import Foundation
import CoreFoundation
import CryptoKit

/// Reads embedded files and INF declarations as data. No installer, registry
/// command, DLL or INF action is executed.
public enum WindowsThemeImport {
    public static func load(_ url: URL) throws -> GalleryTheme {
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { return try loadDirectory(url) }
        if url.pathExtension.lowercased() == "inf" { return try loadDirectory(url.deletingLastPathComponent(), selectedINF: url.lastPathComponent) }
        if url.pathExtension.lowercased() == "zip" { return try loadZIP(url) }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 600_000_000 else { throw ThemeError.invalid("安装包超过 600 MB。") }
        let resources: WindowsResources
        do { resources = try WindowsResources(data: Data(contentsOf: url, options: .mappedIfSafe)) }
        catch { throw ThemeError.invalid("无法直接读取此 EXE 的内嵌光标。当前支持内嵌 CUR／ANI 的 .NET 安装器；其他打包方式请提供解压后的光标 ZIP。\n\(error.localizedDescription)") }
        if resources.resource(suffix: "normal.cur") != nil,
           resources.entries.keys.contains(where: { $0.hasPrefix("PRTS-Replica-") }) { return try resources.theme() }
        let files = Dictionary(uniqueKeysWithValues: resources.entries.keys.map { ($0, resources.resource(named: $0)!) })
        return try theme(files: files, name: url.deletingPathExtension().lastPathComponent)
    }

    private static func loadDirectory(_ url: URL, selectedINF: String? = nil) throws -> GalleryTheme {
        let base = url.standardizedFileURL
        var scanError: Error?
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw ThemeError.invalid("无法读取素材文件夹。")
        }
        var files: [String: Data] = [:], installers: [URL] = [], count = 0, total = 0
        for case let file as URL in iterator {
            count += 1
            guard count <= 10000 else { throw ThemeError.invalid("文件夹内容过多，请选择单独一套鼠标主题的文件夹。") }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if info.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard info.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            if ext == "exe" { installers.append(file); continue }
            guard ["cur", "ani", "inf"].contains(ext) else { continue }
            if ext == "inf", let selectedINF, file.standardizedFileURL != base.appendingPathComponent(selectedINF) { continue }
            let size = info.fileSize ?? 0
            total += size
            guard size <= 40_000_000, total <= 80_000_000, files.count < 1000 else { throw ThemeError.invalid("文件夹的光标素材过多或超过 80 MB，请拆分主题。") }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(base.path + "/") else { throw ThemeError.invalid("素材不在选中的文件夹内。") }
            files[String(path.dropFirst(base.path.count + 1))] = try Data(contentsOf: file)
        }
        if let scanError { throw scanError }
        if !files.keys.contains(where: { ["cur", "ani"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
            if let prts = installers.first(where: { $0.lastPathComponent.lowercased() == "prts-setup.exe" }) { return try load(prts) }
            if installers.count == 1 { return try load(installers[0]) }
            throw ThemeError.invalid("文件夹中没有 CUR／ANI 光标。若有多个 EXE，请直接选择包含素材的安装器。")
        }
        return try theme(files: files, name: base.lastPathComponent)
    }

    private static func loadZIP(_ url: URL) throws -> GalleryTheme {
        // Stream named members rather than extracting paths from an untrusted
        // archive. A bounded file handle also limits expanded data on disk.
        let namesData = try unzip(url, arguments: ["-Z1"], limit: 2_000_000)
        guard let listing = String(data: namesData, encoding: .utf8) else { throw ThemeError.invalid("ZIP 文件名编码无法识别。") }
        let names = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count <= 10000 else { throw ThemeError.invalid("ZIP 文件数量过多。") }
        if let setup = names.first(where: { filename($0).lowercased() == "prts-setup.exe" }) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("PRTS-Setup.exe")
            try unzip(url, arguments: ["-p"], member: setup, limit: 600_000_000).write(to: target)
            return try load(target)
        }
        let assets = names.filter { ["cur", "ani", "inf"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        if assets.isEmpty, let exe = names.first(where: { $0.lowercased().hasSuffix(".exe") }),
           names.filter({ $0.lowercased().hasSuffix(".exe") }).count == 1 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent(filename(exe))
            try unzip(url, arguments: ["-p"], member: exe, limit: 600_000_000).write(to: target)
            return try load(target)
        }
        guard !assets.isEmpty, assets.count <= 1000, Set(assets).count == assets.count else {
            throw ThemeError.invalid("ZIP 中没有可识别的光标，或包含过多／重名文件。请提供 CUR、ANI 和安装 INF，或包含素材的 EXE。")
        }
        var files: [String: Data] = [:], total = 0
        for name in assets.sorted() {
            let data = try unzip(url, arguments: ["-p"], member: name, limit: 40_000_000)
            total += data.count
            guard total <= 80_000_000 else { throw ThemeError.invalid("ZIP 展开的光标素材超过 80 MB。") }
            files[name] = data
        }
        return try theme(files: files, name: url.deletingPathExtension().lastPathComponent)
    }
    private static func unzip(_ url: URL, arguments: [String], member: String? = nil, limit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let literal = member.map { name -> String in
            var result = ""
            for (index, char) in name.enumerated() {
                if "\\[]?*".contains(char) || (index == 0 && char == "-") { result.append("\\") }
                result.append(char)
            }
            return result
        }
        process.arguments = arguments + [url.path] + (literal.map { [$0] } ?? [])
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? pipe.fileHandleForReading.close() }
        var result = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard result.count + chunk.count <= limit else {
                process.terminate(); process.waitUntilExit(); throw ThemeError.invalid("ZIP 展开数据超过限制。")
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeError.invalid("ZIP 文件损坏或成员无法读取。") }
        return result
    }

