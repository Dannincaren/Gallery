import SwiftUI
import GalleryCore

struct ThemeOverview: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    let rename: () -> Void
    let delete: () -> Void
    let mapping: () -> Void

    private var previewRole: CursorRole? {
        store.theme.roles.first { NativeCursorCatalog.identity($0.id) == "com.apple.coregraphics.Arrow" } ?? store.theme.roles.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 18) {
                if let cover = store.library.first(where: { $0.id == store.selectedThemeID })?.cover,
                   let image = EditorImageCache.image(cover) {
                    Image(nsImage: image).resizable().interpolation(store.theme.appearance.effectiveSmoothEdges ? .high : .none)
                        .scaledToFit().frame(width: 64, height: 64)
                        .padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(store.theme.localizedName).font(.largeTitle.bold()).textSelection(.enabled)
                    Text(L("主题总调节")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 18) {
                Text(L("主题外观")).font(.headline)
                Toggle(L("像素风格"), isOn: Binding(get: { store.theme.appearance.pixelArt }, set: {
                    var appearance = store.theme.appearance; appearance.pixelArt = $0; store.setAppearance(appearance)
                })).toggleStyle(.checkbox).disabled(store.editingActiveTheme).accessibilityIdentifier("theme-pixel-art")
                Text(L("保留清晰的像素边缘，忽略本主题的抗锯齿设置；橱窗、预览与实际光标使用相同规则。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        NumericSlider(title: L("主题整体大小"), value: Binding(get: { store.theme.pointerScale }, set: { store.setThemeScale($0) }),
                                      range: store.themeScaleLimits.percentages, unit: "%", multiplier: 100, showsLimits: true)
                        if store.themeScaleLimits.conflicting {
                            Text(L("部分素材的尺寸范围不兼容，请先单独调整角色或素材尺寸。"))
                                .font(.caption).foregroundStyle(.red)
                        }
                        Button(L("还原")) { store.setThemeScale(1) }
                    }
                    RoleSizePreview(clip: previewRole?.clip(.normal), scale: store.theme.pointerScale * (previewRole?.scale ?? 1), appearance: store.theme.appearance)
                }.id(store.selectedThemeID)
                Text(L("仅影响当前主题")).font(.caption).foregroundStyle(.secondary)
            }.padding(22).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
            if store.editingActiveTheme && !runtime.unsupportedRoles.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("部分系统角色保留原生光标")).font(.callout.weight(.medium))
                    ForEach(runtime.unsupportedRoles.keys.sorted(), id: \.self) { id in
                        Text(NativeCursorCatalog.displayName(id) + "：" + runtime.unsupportedRoles[id]!)
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }.foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("自定义映射")).font(.headline)
                    Text(L("为系统角色选择主题素材，每个角色独立保存大小与动画。"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(action: mapping) { Label(L("编辑映射…"), systemImage: "arrow.up.right.square") }
                    .disabled(!store.canEditMapping).help(store.canEditMapping ? L("编辑映射…") : L("请先停用主题，再编辑映射。"))
                    .accessibilityIdentifier("edit-theme-mapping")
            }.padding(22).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 14) {
                Text(L("主题操作")).font(.headline)
                HStack(spacing: 12) {
                    Button { store.exportTheme() } label: { Label(L("导出 Gallery 主题…"), systemImage: "square.and.arrow.up") }
                    Button { store.exportTheme(cape: true) } label: { Label(L("导出常态 Mousecape 主题…"), systemImage: "square.and.arrow.up") }
                }
                Divider().padding(.vertical, 2)
                HStack(spacing: 12) {
                    Button(action: rename) { Label(L("重命名…"), systemImage: "pencil") }
                    Button(role: .destructive, action: delete) { Label(L("删除整个主题…"), systemImage: "trash") }
                }
            }.controlSize(.large).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
            if store.editingActiveTheme {
                HStack {
                    Text(L("暂停后可更改像素风格和角色映射。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("暂停并编辑")) { store.stopTheme() }.disabled(!store.canSwitchTheme)
                }
            }
        }.accessibilityIdentifier("theme-overview")
    }
}
