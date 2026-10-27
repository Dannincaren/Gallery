import AppKit
import Combine
import GalleryCore
import UniformTypeIdentifiers

@MainActor
final class GalleryStore: ObservableObject {
    @Published var theme: GalleryTheme
    @Published var selectedRole = ""
    @Published var selectedMotion: Motion = .normal
    @Published var message: String?
    @Published private(set) var importing = false
    @Published private(set) var saveStatus = "已保存在本机"
    @Published private(set) var library: [LibraryTheme] = []
    @Published private(set) var selectedThemeID: String
    @Published private(set) var activeThemeID: String?
    let runtime = CursorRuntime()
    let preferences = AppPreferences()
    private let root: URL
    private let preview: Bool
    private let selectionDefaults: Bool
    private let saveQueue = DispatchQueue(label: "Gallery.theme-files", qos: .utility)
    private var handledLaunch = false
    private var pendingSave: DispatchWorkItem?
    private var revision = 0
    private var indexURL: URL { root.appendingPathComponent("themes.json") }
    private func themeURL(_ id: String) -> URL { root.appendingPathComponent("Themes/" + id + ".gallery") }
    init(preview: Bool = false, rootURL: URL? = nil) {
        self.preview = preview
        selectionDefaults = rootURL == nil && !preview
        root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Gallery")
        var loaded = Demo.makeTheme(), rows: [LibraryTheme] = [], selected = UUID().uuidString
        if !preview {
            if let index = try? ThemeLibrary.loadIndex(at: root.appendingPathComponent("themes.json")) { rows = index }
            if !rows.isEmpty {
                selected = rows.first(where: { $0.id == UserDefaults.standard.string(forKey: "currentThemeID") })?.id ?? rows[0].id
                if let saved = try? ThemeFiles.load(root.appendingPathComponent("Themes/" + selected + ".gallery")) { loaded = saved }
                else {
                    // Keep a damaged archive intact; opening the editor must
                    // never silently overwrite that user's only copy.
                    selected = UUID().uuidString; rows.append(LibraryTheme(id: selected, theme: loaded))
                }
            } else if let saved = try? ThemeFiles.load(root.appendingPathComponent("current.gallery")) { loaded = saved }
        }
        theme = loaded; selectedThemeID = selected; selectedRole = loaded.roles[0].id
        if rows.isEmpty { rows = [LibraryTheme(id: selected, theme: loaded)] }
        library = rows
        if !preview { saveNow() }
    }
    func setPreviewTheme(_ theme: GalleryTheme) {
        self.theme = theme; selectedRole = theme.roles[0].id
        library = [LibraryTheme(id: selectedThemeID, theme: theme)]
    }
    func handleLaunch() {
        guard !handledLaunch else { return }; handledLaunch = true
        runtime.setScale(preferences.pointerScale)
        if preferences.applyAtLaunch && !runtime.hasRecovery { applyCurrentTheme() }
    }
    func applyCurrentTheme() {
        guard runtime.stop() else { return }
        runtime.setScale(preferences.pointerScale); runtime.start(theme)
        activeThemeID = runtime.enabled ? selectedThemeID : nil
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
        for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].clips[selectedMotion.rawValue] = clip }
        changed()
    }
    func duplicateFrame(at index: Int) -> Int? {
        guard !runtime.enabled, var clip else { return nil }
        do {
            let inserted = try clip.duplicateFrame(at: index)
            edit { $0 = clip }; return inserted
        } catch { message = error.localizedDescription; return nil }
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
    private func refreshEntry() {
        if let index = library.firstIndex(where: { $0.id == selectedThemeID }) { library[index] = LibraryTheme(id: selectedThemeID, theme: theme) }
    }
    func changed() {
        revision += 1; refreshEntry(); pendingSave?.cancel(); saveStatus = "正在保存…"
        let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }
    func saveNow(wait: Bool = false) {
        guard !preview else { return }
        pendingSave?.cancel(); pendingSave = nil; refreshEntry(); revision += 1
        let version = revision, snapshot = theme, rows = library, id = selectedThemeID
        let destination = themeURL(id), root = self.root
        if selectionDefaults { UserDefaults.standard.set(id, forKey: "currentThemeID") }
        let write = {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ThemeFiles.save(snapshot, to: destination)
            try ThemeLibrary.saveIndex(rows, at: root.appendingPathComponent("themes.json"))
            // Preserve compatibility with the previous single-theme location.
            try Data(contentsOf: destination).write(to: root.appendingPathComponent("current.gallery"), options: .atomic)
        }
        if wait {
            do { try saveQueue.sync(execute: write); saveStatus = "已保存在本机" }
            catch { saveStatus = "保存失败"; message = error.localizedDescription }
        } else {
            saveQueue.async { [weak self] in
                let result = Result { try write() }
                DispatchQueue.main.async {
                    guard let self, self.revision == version else { return }
                    switch result {
                    case .success: self.saveStatus = "已保存在本机"
                    case .failure(let error): self.saveStatus = "保存失败"; self.message = error.localizedDescription
                    }
                }
            }
        }
    }
    func selectTheme(_ id: String, role: String? = nil) {
        if id == selectedThemeID { if let role { selectedRole = role }; return }
        guard !importing, library.contains(where: { $0.id == id }) else { return }
        saveNow(); importing = true
        let url = themeURL(id)
        saveQueue.async { [weak self] in
            let result = Result { try ThemeFiles.load(url) }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                switch result {
                case .success(let theme):
                    self.theme = theme; self.selectedThemeID = id
                    self.selectedRole = role ?? theme.roles[0].id; self.selectedMotion = .normal
                    if self.selectionDefaults { UserDefaults.standard.set(id, forKey: "currentThemeID") }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func loadLibraryTheme(_ id: String, completion: @escaping (Result<GalleryTheme, Error>) -> Void) {
        if id == selectedThemeID { completion(.success(theme)); return }
        let url = themeURL(id)
        saveQueue.async {
            let result = Result { try ThemeFiles.load(url) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func installTheme(_ input: GalleryTheme) {
        saveNow()
        var theme = input
        let existing = Set(library.map(\.name)); var suffix = 2
        while existing.contains(theme.name) { theme.name = input.name + " (\(suffix))"; suffix += 1 }
        let row = LibraryTheme(theme: theme)
        library.append(row); self.theme = theme; selectedThemeID = row.id
        selectedRole = theme.roles[0].id; selectedMotion = .normal; changed()
    }
    func openTheme() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.item]; panel.allowsMultipleSelection = false
        panel.message = "导入后会保存为独立主题目录。支持 .gallery、.cape、PRTS Windows ZIP 或 PRTS-Setup.exe。"; panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }; importURL(url)
    }
    func importURL(_ url: URL) {
        guard !importing else { return }
        let ext = url.pathExtension.lowercased()
        guard ["gallery", "cape", "zip", "exe"].contains(ext) else { message = "请选择 .gallery、.cape、PRTS Windows ZIP 或 PRTS-Setup.exe。"; return }
        importing = true; saveStatus = "正在导入主题…"
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> GalleryTheme in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return ext == "gallery" || ext == "cape" ? try ThemeFiles.load(url) : try PRTSImport.load(url)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                switch result {
                case .success(let imported):
                    self.installTheme(imported)
                    self.message = "已加入主题目录。展开目录选择角色；点击「应用此主题」启用。"
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
    func setRoleScale(_ value: Double) {
        guard value.isFinite, let index = roleIndex else { return }
        let name = theme.roles[index].name, value = min(3, max(0.5, value))
        for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].scale = value }
        if activeThemeID == selectedThemeID { runtime.setRoleScale(value, for: selectedRole) }
        changed()
    }
    func setUsesNative(_ value: Bool) {
        guard !runtime.enabled, let index = roleIndex else { return }
        let name = theme.roles[index].name
        for i in theme.roles.indices where theme.roles[i].name == name { theme.roles[i].usesNative = value }
        changed()
    }
    func useTemplate(_ role: CursorRole, sourceName: String) {
        guard !runtime.enabled else { return }
        do { try ThemeLibrary.applyTemplate(role, sourceName: sourceName, to: selectedRole, in: &theme); changed() }
        catch { message = error.localizedDescription }
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
    func resetDemo() { installTheme(Demo.makeTheme()) }
    func importPRTS() { openTheme() }
}
