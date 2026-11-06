import Foundation
import Compression

/// Reads .NET single-file bundle manifests, never executing an apphost or DLL.
/// Layout: dotnet/runtime HostModel/Bundle Manifest and FileEntry (v1, v2, v6).
enum DotNetBundle {
    static let signature = Data([0x8b,0x12,0x02,0xb9,0x6a,0x61,0x20,0x38,0x72,0x7b,0x93,0x02,0x14,0xd7,0xa0,0x32,
                                 0x13,0xf5,0xb9,0xe6,0xef,0xae,0x33,0x18,0xee,0x3b,0x2d,0xce,0x24,0xb3,0x6a,0xae])
    private struct Entry {
        let offset: Int, size: Int, compressed: Int
        let kind: UInt8
        let name: String
        var framework: Bool { name.hasPrefix("System.") || name.hasPrefix("Microsoft.") }
    }
    private struct Reader {
        let data: Data
        var offset: Int
        mutating func number(_ bytes: Int) throws -> Int {
            guard offset >= 0, bytes <= data.count - offset else { throw invalid() }
            var value: UInt64 = 0
            for i in 0..<bytes { value |= UInt64(data[offset + i]) << (i * 8) }
            offset += bytes
            guard let result = Int(exactly: value) else { throw invalid() }
            return result
        }
        mutating func string() throws -> String {
            var length = 0, shift = 0
            while true {
                let byte = try number(1)
                guard shift <= 28 else { throw invalid() }
                length |= (byte & 127) << shift
                if byte & 128 == 0 { break }; shift += 7
            }
            guard length > 0, length <= 4096, length <= data.count - offset,
                  let value = String(data: data.subdata(in: offset..<offset + length), encoding: .utf8) else { throw invalid() }
            offset += length; return value
        }
    }
    private static func invalid() -> ThemeError { .invalid(L(".NET 单文件封装已损坏、越界或版本尚未支持。")) }
    static func resources(in data: Data) throws -> [WindowsResources]? {
        guard let marker = data.range(of: signature) else { return nil }
        guard data.starts(with: [0x4d, 0x5a]), marker.lowerBound >= 8 else { throw invalid() }
        var pointer = Reader(data: data, offset: marker.lowerBound - 8)
        let header = try pointer.number(8)
        guard header > 0, header <= data.count - 12 else { throw invalid() }
        var reader = Reader(data: data, offset: header)
        let version = try reader.number(4), minor = try reader.number(4), count = try reader.number(4)
        guard [1, 2, 6].contains(version), minor == 0, (1...10000).contains(count) else { throw invalid() }
        _ = try reader.string()
        if version >= 2 { for _ in 0..<5 { _ = try reader.number(8) } }
        var entries: [Entry] = [], names = Set<String>()
        for _ in 0..<count {
            let offset = try reader.number(8), size = try reader.number(8)
            let compressed = version >= 6 ? try reader.number(8) : 0
            let kind = try reader.number(1), name = try reader.string()
            let stored = compressed > 0 ? compressed : size
            let components = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains(":"), !components.contains(".."),
                  offset >= 0, offset <= header, stored <= header - offset,
                  !name.contains("\0"), names.insert(name).inserted else { throw invalid() }
            if kind == 1, ["dll", "exe"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                entries.append(Entry(offset: offset, size: size, compressed: compressed, kind: UInt8(kind), name: name))
            }
        }
        // Application assemblies precede platform libraries; only examine the
        // latter if no application assembly contains cursor material.
        entries.sort { ($0.framework ? 1 : 0) < ($1.framework ? 1 : 0) }
        var total = 0, result: [WindowsResources] = [], identities: [[String: Data]] = []
        for entry in entries {
            if entry.framework && !result.isEmpty { continue }
            guard entry.size > 0, entry.size <= 80_000_000, total <= 160_000_000 - entry.size else {
                throw ThemeError.invalid(L("内嵌程序集超过导入大小上限，请导入解压后的光标素材。"))
            }
            total += entry.size
            let payload = data.subdata(in: entry.offset..<entry.offset + (entry.compressed > 0 ? entry.compressed : entry.size))
            let assembly = entry.compressed > 0 ? try inflate(payload, size: entry.size) : payload
            guard let resources = try? WindowsResources(data: assembly),
                  resources.entries.keys.contains(where: { ["cur", "ani"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) else { continue }
            let files = resources.entries.mapValues { assembly.subdata(in: $0) }
            // ReadyToRun bundles can include the same assets twice.
            if identities.contains(where: { $0 == files }) { continue }
            identities.append(files); result.append(resources)
            guard result.count <= 80 else { throw ThemeError.invalid(L("内嵌光标套装超过 80 套，请拆分导入。")) }
        }
        guard !result.isEmpty else { throw ThemeError.invalid(L(".NET 单文件封装中未找到可读取的 CUR／ANI 光标。")) }
        return result
    }
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        let pointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard compression_stream_init(pointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw invalid() }
        defer { compression_stream_destroy(pointer) }
        var result = Data(count: size + 1)
        let valid = data.withUnsafeBytes { source in result.withUnsafeMutableBytes { destination -> Bool in
            pointer.pointee.src_ptr = source.baseAddress!.assumingMemoryBound(to: UInt8.self); pointer.pointee.src_size = data.count
            pointer.pointee.dst_ptr = destination.baseAddress!.assumingMemoryBound(to: UInt8.self); pointer.pointee.dst_size = size + 1
            let status = compression_stream_process(pointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            return status == COMPRESSION_STATUS_END && pointer.pointee.src_size == 0 && pointer.pointee.dst_size == 1
        } }
        guard valid else { throw invalid() }
        result.removeLast(); return result
    }
}
