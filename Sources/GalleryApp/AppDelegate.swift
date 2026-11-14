import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: GalleryStore? {
        didSet {
            guard let store else { return }
            // SwiftUI can attach its state before or after the launch callback.
            // Neither path depends on the editor window being created.
            // Preserve document-open priority while an import is in progress.
            if let pendingURL { self.pendingURL = nil; store.importURL(pendingURL) }
            if finishedLaunching { store.handleLaunch() }
        }
    }
    private var finishedLaunching = false
    private var pendingURL: URL?
    private var pendingTermination: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        store?.handleLaunch()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let store { store.importURL(url) } else { pendingURL = url }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let store, store.importing {
            pendingTermination = store.$importing.filter { !$0 }.first().receive(on: DispatchQueue.main).sink { [weak self, weak store] _ in
                MainActor.assumeIsolated {
                    store?.saveNow(wait: true)
                    let restored = store?.runtime.stop() != false
                    self?.pendingTermination = nil
                    sender.reply(toApplicationShouldTerminate: restored)
                }
            }
            return .terminateLater
        }
        store?.saveNow(wait: true)
        guard store?.runtime.stop() != false else { return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        store?.refreshDockVisibility()
        return true
    }
}
