import SwiftUI

/// Unticked continuous track plus a committed, range-checked numeric entry.
struct NumericSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var multiplier = 1.0
    var inputRange: ClosedRange<Double>?
    @State private var draft = ""
    @State private var committedDraft = ""
    @FocusState private var editing: Bool
    private var limits: ClosedRange<Double> { inputRange ?? range }
    private var display: Double { value * multiplier }
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false).frame(minWidth: 76, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, display)) }, set: {
                let normalized = $0.rounded() / multiplier
                if value != normalized { value = normalized }
            }), in: range).labelsHidden().tint(.accentColor).frame(minWidth: 100, maxWidth: .infinity).accessibilityLabel(title)
            HStack(spacing: 4) {
                TextField("", text: $draft).labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit().weight(.medium)).focused($editing)
                    .frame(width: 48).onSubmit(commit).accessibilityLabel(title + "数值")
                    .help("输入 \(Int(limits.lowerBound))–\(Int(limits.upperBound))\(unit)，回车确认")
                Text(unit).font(.caption).foregroundStyle(.secondary).fixedSize()
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(editing ? 0.2 : 0.08), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
        }
        .onAppear { refresh() }
        .onChange(of: value) { _, _ in if !editing { refresh() } }
        .onChange(of: editing) { _, active in if !active { commit() } }
    }
    private func refresh() { draft = String(Int(display.rounded())); committedDraft = draft }
    private func commit() {
        guard draft != committedDraft else { refresh(); return }
        if let number = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), number.isFinite {
            let normalized = min(limits.upperBound, max(limits.lowerBound, number.rounded()))
            value = normalized / multiplier; draft = String(Int(normalized)); committedDraft = draft; return
        }
        refresh()
    }
}
