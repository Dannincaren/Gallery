import Foundation

public struct CursorDescriptor {
    public let id: String
    public let title: String
    public let resource: String
    public var isAssetOnly: Bool { id.hasPrefix("com.apple.gallery.") }
}

public enum CursorCatalog {
    /// CoreCursor numbers follow Mousecape's cursorMap. Windows-only semantic
    /// roles are retained as editable assets, never registered to invented IDs.
    public static let all: [CursorDescriptor] = {
        var rows: [CursorDescriptor] = []
        func add(_ title: String, _ file: String, _ ids: [String]) {
            rows += ids.map { CursorDescriptor(id: $0, title: title, resource: file) }
        }
        func core(_ ids: [Int]) -> [String] { ids.map { "com.apple.cursor.\($0)" } }
        add("正常选择", "normal.cur", ["com.apple.coregraphics.Arrow", "com.apple.cursor.0", "com.apple.coregraphics.Alias", "com.apple.coregraphics.Copy"])
        add("帮助选择", "helpsel.cur", core([40]))
        add("链接选择", "link.cur", core([2, 13]))
        add("后台运行", "work.ani", core([4]))
        add("忙", "busy.ani", ["com.apple.coregraphics.Wait"])
        add("精准选择", "cross.cur", core([7, 8, 20, 41]))
        add("文本选择", "beam_loop.ani", ["com.apple.coregraphics.IBeam", "com.apple.coregraphics.IBeamXOR"] + core([1]))
        add("竖排文本选择", "beam_loop.ani", core([26]))
        add("手写", "pen.cur", ["com.apple.gallery.Handwriting"])
        add("移动", "move.ani", ["com.apple.coregraphics.Move"] + core([11, 12]))
        add("候选选择", "up.cur", ["com.apple.coregraphics.ArrowCtx"] + core([24]))
        add("垂直调整", "sel_1.ani", core([21, 22, 23, 31, 32, 36]))
        add("水平调整", "sel_2.ani", core([17, 18, 19, 27, 28, 38]))
        add("对角调整 ↗↙", "sel_4.ani", core([29, 30, 37]))
        add("对角调整 ↖↘", "sel_3.ani", core([33, 34, 35]))
        add("调整大小", "sel_4.ani", core([39]))
        add("不可用", "unavail1.ani", core([3]))
        add("复制拖放", "normal.cur", core([5]))
        add("定位选择", "pin.cur", ["com.apple.gallery.Location"])
        add("人员选择", "person.cur", ["com.apple.gallery.Person"])
        return rows
    }()
    public static func title(_ id: String) -> String {
        all.first { $0.id == id }?.title ?? id.replacingOccurrences(of: "com.apple.", with: "")
    }
    public static func assetOnly(_ id: String) -> Bool { id.hasPrefix("com.apple.gallery.") }
    public static func isArrow(_ id: String) -> Bool { ["com.apple.coregraphics.Arrow", "com.apple.cursor.0", "com.apple.coregraphics.ArrowS"].contains(id) }
    public static func isResize(_ id: String) -> Bool {
        ["com.apple.cursor.17", "com.apple.cursor.21", "com.apple.cursor.29", "com.apple.cursor.33", "com.apple.cursor.39"].contains(family(id))
    }
    /// Family identity is independent of editable/localized display names.
    /// Two unrelated roles named "Cursor" must retain independent settings.
    public static func family(_ id: String) -> String {
        let compatible = id == "com.apple.coregraphics.ArrowS" ? "com.apple.coregraphics.Arrow"
            : id == "com.apple.coregraphics.IBeamS" ? "com.apple.coregraphics.IBeam" : id
        guard let row = all.first(where: { $0.id == compatible }) else { return id }
        return all.first(where: { $0.title == row.title })!.id
    }
    public static let compatibilityAliases: [(String, String)] = [
        ("com.apple.coregraphics.Arrow", "com.apple.cursor.0"),
        ("com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS"),
        ("com.apple.coregraphics.IBeam", "com.apple.cursor.1"),
        ("com.apple.coregraphics.IBeam", "com.apple.coregraphics.IBeamS")
    ]
}

public enum MouseEdge: Equatable { case down, up }
/// Passive fallback when a session event tap is unavailable. Counters preserve
/// a complete quick click even when down and up occur between two timer ticks.
public struct MouseEdgeTracker {
    private var downs: UInt32
    private var ups: UInt32
    public init(downs: UInt32, ups: UInt32) { self.downs = downs; self.ups = ups }
    public mutating func observe(downs: UInt32, ups: UInt32, isDown: Bool) -> [MouseEdge] {
        let downChanged = downs != self.downs, upChanged = ups != self.ups
        self.downs = downs; self.ups = ups
        if downChanged && upChanged { return isDown ? [.up, .down] : [.down, .up] }
        if downChanged { return [.down] }
        if upChanged { return [.up] }
        return []
    }
}
