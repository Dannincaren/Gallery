import AppKit
import SwiftUI
import GalleryCore
import UniformTypeIdentifiers

extension UTType {
    static let galleryThemeOrder = UTType(exportedAs: "io.github.rp0902.gallery.theme-order", conformingTo: .data)
}

/// SwiftUI associates the drag with the card that was actually hit. No
/// independently measured AppKit rectangles or per-card mouse monitors.
struct ThemeOrderSource: ViewModifier {
    let enabled: Bool
    let theme: LibraryTheme
    let began: (String) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                let id = theme.id
                began(id)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.galleryThemeOrder.identifier, visibility: .ownProcess) { completion in
                    completion(Data(id.utf8), nil); return nil
                }
                return provider
            } preview: { ThemeOrderPreview(theme: theme) }
        } else { content }
    }
}

private struct ThemeOrderPreview: View {
    let theme: LibraryTheme
    var body: some View {
        HStack(spacing: 8) {
            if let data = theme.cover, let image = EditorImageCache.image(data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
            }
            Text(theme.name.count > 6 ? String(theme.name.prefix(6)) + "…" : theme.name)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }.fixedSize().padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor struct ThemeOrderDropDelegate: DropDelegate {
    let targetID: String, enabled: Bool
    let store: GalleryStore
    @Binding var draggingID: String?
    @Binding var order: [String]?
    @Binding var lastMovePoint: CGPoint?
    @Binding var lastMoveTime: Double
    let finished: () -> Void
    func validateDrop(info: DropInfo) -> Bool {
        enabled && draggingID != nil && info.hasItemsConforming(to: [.galleryThemeOrder])
    }
    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), let sourceID = draggingID, sourceID != targetID,
              var ids = order, let from = ids.firstIndex(of: sourceID), let to = ids.firstIndex(of: targetID) else { return }
        let point = NSEvent.mouseLocation, now = ProcessInfo.processInfo.systemUptime
        // Reflow can generate enter/exit events without physical mouse motion,
        // especially across a row boundary. Don't let those undo the move.
        if let previous = lastMovePoint {
            guard hypot(point.x - previous.x, point.y - previous.y) >= 5,
                  now - lastMoveTime >= 0.18 else { return }
        }
        lastMovePoint = point; lastMoveTime = now
        let moved = ids.remove(at: from); ids.insert(moved, at: to)
        withAnimation(.easeOut(duration: 0.16)) { order = ids }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { validateDrop(info: info) ? DropProposal(operation: .move) : nil }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let sourceID = draggingID, let order,
              let destination = order.firstIndex(of: sourceID) else { return false }
        store.moveTheme(sourceID, to: destination); finished(); return true
    }
}
