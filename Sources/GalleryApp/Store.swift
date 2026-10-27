import AppKit
import Combine
import GalleryCore
import UniformTypeIdentifiers

@MainActor
final class GalleryStore: ObservableObject {
    @Published var theme: GalleryTheme
    @Published var selectedRole: String = ""
    @Published var selectedMotion: Motion = .normal
    @Published var message: String?
    @Published private(set) var importing = false
    @Published private(set) var saveStatus = "已保存在本机"
    let runtime = CursorRuntime()
    let preferences = AppPreferences()
    private var handledLaunch = false
    func handleLaunch() {
        guard !handledLaunch else { return }; handledLaunch = true
        runtime.setScale(preferences.pointerScale)
        if preferences.applyAtLaunch && !runtime.hasRecovery { runtime.start(theme) }
    }
    private var pendingSave: DispatchWorkItem?
    private var projectURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery/current.gallery")
    }
    init(preview: Bool = false) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery/current.gallery")
        let fallback = Demo.makeTheme()
        if !preview, FileManager.default.fileExists(atPath: url.path) {
            do { theme = try ThemeFiles.load(url) }
            catch { theme = fallback; message = "上次的主题未能读取，已载入示例。原文件仍保留：\(error.localizedDescription)" }
        } else { theme = fallback }
        selectedRole = theme.roles[0].id
    }
    var visibleRoles: [CursorRole] {
        var seen = Set<String>()
        return theme.roles.filter { seen.insert($0.name).inserted }
    }
    var roleIndex: Int? { theme.roles.firstIndex { $0.id == selectedRole } }
    var clip: CursorClip? { roleIndex.flatMap { theme.roles[$0].clip(selectedMotion) } }
    func edit(_ action: (inout CursorClip) -> Void) {
        guard !runtime.enabled, let index = roleIndex, var clip else { return }
        action(&clip)
        let name = theme.roles[index].name
        for i in theme.roles.indices where theme.roles[i].name == name {
            theme.roles[i].clips[selectedMotion.rawValue] = clip
        }
        changed()
    }
    func createClip() {
        guard !runtime.enabled, let index = roleIndex else { return }
        let name = theme.roles[index].name, clip = theme.roles[index].clip(.normal)
        for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].clips[selectedMotion.rawValue] = clip }
        changed()
    }
    func removeClip() {
        guard !runtime.enabled, selectedMotion != .normal, let index = roleIndex else { return }
        let name = theme.roles[index].name
        for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].clips.removeValue(forKey: selectedMotion.rawValue) }
        changed()
    }
    func changed() {
        pendingSave?.cancel(); saveStatus = "正在保存…"
        let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }
    func saveNow() {
        pendingSave?.cancel(); pendingSave = nil
        do {
            try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ThemeFiles.save(theme, to: projectURL); saveStatus = "已保存在本机"
        } catch { saveStatus = "保存失败"; message = error.localizedDescription }
    }
    func openTheme() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.item]; panel.allowsMultipleSelection = false
        panel.message = "选择 Gallery 主题（.gallery）、Mousecape 主题（.cape），或 PRTS Windows 安装包（.zip / PRTS-Setup.exe）。"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importURL(url)
    }
    func importURL(_ url: URL) {
        guard !importing else { return }
        let ext = url.pathExtension.lowercased()
        guard ["gallery", "cape", "zip", "exe"].contains(ext) else {
            message = "请选择 .gallery、.cape、PRTS Windows .zip 或 PRTS-Setup.exe。"; return
        }
        importing = true; saveStatus = "正在导入主题…"
        let securityScoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> GalleryTheme in
                defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
                if ext == "gallery" || ext == "cape" { return try ThemeFiles.load(url) }
                return try PRTSImport.load(url)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.importing = false
                switch result {
                case .success(let imported):
                    guard self.runtime.stop() else { return }
                    self.theme = imported; self.selectedRole = imported.roles[0].id; self.selectedMotion = .normal; self.changed()
                    self.message = "已导入「\(imported.name)」，包含 \(self.visibleRoles.count) 类指针。点击「应用主题」启用；可导出为 .gallery，以后直接打开这个文件即可。"
                case .failure(let error): self.message = error.localizedDescription; self.saveStatus = "导入失败"
                }
            }
        }
    }
    func setSplitClick(_ enabled: Bool) {
        guard !runtime.enabled, let index = roleIndex else { return }
        let name = theme.roles[index].name
        for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].splitClickAnimation = enabled }
        changed()
    }
    func exportTheme(cape: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = theme.name + (cape ? ".cape" : ".gallery")
        panel.message = cape ? "导出常态光标供 Mousecape 使用；交互动画请保存为 Gallery 主题。" : "保存包含全部动画和交互设置的主题。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if cape { try ThemeFiles.exportCape(theme, to: url) } else { try ThemeFiles.save(theme, to: url) }
        } catch { message = error.localizedDescription }
    }
    func importFrames(append: Bool) {
        guard !runtime.enabled else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .data]; panel.allowsMultipleSelection = true
        panel.message = "选择 PNG 帧序列、GIF、CUR 或 ANI；多文件按文件名排序。"
        guard panel.runModal() == .OK else { return }
        do {
            let clips = try panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { try AnimationImport.read($0) }
            guard let first = clips.first, let index = roleIndex else { return }
            let newFrames = clips.flatMap(\.frames)
            let old = clip ?? theme.roles[index].clip(.normal)!
            var result = append ? old : CursorClip(frames: [], frameDuration: first.frameDuration,
                width: old.width, height: old.height, hotX: old.hotX, hotY: old.hotY)
            if !append, let ext = panel.urls.first?.pathExtension.lowercased(), ext == "cur" || ext == "ani" {
                result.hotX = first.hotX / first.width * old.width
                result.hotY = first.hotY / first.height * old.height
            }
            result.frames = (append ? old.frames : []) + newFrames
            try result.validate()
            let name = theme.roles[index].name
            for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].clips[selectedMotion.rawValue] = result }
            changed()
        } catch { message = error.localizedDescription }
    }
    func resetDemo() {
        guard runtime.stop() else { return }
        theme = Demo.makeTheme(); selectedRole = theme.roles[0].id; selectedMotion = .normal; changed()
    }
    func importPRTS() { openTheme() }
}
