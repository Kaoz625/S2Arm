import Foundation
import S2ArmShellBridge
import SaveSync
import ShellUI

/// iCloud 存档同步的 iOS 一侧（方案见 launchers/shared/SaveSync）：
///   玩家在库设置「云存档」里选 iCloud 云盘的一个文件夹（Mac 上选同一个），书签存在 ShellSettingsStore；
///   选好游戏、起宿主之前，宿主（ios/app.m）问 s2a_shell_cloud_sync_vc 要同步页：导出本地存档 → 和云盘比 → 上传 / 下载恢复 / 冲突让玩家选。
///   存档作业全部走服务层 S2A_SaveTransfer（经 s2a_shell_save_request），这里不碰存档目录。同步失败不改本地存档，照常开始游戏。
///   限制（直说）：游戏和库同进程，游戏运行中不导出，手机上玩完要下次打开 App 选游戏时才上传。
enum CloudSaves {
    static let deviceKey = "S2ASaveSync.device"

    /// 玩家选的云盘文件夹（书签解析成功并已开始访问）；没开云存档回 nil
    static func folder(_ store: ShellSettingsStore = .current) -> URL? {
        guard let data = store.cloudSavesBookmark else { return nil }   // 没开云存档：正常情况，不打日志
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { NSLog("S2Arm 云存档：【红】读不出选的文件夹（书签 %d 字节）：%@", data.count, String(describing: error)); return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        NSLog("S2Arm 云存档：文件夹 %@（%@，访问授权 %@）", url.lastPathComponent, stale ? "书签已过期、已刷新" : "书签有效", scoped ? "拿到" : "没拿到")
        if stale, let fresh = try? url.bookmarkData() { store.defaults.set(fresh, forKey: ShellSettingsStore.cloudSavesKey) }
        return url
    }

    static func remember(_ url: URL, store: ShellSettingsStore = .current) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else { return false }
        store.defaults.set(data, forKey: ShellSettingsStore.cloudSavesKey)
        store.storeCloudSavesFolderName(url.lastPathComponent)
        return true
    }

    static func forget(store: ShellSettingsStore = .current) {
        store.defaults.removeObject(forKey: ShellSettingsStore.cloudSavesKey)
        store.clearCloudSavesFolderName()
    }

    /// 本设备固定的 uuid（第一次用时生成）
    static func deviceID(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString.lowercased(); defaults.set(id, forKey: deviceKey); return id
    }

    static func baseKey(folder: URL, gameID: String) -> String { "S2ASaveSync.base.\(folder.lastPathComponent).\(gameID)" }

