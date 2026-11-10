import Foundation
import Testing
import S2ArmShellBridge
import ShellUI
@testable import S2ArmShellHost

// 期望值按 Fixtures/catalogue.json 手算：8 条里重复的 Alpha 丢弃 → 7 条；状态按字段逐条对位
@Test func catalogueFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "catalogue", withExtension: "json", subdirectory: "Fixtures"))
    let c = Catalogue.load(path: url.path)
    #expect(c.tiles.map(\.id) == ["0100000000010000", "0100000000020000", "0100000000030000", "0100000000040000",
                                  "0100000000050000", "bad", "0100000000060000"])
    #expect(c.tiles[0].title == "Alpha" && c.tiles[0].subtitle == "1.2.0" && c.tiles[0].banner == nil)
    #expect(c.tiles[0].state == .playable)
    #expect(c.tiles[1].state == .needsGameData)
    #expect(c.tiles[2].state == .needsAppUpdate)
    #expect(c.tiles[3].state == .broken(reason: "R", detail: "D"))
    #expect(c.tiles[4].state == .broken(reason: "", detail: "", technical: L("Unknown state \"flying\"", "未知状态 \"flying\"")))
    if case .broken = c.tiles[5].state {} else { Issue.record("非法 title_id 应显示为不可用") }
    #expect(c.tiles[6].state == .playable)   // 缺 state 按可运行
    #expect(c.problems.count == 2)           // 重复 1 + 非法 id 1
}

@Test func catalogueBadInputs() {
    let base = URL(fileURLWithPath: "/")
    #expect(Catalogue.parse(Data("not json".utf8), baseDirectory: base).tiles.isEmpty)
    #expect(Catalogue.parse(Data(#"{"schema":2,"games":[]}"#.utf8), baseDirectory: base).problems.count == 1)
    #expect(Catalogue.load(path: "/nonexistent/s2a.json").problems.count == 1)
}

/// 宿主没接的功能必须是 nil：界面据此不显示按钮。接上一项，就把它从这张表挪走，入口自动出现。
@MainActor @Test func unwiredActionsStayNilSoTheirButtonsAreHidden() throws {
    let data = Data(#"{"games":[]}"#.utf8)
    let a = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/"))).actions
    #expect(a.onUseAppData == nil && a.onPickCloudSaves == nil && a.onDisableCloudSaves == nil && a.onUseShellCloud == nil)
    #expect(a.onResetDefaults == nil && a.onShowLog == nil && a.onAppUpdate == nil)
    #expect(a.onPickShellData == nil && a.onClearShellData == nil && a.onPickShellCloud == nil && a.onClearShellCloud == nil)
    #expect(a.onGlobalPadMapChange == nil && a.onGlobalPadMapReset == nil)
}

// 删除游戏（#227 iPad 点了没反应：宿主从没给 onDeleteGame 实现）：不勾存档 → 数据根下只留 S2A/（存档），勾了 → 整个删；删完库里不再显示。期望按目录手写
@MainActor @Test func deleteGameRemovesDataAndKeepsSavesUnlessAsked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-del-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b) = ("0100000000010000", "0100000000020000")
    for id in [a, b] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(id)/资源包"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(id)/S2A/ryujinx/bis/user/save"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("\(id)/identity.json"))
    }
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"}]}"#.utf8)
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")),
                                    gameDataReady: { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/资源包").path) }, gamesRoot: root)
    #expect(model.games.map(\.id) == [a, b])
    let delete = try #require(model.actions.onDeleteGame)
    delete(a, false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(a).path) == ["S2A"])
    delete(b, true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(b).path))
    #expect(model.games.isEmpty)
}

@MainActor @Test func playOnlyForPlayable() {
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B","state":"needs_game_data"}]}"#.utf8)
    var played: [String] = []
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) })
    model.actions.onPlay("0100000000010000")
    model.actions.onPlay("0100000000020000")
    model.actions.onPlay("FFFFFFFFFFFFFFFF")
    #expect(played == ["0100000000010000"])
}

// 资源包不在机上（11-07 Duo「游戏没能启动」）：清单写 playable 也显示需要游戏数据、Play 不放行而是要导入说明；放好后重判 → 可运行、放行。
//   清单本来写 needs_game_data 的款不因资源包在就变可运行（以清单为底）
@MainActor @Test func gameDataMissingBlocksPlay() {
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B","state":"needs_game_data"}]}"#.utf8)
    var ready: Set<String> = ["0100000000020000"]
    var played: [String] = [], picked: [String] = []
    let model = S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { played.append($0) },
                                    gameDataReady: { ready.contains($0) }, pickGameData: { picked.append($0) })
    #expect(model.games.map(\.id) == ["0100000000020000"])   // 只显示这台设备上资源到位的款
    model.actions.onPlay("0100000000010000")
    #expect(played.isEmpty && picked == ["0100000000010000"])
    model.actions.onPickGameData("0100000000010000")
    #expect(picked == ["0100000000010000", "0100000000010000"])
    ready.insert("0100000000010000"); model.refreshGameData()
    #expect(model.games.map(\.id) == ["0100000000010000", "0100000000020000"] && model.games.map(\.game.state) == [.playable, .needsGameData])   // 再推一款，刷新后多一款
    model.actions.onPlay("0100000000010000")
    #expect(played == ["0100000000010000"])
    ready.remove("0100000000010000")              // 库开着时资源包被拿走：Play 当场重判、不放行
    model.actions.onPlay("0100000000010000")
    #expect(played == ["0100000000010000"] && picked.count == 3)
    #expect(model.games.map(\.id) == ["0100000000020000"])   // 删掉后不再显示
}

