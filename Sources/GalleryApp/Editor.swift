import SwiftUI
import GalleryCore

private struct ThemeToolbarSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        }
    }
}

struct GalleryEditor: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var runtime: CursorRuntime
    @ObservedObject var preferences: AppPreferences
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playing = true
    @State private var selectedFrame = 0
    @State private var previewStart = Date()
    @State private var showSettings = false
    @State private var adjustingSize = false
    @State private var showImport = false
    @State private var showRoleSource = false
    @State private var themeToDelete: LibraryTheme?
    @State private var showingTheme = false
    @State private var selectedGalleryThemeID: String?
    @State private var showLoadingProgress = false
    @State private var extraStartSlotExpanded = false
    @State private var extraStartIconVisible = false
    @State private var toolbarPresentationGeneration = UUID()
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
                ThemeGallery(store: store, runtime: runtime, selection: $selectedGalleryThemeID, open: openTheme, importTheme: { showImport = true }) { folder in
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
        .disabled(store.importing && showingTheme)
        .allowsHitTesting(!store.importing)
        .sheet(isPresented: $showSettings) { InteractionSettings(store: store, runtime: runtime) }
        .sheet(isPresented: $showImport) { ImportThemePanel(store: store) }
        .sheet(item: $store.importReview, onDismiss: { store.cancelImportReview() }) { review in ImportReviewSheet(store: store, review: review) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.importing, let url = urls.first else { return false }
            store.importURL(url); return true
        }
        .alert("Gallery", isPresented: Binding(get: { store.message != nil || runtime.error != nil }, set: { if !$0 { store.message = nil; runtime.error = nil } })) {
            Button(L("好")) { store.message = nil; runtime.error = nil }
        } message: { Text(runtime.error ?? store.message ?? "") }
        .onChange(of: store.selectedRole) { _, _ in selectedFrame = 0; previewStart = Date() }
        .onChange(of: store.selectedMotion) { _, _ in selectedFrame = 0; previewStart = Date() }
        .onAppear { editorActive = NSApp.isActive }
        .background(EditorVisibilityReader(visible: $editorVisible).frame(width: 0, height: 0))
        .onChange(of: store.selectedThemeID) { _, id in
            selectedGalleryThemeID = id
            if openingThemeID == id { showingTheme = true; openingThemeID = nil }
            selectedFrame = 0; previewStart = Date()
        }
        .onChange(of: store.library.map(\.id)) { _, ids in
            if let selectedGalleryThemeID, !ids.contains(selectedGalleryThemeID) { self.selectedGalleryThemeID = nil }
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
        .task(id: store.importing) {
            showLoadingProgress = false
            guard store.importing else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, store.importing else { return }
            showLoadingProgress = true
        }
        .overlay(alignment: .topTrailing) {
            if store.importing && showLoadingProgress {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(openingThemeID == nil ? L("正在处理主题…") : L("正在打开主题…")).font(.callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(16).allowsHitTesting(false)
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
                            Text(store.roleIndex.map { store.theme.roles[$0].localizedName } ?? L("光标")).font(.largeTitle.bold())
                            Text(L("直接调整热点与动画，自动保存到当前主题。")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.editingActiveTheme { Button(L("暂停并编辑")) { runtime.stop() } }

                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L("像素风格"), isOn: Binding(get: { store.theme.appearance.pixelArt }, set: {
                            var appearance = store.theme.appearance; appearance.pixelArt = $0; store.setAppearance(appearance)
                        }))
                            .toggleStyle(.checkbox).fixedSize()
                            .disabled(store.editingActiveTheme).accessibilityIdentifier("theme-pixel-art")
                        Text(L("保留清晰的像素边缘，忽略本主题的抗锯齿设置；橱窗、预览与实际光标使用相同规则。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        NumericSlider(title: L("主题整体大小"), value: Binding(get: { store.theme.pointerScale }, set: {
                            store.setThemeScale($0)
                        }), range: 25...300, unit: "%", multiplier: 100, onTrackingChanged: { adjustingSize = $0 })
                        Button(L("还原")) { store.setThemeScale(1) }
                        Text(L("仅影响当前主题")).font(.caption).foregroundStyle(.secondary)
                    }
                    if store.importing {
                        HStack { ProgressView().controlSize(.small); Text(L("正在转换和整理动画，请稍候…")) }
                    }
                    if let index = store.roleIndex {
                        roleControls(store.theme.roles[index])
                        Text(store.theme.roles[index].splitClickAnimation
                             ? L("已添加按住动画：按住时持续播放，松开时播放松手动画。")
                             : L("未添加按住动画：点击后自动连播按下与松手动画。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(L("动画状态"), selection: $store.selectedMotion) {
                        ForEach(Motion.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if store.selectedMotion == .idle, let index = store.roleIndex { idleTiming(store.theme.roles[index]) }
                    if let index = store.roleIndex { variantControls(store.theme.roles[index]) }
                    if let clip = store.clip {
                        clipEditor(clip)
                    } else {
                        ContentUnavailableView {
                            Label(L("尚未设置\(store.selectedMotion.title)动画"), systemImage: "film.stack")
                        } description: {
                            Text(L("可以复制常态开始编辑，或直接导入动画文件。未设置时使用常态光标。"))
                        } actions: {
                            Button(L("从常态复制")) { store.createClip() }
                            Button(L("导入动画")) { store.importFrames(append: false) }.buttonStyle(.borderedProminent)
                        }.frame(minHeight: 360).disabled(store.editingActiveTheme)
                    }
                }.padding(28)
            }
            HStack {
                Circle().fill(store.saveStatus == L("已保存在本机") ? .green : .orange).frame(width: 5, height: 5)
                Text(store.saveStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L("Gallery \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("开发版")) · 基于 Mousecape")).font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, 22).padding(.vertical, 12).background(.bar)
        }
    }
    private var themeControlID: String? {
        let id = showingTheme ? store.selectedThemeID : selectedGalleryThemeID
        return id.flatMap { candidate in store.library.contains(where: { $0.id == candidate }) ? candidate : nil }
    }
    private var showsAdditionalStartControl: Bool {
        runtime.enabled && themeControlID.map { !store.isActiveTheme($0) } == true
    }
    @ToolbarContentBuilder private var themeToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if showingTheme {
                Button(action: showGallery) { Label(L("主题橱窗"), systemImage: "chevron.left") }.help(L("返回主题橱窗"))
            }
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(id: "gallery-theme-controls") { themeToolbarCapsule }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "gallery-theme-controls") { themeToolbarCapsule }
        }
    }
    private var themeToolbarCapsule: some View {
        HStack(spacing: 0) {
            // Keep one native toolbar item at its maximum width. Only this
            // internal slot changes width, so AppKit never relays out the
            // title-bar capsule or shifts its right-hand controls.
            ToolbarIconButton(title: L("使用选中主题"), symbol: "play.circle",
                tooltip: showsAdditionalStartControl && extraStartIconVisible ? L("开始使用选中的主题") : nil,
                identifier: "start-selected-theme", enabled: !store.importing && themeControlID != nil && showsAdditionalStartControl,
                action: startSelectedTheme)
                .frame(width: 34, height: 30)
                .frame(width: extraStartSlotExpanded ? 34 : 0, alignment: .trailing)
                .clipped().opacity(extraStartIconVisible ? 1 : 0)
                .allowsHitTesting(showsAdditionalStartControl && extraStartIconVisible)
                .accessibilityHidden(!showsAdditionalStartControl || !extraStartIconVisible)
            ToolbarIconButton(title: runtime.enabled ? L("停用并恢复") : (showingTheme ? L("使用此主题") : L("使用选中主题")),
                symbol: runtime.enabled ? "pause.circle" : "play.circle",
                tooltip: runtime.enabled ? L("停用并恢复光标") : (themeControlID == nil ? L("先选择一张主题卡片") : L("开始使用选中的主题")),
                identifier: runtime.enabled ? "stop-gallery-theme" : "start-selected-theme",
                enabled: !store.importing && (runtime.enabled || themeControlID != nil)) {
                if runtime.enabled {
                    if !showingTheme && selectedGalleryThemeID == nil { selectedGalleryThemeID = store.activeThemeID }
                    runtime.stop()
                } else { startSelectedTheme() }
            }
                .frame(width: 34, height: 30)
            ToolbarIconButton(title: L("导入主题"), symbol: "plus", tooltip: L("导入主题"), identifier: "import-theme", enabled: !store.importing) { showImport = true }
                .frame(width: 34, height: 30)
            ToolbarIconButton(title: L("交互与应用设置"), symbol: "slider.horizontal.3", tooltip: L("交互与应用设置"), identifier: "gallery-settings", enabled: !store.importing) { showSettings = true }
                .frame(width: 34, height: 30)
        }
        .labelStyle(.iconOnly).font(.system(size: 18)).buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .modifier(ThemeToolbarSurface())
        .frame(width: 148, height: 38, alignment: .trailing)
        .onAppear {
            extraStartSlotExpanded = showsAdditionalStartControl
            extraStartIconVisible = showsAdditionalStartControl
        }
        .onDisappear { toolbarPresentationGeneration = UUID() }
        .onChange(of: showsAdditionalStartControl) { _, expanded in updateToolbarExpansion(expanded) }
    }
    private func updateToolbarExpansion(_ expanded: Bool) {
        let generation = UUID(); toolbarPresentationGeneration = generation
        let resize = Animation.easeInOut(duration: reduceMotion ? 0.12 : 0.2)
        let fade = Animation.easeOut(duration: reduceMotion ? 0.06 : 0.1)
        if expanded {
            withAnimation(resize, completionCriteria: .logicallyComplete) {
                extraStartSlotExpanded = true
            } completion: {
                guard toolbarPresentationGeneration == generation else { return }
                withAnimation(fade) { extraStartIconVisible = true }
            }
        } else {
            // Never clip a visible symbol against a moving capsule edge.
            withAnimation(fade, completionCriteria: .logicallyComplete) {
                extraStartIconVisible = false
            } completion: {
                guard toolbarPresentationGeneration == generation else { return }
                withAnimation(resize) { extraStartSlotExpanded = false }
            }
        }
    }
    private func startSelectedTheme() {
        if let id = themeControlID { store.selectTheme(id, activate: true) }
    }
    private func openTheme(_ id: String) {
        guard !store.importing else { return }
        selectedGalleryThemeID = id
        playing = true; previewStart = Date(); openingThemeID = id
        store.selectTheme(id)
        if store.selectedThemeID == id { showingTheme = true; openingThemeID = nil }
    }
    private func showGallery() {
        playing = false; showingTheme = false; openingThemeID = nil
        selectedGalleryThemeID = store.selectedThemeID
        store.saveIfNeeded()
    }
    @ViewBuilder private func themeActions(_ folder: LibraryTheme) -> some View {
        Button(L("打开主题")) { openTheme(folder.id) }.disabled(store.importing)
        if store.isActiveTheme(folder.id) {
            Button(L("停用并恢复光标")) { runtime.stop() }.disabled(store.importing)
        } else {
            Button(L("使用此主题")) { store.selectTheme(folder.id, activate: true) }.disabled(store.importing)
        }
        Divider()
        Button(L("重命名…")) { themeToRename = folder }.disabled(store.importing)
        Button(L("导出 Gallery 主题…")) { store.exportTheme(folder.id) }.disabled(store.importing)
        Button(L("导出常态 Mousecape 主题…")) { store.exportTheme(folder.id, cape: true) }.disabled(store.importing)
        Divider()
        Button(L("删除整个主题…"), role: .destructive) { themeToDelete = folder }.disabled(store.importing)
    }
    private func deletionMessage(_ folder: LibraryTheme) -> String {
        var text = L("将删除「\(folder.localizedName)」的全部角色与动画。")
        if store.isActiveTheme(folder.id) { text += L("该主题正在使用，会先停用并恢复光标。") }
        text += L("原始安装包不受影响；主题文件可从废纸篓找回。")
        if store.library.count == 1 { text += L("删除后回到内置主题。") }
        return text
    }
    private var sidebarText: Color { colorScheme == .dark ? .white : .black }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            SidebarGalleryWordmark().padding(.top, 16).padding(.horizontal, 18)
            HStack(alignment: .top, spacing: 12) {
                if let data = store.library.first(where: { $0.id == store.selectedThemeID })?.cover, let image = EditorImageCache.image(data) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.theme.localizedName).font(.headline).lineLimit(3).foregroundStyle(sidebarText)
                    Text(store.isActiveTheme(store.selectedThemeID) ? L("正在使用") : L("正在浏览"))
                        .font(.caption).foregroundStyle(store.isActiveTheme(store.selectedThemeID) ? .green : .secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let folder = store.library.first(where: { $0.id == store.selectedThemeID }) {
                    Menu { themeActions(folder) } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("主题操作"))
                }
            }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 12)
            List {
                Section {
                    ForEach(store.visibleRoles) { role in roleRow(role) }
                } header: { Text(L("光标角色")).foregroundStyle(sidebarText.opacity(0.65)) }
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
                    Text(role.localizedName).font(.callout.weight(selected ? .semibold : .regular)).foregroundStyle(sidebarText)
                    Text(roleSubtitle(LibraryRole(role))).font(.caption2).foregroundStyle(sidebarText.opacity(0.6))
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 5).padding(.horizontal, 6).contentShape(RoundedRectangle(cornerRadius: 8))
                .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func roleSubtitle(_ role: LibraryRole) -> String {
        if role.usesNative { return L("系统原有") }
        if role.id.hasPrefix("com.apple.gallery.Imported.") { return L("未分类素材 · 可混用") }
        if CursorCatalog.assetOnly(role.id) { return L("应用自定义 · 可编辑素材") }
        return L("\(role.motionCount) 个动画状态")
    }
    private func idleTiming(_ role: CursorRole) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(L("待机等待"), systemImage: "moon.zzz").font(.headline)
                Spacer()
                Picker(L("等待方式"), selection: Binding(get: { role.idleDelayOverride != nil }, set: {
                    store.setRoleIdleDelay($0 ? store.theme.idleDelay : nil, for: role.id)
                })) {
                    Text(L("跟随全局")).tag(false)
                    Text(L("单独设置")).tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
            }
            if role.idleDelayOverride != nil {
                NumericSlider(title: L("静止后播放"), value: Binding(get: { store.theme.roles.first { $0.id == role.id }?.idleDelay(default: store.theme.idleDelay) ?? store.theme.idleDelay }, set: {
                    store.setRoleIdleDelay($0, for: role.id)
                }), range: 1...60, unit: L("秒"), inputRange: 1...600, updatesWhileDragging: false).id(role.id + ":idle")
                Text(L("拖动调整 1–60 秒，也可直接输入至 600 秒。")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("使用全局默认：\(Int(store.theme.idleDelay)) 秒。仅此角色可单独覆盖。")).font(.callout).foregroundStyle(.secondary)
            }
            if !store.theme.idleEnabled { Text(L("全局待机动画已关闭，可在「交互与应用设置」中开启。")).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func variantControls(_ role: CursorRole) -> some View {
        HStack(spacing: 12) {
            let variants = role.variants[store.selectedMotion.rawValue] ?? []
            if variants.count > 1 {
                Picker(L("素材版本"), selection: Binding(get: { role.selectedVariants[store.selectedMotion.rawValue] ?? "" }, set: {
                    store.selectVariant($0, for: store.selectedMotion); selectedFrame = 0; previewStart = Date()
                })) {
                    if role.selectedVariants[store.selectedMotion.rawValue] == nil { Text(L("当前素材")).tag("") }
                    ForEach(variants) { variant in Text(variant.localizedName).tag(variant.id) }
                }.frame(maxWidth: 440)
                if let clip = store.clip { Text(clip.frames.count > 1 ? L("动态 · \(clip.frames.count) 帧") : L("静态 · 单帧")).font(.caption).foregroundStyle(.secondary) }
            } else { Text(L("素材版本")).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Button(L("添加其他版本…")) { store.importVariant() }
        }.disabled(store.editingActiveTheme)
    }
    private var statusBar: some View {
        HStack(spacing: 9) {
            Image(systemName: runtime.enabled ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(runtime.enabled ? .green : .secondary)
            ThemeStatusSummary(
                active: store.activeThemeName.map { L("正在使用：") + $0 } ?? (runtime.enabled ? L("自定义光标已启用") : L("自定义光标已停用")),
                browsing: runtime.enabled && !store.isActiveTheme(store.selectedThemeID) ? L("浏览：\(store.theme.localizedName)") : nil,
                detail: runtime.status)
            Spacer()
            if runtime.hasRecovery && !runtime.enabled { Button(L("恢复上次光标")) { runtime.recover() } }
        }.padding(.horizontal, 24).padding(.vertical, 13).background(.quaternary.opacity(0.35))
    }
    @ViewBuilder private func clipEditor(_ clip: CursorClip) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 12) {
                TimelineView(.animation(minimumInterval: max(1.0 / 60, clip.frameDuration), paused: !playing || clip.frames.count < 2 || !editorActive || !editorVisible || store.editingActiveTheme || adjustingSize || showSettings || showImport || store.importReview != nil || showRoleSource || themeToRename != nil || themeToDelete != nil)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(previewStart))
                    let n = playing ? Int(elapsed / clip.frameDuration) : selectedFrame
                    let index = playing && !store.selectedMotion.loops ? min(n, clip.frames.count - 1) : n % clip.frames.count
                    HotspotPreview(clip: clip, frame: max(0, min(index, clip.frames.count - 1)), appearance: store.theme.appearance, editable: !store.editingActiveTheme) { x, y in
                        store.edit { $0.hotX = x; $0.hotY = y }
                    }
                    .onChange(of: !store.selectedMotion.loops && elapsed >= clip.duration) { _, finished in
                        if finished && playing { selectedFrame = clip.frames.count - 1; playing = false }
                    }
                }.frame(minWidth: 320, minHeight: 300).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                HStack {
                    Button { playing.toggle(); previewStart = Date() } label: {
                        Label(store.editingActiveTheme ? L("预览已暂停") : (clip.frames.count < 2 ? L("静态预览") : (playing ? L("暂停预览") : L("播放预览"))), systemImage: playing ? "pause.fill" : "play.fill")
                    }.disabled(store.editingActiveTheme || clip.frames.count < 2)
                        .help(store.editingActiveTheme ? L("先暂停此主题，再播放编辑器预览。") : L("播放或暂停预览"))
                    Button { previewStart = Date(); playing = true } label: { Image(systemName: "backward.end.fill") }
                        .help(L("重新播放")).disabled(store.editingActiveTheme || clip.frames.count < 2)
                    Spacer()
                    Text(L("\(clip.frames.count) 帧 · \(clip.duration, specifier: "%.2f") 秒")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(L("在预览中点击，设置实际点击位置。红色十字为热点。")).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text(L("热点与尺寸")).font(.headline)
                number(L("热点 X"), value: clip.hotX, range: 0...max(0, clip.width - 0.01)) { v in store.edit { $0.hotX = v } }
                number(L("热点 Y"), value: clip.hotY, range: 0...max(0, clip.height - 0.01)) { v in store.edit { $0.hotY = v } }
                number(L("宽度"), value: clip.width, range: 1...128) { v in store.edit { $0.width = v; $0.hotX = min($0.hotX, v - 0.01) } }
                number(L("高度"), value: clip.height, range: 1...128) { v in store.edit { $0.height = v; $0.hotY = min($0.hotY, v - 0.01) } }
                Text(L("以上单位均为逻辑点，适配 Retina 屏幕。")).font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(L("播放速度")).font(.headline)
                number(L("每秒帧数"), value: 1 / clip.frameDuration, range: 0.1...240) { v in store.edit { $0.frameDuration = 1 / v } }
                Text(store.selectedMotion.loops ? L("此状态循环播放。") : L("播放一次后进入下一状态；提前松手会立即播放松手动画。"))
                    .font(.caption).foregroundStyle(.secondary)
                if clip.frames.count > 24 {
                    Label(L("Gallery 保留完整帧；导出 Mousecape 时采样为 24 帧。"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 210).disabled(store.editingActiveTheme)
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("帧序列")).font(.headline)
                Spacer()
                Button(L("替换动画…")) { store.importFrames(append: false); selectedFrame = 0 }
                Button(L("追加帧…")) { store.importFrames(append: true) }
                if store.selectedMotion != .normal { Button(L("移除此状态"), role: .destructive) { store.removeClip() } }
            }.disabled(store.editingActiveTheme)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 9) {
                    ForEach(Array(clip.frames.enumerated()), id: \.offset) { index, data in
                        Button { selectedFrame = index; playing = false } label: {
                            VStack(spacing: 5) {
                                if let image = EditorImageCache.image(data) { Image(nsImage: image).resizable().interpolation(store.theme.appearance.effectiveSmoothEdges ? .high : .none).scaledToFit().frame(width: 44, height: 44) }
                                Text(String(format: "%02d", index + 1)).font(.caption2.monospacedDigit())
                            }.padding(8).background(selectedFrame == index ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedFrame == index ? Color.accentColor : .clear))
                        }.buttonStyle(.plain).contextMenu {
                            Button(L("复制当前帧")) { selectedFrame = index; duplicateFrame(index) }.disabled(store.editingActiveTheme)
                            Button(L("设为主题封面")) { selectedFrame = index; playing = false; store.setThemeCover(at: index) }
                        }
                    }
                }.padding(.vertical, 2)
            }
            HStack {
                Button { moveFrame(-1) } label: { Label(L("前移"), systemImage: "arrow.left") }.disabled(selectedFrame <= 0)
                Button { moveFrame(1) } label: { Label(L("后移"), systemImage: "arrow.right") }.disabled(selectedFrame >= clip.frames.count - 1)
                Button { duplicateFrame(selectedFrame) } label: { Label(L("复制当前帧"), systemImage: "doc.on.doc") }
                    .disabled(clip.frames.count >= 240)
                Button(L("删除当前帧"), role: .destructive) {
                    store.edit { $0.frames.remove(at: min(selectedFrame, $0.frames.count - 1)) }
                    selectedFrame = max(0, min(selectedFrame, clip.frames.count - 2))
                }.disabled(clip.frames.count <= 1)
                Spacer()
                Text(L("支持 PNG 序列、GIF、Windows CUR / ANI")).font(.caption).foregroundStyle(.secondary)
            }.disabled(store.editingActiveTheme)
            HStack {
                let current = max(0, min(selectedFrame, clip.frames.count - 1))
                Button {
                    playing = false; store.setThemeCover(at: current)
                } label: {
                    Label(store.theme.coverFrame == clip.frames[current] ? L("已设为主题封面") : L("设为主题封面"), systemImage: "photo")
                }.disabled(store.importing || store.theme.coverFrame == clip.frames[current])
                if store.theme.coverFrame != nil { Button(L("恢复默认封面")) { store.resetThemeCover() }.disabled(store.importing) }
                Spacer()
                Text(L("当前帧 \(current + 1) / \(clip.frames.count)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(18).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
    private func duplicateFrame(_ index: Int) {
        if let inserted = store.duplicateFrame(at: index) { selectedFrame = inserted; playing = false }
    }
    private func roleControls(_ role: CursorRole) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        NumericSlider(title: L("此角色大小"), value: Binding(get: { store.theme.roles.first { $0.id == role.id }?.scale ?? role.scale }, set: { store.setRoleScale($0, for: role.id) }),
                                      range: 25...300, unit: "%", multiplier: 100, onTrackingChanged: { adjustingSize = $0 }).disabled(role.usesNative).id(store.selectedThemeID + role.id + ":size")
                        Button(L("还原")) { store.setRoleScale(1, for: role.id) }.disabled(role.usesNative)
                    }
                    Text(L("叠加主题整体大小；右侧按实际大小静态预览。")).font(.caption).foregroundStyle(.secondary)
                }
                RoleSizePreview(clip: role.clip(.normal), scale: store.theme.pointerScale * role.scale, appearance: store.theme.appearance)
            }
            HStack {
                Toggle(L("使用系统原有光标"), isOn: Binding(get: { role.usesNative }, set: { store.setUsesNative($0) }))
                Spacer()
                if let name = role.sourceThemeName { Text(L("素材来自：\(name)")).font(.caption).foregroundStyle(.secondary) }
                Button(L("从其他主题选取…")) { showRoleSource = true }
            }.disabled(store.editingActiveTheme)
            if store.editingActiveTheme { Text(L("暂停此主题后可更换角色来源；大小可以直接调节。")).font(.caption).foregroundStyle(.secondary) }
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

struct ImportThemePanel: View {
    @ObservedObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenImportGuide") private var hasSeenImportGuide = false
    @State private var showGuide = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Label(L("导入主题"), systemImage: "square.and.arrow.down").font(.title2.bold())
                Button { showGuide = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 19)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(L("查看导入说明")).accessibilityLabel(L("查看导入说明"))
                    .accessibilityIdentifier("import-guide-button")
                Spacer()
            }
            Text(L("选择文件或文件夹，也可以直接拖入 Gallery。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                formatRow(L("已整理好的主题"), details: ".gallery · .cape", icon: "photo.stack")
                Divider()
                formatRow(L("Windows 光标素材"), details: L("CUR · ANI · INF · EXE · ZIP · 文件夹"), icon: "shippingbox")
            }.padding(18).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            Text(L("仅提取光标素材，不运行 Windows 程序。多套素材可在下一步选择。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("载入内置主题")) { dismiss(); store.resetDemo() }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("选择文件或文件夹…")) {
                    dismiss(); DispatchQueue.main.async { store.openTheme() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
        .sheet(isPresented: $showGuide, onDismiss: { hasSeenImportGuide = true }) { ImportGuideSheet() }
        .onAppear { if !hasSeenImportGuide { showGuide = true } }
    }
    private func formatRow(_ title: String, details: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(details).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ImportGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "info.circle").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.secondary)
                Text(L("导入说明")).font(.title2.bold())
                Text(L("先准备素材，再选择与应用主题。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("GALLERY").font(.system(size: 10, weight: .medium)).kerning(2.5).foregroundStyle(.tertiary)
            }.padding(24).frame(width: 168, alignment: .leading).frame(maxHeight: .infinity)
                .background(.quaternary.opacity(0.3))
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(L("支持的文件")).font(.title3.bold())
                        formatSection("square.stack", title: L("完整主题"), formats: ".gallery · .cape") {
                            Text(L(".gallery 保留角色、热点、各阶段动画、大小与外观设置。.cape 是 Mousecape 主题，包含常态光标；导入后可在 Gallery 补充交互动画。"))
                        }
                        formatSection("cursorarrow", title: L("Windows 光标与素材文件夹"), formats: "CUR · ANI · INF") {
                            Text(L("CUR 是静态光标，ANI 是动态光标。可直接选择文件，或选择包含它们的文件夹。INF 用于映射角色，请将它与原来的素材目录一起保留。"))
                        }
                        formatSection("shippingbox", title: L("安装包与压缩包"), formats: "EXE · ZIP") {
                            Text(L("支持包含光标资源的 .NET、.NET 单文件与 Inno Setup 安装包，以及包含可用素材的 ZIP。单个包最大 2 GB；仅读取光标，不运行 Windows 程序，壁纸、应用图标与其他内容会跳过。"))
                            Text(L("并非所有 EXE 都内含可提取的素材。快捷安装入口、加密或其他不支持的封装导入失败时，请改用解压后的 CUR／ANI 文件夹。原文件不会修改。"))
                        }
                        Text(L("Windows 素材可能只包含常态动画。按下、按住与松手需要对应素材，可在导入后补充；已有主题缺少的其他版本也可在角色页添加。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider().padding(.vertical, 2)
                        Text(L("导入与使用")).font(.title3.bold())
                        guideStep("1", title: L("选择文件或文件夹"), detail: L("拖入 Gallery 窗口，或在导入面板点「选择文件或文件夹」。多套主题与同角色的多个版本会显示选择页，可先预览并勾选需要保留的内容。"))
                        guideStep("2", title: L("选中并开始使用"), detail: L("单击橱窗卡片选中主题，再点右上角开始按钮。若已有另一主题启用，会将其替换。"))
                        guideStep("3", title: L("进入编辑"), detail: L("再次单击已选中的卡片，或直接打开使用中的主题。可编辑角色素材、热点、帧序列与大小；使用中的主题需先停止，其他主题可继续编辑。"))
                        guideStep("4", title: L("停止或退出"), detail: L("停止按钮会恢复系统光标。关闭窗口后仍在后台运行，可从菜单栏重开；也可在设置中点「退出 Gallery」，保存并恢复光标后退出。"))
                    }.padding(.trailing, 12).padding(.vertical, 2)
                }
                Divider()
                HStack(alignment: .center, spacing: 18) {
                    Text(L("以后可通过导入标题旁的 ⓘ 再次查看。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("知道了")) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }.padding(28)
        }.frame(width: 780, height: 720)
    }
    private func formatSection<Content: View>(_ symbol: String, title: String, formats: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.headline)
            Text(formats).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9, content: content)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func guideStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).background(.quaternary, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HotspotPreview: View {
    let clip: CursorClip
    let frame: Int
    let appearance: CursorAppearance
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
                    Image(nsImage: image).resizable().interpolation(appearance.effectiveSmoothEdges ? .high : .none)
                        .shadow(color: .black.opacity(appearance.shadow ? 0.32 : 0), radius: 1.5 * scale, x: 0, y: scale)
                        .frame(width: width, height: height).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
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
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("交互与应用")).font(.title2.bold())
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("界面语言"))
                    Text(L("重新打开 Gallery 后生效。")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("界面语言"), selection: Binding(get: { preferences.interfaceLanguage }, set: { preferences.setInterfaceLanguage($0) })) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 170).accessibilityIdentifier("interface-language")
            }
            GroupBox(L("启动")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L("开机自启动（登录后运行）"), isOn: Binding(get: { preferences.launchAtLogin || preferences.needsApproval }, set: { preferences.setLaunchAtLogin($0) }))
                    if preferences.needsApproval {
                        HStack {
                            Text(L("请在系统登录项中允许 Gallery。"))
                            Button(L("打开登录项设置")) { preferences.openLoginSettings() }
                        }.font(.caption)
                    }
                    Toggle(L("启动后自动应用当前主题"), isOn: $preferences.applyAtLaunch)
                    Toggle(L("启用主题时隐藏 Dock 图标"), isOn: $preferences.hideDockIconWhileRunning)
                    Text(runtime.enabled && preferences.hideDockIconWhileRunning
                         ? (NSApp.activationPolicy() == .accessory ? L("Dock 图标已隐藏，可从菜单栏重新打开 Gallery。") : L("正在隐藏 Dock 图标…"))
                         : L("隐藏后可从菜单栏重新打开 Gallery；停用主题后恢复 Dock 图标。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("请将应用放入「应用程序」后开启。存在待恢复记录时不会自动应用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(L("快速甩动鼠标时放大主题光标"), isOn: $preferences.shakeToLocate)
                .help(L("连续快速往返甩动时临时放大，随后恢复。此开关控制 Gallery 的放大效果，系统自带的定位鼠标设置独立生效。"))
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L("光标外观 · 当前主题")) {
                  VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("抗锯齿（平滑缩放）"), isOn: Binding(get: { store.theme.appearance.smoothEdges }, set: {
                        var appearance = store.theme.appearance; appearance.smoothEdges = $0; store.setAppearance(appearance)
                    }))
                    if store.theme.appearance.pixelArt {
                        Text(L("此主题使用像素风格；抗锯齿设置会在关闭像素风格后生效。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(L("添加柔和阴影"), isOn: Binding(get: { store.theme.appearance.shadow }, set: {
                        var appearance = store.theme.appearance; appearance.shadow = $0; store.setAppearance(appearance)
                    }))
                    Text(L("阴影在应用主题时预先生成并缓存，会增加准备时间和部分缓存；移动时不实时计算阴影。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if store.editingActiveTheme { Text(L("暂停此主题后可更改外观。")).font(.caption).foregroundStyle(.secondary) }
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(L("交互动画")) {
                  VStack(alignment: .leading, spacing: 14) {
                    Toggle(L("鼠标静止时播放待机动画"), isOn: $store.theme.idleEnabled)
                    NumericSlider(title: L("默认等待"), value: Binding(get: { store.theme.idleDelay }, set: { store.setDefaultIdleDelay($0) }), range: 1...60, unit: L("秒"), inputRange: 1...600, updatesWhileDragging: false)
                    Text(L("各角色可在「待机」页单独设置，未设置时使用此默认值。")).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("播放左键按下、按住与松手动画"), isOn: $store.theme.clickEnabled)
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(L("在这些应用中暂停交互动画")) {
                  VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.theme.excludedBundleIDs, id: \.self) { id in
                        HStack { Text(id).font(.caption); Spacer(); Button(L("移除")) { store.theme.excludedBundleIDs.removeAll { $0 == id } } }
                    }
                    Menu(L("添加正在运行的应用…")) {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }, id: \.processIdentifier) { app in
                            if let id = app.bundleIdentifier {
                                Button(app.localizedName ?? id) { if !store.theme.excludedBundleIDs.contains(id) { store.theme.excludedBundleIDs.append(id) } }
                            }
                        }
                    }
                    Text(L("暂停交互时仍保留常态主题。游戏或使用自定义光标的应用可以加入此列表。")).font(.caption).foregroundStyle(.secondary)
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.vertical, 2).disabled(store.editingActiveTheme)
            HStack {
                Button(L("检查输入监控授权")) { runtime.requestInputAccess() }
                Button(L("打开隐私设置")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
            }
            Text(L("Gallery 只观察鼠标，不拦截点击、不记录键盘。锁屏、休眠时尽量恢复常态。请先退出 Mousecape 的自动重应用助手，避免两个工具同时修改主题。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(runtime.diagnostics).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            UpdateSettingsSection()
            HStack {
                Button(L("退出 Gallery")) { NSApp.terminate(nil) }
                    .help(L("保存修改并恢复系统光标后退出。"))
                    .accessibilityIdentifier("quit-gallery")
                Spacer()
                Button(L("完成")) { store.changed(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(width: 590, height: 790)
        .onAppear { preferences.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in preferences.refreshLoginStatus() }
        .alert(L("启动设置"), isPresented: Binding(get: { preferences.error != nil }, set: { if !$0 { preferences.error = nil } })) {
            Button(L("好")) { preferences.error = nil }
        } message: { Text(preferences.error ?? "") }
        .onChange(of: store.theme.idleEnabled) { _, _ in store.changed() }
        .onChange(of: store.theme.clickEnabled) { _, _ in store.changed() }
        .onChange(of: store.theme.excludedBundleIDs) { _, _ in store.changed() }
    }
}
