import Combine
import GalleryCore

// Observe startup decisions without linking the native cursor bridge or
// registering resources in the user's WindowServer session.
@MainActor final class CursorRuntime: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Isolated startup check"
    @Published var error: String?
    var hasRecovery = false
    private(set) var starts: [String] = []
    private(set) var shakeEnabled = false
    var diagnostics: String { status }
    func start(_ theme: GalleryTheme) { starts.append(theme.name); enabled = true }
    @discardableResult func stop() -> Bool { enabled = false; return true }
    func recover() {}
    func requestInputAccess() {}
    func setShakeEnabled(_ value: Bool) { shakeEnabled = value }
    func setScale(_ value: Double) {}
    func setRoleScale(_ value: Double, for identifier: String) {}
    func setRoleIdleDelay(_ value: Double?, for identifier: String) {}
}
