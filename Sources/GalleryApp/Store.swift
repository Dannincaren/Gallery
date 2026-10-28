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
    private var thumbnailJobs = Set<String>()
    private var subscriptions = Set<AnyCancellable>()
    private var pendingDockRefresh: DispatchWorkItem?
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
        library = [ThemeLibrary.thumbnails(id: selectedThemeID, theme: theme, previous: nil)]
    }
    func handleLaunch() {
        guard !handledLaunch else { return }; handledLaunch = true
        runtime.setScale(preferences.pointerScale)
        runtime.setShakeEnabled(preferences.shakeToLocate)
        if selectionDefaults {
            runtime.$enabled.combineLatest(preferences.$hideDockIconWhileRunning)
                .map { $0 && $1 }.removeDuplicates().sink { [weak self] _ in
                    self?.refreshDockVisibility()
                }.store(in: &subscriptions)
            preferences.$shakeToLocate.removeDuplicates().sink { [weak self] value in
                self?.runtime.setShakeEnabled(value)
            }.store(in: &subscriptions)
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification, NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                    self?.refreshDockVisibility()
                }.store(in: &subscriptions)
            }
        }
        if preferences.applyAtLaunch && !runtime.hasRecovery { applyCurrentTheme() }
    }
    func refreshDockVisibility() {
        guard selectionDefaults else { return }
        // SwiftUI can restore the regular activation policy when reopening a
        // window. Reapply after that transaction, without a polling timer.
        let apply = { [weak self] in
            guard let self else { return }
            let policy: NSApplication.ActivationPolicy = self.runtime.enabled && self.preferences.hideDockIconWhileRunning ? .accessory : .regular
            if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
            self.preferences.recordDockVisibility(hidden: NSApp.activationPolicy() == .accessory)
        }
        DispatchQueue.main.async(execute: apply)
        pendingDockRefresh?.cancel()
        let settled = DispatchWorkItem(block: apply); pendingDockRefresh = settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settled)
    }
    func applyCurrentTheme() {
        guard runtime.stop() else { return }
        runtime.setScale(preferences.pointerScale); runtime.start(theme)
        activeThemeID = runtime.enabled ? selectedThemeID : nil
    }
    var visibleRoles: [CursorRole] {
        var seen = Set<String>()
        return theme.roles.filter { seen.insert(CursorCatalog.family($0.id)).inserted }
    }
    var roleIndex: Int? { theme.roles.firstIndex { $0.id == selectedRole } }
    var clip: CursorClip? { roleIndex.flatMap { theme.roles[$0].clip(selectedMotion) } }
    func edit(_ action: (inout CursorClip) -> Void) {
        guard !runtime.enabled, let index = roleIndex, var clip else { return }
        action(&clip)
        let family = CursorCatalog.family(theme.roles[index].id)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips[selectedMotion.rawValue] = clip }
        changed()
    }
    func duplicateFrame(at index: Int) -> Int? {
        guard !runtime.enabled, var clip else { return nil }
        do {
            let inserted = try clip.duplicateFrame(at: index)
            edit { $0 = clip }; return inserted
        } catch { message = error.localizedDescription; return nil }
    }
    func selectVariant(_ id: String, for motion: Motion) {
        guard !runtime.enabled, let index = roleIndex else { return }
        var role = theme.roles[index]; role.selectVariant(id, for: motion)
        copyVariants(role, motion: motion)
        changed()
    }
    private func copyVariants(_ role: CursorRole, motion: Motion) {
        let family = CursorCatalog.family(role.id), key = motion.rawValue
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family {
            theme.roles[i].clips[key] = role.clips[key]
            theme.roles[i].variants[key] = role.variants[key]
            theme.roles[i].selectedVariants[key] = role.selectedVariants[key]
        }
    }
    func addVariant(_ clip: CursorClip, name: String, for motion: Motion) throws {
        guard !runtime.enabled, let index = roleIndex else { return }
        try clip.validate()
        let key = motion.rawValue
        guard (theme.roles[index].variants[key]?.count ?? 0) < 31 else { throw ThemeError.invalid("每个状态最多保留 32 套素材。") }
        let id = UUID().uuidString
        var role = theme.roles[index]
        role.variants[key, default: []].append(CursorVariant(id: id, name: name, clip: clip))
        role.selectVariant(id, for: motion); copyVariants(role, motion: motion)
        changed()
    }
    func importVariant() {
        guard !runtime.enabled else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .data]; panel.allowsMultipleSelection = false
        panel.message = "为「\(selectedMotion.title)」添加另一套素材，保留已有版本。支持 PNG、GIF、CUR、ANI。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try addVariant(AnimationImport.read(url), name: url.lastPathComponent, for: selectedMotion) }
        catch { message = error.localizedDescription }
    }
    func createClip() {
        guard !runtime.enabled, let index = roleIndex else { return }
        let family = CursorCatalog.family(theme.roles[index].id), clip = theme.roles[index].clip(.normal)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips[selectedMotion.rawValue] = clip }
        changed()
    }
    func removeClip() {
        guard !runtime.enabled, selectedMotion != .normal, let index = roleIndex else { return }
        let family = CursorCatalog.family(theme.roles[index].id)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips.removeValue(forKey: selectedMotion.rawValue) }
        changed()
    }
    private func refreshEntry() {
        if let index = library.firstIndex(where: { $0.id == selectedThemeID }) {
            let old = library[index]
            var updated = LibraryTheme(id: selectedThemeID, theme: theme)
            for i in updated.roles.indices {
                if let previous = old.roles.first(where: { $0.id == updated.roles[i].id }) {
                    updated.roles[i].thumbnail = previous.thumbnail; updated.roles[i].thumbnailKey = previous.thumbnailKey
                }
            }
            library[index] = updated
        }
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
            let row = ThemeLibrary.thumbnails(id: id, theme: snapshot, previous: rows.first { $0.id == id })
            var updatedRows = rows
            if let index = updatedRows.firstIndex(where: { $0.id == id }) { updatedRows[index] = row }
            try ThemeLibrary.saveIndex(updatedRows, at: root.appendingPathComponent("themes.json"))
            // Preserve compatibility with the previous single-theme location.
            try Data(contentsOf: destination).write(to: root.appendingPathComponent("current.gallery"), options: .atomic)
            return row
        }
        if wait {
            do { let row = try saveQueue.sync(execute: write); mergeThumbnails(row); saveStatus = "已保存在本机" }
            catch { saveStatus = "保存失败"; message = error.localizedDescription }
        } else {
            saveQueue.async { [weak self] in
                let result = Result { try write() }
                DispatchQueue.main.async {
                    guard let self, self.revision == version else { return }
                    switch result {
                    case .success(let row): self.mergeThumbnails(row); self.saveStatus = "已保存在本机"
                    case .failure(let error): self.saveStatus = "保存失败"; self.message = error.localizedDescription
                    }
                }
            }
        }
    }
    private func mergeThumbnails(_ row: LibraryTheme) {
        guard let index = library.firstIndex(where: { $0.id == row.id }) else { return }
        var updated = library[index]
        for i in updated.roles.indices {
            if let source = row.roles.first(where: { $0.id == updated.roles[i].id }) {
                updated.roles[i].thumbnail = source.thumbnail
                updated.roles[i].thumbnailKey = source.thumbnailKey
            }
        }
        library[index] = updated
    }
    func ensureThumbnails(_ id: String) {
        guard !preview, let entry = library.first(where: { $0.id == id }), entry.roles.contains(where: { $0.thumbnail == nil }), !thumbnailJobs.contains(id) else { return }
        if id == selectedThemeID { saveNow(); return }
        thumbnailJobs.insert(id)
        let url = themeURL(id)
        saveQueue.async { [weak self] in
            let row = (try? ThemeFiles.load(url)).map { ThemeLibrary.thumbnails(id: id, theme: $0, previous: entry) }
            DispatchQueue.main.async {
                guard let self else { return }; self.thumbnailJobs.remove(id)
                if let row {
                    self.mergeThumbnails(row)
                    let rows = self.library, url = self.indexURL
                    self.saveQueue.async { try? ThemeLibrary.saveIndex(rows, at: url) }
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
    func setRoleScale(_ value: Double, for identifier: String? = nil) {
        guard value.isFinite, let index = theme.roles.firstIndex(where: { $0.id == (identifier ?? selectedRole) }) else { return }
        let family = CursorCatalog.family(theme.roles[index].id), value = min(3, max(0.5, value))
        guard theme.roles.contains(where: { CursorCatalog.family($0.id) == family && $0.scale != value }) else { return }
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].scale = value }
        if activeThemeID == selectedThemeID { runtime.setRoleScale(value, for: theme.roles[index].id) }
        changed()
    }
    func setRoleIdleDelay(_ value: Double?, for identifier: String) {
        guard value == nil || (value!.isFinite && (1...600).contains(value!)) else { return }
        let family = CursorCatalog.family(identifier)
        guard theme.roles.contains(where: { CursorCatalog.family($0.id) == family && $0.idleDelayOverride != value }) else { return }
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].idleDelayOverride = value }
        if activeThemeID == selectedThemeID { runtime.setRoleIdleDelay(value, for: identifier) }
        changed()
    }
    func setUsesNative(_ value: Bool) {
        guard !runtime.enabled, let index = roleIndex else { return }
        let family = CursorCatalog.family(theme.roles[index].id)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].usesNative = value }
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
            let family = CursorCatalog.family(theme.roles[index].id)
            for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips[selectedMotion.rawValue] = result }
            changed()
        } catch { message = error.localizedDescription }
    }
    func resetDemo() { installTheme(Demo.makeTheme()) }
    func importPRTS() { openTheme() }
}
