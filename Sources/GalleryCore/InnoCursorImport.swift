import Foundation

/// A native helper reads Inno data; Windows installer code is never executed.
public enum InnoCursorImport {
    public static func recognizes(_ url: URL) throws -> Bool {
        guard url.pathExtension.lowercased() == "exe" else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let header = try handle.read(upToCount: 2_000_000) ?? Data()
        return header.starts(with: [0x4d, 0x5a]) && header.range(of: Data("Inno Setup Setup Data (".utf8)) != nil
    }
    public static func load(_ url: URL, helperURL: URL? = nil) throws -> [GalleryTheme] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= WindowsResources.maximumInstallerBytes else { throw ThemeError.invalid("安装包为空或超过 2 GB。") }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GalleryInno")
        guard let helper = helperURL ?? (FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : Bundle.main.url(forResource: "GalleryInno", withExtension: nil, subdirectory: "Helpers")),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ThemeError.invalid("已识别为 Inno Setup 安装包，但此应用包缺少解包组件。请使用包含 Inno 支持的完整 Gallery.app，或导入解压后的 CUR／ANI 文件夹。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Gallery-Inno-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process(), pipe = Pipe()
        process.executableURL = helper
        process.arguments = ["--gallery-cursors", "--silent", "--extract", "--output-dir", root.path, url.path]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close(); if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var diagnostics = Data()
        while let data = try pipe.fileHandleForReading.read(upToCount: 65536), !data.isEmpty {
            diagnostics.append(data)
            if diagnostics.count > 32000 { diagnostics = diagnostics.suffix(32000) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(data: diagnostics, encoding: .utf8) ?? "未知解包错误"
            throw ThemeError.invalid("Inno Setup 素材提取失败（可能为加密、损坏或尚未支持的版本）。\n" + String(reason.suffix(1600)))
        }
        return try themes(in: root, packageName: url.deletingPathExtension().lastPathComponent)
    }
    public static func themes(in root: URL, packageName: String) throws -> [GalleryTheme] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw ThemeError.invalid("无法读取已提取的光标。") }
        var groups: [URL: [URL]] = [:], configs: [URL] = [], count = 0, bytes = 0
        for case let url as URL in iterator {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isSymbolicLink != true else { throw ThemeError.invalid("安装包含有无效的符号链接。") }
            guard info.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["cur", "ani", "inf"].contains(ext) else { continue }
            let size = info.fileSize ?? 0; bytes += size; count += 1
            guard size <= 40_000_000, bytes <= 160_000_000, count <= 1000 else { throw ThemeError.invalid("提取的光标素材过多，请拆分套装。") }
            if ext == "inf" { if size <= 1_000_000 { configs.append(url) }; continue }
            groups[url.deletingLastPathComponent(), default: []].append(url)
        }
        guard !groups.isEmpty else { throw ThemeError.invalid("安装包中未找到 CUR／ANI 光标；壁纸、应用图标和程序不会导入。") }
        guard groups.count <= 80 else { throw ThemeError.invalid("安装包中的光标套装超过 80 套，请拆分导入。") }
        return try groups.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { directory in
            let cursors = groups[directory]!.sorted { $0.path < $1.path }
            var files: [String: Data] = [:], total = 0
            let infs = configs.filter { $0.deletingLastPathComponent() == directory || $0.deletingLastPathComponent() == directory.deletingLastPathComponent() }
            for url in cursors + infs {
                let data = try Data(contentsOf: url); total += data.count
                guard total <= 80_000_000 else { throw ThemeError.invalid("单套光标素材超过 80 MB。") }
                files[url.lastPathComponent] = data
            }
            var label = directory.lastPathComponent
            if label.lowercased().hasPrefix("cursors") {
                let variant = label.lowercased().contains("minimal") ? " · 简约" : ""
                label = directory.deletingLastPathComponent().lastPathComponent + variant
            }
            let name = groups.count == 1 || label.caseInsensitiveCompare(packageName) == .orderedSame ? packageName : packageName + " · " + label
            return try WindowsThemeImport.theme(files: files, name: name)
        }
    }
}
