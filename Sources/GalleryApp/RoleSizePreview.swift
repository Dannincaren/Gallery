import SwiftUI
import GalleryCore

/// A still at the effective cursor size. The magnified hotspot editor is kept
/// independent so size changes remain visible without playing an animation.
struct RoleSizePreview: View {
    let clip: CursorClip?
    let scale: Double
    let appearance: CursorAppearance
    @State private var rendered: CursorClip?
    private struct Input: Equatable { let clip: CursorClip?; let appearance: CursorAppearance }
    private var source: CursorClip? {
        guard var clip, let first = clip.frames.first else { return nil }
        clip.frames = [first]; return clip
    }
    var body: some View {
        let display = (rendered ?? source)?.scaled(by: scale)
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.25))
                if let display, let data = display.frames.first, let image = EditorImageCache.image(data) {
                    Image(nsImage: image).resizable().interpolation(appearance.smoothEdges ? .high : .none)
                        .frame(width: display.width, height: display.height)
                }
            }.frame(width: 136, height: 136)
            if let display { Text(L("\(Int(display.width.rounded())) × \(Int(display.height.rounded())) 点")).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .task(id: Input(clip: source, appearance: appearance)) {
            let source = source, appearance = appearance
            let result = await Task.detached(priority: .utility) {
                guard let source else { return Optional<CursorClip>.none }
                return autoreleasepool {
                    var renderer = CursorAppearanceRenderer(appearance)
                    return try? renderer.render(source)
                }
            }.value
            if !Task.isCancelled { rendered = result }
        }
        .accessibilityLabel(L("实际大小预览"))
    }
}
