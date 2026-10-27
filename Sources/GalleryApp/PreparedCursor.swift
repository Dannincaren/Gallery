import AppKit
import GalleryCore

struct PreparedFrame {
    let image: CGImage
    let data: Data
}
struct PreparedClip {
    let clip: CursorClip
    let frames: [PreparedFrame]
}
@MainActor
final class PreparedCursors {
    private var decoded: [Data: CGImage] = [:]
    private var clips: [String: [Motion: PreparedClip]] = [:]
    init(roles: [CursorRole]) throws {
        for role in roles where !role.usesNative {
            var prepared: [Motion: PreparedClip] = [:]
            for motion in Motion.allCases {
                guard let clip = role.clip(motion) else { continue }
                let frames = try clip.frames.map { data -> PreparedFrame in
                    if decoded[data] == nil {
                        let image = try CursorImages.bitmap(data)
                        // Decode before the first click rather than in NSImage's
                        // lazy drawing path on the event delivery thread.
                        let context = CGContext(data: nil, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        decoded[data] = context.makeImage()!
                    }
                    return PreparedFrame(image: decoded[data]!, data: data)
                }
                prepared[motion] = PreparedClip(clip: clip, frames: frames)
            }
            clips[role.id] = prepared
        }
    }
    func clip(role: String, motion: Motion) -> PreparedClip? { clips[role]?[motion] }
}