    struct ServiceError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// 一次服务层存档作业：context 是 s2a_shell_save_context 给的公共字段，op 是本次的字段
    static func call(_ context: [String: Any], _ op: [String: Any]) throws -> [String: Any] {
        let request = context.merging(op) { _, new in new }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        guard let raw = json.withCString({ s2a_shell_save_request($0) }) else { throw ServiceError(message: L("This build has no save service, so iCloud Saves didn’t sync.", "这个安装包没有存档服务，iCloud 存档没同步。")) }
        defer { free(raw) }
        let response = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? [String: Any] ?? [:]
        guard response["ok"] as? Bool == true else {
            throw ServiceError(message: ((response["error"] as? [String: Any])?["message"] as? String) ?? L("The save service didn’t return a valid result.", "存档服务没有返回有效结果。"))
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    static func ports(_ context: [String: Any]) -> SaveSyncPorts {
        nonisolated(unsafe) let context = context
        return SaveSyncPorts(
            export: { url in
                guard try call(context, ["operation": "status"])["hasSave"] as? Bool == true else { return false }
                _ = try call(context, ["operation": "export", "path": url.path]); return true
            },
            inspect: { url in try files(call(context, ["operation": "inspect", "path": url.path])) },
            restore: { url in
                let preview = try call(context, ["operation": "inspect", "path": url.path])
                _ = try call(context, ["operation": "restore", "path": url.path,
                                       "archiveSha256": preview["archiveSha256"] ?? "", "targetFingerprint": preview["targetFingerprint"] ?? ""])
                // 收掉已提交的事务记录，不然下次起局会先进存档管理页。此时存档已经换了：失败要照实说（基线不前进，下次同步内容相同只记基线）
                do { _ = try call(context, ["operation": "recover"]) }
                catch { throw ServiceError(message: L("Your saves were switched to the iCloud progress, but finishing up didn’t complete (\(error.localizedDescription)). Next time you play, the saves screen will open first to finish it.", "存档已经换成云端的进度，但收尾没做完（\(error.localizedDescription)）。下次开始游戏前会先进存档管理页接着处理。")) }
            })
    }

    static func files(_ inspect: [String: Any]) throws -> [SaveFile] {
        guard let list = (inspect["manifest"] as? [String: Any])?["files"] as? [[String: Any]] else { throw ServiceError(message: L("Couldn’t read the full save list.", "存档清单读不全。")) }
        return try list.map {
            guard let path = $0["path"] as? String, let sha = $0["sha256"] as? String else { throw ServiceError(message: L("Couldn’t read the full save list.", "存档清单读不全。")) }
            return SaveFile(path: path, sha256: sha)
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 库设置「云存档 → 选择文件夹…」：系统文件夹选择器，选完记书签
@MainActor final class CloudFolderPicker: NSObject, UIDocumentPickerDelegate {
    static var current: CloudFolderPicker?
    static func present() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        let me = CloudFolderPicker(); current = me; picker.delegate = me
        topController()?.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { NSLog("S2Arm 云存档：选了文件夹 %@（%@）", url.lastPathComponent, CloudSaves.remember(url) ? "已记住" : "【红】书签没存上") }
        Self.current = nil
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { Self.current = nil }
}

@MainActor func topController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
}

/// 起局前的同步页（11-09 维护者：别是黑底一行竖字）：卡片里写清哪款游戏、在做什么；冲突在卡片里列出各份存档让玩家点选；
///   失败写原因、本机存档没动、照常开始。配色用游戏库同一套（ShellPalette），字重 / 圆角同库界面
@MainActor @Observable final class CloudSyncModel {
    enum Phase { case syncing, choosing([SaveSyncChoice]), finished(String), failed(String) }
    var phase: Phase = .syncing
    let game: String
    var pick: ((SaveSyncChoice?) -> Void)?
    var start: () -> Void = {}
    /// 同步中「跳过」：取消这次同步（已经开始的恢复会做完），本机存档照旧开始
    var skip: () -> Void = {}
    init(game: String) { self.game = game }

    /// 冲突：卡片里列出各份存档，等玩家点一份（nil = 先不选）
    func ask(_ choices: [SaveSyncChoice]) async -> SaveSyncChoice? {
        await withCheckedContinuation { (k: CheckedContinuation<SaveSyncChoice?, Never>) in
            pick = { [weak self] c in self?.pick = nil; self?.phase = .syncing; k.resume(returning: c) }
            phase = .choosing(choices)
        }
    }
}

struct CloudSyncView: View {
    let model: CloudSyncModel
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f }()
    private var localName: String { UIDevice.current.userInterfaceIdiom == .pad ? L("This iPad", "这台 iPad") : L("This iPhone", "这台 iPhone") }

    var body: some View {
        ZStack {
            ShellPalette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellPalette.background)
                        .frame(width: 30, height: 30).background(ShellPalette.cream, in: Circle())
                    Text(L("ICLOUD SAVES", "ICLOUD 存档")).font(.system(size: 11.5, weight: .bold)).tracking(1.3).foregroundStyle(ShellPalette.muted)
                }
                Text(model.game).font(.system(size: 24, weight: .heavy)).tracking(-0.5).foregroundStyle(.white).lineLimit(2)
                content
            }
            .padding(26)
            .frame(maxWidth: 480, alignment: .leading)
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .padding(.horizontal, 24)
        }
    }

    private var icon: String {
        switch model.phase {
        case .failed: "exclamationmark.icloud"
        case .finished: "checkmark.icloud"
        default: "icloud"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .syncing:
            HStack(spacing: 10) {
                ProgressView().tint(ShellPalette.cream)
                Text(L("Checking saves with iCloud…", "正在和 iCloud 核对存档…")).font(.system(size: 15, weight: .medium)).foregroundStyle(ShellPalette.muted)
            }
            Button(L("Skip Sync and Play", "跳过同步，直接开始")) { model.skip() }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellPalette.muted).frame(maxWidth: .infinity)
        case .finished(let text):
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(ShellPalette.ready)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Couldn’t sync this time", "这次没同步上")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(message).font(.system(size: 14)).foregroundStyle(ShellPalette.muted).fixedSize(horizontal: false, vertical: true)
                Text(L("Saves on this device weren’t changed, so you can play as usual.", "本机存档没有改动，可以照常玩。")).font(.system(size: 14)).foregroundStyle(ShellPalette.muted)
            }
            primary(L("Play", "开始游戏")) { model.start() }
        case .choosing(let choices):
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Both have new progress. Choose one to keep playing", "两边各有新进度，选一份继续玩")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(L("The one you don’t choose is kept as a backup, so nothing is lost.", "没选的那份会留作备份，不会丢。")).font(.system(size: 14)).foregroundStyle(ShellPalette.muted)
            }
            VStack(spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, c in
                    Button { model.pick?(c) } label: { row(c) }.buttonStyle(.plain)
                }
            }
            Button(L("Decide Later and Play", "先不选，直接开始")) { model.pick?(nil) }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellPalette.muted).frame(maxWidth: .infinity)
        }
    }

    private func row(_ c: SaveSyncChoice) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
        let detail = c.isLocal ? L("On this device · \(size)", "就在这台设备上 · \(size)") : L("Saved \(c.savedAt.map { Self.time.string(from: $0) } ?? "at an unknown time") · \(size)", "保存于 \(c.savedAt.map { Self.time.string(from: $0) } ?? "未知时间") · \(size)")
        return HStack(spacing: 14) {
            Image(systemName: Self.symbol(c.platform))
                .font(.system(size: 20)).foregroundStyle(ShellPalette.cream).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.isLocal ? localName : c.deviceName).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 13)).foregroundStyle(ShellPalette.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellPalette.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// 设备图标：head 里记的设备类型；旧 head 没记的画通用图标
    static func symbol(_ platform: String?) -> String {
        switch platform {
        case "mac": "laptopcomputer"
        case "iphone": "iphone"
        case "ipad": "ipad"
        default: "externaldrive.badge.icloud"
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(ShellPalette.background)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(ShellPalette.cream, in: Capsule())
        }.buttonStyle(.plain)
    }
}

