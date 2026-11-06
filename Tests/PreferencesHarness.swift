import Foundation
import GalleryCore

@main @MainActor
struct PreferencesHarness {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw ThemeError.invalid(message) }
        }
        if CommandLine.arguments.count > 1 {
            try check(GalleryLocalization.isEnglish == (CommandLine.arguments[1] == "en"), "Saved language was not applied after reopening")
            print("PASS reopened " + L("导入主题"))
            return
        }
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain == "io.github.gallery.preferences-check")
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain); defaults.synchronize() }
        let systemLanguages = defaults.object(forKey: "AppleLanguages") as? [String]
        let launchTitle = L("导入主题")
        let preferences = AppPreferences()
        try check(preferences.interfaceLanguage == .system, "System languages were mistaken for a manual override")
        preferences.applyAtLaunch = true
        preferences.shakeToLocate = true

        func reopen(_ language: String) throws {
            try check(defaults.synchronize(), "Could not persist the isolated test preferences")
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = [language]
            try child.run(); child.waitUntilExit()
            try check(child.terminationStatus == 0, "Language relaunch failed")
        }
        preferences.setInterfaceLanguage(.english)
        try check(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["en"], "English preference was not persisted")
        try check(AppPreferences().interfaceLanguage == .english, "English preference was not restored")
        try check(L("导入主题") == launchTitle, "Language changed halfway through a session")
        try reopen("en")
        preferences.setInterfaceLanguage(.simplifiedChinese)
        try check(AppPreferences().interfaceLanguage == .simplifiedChinese, "Chinese preference was not restored")
        try reopen("zh-Hans")
        preferences.setInterfaceLanguage(.system)
        try check(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil, "Follow System did not clear the override")
        try check(defaults.object(forKey: "AppleLanguages") as? [String] == systemLanguages, "Inherited system languages were changed")
        try check(AppPreferences().interfaceLanguage == .system, "Follow System was not restored")
        try check(preferences.applyAtLaunch && preferences.shakeToLocate, "Language selection changed other preferences")
        print("PASS manual language persistence, real relaunch, Follow System and unchanged session/preferences")
    }
}
