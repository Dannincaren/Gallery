import AppKit
import GalleryCore

enum Demo {
    static func makeTheme() -> GalleryTheme {
        let roles = [("com.apple.coregraphics.Arrow", "箭头"), ("com.apple.coregraphics.IBeam", "文本"),
                     ("com.apple.cursor.2", "链接"), ("com.apple.cursor.13", "指向手势")]
        return GalleryTheme(name: "Gallery · 光晕", author: "Gallery", roles: roles.map { id, name in
            let clips = Dictionary(uniqueKeysWithValues: Motion.allCases.map { motion in
                let count = motion == .normal ? 1 : 20
                let frames = (0..<count).map { index -> Data in
                    let image = NSImage(size: NSSize(width: 96, height: 96), flipped: true) { _ in
                        let phase = Double(index) / Double(count)
                        if motion != .normal {
                            let pulse = motion == .idle ? 0.5 + 0.5 * sin(phase * .pi * 2) : phase
                            let radius = motion == .hold ? 22.0 : 10 + pulse * 22
                            let color: NSColor = motion == .idle ? .systemTeal : .systemBlue
                            color.withAlphaComponent(motion == .release ? 0.45 * (1 - phase) : 0.2).setFill()
                            NSBezierPath(ovalIn: NSRect(x: 30 - radius, y: 30 - radius, width: radius * 2, height: radius * 2)).fill()
                            color.withAlphaComponent(0.8).setStroke()
                            let ring = NSBezierPath(ovalIn: NSRect(x: 30 - radius, y: 30 - radius, width: radius * 2, height: radius * 2))
                            ring.lineWidth = 2; ring.stroke()
                        }
                        let path = NSBezierPath()
                        if name == "文本" {
                            path.move(to: NSPoint(x: 40, y: 18)); path.line(to: NSPoint(x: 56, y: 18))
                            path.move(to: NSPoint(x: 48, y: 18)); path.line(to: NSPoint(x: 48, y: 77))
                            path.move(to: NSPoint(x: 40, y: 77)); path.line(to: NSPoint(x: 56, y: 77))
                            NSColor.white.setStroke(); path.lineWidth = 7; path.stroke()
                            NSColor(calibratedWhite: 0.12, alpha: 1).setStroke(); path.lineWidth = 3; path.stroke()
                        } else {
                            path.move(to: NSPoint(x: 30, y: 30)); path.line(to: NSPoint(x: 30, y: 76))
                            path.line(to: NSPoint(x: 41, y: 64)); path.line(to: NSPoint(x: 50, y: 82))
                            path.line(to: NSPoint(x: 59, y: 77)); path.line(to: NSPoint(x: 50, y: 59))
                            path.line(to: NSPoint(x: 67, y: 59)); path.close()
                            NSColor.white.setStroke(); path.lineWidth = 5; path.lineJoinStyle = .round; path.stroke()
                            (name == "箭头" ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.systemBlue).setFill(); path.fill()
                        }
                        return true
                    }
                    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    return rep.representation(using: .png, properties: [:])!
                }
                let clip = CursorClip(frames: frames, frameDuration: motion == .idle ? 0.07 : 0.025,
                                      hotX: name == "文本" ? 16 : 10, hotY: name == "文本" ? 16 : 10)
                return (motion.rawValue, clip)
            })
            return CursorRole(id: id, name: name, clips: clips)
        })
    }
}
