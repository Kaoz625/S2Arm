#if canImport(UIKit)
import SwiftUI
import UIKit
import ShellUI
import S2ArmShellBridge

/// 虚拟手柄布局编辑页（11-07 维护者：游戏库 → 这款的设置 → 按键布局 →「调整位置…」）：这款的封面当范例底图，按键按游戏里同一套描线样式画，
/// 拖哪个挪哪个；「完成」存本款「我的布局」并选中，「恢复默认」切回默认布局（我的布局文件保留）。
/// 下方按键透明度拉杆（11-07 维护者：去掉「取消」，两键居中，拉杆配一行说明）：写 App 级 S2AVPadOpacity（全部游戏共用，同设置页那一行），拖动时本页按键跟着变。
/// 几何与游戏内 vpad.m 同口径：可放区域 = 安全区（左右至少 16、底至少 8 点），按键 x / y 是区域宽高比例、尺寸是区域短边比例。
/// 数据只经 C 接口 s2a_shell_vpad_*（宿主 ios/vpad_shell.m），与游戏内拖动编辑同一份文件。
struct S2ArmTouchEditorView: View {
    let gameID: String
    let banner: URL?
    @State var opacity: Double
    let close: () -> Void

    struct Key: Identifiable { let id: String; var center: CGPoint; let size: CGSize; let radius: CGFloat }
    @State private var keys: [Key] = []
    @State private var area: CGRect = .zero
    @State private var problem: String?

    // 方案三「描线」+ 摇杆区方案二「石墨」（同 vpad.m vp_line / vp_face / 摇杆圈）
    private let line = Color.white.opacity(0.78), face = Color(red: 150 / 255, green: 215 / 255, blue: 230 / 255).opacity(0.9)

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size
            ZStack(alignment: .topLeading) {
                background(full)
                if full.width < full.height {
                    Text(shellText("Turn your phone sideways to adjust button positions")).font(.headline).foregroundStyle(.white).frame(width: full.width, height: full.height)
                    bar(full, landscape: false)
                } else {
                    sticks
                    ForEach($keys) { $k in keyView(k).position(k.center).gesture(drag($k)) }
                    bar(full, landscape: true)
                }
            }
            .onAppear { load(full) }
            .onChange(of: full) { _, new in load(new) }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    private func background(_ size: CGSize) -> some View {
        Group {
            if let banner, let image = UIImage(contentsOfFile: banner.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
            } else { Color(white: 0.15) }
        }
        .overlay(Color.black.opacity(0.25))
        .frame(width: size.width, height: size.height)
    }

