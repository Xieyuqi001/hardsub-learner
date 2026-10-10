import EnglishCore
import Foundation

/// 把一次会话写成中英对照的背诵材料。
///
/// 单独拆出来而不是留在 `WorkbenchWindow` 里：生成文档和"把文档显示在哪个窗口"
/// 是两件事。拆开之后导出逻辑可以脱离窗口被调用（批量导出、命令行、将来的
/// 自动导出），也不必为了测它去起一个 WKWebView。
enum Exporter {

    enum Format: String {
        case markdown = "md"
        case plainText = "txt"

        var filename: String {
            switch self {
            case .markdown: "export.md"
            case .plainText: "export.txt"
            }
        }

        var favoritesFilename: String {
            switch self {
            case .markdown: "favorites.md"
            case .plainText: "favorites.txt"
            }
        }
    }

    struct Result {
        var ok: Bool
        var path: String = ""
        var sentenceCount: Int = 0
        var characterCount: Int = 0
        var error: String = ""

        var json: [String: Any] {
            ok
                ? ["ok": true, "path": path,
                   "sentenceCount": sentenceCount, "characterCount": characterCount]
                : ["ok": false, "error": error]
        }
    }

    /// 写进会话目录，紧挨着 `entries.jsonl`。
    /// 不放桌面也不放下载：导出物和它的来源数据待在一起，找起来最省事。
    static func write(sessionID: String, format: Format, store: SessionStore) -> Result {
        guard let meta = store.meta(of: sessionID) else {
            return Result(ok: false, error: "打不开这个会话")
        }
        let entries = store.entries(of: sessionID)
        guard !entries.isEmpty else {
            return Result(ok: false, error: "这个会话还没有任何字幕")
        }

        let text = format == .markdown ? markdown(entries, meta: meta) : plainText(entries)
        let dest = store.root
            .appendingPathComponent(sessionID)
            .appendingPathComponent(format.filename)

        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            return Result(ok: false, error: "写入失败：\(error.localizedDescription)")
        }
        return Result(ok: true, path: dest.path,
                      sentenceCount: entries.count, characterCount: text.count)
    }

    /// 英文加粗、中文缩进一行。
    ///
    /// 刻意让英文占视觉重心——这份材料是拿来学英语的，中文只是对照。
    /// 缩进四个空格在 Markdown 里会渲染成代码块，正好把中文压成次要的第二行。
    static func markdown(_ entries: [SubtitleEntry], meta: SessionMeta) -> String {
        var out = "# \(meta.name)\n\n"

        out += "> \(dateFormatter.string(from: meta.startedAt)) · \(entries.count) 句\n"
        if let s = meta.selection {
            out += String(format: "> 抓取区域 %.0f, %.0f · %.0f×%.0f\n",
                          s.x, s.y, s.width, s.height)
        }
        out += "\n---\n\n"

        for e in entries {
            out += "\(e.index). "
            out += e.english.isEmpty ? "*(没识别到英文)*" : "**\(e.english)**"
            out += "\n"
            if !e.chinese.isEmpty {
                out += "    \(e.chinese)\n"
            }
            out += "\n"
        }
        return out
    }

    static func plainText(_ entries: [SubtitleEntry]) -> String {
        entries.map { e in
            let en = e.english.isEmpty ? "(没识别到英文)" : e.english
            let zh = e.chinese.isEmpty ? "" : "\n\(e.chinese)"
            return "\(en)\(zh)"
        }.joined(separator: "\n\n")
    }

    // MARK: - 收藏导出（M9）

    /// 把**所有会话**的收藏汇总成一篇背诵材料。
    ///
    /// 和上面的 `write` 各自独立、不共用函数：会话导出是「这一集的全量流水账」，
    /// 收藏导出是「跨集的节选」，两者的头部、分组、编号规则都不一样。
    /// 硬凑成一个函数只会让两边的边界都变模糊。
    static func writeFavorites(format: Format, store: SessionStore) -> Result {
        let groups = store.listAllFavorites()
        guard !groups.isEmpty else {
            // 明确报错，**不生成空文件** —— 空文件混在目录里，下次会分不清
            // 是"真的没收藏"还是"导出坏了"
            return Result(ok: false, error: "还没有收藏")
        }

        let total = groups.reduce(0) { $0 + $1.favorites.count }
        let text = format == .markdown
            ? favoritesMarkdown(groups, total: total)
            : favoritesPlainText(groups)

        // 放到 sessions 的**上一级**：收藏是跨会话的，塞进任何一个会话目录都不对
        let dest = store.root.deletingLastPathComponent()
            .appendingPathComponent(format.favoritesFilename)

        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            return Result(ok: false, error: "写入失败：\(error.localizedDescription)")
        }
        return Result(ok: true, path: dest.path,
                      sentenceCount: total, characterCount: text.count)
    }

    static func favoritesMarkdown(_ groups: [(meta: SessionMeta, favorites: [Favorite])],
                                  total: Int) -> String {
        var out = "# 收藏 · 背诵材料\n\n"
        out += "> 共 \(total) 句 · 来自 \(groups.count) 集 · "
        out += "导出于 \(dateFormatter.string(from: Date()))\n\n"
        out += "---\n\n"

        for group in groups {
            out += "## \(group.meta.name)（\(dayFormatter.string(from: group.meta.startedAt))）\n\n"
            for f in group.favorites {
                // 编号用它在**原会话里**的 index，不重新连号 ——
                // 背诵时忽然想回原文档看上下文，靠这个号才找得到
                out += "\(f.index). "
                out += f.english.isEmpty ? "*(没识别到英文)*" : "**\(f.english)**"
                out += "\n"
                if !f.chinese.isEmpty { out += "    \(f.chinese)\n" }
                out += "\n"
            }
        }
        return out
    }

    static func favoritesPlainText(_ groups: [(meta: SessionMeta, favorites: [Favorite])]) -> String {
        groups.map { group in
            let body = group.favorites.map { f -> String in
                let en = f.english.isEmpty ? "(没识别到英文)" : f.english
                let zh = f.chinese.isEmpty ? "" : "\n\(f.chinese)"
                return "\(en)\(zh)"
            }.joined(separator: "\n\n")
            return "\(group.meta.name)\n\n\(body)"
        }.joined(separator: "\n\n\n")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
