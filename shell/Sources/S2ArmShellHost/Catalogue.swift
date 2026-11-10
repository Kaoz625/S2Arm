import Foundation
import ShellUI

/// 游戏目录清单（catalogue JSON）：S2Arm 出包 / 组装期写、库界面读。字段名取上游 `game.manifest.json`（schema 1）的必要子集，
/// 同名同义，未来接对方 manifest 不改键；不认识的键忽略。
///
/// ```json
/// { "schema": 1,
///   "games": [ { "title_id": "0100ABCDEF012345", "name": "游戏名", "display_version": "1.0.0",
///                "banner": "covers/x.jpg", "icon": "icons/x.png",
///                "state": "playable" | "needs_game_data" | "needs_app_update" | "broken",
///                "reason": "一行原因", "detail": "给玩家的一句话" } ] }
/// ```
/// banner / icon 是相对清单所在目录的路径（也可绝对路径），读不到就不显示图（界面画占位）。
public struct CatalogueEntry: Decodable, Equatable, Sendable {
    public var titleID: String
    public var name: String
    public var displayVersion: String?
    public var banner: String?
    public var icon: String?
    public var state: String?
    public var reason: String?
    public var detail: String?

    enum CodingKeys: String, CodingKey {
        case name, banner, icon, state, reason, detail
        case titleID = "title_id", displayVersion = "display_version"
    }
}

public struct CatalogueFile: Decodable, Equatable, Sendable {
    public var schema: Int
    public var games: [CatalogueEntry]
    public static let supportedSchema = 1
}

/// 读清单的结果：界面用的条目 + 读的过程中发现的问题（只进日志，不弹窗）。
public struct Catalogue: Equatable, Sendable {
    public var tiles: [GameTile]
    public var problems: [String]
    /// 游戏号 → 封面（banner）文件：虚拟手柄布局编辑页拿它当范例底图（Artwork 的像素在上游模块里不公开）
    public var bannerURLs: [String: URL] = [:]

    /// 从文件读；文件不在 / 坏了 → 空列表 + 一条问题。
    public static func load(path: String) -> Catalogue {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return Catalogue(tiles: [], problems: ["清单读不了：\(path)"]) }
        return parse(data, baseDirectory: url.deletingLastPathComponent())
    }

    /// 纯解析：同一份字节与目录总得同一结果（单测直接测它）。
    public static func parse(_ data: Data, baseDirectory: URL) -> Catalogue {
        let file: CatalogueFile
        do { file = try JSONDecoder().decode(CatalogueFile.self, from: data) }
        catch { return Catalogue(tiles: [], problems: ["清单 JSON 坏了：\(error)"]) }
        guard file.schema == CatalogueFile.supportedSchema else {
            return Catalogue(tiles: [], problems: ["清单 schema \(file.schema) 不认（只认 \(CatalogueFile.supportedSchema)）"])
        }
        var seen = Set<String>()
        var tiles: [GameTile] = []
        var problems: [String] = []
        var banners: [String: URL] = [:]
        for e in file.games {
            // 同一 title_id 只留第一条：界面以 id 区分条目，重复会乱焦点
            guard seen.insert(e.titleID).inserted else { problems.append("重复的 title_id \(e.titleID)，后一条丢弃"); continue }
            var state = gameState(e)
            if !isTitleID(e.titleID) {
                state = .broken(reason: "", detail: "", technical: L("title_id \"\(e.titleID)\" is not 16 uppercase hex digits", "title_id \"\(e.titleID)\" 不是 16 位大写十六进制"))
                problems.append("title_id \"\(e.titleID)\" 不合规，按不可用显示")
            }
            if let b = e.banner, !b.isEmpty { banners[e.titleID] = b.hasPrefix("/") ? URL(fileURLWithPath: b) : baseDirectory.appendingPathComponent(b) }
            tiles.append(GameTile(id: e.titleID, title: e.name, subtitle: e.displayVersion ?? "",
                                  banner: artwork(e.banner, id: e.titleID + ".banner", base: baseDirectory),
                                  icon: artwork(e.icon, id: e.titleID + ".icon", base: baseDirectory),
                                  state: state))
        }
        var c = Catalogue(tiles: tiles, problems: problems); c.bannerURLs = banners
        return c
    }

    static func gameState(_ e: CatalogueEntry) -> GameState {
        switch e.state ?? "playable" {
        case "playable": .playable
        case "needs_game_data": .needsGameData
        case "needs_app_update": .needsAppUpdate
        case "broken": .broken(reason: e.reason ?? "", detail: e.detail ?? "")
        case let other: .broken(reason: "", detail: "", technical: L("Unknown state \"\(other)\"", "未知状态 \"\(other)\""))
        }
    }

    static func artwork(_ path: String?, id: String, base: URL) -> Artwork? {
        guard let path, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Artwork(id: id, data: data)
    }
}

/// 与上游 GameManifest 同口径：16 位数字或大写 A–F。
func isTitleID(_ text: String) -> Bool {
    text.count == 16 && text.allSatisfy { $0.isNumber || ("A"..."F").contains($0) }
}
