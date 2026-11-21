import Foundation

public struct RoleMappingChoice: Codable, Equatable, Hashable, Sendable {
    public var sourceID: String
    public var normalVariantID: String?
    public init(sourceID: String, normalVariantID: String? = nil) {
        self.sourceID = sourceID; self.normalVariantID = normalVariantID
    }
}

/// Editing metadata only. All runtime settings and clocks belong to the
/// destination role IDs, even when two destinations use identical artwork.
public struct ThemeMapping: Codable, Equatable, Sendable {
    public var sources: [CursorRole]
    public var bindings: [String: RoleMappingChoice]
    public var detailedNativeRoles: Bool
    /// Capture before collapsing imported aliases; source IDs alone cannot
    /// reconstruct the original directional / alias assignments reliably.
    public var importBindings: [String: RoleMappingChoice]?
    public init(sources: [CursorRole], bindings: [String: RoleMappingChoice], detailedNativeRoles: Bool = true,
                importBindings: [String: RoleMappingChoice]? = nil) {
        self.sources = sources; self.bindings = bindings; self.detailedNativeRoles = detailedNativeRoles; self.importBindings = importBindings
    }
    private enum CodingKeys: String, CodingKey { case sources, bindings, detailedNativeRoles, importBindings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decode([CursorRole].self, forKey: .sources)
        bindings = try values.decode([String: RoleMappingChoice].self, forKey: .bindings)
        detailedNativeRoles = try values.decodeIfPresent(Bool.self, forKey: .detailedNativeRoles) ?? false
        importBindings = try values.decodeIfPresent([String: RoleMappingChoice].self, forKey: .importBindings)
    }
    public static let nativeRoles = NativeCursorCatalog.all
    private static let legacyRoles: [CursorDescriptor] = {
        var seen = Set<String>()
        return CursorCatalog.all.filter { !$0.isAssetOnly && seen.insert(CursorCatalog.family($0.id)).inserted }
    }()
    public static func draft(for theme: GalleryTheme) -> ThemeMapping {
        if let mapping = theme.mapping, mapping.detailedNativeRoles { return mapping }
        if let old = theme.mapping {
            var bindings: [String: RoleMappingChoice] = [:]
            for native in nativeRoles {
                let ids = NativeCursorCatalog.identifiers(for: native.id)
                let matching = ids.compactMap { old.bindings[CursorCatalog.family($0)] }.first
                if let matching { bindings[native.id] = matching }
            }
            return ThemeMapping(sources: old.sources, bindings: bindings,
                                importBindings: inferredImportBindings(sources: old.sources))
        }
        var seen = Set<String>()
        let sources = theme.roles.filter { seen.insert(CursorCatalog.family($0.id)).inserted }
        var bindings: [String: RoleMappingChoice] = [:]
        for native in nativeRoles {
            let ids = NativeCursorCatalog.identifiers(for: native.id)
            guard let role = theme.roles.first(where: { $0.id == native.id }) ?? theme.roles.first(where: { ids.contains($0.id) }), !role.usesNative,
                  let source = sources.first(where: { CursorCatalog.family($0.id) == CursorCatalog.family(role.id) }) else { continue }
            bindings[native.id] = RoleMappingChoice(sourceID: source.id)
        }
        return ThemeMapping(sources: sources, bindings: bindings, importBindings: bindings)
    }
    private static func inferredImportBindings(sources: [CursorRole]) -> [String: RoleMappingChoice] {
        var result: [String: RoleMappingChoice] = [:]
        for native in nativeRoles {
            let ids = NativeCursorCatalog.identifiers(for: native.id)
            let source = sources.first { $0.id == native.id } ?? ids.lazy.compactMap { id in
                sources.first { CursorCatalog.family($0.id) == CursorCatalog.family(id) }
            }.first
            if let source, !source.usesNative { result[native.id] = RoleMappingChoice(sourceID: source.id) }
        }
        return result
    }
    public var restoringImportBindings: ThemeMapping {
        var result = self
        let original = importBindings ?? Self.inferredImportBindings(sources: sources)
        result.bindings = original.filter { _, choice in
            sources.contains { source in source.id == choice.sourceID && (choice.normalVariantID == nil ||
                source.variants[Motion.normal.rawValue]?.contains { $0.id == choice.normalVariantID } == true) }
        }
        result.importBindings = result.bindings
        return result
    }
    public var unusedSources: [CursorRole] {
        let used = Set(bindings.values.map(\.sourceID))
        return sources.filter { !used.contains($0.id) }
    }
    public func role(for choice: RoleMappingChoice) -> CursorRole? {
        guard var source = sources.first(where: { $0.id == choice.sourceID }) else { return nil }
        if let variant = choice.normalVariantID {
            guard let selected = source.variants[Motion.normal.rawValue]?.first(where: { $0.id == variant }) else { return nil }
            // The outgoing material remains on the source shelf. Do not add
            // a 33rd alternative to a destination that already has 32.
            source.clips[Motion.normal.rawValue] = selected.clip
            source.selectedVariants[Motion.normal.rawValue] = variant
        }
        return source
    }
    public func validate() throws {
        let native = Set((detailedNativeRoles ? Self.nativeRoles : Self.legacyRoles).map(\.id))
        let available = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !sources.isEmpty, sources.count <= 80, Set(sources.map(\.id)).count == sources.count,
              bindings.count <= native.count, bindings.keys.allSatisfy(native.contains),
              bindings.values.allSatisfy({ choice in
                  guard let source = available[choice.sourceID] else { return false }
                  return choice.normalVariantID.map { id in source.variants[Motion.normal.rawValue]?.contains { $0.id == id } == true } ?? true
              }) else {
            throw ThemeError.invalid(L("光标映射或来源素材无效。"))
        }
        for source in sources { try GalleryTheme.validateRole(source) }
        if let importBindings {
            var original = self; original.importBindings = nil; original.bindings = importBindings
            try original.validate()
        }
    }
    public func applying(to input: GalleryTheme, deleteUnused: Bool) throws -> GalleryTheme {
        try validate()
        guard !bindings.isEmpty else { throw ThemeError.invalid(L("请至少绑定一个系统角色。")) }
        var result = input
        let previous = Self.draft(for: input)
        var copies: [CursorRole] = []
        for native in detailedNativeRoles ? Self.nativeRoles : Self.legacyRoles {
            guard let choice = bindings[native.id], let source = role(for: choice) else { continue }
            let unchanged = previous.bindings[native.id] == choice
            // Preserve edits to each destination when revisiting the mapping
            // window. Rebinding explicitly creates a fresh value copy.
            let ids = detailedNativeRoles ? NativeCursorCatalog.identifiers(for: native.id)
                : CursorCatalog.all.filter { CursorCatalog.family($0.id) == native.id }.map(\.id)
            let existing = input.roles.filter { ids.contains($0.id) }
            let canonical = existing.first { $0.id == native.id } ?? existing.first ?? source
            for id in ids {
                var copy = unchanged ? (input.mapping?.detailedNativeRoles == true
                    ? (existing.first { $0.id == id } ?? canonical) : canonical) : source
                copy.id = id; copy.name = native.title
                if !unchanged || existing.isEmpty { copy.usesNative = false }
                copies.append(copy)
            }
        }
        result.roles = copies
        var saved = self
        if saved.importBindings == nil { saved.importBindings = restoringImportBindings.bindings }
        if deleteUnused {
            let used = Set(bindings.values.map(\.sourceID))
            saved.sources.removeAll { !used.contains($0.id) }
            saved.importBindings = saved.importBindings?.filter { used.contains($0.value.sourceID) }
        }
        result.mapping = saved
        try result.validate()
        return result
    }
}

