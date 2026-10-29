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
            let cached = try ThemeLibrary.loadIndex(at: root.appendingPathComponent("themes.json"))
            try verify(cached[0].roles[0].thumbnail != nil, "角色缩略图未保存")
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
            try verify(reopened.library[0].roles[0].thumbnail != nil, "重新打开后缩略图丢失")
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
            let roleIDs = ["com.apple.coregraphics.Arrow", "com.apple.cursor.13", "com.apple.cursor.19", "com.apple.cursor.23", "com.apple.cursor.17"]
            reopened.theme = GalleryTheme(name: "Same names", roles: roleIDs.map { CursorRole(id: $0, name: "Cursor", clips: ["normal": clip]) })
            reopened.selectedRole = roleIDs[0]
            reopened.setRoleScale(1.7, for: roleIDs[2])
            try verify(reopened.theme.roles.map(\.scale) == [1, 1, 1.7, 1, 1.7], "水平大小串到链接/垂直/正常角色")
            try verify(reopened.visibleRoles.count == 4, "重名角色被错误合并")
            reopened.saveNow(wait: true)
            let isolated = try ThemeFiles.load(selectedURL)
            try verify(isolated.roles.map(\.scale) == [1, 1, 1.7, 1, 1.7], "独立大小保存失真")
            print("PASS same-name role isolation and captured slider target")
            reopened.setRoleIdleDelay(23, for: roleIDs[2]); reopened.saveNow(wait: true)
            let idleSaved = try ThemeFiles.load(selectedURL)
            try verify(idleSaved.roles.map(\.idleDelayOverride) == [nil, nil, 23, nil, 23], "角色待机时间串到其他角色或未保存")
            reopened.setRoleIdleDelay(nil, for: roleIDs[2]); reopened.saveNow(wait: true)
            try verify(try ThemeFiles.load(selectedURL).roles.allSatisfy { $0.idleDelayOverride == nil }, "恢复全局待机默认值失败")
            print("PASS per-role idle override, alias persistence and default restoration")
            reopened.selectedRole = roleIDs[2]; reopened.selectedMotion = .normal
            var alternate = clip; alternate.frames = [png]; alternate.hotX = 4
            try reopened.addVariant(alternate, name: "静态", for: .normal)
            try verify(reopened.theme.roles[2].variants == reopened.theme.roles[4].variants, "同族初始素材的版本标识不一致")
            try verify(reopened.theme.roles[1].variants.isEmpty && reopened.theme.roles[3].variants.isEmpty, "可选素材串到其他角色")
            let oldID = reopened.theme.roles[2].variants["normal"]!.last!.id
            reopened.edit { $0.hotY = 6 }
            reopened.selectVariant(oldID, for: .normal)
            try verify(reopened.clip == clip && reopened.theme.roles[4].clip(.normal) == clip, "切回原有素材丢失或别名不同步")
            let newID = reopened.theme.roles[2].variants["normal"]!.first!.id
            reopened.selectVariant(newID, for: .normal); reopened.saveNow(wait: true)
            let variantsSaved = try ThemeFiles.load(selectedURL)
            try verify(variantsSaved.roles[2].clip(.normal)?.hotY == 6 && variantsSaved.roles[2].variants["normal"]?.count == 2, "素材切换未保留编辑或未独立保存")
            print("PASS variant switching preserves aliases, edits, other roles and portable assets")
            let beforeRename = reopened.theme, beforeRole = reopened.selectedRole
            reopened.renameTheme(secondID, to: "  Renamed collection  "); try waitFor(reopened)
            try verify(reopened.selectedThemeID == firstID && reopened.selectedRole == beforeRole && reopened.theme == beforeRename,
                "卡片重命名改变了当前浏览主题或角色")
            let renamed = try ThemeFiles.load(root.appendingPathComponent("Themes/" + secondID + ".gallery"))
            try verify(renamed.name == "Renamed collection" && reopened.library.first(where: { $0.id == secondID })?.name == renamed.name,
                "卡片重命名没有更新归档与目录")
            reopened.renameTheme(firstID, to: "Selected collection"); reopened.saveNow(wait: true)
            let renamedSelected = try ThemeFiles.load(selectedURL)
            try verify(renamedSelected.name == "Selected collection" && renamedSelected.roles == beforeRename.roles,
                "当前主题重命名丢失了角色或动画")
            try verify(reopened.library.first(where: { $0.id == firstID })?.cover != nil, "封面缓存未合并到当前主题")
            print("PASS card rename preserves browsing, clips, alternatives and cached cover")
            let trashRoot = root.appendingPathComponent("TestTrash")
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let deleting = GalleryStore(rootURL: root, trashThemeFile: { input in
                let output = trashRoot.appendingPathComponent(input.lastPathComponent)
                try FileManager.default.moveItem(at: input, to: output); return output
            })
            let selectedBefore = deleting.selectedThemeID
            let inactive = deleting.library.first { $0.id != selectedBefore }!.id
            let inactiveURL = root.appendingPathComponent("Themes/" + inactive + ".gallery")
            let inactiveBytes = try Data(contentsOf: inactiveURL)
            deleting.deleteTheme(inactive); deleting.saveNow(wait: true); try waitFor(deleting)
            try verify(deleting.library.count == 1 && deleting.selectedThemeID == selectedBefore, "删除其他主题改变了当前浏览主题")
            try verify(!FileManager.default.fileExists(atPath: inactiveURL.path) &&
                       (try Data(contentsOf: trashRoot.appendingPathComponent(inactive + ".gallery"))) == inactiveBytes, "删除没有保留完整可恢复文件")
            let remaining = GalleryStore(rootURL: root); remaining.saveNow(wait: true)
            try verify(remaining.library.count == 1 && !remaining.library.contains { $0.id == inactive }, "重新打开后被删除主题复活")
            deleting.theme.name = "Last theme edits"; deleting.changed()
            deleting.deleteTheme(selectedBefore); deleting.saveNow(wait: true); try waitFor(deleting)
            try verify(deleting.library.count == 1 && deleting.selectedThemeID != selectedBefore, "删除最后主题未回到新的内置主题")
            try verify(try ThemeFiles.load(trashRoot.appendingPathComponent(selectedBefore + ".gallery")).name == "Last theme edits", "删除前的待保存编辑丢失")
            let finalIndex = try ThemeLibrary.loadIndex(at: root.appendingPathComponent("themes.json"))
            try verify(finalIndex.map(\.id) == deleting.library.map(\.id), "延迟保存恢复了旧目录索引")
            let denied = GalleryStore(rootURL: root, trashThemeFile: { _ in throw ThemeError.invalid("测试：无法移入废纸篓") })
            let protectedID = denied.selectedThemeID
            denied.deleteTheme(protectedID); try waitFor(denied)
            try verify(denied.library == finalIndex && FileManager.default.fileExists(atPath: root.appendingPathComponent("Themes/" + protectedID + ".gallery").path), "删除失败丢失了主题或目录")
            print("PASS recoverable whole-theme deletion, pending saves, last-theme fallback and failed-trash isolation")
            print("Editor checks passed; no user library or login settings changed")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
