import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 收藏（M9）
//
// 和 Models.swift 同一条约束：**这一层不读时钟**。`starredAt` 由调用方传进来，
// 于是同一输入永远得到同一输出——回归才能是可复现的。
//
// 为什么不把收藏塞进 SubtitleEntry：`entries.jsonl` 是采集侧的**追加写**文件，
// 它的「崩溃安全」正是靠"只追加、不改写"换来的。工作台去改写它会破坏那个前提。
// 收藏另存 `favorites.json`，工作台独写、采集侧永不碰，详见
// docs/plan-workbench-v1.1.md 的 D2 与 §8「永久不变量」。
//
// 为什么收藏带**文本快照**：跨会话的收藏视图因此只需读 N 个小文件，
// 不必把 N 份完整字幕稿全解析一遍；原句万一重编号，快照也还在。
// ─────────────────────────────────────────────────────────────────────────────

/// 一条收藏。
public struct Favorite: Sendable, Equatable, Codable {
    /// 句在会话内的序号（与 `SubtitleEntry.index` 同一个坐标）
    public var index: Int
    /// 英文快照
    public var english: String
    /// 中文快照。片源没有中字时为空串
    public var chinese: String
    /// 收藏时刻。由调用方传入
    public var starredAt: Date

    public init(index: Int, english: String, chinese: String, starredAt: Date) {
        self.index = index
        self.english = english
        self.chinese = chinese
        self.starredAt = starredAt
    }
}

/// 一个会话的收藏集合 —— 就是 `favorites.json` 的形状。
public struct FavoritesDoc: Sendable, Equatable, Codable {

    public var favorites: [Favorite]

    public init(favorites: [Favorite] = []) {
        self.favorites = favorites
    }

    // MARK: - 查询

    public var isEmpty: Bool { favorites.isEmpty }
    public var count: Int { favorites.count }

    public func contains(index: Int) -> Bool {
        favorites.contains { $0.index == index }
    }

    public func favorite(at index: Int) -> Favorite? {
        favorites.first { $0.index == index }
    }

    // MARK: - 增删
    //
    // 只有「加」和「去」，**没有 toggle**。
    //
    // 网页侧点星标时发的是**明确意图**（这条要收藏 / 这条要取消），不是"翻一下"。
    // 因为网页的渲染状态可能落后于盘上的真实状态，而 toggle 在状态错位时会**翻错**：
    // 本以为要取消，结果反而加了一条。明确意图在错位时是自愈的——
    // 重复加是幂等的，重复取消也是幂等的，两种情况都收敛到正确结果。

    /// 收藏一句。**幂等**：同一 index 已在集合里就原样返回（不产生第二条）。
    public func adding(_ entry: SubtitleEntry, at date: Date) -> FavoritesDoc {
        guard !contains(index: entry.index) else { return self }
        let added = Favorite(index: entry.index, english: entry.english,
                             chinese: entry.chinese, starredAt: date)
        return FavoritesDoc(favorites: favorites + [added]).sorted()
    }

    /// 取消收藏。**幂等**：index 不在集合里就原样返回（不崩、不变）。
    public func removing(index: Int) -> FavoritesDoc {
        guard contains(index: index) else { return self }
        return FavoritesDoc(favorites: favorites.filter { $0.index != index })
    }

    // MARK: - 排序与去重

    /// index 升序；同一 index（只可能来自手改过的文件）再按 `starredAt` 排，
    /// 保证是个**全序**，去掉"排序不稳定导致输出随机"的隐患。
    public func sorted() -> FavoritesDoc {
        FavoritesDoc(favorites: favorites.sorted {
            $0.index != $1.index ? $0.index < $1.index : $0.starredAt < $1.starredAt
        })
    }

    /// 同一 index 出现多次时只留第一次。正常写入路径产生不了重复
    /// （`adding` 是幂等的），这一步纯粹是兜手改过的文件。
    public func deduped() -> FavoritesDoc {
        var seen = Set<Int>()
        return FavoritesDoc(favorites: sorted().favorites.filter { seen.insert($0.index).inserted })
    }

    // MARK: - 编解码

    /// **任何坏数据都退化成空文档，不抛错。**
    ///
    /// 同 `entries.jsonl`「坏一行只坏一行」的哲学：某一个会话的收藏文件坏了，
    /// 不该让整个跨会话的收藏视图跟着失败——那一集少几条，其余照常显示。
    public static func decode(_ data: Data?) -> FavoritesDoc {
        guard let data, !data.isEmpty,
              let doc = try? decoder.decode(FavoritesDoc.self, from: data) else {
            return FavoritesDoc()
        }
        return doc.deduped()
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(sorted())
    }

    // iso8601：和 SessionStore 的 coder 保持一致，网页侧 `new Date(...)` 能直接解析。
    // 代价：iso8601 不带小数秒，`starredAt` 落盘时会被截到整秒——收藏时间精确到秒足够。
    // prettyPrinted：和 entries.jsonl 一样保持人能直接 cat 看。
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
