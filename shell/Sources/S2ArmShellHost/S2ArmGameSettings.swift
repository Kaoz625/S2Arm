import Foundation
import S2ArmShellBridge
import ShellUI

/// 每款游戏的设置行（11-07 维护者：游戏库按住游戏 / 点设置弹出；60 帧、宽屏强制启用点一下切换就生效，虚拟手柄布局进二级页，
/// 全部按键透明度一个全局拉杆）。只放数据：上游 GameDetailView 原样画（开关 / 多选 / 拉杆），改动经 ShellActions.onChange 回到这里。
///
/// 存哪：
/// - 60 帧 / 宽屏强制启用：按游戏，独立偏好 `S2AGame.<游戏号>`（键 S2AFps60、S2AWidenForce）；起局时宿主 ios/settings.m 先读这一款的
/// - 按键透明度：App 级 `S2AVPadOpacity`（0.1–1，缺省 1），全部游戏共用；宿主 ios/vpad.m 进游戏时读
/// - 虚拟手柄布局：按游戏，走 C 接口 s2a_shell_vpad_*（宿主 ios/vpad_shell.m），与游戏内拖动编辑同一份文件
public enum S2ArmGameSettings {
    public static let fps60 = "fps60", widenForce = "widenForce", opacity = "vpadOpacity", layout = "vpadLayout", holdLock = "vpadHoldLock", identity = "gameIdentity", editIdentity = "edit"
    /// 布局多选里打开二级编辑页的那一项（不是一个方案）
    public static let editLayout = "edit"

    /// 存偏好的地方；单测换成临时 suite
    public struct Stores {
        public var game: (String) -> UserDefaults?
        public var app: UserDefaults
        public init(game: @escaping (String) -> UserDefaults?, app: UserDefaults) { self.game = game; self.app = app }
        public static var live: Stores { Stores(game: { UserDefaults(suiteName: "S2AGame." + $0) }, app: .standard) }
    }

    /// 本款布局的当前状态（宿主接口给的 JSON）；读不到（Mac 单测、宿主没链）按「默认、没有我的布局」
    public struct LayoutState: Equatable { public var selected: String; public var hasMine: Bool; public var holdLock = true; public var customIdentity = false }
    public static func layoutState(_ id: String) -> LayoutState {
        guard let p = id.withCString({ s2a_shell_vpad_layout_json($0, 832, 419) }) else { return LayoutState(selected: "default", hasMine: false) }
        defer { free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        return LayoutState(selected: obj?["selected"] as? String ?? "default", hasMine: obj?["hasMine"] as? Bool ?? false, holdLock: obj?["holdLock"] as? Bool ?? true)
    }

    public static func sections(for id: String, stores: Stores = .live, state: LayoutState) -> [SettingSection] {
        let g = stores.game(id)
        let on60 = (g?.object(forKey: "S2AFps60") as? Bool) ?? true
        let force = g?.bool(forKey: "S2AWidenForce") ?? false
        let op = (stores.app.object(forKey: "S2AVPadOpacity") as? Double).map { min(1, max(0.1, $0)) } ?? 1
        var options = [SettingOption("default", L("Default layout", "默认布局"))]
        if state.hasMine { options.append(SettingOption("mine", L("My layout", "我的布局"))) }
        options.append(SettingOption(editLayout, L("Arrange…", "调整位置…")))
        let current = state.selected == "mine" && state.hasMine ? "mine" : "default"
        return [
            SettingSection(id: "s2a.identity", title: L("Display", "显示"), rows: [
                SettingRow(id: identity, label: L("Name & Cover", "名字和封面"), note: L("Only changes how it shows on this iPhone", "只改这台 iPhone 上的显示"), kind: .choice([SettingOption("current", state.customIdentity ? L("Custom", "已自定义") : L("Default", "默认")), SettingOption(editIdentity, L("Edit…", "修改…"))]), value: "current"),
            ]),
            SettingSection(id: "s2a.picture", title: L("Picture", "画面"), rows: [
                SettingRow(id: fps60, label: L("60 FPS", "60 帧"), note: L("Turn off to use the game’s own frame rate (usually 30 FPS) and save battery", "关掉回到游戏自己的帧率（多为 30 帧），更省电"), kind: .toggle(on: "on", off: "off"), value: on60 ? "on" : "off"),
                SettingRow(id: widenForce, label: L("Force Widescreen", "宽屏强制启用"), note: L("Fills the screen even in games that haven’t been tested; goes back to 16:9 automatically if the picture looks stretched", "没验证过的游戏也铺满全屏；画面若被拉伸会自动退回 16:9"), kind: .toggle(on: "on", off: "off"), value: force ? "on" : "off"),
            ]),
            SettingSection(id: "s2a.vpad", title: L("Virtual Controller", "虚拟手柄"), rows: [
                SettingRow(id: layout, label: L("Button Layout", "按键布局"), note: L("Arranging applies to this game only", "调整位置只对这款游戏生效"), kind: .choice(options), value: current),
                SettingRow(id: holdLock, label: L("Hold to Lock ZL / ZR", "按住锁定 ZL / ZR"), note: L("Hold for 2 seconds to lock, tap again to unlock; this game only", "按住 2 秒锁定，再点一下解锁；只对这款游戏生效"), kind: .toggle(on: "on", off: "off"), value: state.holdLock ? "on" : "off"),
                SettingRow(id: opacity, label: L("Button opacity", "按键透明度"), note: L("Applies to all games; takes effect next time you start a game", "全部游戏共用，下次进游戏生效"), kind: .range(min: 10, max: 100, step: 5, unit: "%"), value: String(Int((op * 100).rounded()))),
            ]),
        ]
    }

    /// 改动：返回 true = 要打开布局编辑页（不是存值）
    @discardableResult
    public static func apply(id: String, setting: String, value: String, stores: Stores = .live) -> Bool {
        switch setting {
        case fps60: stores.game(id)?.set(value == "on", forKey: "S2AFps60")
        case widenForce: stores.game(id)?.set(value == "on", forKey: "S2AWidenForce")
        case opacity: if let v = Double(value) { stores.app.set(min(1, max(0.1, v / 100)), forKey: "S2AVPadOpacity") }
        case holdLock: _ = id.withCString { s2a_shell_vpad_set_hold_lock($0, value == "on" ? 1 : 0) }
        case layout:
            if value == editLayout { return true }
            if value == "default" || value == "mine" { _ = id.withCString { i in value.withCString { s2a_shell_vpad_select(i, $0) } } }
        default: break
        }
        return false
    }
}
