import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppPreferences: ObservableObject {
    @Published var pointerScale: Double {
        didSet { UserDefaults.standard.set(pointerScale, forKey: "pointerScale") }
    }
    @Published var applyAtLaunch: Bool {
        didSet { UserDefaults.standard.set(applyAtLaunch, forKey: "applyAtLaunch") }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var needsApproval = false
    @Published var error: String?
    init() {
        let saved = UserDefaults.standard.double(forKey: "pointerScale")
        pointerScale = saved.isFinite && (0.5...3).contains(saved) ? saved : 1
        applyAtLaunch = UserDefaults.standard.bool(forKey: "applyAtLaunch")
        refreshLoginStatus()
    }
    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        needsApproval = status == .requiresApproval
    }
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
