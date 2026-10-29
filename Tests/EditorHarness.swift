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
    static func checkThemeSizes(at root: URL, role: CursorRole) throws {
        let themes = root.appendingPathComponent("Themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let a = GalleryTheme(name: "A", roles: [role]), b = GalleryTheme(name: "B", roles: [role])
        let rows = [LibraryTheme(theme: a), LibraryTheme(theme: b)]
        func legacyFile(_ theme: GalleryTheme, at url: URL) throws {
            try ThemeFiles.save(theme, to: url)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            json.removeValue(forKey: "pointerScale")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        for (theme, row) in zip([a, b], rows) { try legacyFile(theme, at: themes.appendingPathComponent(row.id + ".gallery")) }
        try ThemeLibrary.saveIndex(rows, at: root.appendingPathComponent("themes.json"))
        let store = GalleryStore(rootURL: root, legacyPointerScale: 1.86); store.saveNow(wait: true)
        try verify(store.theme.pointerScale == 1.86, "旧全局大小未初始化当前主题")
        store.setThemeScale(1.4); store.saveNow(wait: true)
        store.selectTheme(rows[1].id); try waitFor(store)
        try verify(store.theme.pointerScale == 1.86, "未打开旧主题的初始大小随其他主题改变")
        store.setThemeScale(0.8); store.saveNow(wait: true)
        store.selectTheme(rows[0].id); try waitFor(store)
        try verify(store.theme.pointerScale == 1.4 && store.theme.roles == a.roles, "切换主题丢失整体大小或改变了角色素材")
        store.setThemeScale(1); store.saveNow(wait: true)
        store.selectTheme(rows[1].id); try waitFor(store)
        store.setThemeScale(.nan)
        try verify(store.theme.pointerScale == 0.8, "还原或非法值改变了另一主题的大小")
        let oldImport = root.appendingPathComponent("external.gallery")
        try legacyFile(a, at: oldImport)
        store.importURL(oldImport); try waitFor(store); store.saveNow(wait: true)
        try verify(store.theme.pointerScale == 1, "新导入的无大小主题继承了旧全局大小")
        store.setThemeScale(2.3); store.saveNow(wait: true)
        let importedID = store.selectedThemeID
        let reopened = GalleryStore(rootURL: root, legacyPointerScale: 2.9); reopened.saveNow(wait: true)
        for (id, value) in [(rows[0].id, 1.0), (rows[1].id, 0.8), (importedID, 2.3)] {
            reopened.selectTheme(id); try waitFor(reopened)
            try verify(reopened.theme.pointerScale == value, "重新打开主题后大小未独立保存")
        }
        print("PASS independent theme size, reset, legacy migration and external import")
    }
    static func checkThemeOrder(at root: URL, role: CursorRole) throws {
        let folder = root.appendingPathComponent("Themes"), index = root.appendingPathComponent("themes.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let themes = ["A", "B", "C"].map { GalleryTheme(name: $0, roles: [role]) }
        let rows = themes.map { LibraryTheme(theme: $0) }, ids = rows.map(\.id)
        for (theme, row) in zip(themes, rows) { try ThemeFiles.save(theme, to: folder.appendingPathComponent(row.id + ".gallery")) }
        try ThemeLibrary.saveIndex(rows, at: index)
        let store = GalleryStore(rootURL: root); store.saveNow(wait: true)
        let selected = store.selectedThemeID, original = store.theme
        let originalFiles = try ids.map { try Data(contentsOf: folder.appendingPathComponent($0 + ".gallery")) }
        func persisted(_ order: [String]) throws {
            let until = Date().addingTimeInterval(5)
            while (try? ThemeLibrary.loadIndex(at: index).map(\.id)) != order && Date() < until {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            try verify(try ThemeLibrary.loadIndex(at: index).map(\.id) == order, "主题顺序未落盘或被旧保存覆盖")
        }
        store.moveTheme(ids[0], to: 2); try persisted([ids[1], ids[2], ids[0]])
        store.moveTheme(ids[0], to: 0); store.moveTheme(ids[2], to: 1)
        let expected = [ids[0], ids[2], ids[1]]
        try persisted(expected)
        store.reorderThemes([ids[1], ids[0], ids[2]]); try persisted([ids[1], ids[0], ids[2]])
        store.reorderThemes(expected); try persisted(expected)
        store.reorderThemes([ids[0], ids[0], ids[1]])
        store.reorderThemes(Array(expected.dropLast()))
        store.reorderThemes(expected + [UUID().uuidString])
        store.moveTheme("missing", to: 0); store.moveTheme(ids[1], to: -1); store.moveTheme(ids[1], to: 3)
        try verify(store.library.map(\.id) == expected && store.selectedThemeID == selected && store.theme == original && !store.runtime.enabled,
            "排序改变了浏览主题、动画、运行状态或接受了无效目标")
        let savedFiles = try ids.map { try Data(contentsOf: folder.appendingPathComponent($0 + ".gallery")) }
        try verify(savedFiles == originalFiles, "排序重写了主题素材归档")
        store.setThemeCover(at: 1); store.saveNow(wait: true)
        try verify(store.theme.coverFrame == role.clip(.normal)!.frames[1] && store.theme.roles == original.roles,
            "当前帧封面修改了动画或选错图像")
        let coverSaved = try ThemeFiles.load(folder.appendingPathComponent(selected + ".gallery"))
        try verify(coverSaved.coverFrame == store.theme.coverFrame && store.library.first(where: { $0.id == selected })?.cover != nil,
            "自定义封面未随主题或目录持久化")
        store.setThemeCover(at: -1); try verify(store.theme.coverFrame == coverSaved.coverFrame, "无效帧清除了封面")
        store.resetThemeCover(); store.saveNow(wait: true)
        try verify(try ThemeFiles.load(folder.appendingPathComponent(selected + ".gallery")).coverFrame == nil, "恢复默认封面未保存")
        // A delayed editor save and thumbnail callbacks must retain new order.
        store.theme.name = "Edited A"; store.changed()
        store.moveTheme(ids[0], to: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let latest = [ids[2], ids[1], ids[0]]; try persisted(latest)
        try verify(try ThemeFiles.load(folder.appendingPathComponent(selected + ".gallery")).name == "Edited A", "排序丢失待保存的主题编辑")
        let reopened = GalleryStore(rootURL: root); reopened.saveNow(wait: true)
        try verify(reopened.library.map(\.id) == latest, "重新打开后主题顺序丢失")
        let imported = root.appendingPathComponent("D.gallery")
        try ThemeFiles.save(GalleryTheme(name: "D", roles: [role]), to: imported)
        reopened.importURL(imported); try waitFor(reopened); reopened.saveNow(wait: true)
        try verify(Array(reopened.library.map(\.id).prefix(3)) == latest && reopened.library.last?.name == "D", "导入打乱了自定义顺序")
        let prior = reopened.library.map(\.id), backup = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index); try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        reopened.message = nil
        reopened.moveTheme(prior[0], to: prior.count - 1)
        let until = Date().addingTimeInterval(5)
        while reopened.message == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try verify(reopened.message?.hasPrefix("主题顺序保存失败") == true && reopened.library.map(\.id) == prior, "排序写入失败未提示或丢失目录顺序")
        try FileManager.default.removeItem(at: index); try backup.write(to: index)
        print("PASS theme reorder, restart, archive isolation, queued saves, import append and write-failure rollback")
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
            try checkThemeSizes(at: root.appendingPathComponent("SizeIsolation"), role: first)
            try checkThemeOrder(at: root.appendingPathComponent("ThemeOrdering"), role: first)
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
