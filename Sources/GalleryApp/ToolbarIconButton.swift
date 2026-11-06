import AppKit
import SwiftUI

/// A toolbar group must not share its first child's help text. Native buttons
/// own their tooltip rectangles, including when the leading slot is collapsed.
struct ToolbarIconButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let tooltip: String?
    let identifier: String
    var enabled = true
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        var symbol: String?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(), target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.setButtonType(.momentaryPushIn)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        if context.coordinator.symbol != symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            context.coordinator.symbol = symbol
        }
        button.isEnabled = enabled
        button.toolTip = tooltip
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(tooltip)
        button.setAccessibilityIdentifier(identifier)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 34, height: 30)
    }
}
