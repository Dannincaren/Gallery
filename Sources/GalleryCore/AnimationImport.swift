import Foundation
import ImageIO
import CoreGraphics

public enum AnimationImport {
    private static func u16(_ d: Data, _ p: Int) throws -> Int {
        guard p >= 0, p + 2 <= d.count else { throw ThemeError.invalid("光标文件已截断。") }
        return Int(d[p]) | Int(d[p + 1]) << 8
    }
    private static func u32(_ d: Data, _ p: Int) throws -> Int {
        guard p >= 0, p + 4 <= d.count else { throw ThemeError.invalid("动画文件已截断。") }
        return (0..<4).reduce(0) { $0 | Int(d[p + $1]) << ($1 * 8) }
    }
    private static func cursor(_ data: Data) throws -> CursorClip {
        guard try u16(data, 0) == 0, try u16(data, 2) == 2 else { throw ThemeError.invalid("不是 CUR 光标。") }
        let count = try u16(data, 4)
        guard count > 0, count <= 256, 6 + count * 16 <= data.count else { throw ThemeError.invalid("无效 CUR 目录。") }
        let entries = (0..<count).map { 6 + $0 * 16 }
        let offset = entries.max(by: { (data[$0] == 0 ? 256 : Int(data[$0])) < (data[$1] == 0 ? 256 : Int(data[$1])) })!
        let width = data[offset] == 0 ? 256 : Int(data[offset])
        let height = data[offset + 1] == 0 ? 256 : Int(data[offset + 1])
        let hotX = try u16(data, offset + 4), hotY = try u16(data, offset + 6)
        let length = try u32(data, offset + 8), start = try u32(data, offset + 12)
        guard start >= 6 + count * 16, length > 0, start + length <= data.count else { throw ThemeError.invalid("无效 CUR 图像范围。") }
        let payload = data.subdata(in: start..<start + length)
        let imageData: Data
        if payload.starts(with: [137, 80, 78, 71]) { imageData = payload }
        else if payload.count >= 40, try u32(payload, 0) == 40, [24, 32].contains(try u16(payload, 14)), try u32(payload, 16) == 0,
                try u32(payload, 4) == width, try u32(payload, 8) == height * 2 {
            // Decode common 24/32-bit bottom-up CUR DIBs ourselves. ImageIO can
            // discard a 24-bit icon's AND mask, producing an opaque black box.
            // 32-bit images use the mask when their alpha channel is all zero.
            let pixelStart = 40, pixelBytes = try u16(payload, 14) / 8
            let stride = ((width * pixelBytes + 3) / 4) * 4, maskStride = ((width + 31) / 32) * 4
            guard pixelStart + stride * height <= payload.count else { throw ThemeError.invalid("CUR 位图已截断。") }
            if pixelBytes == 3, pixelStart + stride * height + maskStride * height > payload.count {
                throw ThemeError.invalid("CUR 透明遮罩已截断。")
            }
            let hasAlpha = pixelBytes == 4 && (0..<height).contains { row in (0..<width).contains { column in payload[pixelStart + row * stride + column * 4 + 3] != 0 } }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let source = pixelStart + (height - 1 - y) * stride + x * pixelBytes
                let dest = (y * width + x) * 4
                let mask = pixelStart + stride * height + (height - 1 - y) * maskStride + x / 8
                let alpha: UInt8 = hasAlpha ? payload[source + 3] : (mask < payload.count && payload[mask] & (0x80 >> (x % 8)) != 0 ? 0 : 255)
                rgba[dest] = payload[source + 2]; rgba[dest + 1] = payload[source + 1]
                rgba[dest + 2] = payload[source]; rgba[dest + 3] = alpha
            } }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ThemeError.invalid("CUR 位图解码失败。") }
            imageData = try CursorImages.png(image)
        } else {
            // Windows cursor entries carry hotspots where ICO carries planes / depth.
            var ico = Data([0, 0, 1, 0, 1, 0])
            ico.append(data.subdata(in: offset..<offset + 4))
            ico.append(contentsOf: [1, 0, 32, 0])
            for value in [length, 22] { ico.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
            ico.append(payload); imageData = ico
        }
        return CursorClip(frames: [try CursorImages.png(CursorImages.bitmap(imageData))],
                          width: Double(min(width, 128)), height: Double(min(height, 128)),
                          hotX: Double(hotX) * Double(min(width, 128)) / Double(width),
                          hotY: Double(hotY) * Double(min(height, 128)) / Double(height))
    }
    public static func read(_ url: URL) throws -> CursorClip {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 40_000_000 else { throw ThemeError.invalid("动画文件为空或超过 40 MB。") }
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent.lowercased()
        return try read(data, extension: url.pathExtension, trimTerminalHold: name.contains("_press") || name.contains("_release") || name == "beam_click.ani")
    }
    public static func read(_ data: Data, extension ext: String, trimTerminalHold: Bool = false) throws -> CursorClip {
        guard !data.isEmpty, data.count <= 40_000_000 else { throw ThemeError.invalid("动画文件为空或过大。") }
        if ext.lowercased() == "cur" { let clip = try cursor(data); try clip.validate(); return clip }
        if ext.lowercased() == "ani" { return try ani(data, trimTerminalHold: trimTerminalHold) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ThemeError.invalid("不支持此图像。") }
        let count = CGImageSourceGetCount(source)
        guard (1...240).contains(count) else { throw ThemeError.invalid("动画需要 1–240 帧。") }
        var frames: [Data] = [], durations: [Double] = []
        for i in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                  let w = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  w > 0, h > 0, w <= 2048, h <= 2048,
                  let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { throw ThemeError.invalid("图像损坏或大于 2048 像素。") }
            frames.append(try CursorImages.png(image))
            let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            durations.append(max(1.0 / 60, (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.05))
        }
        return try uniform(frames: frames, durations: durations, template: CursorClip(frames: frames))
    }
    private static func ani(_ data: Data, trimTerminalHold: Bool) throws -> CursorClip {
        guard data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "ACON" else { throw ThemeError.invalid("无效 ANI 文件头。") }
        let declaredSize = try u32(data, 4)
        // Some Windows exporters include the RIFF header in its own size field
        // (including legacy exporters). Accept only this exact eight-byte discrepancy. Parse
        // against the real buffer and still require complete, bounded chunks.
        guard declaredSize == data.count - 8 || declaredSize == data.count else {
            throw ThemeError.invalid("ANI 声明长度与实际文件不符，文件可能已截断。")
        }
        var frames: [CursorClip] = [], rates: [Int] = [], sequence: [Int] = []
        var defaultRate = 3, steps = 0
        var position = 12
        while position + 8 <= data.count {
            let tag = String(data: data[position..<position + 4], encoding: .ascii)
            let length = try u32(data, position + 4), start = position + 8, end = start + length
            guard end + length % 2 <= data.count else { throw ThemeError.invalid("ANI 区块越界。") }
            if tag == "anih", length >= 36 { steps = try u32(data, start + 8); defaultRate = max(1, try u32(data, start + 28)) }
            if tag == "rate" || tag == "seq " {
                guard length % 4 == 0, length <= 40000 else { throw ThemeError.invalid("ANI 时序无效。") }
                let values = try stride(from: start, to: end, by: 4).map { try u32(data, $0) }
                if tag == "rate" { rates = values } else { sequence = values }
            }
            if tag == "LIST", length >= 4, String(data: data[start..<start + 4], encoding: .ascii) == "fram" {
                var p = start + 4
                while p + 8 <= end {
                    let n = try u32(data, p + 4)
                    guard p + 8 + n + n % 2 <= end, frames.count < 10000 else { throw ThemeError.invalid("ANI 帧越界。") }
                    if String(data: data[p..<p + 4], encoding: .ascii) == "icon" {
                        frames.append(try cursor(data.subdata(in: p + 8..<p + 8 + n)))
                    }
                    p += 8 + n + n % 2
                }
                guard p == end else { throw ThemeError.invalid("ANI 帧区块已截断。") }
            }
            position = end + length % 2
        }
        guard position == data.count else { throw ThemeError.invalid("ANI 区块已截断。") }
        guard let template = frames.first else { throw ThemeError.invalid("ANI 缺少图像。") }
        if steps == 0 { steps = frames.count }
        guard steps <= 10000 else { throw ThemeError.invalid("ANI 时序过长。") }
        let indices = sequence.isEmpty ? (0..<steps).map { $0 % frames.count } : sequence
        guard indices.count == steps, indices.allSatisfy({ $0 < frames.count }) else { throw ThemeError.invalid("ANI 帧索引越界。") }
        var durations = (0..<steps).map { Double($0 < rates.count ? max(1, rates[$0]) : defaultRate) / 60 }
        // Some one-shot ANI files use a ~60-second final frame to stop Windows
        // from looping. It is a freeze sentinel, not part of the transition.
        // Gallery owns hold/release timing, so preserve the transition and trim
        // only that terminal sentinel; do not uniformly sample a minute of stills.
        if trimTerminalHold, durations.count > 1, let last = durations.last, last >= 10 {
            let typical = durations.dropLast().sorted()[max(0, (durations.count - 2) / 2)]
            if last > typical * 30 { durations[durations.count - 1] = max(1.0 / 60, typical) }
        }
        return try uniform(frames: indices.map { frames[$0].frames[0] }, durations: durations, template: template)
    }
    private static func uniform(frames: [Data], durations: [Double], template: CursorClip) throws -> CursorClip {
        if frames.count == 1 {
            var result = template; result.frames = frames; result.frameDuration = durations[0]
            try result.validate(); return result
        }
        let total = durations.reduce(0, +)
        let count = min(240, max(frames.count, Int(ceil(total * 30))))
        var result = template
        var index = 0, accumulated = durations[0]
        result.frames = (0..<count).map { n in
            let time = Double(n) * total / Double(count)
            while index + 1 < frames.count, time >= accumulated { index += 1; accumulated += durations[index] }
            return frames[index]
        }
        result.frameDuration = total / Double(count)
        try result.validate()
        return result
    }
}
