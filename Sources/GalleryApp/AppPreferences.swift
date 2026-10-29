import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppPreferences: ObservableObject {
    @Published var applyAtLaunch: Bool {
        didSet { UserDefaults.standard.set(applyAtLaunch, forKey: "applyAtLaunch") }
    }
    @Published var hideDockIconWhileRunning: Bool {
        didSet { UserDefaults.standard.set(hideDockIconWhileRunning, forKey: "hideDockIconWhileRunning") }
    }
    @Published var shakeToLocate: Bool {
        didSet { UserDefaults.standard.set(shakeToLocate, forKey: "shakeToLocate") }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var needsApproval = false
    @Published private(set) var dockIconHidden = false
    @Published var error: String?
    init() {
        applyAtLaunch = UserDefaults.standard.bool(forKey: "applyAtLaunch")
        hideDockIconWhileRunning = UserDefaults.standard.bool(forKey: "hideDockIconWhileRunning")
        shakeToLocate = UserDefaults.standard.bool(forKey: "shakeToLocate")
        refreshLoginStatus()
    }
    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        needsApproval = status == .requiresApproval
    }
    func recordDockVisibility(hidden: Bool) { if dockIconHidden != hidden { dockIconHidden = hidden } }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            self.error = "未能更改开机自启动。请将 Gallery 放入「应用程序」后再试。\n\(error.localizedDescription)"
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
