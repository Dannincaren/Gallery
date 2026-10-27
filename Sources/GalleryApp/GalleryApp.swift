import SwiftUI
import GalleryNative
import GalleryCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: GalleryStore? { didSet { if let pendingURL { self.pendingURL = nil; store?.importURL(pendingURL) } } }
    private var pendingURL: URL?
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let store { store.importURL(url) } else { pendingURL = url }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.saveNow()
        guard store?.runtime.stop() != false else { return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct GalleryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: GalleryStore
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--convert-prts"), CommandLine.arguments.count > index + 2 {
            do {
                let theme = try PRTSImport.load(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                try ThemeFiles.save(theme, to: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                print("Converted \(theme.roles.count) system variants / \(Set(theme.roles.map(\.name)).count) categories")
                exit(0)
            } catch { print(error.localizedDescription); exit(2) }
        }
        if CommandLine.arguments.contains("--self-check") {
            print("Gallery native capabilities: \(GLCursorBridge.diagnostics())")
            for id in ["com.apple.coregraphics.Arrow", "com.apple.cursor.19", "com.apple.cursor.23"] {
                if let c = GLCursorBridge.standardCursor(id) { print(id, "core=", c["CoreCursorType"] ?? "?", "size=", c["PointsWide"] ?? "?") }
            }
            print("No cursor resources were changed.")
            exit(GLCursorBridge.available() ? 0 : 2)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--native-roundtrip"), CommandLine.arguments.count > index + 1 {
            // Explicit developer check: re-register an identical arrow, then
            // restore the exact original dictionary. Write a recovery copy first.
            let id = "com.apple.coregraphics.Arrow"
            guard let original = GLCursorBridge.readCursor(id) else { print("Cannot read original arrow"); exit(2) }
            do {
                let backup = try PropertyListSerialization.data(fromPropertyList: [id: original], format: .binary, options: 0)
                try backup.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
                _ = try CursorImages.fromCape(original)
                let applied = GLCursorBridge.registerCursor(original, identifier: id)
                let readable = GLCursorBridge.readCursor(id) != nil
                let restored = GLCursorBridge.registerCursor(original, identifier: id)
                print("Native identical-arrow roundtrip: register=\(applied) readable=\(readable) restore=\(restored)")
                exit(applied == 0 && readable && restored == 0 ? 0 : 2)
            } catch { print(error); exit(2) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.appearance = NSAppearance(named: .aqua)
            let store = GalleryStore(preview: true)
            if CommandLine.arguments.count > index + 2,
               let theme = try? ThemeFiles.load(URL(fileURLWithPath: CommandLine.arguments[index + 2])) {
                store.theme = theme; store.selectedRole = theme.roles[0].id
            }
            let host = NSHostingView(rootView: GalleryEditor(store: store).frame(width: 1120, height: 780).environment(\.colorScheme, .light))
            host.frame = NSRect(x: 0, y: 0, width: 1120, height: 780)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
                    catch { print(error); exit(1) }
                }
            }
            exit(1)
        }
        _store = StateObject(wrappedValue: GalleryStore())
    }
    var body: some Scene {
        Window("Gallery", id: "editor") {
            GalleryEditor(store: store).onAppear { delegate.store = store }
        }.defaultSize(width: 1120, height: 780)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("导入主题…") { store.openTheme() }.keyboardShortcut("o")
                    Button("导出主题…") { store.exportTheme() }.keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
        MenuBarExtra("Gallery", systemImage: "cursorarrow.rays") {
            MenuContents(store: store, runtime: store.runtime)
        }
    }
}

private struct MenuContents: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(runtime.status)
        Button("打开 Gallery") { openWindow(id: "editor"); NSApp.activate(ignoringOtherApps: true) }
        Button(runtime.enabled ? "停用并恢复光标" : "应用当前主题") {
            if runtime.enabled { runtime.stop() } else { runtime.start(store.theme) }
        }
        if runtime.hasRecovery && !runtime.enabled { Button("恢复上次光标") { runtime.recover() } }
        Divider()
        Button("退出 Gallery") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
