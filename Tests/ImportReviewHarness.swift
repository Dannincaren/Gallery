import AppKit
import GalleryCore

/// Exercises review/cancel and the batch transaction without enabling a cursor
/// or writing the user's library or defaults.
@main @MainActor
struct ImportReviewHarness {
    static func verify(_ value: Bool, _ reason: String) throws {
        if !value { throw ThemeError.invalid(reason) }
    }
    static func pump(_ seconds: Double = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func wait(_ store: GalleryStore) throws {
        let until = Date().addingTimeInterval(10)
        while store.importing && Date() < until { pump() }
        try verify(!store.importing, "导入操作超时")
    }
    static func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Themes"), includingPropertiesForKeys: nil) {
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
        for name in ["themes.json", "current.gallery"] { result[name] = try Data(contentsOf: root.appendingPathComponent(name)) }
        return result
    }
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = GalleryStore(rootURL: root)
        store.saveNow(wait: true); pump()
        var theme = Demo.makeTheme(); theme.name = "Reviewed"
        let still = theme.roles[0].clip(.normal)!
        var loop = still; loop.frames = [still.frames[0], theme.roles[0].clip(.press)!.frames[0]]
        theme.roles[0].variants["normal"] = [CursorVariant(id: "still", name: "Static", clip: still), CursorVariant(id: "loop", name: "Animated", clip: loop)]
        theme.roles[0].selectedVariants["normal"] = "still"
        let external = root.appendingPathComponent("Alternatives.gallery")
        try ThemeFiles.save(theme, to: external)
        let original = try snapshot(root), rows = store.library
        store.importURL(external); try wait(store)
        try verify(store.importReview?.themes.count == 1 && store.library == rows, "多素材 Gallery 文件未先询问选择")
        try verify(try snapshot(root) == original, "尚未确认就写入主题库")
        store.cancelImportReview(); pump()
        try verify(store.importReview == nil && (try snapshot(root)) == original, "取消导入仍改动文件")
        print("PASS alternatives prompt and cancellation leave library unchanged")
        store.importURL(external); try wait(store)
        let selected = try ImportSelection.keeping([ImportSelection.key(role: theme.roles[0].id, motion: .normal): ["loop"]], in: store.importReview!.themes[0])
        store.confirmImportReview([selected, selected]); try wait(store)
        try verify(store.library.count == rows.count + 2 && store.importReview == nil, "所选套装未分别保存")
        try verify(Array(store.library.suffix(2).map(\.name)) == ["Reviewed", "Reviewed (2)"], "批量重名主题未区分")
        let latest = try ThemeFiles.load(root.appendingPathComponent("Themes/" + store.selectedThemeID + ".gallery"))
        try verify(latest.roles[0].variants["normal"]?.count == 1 && latest.roles[0].selectedVariants["normal"] == "loop", "未保留用户勾选素材")
        try verify(!store.runtime.enabled, "导入意外启用系统光标")
        print("PASS selected themes and materials saved separately with unique names")
        store.saveNow(wait: true); pump()
        let saved = try snapshot(root), savedRows = store.library, current = store.theme
        let invalid = GalleryTheme(name: "Broken", roles: [])
        store.confirmImportReview([selected, invalid]); try wait(store)
        try verify(store.library == savedRows && store.theme == current, "失败批次修改了当前主题")
        try verify(try snapshot(root) == saved, "第二套保存失败后遗留了部分主题或更改索引")
        print("PASS failed second theme rolls back archives, index and current theme")
    }
}