    private static let registry: [String: String] = [
        "normal.cur": "arrow", "helpsel.cur": "help", "link.cur": "hand", "work.ani": "appstarting",
        "busy.ani": "wait", "cross.cur": "crosshair", "beam_loop.ani": "ibeam", "pen.cur": "nwpen",
        "move.ani": "sizeall", "up.cur": "uparrow", "sel_1.ani": "sizens", "sel_2.ani": "sizewe",
        "sel_3.ani": "sizenwse", "sel_4.ani": "sizenesw", "unavail1.ani": "no", "pin.cur": "pin", "person.cur": "person"
    ]
    private static let aliases: [String: [String]] = [
        "arrow": ["normal", "arrow", "pointer", "正常选择"], "help": ["help", "helpsel", "帮助选择"],
        "hand": ["link", "hand", "链接选择"], "appstarting": ["working", "work", "appstarting", "后台运行"],
        "wait": ["busy", "wait", "忙"], "crosshair": ["precision", "cross", "crosshair", "精准选择"],
        "ibeam": ["text", "ibeam", "beam", "文本选择"], "nwpen": ["handwriting", "pen", "手写"],
        "sizeall": ["move", "sizeall", "移动"], "uparrow": ["alternate", "up", "uparrow", "候选选择"],
        "sizens": ["vertical", "vert", "sizens", "垂直调整"], "sizewe": ["horizontal", "horz", "sizewe", "水平调整"],
        "sizenwse": ["diagonal1", "dgn1", "sizenwse"], "sizenesw": ["diagonal2", "dgn2", "sizenesw"],
        "no": ["unavailable", "unavail", "no", "不可用"], "pin": ["pin", "location", "定位选择"], "person": ["person", "人员选择"]
    ]
    public static func theme(files: [String: Data], name: String) throws -> GalleryTheme {
        let assets = files.keys.filter { ["cur", "ani"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.sorted()
        guard !assets.isEmpty, assets.count <= 1000 else { throw ThemeError.invalid("没有可读取的 CUR／ANI 素材，或素材数量过多。") }
        var declarations: [String: [String]] = [:], scheme = name
        for inf in files.keys.filter({ $0.lowercased().hasSuffix(".inf") }).sorted() {
            let parsed = try parseINF(files[inf]!)
            if let title = parsed.name { scheme = title }
            for (key, values) in parsed.roles { declarations[key, default: []] += values }
        }
        let filenameCounts = Dictionary(grouping: assets, by: { filename($0).lowercased() }).mapValues(\.count)
        var choices: [String: [Motion: [String]]] = [:], used = Set<String>(), decoded: [String: CursorClip] = [:]
        for (key, names) in declarations {
            for reference in names {
                let matches = assets.filter { Self.matches($0, reference: reference) }
                guard !matches.isEmpty else { throw ThemeError.invalid("安装配置引用了缺失素材：\(filename(reference))。") }
                choices[key, default: [:]][.normal, default: []] += matches
            }
        }
        let declaredAssets = Set(choices.values.flatMap { $0[.normal] ?? [] })
        for asset in assets where !declaredAssets.contains(asset) {
            let stem = URL(fileURLWithPath: filename(asset)).deletingPathExtension().lastPathComponent.lowercased()
            var assigned = false
            for key in aliases.keys.sorted() {
                var bases = aliases[key]! + (declarations[key] ?? []).map { URL(fileURLWithPath: filename($0)).deletingPathExtension().lastPathComponent.lowercased() }
                bases = Array(Set(bases))
                for base in bases {
                    let suffix = stem == base ? "" : (stem.hasPrefix(base + "_") ? String(stem.dropFirst(base.count + 1)) : "?")
                    let motion: Motion?
                    switch suffix {
                    case "", "static", "loop", "normal": motion = .normal
                    case "press", "click", "down": motion = .press
                    case "hold", "held": motion = .hold
                    case "release", "up": motion = .release
                    case "idle": motion = .idle
                    default: motion = nil
                    }
                    if let motion { choices[key, default: [:]][motion, default: []].append(asset); assigned = true; break }
                }
                if assigned { break }
            }
        }
        func clip(_ asset: String) throws -> CursorClip {
            if let cached = decoded[asset] { return cached }
            let clip = try AnimationImport.read(files[asset]!, extension: URL(fileURLWithPath: asset).pathExtension.lowercased())
            decoded[asset] = clip; return clip
        }
        var roles: [CursorRole] = []
        for descriptor in CursorCatalog.all {
            guard let key = registry[descriptor.resource], let motions = choices[key], let normal = motions[.normal], !normal.isEmpty else { continue }
            var clips: [String: CursorClip] = [:], variants: [String: [CursorVariant]] = [:], selected: [String: String] = [:]
            for motion in Motion.allCases {
                let names = Array(Set(motions[motion] ?? [])).sorted()
                guard names.count <= 32 else { throw ThemeError.invalid("\(descriptor.title)的素材版本超过 32 套，请拆分安装包。") }
                for asset in names {
                    let decoded = try clip(asset); used.insert(asset)
                    variants[motion.rawValue, default: []].append(CursorVariant(id: asset,
                        name: "\(decoded.frames.count > 1 ? "动态" : "静态") · " + ((filenameCounts[filename(asset).lowercased()] ?? 0) > 1 ? asset : filename(asset)), clip: decoded))
                }
                if let first = variants[motion.rawValue]?.first { clips[motion.rawValue] = first.clip; selected[motion.rawValue] = first.id }
            }
            roles.append(CursorRole(id: descriptor.id, name: descriptor.title, clips: clips, variants: variants, selectedVariants: selected))
        }
        // Unknown filenames remain editable, mixable and exportable. Do not
        // guess a system cursor or quietly discard a successfully decoded file.
        for asset in assets where !used.contains(asset) {
            let id = SHA256.hash(data: Data(asset.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            roles.append(CursorRole(id: "com.apple.gallery.Imported." + id, name: filename(asset), clips: [Motion.normal.rawValue: try clip(asset)]))
        }
        guard roles.count <= 80 else { throw ThemeError.invalid("光标角色和未分类素材超过 80 项，请拆分安装包。") }
        let result = GalleryTheme(name: scheme, author: "用户本地导入", roles: roles)
        try result.validate(); return result
    }
    private static func filename(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? path }
    private static func matches(_ asset: String, reference: String) -> Bool {
        let a = filename(asset).lowercased(), r = filename(reference).lowercased()
        return a == r || a.hasSuffix("." + r) || a.hasSuffix("-" + r)
    }
    private static func parseINF(_ data: Data) throws -> (name: String?, roles: [String: [String]]) {
        guard data.count <= 1_000_000 else { throw ThemeError.invalid("安装配置超过 1 MB。") }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text: String?
        if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) ?? String(data: data, encoding: .windowsCP1252) }
        guard let text else { throw ThemeError.invalid("安装配置的文本编码无法识别。") }
        func fields(_ line: String, separator: Character) -> [String] {
            var quoted = false, current = "", values: [String] = []
            for char in line {
                if char == "\"" { quoted.toggle(); continue }
                if char == ";" && !quoted { break }
                if char == separator && !quoted { values.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(char) }
            }
            values.append(current.trimmingCharacters(in: .whitespaces)); return values
        }
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines)
        var section = "", strings: [String: String] = [:]
        for line in lines {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("[") { section = clean.lowercased(); continue }
            if section == "[strings]" {
                let pair = fields(line, separator: "=")
                if pair.count == 2 { strings[pair[0].lowercased()] = pair[1] }
            }
        }
        let variables = try NSRegularExpression(pattern: "%([^%]+)%")
        func expand(_ input: String) throws -> String {
            var result = input
            for _ in 0..<8 {
                guard result.count <= 4096 else { throw ThemeError.invalid("安装配置的字符串替换过长。") }
                var next = "", position = result.startIndex
                for match in variables.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
                    guard let range = Range(match.range, in: result), let key = Range(match.range(at: 1), in: result) else { continue }
                    let replacement = strings[String(result[key]).lowercased()] ?? String(result[range])
                    guard next.count + result[position..<range.lowerBound].count + replacement.count <= 4096 else {
                        throw ThemeError.invalid("安装配置的字符串替换过长。")
                    }
                    next += result[position..<range.lowerBound]; next += replacement; position = range.upperBound
                }
                next += result[position...]
                guard next.count <= 4096 else { throw ThemeError.invalid("安装配置的字符串替换过长。") }
                if next == result { return result }; result = next
            }
            return result
        }
        var roles: [String: [String]] = [:]
        for line in lines {
            let f = fields(line, separator: ",")
            if f.count >= 5, ["hkcu", "hklm"].contains(f[0].lowercased()), f[1].lowercased() == "control panel\\cursors",
               registry.values.contains(f[2].lowercased()) {
                let reference = try expand(f[4]); roles[f[2].lowercased(), default: []].append(reference)
            }
        }
        let title = try strings["scheme_name"].map(expand).flatMap { $0.isEmpty || $0.contains("%") ? nil : $0 }
        return (title, roles)
    }
}
