import SwiftUI
import GalleryCore

struct ImportReviewSheet: View {
    @ObservedObject var store: GalleryStore
    let review: ThemeImportReview
    @State private var chosen = Set([0])
    @State private var omitted = Set<String>()
    @State private var expanded = Set([0])
    @State private var previewID: String?
    @State private var error: String?
    private func itemKey(_ theme: Int, _ role: String, _ motion: Motion, _ variant: String) -> String {
        String(theme) + ":" + ImportSelection.key(role: role, motion: motion) + ":" + variant
    }
    private func roles(_ theme: GalleryTheme) -> [CursorRole] {
        var seen = Set<String>(); return theme.roles.filter { seen.insert(CursorCatalog.family($0.id)).inserted }
    }
    private func selections(_ index: Int) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for role in roles(review.themes[index]) {
            for motion in Motion.allCases {
                guard let variants = role.variants[motion.rawValue], variants.count > 1 else { continue }
                result[ImportSelection.key(role: role.id, motion: motion)] = Set(variants.filter {
                    !omitted.contains(itemKey(index, role.id, motion, $0.id))
                }.map(\.id))
            }
        }
        return result
    }
    private func materialRow(_ variant: CursorVariant, index: Int, role: CursorRole, motion: Motion) -> some View {
        let key = itemKey(index, role.id, motion, variant.id)
        let clip = role.selectedVariants[motion.rawValue] == variant.id ? role.clip(motion) ?? variant.clip : variant.clip
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { !omitted.contains(key) }, set: {
                if $0 { omitted.remove(key) } else { omitted.insert(key) }
            })) {
                HStack {
                    Text(variant.localizedName).lineLimit(2)
                    Spacer()
                    Text(clip.frames.count > 1 ? L("\(clip.frames.count) 帧") : L("静态")).font(.caption).foregroundStyle(.secondary)
                    if role.selectedVariants[motion.rawValue] == variant.id { Text(L("默认")).font(.caption).foregroundStyle(.blue) }
                }
            }
            .disabled(!chosen.contains(index))
            Button { previewID = key } label: {
                Label(L("预览"), systemImage: "eye")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel(L("预览 ") + role.localizedName + " · " + motion.title + " · " + variant.localizedName)
            .popover(isPresented: Binding(get: { previewID == key }, set: {
                if !$0 && previewID == key { previewID = nil }
            }), arrowEdge: .trailing) {
                ImportMaterialPreview(clip: clip, title: variant.localizedName, subtitle: role.localizedName + " · " + motion.title)
                    .id(key)
            }
            .onDisappear { if previewID == key { previewID = nil } }
        }.font(.callout)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("选择要导入的光标")).font(.title2.bold())
            Text(L("勾选套装和需要保留的素材。每套分别加入主题橱窗；壁纸、应用图标和程序不会导入。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(L("已选择 \(chosen.count) / \(review.themes.count) 套")).font(.callout.monospacedDigit())
                Spacer()
                Button(L("全选套装")) { chosen = Set(review.themes.indices) }
                Button(L("清空选择")) { chosen.removeAll() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(review.themes.indices, id: \.self) { index in
                        let theme = review.themes[index]
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Toggle(isOn: Binding(get: { chosen.contains(index) }, set: {
                                    if $0 { chosen.insert(index) } else { chosen.remove(index) }
                                })) { EmptyView() }.labelsHidden().accessibilityLabel(L("导入 ") + theme.localizedName)
                                if let frame = theme.coverFrame ?? theme.roles.first(where: { CursorCatalog.isArrow($0.id) })?.clip(.normal)?.frames.first,
                                   let image = EditorImageCache.image(frame) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 42, height: 42)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(theme.localizedName).font(.headline).lineLimit(2)
                                    Text(L("\(roles(theme).count) 个角色")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            if ImportSelection.hasAlternatives(theme) {
                                DisclosureGroup(L("选择此套装的素材版本"), isExpanded: Binding(get: { expanded.contains(index) }, set: {
                                    if $0 { expanded.insert(index) } else { expanded.remove(index) }
                                })) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach(roles(theme)) { role in
                                            ForEach(Motion.allCases) { motion in
                                                if let variants = role.variants[motion.rawValue], variants.count > 1 {
                                                    VStack(alignment: .leading, spacing: 8) {
                                                        Text(role.localizedName + " · " + motion.title).font(.callout.weight(.semibold))
                                                        ForEach(variants) { variant in
                                                            materialRow(variant, index: index, role: role, motion: motion)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }.padding(.top, 10)
                                }.font(.callout)
                            }
                        }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.vertical, 2)
            }
            Text(L("常态至少保留一套。多套素材可在导入后切换；若取消默认版本，将使用其余所选版本中的第一套。")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button(L("取消")) { store.cancelImportReview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("导入所选 \(chosen.count) 套")) {
                    do {
                        let themes = try chosen.sorted().map { try ImportSelection.keeping(selections($0), in: review.themes[$0]) }
                        store.confirmImportReview(themes)
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }.padding(24).frame(width: 680, height: 720)
        .onChange(of: expanded) { _, value in
            if let previewID, !value.contains(where: { previewID.hasPrefix("\($0):") }) { self.previewID = nil }
        }
        .onDisappear { previewID = nil }
    }
}
