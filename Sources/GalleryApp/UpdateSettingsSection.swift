import SwiftUI
import GalleryCore
import UniformTypeIdentifiers

struct UpdateSettingsSection: View {
    @ObservedObject var updates: AppUpdateChecker = .shared
    @State private var selectingDestination = false
    private func download(_ release: GalleryRelease) {
        guard !selectingDestination, !updates.downloading else { return }
        selectingDestination = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Gallery-" + release.versionName + ".zip"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = L("下载")
        panel.message = L("选择安装包的保存位置，下载完成后打开并替换 Gallery。")
        let completed: (NSApplication.ModalResponse) -> Void = { response in
            selectingDestination = false
            if response == .OK, let destination = panel.url { updates.download(to: destination) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completed) }
        else { panel.begin(completionHandler: completed) }
    }
    var body: some View {
        GroupBox(L("版本与更新")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("当前版本 \(updates.currentVersion)")).font(.callout)
                    Spacer()
                    Button { updates.check() } label: {
                        HStack(spacing: 7) {
                            if updates.checking { ProgressView().controlSize(.mini).frame(width: 12) }
                            else { Image(systemName: "arrow.triangle.2.circlepath").frame(width: 12) }
                            Text(L("检查更新"))
                        }
                    }.disabled(updates.checking || updates.downloading || selectingDestination).accessibilityIdentifier("check-for-updates")
                }
                Group {
                    switch updates.state {
                    case .idle: EmptyView()
                    case .checking: Text(L("正在连接 GitHub…"))
                    case .current: Label(L("已是最新版本"), systemImage: "checkmark.circle")
                    case .available(let release):
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("新版本 \(release.versionName) 可用"))
                            switch updates.downloadState {
                            case .idle, .failed:
                                HStack {
                                    if release.package != nil {
                                        Button(L("下载更新…")) { download(release) }
                                            .disabled(selectingDestination).accessibilityIdentifier("download-update")
                                    }
                                    Link(L("版本说明"), destination: release.url)
                                }
                                if case .failed(let error) = updates.downloadState { Text(error).foregroundStyle(.red) }
                                else if release.package == nil { Text(L("此版本未提供可验证的安装包，请前往发行页面。")) }
                            case .downloading(let ratio):
                                ProgressView(value: ratio).progressViewStyle(.linear)
                                HStack {
                                    Text(L("正在下载…"))
                                    Text(ratio, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                                    Spacer()
                                    Button(L("取消下载")) { updates.cancelDownload() }
                                }
                                Text(L("关闭设置后仍会继续下载，可回来查看进度。")).font(.caption)
                            case .verifying:
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text(L("正在校验安装包…"))
                                    Spacer()
                                    Button(L("取消下载")) { updates.cancelDownload() }
                                }
                            case .ready:
                                Label(L("下载完成"), systemImage: "checkmark.circle")
                                HStack {
                                    Button(L("打开安装包")) { if let file = updates.downloadedFile() { NSWorkspace.shared.open(file) } }
                                    Button(L("在访达中显示")) { if let file = updates.downloadedFile() { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
                                }
                            }
                        }
                    case .failed(let message):
                        Text(message)
                        Link(L("打开发行页面"), destination: GalleryRelease.releasesURL)
                    }
                }.font(.callout).foregroundStyle(.secondary)
                Text(L("仅在点击时检查或下载安装包；完成后打开安装包并替换 Gallery。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { updates.cancel() }
    }
}
