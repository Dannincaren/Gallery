import GalleryCore
import AppKit
import Combine
import ServiceManagement

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published private(set) var interfaceLanguage: InterfaceLanguage
    @Published var applyAtLaunch: Bool {
        didSet { defaults.set(applyAtLaunch, forKey: "applyAtLaunch") }
    }
    @Published var hideDockIconWhileRunning: Bool {
        didSet { defaults.set(hideDockIconWhileRunning, forKey: "hideDockIconWhileRunning") }
    }
    @Published var shakeToLocate: Bool {
        didSet { defaults.set(shakeToLocate, forKey: "shakeToLocate") }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var needsApproval = false
    @Published private(set) var dockIconHidden = false
    @Published var error: String?
    init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        let languages = domain.flatMap { defaults.persistentDomain(forName: $0)?["AppleLanguages"] as? [String] }
        if let language = languages?.first, language.hasPrefix("zh") { interfaceLanguage = .simplifiedChinese }
        else if let language = languages?.first, language.hasPrefix("en") { interfaceLanguage = .english }
        else { interfaceLanguage = .system }
        applyAtLaunch = defaults.bool(forKey: "applyAtLaunch")
        hideDockIconWhileRunning = defaults.bool(forKey: "hideDockIconWhileRunning")
        shakeToLocate = defaults.bool(forKey: "shakeToLocate")
        refreshLoginStatus()
    }
    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        guard language != interfaceLanguage else { return }
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
        interfaceLanguage = language
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
            self.error = L("未能更改开机自启动。请将 Gallery 放入「应用程序」后再试。\n\(error.localizedDescription)")
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