// 宿主「重新检查」→ s2a_shell_refresh → 登记的处理函数
nonisolated(unsafe) private var refreshed = 0
@Test func cBridgeRefresh() {
    s2a_shell_set_refresh_handler(nil, nil); s2a_shell_refresh(); #expect(refreshed == 0)
    s2a_shell_set_refresh_handler({ _ in refreshed += 1 }, nil); s2a_shell_refresh(); #expect(refreshed == 1)
    s2a_shell_set_refresh_handler(nil, nil)
    #expect(s2a_shell_game_data_ready("0100000000010000") == 1)   // 不链宿主时弱定义缺省：按就绪
}

// C 出口：没登记 → 0；登记后 → 1 且处理函数拿到同一个 id
nonisolated(unsafe) private var lastPlayed = ""
@Test func cBridgeForwards() {
    s2a_shell_set_play_handler(nil, nil)
    #expect(s2a_shell_play("0100000000010000") == 0)
    s2a_shell_set_play_handler({ id, _ in lastPlayed = String(cString: id!) }, nil)
    #expect(s2a_shell_play("0100000000020000") == 1)
    #expect(lastPlayed == "0100000000020000")
    s2a_shell_set_play_handler(nil, nil)
}

// 每款游戏的设置行（S2ArmGameSettings，11-07 维护者）：临时偏好，期望值手算
@MainActor @Test func gameSettingsRows() throws {
    let tag = UUID().uuidString
    let app = try #require(UserDefaults(suiteName: "s2a.test.app." + tag))
    var games: [String: UserDefaults] = [:]
    let stores = S2ArmGameSettings.Stores(game: { id in
        if let d = games[id] { return d }
        let d = UserDefaults(suiteName: "s2a.test.game.\(tag).\(id)"); games[id] = d; return d }, app: app)
    defer { app.removePersistentDomain(forName: "s2a.test.app." + tag); for (id, _) in games { UserDefaults().removePersistentDomain(forName: "s2a.test.game.\(tag).\(id)") } }
    func row(_ s: [SettingSection], _ id: String) -> SettingRow? { s.flatMap(\.rows).first { $0.id == id } }
    // 缺省：60 帧开、宽屏强制关、透明度 100、布局默认，没有「我的布局」时选项 = 默认 + 调整位置
    var s = S2ArmGameSettings.sections(for: "G1", stores: stores, state: .init(selected: "default", hasMine: false))
    #expect(row(s, "fps60")?.value == "on" && row(s, "widenForce")?.value == "off" && row(s, "vpadOpacity")?.value == "100")
    #expect(row(s, "vpadHoldLock")?.value == "on")
    #expect(row(S2ArmGameSettings.sections(for: "G1", stores: stores, state: .init(selected: "default", hasMine: false, holdLock: false)), "vpadHoldLock")?.value == "off")
    if case .choice(let o) = row(s, "vpadLayout")?.kind { #expect(o.map(\.id) == ["default", "edit"]) } else { Issue.record("布局行应是多选") }
    // 改：G1 关 60 帧、开宽屏强制、透明度 40 → G1 两项变了、G2 不变；透明度全局 0.4
    #expect(!S2ArmGameSettings.apply(id: "G1", setting: "fps60", value: "off", stores: stores))
    S2ArmGameSettings.apply(id: "G1", setting: "widenForce", value: "on", stores: stores)
    S2ArmGameSettings.apply(id: "G1", setting: "vpadOpacity", value: "40.0", stores: stores)
    s = S2ArmGameSettings.sections(for: "G1", stores: stores, state: .init(selected: "mine", hasMine: true))
    #expect(row(s, "fps60")?.value == "off" && row(s, "widenForce")?.value == "on" && row(s, "vpadOpacity")?.value == "40")
    #expect(games["G1"]?.object(forKey: "S2AFps60") as? Bool == false && games["G1"]?.bool(forKey: "S2AWidenForce") == true)
    #expect(abs((app.object(forKey: "S2AVPadOpacity") as? Double ?? 0) - 0.4) < 1e-9)
    if case .choice(let o) = row(s, "vpadLayout")?.kind { #expect(o.map(\.id) == ["default", "mine", "edit"]) }
    #expect(row(s, "vpadLayout")?.value == "mine")
    let s2 = S2ArmGameSettings.sections(for: "G2", stores: stores, state: .init(selected: "default", hasMine: false))
    #expect(row(s2, "fps60")?.value == "on" && row(s2, "widenForce")?.value == "off" && row(s2, "vpadOpacity")?.value == "40")
    // 透明度钳在 10–100：给 5 存成 0.1
    S2ArmGameSettings.apply(id: "G1", setting: "vpadOpacity", value: "5", stores: stores)
    #expect(abs((app.object(forKey: "S2AVPadOpacity") as? Double ?? 0) - 0.1) < 1e-9)
    // 选「调整位置…」= 打开编辑页，不存值
    #expect(S2ArmGameSettings.apply(id: "G1", setting: "vpadLayout", value: "edit", stores: stores))
}

// 这台 iPhone 上的名字和封面：叠在清单上、可恢复默认，不影响别的款。期望值手写
@MainActor @Test func gameIdentityOverridesCatalogue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"schema":1,"games":[{"title_id":"0100000000000001","name":"原名一"},{"title_id":"0100000000000002","name":"原名二"}]}"#
    let catalogue = Catalogue.parse(Data(json.utf8), baseDirectory: root)
    let store = GameIdentityStore(root: root)
    let model = S2ArmShellHostModel(catalogue: catalogue, gameDataReady: { _ in true }, pickGameData: { _ in }, identityStore: store)
    let a = "0100000000000001", b = "0100000000000002"
    #expect(model.games.map(\.game.title) == ["原名一", "原名二"] && !model.hasCustomIdentity(a))
    model.change(a, S2ArmGameSettings.identity, S2ArmGameSettings.editIdentity)
    #expect(model.editingIdentity == a)
    model.saveIdentity(a, name: "  我的游戏  ", cover: nil)
    #expect(model.editingIdentity == nil && model.games[0].game.title == "我的游戏" && model.games[1].game.title == "原名二")
    #expect(store.load(a)?.name == "我的游戏" && store.load(b) == nil)
    // 下次启动：从磁盘读回
    let again = S2ArmShellHostModel(catalogue: catalogue, gameDataReady: { _ in true }, pickGameData: { _ in }, identityStore: store)
    #expect(again.games[0].game.title == "我的游戏")
    // 名字没改：不算自定义
    model.saveIdentity(b, name: "原名二", cover: nil)
    #expect(store.load(b) == nil && !model.hasCustomIdentity(b))
    model.resetIdentity(a)
    #expect(model.games[0].game.title == "原名一" && store.load(a) == nil)
}

