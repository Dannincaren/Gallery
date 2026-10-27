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
    @Published private(set) var saveStatus = "已保存在本机"
    let runtime = CursorRuntime()
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
    var roleIndex: Int? { theme.roles.firstIndex { $0.id == selectedRole } }
    var clip: CursorClip? { roleIndex.flatMap { theme.roles[$0].clip(selectedMotion) } }
    func edit(_ action: (inout CursorClip) -> Void) {
        guard !runtime.enabled, let index = roleIndex, var clip else { return }
        action(&clip)
        theme.roles[index].clips[selectedMotion.rawValue] = clip
        changed()
    }
    func createClip() {
        guard !runtime.enabled, let index = roleIndex else { return }
        theme.roles[index].clips[selectedMotion.rawValue] = theme.roles[index].clip(.normal)
        changed()
    }
    func removeClip() {
        guard !runtime.enabled, selectedMotion != .normal, let index = roleIndex else { return }
        theme.roles[index].clips.removeValue(forKey: selectedMotion.rawValue); changed()
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
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false
        panel.message = "选择 .cape 或 .gallery 主题"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ThemeFiles.load(url)
            guard runtime.stop() else { return }
            theme = imported; selectedRole = imported.roles[0].id; selectedMotion = .normal; changed()
        } catch { message = error.localizedDescription }
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
            theme.roles[index].clips[selectedMotion.rawValue] = result; changed()
        } catch { message = error.localizedDescription }
    }
    func resetDemo() {
        guard runtime.stop() else { return }
        theme = Demo.makeTheme(); selectedRole = theme.roles[0].id; selectedMotion = .normal; changed()
    }
    func importPRTS() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false
        panel.message = "选择 PRTS Windows 发布包 ZIP，或解压后的 PRTS-Setup.exe。只读取嵌入素材，不运行 Windows 程序。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveStatus = "正在导入 PRTS…"
        // Archive expansion and image decoding are deliberately off the UI thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> GalleryTheme in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                var input = url
                if url.pathExtension.lowercased() == "zip" {
                    let extracted = directory.appendingPathComponent("PRTS-Setup.exe")
                    FileManager.default.createFile(atPath: extracted.path, contents: nil)
                    let output = try FileHandle(forWritingTo: extracted)
                    defer { try? output.close() }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = ["-p", url.path, "*/PRTS-Setup.exe"]
                    process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw ThemeError.invalid("ZIP 中没有找到 PRTS-Setup.exe。") }
                    input = extracted
                }
                let data = try Data(contentsOf: input, options: .mappedIfSafe)
                return try WindowsResources(data: data).theme()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let imported):
                    guard self.runtime.stop() else { return }
                    self.theme = imported; self.selectedRole = imported.roles[0].id; self.selectedMotion = .normal; self.changed()
                case .failure(let error): self.message = error.localizedDescription; self.saveStatus = "导入失败"
                }
            }
        }
    }
}