@MainActor final class CloudSyncController: UIHostingController<CloudSyncView> {
    let engine: SaveSyncEngine
    let model: CloudSyncModel
    let onDone: () -> Void
    var work: Task<SaveSyncOutcome, Error>?
    var finished = false
    init(engine: SaveSyncEngine, game: String, done: @escaping () -> Void) {
        self.engine = engine; self.onDone = done
        model = CloudSyncModel(game: game)
        super.init(rootView: CloudSyncView(model: model))
        model.start = { [weak self] in self?.done() }
        model.skip = { [weak self] in NSLog("S2Arm 云存档：玩家跳过这次同步"); self?.work?.cancel() }
    }
    /// 只回调一次（跳过与同步结束可能前后脚到）
    func done() { if !finished { finished = true; onDone() } }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard work == nil else { return }
        let engine = engine, model = model
        let work = Task.detached { try await engine.sync { choices in await model.ask(choices) } }
        self.work = work
        Task {
            do {
                let outcome = try await work.value
                NSLog("S2Arm 云存档：%@", String(describing: outcome))
                // 结果停一下让玩家看清（取回 / 上传 / 已是最新），再进游戏
                model.phase = .finished(Self.describe(outcome))
                try? await Task.sleep(nanoseconds: 900_000_000)
                done()
            } catch is CancellationError {
                done()   // 玩家点了跳过：本机存档没动，直接开始
            } catch {
                NSLog("S2Arm 云存档：【红】同步失败：%@", error.localizedDescription)
                model.phase = .failed(error.localizedDescription)
            }
        }
    }

    static func describe(_ outcome: SaveSyncOutcome) -> String {
        switch outcome {
        case .upToDate: L("Saves are up to date", "存档已是最新")
        case .uploaded: L("Saved this device’s progress to iCloud", "已把这台设备的进度存到 iCloud")
        case .downloaded(let from), .tookRemote(let from): L("Switched to progress from \(from)", "已换成 \(from) 的进度")
        case .keptLocal: L("Kept this device’s progress and saved it to iCloud", "已用这台设备的进度，并存到 iCloud")
        case .conflictSkipped: L("Not syncing this time; starting with this device’s saves", "这次先不同步，用这台设备的存档开始")
        }
    }
}

/// app.m 用的 C 入口（声明在 S2ArmShellBridge/include/s2a_shell.h）
@MainActor @_cdecl("s2a_shell_cloud_sync_vc")
public func s2a_shell_cloud_sync_vc(_ gameID: UnsafePointer<CChar>?, _ done: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                    _ ctx: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard ShellSettingsStore.current.cloudSavesBookmark != nil else { return nil }   // 没开云存档
    guard let folder = CloudSaves.folder() else { return nil }
    guard let raw = s2a_shell_save_context() else { NSLog("S2Arm 云存档：本款没有存档身份或存档服务，不同步"); return nil }
    defer { free(raw) }
    // 云盘按存档身份里的游戏号分目录（单款包的启动上下文没有游戏号；容器里两者相同）
    guard let context = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? [String: Any],
          let gameID = ((context["game"] as? [String: Any])?["id"] as? String).map({ $0.uppercased() }) ?? gameID.map({ String(cString: $0) }),
          gameID.count == 16, gameID.allSatisfy(\.isHexDigit) else { NSLog("S2Arm 云存档：【红】存档身份里没有有效游戏号，不同步"); return nil }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-cloud-sync", isDirectory: true)
    let key = CloudSaves.baseKey(folder: folder, gameID: gameID)
    let engine = SaveSyncEngine(folder: CloudSaveFolder(root: folder, gameID: gameID), device: CloudSaves.deviceID(), deviceName: UIDevice.current.name, platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
                                work: work, ports: CloudSaves.ports(context),
                                loadBase: { UserDefaults.standard.string(forKey: key) }, storeBase: { UserDefaults.standard.set($0, forKey: key) })
    nonisolated(unsafe) let ctx = ctx
    let vc = CloudSyncController(engine: engine, game: (context["game"] as? [String: Any])?["name"] as? String ?? gameID) { done?(ctx) }
    return Unmanaged.passRetained(vc as UIViewController).toOpaque()
}
#endif
