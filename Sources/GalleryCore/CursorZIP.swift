import Foundation
import CoreFoundation
import Compression

/// Central-directory reader for cursor packages. No archive path is extracted;
/// only requested contents are decoded, with bounded streaming and CRC checks.
struct CursorZIP {
    struct Entry {
        let name: String, offset: Int, compressed: Int, size: Int, method: Int, flags: Int, crc: UInt32, link: Bool
    }
    let entries: [Entry]
    private let data: Data
    private let directory: Int
    private static func invalid(_ detail: String = "文件已损坏或越界") -> ThemeError { .invalid("ZIP \(detail)。") }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) throws -> Int {
        guard offset >= 0, offset <= data.count, count <= data.count - offset else { throw invalid() }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(data[offset + i]) << (i * 8) }
        guard let result = Int(exactly: value) else { throw invalid() }; return result
    }
    init(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22, data.count <= WindowsResources.maximumInstallerBytes else { throw Self.invalid("为空、过小或超过 2 GB") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try Self.number(data, i, 4) == 0x06054b50, try Self.number(data, i + 20, 2) == data.count - i - 22 { end = i; break }
        }
        guard let end, try Self.number(data, end + 4, 2) == 0, try Self.number(data, end + 6, 2) == 0 else { throw Self.invalid("不支持分卷或目录无效") }
        var directoryEnd = end
        var count = try Self.number(data, end + 10, 2), length = try Self.number(data, end + 12, 4), directory = try Self.number(data, end + 16, 4)
        if count == 0xffff || length == 0xffffffff || directory == 0xffffffff {
            guard end >= 20, try Self.number(data, end - 20, 4) == 0x07064b50,
                  try Self.number(data, end - 16, 4) == 0, try Self.number(data, end - 4, 4) == 1 else { throw Self.invalid("ZIP64 定位信息无效") }
            let header = try Self.number(data, end - 12, 8)
            guard try Self.number(data, header, 4) == 0x06064b50,
                  try Self.number(data, header + 16, 4) == 0, try Self.number(data, header + 20, 4) == 0 else { throw Self.invalid() }
            count = try Self.number(data, header + 32, 8); length = try Self.number(data, header + 40, 8); directory = try Self.number(data, header + 48, 8)
            directoryEnd = header
        }
        guard count <= 50000, directory <= end, length <= end - directory else { throw Self.invalid("文件数量过多或目录越界") }
        var adjustment = 0
        if count > 0, try Self.number(data, directory, 4) != 0x02014b50 {
            // A ZIP self-extractor can prepend an apphost without rewriting
            // the original archive's relative offsets.
            let actual = directoryEnd - length
            guard actual >= directory, try Self.number(data, actual, 4) == 0x02014b50 else { throw Self.invalid() }
            adjustment = actual - directory; directory = actual
        }
        var p = directory, entries: [Entry] = []
        for _ in 0..<count {
            guard p <= directory + length - 46, try Self.number(data, p, 4) == 0x02014b50 else { throw Self.invalid() }
            let flags = try Self.number(data, p + 8, 2), method = try Self.number(data, p + 10, 2), crc = try Self.number(data, p + 16, 4)
            var compressed = try Self.number(data, p + 20, 4), size = try Self.number(data, p + 24, 4), offset = try Self.number(data, p + 42, 4)
            let nameLength = try Self.number(data, p + 28, 2), extraLength = try Self.number(data, p + 30, 2), comment = try Self.number(data, p + 32, 2)
            guard nameLength > 0, nameLength <= 4096, nameLength + extraLength + comment <= directory + length - p - 46,
                  try Self.number(data, p + 34, 2) == 0 else { throw Self.invalid() }
            let rawName = data.subdata(in: p + 46..<p + 46 + nameLength)
            var unicode: String?, extra = p + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra < extraEnd {
                guard extraEnd - extra >= 4 else { throw Self.invalid() }
                let tag = try Self.number(data, extra, 2), bytes = try Self.number(data, extra + 2, 2); extra += 4
                guard bytes <= extraEnd - extra else { throw Self.invalid() }
                if tag == 1 {
                    var q = extra
                    for field in 0..<3 {
                        let needed = field == 0 ? size == 0xffffffff : field == 1 ? compressed == 0xffffffff : offset == 0xffffffff
                        if needed {
                            guard q + 8 <= extra + bytes else { throw Self.invalid() }
                            let value = try Self.number(data, q, 8); q += 8
                            if field == 0 { size = value } else if field == 1 { compressed = value } else { offset = value }
                        }
                    }
                } else if tag == 0x7075, bytes >= 5, data[extra] == 1, UInt32(try Self.number(data, extra + 1, 4)) == Self.crc32(rawName) {
                    unicode = String(data: data.subdata(in: extra + 5..<extra + bytes), encoding: .utf8)
                }
                extra += bytes
            }
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
            let decoded = unicode ?? String(data: rawName, encoding: .utf8) ?? (flags & 0x800 == 0 ? String(data: rawName, encoding: gb) ?? String(data: rawName, encoding: dos) : nil)
            guard let decoded, !decoded.contains("\0") else { throw Self.invalid("文件名编码无法识别") }
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            guard !name.hasPrefix("/"), !name.contains(":"), !name.split(separator: "/").contains(".."),
                  offset <= directory, compressed <= directory - offset else { throw Self.invalid("文件路径或数据范围无效") }
            let mode = try Self.number(data, p + 38, 4) >> 16
            guard offset <= directory - adjustment else { throw Self.invalid() }
            offset += adjustment
            entries.append(Entry(name: name, offset: offset, compressed: compressed, size: size, method: method, flags: flags, crc: UInt32(crc), link: mode & 0xf000 == 0xa000))
            p += 46 + nameLength + extraLength + comment
        }
        self.data = data; self.directory = directory; self.entries = entries
    }
    func read(_ entry: Entry, limit: Int, to destination: URL? = nil) throws -> Data {
        guard !entry.link, entry.flags & 1 == 0 else { throw Self.invalid("所选素材为链接或已加密，请先解压后导入") }
        guard entry.size <= limit, [0, 8].contains(entry.method), try Self.number(data, entry.offset, 4) == 0x04034b50,
              try Self.number(data, entry.offset + 8, 2) == entry.method else { throw Self.invalid("压缩方式不受支持或素材超过限制") }
        let start = try entry.offset + 30 + Self.number(data, entry.offset + 26, 2) + Self.number(data, entry.offset + 28, 2)
        guard start <= directory, entry.compressed <= directory - start else { throw Self.invalid() }
        var result = Data(), produced = 0, crc = UInt32.max
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        let output: FileHandle?
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw Self.invalid("无法创建临时文件") }
            output = try FileHandle(forWritingTo: destination)
        } else { output = nil }
        defer { try? output?.close() }
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            guard bytes.count <= entry.size - produced, ProcessInfo.processInfo.systemUptime <= deadline else { throw Self.invalid("解压大小异常或耗时过长") }
            crc = Self.updateCRC(crc, bytes); produced += bytes.count
            if let output { try output.write(contentsOf: Data(bytes)) } else { result.append(contentsOf: bytes) }
        }
        try data.withUnsafeBytes { buffer in
            let source = UnsafeRawBufferPointer(rebasing: buffer[start..<start + entry.compressed])
            if entry.method == 0 {
                guard entry.compressed == entry.size else { throw Self.invalid() }
                for i in stride(from: 0, to: source.count, by: 65536) { try emit(UnsafeRawBufferPointer(rebasing: source[i..<min(source.count, i + 65536)])) }
            } else {
                let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
                defer { stream.deallocate() }
                guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Self.invalid() }
                defer { compression_stream_destroy(stream) }
                stream.pointee.src_ptr = source.baseAddress!.assumingMemoryBound(to: UInt8.self); stream.pointee.src_size = source.count
                var bytes = [UInt8](repeating: 0, count: 65536)
                try bytes.withUnsafeMutableBytes { destination in
                    while true {
                        let remaining = stream.pointee.src_size
                        stream.pointee.dst_ptr = destination.baseAddress!.assumingMemoryBound(to: UInt8.self); stream.pointee.dst_size = destination.count
                        let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        let count = destination.count - stream.pointee.dst_size
                        try emit(UnsafeRawBufferPointer(rebasing: destination[..<count]))
                        if status == COMPRESSION_STATUS_END { guard stream.pointee.src_size == 0 else { throw Self.invalid() }; break }
                        guard status == COMPRESSION_STATUS_OK, count > 0 || stream.pointee.src_size < remaining else { throw Self.invalid() }
                    }
                }
            }
        }
        guard produced == entry.size, ~crc == entry.crc else { throw Self.invalid("素材长度或 CRC 校验失败") }
        return result
    }
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }; return crc
    }
    private static func updateCRC(_ initial: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = initial
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }; return crc
    }
    private static func crc32(_ data: Data) -> UInt32 { ~data.withUnsafeBytes { updateCRC(UInt32.max, $0) } }
}
