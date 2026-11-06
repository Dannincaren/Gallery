import SwiftUI
import GalleryCore

struct UpdateSettingsSection: View {
    @StateObject private var updates = AppUpdateChecker()
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
                    }.disabled(updates.checking).accessibilityIdentifier("check-for-updates")
                }
                Group {
                    switch updates.state {
                    case .idle: EmptyView()
                    case .checking: Text(L("正在连接 GitHub…"))
                    case .current: Label(L("已是最新版本"), systemImage: "checkmark.circle")
                    case .available(let release):
                        HStack {
                            Text(L("新版本 \(release.versionName) 可用"))
                            Spacer()
                            Link(L("查看并下载"), destination: release.url)
                        }
                    case .failed(let message):
                        Text(message)
                        Link(L("打开发行页面"), destination: GalleryRelease.releasesURL)
                    }
                }.font(.callout).foregroundStyle(.secondary)
                Text(L("仅在点击时连接 GitHub 检查正式版本；更新需手动下载与安装。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { updates.cancel() }
    }
}
