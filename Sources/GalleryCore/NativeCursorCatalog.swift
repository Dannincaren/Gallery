import Foundation

/// macOS cursor slots, without Gallery's Windows-oriented semantic grouping.
/// Only spellings of the same OS slot are aliases. The resize directions,
/// hand states, crosshairs and drag operations are independent destinations.
public enum NativeCursorCatalog {
    public static let all: [CursorDescriptor] = {
        let rows: [(String, String, String)] = [
            ("com.apple.coregraphics.Arrow", "箭头", ""),
            // Resource names describe text layout, not the I-beam's shape.
            ("com.apple.coregraphics.IBeam", "I 型光标", "ibeamhorizontal"),
            ("com.apple.cursor.26", "垂直文本 I 型光标", "ibeamvertical"),
            ("com.apple.cursor.13", "指向手形", "pointinghand"),
            ("com.apple.cursor.12", "张开的手", "openhand"),
            ("com.apple.cursor.11", "握紧的手", "closedhand"),
            ("com.apple.cursor.2", "拖移链接", "makealias"),
            ("com.apple.cursor.5", "拖移复制", "copy"),
            ("com.apple.cursor.3", "不允许操作", "notallowed"),
            ("com.apple.cursor.24", "上下文菜单", "contextualmenu"),
            ("com.apple.cursor.25", "项目消失", "poof"),
            ("com.apple.cursor.4", "忙碌但可点击", "busybutclickable"),
            ("com.apple.coregraphics.Wait", "等待", ""),
            ("com.apple.cursor.40", "帮助", "help"),
            ("com.apple.cursor.20", "十字线", "cross"),
            ("com.apple.cursor.41", "单元格", "cell"),
            ("com.apple.cursor.7", "十字线（系统 7）", ""),
            ("com.apple.cursor.8", "十字线（系统 8）", ""),
            ("com.apple.coregraphics.IBeamXOR", "反色 I 型光标", ""),
            ("com.apple.cursor.9", "截屏选区", "screenshotselection"),
            ("com.apple.cursor.10", "截屏窗口", "screenshotwindow"),
            ("com.apple.coregraphics.Move", "移动", "move"),
            ("com.apple.cursor.42", "放大", "zoomin"),
            ("com.apple.cursor.43", "缩小", "zoomout"),
            ("com.apple.cursor.17", "调整列宽（向左）", "resizeleft"),
            ("com.apple.cursor.18", "调整列宽（向右）", "resizeright"),
            ("com.apple.cursor.19", "调整列宽（双向）", "resizeleftright"),
            ("com.apple.cursor.21", "调整行高（向上）", "resizeup"),
            ("com.apple.cursor.22", "调整行高（向下）", "resizedown"),
            ("com.apple.cursor.23", "调整行高（双向）", "resizeupdown"),
            ("com.apple.cursor.27", "调整边框（向东）", "resizeeast"),
            ("com.apple.cursor.38", "调整边框（向西）", "resizewest"),
            ("com.apple.cursor.28", "调整边框（东西）", "resizeeastwest"),
            ("com.apple.cursor.36", "调整边框（向南）", "resizesouth"),
            ("com.apple.cursor.31", "调整边框（向北）", "resizenorth"),
            ("com.apple.cursor.32", "调整边框（南北）", "resizenorthsouth"),
            ("com.apple.cursor.33", "调整边框（西北）", "resizenorthwest"),
            ("com.apple.cursor.35", "调整边框（东南）", "resizesoutheast"),
            ("com.apple.cursor.34", "调整边框（西北／东南）", "resizenorthwestsoutheast"),
            ("com.apple.cursor.29", "调整边框（东北）", "resizenortheast"),
            ("com.apple.cursor.37", "调整边框（西南）", "resizesouthwest"),
            ("com.apple.cursor.30", "调整边框（东北／西南）", "resizenortheastsouthwest"),
            ("com.apple.cursor.39", "调整大小（系统 39）", ""),
            ("com.apple.cursor.14", "计数手形（递增）", "countinguphand"),
            ("com.apple.cursor.15", "计数手形（递减）", "countingdownhand"),
            ("com.apple.cursor.16", "计数手形（增减）", "countingupandownhand")
        ]
        return rows.map { CursorDescriptor(id: $0.0, title: $0.1, resource: $0.2) }
    }()
    /// Public AppKit names where documented; raw OS identifiers elsewhere.
    /// Direction variants below were matched to the local NSCursor API probe.
    private static let publicNames: [String: String] = [
            "com.apple.coregraphics.Arrow": "arrow", "com.apple.coregraphics.IBeam": "iBeam",
            "com.apple.cursor.26": "iBeamCursorForVerticalLayout", "com.apple.cursor.13": "pointingHand",
            "com.apple.cursor.12": "openHand", "com.apple.cursor.11": "closedHand",
            "com.apple.cursor.2": "dragLink", "com.apple.cursor.5": "dragCopy",
            "com.apple.cursor.3": "operationNotAllowed", "com.apple.cursor.24": "contextualMenu",
            "com.apple.cursor.25": "disappearingItem", "com.apple.cursor.20": "crosshair",
            "com.apple.cursor.42": "zoomIn", "com.apple.cursor.43": "zoomOut",
            "com.apple.cursor.17": "columnResize(left)", "com.apple.cursor.18": "columnResize(right)",
            "com.apple.cursor.19": "columnResize(all)", "com.apple.cursor.21": "rowResize(up)",
            "com.apple.cursor.22": "rowResize(down)", "com.apple.cursor.23": "rowResize(all)",
            "com.apple.cursor.31": "frameResize(top, outward)", "com.apple.cursor.36": "frameResize(bottom, outward)",
            "com.apple.cursor.38": "frameResize(left, outward)", "com.apple.cursor.27": "frameResize(right, outward)",
            "com.apple.cursor.32": "frameResize(top, all)", "com.apple.cursor.28": "frameResize(left, all)",
            "com.apple.cursor.33": "frameResize(topLeft, outward)", "com.apple.cursor.35": "frameResize(bottomRight, outward)",
            "com.apple.cursor.29": "frameResize(topRight, outward)", "com.apple.cursor.37": "frameResize(bottomLeft, outward)",
            "com.apple.cursor.34": "frameResize(topLeft, all)", "com.apple.cursor.30": "frameResize(topRight, all)"
        ]
    public static func systemName(_ id: String) -> String {
        let key = identity(id)
        return publicNames[key] ?? key
    }
    public static func displayName(_ id: String) -> String {
        let key = identity(id)
        let description = ["com.apple.cursor.7", "com.apple.cursor.8", "com.apple.cursor.39"].contains(key)
            ? L("旧系统槽位，公开用途未确认") : GalleryLocalization.label(title(key))
        return systemName(key) + " (" + description + ")"
    }
    private static let aliases: [String: String] = [
        "com.apple.cursor.0": "com.apple.coregraphics.Arrow",
        "com.apple.coregraphics.ArrowS": "com.apple.coregraphics.Arrow",
        "com.apple.cursor.1": "com.apple.coregraphics.IBeam",
        "com.apple.coregraphics.IBeamS": "com.apple.coregraphics.IBeam",
        "com.apple.coregraphics.Alias": "com.apple.cursor.2",
        "com.apple.coregraphics.Copy": "com.apple.cursor.5",
        "com.apple.coregraphics.ArrowCtx": "com.apple.cursor.24"
    ]
    public static func identity(_ id: String) -> String { aliases[id] ?? id }
    public static func identifiers(for id: String) -> [String] {
        let canonical = identity(id)
        return [canonical] + aliases.keys.filter { aliases[$0] == canonical }.sorted()
    }
    public static func title(_ id: String) -> String { all.first { $0.id == identity(id) }?.title ?? CursorCatalog.title(id) }
}
