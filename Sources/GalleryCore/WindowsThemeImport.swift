import Foundation
import CoreFoundation
import CryptoKit

/// Reads embedded files and INF declarations as data. No installer, registry
/// command, DLL or INF action is executed.
public enum WindowsThemeImport {
    public static func load(_ url: URL) throws -> GalleryTheme {
        guard let first = try candidates(url).first else { throw ThemeError.invalid(L("安装包中没有可导入的光标。")) }
        return first
    }
    public static func candidates(_ url: URL) throws -> [GalleryTheme] {
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { return try loadDirectory(url) }
        if url.pathExtension.lowercased() == "inf" { return try loadDirectory(url.deletingLastPathComponent(), selectedINF: url.lastPathComponent) }
        if ["cur", "ani"].contains(url.pathExtension.lowercased()) {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 40_000_000 else { throw ThemeError.invalid(L("单个光标文件超过 40 MB。")) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            var imported = try theme(files: [url.lastPathComponent: data], name: url.deletingPathExtension().lastPathComponent)
            if imported.roles.allSatisfy({ $0.id.hasPrefix("com.apple.gallery.Imported.") }), let role = imported.roles.first {
                imported.roles = [CursorRole(id: "com.apple.coregraphics.Arrow", name: CursorCatalog.title("com.apple.coregraphics.Arrow"), clips: role.clips)]
            }
            return [imported]
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= WindowsResources.maximumInstallerBytes else { throw ThemeError.invalid(L("安装包超过 2 GB。")) }
        if url.pathExtension.lowercased() == "zip" { return try loadZIP(url) }
        if try InnoCursorImport.recognizes(url) { return try InnoCursorImport.load(url) }
        let packages: [WindowsResources]
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            packages = try DotNetBundle.resources(in: data) ?? [WindowsResources(data: data)]
        }
        catch {
            if (try? CursorZIP(url)) != nil { return try loadZIP(url) }
            throw ThemeError.invalid(L("无法直接读取此 EXE 的内嵌光标。支持 .NET、.NET 单文件、Inno Setup 和含 ZIP 素材的封装；其他形式请先解压出 CUR／ANI。\n\(error.localizedDescription)"))
        }
        return try packages.flatMap { resources in
        if resources.resource(suffix: "normal.cur") != nil,
           resources.entries.keys.contains(where: { $0.hasPrefix("PRTS-Replica-") }) { return [try resources.theme()] }
        // Bound only extracted cursor/config data, not wallpaper or icon payloads.
        var files: [String: Data] = [:], total = 0
        for name in resources.entries.keys.sorted() {
            if name.lowercased().hasSuffix(".inf"), resources.entries[name]!.count > 1_000_000 { continue }
            total += resources.entries[name]!.count
            guard total <= 80_000_000 else { throw ThemeError.invalid(L("安装包中的光标素材超过 80 MB，请拆分主题。")) }
            files[name] = resources.resource(named: name)
        }
        return try groupedThemes(files: files, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private static func loadDirectory(_ url: URL, selectedINF: String? = nil) throws -> [GalleryTheme] {
        let base = url.standardizedFileURL
        var scanError: Error?
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw ThemeError.invalid(L("无法读取素材文件夹。"))
        }
        var files: [String: Data] = [:], installers: [URL] = [], count = 0, total = 0
        for case let file as URL in iterator {
            count += 1
            guard count <= 50000 else { throw ThemeError.invalid(L("文件夹内容过多，请选择光标素材子文件夹。")) }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if info.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard info.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            if ext == "exe" { installers.append(file); continue }
            guard ["cur", "ani", "inf"].contains(ext) else { continue }
            if ext == "inf", let selectedINF, file.standardizedFileURL != base.appendingPathComponent(selectedINF) { continue }
            let size = info.fileSize ?? 0
            if ext == "inf", size > 1_000_000 {
                if selectedINF != nil { throw ThemeError.invalid(L("安装配置超过 1 MB。")) }
                continue
            }
            total += size
            guard size <= 40_000_000, total <= 80_000_000, files.count < 1000 else { throw ThemeError.invalid(L("文件夹的光标素材过多或超过 80 MB，请拆分主题。")) }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(base.path + "/") else { throw ThemeError.invalid(L("素材不在选中的文件夹内。")) }
            files[String(path.dropFirst(base.path.count + 1))] = try Data(contentsOf: file)
        }
        if let scanError { throw scanError }
        if !files.keys.contains(where: { ["cur", "ani"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
            if let prts = installers.first(where: { $0.lastPathComponent.lowercased() == "prts-setup.exe" }) { return try candidates(prts) }
            if installers.count == 1 { return try candidates(installers[0]) }
            throw ThemeError.invalid(L("文件夹中没有 CUR／ANI 光标。若有多个 EXE，请直接选择包含素材的安装器。"))
        }
        return try groupedThemes(files: files, name: base.lastPathComponent)
    }

    private static func loadZIP(_ url: URL) throws -> [GalleryTheme] {
        let archive = try CursorZIP(url)
        let assets = archive.entries.filter { ["cur", "ani", "inf"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
        let hasCursors = assets.contains { ["cur", "ani"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
        let installers = archive.entries.filter { $0.name.lowercased().hasSuffix(".exe") }
        let installer = installers.first(where: { filename($0.name).lowercased() == "prts-setup.exe" })
            ?? (installers.count == 1 ? installers.first : nil)
        func read(_ entry: CursorZIP.Entry, limit: Int, to destination: URL? = nil) throws -> Data {
            guard !entry.link, entry.flags & 1 == 0 else { throw ThemeError.invalid(L("ZIP 中的光标为链接或已加密，请先解压后导入。")) }
            if [0, 8].contains(entry.method) { return try archive.read(entry, limit: limit, to: destination) }
            return try unzip(url, arguments: ["-p"], member: entry.name, limit: limit, to: destination)
        }
        if !hasCursors, let setup = installer {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent(filename(setup.name))
            _ = try read(setup, limit: WindowsResources.maximumInstallerBytes, to: target)
            return try candidates(target)
        }
        guard hasCursors, assets.count <= 1000, Set(assets.map(\.name)).count == assets.count else {
            throw ThemeError.invalid(L("ZIP 中没有可识别的光标，或包含过多／重名文件。请提供 CUR、ANI 和安装 INF，或包含素材的 EXE。"))
        }
        var files: [String: Data] = [:], total = 0
        for entry in assets.sorted(by: { $0.name < $1.name }) {
            let data: Data
            if entry.name.lowercased().hasSuffix(".inf") {
                guard entry.size <= 1_000_000, let configuration = try? read(entry, limit: 1_000_000) else { continue }
                data = configuration
            } else { data = try read(entry, limit: 40_000_000) }
            total += data.count
            guard total <= 80_000_000 else { throw ThemeError.invalid(L("ZIP 展开的光标素材超过 80 MB。")) }
            files[entry.name] = data
        }
        return try groupedThemes(files: files, name: url.deletingPathExtension().lastPathComponent)
    }
    private static func unzip(_ url: URL, arguments: [String], member: String? = nil, limit: Int, to destination: URL? = nil) throws -> Data {
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
        let output: FileHandle?
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ThemeError.invalid(L("无法创建临时安装包。")) }
            output = try FileHandle(forWritingTo: destination)
        } else { output = nil }
        defer { try? output?.close() }
        try process.run()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        var result = Data(), total = 0
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            total += chunk.count
            guard total <= limit else {
                throw ThemeError.invalid(destination == nil ? L("ZIP 展开数据超过限制。") : L("ZIP 内安装包超过 2 GB。"))
            }
            if let output { try output.write(contentsOf: chunk) }
            else { result.append(chunk) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeError.invalid(L("ZIP 文件损坏或成员无法读取。")) }
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
    private static func groupedThemes(files: [String: Data], name: String) throws -> [GalleryTheme] {
        let configured = try files.keys.filter { $0.lowercased().hasSuffix(".inf") }.filter { !(try parseINF(files[$0]!)).roles.isEmpty }
        let directories = Set(configured.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).deletingLastPathComponent })
        let roots = directories.filter { directory in
            !directory.isEmpty && !directories.contains { $0 != directory && (directory.hasPrefix($0 + "/") || $0.isEmpty) }
        }.sorted()
        let cursors = files.keys.filter { ["cur", "ani"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        // Split independent configured sets only when every cursor belongs to
        // one of them. Otherwise preserve the existing all-materials import.
        guard roots.count > 1, cursors.allSatisfy({ file in roots.contains { file.replacingOccurrences(of: "\\", with: "/").hasPrefix($0 + "/") } }) else {
            return [try theme(files: files, name: name)]
        }
        guard roots.count <= 80 else { throw ThemeError.invalid(L("光标套装超过 80 套，请拆分导入。")) }
        return try roots.map { root in
            let selected = files.filter { $0.key.replacingOccurrences(of: "\\", with: "/").hasPrefix(root + "/") }
            return try theme(files: selected, name: name + " · " + (root as NSString).lastPathComponent)
        }
    }
    public static func theme(files: [String: Data], name: String) throws -> GalleryTheme {
        let assets = files.keys.filter { ["cur", "ani"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.sorted()
        guard !assets.isEmpty, assets.count <= 1000 else { throw ThemeError.invalid(L("没有可读取的 CUR／ANI 素材，或素材数量过多。")) }
        var declarations: [String: [String]] = [:], scheme = name
        for inf in files.keys.filter({ $0.lowercased().hasSuffix(".inf") }).sorted() {
            guard files[inf]!.count <= 1_000_000 else { continue }
            let parsed = try parseINF(files[inf]!)
            guard !parsed.roles.isEmpty else { continue }
            if let title = parsed.name { scheme = title }
            for (key, values) in parsed.roles { declarations[key, default: []] += values }
        }
        let filenameCounts = Dictionary(grouping: assets, by: { filename($0).lowercased() }).mapValues(\.count)
        var choices: [String: [Motion: [String]]] = [:], used = Set<String>(), decoded: [String: CursorClip] = [:]
        for (key, names) in declarations {
            for reference in names {
                let matches = assets.filter { Self.matches($0, reference: reference) }
                guard !matches.isEmpty else { throw ThemeError.invalid(L("安装配置引用了缺失素材：\(filename(reference))。")) }
                choices[key, default: [:]][.normal, default: []] += matches
            }
        }
        let declaredAssets = Set(choices.values.flatMap { $0[.normal] ?? [] })
        for asset in assets where !declaredAssets.contains(asset) {
            let stem = URL(fileURLWithPath: filename(asset)).deletingPathExtension().lastPathComponent.lowercased()
            // Common seventeen-role sets call background activity "busy" and
            // the blocking wait cursor "wait". Preserve their distinct roles.
            if stem == "busy", assets.contains(where: { URL(fileURLWithPath: filename($0)).deletingPathExtension().lastPathComponent.lowercased() == "wait" }) {
                choices["appstarting", default: [:]][.normal, default: []].append(asset); continue
            }
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
            let clip: CursorClip
            do { clip = try AnimationImport.read(files[asset]!, extension: URL(fileURLWithPath: asset).pathExtension.lowercased()) }
            catch { throw ThemeError.invalid(L("无法读取素材「\(asset)」：\(error.localizedDescription)")) }
            decoded[asset] = clip; return clip
        }
        var roles: [CursorRole] = []
        for descriptor in CursorCatalog.all {
            guard let key = registry[descriptor.resource], let motions = choices[key], let normal = motions[.normal], !normal.isEmpty else { continue }
            var clips: [String: CursorClip] = [:], variants: [String: [CursorVariant]] = [:], selected: [String: String] = [:]
            for motion in Motion.allCases {
                let names = Array(Set(motions[motion] ?? [])).sorted()
                guard names.count <= 32 else { throw ThemeError.invalid(L("\(GalleryLocalization.label(descriptor.title))的素材版本超过 32 套，请拆分安装包。")) }
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
        guard roles.count <= 80 else { throw ThemeError.invalid(L("光标角色和未分类素材超过 80 项，请拆分安装包。")) }
        let result = GalleryTheme(name: scheme, author: "用户本地导入", roles: roles)
        try result.validate(); return result
    }
    private static func filename(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? path }
    private static func matches(_ asset: String, reference: String) -> Bool {
        let a = filename(asset).lowercased(), r = filename(reference).lowercased()
        return a == r || a.hasSuffix("." + r) || a.hasSuffix("-" + r)
    }
    private static func parseINF(_ data: Data) throws -> (name: String?, roles: [String: [String]]) {
        guard data.count <= 1_000_000 else { throw ThemeError.invalid(L("安装配置超过 1 MB。")) }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text: String?
        if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) ?? String(data: data, encoding: .windowsCP1252) }
        guard let text else { throw ThemeError.invalid(L("安装配置的文本编码无法识别。")) }
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
                guard result.count <= 4096 else { throw ThemeError.invalid(L("安装配置的字符串替换过长。")) }
                var next = "", position = result.startIndex
                for match in variables.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
                    guard let range = Range(match.range, in: result), let key = Range(match.range(at: 1), in: result) else { continue }
                    let replacement = strings[String(result[key]).lowercased()] ?? String(result[range])
                    guard next.count + result[position..<range.lowerBound].count + replacement.count <= 4096 else {
                        throw ThemeError.invalid(L("安装配置的字符串替换过长。"))
                    }
                    next += result[position..<range.lowerBound]; next += replacement; position = range.upperBound
                }
                next += result[position...]
                guard next.count <= 4096 else { throw ThemeError.invalid(L("安装配置的字符串替换过长。")) }
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
        guard !roles.isEmpty else { return (nil, [:]) }
        let title = try strings["scheme_name"].map(expand).flatMap { $0.isEmpty || $0.contains("%") ? nil : $0 }
        return (title, roles)
    }
}
