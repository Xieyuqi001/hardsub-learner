import EnglishCapture
import EnglishCore
import Foundation

/// 一次「观看会话」。一次看一集 = 一份文档。
struct SessionMeta: Codable {
    var id: String
    var name: String
    var startedAt: Date
    var selection: ScreenSelection?
}

/// 会话的落盘目录。
///
///   ~/Library/Application Support/English/sessions/<id>/
///       meta.json      会话元信息
///       entries.jsonl  一句一行，**追加写**
///
/// 选 JSONL 而不是 SQLite：追加写天然崩溃安全（写坏最多坏最后一行），
/// 而且能直接 `cat` / `grep` 看，调试和导出都省事。等真需要查询了再上数据库。
final class SessionStore {

    let root: URL

    /// `root` 只有自检会传：给一个临时目录，就能在**完全不碰用户真实数据**的前提下
    /// 跑完整的落盘路径（真实 FileManager、真实原子写、真实 JSON coder）。
    /// 见 `English --selftest-store`。
    init(root: URL? = nil) {
        if let root {
            self.root = root
            return
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        self.root = base.appendingPathComponent("English/sessions", isDirectory: true)
    }

    func listSessions() -> [SessionMeta] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return ids.compactMap { id in
            let url = root.appendingPathComponent(id).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder.session.decode(SessionMeta.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func meta(of id: String) -> SessionMeta? {
        let url = root.appendingPathComponent(id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.session.decode(SessionMeta.self, from: data)
    }

    /// 只读地读一个会话的条目，**不开写句柄**。
    ///
    /// 工作台是旁观的：如果它和正在采集的那个会话共用同一个 `FileHandle`，
    /// 两边的写偏移会互相踩。所以读和写必须走两条路。
    func entries(of id: String) -> [SubtitleEntry] {
        Session.decodeEntries(at: root.appendingPathComponent(id)
            .appendingPathComponent("entries.jsonl"))
    }

    /// 改会话的**展示名**。
    ///
    /// 目录 id **不动**：它既是排序键又是引用目标，改它要迁移全部数据、改所有指向它的
    /// 地方，收益为零。所以名字纯粹是 `meta.json` 里的一个字段。
    ///
    /// 只写 `meta.json` 这**一个**文件，而且是原子写。采集侧在会话创建之后再不读它
    /// （`CaptureCoordinator` 只在 createSession 时写一次，唯一的读者是导出，走的是读盘），
    /// 所以**采集进行中改名是安全的**，两边不会抢文件。
    ///
    /// 代价：**已经导出过的文件不会追溯更新**，下一次导出才用新名字。
    func rename(id: String, to newName: String) throws -> SessionMeta {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionStoreError.emptyName }
        guard var meta = meta(of: id) else { throw SessionStoreError.noSuchSession }

        meta.name = trimmed
        let url = root.appendingPathComponent(id).appendingPathComponent("meta.json")
        try JSONEncoder.session.encode(meta).write(to: url, options: .atomic)
        return meta
    }

    // MARK: - 收藏（M9）
    //
    // 收藏落在**每个会话目录**里，而不是一个全局文件：一个会话的收藏文件坏了，
    // 只影响那一集，其余照常显示（同 entries.jsonl「坏一行只坏一行」的哲学）。
    // 工作台是它唯一的写入方；采集侧不碰它。

    /// 读一个会话的收藏。文件不存在 / 坏掉 / 半截 → 空文档，**不抛错**。
    func favorites(of id: String) -> FavoritesDoc {
        FavoritesDoc.decode(try? Data(contentsOf: favoritesURL(of: id)))
    }

    /// 原子写。写一半被杀不会留下半截文件。
    func setFavorites(_ doc: FavoritesDoc, for id: String) throws {
        guard meta(of: id) != nil else { throw SessionStoreError.noSuchSession }
        try doc.encoded().write(to: favoritesURL(of: id), options: .atomic)
    }

    /// 跨会话聚合，给全局收藏视图用。
    ///
    /// **排序是白送的**：`listSessions()` 本来就按 `startedAt` 倒序返回，
    /// 顺着它走即可，不需要在这里再排一遍。空的会话直接跳过。
    func listAllFavorites() -> [(meta: SessionMeta, favorites: [Favorite])] {
        listSessions().compactMap { meta in
            let doc = favorites(of: meta.id)
            return doc.isEmpty ? nil : (meta, doc.favorites)
        }
    }

    private func favoritesURL(of id: String) -> URL {
        root.appendingPathComponent(id).appendingPathComponent("favorites.json")
    }

    func createSession(name: String? = nil, selection: ScreenSelection?) throws -> Session {
        let now = Date()
        let id = Self.sessionID(for: now)
        let meta = SessionMeta(
            id: id,
            name: name ?? Self.defaultName(for: now),
            startedAt: now,
            selection: selection
        )
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.session.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        return Session(meta: meta, directory: dir)
    }

    /// 会话 id 用时间戳，兼作目录名——天然可排序，人眼也能读懂
    private static func sessionID(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func defaultName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return "观看会话 \(f.string(from: date))"
    }
}

enum SessionStoreError: LocalizedError {
    case emptyName
    case noSuchSession

    var errorDescription: String? {
        switch self {
        case .emptyName: "名字不能为空"
        case .noSuchSession: "找不到这个会话"
        }
    }
}

/// 一个已打开的会话，负责追加写。
/// `@unchecked Sendable`：持有 FileHandle（非 Sendable），但只被单一采集任务串行写。
final class Session: @unchecked Sendable {
    let meta: SessionMeta
    private let entriesURL: URL
    private let handle: FileHandle?

    init(meta: SessionMeta, directory: URL) {
        self.meta = meta
        let url = directory.appendingPathComponent("entries.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.entriesURL = url
        self.handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ entry: SubtitleEntry) throws {
        var data = try JSONEncoder.session.encode(entry)
        data.append(0x0A)   // 换行
        try handle?.write(contentsOf: data)
    }

    func loadEntries() -> [SubtitleEntry] {
        Self.decodeEntries(at: entriesURL)
    }

    /// JSONL 解码。最后一行可能只写了一半（进程被杀），`compactMap` 会把它丢掉——
    /// 这正是选 JSONL 而不是单个 JSON 数组的原因：坏一行只坏一行。
    static func decodeEntries(at url: URL) -> [SubtitleEntry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder.session
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(SubtitleEntry.self, from: Data($0.utf8))
        }
    }

    func close() {
        try? handle?.close()
    }
}

extension JSONEncoder {
    static let session: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
}

extension JSONDecoder {
    static let session: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
