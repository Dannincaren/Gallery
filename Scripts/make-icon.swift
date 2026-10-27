import AppKit

// Reuse Gallery's existing cursorarrow.rays symbol as a centered black mark.
// This stays deterministic and sharp at every Dock and Finder icon size.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let symbol = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 512, weight: .regular))!
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let t = NSAffineTransform(); t.scale(by: scale); t.concat()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 204, yRadius: 204).fill()
    let ratio = min(550 / symbol.size.width, 550 / symbol.size.height)
    let w = symbol.size.width * ratio, h = symbol.size.height * ratio
    let rect = NSRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h)
    symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: destination.appendingPathComponent(name)) }
}
