import Foundation
import GalleryCore

/// Accessed only on GalleryStore's serial file queue. Retain at most two recent
/// themes; file identity and modification metadata invalidate external edits.
final class ThemeReadCache: @unchecked Sendable {
    private struct Stamp: Equatable {
        let modified: Date, bytes: Int, inode: UInt64, device: UInt64
    }
    private struct Entry { let stamp: Stamp; let theme: GalleryTheme }
    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private let budget = 24 * 1024 * 1024
    private func stamp(_ url: URL) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date,
              let bytes = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { throw ThemeError.invalid(L("无法读取主题文件信息。")) }
        return Stamp(modified: date, bytes: bytes.intValue, inode: inode.uint64Value, device: device.uint64Value)
    }
    func canPrepare(_ url: URL) -> Bool { (try? stamp(url).bytes).map { $0 <= 20 * 1024 * 1024 } ?? false }
    func load(_ url: URL, read: (URL) throws -> GalleryTheme) throws -> GalleryTheme {
        guard let current = try? stamp(url) else {
            entries.removeValue(forKey: url); order.removeAll { $0 == url }
            return try read(url)
        }
        if let cached = entries[url], cached.stamp == current {
            order.removeAll { $0 == url }; order.append(url)
            return cached.theme
        }
        let theme = try read(url)
        if (try? stamp(url)) == current { insert(theme, url: url, stamp: current) }
        return theme
    }
    func remember(_ theme: GalleryTheme, at url: URL) {
        if let stamp = try? stamp(url) { insert(theme, url: url, stamp: stamp) }
    }
    private func insert(_ theme: GalleryTheme, url: URL, stamp: Stamp) {
        entries.removeValue(forKey: url); order.removeAll { $0 == url }
        guard stamp.bytes <= budget else { return }
        while entries.count >= 2 || entries.values.reduce(0, { $0 + $1.stamp.bytes }) + stamp.bytes > budget {
            guard !order.isEmpty else { break }
            entries.removeValue(forKey: order.removeFirst())
        }
        entries[url] = Entry(stamp: stamp, theme: theme); order.append(url)
    }
}
