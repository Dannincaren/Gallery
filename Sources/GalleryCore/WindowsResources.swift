import Foundation

/// Read embedded CLI ManifestResource entries without loading or executing PE
/// code. ECMA-335 II.24/II.22 metadata layout; every range is checked.
public struct WindowsResources {
    private let data: Data
    public let entries: [String: Range<Int>]
    public init(data: Data) throws {
        guard data.count <= 600_000_000 else { throw ThemeError.invalid("安装器超过 600 MB。") }
        let r = BinaryReader(data: data)
        guard try r.u16(0) == 0x5a4d else { throw ThemeError.invalid("不是 Windows 安装器。") }
        let pe = try r.u32(0x3c)
        guard try r.u32(pe) == 0x4550 else { throw ThemeError.invalid("PE 签名无效。") }
        let sections = try r.u16(pe + 6), optSize = try r.u16(pe + 20), optional = pe + 24
        guard sections > 0, sections <= 96 else { throw ThemeError.invalid("PE 节表无效。") }
        let magic = try r.u16(optional)
        guard magic == 0x10b || magic == 0x20b else { throw ThemeError.invalid("不支持此 PE 格式。") }
        let directory = optional + (magic == 0x10b ? 96 : 112)
        guard optSize >= directory - optional + 15 * 8 else { throw ThemeError.invalid("缺少 CLI 目录。") }
        func fileOffset(_ address: Int) throws -> Int {
            for i in 0..<sections {
                let section = optional + optSize + i * 40
                let virtual = try r.u32(section + 12), rawSize = try r.u32(section + 16), raw = try r.u32(section + 20)
                if address >= virtual, address - virtual < rawSize {
                    let offset = raw + address - virtual
                    try r.bounds(offset, 1); return offset
                }
            }
            throw ThemeError.invalid("CLI 地址不在有效节内。")
        }
        let cli = try fileOffset(r.u32(directory + 14 * 8))
        let metadata = try fileOffset(r.u32(cli + 8))
        let resources = try fileOffset(r.u32(cli + 24))
        let resourcesLength = try r.u32(cli + 28)
        try r.bounds(resources, resourcesLength)
        guard try r.u32(metadata) == 0x424a5342 else { throw ThemeError.invalid("CLI 元数据签名无效。") }
        let versionLength = try r.u32(metadata + 12)
        var p = metadata + 16 + versionLength
        p = (p + 3) & ~3
        let streams = try r.u16(p + 2); p += 4
        guard streams <= 32 else { throw ThemeError.invalid("元数据流过多。") }
        var streamOffsets: [String: Int] = [:]
        for _ in 0..<streams {
            let offset = try r.u32(p), length = try r.u32(p + 4)
            let (name, consumed) = try r.string(p + 8, maximum: 32)
            try r.bounds(metadata + offset, length)
            streamOffsets[name] = metadata + offset
            p = (p + 8 + consumed + 3) & ~3
        }
        guard let strings = streamOffsets["#Strings"], let tables = streamOffsets["#~"] ?? streamOffsets["#-"] else {
            throw ThemeError.invalid("安装器缺少标准 CLI 元数据表。")
        }
        let heapFlags = try r.byte(tables + 6)
        let stringIndex = heapFlags & 1 == 0 ? 2 : 4
        let guidIndex = heapFlags & 2 == 0 ? 2 : 4
        let blobIndex = heapFlags & 4 == 0 ? 2 : 4
        var counts = [Int](repeating: 0, count: 64)
        p = tables + 24
        for table in 0..<64 {
            let flag = try r.byte(tables + 8 + table / 8)
            if flag & (1 << (table % 8)) != 0 { counts[table] = try r.u32(p); p += 4 }
        }
        func index(_ table: Int) -> Int { counts[table] < 65536 ? 2 : 4 }
        func coded(_ bits: Int, _ tables: [Int]) -> Int { tables.map { counts[$0] }.max()! < (1 << (16 - bits)) ? 2 : 4 }
        let type = coded(2, [2, 1, 27]), member = coded(1, [6, 10])
        let implementation = coded(2, [38, 35, 39])
        let s = stringIndex, b = blobIndex, g = guidIndex
        let sizes = [
            2+s+g*3, coded(2,[0,26,35,1])+s*2, 4+s*2+type+index(4)+index(6), index(4), 2+s+b,
            index(6), 8+s+b+index(8), index(8), 4+s, index(2)+type,
            coded(3,[2,1,26,6,27])+s+b, 2+coded(2,[4,8,23])+b,
            coded(5,[6,4,1,2,8,9,10,0,14,23,20,17,26,27,32,35,38,39,40,42,44,43])+coded(3,[6,10])+b,
            coded(1,[4,8])+b, 2+coded(2,[2,6,32])+b, 6+index(2), 4+index(4), b,
            index(2)+index(20), index(20), 2+s+type, index(2)+index(23), index(23), 2+s+b,
            2+index(6)+coded(1,[20,23]), index(2)+member*2, s, b,
            2+coded(1,[4,6])+s+index(26), 4+index(4), 8, 4, 16+b+s*2, 4, 12,
            12+b*2+s*2, 4+index(35), 12+index(35), 4+s+b, 8+s*2+implementation
        ]
        for table in 0..<40 {
            guard counts[table] <= 5_000_000 else { throw ThemeError.invalid("元数据表过大。") }
            let length = counts[table] * sizes[table]
            try r.bounds(p, length); p += length
        }
        guard counts[40] > 0, counts[40] <= 10000 else { throw ThemeError.invalid("未找到嵌入素材。") }
        var found: [String: Range<Int>] = [:]
        for _ in 0..<counts[40] {
            let offset = try r.u32(p)
            let nameOffset = try r.integer(p + 8, bytes: s)
            let external = try r.integer(p + 8 + s, bytes: implementation)
            let (name, _) = try r.string(strings + nameOffset, maximum: 512)
            if external == 0, name.hasPrefix("PRTS-Replica-"), name.hasSuffix(".cur") || name.hasSuffix(".ani") {
                guard offset + 4 <= resourcesLength else { throw ThemeError.invalid("素材偏移越界。") }
                let length = try r.u32(resources + offset)
                guard length > 0, length <= 40_000_000, offset + 4 + length <= resourcesLength else { throw ThemeError.invalid("素材长度越界。") }
                found[name] = resources + offset + 4..<resources + offset + 4 + length
            }
            p += 8 + s + implementation
        }
        guard !found.isEmpty else { throw ThemeError.invalid("安装器没有可识别的 PRTS 光标资源。") }
        self.data = data; self.entries = found
    }
    public func resource(suffix: String) -> Data? {
        guard let name = entries.keys.sorted().first(where: { $0.hasSuffix("-" + suffix) }), let range = entries[name] else { return nil }
        return data.subdata(in: range)
    }
    public func theme() throws -> GalleryTheme {
        var roles: [CursorRole] = []
        var cache: [String: CursorClip] = [:]
        func loadEntry(_ name: String) throws -> CursorClip? {
            if let clip = cache[name] { return clip }
            guard let range = entries[name] else { return nil }
            let clip = resized(try AnimationImport.read(data.subdata(in: range), extension: URL(fileURLWithPath: name).pathExtension,
                trimTerminalHold: name.contains("_press") || name.contains("_release") || name.hasSuffix("-beam_click.ani")))
            cache[name] = clip; return clip
        }
        func load(_ name: String) throws -> CursorClip? {
            guard let entry = entries.keys.sorted().first(where: { $0.hasSuffix("-" + name) }) else { return nil }
            return try loadEntry(entry)
        }
        for descriptor in CursorCatalog.all {
            guard let base = try load(descriptor.resource) else { continue }
            let prefix = URL(fileURLWithPath: descriptor.resource).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_loop", with: "")
            var clips = [Motion.normal.rawValue: base]
            for (motion, filename) in [(Motion.press, prefix == "beam" ? "beam_click.ani" : prefix + "_press.ani"),
                                       (.hold, prefix + "_hold.cur"), (.release, prefix + "_release.ani")] {
                clips[motion.rawValue] = try load(filename)
            }
            if CursorCatalog.isArrow(descriptor.id) { clips[Motion.idle.rawValue] = try load("idle.ani") }
            var variants: [String: [CursorVariant]] = [:], selected: [String: String] = [:]
            for motion in Motion.allCases where clips[motion.rawValue] != nil {
                let original: String
                switch motion {
                case .normal: original = descriptor.resource
                case .idle: original = "idle.ani"
                case .press: original = prefix == "beam" ? "beam_click.ani" : prefix + "_press.ani"
                case .hold: original = prefix + "_hold.cur"
                case .release: original = prefix + "_release.ani"
                }
                var filenames = [original]
                if motion == .normal {
                    if original == "beam_loop.ani" { filenames.append("beam.cur") }
                    else if original.hasSuffix(".ani") { filenames.append(prefix + "_static.cur") }
                    if original == "unavail1.ani" { filenames += ["unavail2.ani", "unavail2_static.cur"] }
                }
                let names = filenames.flatMap { file in entries.keys.sorted().filter { $0.hasSuffix("-" + file) } }
                for name in names.prefix(32) {
                    guard let clip = try loadEntry(name) else { continue }
                    let filename = name.components(separatedBy: "-").last ?? name
                    let kind = clip.frames.count > 1 ? "动态" : "静态"
                    let label = "\(kind) · \(filename)" + (names.filter { $0.hasSuffix("-" + filename) }.count > 1 ? " · \(name)" : "")
                    variants[motion.rawValue, default: []].append(CursorVariant(id: name, name: label, clip: clip))
                }
                selected[motion.rawValue] = variants[motion.rawValue]?.first?.id
            }
            roles.append(CursorRole(id: descriptor.id, name: descriptor.title, clips: clips, variants: variants, selectedVariants: selected))
        }
        let theme = GalleryTheme(name: "PRTS · Gallery", author: "PRTS 原作者 / 用户本地导入", roles: roles)
        try theme.validate(); return theme
    }
    private func resized(_ clip: CursorClip) -> CursorClip {
        var c = clip
        c.hotX = c.hotX * 32 / c.width; c.hotY = c.hotY * 32 / c.height
        c.width = 32; c.height = 32
        return c
    }
}

private struct BinaryReader {
    let data: Data
    func bounds(_ p: Int, _ length: Int) throws {
        guard p >= 0, length >= 0, p <= data.count, length <= data.count - p else { throw ThemeError.invalid("安装器数据已截断或越界。") }
    }
    func byte(_ p: Int) throws -> Int { try bounds(p, 1); return Int(data[p]) }
    func integer(_ p: Int, bytes: Int) throws -> Int {
        try bounds(p, bytes)
        return (0..<bytes).reduce(0) { $0 | Int(data[p + $1]) << ($1 * 8) }
    }
    func u16(_ p: Int) throws -> Int { try integer(p, bytes: 2) }
    func u32(_ p: Int) throws -> Int { try integer(p, bytes: 4) }
    func string(_ p: Int, maximum: Int) throws -> (String, Int) {
        try bounds(p, 1)
        let end = min(data.count, p + maximum)
        guard let zero = data[p..<end].firstIndex(of: 0), let string = String(data: data[p..<zero], encoding: .utf8) else { throw ThemeError.invalid("元数据字符串无效。") }
        return (string, zero - p + 1)
    }
}
