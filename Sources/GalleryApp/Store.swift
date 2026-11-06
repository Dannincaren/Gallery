import AppKit
import Combine
import GalleryCore
import UniformTypeIdentifiers

struct ThemeImportReview: Identifiable {
    let id = UUID()
    let themes: [GalleryTheme]
}

@MainActor
final class GalleryStore: ObservableObject {
    @Published var theme: GalleryTheme
    @Published var selectedRole = ""
    @Published var selectedMotion: Motion = .normal
    @Published var message: String?
    @Published var importReview: ThemeImportReview?
    @Published private(set) var importing = false
    @Published private(set) var saveStatus = L("已保存在本机")
    @Published private(set) var library: [LibraryTheme] = []
    @Published private(set) var selectedThemeID: String
    @Published private(set) var activeThemeID: String?
    let runtime: CursorRuntime
    let preferences = AppPreferences()
    private let root: URL
    private let preview: Bool
    private let selectionDefaults: Bool
    private let loadStoredTheme: @Sendable (URL) throws -> GalleryTheme
    private let themeReads = ThemeReadCache()
    private var pendingThemePreparation: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "Gallery.theme-files", qos: .utility)
    private var handledLaunch = false
    private var pendingSave: DispatchWorkItem?
    private var revision = 0
    private var thumbnailJobs = Set<String>()
    private var libraryRevision = 0
    private var orderRevision = 0
    private var deletingTheme = false
    private let trashThemeFile: (URL) throws -> URL
    private var subscriptions = Set<AnyCancellable>()
    private var pendingDockRefresh: DispatchWorkItem?
    private var indexURL: URL { root.appendingPathComponent("themes.json") }
    private func themeURL(_ id: String) -> URL { root.appendingPathComponent("Themes/" + id + ".gallery") }
    init(preview: Bool = false, rootURL: URL? = nil, legacyPointerScale: Double? = nil, runtime: CursorRuntime? = nil, trashThemeFile: ((URL) throws -> URL)? = nil) {
        self.runtime = runtime ?? CursorRuntime()
        let savedScale = legacyPointerScale ?? (rootURL == nil && !preview ? UserDefaults.standard.double(forKey: "pointerScale") : 1)
        let inheritedScale = savedScale.isFinite && (0.25...3).contains(savedScale) ? savedScale : 1
        let read: @Sendable (URL) throws -> GalleryTheme = { try ThemeFiles.load($0, legacyPointerScale: inheritedScale) }
        loadStoredTheme = read
        self.trashThemeFile = trashThemeFile ?? { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            guard let result = trashed as URL? else { throw ThemeError.invalid(L("主题已移入废纸篓，但未能获取恢复位置。")) }
            return result
        }
        self.preview = preview
        selectionDefaults = rootURL == nil && !preview
        root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Gallery")
        var loaded = Demo.makeTheme(), rows: [LibraryTheme] = [], selected = UUID().uuidString
        if !preview {
            if let index = try? ThemeLibrary.loadIndex(at: root.appendingPathComponent("themes.json")) { rows = index }
            if !rows.isEmpty {
                selected = rows.first(where: { $0.id == UserDefaults.standard.string(forKey: "currentThemeID") })?.id ?? rows[0].id
                if let saved = try? read(root.appendingPathComponent("Themes/" + selected + ".gallery")) { loaded = saved }
                else {
                    // Keep a damaged archive intact; opening the editor must
                    // never silently overwrite that user's only copy.
                    selected = UUID().uuidString; rows.append(LibraryTheme(id: selected, theme: loaded))
                }
            } else if let saved = try? read(root.appendingPathComponent("current.gallery")) { loaded = saved }
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
        if preferences.applyAtLaunch && !runtime.hasRecovery {
            let saved = selectionDefaults ? UserDefaults.standard.string(forKey: "lastAppliedThemeID") : nil
            let target = saved.flatMap { id in library.contains(where: { $0.id == id }) ? id : nil } ?? selectedThemeID
            selectTheme(target, activate: true)
        }
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
    var activeThemeName: String? {
        guard runtime.enabled, let activeThemeID else { return nil }
        return library.first(where: { $0.id == activeThemeID })?.localizedName
    }
    func isActiveTheme(_ id: String) -> Bool { runtime.enabled && activeThemeID == id }
    var editingActiveTheme: Bool { isActiveTheme(selectedThemeID) }
    func applyCurrentTheme() {
        guard !importing else { return }
        saveNow(wait: true)
        guard saveStatus == L("已保存在本机"), runtime.stop() else { return }
        runtime.start(theme)
        activeThemeID = runtime.enabled ? selectedThemeID : nil
        if runtime.enabled && selectionDefaults { UserDefaults.standard.set(selectedThemeID, forKey: "lastAppliedThemeID") }
    }
    var visibleRoles: [CursorRole] {
        var seen = Set<String>()
        return theme.roles.filter { seen.insert(CursorCatalog.family($0.id)).inserted }
    }
    var roleIndex: Int? { theme.roles.firstIndex { $0.id == selectedRole } }
    var clip: CursorClip? { roleIndex.flatMap { theme.roles[$0].clip(selectedMotion) } }
    func edit(_ action: (inout CursorClip) -> Void) {
        guard !editingActiveTheme, let index = roleIndex, var clip else { return }
        action(&clip)
        let family = CursorCatalog.family(theme.roles[index].id)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips[selectedMotion.rawValue] = clip }
        changed()
    }
    func duplicateFrame(at index: Int) -> Int? {
        guard !editingActiveTheme, var clip else { return nil }
        do {
            let inserted = try clip.duplicateFrame(at: index)
            edit { $0 = clip }; return inserted
        } catch { message = error.localizedDescription; return nil }
    }
    func setThemeCover(at index: Int) {
        guard !preview, !importing, let clip, clip.frames.indices.contains(index), theme.coverFrame != clip.frames[index] else { return }
        theme.coverFrame = clip.frames[index]; changed(); saveNow()
    }
    func resetThemeCover() {
        guard !preview, !importing, theme.coverFrame != nil else { return }
        theme.coverFrame = nil; changed(); saveNow()
    }
    func selectVariant(_ id: String, for motion: Motion) {
        guard !editingActiveTheme, let index = roleIndex else { return }
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
        guard !editingActiveTheme, let index = roleIndex else { return }
        try clip.validate()
        let key = motion.rawValue
        guard (theme.roles[index].variants[key]?.count ?? 0) < 31 else { throw ThemeError.invalid(L("每个状态最多保留 32 套素材。")) }
        let id = UUID().uuidString
        var role = theme.roles[index]
        role.variants[key, default: []].append(CursorVariant(id: id, name: name, clip: clip))
        role.selectVariant(id, for: motion); copyVariants(role, motion: motion)
        changed()
    }
    func importVariant() {
        guard !editingActiveTheme else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .data]; panel.allowsMultipleSelection = false
        panel.message = L("为「\(selectedMotion.title)」添加另一套素材，保留已有版本。支持 PNG、GIF、CUR、ANI。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try addVariant(AnimationImport.read(url), name: url.lastPathComponent, for: selectedMotion) }
        catch { message = error.localizedDescription }
    }
    func createClip() {
        guard !editingActiveTheme, let index = roleIndex else { return }
        let family = CursorCatalog.family(theme.roles[index].id), clip = theme.roles[index].clip(.normal)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips[selectedMotion.rawValue] = clip }
        changed()
    }
    func removeClip() {
        guard !editingActiveTheme, selectedMotion != .normal, let index = roleIndex else { return }
        let family = CursorCatalog.family(theme.roles[index].id)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].clips.removeValue(forKey: selectedMotion.rawValue) }
        changed()
    }
    private func refreshEntry() {
        if let index = library.firstIndex(where: { $0.id == selectedThemeID }) {
            let old = library[index]
            var updated = LibraryTheme(id: selectedThemeID, theme: theme)
            updated.cover = old.cover; updated.coverKey = old.coverKey
            for i in updated.roles.indices {
                if let previous = old.roles.first(where: { $0.id == updated.roles[i].id }) {
                    updated.roles[i].thumbnail = previous.thumbnail; updated.roles[i].thumbnailKey = previous.thumbnailKey
                }
            }
            if updated != old { library[index] = updated }
        }
    }
    func changed() {
        revision += 1; refreshEntry(); pendingSave?.cancel()
        if saveStatus != L("正在保存…") { saveStatus = L("正在保存…") }
        let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }
    func saveIfNeeded() {
        if pendingSave != nil || saveStatus != L("已保存在本机") { saveNow() }
    }
    func prepareTheme(_ id: String) {
        cancelThemePreparation()
        guard id != selectedThemeID, library.contains(where: { $0.id == id }) else { return }
        let url = themeURL(id), read = loadStoredTheme, cache = themeReads
        let task = DispatchWorkItem {
            guard cache.canPrepare(url) else { return }
            _ = try? cache.load(url, read: read)
        }
        pendingThemePreparation = task
        saveQueue.asyncAfter(deadline: .now() + 0.08, execute: task)
    }
    func cancelThemePreparation() { pendingThemePreparation?.cancel(); pendingThemePreparation = nil }
    func saveNow(wait: Bool = false) {
        guard !preview, !deletingTheme else { return }
        pendingSave?.cancel(); pendingSave = nil; refreshEntry(); revision += 1
        let version = revision, snapshot = theme, rows = library, id = selectedThemeID
        let destination = themeURL(id), root = self.root, cache = themeReads
        if selectionDefaults { UserDefaults.standard.set(id, forKey: "currentThemeID") }
        let write = {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ThemeFiles.save(snapshot, to: destination)
            cache.remember(snapshot, at: destination)
            let row = ThemeLibrary.thumbnails(id: id, theme: snapshot, previous: rows.first { $0.id == id })
            var updatedRows = rows
            if let index = updatedRows.firstIndex(where: { $0.id == id }) { updatedRows[index] = row }
            try ThemeLibrary.saveIndex(updatedRows, at: root.appendingPathComponent("themes.json"))
            // Preserve compatibility with the previous single-theme location.
            try Data(contentsOf: destination).write(to: root.appendingPathComponent("current.gallery"), options: .atomic)
            return row
        }
        if wait {
            do { let row = try saveQueue.sync(execute: write); mergeThumbnails(row); saveStatus = L("已保存在本机") }
            catch { saveStatus = L("保存失败"); message = error.localizedDescription }
        } else {
            saveQueue.async { [weak self] in
                let result = Result { try write() }
                DispatchQueue.main.async {
                    guard let self, self.revision == version else { return }
                    switch result {
                    case .success(let row): self.mergeThumbnails(row); self.saveStatus = L("已保存在本机")
                    case .failure(let error): self.saveStatus = L("保存失败"); self.message = error.localizedDescription
                    }
                }
            }
        }
    }
    private func mergeThumbnails(_ row: LibraryTheme) {
        guard let index = library.firstIndex(where: { $0.id == row.id }) else { return }
        var updated = library[index]
        updated.appearance = row.appearance
        updated.cover = row.cover; updated.coverKey = row.coverKey
        for i in updated.roles.indices {
            if let source = row.roles.first(where: { $0.id == updated.roles[i].id }) {
                updated.roles[i].thumbnail = source.thumbnail
                updated.roles[i].thumbnailKey = source.thumbnailKey
            }
        }
        if library[index] != updated { library[index] = updated }
    }
    func ensureThumbnails(_ id: String) {
        guard !preview, let entry = library.first(where: { $0.id == id }), ThemeLibrary.needsThumbnails(entry), !thumbnailJobs.contains(id) else { return }
        if id == selectedThemeID { saveNow(); return }
        thumbnailJobs.insert(id)
        let url = themeURL(id), capturedLibrary = libraryRevision, capturedRevision = revision, read = loadStoredTheme
        saveQueue.async { [weak self] in
            let row = (try? read(url)).map { ThemeLibrary.thumbnails(id: id, theme: $0, previous: entry) }
            DispatchQueue.main.async {
                guard let self else { return }; self.thumbnailJobs.remove(id)
                guard capturedLibrary == self.libraryRevision, self.library.contains(where: { $0.id == id }) else { return }
                guard id != self.selectedThemeID || capturedRevision == self.revision else { return }
                if let row {
                    self.mergeThumbnails(row)
                    let rows = self.library, url = self.indexURL
                    self.saveQueue.async { try? ThemeLibrary.saveIndex(rows, at: url) }
                }
            }
        }
    }
    /// The array order is the persisted gallery order. Do not reload/apply a
    /// theme or rewrite its animation archive just to move a card.
    func moveTheme(_ id: String, to destination: Int) {
        guard !preview, !importing, library.indices.contains(destination),
              let source = library.firstIndex(where: { $0.id == id }), source != destination else { return }
        var ids = library.map(\.id)
        let moved = ids.remove(at: source)
        ids.insert(moved, at: destination)
        reorderThemes(ids)
    }
    func reorderThemes(_ ids: [String]) {
        let previousIDs = library.map(\.id)
        guard !preview, !importing, ids != previousIDs, ids.count == library.count,
              Set(ids).count == ids.count, Set(ids) == Set(previousIDs) else { return }
        let entries = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let rows = ids.compactMap { entries[$0] }
        library = rows; orderRevision += 1
        let snapshot = rows, version = orderRevision, index = indexURL
        saveQueue.async { [weak self] in
            let result = Result { try ThemeLibrary.saveIndex(snapshot, at: index) }
            DispatchQueue.main.async {
                guard let self, self.orderRevision == version else { return }
                if case .failure(let error) = result {
                    if self.library.map(\.id) == snapshot.map(\.id) {
                        let positions = Dictionary(uniqueKeysWithValues: previousIDs.enumerated().map { ($0.element, $0.offset) })
                        self.library.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
                    }
                    self.message = L("主题顺序保存失败：\(error.localizedDescription)")
                }
            }
        }
    }
    func selectTheme(_ id: String, role: String? = nil, activate: Bool = false) {
        guard !importing else { return }
        if id == selectedThemeID {
            if let role { selectedRole = role }
            if activate { applyCurrentTheme() }; return
        }
        guard !importing, library.contains(where: { $0.id == id }) else { return }
        cancelThemePreparation(); saveIfNeeded(); importing = true
        let url = themeURL(id), read = loadStoredTheme, cache = themeReads, compatibility = root.appendingPathComponent("current.gallery")
        saveQueue.async(qos: .userInitiated) { [weak self] in
            let result = Result {
                let theme = try cache.load(url, read: read)
                // Preserve the legacy current-theme file without re-encoding
                // all images and aliases when navigation did not edit them.
                try Data(contentsOf: url, options: .mappedIfSafe).write(to: compatibility, options: .atomic)
                return theme
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                // The save and load use the same serial queue; its save-result
                // callback reaches the main queue before this callback.
                guard self.saveStatus == L("已保存在本机") else { return }
                switch result {
                case .success(let theme):
                    self.theme = theme; self.selectedThemeID = id
                    self.selectedRole = role ?? theme.roles[0].id; self.selectedMotion = .normal
                    if self.selectionDefaults { UserDefaults.standard.set(id, forKey: "currentThemeID") }
                    if activate { self.applyCurrentTheme() }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func loadLibraryTheme(_ id: String, completion: @escaping (Result<GalleryTheme, Error>) -> Void) {
        if id == selectedThemeID { completion(.success(theme)); return }
        let url = themeURL(id), read = loadStoredTheme, cache = themeReads
        saveQueue.async {
            let result = Result { try cache.load(url, read: read) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func deleteTheme(_ id: String) {
        guard !preview, !importing, let removed = library.first(where: { $0.id == id }) else { return }
        saveNow(wait: true)
        guard saveStatus == L("已保存在本机") else { return }
        if isActiveTheme(id), !runtime.stop() { return }
        if activeThemeID == id { activeThemeID = nil }
        // Drain previous writes before taking the file out of the library.
        // Invalidate delayed thumbnail callbacks so none can restore an old
        // directory index after the deletion commits.
        libraryRevision += 1; revision += 1; importing = true; deletingTheme = true
        let previousRows = library, previousTheme = theme, previousID = selectedThemeID
        let root = self.root, source = themeURL(id), trash = trashThemeFile, read = loadStoredTheme
        saveQueue.async { [weak self] in
            let result = Result { () -> (GalleryTheme, String, [LibraryTheme]) in
                var rows = previousRows.filter { $0.id != id }
                let selected: String, next: GalleryTheme
                if previousID != id { selected = previousID; next = previousTheme }
                else if let first = rows.first {
                    selected = first.id
                    next = try read(root.appendingPathComponent("Themes/" + first.id + ".gallery"))
                } else {
                    next = Demo.makeTheme()
                    let row = ThemeLibrary.thumbnails(id: UUID().uuidString, theme: next, previous: nil)
                    selected = row.id; rows = [row]
                }
                let index = root.appendingPathComponent("themes.json"), compatibility = root.appendingPathComponent("current.gallery")
                let oldIndex = try Data(contentsOf: index), oldCompatibility = try Data(contentsOf: compatibility)
                let fallbackURL = root.appendingPathComponent("Themes/" + selected + ".gallery")
                let createsFallback = !FileManager.default.fileExists(atPath: fallbackURL.path)
                // Trash is recoverable through Finder. Keep its returned URL
                // so a failed index write can also roll back the move.
                let trashed = try trash(source)
                do {
                    if createsFallback { try ThemeFiles.save(next, to: fallbackURL) }
                    try ThemeFiles.save(next, to: compatibility)
                    try ThemeLibrary.saveIndex(rows, at: index)
                } catch {
                    try? oldIndex.write(to: index, options: .atomic)
                    try? oldCompatibility.write(to: compatibility, options: .atomic)
                    if createsFallback { try? FileManager.default.removeItem(at: fallbackURL) }
                    do { try FileManager.default.moveItem(at: trashed, to: source) }
                    catch { throw ThemeError.invalid(L("删除未完成，主题备份位于废纸篓：\(trashed.lastPathComponent)。请重新导入该文件。")) }
                    throw error
                }
                return (next, selected, rows)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.deletingTheme = false; self.importing = false
                switch result {
                case .success(let (next, selected, rows)):
                    self.library = rows; self.theme = next; self.selectedThemeID = selected
                    if previousID == id { self.selectedRole = next.roles[0].id; self.selectedMotion = .normal }
                    if self.selectionDefaults {
                        UserDefaults.standard.set(selected, forKey: "currentThemeID")
                        if UserDefaults.standard.string(forKey: "lastAppliedThemeID") == id { UserDefaults.standard.removeObject(forKey: "lastAppliedThemeID") }
                    }
                    self.saveStatus = L("已保存在本机")
                    self.message = L("已删除「\(removed.name)」并移入废纸篓。需要找回时，可取出 .gallery 文件重新导入。")
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    private func installTheme(_ input: GalleryTheme) {
        saveNow()
        var theme = input
        let existing = Set(library.map(\.name)); var suffix = 2
        while existing.contains(theme.name) { theme.name = input.name + " (\(suffix))"; suffix += 1 }
        let row = LibraryTheme(theme: theme)
        libraryRevision += 1
        library.append(row); self.theme = theme; selectedThemeID = row.id
        selectedRole = theme.roles[0].id; selectedMotion = .normal; changed()
    }
    func openTheme() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.item]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = true
        panel.message = L("支持最高 2 GB 的 ZIP、含光标的 .NET／单文件／Inno Setup EXE，以及 CUR、ANI、光标文件夹、INF、Gallery／Mousecape 主题。多套素材可先勾选；仅提取光标，原文件不会改动。"); panel.prompt = L("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }; importURL(url)
    }
    func importURL(_ url: URL) {
        guard !importing, importReview == nil else { return }
        let ext = url.pathExtension.lowercased()
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard directory || ["gallery", "cape", "zip", "exe", "inf", "cur", "ani"].contains(ext) else { message = L("请选择主题文件、CUR／ANI 光标、素材文件夹、INF、ZIP 或 EXE 安装器。"); return }
        importing = true; saveStatus = L("正在导入主题…")
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> [GalleryTheme] in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return !directory && (ext == "gallery" || ext == "cape") ? [try ThemeFiles.load(url)] : try WindowsThemeImport.candidates(url)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                switch result {
                case .success(let imported):
                    if imported.count > 1 || imported.contains(where: ImportSelection.hasAlternatives) {
                        self.importReview = ThemeImportReview(themes: imported); self.saveStatus = L("等待选择导入素材")
                    } else if let theme = imported.first {
                        self.installTheme(theme)
                        self.message = L("已加入主题橱窗。打开卡片可编辑角色；在主题菜单中选择「使用此主题」启用。")
                    }
                case .failure(let error): self.message = error.localizedDescription; self.saveStatus = L("导入失败")
                }
            }
        }
    }
    func cancelImportReview() {
        importReview = nil
        if saveStatus == L("等待选择导入素材") { saveStatus = L("已保存在本机") }
    }
    func confirmImportReview(_ inputs: [GalleryTheme]) {
        guard !importing, !inputs.isEmpty, library.count + inputs.count <= 200 else {
            message = L("请至少选择一套主题；主题目录最多保留 200 套。"); return
        }
        saveNow(); importReview = nil; importing = true; libraryRevision += 1
        var names = Set(library.map(\.name))
        let imports = inputs.map { input -> (GalleryTheme, LibraryTheme) in
            var value = input, suffix = 2
            while names.contains(value.name) { value.name = input.name + " (\(suffix))"; suffix += 1 }
            names.insert(value.name); return (value, LibraryTheme(theme: value))
        }
        let rows = library, root = self.root, index = indexURL
        saveQueue.async { [weak self] in
            let result = Result { () -> [LibraryTheme] in
                let oldIndex = try Data(contentsOf: index)
                let compatibility = root.appendingPathComponent("current.gallery")
                let oldCurrent = try? Data(contentsOf: compatibility)
                var created: [URL] = [], added: [LibraryTheme] = []
                do {
                    for (theme, row) in imports {
                        let url = root.appendingPathComponent("Themes/" + row.id + ".gallery")
                        try ThemeFiles.save(theme, to: url); created.append(url)
                        added.append(ThemeLibrary.thumbnails(id: row.id, theme: theme, previous: nil))
                    }
                    try ThemeLibrary.saveIndex(rows + added, at: index)
                    try Data(contentsOf: created[0]).write(to: compatibility, options: .atomic)
                    return added
                } catch {
                    for url in created { try? FileManager.default.removeItem(at: url) }
                    try? oldIndex.write(to: index, options: .atomic)
                    if let oldCurrent { try? oldCurrent.write(to: compatibility, options: .atomic) }
                    throw error
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                switch result {
                case .success(let added):
                    self.library = rows + added; self.theme = imports[0].0; self.selectedThemeID = added[0].id
                    self.selectedRole = self.theme.roles[0].id; self.selectedMotion = .normal; self.saveStatus = L("已保存在本机")
                    if self.selectionDefaults { UserDefaults.standard.set(added[0].id, forKey: "currentThemeID") }
                    self.message = L("已导入所选 \(added.count) 套主题。")
                case .failure(let error): self.message = error.localizedDescription; self.saveStatus = L("导入失败")
                }
            }
        }
    }
    func setThemeScale(_ value: Double) {
        guard value.isFinite else { return }
        let value = min(3, max(0.25, value))
        guard theme.pointerScale != value else { return }
        theme.pointerScale = value
        // Browsing another collection must not resize the applied theme.
        if runtime.enabled && activeThemeID == selectedThemeID { runtime.setScale(value) }
        changed()
    }
    func setRoleScale(_ value: Double, for identifier: String? = nil) {
        guard value.isFinite, let index = theme.roles.firstIndex(where: { $0.id == (identifier ?? selectedRole) }) else { return }
        let family = CursorCatalog.family(theme.roles[index].id), value = min(3, max(0.25, value))
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
    func setDefaultIdleDelay(_ value: Double) {
        guard !editingActiveTheme, value.isFinite else { return }
        let delay = min(600, max(1, value.rounded()))
        guard theme.idleDelay != delay else { return }
        theme.idleDelay = delay; changed()
    }
    func setAppearance(_ value: CursorAppearance) {
        guard !editingActiveTheme, theme.appearance != value else { return }
        theme.appearance = value; changed()
    }
    func setUsesNative(_ value: Bool) {
        guard !editingActiveTheme, let index = roleIndex else { return }
        let family = CursorCatalog.family(theme.roles[index].id)
        for i in theme.roles.indices where CursorCatalog.family(theme.roles[i].id) == family { theme.roles[i].usesNative = value }
        changed()
    }
    func useTemplate(_ role: CursorRole, sourceName: String) {
        guard !editingActiveTheme else { return }
        do { try ThemeLibrary.applyTemplate(role, sourceName: sourceName, to: selectedRole, in: &theme); changed() }
        catch { message = error.localizedDescription }
    }
    func exportTheme(cape: Bool = false) { exportTheme(selectedThemeID, cape: cape) }
    func exportTheme(_ id: String, cape: Bool = false) {
        guard !importing else { return }
        loadLibraryTheme(id) { [weak self] result in
            guard let self else { return }
            do {
                let snapshot = try result.get()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = snapshot.name + (cape ? ".cape" : ".gallery")
                panel.message = cape ? L("导出常态光标供 Mousecape 使用；交互动画请保存为 Gallery 主题。") : L("保存包含全部动画和交互设置的主题。")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                if cape { try ThemeFiles.exportCape(snapshot, to: url) } else { try ThemeFiles.save(snapshot, to: url) }
            } catch { self.message = error.localizedDescription }
        }
    }
    func renameTheme(_ id: String, to input: String) {
        guard !importing, library.contains(where: { $0.id == id }) else { return }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { message = L("主题名称不能为空。"); return }
        if id == selectedThemeID { theme.name = name; changed(); return }
        saveNow(); libraryRevision += 1; revision += 1; importing = true
        let rows = library, destination = themeURL(id), index = indexURL, read = loadStoredTheme
        saveQueue.async { [weak self] in
            let result = Result { () -> LibraryTheme in
                let original = try Data(contentsOf: destination), originalIndex = try Data(contentsOf: index)
                var theme = try read(destination); theme.name = name
                let row = ThemeLibrary.thumbnails(id: id, theme: theme, previous: rows.first { $0.id == id })
                var updated = rows
                if let i = updated.firstIndex(where: { $0.id == id }) { updated[i] = row }
                do {
                    try ThemeFiles.save(theme, to: destination)
                    try ThemeLibrary.saveIndex(updated, at: index)
                } catch {
                    try? original.write(to: destination, options: .atomic)
                    try? originalIndex.write(to: index, options: .atomic)
                    throw error
                }
                return row
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                switch result {
                case .success(let row):
                    if let i = self.library.firstIndex(where: { $0.id == id }) { self.library[i] = row }
                    self.saveStatus = L("已保存在本机")
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func importFrames(append: Bool) {
        guard !editingActiveTheme else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .data]; panel.allowsMultipleSelection = true
        panel.message = L("选择 PNG 帧序列、GIF、CUR 或 ANI；多文件按文件名排序。")
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
}
