import SwiftUI
import GalleryCore

/// The gallery only displays cached stills. No frame clocks or animation
/// resources are created for cards, including while hovering.
struct ThemeGallery<Actions: View>: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    let open: (String) -> Void
    let importTheme: () -> Void
    @ViewBuilder var actions: (LibraryTheme) -> Actions
    @State private var query = ""
    private let columns = [GridItem(.adaptive(minimum: 208, maximum: 280), spacing: 22)]
    private var themes: [LibraryTheme] {
        query.isEmpty ? store.library : store.library.filter { $0.name.localizedStandardContains(query) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text("Gallery").font(.custom("Zapfino", size: 28))
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索主题", text: $query).textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 13).padding(.vertical, 10)
                        .background(.quaternary.opacity(0.3), in: Capsule()).frame(width: 230)
                }
                HStack {
                    Text("主题目录").font(.title3.weight(.semibold))
                    Text("\(store.library.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary.opacity(0.45), in: Capsule())
                    Spacer()
                    if let active = store.activeThemeName {
                        HStack(spacing: 7) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("正在使用 · \(active)").lineLimit(1)
                        }.font(.callout).foregroundStyle(.secondary)
                    } else { Text("自定义光标已停用").font(.callout).foregroundStyle(.secondary) }
                }
                if themes.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(themes) { theme in
                            ThemeShowcaseCard(theme: theme, active: store.isActiveTheme(theme.id), open: { open(theme.id) }) {
                                actions(theme)
                            }.onAppear { store.ensureThumbnails(theme.id) }
                        }
                        if query.isEmpty { importCard }
                    }
                }
            }.padding(.horizontal, 38).padding(.top, 28).padding(.bottom, 36)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var importCard: some View {
        Button(action: importTheme) {
            VStack(spacing: 13) {
                Image(systemName: "plus").font(.system(size: 24, weight: .light))
                    .frame(width: 52, height: 52).background(.quaternary.opacity(0.25), in: Circle())
                Text("导入主题").font(.headline)
                Text("EXE · 文件夹 · ZIP · Gallery").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).aspectRatio(1, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 20).strokeBorder(.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .accessibilityIdentifier("import-theme-card")
    }
}

private struct ThemeShowcaseCard<Actions: View>: View {
    let theme: LibraryTheme
    let active: Bool
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    private var arrow: Data? {
        theme.cover ?? theme.roles.first(where: { CursorCatalog.isArrow($0.id) })?.thumbnail
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025))
                    if let arrow, let image = EditorImageCache.image(arrow) {
                        Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                            .frame(width: 88, height: 88).shadow(color: .black.opacity(0.09), radius: 4, y: 4)
                    } else {
                        Image(systemName: "cursorarrow").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text(theme.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text("\(theme.roles.count) 个角色").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.top, 14).padding(.trailing, 34)
            }.padding(17).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("打开主题：\(theme.name)")
            .accessibilityIdentifier("theme-card-\(theme.id)")
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(active ? Color.accentColor.opacity(0.7) : Color.primary.opacity(hovering ? 0.22 : 0.07), lineWidth: active ? 1.5 : 1) }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.09 : 0.035), radius: 10, y: 5)
            .overlay(alignment: .topLeading) {
                if active {
                    Label("正在使用", systemImage: "checkmark.circle.fill").font(.caption2.weight(.medium))
                        .foregroundStyle(.green).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule()).padding(11)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Menu { actions() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        .frame(width: 29, height: 29).background(.regularMaterial, in: Circle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 15).padding(.bottom, 18)
                    .help("\(theme.name)的主题操作")
                    .accessibilityLabel("\(theme.name)的主题操作")
                    .accessibilityIdentifier("theme-menu-\(theme.id)")
            }
            .onHover { hovering = $0 }
            .contextMenu { actions() }
    }
}

struct ThemeRenameSheet: View {
    let theme: LibraryTheme
    let save: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    init(theme: LibraryTheme, save: @escaping (String) -> Void) {
        self.theme = theme; self.save = save; _name = State(initialValue: theme.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("重命名主题").font(.title2.bold())
            TextField("主题名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存名称") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 380)
    }
}

struct ThemeDeleteSheet: View {
    let theme: LibraryTheme
    let message: String
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 15) {
                if let data = theme.cover, let image = EditorImageCache.image(data) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("删除这个主题？").font(.title2.bold())
                    Text(theme.name).font(.headline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("移入废纸篓", role: .destructive) { dismiss(); confirm() }.buttonStyle(.borderedProminent).tint(.red)
            }
        }.padding(28).frame(width: 420)
    }
}
