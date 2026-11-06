import SwiftUI
import GalleryCore

/// The gallery only displays cached stills. No frame clocks or animation
/// resources are created for cards, including while hovering.
struct ThemeGallery<Actions: View>: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    @Binding var selection: String?
    let open: (String) -> Void
    let importTheme: () -> Void
    @ViewBuilder var actions: (LibraryTheme) -> Actions
    @State private var query = ""
    @State private var reordering = false
    @State private var draggingID: String?
    @State private var dragOrder: [String]?
    @State private var dragEndTimer: Timer?
    @State private var dragSessionID: UUID?
    @State private var lastMovePoint: CGPoint?
    @State private var lastMoveTime = -Double.infinity
    private let columns = [GridItem(.adaptive(minimum: 208, maximum: 280), spacing: 22)]
    private var themes: [LibraryTheme] {
        let rows: [LibraryTheme]
        if let dragOrder {
            let entries = Dictionary(uniqueKeysWithValues: store.library.map { ($0.id, $0) })
            rows = dragOrder.compactMap { entries[$0] }
        } else { rows = store.library }
        return query.isEmpty ? rows : rows.filter { $0.localizedName.localizedStandardContains(query) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text("Gallery").font(GalleryWordmark.font).frame(height: 88, alignment: .leading)
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("搜索主题"), text: $query).textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 13).padding(.vertical, 10)
                        .background(.quaternary.opacity(0.3), in: Capsule()).frame(width: 230)
                }
                HStack {
                    Text(L("主题目录")).font(.title3.weight(.semibold))
                    Text("\(store.library.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary.opacity(0.45), in: Capsule())
                    Button {
                        reordering.toggle()
                        clearDrag()
                    } label: {
                        Label(reordering ? L("完成排序") : L("调整顺序"), systemImage: reordering ? "checkmark" : "arrow.up.arrow.down")
                    }.buttonStyle(.borderless).font(.callout)
                        .disabled(store.importing || !query.isEmpty || store.library.count < 2)
                        .help(query.isEmpty ? L("直接拖动卡片调整顺序") : L("清空搜索后调整主题顺序"))
                        .accessibilityIdentifier("reorder-themes")
                    Spacer()
                    if let active = store.activeThemeName {
                        HStack(spacing: 7) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text(L("正在使用 · \(active)")).lineLimit(1)
                        }.font(.callout).foregroundStyle(.secondary)
                    } else { Text(L("自定义光标已停用")).font(.callout).foregroundStyle(.secondary) }
                }
                if reordering {
                    Text(L("直接拖动卡片调整顺序，松手后自动保存。"))
                        .font(.callout).foregroundStyle(.secondary).padding(.top, -15)
                }
                if themes.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(themes) { theme in
                            showcase(theme)
                        }
                        if query.isEmpty { importCard }
                    }
                }
            }.padding(.horizontal, 38).padding(.top, 28).padding(.bottom, 36)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: query) { _, _ in reordering = false; clearDrag(); store.cancelThemePreparation() }
        .onChange(of: store.importing) { _, importing in if importing { reordering = false; clearDrag() } }
        .onExitCommand { clearDrag() }
        .onDisappear { clearDrag(); store.cancelThemePreparation() }
    }
    private func clearDrag() {
        dragEndTimer?.invalidate(); dragEndTimer = nil; dragSessionID = nil
        lastMovePoint = nil; lastMoveTime = -.infinity
        withAnimation(.easeOut(duration: 0.16)) { draggingID = nil; dragOrder = nil }
    }
    private func beginDrag(_ sourceID: String) {
        guard store.library.contains(where: { $0.id == sourceID }) else { return }
        dragEndTimer?.invalidate()
        draggingID = sourceID; dragOrder = store.library.map(\.id)
        lastMovePoint = nil; lastMoveTime = -.infinity
        let token = UUID(); dragSessionID = token
        // A single cheap watcher exists only for this UI gesture. It cleans up
        // a cancelled/outside drop, which SwiftUI's onDrag doesn't report.
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if dragSessionID == token { clearDrag() }
                    }
                }
            }
        }
        timer.tolerance = 0.01; dragEndTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func showcase(_ theme: LibraryTheme) -> some View {
        return ThemeShowcaseCard(theme: theme, active: store.isActiveTheme(theme.id), selected: selection == theme.id, reordering: reordering,
            placeholder: draggingID == theme.id,
            open: {
                guard !reordering, !store.importing else { return }
                if store.isActiveTheme(theme.id) || selection == theme.id { open(theme.id) }
                else { selection = theme.id; store.prepareTheme(theme.id) }
            }) {
                actions(theme)
            }.modifier(ThemeOrderSource(enabled: reordering && !store.importing && query.isEmpty, theme: theme, began: beginDrag))
                .onDrop(of: [.galleryThemeOrder], delegate: ThemeOrderDropDelegate(targetID: theme.id,
                    enabled: reordering && !store.importing && query.isEmpty, store: store, draggingID: $draggingID, order: $dragOrder,
                    lastMovePoint: $lastMovePoint, lastMoveTime: $lastMoveTime, finished: clearDrag))
                .onAppear { store.ensureThumbnails(theme.id) }
    }
    private var importCard: some View {
        Button(action: importTheme) {
            VStack(spacing: 13) {
                Image(systemName: "plus").font(.system(size: 24, weight: .light))
                    .frame(width: 52, height: 52).background(.quaternary.opacity(0.25), in: Circle())
                Text(L("导入主题")).font(.headline)
                Text(L("EXE · 文件夹 · ZIP · Gallery")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).aspectRatio(1, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 20).strokeBorder(.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 26, trailing: 28)).aspectRatio(1, contentMode: .fit)
            .accessibilityIdentifier("import-theme-card").disabled(store.importing)
    }
}