// 名字和封面一次提交（审计 P2-221）：提交点失败时两样都不变、编辑页不关并给原因；存成后旧封面才删。期望值手写
@MainActor @Test func gameIdentitySaveIsAllOrNothing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = #"{"schema":1,"games":[{"title_id":"0100000000000001","name":"原名一"}]}"#
    let catalogue = Catalogue.parse(Data(json.utf8), baseDirectory: root)
    let store = GameIdentityStore(root: root)
    let a = "0100000000000001"
    let folder = root.appendingPathComponent("games/\(a)", isDirectory: true)
    func covers() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("identity-cover") }.sorted() }

    // 早先版本留下的固定名封面照样认；换新封面后它被删、只剩一份
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("identity-cover.jpg"))
    #expect(store.load(a)?.cover?.lastPathComponent == "identity-cover.jpg")
    try store.save(a, name: "名一", cover: Data([4, 5]))
    #expect(covers().count == 1 && covers() != ["identity-cover.jpg"])
    #expect(store.load(a)?.name == "名一" && store.load(a)?.cover.flatMap { try? Data(contentsOf: $0) } == Data([4, 5]))
    // 只改名字：封面沿用
    try store.save(a, name: "名二", cover: nil)
    #expect(store.load(a)?.name == "名二" && store.load(a)?.cover.flatMap { try? Data(contentsOf: $0) } == Data([4, 5]) && covers().count == 1)

    // 提交点失败：identity.json 的位置被一个非空目录占着，原子替换必然失败
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("identity.json/x", isDirectory: true), withIntermediateDirectories: true)
    let model = S2ArmShellHostModel(catalogue: catalogue, gameDataReady: { _ in true }, pickGameData: { _ in }, identityStore: store)
    model.change(a, S2ArmGameSettings.identity, S2ArmGameSettings.editIdentity)
    model.saveIdentity(a, name: "新名", cover: Data([9]))
    #expect(model.editingIdentity == a, "没存成：编辑页不关")
    #expect(model.identityError?.isEmpty == false, "给编辑页显示原因")
    #expect(covers().isEmpty, "新封面没留下半套")
    #expect(store.load(a) == nil && model.games[0].game.title == "原名一", "名字也没变")
    // 负对照：挡路的东西挪走后同样的保存成功、关页、清掉原因
    try FileManager.default.removeItem(at: folder.appendingPathComponent("identity.json"))
    model.saveIdentity(a, name: "新名", cover: Data([9]))
    #expect(model.editingIdentity == nil && model.identityError == nil && model.games[0].game.title == "新名" && covers().count == 1)
    model.resetIdentity(a)
    #expect(covers().isEmpty && store.load(a) == nil)
}
