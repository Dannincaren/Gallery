import AppKit
import SwiftUI
import GalleryCore

/// A menu-bar-only SwiftUI application, with the production delegate and store.
/// No editor scene exists, so a window-dependent bootstrap cannot pass.
@main @MainActor struct StartupHarness: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: GalleryStore

    init() {
        precondition(Bundle.main.bundleIdentifier == "io.github.gallery.startup-check")
        let args = CommandLine.arguments
        let scenario = args[1], root = URL(fileURLWithPath: args[2])
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        let fixture = try! Self.prepare(root)
        defaults.set(fixture.current, forKey: "currentThemeID")
        defaults.set(scenario == "missing-last" ? UUID().uuidString : fixture.last, forKey: "lastAppliedThemeID")
        defaults.set(scenario != "no-auto", forKey: "applyAtLaunch")
        defaults.set(scenario != "keep-dock", forKey: "hideDockIconWhileRunning")
        defaults.set(true, forKey: "shakeToLocate")
        let runtime = CursorRuntime(); runtime.hasRecovery = scenario == "recovery"
        let store = GalleryStore(rootURL: root, runtime: runtime, manageApplicationLifecycle: true)
        _store = StateObject(wrappedValue: store)
        // Match the production App initializer, including early delegate access.
        let bridge = delegate
        if scenario == "pending-document" {
            var incoming = try! ThemeFiles.load(root.appendingPathComponent("Themes/\(fixture.current).gallery"))
            incoming.name = "Imported at launch"
            let url = root.appendingPathComponent("pending.gallery"); try! ThemeFiles.save(incoming, to: url)
            bridge.application(NSApplication.shared, open: [url])
        } else if scenario != "late-binding" { bridge.store = store }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task { @MainActor in
                do {
                    for _ in 0..<80 {
                        if NSApp.isRunning { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    try Self.check(NSApp.isRunning, "Application did not finish launching")
                    if scenario == "late-binding" || scenario == "pending-document" { bridge.store = store }
                    let applies = !["no-auto", "recovery", "pending-document"].contains(scenario)
                    let expectedID = scenario == "missing-last" ? fixture.current : fixture.last
                    let expectedName = scenario == "missing-last" ? "Browsing" : "Previously active"
                    let hidden = applies && scenario != "keep-dock"
                    let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
                    for _ in 0..<100 {
                        if !store.importing && runtime.enabled == applies && NSApp.activationPolicy() == policy { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    try Self.check(!store.importing && runtime.enabled == applies, "Automatic application did not run without an editor window")
                    try Self.check(runtime.starts == (applies ? [expectedName] : []), "Wrong or duplicate startup theme")
                    try Self.check(!applies || store.activeThemeID == expectedID, "Previously active theme was not restored")
                    try Self.check(runtime.shakeEnabled, "Startup observers were not configured")
                    if scenario == "pending-document" {
                        try Self.check(store.theme.name == "Imported at launch" && store.library.count == 3, "Startup dropped the pending document")
                    }
                    try Self.check(NSApp.activationPolicy() == policy && store.preferences.dockIconHidden == hidden, "Dock visibility was not initialized without a window")
                    try Self.check(!NSApp.windows.contains { $0.canBecomeMain }, "An editor window appeared in a windowless startup check")
                    // Reopening or receiving duplicate lifecycle callbacks must
                    // not reapply a theme or lose the requested Dock policy.
                    bridge.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                    bridge.store = store
                    store.handleLaunch()
                    _ = bridge.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try Self.check(runtime.starts == (applies ? [expectedName] : []), "Reopening restarted automatic application")
                    try Self.check(NSApp.activationPolicy() == policy, "Reopening changed Dock visibility")
                    let result: [String: Any] = ["scenario": scenario, "starts": runtime.starts, "dockHidden": hidden,
                        "editorWindows": NSApp.windows.filter { $0.canBecomeMain }.count, "passed": true]
                    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("startup-result.json"))
                    print("PASS windowless \(scenario): starts=\(runtime.starts.count), Dock hidden=\(hidden), no duplicate initialization")
                    try Self.check(bridge.applicationShouldTerminate(NSApp) == .terminateNow && !runtime.enabled, "Normal termination failed")
                    bridge.store = nil
                    defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!); defaults.synchronize()
                    NSApp.terminate(nil)
                } catch {
                    bridge.store = nil; _ = runtime.stop()
                    defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!); defaults.synchronize()
                    print("FAIL \(scenario): \(error.localizedDescription)"); exit(1)
                }
            }
        }
    }
    var body: some Scene {
        MenuBarExtra("Gallery startup check", systemImage: "gearshape") { Text(store.runtime.status) }
    }
    private static func check(_ value: Bool, _ reason: String) throws {
        if !value { throw ThemeError.invalid(reason) }
    }
    private static func prepare(_ root: URL) throws -> (current: String, last: String) {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Themes"), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let clip = CursorClip(frames: [try CursorImages.png(context.makeImage()!)])
        let role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": clip])
        let themes = ["Browsing", "Previously active"].map { GalleryTheme(name: $0, roles: [role]) }
        let rows = themes.map { ThemeLibrary.thumbnails(id: UUID().uuidString, theme: $0, previous: nil) }
        for (theme, row) in zip(themes, rows) { try ThemeFiles.save(theme, to: root.appendingPathComponent("Themes/\(row.id).gallery")) }
        try ThemeLibrary.saveIndex(rows, at: root.appendingPathComponent("themes.json"))
        return (rows[0].id, rows[1].id)
    }
}
