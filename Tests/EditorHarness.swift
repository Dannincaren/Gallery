import AppKit
import GalleryCore

@main @MainActor
struct EditorHarness {
    static func verify(_ value: Bool, _ reason: String) throws {
        if !value { throw ThemeError.invalid(reason) }
    }
    static func waitFor(_ store: GalleryStore) throws {
        let end = Date().addingTimeInterval(10)
        while store.importing && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try verify(!store.importing, "目录操作超时")
    }
    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
                NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); return true
            }
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            let clip = CursorClip(frames: [png, png])
            let first = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": clip])
            let legacy = GalleryTheme(name: "Legacy", roles: [first])
            try ThemeFiles.save(legacy, to: root.appendingPathComponent("current.gallery"))
            let store = GalleryStore(rootURL: root); store.saveNow(wait: true)
            try verify(store.library.count == 1 && store.theme == legacy, "旧主题迁移失败")
            let firstID = store.selectedThemeID
            try verify(store.duplicateFrame(at: 0) == 1 && store.clip?.frames.count == 3, "编辑器复制帧失败")
            store.saveNow(wait: true)
            print("PASS legacy migration and duplicate-frame persistence")
            var other = legacy; other.name = "Other theme"
            let source = root.appendingPathComponent("source.gallery"); try ThemeFiles.save(other, to: source)
            store.importURL(source); try waitFor(store); store.saveNow(wait: true)
            try verify(store.library.count == 2 && store.selectedThemeID != firstID, "导入未创建独立目录")
            let secondID = store.selectedThemeID
            store.selectTheme(firstID, role: first.id); try waitFor(store)
            try verify(store.clip?.frames.count == 3 && store.library.count == 2, "切换目录丢失编辑")
            print("PASS import and switch preserve both theme folders")
            store.setRoleScale(1.4); store.setUsesNative(true); store.saveNow(wait: true)
            let reopened = GalleryStore(rootURL: root); reopened.saveNow(wait: true)
            try verify(reopened.theme.roles[0].scale == 1.4 && reopened.theme.roles[0].usesNative, "单角色设置未保存")
            var sourceTheme: GalleryTheme?
            reopened.loadLibraryTheme(secondID) { result in sourceTheme = try? result.get() }
            let end = Date().addingTimeInterval(5)
            while sourceTheme == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            guard let sourceTheme else { throw ThemeError.invalid("无法读取来源目录") }
            reopened.useTemplate(sourceTheme.roles[0], sourceName: sourceTheme.name); reopened.saveNow(wait: true)
            try verify(!reopened.theme.roles[0].usesNative && reopened.theme.roles[0].scale == 1.4, "替换来源未保留目标大小")
            let selectedURL = root.appendingPathComponent("Themes/" + firstID + ".gallery")
            let saved = try ThemeFiles.load(selectedURL)
            try verify(saved.roles[0].sourceThemeName == sourceTheme.name && saved.roles[0].clips == sourceTheme.roles[0].clips, "来源素材没有独立保存")
            print("PASS role size, native mode and self-contained mixed role")
            print("Editor checks passed; no user library or login settings changed")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
