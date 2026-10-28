import Foundation

/// Advance the clock across equal frames without changing their duration.
/// Precomputed once; playback only performs an array lookup per visible change.
public struct FrameRunSchedule {
    private var next: [Int?]
    private var loop: [Int?]
    public var isStatic: Bool { loop.first.flatMap { $0 } == nil }
    public init<T: Equatable>(_ frames: [T]) {
        let count = frames.count
        next = Array(repeating: nil, count: count)
        if count > 1 {
            for i in stride(from: count - 2, through: 0, by: -1) {
                next[i] = frames[i] == frames[i + 1] ? next[i + 1] : i + 1
            }
        }
        let wrap = frames.last.flatMap { last in frames.firstIndex { $0 != last } }.map { count + $0 }
        loop = next.map { $0 ?? wrap }
    }
    public func nextChange(after step: Int, looping: Bool) -> Int? {
        guard !next.isEmpty else { return nil }
        let step = max(0, step)
        if !looping { return step < next.count ? next[step] : nil }
        let index = step % next.count
        return loop[index].map { step - index + $0 }
    }
}
