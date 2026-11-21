import Combine

/// Phase/role labels have their own publisher. A click or role change should
/// update one text label rather than invalidate the editor, gallery and menu.
@MainActor
final class RuntimeStatus: ObservableObject {
    @Published private(set) var text: String
    init(_ text: String) { self.text = text }
    func set(_ text: String) { if self.text != text { self.text = text } }
}
