import GalleryCore
import SwiftUI
import CoreText

/// Fonts are registered only for this process, once per application launch.
enum GalleryWordmark {
    private static let registration: Void = {
        var roots = [Bundle.main.resourceURL?.appendingPathComponent("Fonts")].compactMap { $0 }
        #if DEBUG
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        #endif
        for root in roots {
            for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static let font: Font = { registration; return .custom("UnifrakturMaguntia", size: 43.6034597472) }()
    private static let engraved = sidebarFont("UnifrakturMaguntia")
    private static let blackletter = sidebarFont("UnifrakturCook-Bold")
    private static let sharp = sidebarFont("PirataOne-Regular")
    static func sidebar(_ style: SidebarWordmarkStyle) -> Font {
        switch style { case .engraved: return engraved; case .blackletter: return blackletter; case .sharp: return sharp }
    }
    private static func sidebarFont(_ name: String) -> Font {
        registration
        let face = CTFontCreateWithName(name as CFString, 100, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "gallery", attributes: [.font: face]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return .custom(name, size: 25 / max(1, bounds.height) * 100)
    }
}

enum SidebarWordmarkStyle: String, CaseIterable, Identifiable {
    case engraved, blackletter, sharp
    var id: String { rawValue }
    var label: String {
        switch self { case .engraved: return L("A · 细刻哥特"); case .blackletter: return L("B · 厚重黑字"); case .sharp: return L("C · 锐角哥特") }
    }
}
private struct SidebarWordmarkStyleKey: EnvironmentKey {
    static let defaultValue = SidebarWordmarkStyle.engraved
}
extension EnvironmentValues {
    var sidebarWordmarkStyle: SidebarWordmarkStyle {
        get { self[SidebarWordmarkStyleKey.self] }
        set { self[SidebarWordmarkStyleKey.self] = newValue }
    }
}
struct SidebarGalleryWordmark: View {
    @Environment(\.sidebarWordmarkStyle) private var style
    var body: some View {
        Text("gallery").font(GalleryWordmark.sidebar(style))
            .frame(height: 40, alignment: .leading).accessibilityLabel("Gallery")
    }
}

/// Standard sans-serif glyphs, with horizontal strokes rising to the right
/// while vertical stems stay upright. Cached once, with no animation clock.
enum GalleryStatusTypography {
    static let italic: Font = {
        var matrix = CGAffineTransform(a: 1, b: 0.18, c: 0, d: 1, tx: 0, ty: 0)
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 12, &matrix)
        return Font(font)
    }()
}