/// Project preferred positions onto a non-overlapping column in both
/// directions. A collision shifts a local cluster up AND down, rather than
/// pushing every later card below it. Unbinding keeps a source near its last
/// position instead of sending it to the bottom of the entire native list.
public struct MappingBoardLayout: Equatable, Sendable {
    public var natives: [String: Double]
    public var sources: [String: Double]
    public init(natives: [String: Double] = [:], sources: [String: Double] = [:]) {
        self.natives = natives; self.sources = sources
    }
}

public enum MappingLayout {
    /// Try the original system order first, moving the source column toward
    /// its destinations. Remaining crossings are inversions between source
    /// groups: a stable sort of only the bound native cards removes those
    /// inversions with the fewest pairwise changes for that source order.
    /// Unbound native cards retain their original slots, and order inside a
    /// shared-source group stays the same as the system catalog.
    public static func arrangement(_ mapping: ThemeMapping, spacing: Double = 204,
                                   previous: [String: Double] = [:], cardHeight: Double = 176) -> MappingBoardLayout {
        let original = ThemeMapping.nativeRoles.map(\.id)
        let heights = Dictionary(uniqueKeysWithValues: mapping.sources.map { ($0.id, cardHeight) })
        let first = sourceSlots(mapping, heights: heights, spacing: spacing, previous: previous)
        let sourceIndices = Dictionary(uniqueKeysWithValues: mapping.sources.enumerated().map { ($1.id, $0) })
        let sourceOrder = mapping.sources.map(\.id).sorted {
            let a = first[$0] ?? 0, b = first[$1] ?? 0
            return a == b ? sourceIndices[$0]! < sourceIndices[$1]! : a < b
        }
        let rank = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($1, $0) })
        let nativeIndices = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($1, $0) })
        let bound = original.filter { mapping.bindings[$0] != nil }
        let grouped = bound.sorted {
            let a = rank[mapping.bindings[$0]!.sourceID] ?? 0, b = rank[mapping.bindings[$1]!.sourceID] ?? 0
            return a == b ? nativeIndices[$0]! < nativeIndices[$1]! : a < b
        }
        var next = 0
        let order = original.map { id -> String in
            guard mapping.bindings[id] != nil else { return id }
            defer { next += 1 }; return grouped[next]
        }
        let natives = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, Double($0) * spacing) })
        let sources = sourceSlots(mapping, heights: heights, spacing: spacing, previous: first, nativeOrder: order)
        return MappingBoardLayout(natives: natives, sources: sources)
    }
    public static func sourceSlots(_ mapping: ThemeMapping, heights: [String: Double] = [:], spacing: Double = 204,
                                   previous: [String: Double] = [:], nativeOrder: [String]? = nil) -> [String: Double] {
        let order = nativeOrder ?? ThemeMapping.nativeRoles.map(\.id)
        let indices = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, Double($0)) })
        var positions: [String: [Double]] = [:]
        for (native, choice) in mapping.bindings {
            if let index = indices[native] { positions[choice.sourceID, default: []].append(index * spacing) }
        }
        var ordered: [(id: String, target: Double, index: Int)] = []
        for (index, source) in mapping.sources.enumerated() {
            let targets = (positions[source.id] ?? []).sorted()
            let target: Double
            if targets.isEmpty { target = previous[source.id] ?? Double(index) * spacing }
            // An even split anchors to an actual earlier destination rather
            // than a midpoint many empty rows away from both (e.g. I-beam/XOR).
            else { target = targets[(targets.count - 1) / 2] }
            ordered.append((source.id, target, index))
        }
        ordered.sort { a, b in a.target == b.target ? a.index < b.index : a.target < b.target }
        // Pool-adjacent-violators solves this small convex placement problem.
        // Removing mandatory gaps turns the constraint into nondecreasing y.
        struct Block { var first: Int; var last: Int; var sum: Double; var count: Double; var mean: Double { sum / count } }
        var offsets: [Double] = [], gap = 0.0, blocks: [Block] = []
        for (index, node) in ordered.enumerated() {
            offsets.append(gap)
            gap += max(spacing, (heights[node.id] ?? 176) + 28)
            blocks.append(Block(first: index, last: index, sum: node.target - offsets[index], count: 1))
            while blocks.count >= 2 && blocks[blocks.count - 2].mean > blocks[blocks.count - 1].mean {
                let last = blocks.removeLast(), before = blocks.removeLast()
                blocks.append(Block(first: before.first, last: last.last, sum: before.sum + last.sum, count: before.count + last.count))
            }
        }
        var result: [String: Double] = [:]
        for block in blocks {
            for index in block.first...block.last { result[ordered[index].id] = max(0, block.mean) + offsets[index] }
        }
        return result
    }
}

/// Sidebar grouping is presentation only. Each destination still edits its own
/// independent CursorRole, and unassigned imported sources remain discoverable.
public struct ThemeRoleGroup: Identifiable, Sendable {
    public let source: CursorRole
    public let destinations: [CursorRole]
    public var id: String { source.id }
}
extension GalleryTheme {
    public var editorRoleGroups: [ThemeRoleGroup] {
        guard let mapping, mapping.detailedNativeRoles else {
            var seen = Set<String>()
            return roles.filter { seen.insert(roleFamily($0.id)).inserted }.map { ThemeRoleGroup(source: $0, destinations: [$0]) }
        }
        return mapping.sources.map { source in
            let ids = Set(mapping.bindings.filter { $0.value.sourceID == source.id }.map(\.key))
            var seen = Set<String>()
            let destinations = roles.filter {
                let id = NativeCursorCatalog.identity($0.id)
                return ids.contains(id) && seen.insert(id).inserted
            }
            return ThemeRoleGroup(source: source, destinations: destinations)
        }
    }
}
