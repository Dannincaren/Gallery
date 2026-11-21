import SwiftUI

struct ThemeStatusSummary: View {
    let active: String
    let browsing: String?
    let detail: RuntimeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(active)
                if let browsing { Text(browsing).foregroundStyle(.secondary) }
            }
            .font(.callout.weight(.semibold)).lineLimit(1)
            RuntimeStatusText(status: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct RuntimeStatusText: View {
    @ObservedObject var status: RuntimeStatus
    var body: some View { Text(status.text) }
}