    /// 摇杆是浮动的（左 / 右半屏任意处按下），这里只画石墨圈示意大致的拇指位，不能拖
    private var sticks: some View {
        let r = min(area.width, area.height) * 60 / 419   // 游戏内半径 60 点（短边 419 时）
        return ForEach([(0.075, 0.69, L("Left stick: press anywhere on the left half", "左摇杆：左半屏任意处按下")), (0.70, 0.81, L("Right stick: press anywhere on the right half", "右摇杆：右半屏任意处按下"))], id: \.2) { x, y, text in
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.32)).frame(width: 2 * r, height: 2 * r)
                    Circle().fill(Color(red: 210 / 255, green: 214 / 255, blue: 220 / 255).opacity(0.59)).frame(width: r * 52 / 60, height: r * 52 / 60)
                }
                Text(text).font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .opacity(opacity)
            .position(x: area.minX + x * area.width, y: area.minY + y * area.height)
            .allowsHitTesting(false)
        }
    }

    private func keyView(_ k: Key) -> some View {
        let isFace = ["A", "B", "X", "Y"].contains(k.id)
        let labels = ["PLUS": "＋", "MINUS": "－", "UP": "▲", "DOWN": "▼", "LEFT": "◀︎", "RIGHT": "▶︎", "LS": "L3", "RS": "R3"]
        return Text(labels[k.id] ?? k.id)
            .font(.system(size: isFace ? 17 : 13, weight: .bold))
            .foregroundStyle(isFace ? face : Color.white.opacity(0.86))
            .frame(width: k.size.width, height: k.size.height)
            .overlay(RoundedRectangle(cornerRadius: k.radius).stroke(line, lineWidth: 1.6))
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .contentShape(Rectangle())
            .opacity(opacity)
            .accessibilityLabel(k.id)
    }

    private func drag(_ k: Binding<Key>) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { g in
            let hw = k.wrappedValue.size.width / 2, hh = k.wrappedValue.size.height / 2   // 整个键不出可放区域
            k.wrappedValue.center = CGPoint(x: min(area.maxX - hw, max(area.minX + hw, g.location.x)),
                                            y: min(area.maxY - hh, max(area.minY + hh, g.location.y)))
        }
    }

    private func bar(_ size: CGSize, landscape: Bool) -> some View {
        VStack(spacing: 10) {
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            else if landscape { Text(shellText("Drag a button to move it (this game only)")).font(.footnote).foregroundStyle(.white) }
            HStack(spacing: 16) {
                if landscape { button(shellText("Reset to default")) { _ = gameID.withCString { s2a_shell_vpad_select($0, "default") }; close() } }
                button(shellText("Done")) { landscape ? save() : close() }
            }
            .frame(width: landscape ? 340 : 170)
            if landscape {
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        Text(shellText("Button opacity")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        Slider(value: $opacity, in: 0.1...1, step: 0.05) { editing in
                            if !editing { UserDefaults.standard.set(min(1, max(0.1, opacity)), forKey: "S2AVPadOpacity") }
                        }
                        .tint(.white)
                        Text("\(Int((opacity * 100).rounded()))%").font(.footnote.monospacedDigit()).foregroundStyle(.white).frame(width: 40, alignment: .trailing)
                    }
                    Text(shellText("Applies to all games; drag to preview here")).font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
                .frame(width: 340)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .position(x: size.width / 2, y: size.height / 2)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 可放区域同 vpad.m layoutSafeRect：安全区，左右至少 16、底至少 8 点
    private func load(_ full: CGSize) {
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let i = w?.safeAreaInsets ?? .zero
        let l = max(i.left, 16), r = max(i.right, 16), b = max(i.bottom, 8)
        area = CGRect(x: l, y: i.top, width: max(1, full.width - l - r), height: max(1, full.height - i.top - b))
        guard full.width >= full.height else { keys = []; return }
        guard let p = gameID.withCString({ s2a_shell_vpad_layout_json($0, Double(area.width), Double(area.height)) }) else {
            problem = L("Couldn’t read this game’s button layout", "读不到这款游戏的按键布局"); keys = []; return
        }
        defer { free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        let unit = min(area.width, area.height)
        keys = (obj?["buttons"] as? [[String: Any]] ?? []).compactMap { b in
            guard let id = b["id"] as? String, let x = b["x"] as? Double, let y = b["y"] as? Double,
                  let bw = b["width"] as? Double, let bh = b["height"] as? Double else { return nil }
            let size = CGSize(width: min(area.width, bw * unit), height: min(area.height, bh * unit))
            let radius = min((b["cornerRadius"] as? Double ?? 0) * unit, min(size.width, size.height) / 2)
            return Key(id: id, center: CGPoint(x: area.minX + x * area.width, y: area.minY + y * area.height), size: size, radius: radius)
        }
    }

    private func save() {
        var centers: [String: [Double]] = [:]
        for k in keys { centers[k.id] = [Double(k.center.x - area.minX), Double(k.center.y - area.minY)] }   // 区域坐标（原点左上）
        guard let data = try? JSONSerialization.data(withJSONObject: centers), let json = String(data: data, encoding: .utf8) else { problem = L("Button positions weren’t saved", "按键位置没保存"); return }
        let ok = gameID.withCString { g in json.withCString { s2a_shell_vpad_save(g, $0, Double(area.width), Double(area.height)) } }
        if ok == 1 { close() } else { problem = L("Button positions weren’t saved. Please try again.", "按键位置没保存，请再试一次") }
    }
}
#endif
