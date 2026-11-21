import Combine
import Foundation
import GalleryCore

struct MappingSourceFocus: Equatable { let id = UUID(); let sourceID: String }

@MainActor
final class ThemeMappingDraft: ObservableObject {
    let initial: ThemeMapping
    let importDefaults: ThemeMapping
    @Published private(set) var mapping: ThemeMapping
    @Published private(set) var canUndo = false
    @Published private(set) var focusRequest: MappingSourceFocus?
    func focus(_ sourceID: String) {
        guard mapping.sources.contains(where: { $0.id == sourceID }) else { return }
        focusRequest = MappingSourceFocus(sourceID: sourceID)
    }
    private var history: [ThemeMapping] = []
    init(theme: GalleryTheme) {
        let value = ThemeMapping.draft(for: theme); initial = value; mapping = value
        importDefaults = value.restoringImportBindings
    }
    var hasChanges: Bool { mapping != initial }
    private func replace(_ value: ThemeMapping) {
        guard value != mapping else { return }
        history.append(mapping)
        if history.count > 64 { history.removeFirst() }
        mapping = value; canUndo = true
    }
    func bind(_ choice: RoleMappingChoice?, to native: String) {
        var value = mapping; value.bindings[native] = choice; replace(value)
    }
    func undo() {
        guard let value = history.popLast() else { return }
        mapping = value; canUndo = !history.isEmpty
    }
    func restoreImportDefaults() { replace(importDefaults) }
}

/// A pending first endpoint. A successful pair consumes the selection, so two
/// cards can never remain highlighted or accidentally bind the next click.
struct MappingSelection {
    private(set) var native: String?
    private(set) var source: RoleMappingChoice?
    mutating func clear() { native = nil; source = nil }
    mutating func selectNative(_ id: String) -> RoleMappingChoice? {
        if let chosen = source { clear(); return chosen }
        if native == id { clear() } else { clear(); native = id }
        return nil
    }
    mutating func selectSource(_ choice: RoleMappingChoice) -> String? {
        if let chosen = native { clear(); return chosen }
        if source == choice { clear() } else { clear(); source = choice }
        return nil
    }
}

enum MappingSavePrompt: String, Identifiable {
    case native, unused
    var id: String { rawValue }
    static func first(for mapping: ThemeMapping) -> Self? {
        mapping.bindings.count < ThemeMapping.nativeRoles.count ? .native : afterNative(for: mapping)
    }
    static func afterNative(for mapping: ThemeMapping) -> Self? { mapping.unusedSources.isEmpty ? nil : .unused }
}
