import AppKit

enum EditorImageCache {
    private static let cache: NSCache<NSData, NSImage> = {
        let value = NSCache<NSData, NSImage>(); value.totalCostLimit = 64 * 1024 * 1024; return value
    }()
    static func image(_ data: Data) -> NSImage? {
        if let cached = cache.object(forKey: data as NSData) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: data as NSData, cost: max(data.count, Int(image.size.width * image.size.height * 4)))
        return image
    }
}
