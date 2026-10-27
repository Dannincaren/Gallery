import Foundation

public enum PRTSImport {
    public static func load(_ url: URL) throws -> GalleryTheme {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var input = url
        if url.pathExtension.lowercased() == "zip" {
            let extracted = directory.appendingPathComponent("PRTS-Setup.exe")
            FileManager.default.createFile(atPath: extracted.path, contents: nil)
            let output = try FileHandle(forWritingTo: extracted)
            defer { try? output.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", url.path, "*/PRTS-Setup.exe"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ThemeError.invalid("请使用完整的 PRTS Windows ZIP；其中应包含「程序文件/PRTS-Setup.exe」。也可以解压后直接选择这个 EXE。") }
            input = extracted
        }
        if input.lastPathComponent == "PRTS-Install.exe" {
            throw ThemeError.invalid("PRTS-Install.exe 只是安装入口，不包含动画。请选择完整 ZIP，或「程序文件」文件夹中的 PRTS-Setup.exe。")
        }
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        return try WindowsResources(data: data).theme()
    }
}
