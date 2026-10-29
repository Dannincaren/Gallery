import SwiftUI
import GalleryCore

struct GalleryEditor: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    @ObservedObject var preferences: AppPreferences
    @Environment(\.colorScheme) private var colorScheme
    @State private var playing = true
    @State private var selectedFrame = 0
    @State private var previewStart = Date()
    @State private var showSettings = false
    @State private var showImport = false
    @State private var showRoleSource = false
    @State private var themeToDelete: LibraryTheme?
    @State private var showingTheme = false
    @State private var openingThemeID: String?
    @State private var deletingThemeID: String?
    @State private var themeToRename: LibraryTheme?
    @State private var editorActive = NSApp.isActive
    @State private var editorVisible = true
    init(store: GalleryStore, startInTheme: Bool = false) {
        self.store = store; self.runtime = store.runtime; self.preferences = store.preferences
        _showingTheme = State(initialValue: startInTheme)
    }
    var body: some View {
        Group {
            if showingTheme {
                NavigationSplitView { sidebar } detail: { editorDetail }
            } else {
                ThemeGallery(store: store, runtime: runtime, open: openTheme, importTheme: { showImport = true }) { folder in
                    themeActions(folder)
                }
            }
        }
        .toolbar { themeToolbar }
        .sheet(item: $themeToDelete) { folder in
            ThemeDeleteSheet(theme: folder, message: deletionMessage(folder)) {
                deletingThemeID = folder.id; store.deleteTheme(folder.id); themeToDelete = nil
            }
        }
        .disabled(store.importing)
        .sheet(isPresented: $showSettings) { InteractionSettings(store: store, runtime: runtime) }
        .sheet(isPresented: $showImport) { ImportThemePanel(store: store) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.importURL(url); return true
        }
        .alert("Gallery", isPresented: Binding(get: { store.message != nil || runtime.error != nil }, set: { if !$0 { store.message = nil; runtime.error = nil } })) {
            Button("好") { store.message = nil; runtime.error = nil }
        } message: { Text(runtime.error ?? store.message ?? "") }
        .onChange(of: store.selectedRole) { _, _ in selectedFrame = 0; previewStart = Date() }
        .onChange(of: store.selectedMotion) { _, _ in selectedFrame = 0; previewStart = Date() }
        .onAppear { editorActive = NSApp.isActive }
        .background(EditorVisibilityReader(visible: $editorVisible).frame(width: 0, height: 0))
        .onChange(of: store.selectedThemeID) { _, id in
            if openingThemeID == id { showingTheme = true; openingThemeID = nil }
            selectedFrame = 0; previewStart = Date()
        }
        .onChange(of: store.importing) { _, busy in
            guard !busy else { return }
            if let id = openingThemeID {
                showingTheme = store.selectedThemeID == id; openingThemeID = nil
            }
            if let id = deletingThemeID {
                if !store.library.contains(where: { $0.id == id }) { showGallery() }
                deletingThemeID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in editorActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in editorActive = false }
        .sheet(item: $themeToRename) { folder in
            ThemeRenameSheet(theme: folder) { store.renameTheme(folder.id, to: $0) }
        }
        .overlay {
            if store.importing {
                ZStack {
                    Color.black.opacity(0.05).ignoresSafeArea()
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text(openingThemeID == nil ? "正在处理主题…" : "正在打开主题…") }
                        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .sheet(isPresented: $showRoleSource) { RoleSourcePicker(store: store) }
        .frame(minWidth: 960, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var editorDetail: some View {
        VStack(spacing: 0) {
            statusBar
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.roleIndex.map { store.theme.roles[$0].name } ?? "光标").font(.largeTitle.bold())
                            Text("直接调整热点与动画，自动保存到当前主题。").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if runtime.enabled { Button("暂停并编辑") { runtime.stop() } }

                    }
                    HStack(spacing: 12) {
                        NumericSlider(title: "主题整体大小", value: Binding(get: { store.theme.pointerScale }, set: {
                            store.setThemeScale($0)
                        }), range: 50...300, unit: "%", multiplier: 100)
                        Button("还原") { store.setThemeScale(1) }
                        Text("仅影响当前主题").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.importing {
                        HStack { ProgressView().controlSize(.small); Text("正在转换和整理动画，请稍候…") }
                    }
                    if let index = store.roleIndex {
                        roleControls(store.theme.roles[index])
                        Text(store.theme.roles[index].splitClickAnimation
                             ? "已添加按住动画：按住时持续播放，松开时播放松手动画。"
                             : "未添加按住动画：点击后自动连播按下与松手动画。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("动画状态", selection: $store.selectedMotion) {
                        ForEach(Motion.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if store.selectedMotion == .idle, let index = store.roleIndex { idleTiming(store.theme.roles[index]) }
                    if let index = store.roleIndex { variantControls(store.theme.roles[index]) }
                    if let clip = store.clip {
                        clipEditor(clip)
                    } else {
                        ContentUnavailableView {
                            Label("尚未设置\(store.selectedMotion.title)动画", systemImage: "film.stack")
                        } description: {
                            Text("可以复制常态开始编辑，或直接导入动画文件。未设置时使用常态光标。")
                        } actions: {
                            Button("从常态复制") { store.createClip() }
                            Button("导入动画") { store.importFrames(append: false) }.buttonStyle(.borderedProminent)
                        }.frame(minHeight: 360).disabled(runtime.enabled)
                    }
                }.padding(28)
            }
            HStack {
                Circle().fill(store.saveStatus == "已保存在本机" ? .green : .orange).frame(width: 5, height: 5)
                Text(store.saveStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Gallery \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · 基于 Mousecape").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, 22).padding(.vertical, 12).background(.bar)
        }
    }
    @ToolbarContentBuilder private var themeToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if showingTheme {
                Button(action: showGallery) { Label("主题橱窗", systemImage: "chevron.left") }.help("返回主题橱窗")
            }
        }
        ToolbarItemGroup {
            if showingTheme && !store.isActiveTheme(store.selectedThemeID) {
                Button { store.applyCurrentTheme() } label: { Label("使用此主题", systemImage: "play.circle") }.tint(.blue)
            }
            if runtime.enabled {
                Button { runtime.stop() } label: { Label("停用并恢复", systemImage: "pause.circle") }
            }
            Button { showImport = true } label: { Label("导入主题", systemImage: "plus") }
            Button { showSettings = true } label: { Label("交互与应用设置", systemImage: "slider.horizontal.3") }
        }
    }
    private func openTheme(_ id: String) {
        guard !store.importing else { return }
        playing = true; previewStart = Date(); openingThemeID = id
        store.selectTheme(id)
        if store.selectedThemeID == id { showingTheme = true; openingThemeID = nil }
    }
    private func showGallery() {
        playing = false; showingTheme = false; openingThemeID = nil
        store.saveNow()
    }
    @ViewBuilder private func themeActions(_ folder: LibraryTheme) -> some View {
        Button("打开主题") { openTheme(folder.id) }
        if store.isActiveTheme(folder.id) {
            Button("停用并恢复光标") { runtime.stop() }
        } else {
            Button("使用此主题") { store.selectTheme(folder.id, activate: true) }
        }
        Divider()
        Button("重命名…") { themeToRename = folder }
        Button("导出 Gallery 主题…") { store.exportTheme(folder.id) }
        Button("导出常态 Mousecape 主题…") { store.exportTheme(folder.id, cape: true) }
        Divider()
        Button("删除整个主题…", role: .destructive) { themeToDelete = folder }
    }
    private func deletionMessage(_ folder: LibraryTheme) -> String {
        var text = "将删除「\(folder.name)」的全部角色与动画。"
        if store.isActiveTheme(folder.id) { text += "该主题正在使用，会先停用并恢复光标。" }
        text += "原始安装包不受影响；主题文件可从废纸篓找回。"
        if store.library.count == 1 { text += "删除后回到内置主题。" }
        return text
    }
    private var sidebarText: Color { colorScheme == .dark ? .white : .black }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Gallery").font(.title2.weight(.semibold)).padding(.top, 20).padding(.horizontal, 18)
            HStack(alignment: .top, spacing: 12) {
                if let data = store.library.first(where: { $0.id == store.selectedThemeID })?.cover, let image = EditorImageCache.image(data) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.theme.name).font(.headline).lineLimit(3).foregroundStyle(sidebarText)
                    Text(store.isActiveTheme(store.selectedThemeID) ? "正在使用" : "正在浏览")
                        .font(.caption).foregroundStyle(store.isActiveTheme(store.selectedThemeID) ? .green : .secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let folder = store.library.first(where: { $0.id == store.selectedThemeID }) {
                    Menu { themeActions(folder) } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("主题操作")
                }
            }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 12)
            List {
                Section {
                    ForEach(store.visibleRoles) { role in roleRow(role) }
                } header: { Text("光标角色").foregroundStyle(sidebarText.opacity(0.65)) }
            }.listStyle(.sidebar)
        }.navigationSplitViewColumnWidth(min: 220, ideal: 246, max: 300)
    }
    private func roleRow(_ role: CursorRole) -> some View {
        let summary = store.library.first(where: { $0.id == store.selectedThemeID })?.roles.first(where: { $0.id == role.id })
        let selected = CursorCatalog.family(store.selectedRole) == CursorCatalog.family(role.id)
        return Button { store.selectedRole = role.id } label: {
            HStack(spacing: 11) {
                Group {
                    if let data = summary?.thumbnail, let image = EditorImageCache.image(data) {
                        Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    } else { Image(systemName: "cursorarrow").foregroundStyle(sidebarText.opacity(0.6)) }
                }.frame(width: 28, height: 28).padding(5).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.name).font(.callout.weight(selected ? .semibold : .regular)).foregroundStyle(sidebarText)
                    Text(roleSubtitle(LibraryRole(role))).font(.caption2).foregroundStyle(sidebarText.opacity(0.6))
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 5).padding(.horizontal, 6).contentShape(RoundedRectangle(cornerRadius: 8))
                .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func roleSubtitle(_ role: LibraryRole) -> String {
        if role.usesNative { return "系统原有" }
        if role.id.hasPrefix("com.apple.gallery.Imported.") { return "未分类素材 · 可混用" }
        if CursorCatalog.assetOnly(role.id) { return "应用自定义 · 可编辑素材" }
        return "\(role.motionCount) 个动画状态"
    }
    private func idleTiming(_ role: CursorRole) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("待机等待", systemImage: "moon.zzz").font(.headline)
                Spacer()
                Picker("等待方式", selection: Binding(get: { role.idleDelayOverride != nil }, set: {
                    store.setRoleIdleDelay($0 ? store.theme.idleDelay : nil, for: role.id)
                })) {
                    Text("跟随全局").tag(false)
                    Text("单独设置").tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
            }
            if role.idleDelayOverride != nil {
                NumericSlider(title: "静止后播放", value: Binding(get: { role.idleDelayOverride ?? store.theme.idleDelay }, set: {
                    store.setRoleIdleDelay($0, for: role.id)
                }), range: 1...60, unit: "秒", inputRange: 1...600).id(role.id + ":idle")
                Text("拖动调整 1–60 秒，也可直接输入至 600 秒。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("使用全局默认：\(Int(store.theme.idleDelay)) 秒。仅此角色可单独覆盖。").font(.callout).foregroundStyle(.secondary)
            }
            if !store.theme.idleEnabled { Text("全局待机动画已关闭，可在「交互与应用设置」中开启。").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func variantControls(_ role: CursorRole) -> some View {
        HStack(spacing: 12) {
            let variants = role.variants[store.selectedMotion.rawValue] ?? []
            if variants.count > 1 {
                Picker("素材版本", selection: Binding(get: { role.selectedVariants[store.selectedMotion.rawValue] ?? "" }, set: {
                    store.selectVariant($0, for: store.selectedMotion); selectedFrame = 0; previewStart = Date()
                })) {
                    if role.selectedVariants[store.selectedMotion.rawValue] == nil { Text("当前素材").tag("") }
                    ForEach(variants) { variant in Text(variant.name).tag(variant.id) }
                }.frame(maxWidth: 440)
                if let clip = store.clip { Text(clip.frames.count > 1 ? "\(clip.frames.count) 帧" : "单帧").font(.caption).foregroundStyle(.secondary) }
            } else { Text("素材版本").font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Button("添加其他版本…") { store.importVariant() }
        }.disabled(runtime.enabled)
    }
    private var statusBar: some View {
        HStack(spacing: 9) {
            Image(systemName: runtime.enabled ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(runtime.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.activeThemeName.map { "正在使用：" + $0 } ?? (runtime.enabled ? "自定义光标已启用" : "自定义光标已停用"))
                    .font(.callout.weight(.semibold))
                Text(runtime.status).font(.caption).foregroundStyle(.secondary)
            }
            if runtime.enabled && !store.isActiveTheme(store.selectedThemeID) {
                Text("浏览：\(store.theme.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if runtime.hasRecovery && !runtime.enabled { Button("恢复上次光标") { runtime.recover() } }
        }.padding(.horizontal, 24).padding(.vertical, 13).background(.quaternary.opacity(0.35))
    }
    @ViewBuilder private func clipEditor(_ clip: CursorClip) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 12) {
                TimelineView(.animation(minimumInterval: max(1.0 / 60, clip.frameDuration), paused: !playing || clip.frames.count < 2 || !editorActive || !editorVisible || runtime.enabled)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(previewStart))
                    let n = playing ? Int(elapsed / clip.frameDuration) : selectedFrame
                    let index = playing && !store.selectedMotion.loops ? min(n, clip.frames.count - 1) : n % clip.frames.count
                    HotspotPreview(clip: clip, frame: max(0, min(index, clip.frames.count - 1)), editable: !runtime.enabled) { x, y in
                        store.edit { $0.hotX = x; $0.hotY = y }
                    }
                    .onChange(of: !store.selectedMotion.loops && elapsed >= clip.duration) { _, finished in
                        if finished && playing { selectedFrame = clip.frames.count - 1; playing = false }
                    }
                }.frame(minWidth: 320, minHeight: 300).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                HStack {
                    Button { playing.toggle(); previewStart = Date() } label: {
                        Label(runtime.enabled ? "预览已暂停" : (clip.frames.count < 2 ? "静态预览" : (playing ? "暂停预览" : "播放预览")), systemImage: playing ? "pause.fill" : "play.fill")
                    }.disabled(runtime.enabled || clip.frames.count < 2)
                        .help(runtime.enabled ? "先暂停自定义主题，再播放编辑器预览。" : "播放或暂停预览")
                    Button { previewStart = Date(); playing = true } label: { Image(systemName: "backward.end.fill") }
                        .help("重新播放").disabled(runtime.enabled || clip.frames.count < 2)
                    Spacer()
                    Text("\(clip.frames.count) 帧 · \(clip.duration, specifier: "%.2f") 秒").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("在预览中点击，设置实际点击位置。红色十字为热点。").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("热点与尺寸").font(.headline)
                number("热点 X", value: clip.hotX, range: 0...max(0, clip.width - 0.01)) { v in store.edit { $0.hotX = v } }
                number("热点 Y", value: clip.hotY, range: 0...max(0, clip.height - 0.01)) { v in store.edit { $0.hotY = v } }
                number("宽度", value: clip.width, range: 1...128) { v in store.edit { $0.width = v; $0.hotX = min($0.hotX, v - 0.01) } }
                number("高度", value: clip.height, range: 1...128) { v in store.edit { $0.height = v; $0.hotY = min($0.hotY, v - 0.01) } }
                Text("以上单位均为逻辑点，适配 Retina 屏幕。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("播放速度").font(.headline)
                number("每秒帧数", value: 1 / clip.frameDuration, range: 0.1...240) { v in store.edit { $0.frameDuration = 1 / v } }
                Text(store.selectedMotion.loops ? "此状态循环播放。" : "播放一次后进入下一状态；提前松手会立即播放松手动画。")
                    .font(.caption).foregroundStyle(.secondary)
                if clip.frames.count > 24 {
                    Label("Gallery 保留完整帧；导出 Mousecape 时采样为 24 帧。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 210).disabled(runtime.enabled)
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("帧序列").font(.headline)
                Spacer()
                Button("替换动画…") { store.importFrames(append: false); selectedFrame = 0 }
                Button("追加帧…") { store.importFrames(append: true) }
                if store.selectedMotion != .normal { Button("移除此状态", role: .destructive) { store.removeClip() } }
            }.disabled(runtime.enabled)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 9) {
                    ForEach(Array(clip.frames.enumerated()), id: \.offset) { index, data in
                        Button { selectedFrame = index; playing = false } label: {
                            VStack(spacing: 5) {
                                if let image = EditorImageCache.image(data) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 44, height: 44) }
                                Text(String(format: "%02d", index + 1)).font(.caption2.monospacedDigit())
                            }.padding(8).background(selectedFrame == index ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedFrame == index ? Color.accentColor : .clear))
                        }.buttonStyle(.plain).contextMenu {
                            Button("复制这一帧") { duplicateFrame(index) }
                        }
                    }
                }.padding(.vertical, 2)
            }
            HStack {
                Button { moveFrame(-1) } label: { Label("前移", systemImage: "arrow.left") }.disabled(selectedFrame <= 0)
                Button { moveFrame(1) } label: { Label("后移", systemImage: "arrow.right") }.disabled(selectedFrame >= clip.frames.count - 1)
                Button { duplicateFrame(selectedFrame) } label: { Label("复制当前帧", systemImage: "doc.on.doc") }
                    .disabled(clip.frames.count >= 240)
                Button("删除选中帧", role: .destructive) {
                    store.edit { $0.frames.remove(at: min(selectedFrame, $0.frames.count - 1)) }
                    selectedFrame = max(0, min(selectedFrame, clip.frames.count - 2))
                }.disabled(clip.frames.count <= 1)
                Spacer()
                Text("支持 PNG 序列、GIF、Windows CUR / ANI").font(.caption).foregroundStyle(.secondary)
            }.disabled(runtime.enabled)
        }.padding(18).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
    private func duplicateFrame(_ index: Int) {
        if let inserted = store.duplicateFrame(at: index) { selectedFrame = inserted; playing = false }
    }
    private func roleControls(_ role: CursorRole) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                NumericSlider(title: "此角色大小", value: Binding(get: { role.scale }, set: { store.setRoleScale($0, for: role.id) }),
                              range: 50...300, unit: "%", multiplier: 100).disabled(role.usesNative).id(role.id + ":size")
                Button("还原") { store.setRoleScale(1, for: role.id) }.disabled(role.usesNative)
                Text("叠加在主题整体大小之上").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("使用系统原有光标", isOn: Binding(get: { role.usesNative }, set: { store.setUsesNative($0) }))
                Spacer()
                if let name = role.sourceThemeName { Text("素材来自：\(name)").font(.caption).foregroundStyle(.secondary) }
                Button("从其他主题选取…") { showRoleSource = true }
            }.disabled(runtime.enabled)
            if runtime.enabled { Text("暂停后可更换角色来源；大小可以直接调节。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func moveFrame(_ offset: Int) {
        store.edit {
            let old = min(selectedFrame, $0.frames.count - 1), new = old + offset
            guard $0.frames.indices.contains(new) else { return }
            $0.frames.swapAt(old, new); selectedFrame = new
        }
    }
    private func number(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            TextField(title, value: Binding(get: { value }, set: { if $0.isFinite { set(min(range.upperBound, max(range.lowerBound, $0))) } }), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 75)
        }
    }
}

private struct ImportThemePanel: View {
    @ObservedObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("导入主题", systemImage: "square.and.arrow.down").font(.title2.bold())
            Text("把文件拖入 Gallery 窗口，或点击下方按钮选择。Gallery 会自动识别格式。")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("已整理好的主题", systemImage: "photo.stack").font(.headline)
                    Text("选择 .gallery 可一次导入全部指针、热点和交互动画。也支持原有 .cape 主题。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Windows 光标安装包", systemImage: "shippingbox").font(.headline)
                    Text("选择内嵌 CUR／ANI 的 .NET EXE（支持 PRTS、mon3tr 这类安装器），或选择包含光标和安装 INF 的文件夹、ZIP。也可直接选 INF。Gallery 直接读取素材，不运行安装程序。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("静态、动态等可选版本会一并保留。旧版主题需重新导入原包，或在角色页「添加其他版本」。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("不同 EXE 的打包方式可能不同，无法直接解析时请使用光标 ZIP。PRTS 请选 PRTS-Setup.exe，避免只选安装入口。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            HStack {
                Button("载入内置主题") { dismiss(); store.resetDemo() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("选择文件或文件夹…") {
                    dismiss(); DispatchQueue.main.async { store.openTheme() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
    }
}

private struct HotspotPreview: View {
    let clip: CursorClip
    let frame: Int
    let editable: Bool
    let set: (Double, Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.width - 48) / clip.width, (geometry.size.height - 48) / clip.height)
            let width = clip.width * scale, height = clip.height * scale
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let step = 16.0
                    for x in stride(from: 0.0, to: size.width, by: step) {
                        for y in stride(from: 0.0, to: size.height, by: step) where (Int(x / step) + Int(y / step)) % 2 == 0 {
                            context.fill(Path(CGRect(x: x, y: y, width: step, height: step)), with: .color(.secondary.opacity(0.06)))
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 18))
                if let image = EditorImageCache.image(clip.frames[frame]) {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: width, height: height).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                Path { p in
                    let x = origin.x + clip.hotX * scale, y = origin.y + clip.hotY * scale
                    p.move(to: CGPoint(x: x - 10, y: y)); p.addLine(to: CGPoint(x: x + 10, y: y))
                    p.move(to: CGPoint(x: x, y: y - 10)); p.addLine(to: CGPoint(x: x, y: y + 10))
                }.stroke(.red, lineWidth: 1.5)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { event in
                guard editable else { return }
                set(min(clip.width - 0.01, max(0, (event.location.x - origin.x) / scale)),
                    min(clip.height - 0.01, max(0, (event.location.y - origin.y) / scale)))
            })
        }
    }
}

struct InteractionSettings: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    @ObservedObject var preferences: AppPreferences
    init(store: GalleryStore, runtime: CursorRuntime) {
        self.store = store; self.runtime = runtime; self.preferences = store.preferences
    }
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("交互与应用").font(.title2.bold())
            GroupBox("启动") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("开机自启动（登录后运行）", isOn: Binding(get: { preferences.launchAtLogin || preferences.needsApproval }, set: { preferences.setLaunchAtLogin($0) }))
                    if preferences.needsApproval {
                        HStack {
                            Text("请在系统登录项中允许 Gallery。")
                            Button("打开登录项设置") { preferences.openLoginSettings() }
                        }.font(.caption)
                    }
                    Toggle("启动后自动应用当前主题", isOn: $preferences.applyAtLaunch)
                    Toggle("启用主题时隐藏 Dock 图标", isOn: $preferences.hideDockIconWhileRunning)
                    Text(runtime.enabled && preferences.hideDockIconWhileRunning
                         ? (NSApp.activationPolicy() == .accessory ? "Dock 图标已隐藏，可从菜单栏重新打开 Gallery。" : "正在隐藏 Dock 图标…")
                         : "隐藏后可从菜单栏重新打开 Gallery；停用主题后恢复 Dock 图标。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("请将应用放入「应用程序」后开启。存在待恢复记录时不会自动应用。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("快速甩动鼠标时放大主题光标", isOn: $preferences.shakeToLocate)
                .help("连续快速往返甩动时临时放大，随后恢复。此开关控制 Gallery 的放大效果，系统自带的定位鼠标设置独立生效。")
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                GroupBox("交互动画") {
                  VStack(alignment: .leading, spacing: 14) {
                    Toggle("鼠标静止时播放待机动画", isOn: $store.theme.idleEnabled)
                    NumericSlider(title: "默认等待", value: $store.theme.idleDelay, range: 1...60, unit: "秒", inputRange: 1...600)
                    Text("各角色可在「待机」页单独设置，未设置时使用此默认值。").font(.caption).foregroundStyle(.secondary)
                    Toggle("播放左键按下、按住与松手动画", isOn: $store.theme.clickEnabled)
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("在这些应用中暂停交互动画") {
                  VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.theme.excludedBundleIDs, id: \.self) { id in
                        HStack { Text(id).font(.caption); Spacer(); Button("移除") { store.theme.excludedBundleIDs.removeAll { $0 == id } } }
                    }
                    Menu("添加正在运行的应用…") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }, id: \.processIdentifier) { app in
                            if let id = app.bundleIdentifier {
                                Button(app.localizedName ?? id) { if !store.theme.excludedBundleIDs.contains(id) { store.theme.excludedBundleIDs.append(id) } }
                            }
                        }
                    }
                    Text("暂停交互时仍保留常态主题。游戏或使用自定义光标的应用可以加入此列表。").font(.caption).foregroundStyle(.secondary)
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
              }.padding(.vertical, 2)
            }.disabled(runtime.enabled)
            HStack {
                Button("检查输入监控授权") { runtime.requestInputAccess() }
                Button("打开隐私设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
            }
            Text("Gallery 只观察鼠标，不拦截点击、不记录键盘。锁屏、休眠时尽量恢复常态。请先退出 Mousecape 的自动重应用助手，避免两个工具同时修改主题。")
                .font(.caption).foregroundStyle(.secondary)
            Text(runtime.diagnostics).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            HStack { Spacer(); Button("完成") { store.changed(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 590, height: 790)
        .onAppear { preferences.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in preferences.refreshLoginStatus() }
        .alert("启动设置", isPresented: Binding(get: { preferences.error != nil }, set: { if !$0 { preferences.error = nil } })) {
            Button("好") { preferences.error = nil }
        } message: { Text(preferences.error ?? "") }
        .onChange(of: store.theme.idleDelay) { _, _ in store.changed() }
        .onChange(of: store.theme.idleEnabled) { _, _ in store.changed() }
        .onChange(of: store.theme.clickEnabled) { _, _ in store.changed() }
        .onChange(of: store.theme.excludedBundleIDs) { _, _ in store.changed() }
    }
}
