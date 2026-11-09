// Derived from NX2Apple frontend/Sources/NX2Apple/LauncherView.swift (908e4e84, MIT; see ../../UPSTREAM.md).
// S2Arm changes: one page, the Library (the Builds and Settings pages, engine sync banner, artwork editor, Manage menu, console mode
// and gamepad driver are not taken); the state is S2ArmLauncherModel (adapter services) instead of LauncherStores; while a game runs
// the library gives way to JobSessionView (the launch job's events and Stop), and Back returns to the library. Second cut: the top bar
// adds Add games (open panel, or drop files on the window → import job) and the environment check (EnvironmentView); the options
// sheet is joined by the install-to-iPhone sheet (InstallView); any job (prepare, install, import) runs in JobSessionView. Export
// (11-07): a game's Export opens ExportView in place of the library (platforms, options, start), and an export runs in
// ExportSessionView (platform queue, steps, time left, per-platform results); the free-up-space sheet (FreeSpaceView) and
// change library (JobSessionView, setup job) sit beside them.
// Toolbar actions keep their ideal width and draw their own button backgrounds, without AppKit's shared glass background.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct LauncherView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @StateObject var padFocus = PadFocus()
    @StateObject var row = RowScroller()
    @StateObject var covers = CoverCache()
    @State var installFor: String?
    @State var spaceFor: String?
    @State var moreFor: String?
    @State var saveFor: String?
    @State var inputFor: String?
    @State var deleteFor: GameSummary?
    @State private var dropTargeted = false
    @State var collectionHeight: CGFloat = 300
    let brand: String

    /// Room for the controller's focus ring, which sits 4 pt outside a card.
    static let ringRoom: CGFloat = 6

    /// What the host's own messages use: the launch job takes zh-Hans or en.
    var uiLanguage: String { loc.lang == .zh ? "zh-Hans" : "en" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            if let result = model.viewingResult, let run = result.export {
                ExportSessionView(model: model, covers: covers, session: result, run: run, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let session = model.session, let run = session.export, !model.sessionHidden {
                ExportSessionView(model: model, covers: covers, session: session, run: run, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let session = model.session, session.export == nil, !model.isInline(session) {
                JobSessionView(model: model, session: session)
            } else if let id = model.exportFor, let game = model.games.first(where: { $0.id == id }) {
                ExportView(model: model, covers: covers, game: game) { installFor = game.id }
            } else {
                libraryPage
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 18).strokeBorder(LauncherPalette.cream, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                .padding(16).allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                        Self.fileURLs(providers) { urls in
                            // 拖进来的是 prod.keys 就当密钥放，别当游戏报错
                            if urls.count == 1, urls[0].pathExtension.lowercased() == "keys" { model.importKeys(urls[0]) } else { model.importGames(urls) }
                        }
                        return true
                    }
            }
        }
        .padScope("main", padFocus)
        .environmentObject(padFocus)
        .launcherDropdownHost()
        .background(LauncherPalette.background)
        .background(LauncherWindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .font(.manrope(13))
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .onAppear { model.refresh(); model.checkEnvironment(); model.startControl(); model.finishPendingUpdate(); model.checkForUpdate() }
        .sheet(item: Binding(get: { installFor.map(OptionsTarget.init) }, set: { installFor = $0?.id })) { target in
            InstallView(model: model, gameID: target.id).environmentObject(loc)
        }
        .sheet(item: Binding(get: { spaceFor.map(OptionsTarget.init) }, set: { spaceFor = $0?.id })) { target in
            FreeSpaceView(model: model, gameID: target.id).environmentObject(loc)
        }
        .sheet(item: Binding(get: { saveFor.map(OptionsTarget.init) }, set: { saveFor = $0?.id })) { target in
            SaveManageSheet(model: model, gameID: target.id).environmentObject(loc)
        }
        .sheet(item: Binding(get: { inputFor.map(OptionsTarget.init) }, set: { inputFor = $0?.id })) { target in
            InputSettingsSheet(model: model, gameID: target.id).environmentObject(loc)
        }
        .alert(txt("game.delete.title").replacingOccurrences(of: "{0}", with: deleteFor?.name ?? ""), isPresented: Binding(get: { deleteFor != nil }, set: { if !$0 { deleteFor = nil } })) {
            Button(txt("game.cancel"), role: .cancel) { deleteFor = nil }
            Button(txt("game.delete.confirm"), role: .destructive) { if let g = deleteFor { model.deleteGame(g) }; deleteFor = nil }
        } message: { Text(txt("game.delete.body")) }
        .sheet(isPresented: $model.showAddGames) { ImportSheet(model: model, kind: .games).environmentObject(loc) }
        .sheet(isPresented: $model.showKeys) { ImportSheet(model: model, kind: .keys).environmentObject(loc) }
        .sheet(isPresented: $model.showEnvironment) {
            EnvironmentView(model: model).environmentObject(loc)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(brand).font(.manrope(22, .bold)).tracking(-0.6).lineLimit(1).fixedSize()
            Spacer()
        }
        .padding(.leading, 90).padding(.trailing, 24)   // the window's traffic lights sit in the transparent title bar
        .frame(height: 52)   // = a unified toolbar's title bar: the system centres the traffic lights in it, so they share this bar's midline
        .background(TitlebarDoubleClick())
        .background(UnifiedTitlebar(actions: topActions))
    }

    /// 顶栏右侧的按钮放进系统工具栏本身：工具栏盖在窗口内容上，内容里的按钮收不到真实点击（11-08 维护者）。
    private var topActions: some View {
        HStack(spacing: 12) {
                if model.loading { ProgressView().controlSize(.small) }
                exportPill
                updateButton
                // 界面语言：一键切到另一种（同旧启动器 LanguageSwitch，维护者 10-23「不让玩家先选」）；当场生效、记住选择，不用重启（11-07 维护者 验收）
                Button { loc.choose(loc.lang == .zh ? Lang.en.code : Lang.zh.code) } label: {
                    Label(loc.lang == .zh ? "English" : "简体中文", systemImage: "globe").font(.manrope(12.5, .semibold))
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .accessibilityIdentifier("top.language")
                Button { installFor = nil; model.goToLibrary() } label: {
                    Label(loc.t("s2arm.nav.library"), systemImage: "square.grid.2x2").font(.manrope(12.5, .semibold))
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .accessibilityIdentifier("top.library")
                Button { model.showAddGames = true } label: {
                    Label(loc.t("s2arm.action.import"), systemImage: "plus").font(.manrope(12.5, .semibold))
                }
                .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
                Button { model.showEnvironment = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(environmentColor).frame(width: 7, height: 7)
                        Text(loc.t("s2arm.env.title")).font(.manrope(12.5, .semibold))
                    }
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
        }
        .fixedSize(horizontal: true, vertical: false)   // 工具栏按完整文案测量，避免「添加游戏」在宽窗口里仍被压成「添加…」
        .padding(.trailing, 8)
        .labelStyle(.titleAndIcon)   // 工具栏里 Label 缺省只显示图标
        .tint(LauncherPalette.cream)
        .environment(\.colorScheme, .dark)
    }

    /// A unified toolbar makes the (transparent) title bar as tall as the top bar, and macOS then centres the close / minimise / zoom
    /// buttons vertically in it. The right-hand actions are its one item, so real clicks reach them.
    private struct UnifiedTitlebar<Actions: View>: NSViewRepresentable {
        let actions: Actions

        final class Coordinator: NSObject, NSToolbarDelegate {
            static var item: NSToolbarItem.Identifier { NSToolbarItem.Identifier("s2arm.actions") }
            let host: NSHostingView<Actions>
            init(_ actions: Actions) { host = NSHostingView(rootView: actions) }
            func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.item] }
            func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.item] }
            func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
                guard id == Self.item else { return nil }
                let item = NSToolbarItem(itemIdentifier: id)
                item.view = host
                item.isBordered = false   // 按钮已有自绘底色；不要再给整组套系统玻璃背景
                return item
            }
        }

        final class Host: NSView {
            var coordinator: Coordinator?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, window.toolbar == nil else { return }
                let toolbar = NSToolbar(identifier: "s2arm.titlebar")
                toolbar.delegate = coordinator
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
                window.toolbarStyle = .unified
                window.titlebarSeparatorStyle = .none
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(actions) }
        func makeNSView(context: Context) -> NSView { let h = Host(); h.coordinator = context.coordinator; return h }
        func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.host.rootView = actions }
    }

    private struct OptionsTarget: Identifiable { let id: String }

    private var environmentColor: Color {
        switch model.environmentState {
        case .unknown: return LauncherPalette.unbuilt
        case .ready, .readyMac: return LauncherPalette.ready   // readyMac：Mac 上能玩，只差打 iPhone 包的项（环境检查页里单列）
        case .missing: return LauncherPalette.danger
        }
    }

    /// 有新版：后台下载时一行小字，下好后一颗「更新并重启」，都在顶栏，不打断玩家。
    @ViewBuilder private var updateButton: some View {
        switch model.updateState {
        case .working(let id, let percent):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(txt(id).replacingOccurrences(of: "{0}", with: "\(percent ?? 0)")).font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .ready:
            Button { model.restartToUpdate() } label: {
                Label(txt(model.busy ? "update.restart.busy" : "update.restart"), systemImage: "arrow.down.circle").font(.manrope(12.5, .semibold))
            }
            .buttonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
        case .failed(let code):
            Button { model.downloadUpdate() } label: { Text(txt("update.retry")).font(.manrope(12.5, .semibold)) }
                .buttonStyle(LauncherSecondaryButtonStyle()).help(txt("update.error." + code))
        case .idle: EmptyView()
        }
    }

    func txt(_ id: String) -> String { BackendText.launcherText(id, language: uiLanguage) }

    /// 收起运行页、或还有排队时：顶部这颗胶囊回到出包页。
    @ViewBuilder private var exportPill: some View {
        if let session = model.session, session.export != nil, model.sessionHidden {
            Button { model.sessionHidden = false } label: {
                HStack(spacing: 7) {
                    if model.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(LauncherPalette.ready) }
                    Text(txt(model.busy ? "export.pill.running" : "export.pill.done").replacingOccurrences(of: "{0}", with: session.name)).font(.manrope(12.5, .semibold)).lineLimit(1)
                    if !model.exportQueue.isEmpty {
                        Text(txt("export.pill.queue").replacingOccurrences(of: "{0}", with: "\(model.exportQueue.count)")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
        }
    }

    /// The file URLs of a drop, delivered together on the main queue.
    static func fileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}
