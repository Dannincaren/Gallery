import SwiftUI
import ImageIO
import GalleryCore

/// Owned by one open popover. Decode only requested frames, with a small local
/// cache; large source bitmaps are downsampled before they become display images.
actor ImportPreviewFrames {
    private var images: [Data: CGImage] = [:]
    private var order: [Data] = []
    private var bytes = 0

    func image(_ data: Data) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let image = images[data] {
            order.removeAll { $0 == data }; order.append(data)
            return image
        }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(384, max(width, height)),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary), !Task.isCancelled else { return nil }
            let cost = image.bytesPerRow * image.height
            while !order.isEmpty && (order.count >= 16 || bytes + cost > 4 * 1024 * 1024) {
                let oldest = order.removeFirst()
                if let removed = images.removeValue(forKey: oldest) { bytes -= removed.bytesPerRow * removed.height }
            }
            images[data] = image; order.append(data); bytes += cost
            return image
        }
    }
    func clear() { images.removeAll(); order.removeAll(); bytes = 0 }
}

struct ImportMaterialPreview: View {
    let clip: CursorClip
    let title: String
    let subtitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var frames = ImportPreviewFrames()
    @State private var image: CGImage?
    @State private var failed = false
    @State private var playing = true
    @State private var pausedFrame = 0
    @State private var started = Date()
    @State private var active = NSApp.isActive
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭预览")
                    .accessibilityLabel("关闭素材预览")
            }
            if clip.frames.count > 1 {
                // Only this popover is animated, at most 30 fps. Use elapsed
                // time so the cap does not change the source animation speed.
                TimelineView(.animation(minimumInterval: max(1.0 / 30, clip.frameDuration), paused: !playing || !active || !visible)) { context in
                    let index = playing ? max(0, Int(context.date.timeIntervalSince(started) / clip.frameDuration)) % clip.frames.count : pausedFrame
                    VStack(spacing: 12) {
                        canvas(index)
                        HStack {
                            Button {
                                if playing { pausedFrame = index }
                                else { started = Date().addingTimeInterval(-Double(pausedFrame) * clip.frameDuration) }
                                playing.toggle()
                            } label: { Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.fill" : "play.fill") }
                            Button { pausedFrame = 0; started = Date(); playing = true } label: { Image(systemName: "backward.end.fill") }
                                .help("重新播放").accessibilityLabel("重新播放素材预览")
                            Spacer()
                            Text("\(index + 1) / \(clip.frames.count) 帧").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.controlSize(.small)
                    }
                }
            } else {
                canvas(0)
                Text("静态素材").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(clip.width, specifier: "%.0f") × \(clip.height, specifier: "%.0f") 点 · \(clip.duration, specifier: "%.2f") 秒")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 300)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .onAppear { active = NSApp.isActive; visible = true; started = Date(); pausedFrame = 0; playing = true }
        .onDisappear { visible = false; image = nil; Task { await frames.clear() } }
    }

    private func canvas(_ index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
            Canvas { context, size in
                let step = 12.0
                for x in stride(from: 0.0, to: size.width, by: step) {
                    for y in stride(from: 0.0, to: size.height, by: step) where (Int(x / step) + Int(y / step)) % 2 == 0 {
                        context.fill(Path(CGRect(x: x, y: y, width: step, height: step)), with: .color(.secondary.opacity(0.08)))
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .aspectRatio(clip.width / clip.height, contentMode: .fit).padding(20)
            } else if failed {
                Label("无法预览此素材", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .frame(height: 176)
        .accessibilityLabel("素材效果预览")
        .task(id: active && visible ? index : nil) {
            guard active, visible, clip.frames.indices.contains(index) else { return }
            let next = await frames.image(clip.frames[index])
            guard !Task.isCancelled else { return }
            if let next { image = next; failed = false }
            else { image = nil; failed = true }
        }
    }
}
