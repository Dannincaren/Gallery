import AppKit
import GalleryCore

@main struct ImportPreviewHarness {
    static func main() async throws {
        let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 0, to: 1024, by: 8) { for y in stride(from: 0, to: 512, by: 8) where (x / 8 + y / 8) % 2 == 0 {
            context.fill(CGRect(x: x, y: y, width: 8, height: 8))
        } }
        let png = try CursorImages.png(context.makeImage()!)
        let frames = ImportPreviewFrames()
        guard let sharp = await frames.image(png, smoothEdges: false), let smooth = await frames.image(png),
              let reused = await frames.image(png, smoothEdges: false), sharp === reused,
              sharp.width == 384, sharp.height == 192, smooth.width == 384, smooth.height == 192 else {
            throw ThemeError.invalid("Preview cache did not keep separate bounded rasters")
        }
        func hasBlendedPixels(_ image: CGImage) -> Bool {
            let rgba = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            rgba.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let values = rgba.data!.assumingMemoryBound(to: UInt8.self)
            return stride(from: 0, to: image.width * image.height * 4, by: 4).contains { values[$0] > 0 && values[$0] < 255 }
        }
        guard !hasBlendedPixels(sharp), hasBlendedPixels(smooth), await frames.image(Data()) == nil else {
            throw ThemeError.invalid("Pixel preview was smoothed or invalid data was accepted")
        }
        await frames.clear()
        guard let reloaded = await frames.image(png, smoothEdges: false), reloaded !== sharp else {
            throw ThemeError.invalid("Closed preview retained its frame cache")
        }
        print("PASS bounded pixel preview uses nearest-neighbor downsampling, separate cache keys, invalid-data rejection and cache release")
    }
}
