import SwiftUI
import GalleryCore

struct RoleSourcePicker: View {
    @ObservedObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @State private var themeID = ""
    @State private var roleID = ""
    @State private var loaded: GalleryTheme?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    private var sources: [LibraryTheme] { store.library.filter { $0.id != store.selectedThemeID } }
    private var roles: [CursorRole] {
        var names = Set<String>()
        return loaded?.roles.filter { names.insert(CursorCatalog.family($0.id)).inserted } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("从其他主题选取光标")).font(.title2.bold())
            Text(L("只替换当前角色的素材，保留它的系统用途和独立大小。保存后无需保留来源主题文件。"))
                .foregroundStyle(.secondary)
            if sources.isEmpty {
                ContentUnavailableView(L("还没有其他主题"), systemImage: "folder.badge.plus", description: Text(L("请先导入另一个主题，随后在这里选取它的角色。")))
            } else {
                Picker(L("主题目录"), selection: $themeID) { ForEach(sources) { Text($0.localizedName).tag($0.id) } }
                if loading { ProgressView(L("正在读取主题…")) }
                if loaded != nil {
                    Picker(L("光标角色"), selection: $roleID) { ForEach(roles) { Text($0.localizedName).tag($0.id) } }
                    if let role = roles.first(where: { $0.id == roleID }), let frame = role.clip(.normal)?.frames.first,
                       let image = EditorImageCache.image(frame) {
                        Image(nsImage: image).resizable().interpolation(store.theme.appearance.effectiveSmoothEdges ? .high : .none).scaledToFit().frame(height: 100).frame(maxWidth: .infinity)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Spacer(minLength: 0)
            HStack {
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("使用这个角色")) {
                    guard let loaded, let role = loaded.roles.first(where: { $0.id == roleID }) else { return }
                    store.useTemplate(role, sourceName: loaded.name); dismiss()
                }.buttonStyle(.borderedProminent).disabled(loading || loaded == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 530, height: 390)
        .onAppear { themeID = sources.first?.id ?? "" }
        .onChange(of: themeID) { _, id in
            loaded = nil; error = nil; loading = true
            let request = UUID(); requestID = request
            store.loadLibraryTheme(id) { result in
                guard requestID == request else { return }; loading = false
                switch result {
                case .success(let theme):
                    loaded = theme
                    roleID = theme.roles.first(where: { $0.id == store.selectedRole })?.id ?? theme.roles[0].id
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
}
