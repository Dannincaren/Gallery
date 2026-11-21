import Foundation
import Darwin

/// Read selected local data through one descriptor. Reject links/special files
/// before reading, and enforce the limit again while reading a growing file.
enum BoundedFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, limit > 0 else { throw invalid() }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { throw invalid() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { throw invalid() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw invalid() }
            data.append(chunk)
        }
        return data
    }
    private static func invalid() -> ThemeError { .invalid(L("文件为空、过大、不是普通文件或为符号链接。")) }
}
