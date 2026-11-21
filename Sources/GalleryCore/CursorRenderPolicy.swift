/// The geometry macOS actually displays. Nearby scale values that land on the
/// same point grid share a raster; source artwork and editor values stay exact.
public struct CursorRasterGeometry: Hashable, Sendable {
    public let width: Double, height: Double, hotX: Double, hotY: Double
    public init(_ clip: CursorClip, scale: Double = 1) {
        let aligned = clip.scaled(by: (scale * 10000).rounded() / 10000).alignedToPixels()
        width = aligned.width; height = aligned.height; hotX = aligned.hotX; hotY = aligned.hotY
    }
    public func applying(to clip: CursorClip) -> CursorClip {
        var result = clip
        result.width = width; result.height = height; result.hotX = hotX; result.hotY = hotY
        return result
    }
    public func rasterBytes(maximumScale: Int, frameCount: Int = 2) -> Int {
        let scales = (1...max(1, min(3, maximumScale))).reduce(0) { $0 + $1 * $1 }
        return Int(width) * Int(height) * 4 * frameCount * scales
    }
}

/// Expand only enough to keep one affordable active animation and a little
/// spare space. Oversized clips keep streaming within the same hard bound.
public struct CursorFrameCacheBudget: Equatable {
    public static let baseBytes = 32 * 1024 * 1024
    public static let maximumBytes = 48 * 1024 * 1024
    public let bytes: Int, count: Int
    public let retainsActiveClip: Bool
    public init(uniqueFrames: Int, bytesPerFrame: Int) {
        let frames = max(0, min(240, uniqueFrames)), spare = 4 * 1024 * 1024
        let cost = frames.multipliedReportingOverflow(by: max(0, bytesPerFrame))
        retainsActiveClip = !cost.overflow && cost.partialValue <= Self.maximumBytes - spare
        bytes = retainsActiveClip ? max(Self.baseBytes, cost.partialValue + spare) : Self.maximumBytes
        count = max(192, frames + 32)
    }
}

/// One outstanding image confirmation. Only repeated misses for the same
/// submission/seed back off; a new seed or submission can be checked at once.
public struct CursorConfirmationBackoff {
    public private(set) var revision: Int?
    public private(set) var deadline: Double?
    private var seed: Int32?
    private var attempt = 0
    private var probing = false
    public init() {}
    public mutating func reset() { self = CursorConfirmationBackoff() }
    public mutating func synchronize(revision: Int?, now: Double) {
        guard revision != self.revision else { return }
        reset(); self.revision = revision
        if revision != nil { deadline = now }
    }
    public func shouldProbe(seed: Int32, now: Double) -> Bool {
        guard revision != nil, !probing else { return false }
        return self.seed != seed || deadline.map { now >= $0 } == true
    }
    public mutating func beginProbe(seed: Int32) {
        self.seed = seed; probing = true; deadline = nil
    }
    public mutating func finishProbe(revision: Int, now: Double) {
        guard self.revision == revision else { return }
        probing = false
        deadline = now + 0.002 * Double(1 << attempt)
        attempt = min(3, attempt + 1)
    }
}