struct ThemeShowcaseCard<Actions: View>: View {
    let theme: LibraryTheme
    let active: Bool
    var selected = false
    var reordering = false
    var placeholder = false
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var showActiveLabel = false
    @State private var presentedElevation: Int?
    @State private var presentationGeneration = UUID()
    private var elevationDuration: Double { reduceMotion ? 0.12 : 0.2 }
    private var labelFadeOutDuration: Double { reduceMotion ? 0.08 : 0.16 }
    private var elevation: Int { active ? 2 : selected ? 1 : 0 }
    private var visibleElevation: Int { presentedElevation ?? elevation }
    private var lift: CGSize { CGSize(width: visibleElevation == 2 ? -1 : 0, height: visibleElevation == 2 ? -3 : visibleElevation == 1 ? -2 : 0) }
    private var depth: CGSize { CGSize(width: visibleElevation == 2 ? 22 : visibleElevation == 1 ? 6 : 0, height: visibleElevation == 2 ? 12 : visibleElevation == 1 ? 6 : 0) }
    private var backing: Color {
        visibleElevation == 2 ? Color(white: colorScheme == .dark ? 0.44 : 0.43)
            : Color(white: colorScheme == .dark ? 0.38 : 0.82)
    }
    private var arrow: Data? {
        theme.cover ?? theme.roles.first(where: { CursorCatalog.isArrow($0.id) })?.thumbnail
    }
    var body: some View {
        Button(action: open) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    // The opaque face conceals the backing at rest. Reveal it
                    // through movement, rather than also fading a tiny edge
                    // from transparent (which only becomes visible at the end).
                    .fill(backing)
                    .offset(x: depth.width, y: depth.height)
                    .shadow(color: .black.opacity(visibleElevation == 2 ? 0.14 : visibleElevation == 1 ? 0.08 : 0),
                        radius: visibleElevation == 2 ? 8 : 4, x: visibleElevation == 2 ? 3 : 1, y: visibleElevation == 2 ? 5 : 2)
                face.offset(lift)
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if GalleryLocalization.isEnglish {
                        Text("IN\nUSE").font(.system(size: 10, weight: .semibold))
                            .multilineTextAlignment(.center).lineSpacing(3)
                    } else {
                        VStack(spacing: 3) {
                            ForEach(Array("正在使用"), id: \.self) { character in
                                Text(String(character))
                            }
                        }.font(GalleryStatusTypography.italic)
                    }
                }
                .foregroundStyle(Color(red: 1, green: 0.98, blue: 0.92))
                .shadow(color: Color.white.opacity(0.72), radius: 1.2)
                .shadow(color: Color(red: 1, green: 0.97, blue: 0.87).opacity(0.48), radius: 3)
                .frame(width: 22).padding(.top, 27)
                .offset(x: 22, y: 12).opacity(active && showActiveLabel ? 1 : 0)
                .animation(active ? .easeOut(duration: 0.14) : .easeInOut(duration: labelFadeOutDuration), value: active && showActiveLabel)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            // The face, depth and label all stay inside this fixed grid cell.
            // Every face keeps the same square size in all three states.
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 26, trailing: 28))
            .aspectRatio(1, contentMode: .fit).contentShape(Rectangle())
        }
        .buttonStyle(ShowcaseCardButtonStyle())
        .accessibilityLabel("\(reordering ? L("移动主题") : (active || selected ? L("打开主题") : L("选择主题")))：\(theme.localizedName)")
        .accessibilityValue(active ? L("正在使用") : selected ? L("已选中") : L("未选中"))
        .accessibilityIdentifier("theme-card-\(theme.id)")
        .overlay(alignment: .bottomTrailing) {
            Menu { actions() } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .frame(width: 29, height: 29).background(.regularMaterial, in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 43).padding(.bottom, 44).offset(lift)
            .help(L("\(theme.localizedName)的主题操作")).accessibilityLabel(L("\(theme.localizedName)的主题操作"))
            .accessibilityIdentifier("theme-menu-\(theme.id)")
        }
        .opacity(placeholder ? 0.28 : 1)
        .onHover { hovering = $0 }
        .contextMenu { actions() }
        .onAppear { presentedElevation = elevation; showActiveLabel = active }
        .onDisappear { presentationGeneration = UUID() }
        .onChange(of: elevation) { previous, next in
            // Let the label fade finish before retracting its backing.
            // Hover styling has its own local animation, so entering the card
            // while clicking cannot shorten this transition.
            let delay = previous == 2 && next != 2 ? labelFadeOutDuration + 0.02 : 0
            let generation = UUID(); presentationGeneration = generation
            showActiveLabel = false
            withAnimation(.easeInOut(duration: elevationDuration).delay(delay), completionCriteria: .logicallyComplete) {
                presentedElevation = next
            } completion: {
                guard presentationGeneration == generation, next == 2 else { return }
                showActiveLabel = true
            }
        }
    }
    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025))
                if let arrow, let image = EditorImageCache.image(arrow) {
                    Image(nsImage: image).resizable().interpolation(theme.appearance?.smoothEdges == false ? .none : .high).scaledToFit()
                        .frame(width: 80, height: 80).shadow(color: .black.opacity(0.09), radius: 4, y: 4)
                } else {
                    Image(systemName: "cursorarrow").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                Text(theme.localizedName).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(L("\(theme.roles.count) 个角色")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.top, 14).padding(.trailing, 34)
        }
        .padding(17).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.07), lineWidth: 1)
                .animation(.easeOut(duration: 0.14), value: hovering)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.025), radius: 3, y: 1)
    }
}

// Keep the opaque card face during a short navigation load. The loading
// overlay already communicates that controls are temporarily unavailable.
private struct ShowcaseCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
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
            Text(L("重命名主题")).font(.title2.bold())
            TextField(L("主题名称"), text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存名称")) { save(name); dismiss() }.keyboardShortcut(.defaultAction)
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
                    Text(L("删除这个主题？")).font(.title2.bold())
                    Text(theme.localizedName).font(.headline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("移入废纸篓"), role: .destructive) { dismiss(); confirm() }.buttonStyle(.borderedProminent).tint(.red)
            }
        }.padding(28).frame(width: 420)
    }
}
