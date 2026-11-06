import SwiftUI

struct ThemeStatusSummary: View {
    let active: String
    let browsing: String?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(active)
                if let browsing { Text(browsing).foregroundStyle(.secondary) }
            }
            .font(.callout.weight(.semibold)).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
