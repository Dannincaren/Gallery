import SwiftUI
import GalleryCore

@MainActor
final class ThemeMappingWindowPresenter: NSObject, NSWindowDelegate {
    private var controller: NSWindowController?
    private var themeID: String?
    private var draft: ThemeMappingDraft?
    private weak var store: GalleryStore?
    private let sessionID = UUID()
    func show(for store: GalleryStore, sourceID: String? = nil) {
        guard store.canEditMapping else { return }
        if themeID == store.selectedThemeID, let window = controller?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil); if let sourceID { self.draft?.focus(sourceID) }; return
        }
        if let window = controller?.window {
            guard windowShouldClose(window) else { return }; window.close()
        }
        let draft = ThemeMappingDraft(theme: store.theme)
        guard store.beginMappingEditor(sessionID) else { return }
        self.store = store
        if let sourceID { draft.focus(sourceID) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("自定义映射") + " · " + store.theme.localizedName
        window.minSize = NSSize(width: 780, height: 540)
        window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSHostingView(rootView: ThemeMappingEditor(store: store, draft: draft,
            themeID: store.selectedThemeID, appearance: store.theme.appearance,
            finished: { [weak window] in window?.close() }))
        // The scrollable board must never make its window grow to the full
        // document height when artwork or expanded variants change layout.
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setContentSize(NSSize(width: 780, height: 760))
        self.draft = draft; themeID = store.selectedThemeID
        controller = NSWindowController(window: window)
        window.center(); controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard draft?.hasChanges == true else { return true }
        let alert = NSAlert()
        alert.messageText = L("放弃未保存的映射？")
        alert.informativeText = L("尚未保存，主题中的原有角色不会改变。")
        alert.addButton(withTitle: L("继续编辑")); alert.addButton(withTitle: L("放弃更改"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        store?.endMappingEditor(sessionID); store = nil
        controller = nil; draft = nil; themeID = nil
    }
}

struct ThemeMappingEditor: View {
    @ObservedObject var store: GalleryStore
    @ObservedObject var draft: ThemeMappingDraft
    let themeID: String
    let appearance: CursorAppearance
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("hasSeenMappingGuide") private var hasSeenGuide = false
    @State private var showGuide = false
    @State private var selection = MappingSelection()
    @State private var sourcePicks: [String: RoleMappingChoice] = [:]
    @State private var layout = MappingBoardLayout()
    @State private var nativeClips: [String: CursorClip] = [:]
    @State private var visibleRect = CGRect(x: 0, y: 0, width: 780, height: 650)
    @State private var active = NSApp.isActive
    @State private var visible = false
    @State private var prompt: MappingSavePrompt?
    @State private var nextPrompt: MappingSavePrompt?
    @State private var commitAfterDismiss = false
    @State private var deleteAfterDismiss = false
    @State private var error: String?
    @State private var frames = MappingFrameCache()
    @State private var materialPresentations: [String: MappingMaterialPresentation] = [:]
    @State private var selectedLine: String?
    @State private var showRestore = false
    @State private var focusNative: String?
    @State private var scrollTarget: MappingScrollRequest?
    private let cardSize = 160.0
    private let columnGap = 390.0
    private let lineWidth = 6.5
    private var rowSpacing: Double { cardSize + 28 }
    private var editable: Bool { store.selectedThemeID == themeID && store.canEditMapping }
    private var mapping: ThemeMapping { draft.mapping }
    private var materialAppearance: CursorAppearance { store.selectedThemeID == themeID ? store.theme.appearance : appearance }
    private var nativeIDs: [String] { ThemeMapping.nativeRoles.map(\.id) }
    private struct MaterialRequest: Equatable { let assets: [MappingMaterialAsset]; let appearance: CursorAppearance }
    private var materialRequest: MaterialRequest {
        MaterialRequest(assets: mapping.sources.compactMap { source in
            guard let clip = mapping.role(for: displayedChoice(source))?.clip(.normal) else { return nil }
            return MappingMaterialAsset(id: source.id, clip: clip)
        }, appearance: materialAppearance)
    }
    private var slots: [String: Double] { layout.sources.isEmpty ? MappingLayout.arrangement(mapping, spacing: rowSpacing, cardHeight: cardSize).sources : layout.sources }
    private var nativeSlots: [String: Double] { layout.natives.isEmpty ? MappingLayout.arrangement(mapping, spacing: rowSpacing, cardHeight: cardSize).natives : layout.natives }
    private var contentHeight: Double {
        max(Double(nativeIDs.count) * rowSpacing, (slots.values.max() ?? 0) + rowSpacing) + 24
    }
    private var lineColor: Color {
        colorScheme == .dark ? Color(red: 0.89, green: 0.88, blue: 0.83) : Color(red: 0.23, green: 0.24, blue: 0.25)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { viewport in
                ScrollView {
                    board(width: viewport.size.width)
                        .background(MappingViewportReader(rect: $visibleRect, target: scrollTarget).frame(width: 0, height: 0))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EditorVisibilityReader(visible: $visible).frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .onAppear {
            layout = MappingLayout.arrangement(mapping, spacing: rowSpacing, cardHeight: cardSize)
            if let request = draft.focusRequest { focusSource(request.sourceID) }
        }
        .onChange(of: draft.focusRequest) { _, request in
            if let request { focusSource(request.sourceID) }
        }
        .onChange(of: visible) { _, shown in
            if shown && !hasSeenGuide { showGuide = true }
        }
        .onChange(of: mapping.bindings) { _, _ in
            selection.clear()
            if let id = selectedLine, mapping.bindings[id] == nil { selectedLine = nil }
            updateLayout(follow: true)
        }
        .alert(L("恢复导入时的对应关系？"), isPresented: $showRestore) {
            Button(L("取消"), role: .cancel) {}
            Button(L("恢复")) {
                focusNative = nil; clearSelection(); sourcePicks = [:]; draft.restoreImportDefaults()
                layout = MappingLayout.arrangement(mapping, spacing: rowSpacing, cardHeight: cardSize)
                scrollTarget = MappingScrollRequest(centerY: visibleRect.height / 2, animated: !reduceMotion)
            }
        } message: {
            Text(L("恢复当前保留素材的导入对应关系，可通过撤回恢复本次操作。此前已删除的素材无法找回；不会重置主题整体大小或像素风格。"))
        }
        .task { nativeClips = await NativeMappingArtwork.load() }
        .task(id: materialRequest) {
            let request = materialRequest
            let prepared = await frames.materials(request.assets, appearance: request.appearance,
                                                  available: CGSize(width: cardSize - 24, height: 84))
            if !Task.isCancelled { materialPresentations = prepared }
        }
        .onDisappear { visible = false; Task { await frames.clear() } }
        .sheet(isPresented: $showGuide, onDismiss: { hasSeenGuide = true }) { MappingGuideSheet() }
        .sheet(item: $prompt, onDismiss: advanceSave) { step in saveSheet(step) }
        .accessibilityIdentifier("theme-mapping-editor")
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L("自定义映射")).font(.title2.bold())
                Button { showGuide = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 18)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(L("查看映射说明")).accessibilityLabel(L("查看映射说明"))
                    .accessibilityIdentifier("mapping-guide-button")
                Spacer()
                Button { focusNative = nil; selection.clear(); sourcePicks = [:]; draft.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!draft.canUndo).help(L("撤回")).accessibilityLabel(L("撤回"))
                    .keyboardShortcut("z", modifiers: .command)
                Button { showRestore = true } label: { Image(systemName: "arrow.counterclockwise") }
                    .help(L("恢复导入时的对应关系")).accessibilityLabel(L("恢复导入时的对应关系"))
                Button(L("保存")) {
                    error = nil
                    if let first = MappingSavePrompt.first(for: mapping) { prompt = first }
                    else { save(deleteUnused: false) }
                }.buttonStyle(.borderedProminent).disabled(!editable || mapping.bindings.isEmpty)
                    .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("finish-theme-mapping")
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if !editable {
                Text(store.selectedThemeID != themeID ? L("浏览的主题已改变，请重新打开映射窗口。") : L("请先停用主题，再编辑映射。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 28).padding(.vertical, 20)
            .background(Color(nsColor: .windowBackgroundColor).contentShape(Rectangle()).onTapGesture { clearSelection() })
    }
    @ViewBuilder private func saveSheet(_ step: MappingSavePrompt) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if step == .native {
                Text(L("未配对角色使用系统光标？")).font(.title2.bold())
                Text(L("以下 \(nativeIDs.count - mapping.bindings.count) 个原生角色尚未配对，应用主题时会保留 macOS 原生光标。是否继续？"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                confirmationList(native: true)
                HStack {
                    Button(L("返回调整")) { prompt = nil }
                    Spacer()
                    Button(L("使用系统光标并继续")) {
                        nextPrompt = MappingSavePrompt.afterNative(for: mapping)
                        commitAfterDismiss = nextPrompt == nil; prompt = nil
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                Text(L("删除未使用的主题素材？")).font(.title2.bold())
                Text(L("以下 \(mapping.unusedSources.count) 个主题角色未用于映射。删除会从当前主题的本地存档中移除这些素材及不再引用的图像，以节省空间；仍被其他角色使用的图像会保留。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                confirmationList(native: false)
                HStack(spacing: 12) {
                    Button(L("返回调整")) { prompt = nil }
                    Spacer()
                    Button(L("删除并保存")) { deleteAfterDismiss = true; commitAfterDismiss = true; prompt = nil }
                    Button(L("保留并保存")) { commitAfterDismiss = true; prompt = nil }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(26).frame(width: 600, height: 540)
    }
    private func confirmationList(native: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if native {
                    ForEach(ThemeMapping.nativeRoles.filter { mapping.bindings[$0.id] == nil }, id: \.id) { item in
                        confirmationRow(title: NativeCursorCatalog.displayName(item.id), detail: L("使用 macOS 原生光标"), clip: nativeClips[item.id], native: true)
                    }
                } else {
                    ForEach(mapping.unusedSources) { item in
                        confirmationRow(title: item.localizedName, detail: L("未用于任何原生角色"), clip: item.clip(.normal), native: false)
                    }
                }
            }.padding(10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
    private func confirmationRow(title: String, detail: String, clip: CursorClip?, native: Bool) -> some View {
        HStack(spacing: 18) {
            MappingCursorPreview(clip: clip, appearance: native ? CursorAppearance() : materialAppearance, running: false, frames: frames, sizing: native ? .fit : .material)
                .frame(width: 64, height: 64).background(native ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .environment(\.colorScheme, native ? .light : colorScheme)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func updateLayout(follow: Bool) {
        let next = MappingLayout.arrangement(mapping, spacing: rowSpacing, previous: layout.sources, cardHeight: cardSize)
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.35)) { layout = next }
        if follow, let id = focusNative, let y = next.natives[id] {
            let center = y + 20 + cardSize / 2
            if abs(center - visibleRect.midY) > visibleRect.height * 0.3 {
                scrollTarget = MappingScrollRequest(centerY: center, animated: !reduceMotion)
            }
        }
    }
    private func removeConnection(_ id: String) {
        focusNative = id; selection.clear(); selectedLine = nil; draft.bind(nil, to: id)
    }
    private func advanceSave() {
        if let next = nextPrompt { nextPrompt = nil; prompt = next }
        else if commitAfterDismiss {
            let deleting = deleteAfterDismiss; commitAfterDismiss = false; deleteAfterDismiss = false
            save(deleteUnused: deleting)
        }
    }
    private func save(deleteUnused: Bool) {
        do { try store.applyMapping(mapping, to: themeID, deleteUnused: deleteUnused); finished() }
        catch { self.error = error.localizedDescription }
    }
    private func focusSource(_ id: String) {
        guard let source = mapping.sources.first(where: { $0.id == id }), let y = slots[id] else { return }
        selection.clear(); selectedLine = nil
        _ = selection.selectSource(displayedChoice(source))
        scrollTarget = MappingScrollRequest(centerY: y + 20 + cardSize / 2, animated: !reduceMotion)
    }
    private func clearSelection() { selection.clear(); selectedLine = nil }
    private func selectNative(_ id: String) {
        selectedLine = nil
        if let source = selection.selectNative(id) {
            focusNative = id; selectedLine = id; draft.bind(source, to: id)
        }
    }
    private func selectSource(_ choice: RoleMappingChoice) {
        selectedLine = nil; sourcePicks[choice.sourceID] = choice
        if let native = selection.selectSource(choice) { focusNative = native; selectedLine = native; draft.bind(choice, to: native) }
    }
    private func chooseVersion(_ choice: RoleMappingChoice) {
        guard selection.source != choice else { return }
        selectSource(choice)
    }
    private func displayedChoice(_ source: CursorRole) -> RoleMappingChoice {
        if let chosen = sourcePicks[source.id] { return chosen }
        return nativeIDs.compactMap { mapping.bindings[$0] }.first { $0.sourceID == source.id } ?? RoleMappingChoice(sourceID: source.id)
    }
    private func board(width: Double) -> some View {
        let gap = min(columnGap, max(120, width - cardSize * 2 - 60))
        let leftX = max(30, (width - cardSize * 2 - gap) / 2)
        let rightX = leftX + cardSize + gap
        let positions = slots
        return ZStack(alignment: .topLeading) {
            ForEach(nativeIDs, id: \.self) { id in
                if let choice = mapping.bindings[id], let nativeY = nativeSlots[id],
                   let source = mapping.sources.first(where: { $0.id == choice.sourceID }), let slot = positions[source.id] {
                    let line = MappingConnection(start: CGPoint(x: leftX + cardSize + 13, y: nativeY + 20 + cardSize / 2),
                                                 end: CGPoint(x: rightX - 13, y: slot + 20 + cardSize / 2))
                    line.stroke(selectedLine == id && colorScheme != .dark ? Color(white: 0.55) : lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .shadow(color: lineColor.opacity(colorScheme == .dark ? (selectedLine == id ? 0.9 : 0.28) : 0), radius: selectedLine == id ? 8 : 3)
                        .zIndex(selectedLine == id ? 2 : 1)
                        .allowsHitTesting(false)
                        .accessibilityElement().accessibilityLabel(L("\(GalleryLocalization.label(NativeCursorCatalog.title(id))) 绑定到 \(source.localizedName)"))
                        .accessibilityAddTraits(selectedLine == id ? [.isSelected] : [])
                        .accessibilityAction(named: Text(L("取消绑定"))) { removeConnection(id) }
                }
            }
            ForEach(ThemeMapping.nativeRoles, id: \.id) { descriptor in
                let y = (nativeSlots[descriptor.id] ?? 0) + 20
                MappingShowcase(title: NativeCursorCatalog.displayName(descriptor.id), clip: nativeClips[descriptor.id],
                    selected: selection.native == descriptor.id, size: cardSize,
                    nativeSizing: MappingPreviewSizing.nativeMode(id: descriptor.id, clips: nativeClips), port: .right, portColor: lineColor,
                    animate: canAnimate(y: y), appearance: CursorAppearance(), frames: frames,
                    action: { selectNative(descriptor.id) })
                    .overlay(alignment: .topLeading) {
                        if (nativeClips[descriptor.id]?.frames.count ?? 0) > 24,
                           NativeCursorCatalog.identity(descriptor.id) != "com.apple.coregraphics.Wait" {
                            Text(L("系统保留")).font(.caption2.weight(.medium)).foregroundStyle(.red).padding(8)
                                .help(L("当前系统无法安全替换此角色；运行时保留原生光标。"))
                        }
                    }
                    .frame(width: cardSize, height: cardSize).offset(x: leftX, y: y)
                    .help(NativeCursorCatalog.displayName(descriptor.id) + "\n" + descriptor.id).accessibilityIdentifier("mapping-native-" + descriptor.id)
                    .zIndex(10)
            }
            ForEach(mapping.sources) { source in
                let y = (positions[source.id] ?? 0) + 20
                let choice = displayedChoice(source)
                MappingSourceShowcase(source: source, choice: choice, selected: selection.source?.sourceID == source.id,
                    size: cardSize, inViewport: intersectsViewport(y: y),
                    prepared: materialPresentations[source.id],
                    appearance: materialAppearance, animate: canAnimate(y: y),
                    portColor: lineColor, frames: frames, action: { selectSource(choice) }, chooseVersion: chooseVersion)
                    .frame(width: cardSize, height: cardSize).offset(x: rightX, y: y).zIndex(10)
            }
            MappingBoardInput(cards: nativeIDs.compactMap { id in
                nativeSlots[id].map { CGRect(x: leftX, y: $0 + 20, width: cardSize, height: cardSize) }
            } + mapping.sources.compactMap { source in
                positions[source.id].map { CGRect(x: rightX, y: $0 + 20, width: cardSize, height: cardSize) }
            }, lines: nativeIDs.compactMap { id in
                guard let choice = mapping.bindings[id], let start = nativeSlots[id], let end = positions[choice.sourceID] else { return nil }
                return MappingInputLine(id: id, start: CGPoint(x: leftX + cardSize + 13, y: start + 20 + cardSize / 2),
                    end: CGPoint(x: rightX - 13, y: end + 20 + cardSize / 2))
            }, selected: selectedLine) { action in
                switch action {
                case .select(let id): selection.clear(); selectedLine = id == selectedLine ? nil : id
                case .disconnect(let id): removeConnection(id)
                }
            }.frame(width: width, height: contentHeight).zIndex(20).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .topLeading).frame(height: contentHeight)
    }
    private func canAnimate(y: Double) -> Bool { active && visible && !showGuide && prompt == nil && intersectsViewport(y: y) }
    private func intersectsViewport(y: Double) -> Bool { y + cardSize > visibleRect.minY && y < visibleRect.maxY }
}

private struct MappingConnection: Shape {
    var start: CGPoint
    var end: CGPoint
    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(start.animatableData, end.animatableData) }
        set { start.animatableData = newValue.first; end.animatableData = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: start)
        let bend = (end.x - start.x) * 0.45
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return path
    }
}
private struct MappingShowcase: View {
    @Environment(\.colorScheme) private var colorScheme
    enum Port { case left, right }
    let title: String
    let clip: CursorClip?
    let selected: Bool
    var size: Double = 160
    var inViewport = true
    var prepared: MappingMaterialPresentation?
    var nativeSizing = MappingPreviewSizing.native
    let port: Port
    let portColor: Color
    let animate: Bool
    let appearance: CursorAppearance
    let frames: MappingFrameCache
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                MappingCursorPreview(clip: clip, appearance: appearance, running: animate, frames: frames,
                    sizing: port == .right ? nativeSizing : .material, inViewport: inViewport, prepared: prepared)
                    .environment(\.colorScheme, port == .right ? .light : colorScheme)
                    .frame(width: port == .right ? 84 : size - 24, height: 84)
                    .background {
                        // Some system PDFs are black without an outline. A
                        // light stage keeps the original glyph readable in
                        // dark appearance without recoloring the OS artwork.
                        if port == .right && colorScheme == .dark {
                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.94))
                        }
                    }
                Spacer(minLength: 4)
                Text(title).font(.system(size: port == .right ? 11 : 13, weight: .medium)).lineLimit(port == .right ? 4 : 2).multilineTextAlignment(.center)
                    .frame(height: 52).frame(maxWidth: .infinity).padding(.bottom, 10)
            }.padding(.horizontal, 10).padding(.top, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1) }
                .shadow(color: .black.opacity(selected ? 0.09 : 0.025), radius: selected ? 8 : 3, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? [.isSelected] : [])
            .overlay(alignment: port == .left ? .leading : .trailing) {
                // Outside the button label: pressed opacity cannot expose the
                // connection drawn underneath the opaque hollow port.
                Circle().fill(colorScheme == .dark ? Color(white: 0.12) : .white)
                    .overlay(Circle().strokeBorder(portColor, lineWidth: 2.5))
                    .frame(width: 12, height: 12).offset(x: port == .left ? -19 : 19)
                    .allowsHitTesting(false)
            }
    }
}

private struct MappingSourceShowcase: View {
    let source: CursorRole
    let choice: RoleMappingChoice
    let selected: Bool
    var size: Double = 160
    var inViewport = true
    var prepared: MappingMaterialPresentation?
    let appearance: CursorAppearance
    let animate: Bool
    let portColor: Color
    let frames: MappingFrameCache
    let action: () -> Void
    let chooseVersion: (RoleMappingChoice) -> Void
    @State private var showVersions = false
    private var clip: CursorClip? { choice.normalVariantID.flatMap { id in source.variants["normal"]?.first { $0.id == id }?.clip } ?? source.clip(.normal) }
    private var hasVersions: Bool { source.variants["normal"]?.contains { $0.clip != source.clip(.normal) } == true }
    var body: some View {
        MappingShowcase(title: source.localizedName, clip: clip, selected: selected, size: size, inViewport: inViewport, prepared: prepared, port: .left, portColor: portColor,
            animate: animate && !showVersions, appearance: appearance, frames: frames, action: action)
            .overlay(alignment: .topTrailing) {
                if hasVersions {
                    Button { showVersions = true } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                            .frame(width: 29, height: 27).background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).padding(8).help(L("展开素材版本")).accessibilityLabel(L("展开素材版本"))
                        .accessibilityIdentifier("mapping-variants-" + source.id)
                        .popover(isPresented: $showVersions, arrowEdge: .trailing) {
                            MappingMaterialPicker(source: source, choice: choice, appearance: appearance, frames: frames) {
                                showVersions = false; chooseVersion($0)
                            }
                        }
                }
            }
    }
}

private struct MappingMaterialPicker: View {
    let source: CursorRole
    let appearance: CursorAppearance
    let frames: MappingFrameCache
    let choose: (RoleMappingChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: RoleMappingChoice
    @State private var playing = true
    @State private var active = NSApp.isActive
    private struct Option: Identifiable { let id: RoleMappingChoice; let title: String; let clip: CursorClip }
    init(source: CursorRole, choice: RoleMappingChoice, appearance: CursorAppearance, frames: MappingFrameCache,
         choose: @escaping (RoleMappingChoice) -> Void) {
        self.source = source; self.appearance = appearance; self.frames = frames; self.choose = choose
        _chosen = State(initialValue: choice)
    }
    private var options: [Option] {
        var values: [Option] = []
        if let clip = source.clip(.normal) { values.append(Option(id: RoleMappingChoice(sourceID: source.id), title: L("当前常态素材"), clip: clip)) }
        values += (source.variants["normal"] ?? []).filter { $0.clip != source.clip(.normal) || $0.id == chosen.normalVariantID }.map {
            Option(id: RoleMappingChoice(sourceID: source.id, normalVariantID: $0.id), title: $0.localizedName, clip: $0.clip)
        }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(source.localizedName).font(.headline).lineLimit(2)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("关闭预览"))
            }
            if let option = options.first(where: { $0.id == chosen }) {
                MappingCursorPreview(clip: option.clip, appearance: appearance, running: playing && active, frames: frames, sizing: .material)
                    .padding(20).frame(height: 166).frame(maxWidth: .infinity)
                    .background(MappingCheckerboard()).clipShape(RoundedRectangle(cornerRadius: 10)).id(option.id)
                HStack {
                    if option.clip.frames.count > 1 {
                        Button { playing.toggle() } label: { Label(playing ? L("暂停") : L("播放"), systemImage: playing ? "pause.fill" : "play.fill") }
                    } else { Text(L("静态素材")).foregroundStyle(.secondary) }
                    Spacer()
                    Text(L("\(option.clip.frames.count) 帧")).foregroundStyle(.secondary)
                }.font(.caption).controlSize(.small)
            }
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        Button { chosen = option.id } label: {
                            HStack(spacing: 10) {
                                Text(option.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                if chosen == option.id { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(chosen == option.id ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: min(200, Double(options.count) * 42))
            HStack { Spacer(); Button(L("选用此版本")) { choose(chosen) }.buttonStyle(.borderedProminent) }
        }.padding(16).frame(width: 310)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
    }
}
private struct MappingCheckerboard: View {
    var body: some View {
        Color(nsColor: .controlBackgroundColor).overlay {
            Canvas { context, size in
                for x in stride(from: 0.0, to: size.width, by: 12) {
                    for y in stride(from: 0.0, to: size.height, by: 12) where (Int(x / 12) + Int(y / 12)) % 2 == 0 {
                        context.fill(Path(CGRect(x: x, y: y, width: 12, height: 12)), with: .color(.secondary.opacity(0.08)))
                    }
                }
            }
        }
    }
}

private struct MappingCursorPreview: View {
    let clip: CursorClip?
    let appearance: CursorAppearance
    let running: Bool
    let frames: MappingFrameCache
    var sizing = MappingPreviewSizing.fit
    var inViewport = true
    var prepared: MappingMaterialPresentation?
    @State private var canvas: CGRect?
    @State private var image: CGImage?
    @State private var started = Date()
    @State private var pausedFrame = 0
    private var adaptive: Bool { if case .material = sizing { return true }; return false }
    private var material: MappingMaterialPresentation? {
        guard adaptive, prepared?.clip == clip, prepared?.appearance == appearance else { return nil }
        return prepared
    }
    private struct CanvasRequest: Equatable { let clip: CursorClip?; let appearance: CursorAppearance; let visible: Bool; let adaptive: Bool }
    private struct Request: Equatable { let frame: Data?; let appearance: CursorAppearance; let width: Double; let height: Double }
    var body: some View {
        TimelineView(.animation(minimumInterval: max(1.0 / 30, clip?.frameDuration ?? 1), paused: !running || (clip?.frames.count ?? 0) < 2)) { context in
            let count = clip?.frames.count ?? 0
            let index = running && count > 1 ? max(0, Int(context.date.timeIntervalSince(started) / (clip?.frameDuration ?? 1))) % count : min(pausedFrame, max(0, count - 1))
            let data = count > 0 ? clip?.frames[index] : nil
            Group {
                if let image { raster(image) }
                else if clip == nil {
                    Text(L("系统图像暂不可用")).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                } else { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: Request(frame: data, appearance: appearance, width: clip?.width ?? 0, height: clip?.height ?? 0)) {
                    guard let clip, let data else { return }
                    let result = await frames.image(data, clip: clip, appearance: appearance)
                    if !Task.isCancelled { image = result }
                }
        }
        .onChange(of: running) { _, playing in
            guard let clip, clip.frames.count > 1 else { return }
            if playing { started = Date().addingTimeInterval(-Double(pausedFrame) * clip.frameDuration) }
            else { pausedFrame = max(0, Int(Date().timeIntervalSince(started) / clip.frameDuration)) % clip.frames.count }
        }
        .onChange(of: clip) { _, _ in canvas = nil }
        .onChange(of: appearance) { _, _ in canvas = nil }
        .task(id: CanvasRequest(clip: clip, appearance: appearance, visible: inViewport, adaptive: adaptive)) {
            guard adaptive, inViewport, let clip else { return }
            let bounds = await frames.canvas(clip, appearance: appearance)
            if !Task.isCancelled { canvas = bounds }
        }
        .onDisappear { image = nil }
    }
    private func raster(_ image: CGImage) -> some View {
        let prepared = material
        let shown = cropped(image, bounds: prepared?.bounds ?? canvas)
        return GeometryReader { geometry in
            let size = prepared?.size ?? MappingPreviewSizing.size(mode: sizing,
                image: CGSize(width: shown.width, height: shown.height), available: geometry.size)
            Image(decorative: shown, scale: 1).resizable().interpolation(appearance.effectiveSmoothEdges ? .high : .none)
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
    private func cropped(_ image: CGImage, bounds: CGRect?) -> CGImage {
        guard let bounds else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let crop = CGRect(x: bounds.minX * width, y: bounds.minY * height,
                          width: bounds.width * width, height: bounds.height * height).integral
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        return image.cropping(to: crop.intersection(extent)) ?? image
    }
}
