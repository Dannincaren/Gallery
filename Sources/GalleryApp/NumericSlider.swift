import GalleryCore
import SwiftUI

/// Unticked continuous track plus a committed, range-checked numeric entry.
struct NumericSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var multiplier = 1.0
    var inputRange: ClosedRange<Double>?
    /// Timing needs one final commit; size previews use bounded live updates.
    var updatesWhileDragging = true
    var onTrackingChanged: (Bool) -> Void = { _ in }
    @State private var tracking = false
    @State private var trackedValue: Double?
    @State private var pendingUpdate: DispatchWorkItem?
    @State private var lastUpdate = Date.distantPast
    @State private var draft = ""
    @State private var committedDraft = ""
    @FocusState private var editing: Bool
    private var limits: ClosedRange<Double> { inputRange ?? range }
    private var display: Double { (trackedValue ?? value) * multiplier }
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false).frame(minWidth: 76, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, display)) }, set: track), in: range, onEditingChanged: { active in
                tracking = active
                onTrackingChanged(active)
                if !active { flush() }
            }).labelsHidden().tint(.accentColor).frame(minWidth: 100, maxWidth: .infinity).accessibilityLabel(title)
            HStack(spacing: 4) {
                TextField("", text: Binding(get: { editing ? draft : String(Int(display.rounded())) }, set: { draft = $0 }))
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit().weight(.medium)).focused($editing)
                    .frame(width: 48).onSubmit(commit).accessibilityLabel(title + L("数值"))
                    .help(L("输入 \(Int(limits.lowerBound))–\(Int(limits.upperBound))\(unit)，回车确认"))
                Text(unit).font(.caption).foregroundStyle(.secondary).fixedSize()
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(editing ? 0.2 : 0.08), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
        }
        .onAppear { refresh() }
        .onChange(of: value) { _, _ in if !editing && !tracking { refresh() } }
        .onChange(of: editing) { _, active in if active { refresh() } else { commit() } }
        .onDisappear { pendingUpdate?.cancel(); if tracking { onTrackingChanged(false) } }
    }
    private func track(_ number: Double) {
        let normalized = number.rounded() / multiplier
        trackedValue = normalized
        draft = String(Int(number.rounded())); committedDraft = draft
        // AX and keyboard changes have no mouse tracking transaction.
        guard tracking else { flush(); return }
        guard updatesWhileDragging, pendingUpdate == nil else { return }
        let delay = max(0, 1.0 / 30 - Date().timeIntervalSince(lastUpdate))
        let task = DispatchWorkItem {
            pendingUpdate = nil
            if let current = trackedValue, current != value { value = current }
            lastUpdate = Date()
        }
        pendingUpdate = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func flush() {
        pendingUpdate?.cancel(); pendingUpdate = nil
        if let current = trackedValue, current != value { value = current }
        trackedValue = nil; lastUpdate = Date(); refresh()
    }
    private func refresh() { draft = String(Int(display.rounded())); committedDraft = draft }
    private func commit() {
        guard draft != committedDraft else { refresh(); return }
        if let number = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), number.isFinite {
            let normalized = min(limits.upperBound, max(limits.lowerBound, number.rounded()))
            pendingUpdate?.cancel(); pendingUpdate = nil; trackedValue = nil
            value = normalized / multiplier; draft = String(Int(normalized)); committedDraft = draft; return
        }
        refresh()
    }
}
