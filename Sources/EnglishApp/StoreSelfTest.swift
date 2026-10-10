import EnglishCapture
import EnglishCore
import Foundation

/// `English --selftest-store`
///
/// 验的是**只靠读代码确认不了**的那些性质：改名和收藏到底有没有按预期落到盘上，
/// 以及那条最要紧的不变量 —— **工作台永不写 `entries.jsonl`**。
///
/// 全程在临时目录里跑（`SessionStore(root:)`），**不碰用户的真实数据**。
/// 这和 `--selftest-capture` 是同一个路数：GUI 点不出来的东西，用命令行验。
enum StoreSelfTest {

    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "  \u{001B}[32m✓\u{001B}[0m \(label)"
                     : "  \u{001B}[31m✗ \(label)\u{001B}[0m")
            if !ok { failures += 1 }
        }

        // 注意这里**套了两层**：store.root 是 sessions/，它的上一级才是
        // 「导出文件该落的地方」——和线上 Application Support/English/sessions 同构。
        //
        // 为什么必须套这一层：收藏导出落在 root.deletingLastPathComponent()。
        // 如果直接把 root 设在 NSTemporaryDirectory() 上，导出的 favorites.md
        // 就掉进**所有进程共用的 $TMPDIR**，defer 只删得掉会话目录、删不掉它。
        // 于是第一遍跑全绿，第二遍开始「零收藏时不生成空文件」那条必红 ——
        // 一条只在首跑成立的断言，等于没验。
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("english-store-selftest-\(UUID().uuidString)")
        let tmp = home.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }   // 删 home，连带 favorites.md

        print("── 落盘自检（临时目录，不碰真实数据）──")
        print("  \(home.path)\n")

        let store = SessionStore(root: tmp)

        // ── 建会话 ──────────────────────────────────────
        guard let session = try? store.createSession(selection: nil) else {
            print("  \u{001B}[31m✗ 建会话就失败了，后面的都不用跑\u{001B}[0m")
            return 1
        }
        let id = session.meta.id
        let dir = tmp.appendingPathComponent(id)
        let metaURL = dir.appendingPathComponent("meta.json")
        let entriesURL = dir.appendingPathComponent("entries.jsonl")

        check(FileManager.default.fileExists(atPath: metaURL.path), "建会话 → meta.json 落盘")

        // ── 铺 3 句真实形状的数据（含一条没中字的）────────
        let entries = [
            SubtitleEntry(index: 1, start: 0, end: 1.4,
                          chinese: "我不会骗你的。", english: "I'm not gonna lie to you.",
                          frameCount: 3, isFlash: false),
            SubtitleEntry(index: 2, start: 1.4, end: 2.9,
                          chinese: "你能来我真的很高兴。", english: "I'm really glad you came.",
                          frameCount: 3, isFlash: false),
            SubtitleEntry(index: 3, start: 2.9, end: 3.2,
                          chinese: "", english: "Anyway.",
                          frameCount: 1, isFlash: true),
        ]
        for e in entries { try? session.append(e) }
        session.close()

        check(store.entries(of: id).count == 3, "追加 3 句 → entries.jsonl 读回 3 句")

        // 记下改名前 entries.jsonl 的原始字节，最后要拿它验不变量
        guard let entriesBefore = try? Data(contentsOf: entriesURL) else {
            print("  \u{001B}[31m✗ 读不回 entries.jsonl\u{001B}[0m")
            return 1
        }

        // ── 改名 ────────────────────────────────────────
        var renameError: Error?
        var renamed: SessionMeta?
        do { renamed = try store.rename(id: id, to: "  怪奇物语 S01E01  ") } catch { renameError = error }

        check(renameError == nil, "改名不抛错")
        check(renamed?.name == "怪奇物语 S01E01",
              "首尾空白被 trim 掉（'  怪奇物语 S01E01  ' → '怪奇物语 S01E01'）")
        check(store.meta(of: id)?.name == "怪奇物语 S01E01", "从盘上重读 meta.json → 新名字在")
        check(session.meta.id == id && FileManager.default.fileExists(atPath: dir.path),
              "★ 目录名（= id）没变，会话目录还在原处")

        // 空名字必须被拒，而且**不能把盘上已有的名字改坏**
        var emptyRejected = false
        do { _ = try store.rename(id: id, to: "   ") } catch { emptyRejected = true }
        check(emptyRejected, "空名字 / 全空格被拒（抛错）")
        check(store.meta(of: id)?.name == "怪奇物语 S01E01", "被拒之后盘上的名字完好无损")

        // ── 收藏 ────────────────────────────────────────
        check(store.favorites(of: id).isEmpty, "新会话还没有任何收藏（文件不存在 → 空文档）")

        var doc = store.favorites(of: id)
        doc = doc.adding(entries[0], at: Date(timeIntervalSince1970: 1_760_000_000))
        doc = doc.adding(entries[2], at: Date(timeIntervalSince1970: 1_760_000_100))
        try? store.setFavorites(doc, for: id)

        check(store.favorites(of: id).count == 2, "收藏 2 句 → favorites.json 落盘 2 条")
        check(store.favorites(of: id).favorite(at: 3)?.chinese == "",
              "没中字的那句，空中文快照也存得住")
        check(store.favorites(of: id).favorite(at: 1)?.english == "I'm not gonna lie to you.",
              "英文快照经落盘往返后一模一样")

        // 幂等要经得起**落盘往返**——内存里对不代表盘上对
        var again = store.favorites(of: id)
        again = again.adding(entries[0], at: Date(timeIntervalSince1970: 0))
        try? store.setFavorites(again, for: id)
        check(store.favorites(of: id).count == 2, "重复收藏同一句（经落盘往返）→ 仍然 2 条")

        try? store.setFavorites(store.favorites(of: id).removing(index: 1), for: id)
        let afterRemove = store.favorites(of: id)
        check(afterRemove.count == 1 && afterRemove.contains(index: 3),
              "取消第 1 句 → 只剩第 3 句")

        // ── 换一个 store 实例重读：证明是盘上的，不是内存里的 ──
        let reopened = SessionStore(root: tmp)
        check(reopened.favorites(of: id).count == 1, "换 store 实例重读 → 收藏还在")
        check(reopened.meta(of: id)?.name == "怪奇物语 S01E01", "换 store 实例重读 → 新名字还在")
        check(reopened.listAllFavorites().count == 1, "跨会话聚合：这一集出现在收藏列表里")

        // ── 抗损坏 ──────────────────────────────────────
        try? Data("这不是 json".utf8)
            .write(to: dir.appendingPathComponent("favorites.json"))
        check(store.favorites(of: id).isEmpty, "favorites.json 坏掉 → 退化成空收藏，不崩")
        check(store.listSessions().count == 1, "收藏文件坏掉不影响会话本身还在")

        // ── 零收藏时不许生成空文件 ──────────────────────
        // 此刻上面刚把 favorites.json 弄坏过，所以等价于"一条收藏都没有"
        let noFav = Exporter.writeFavorites(format: .markdown, store: store)
        check(!noFav.ok, "【反向对照】零收藏导出 → 明确报错，不假装成功")
        let favMD = store.root.deletingLastPathComponent()
            .appendingPathComponent("favorites.md")
        check(!FileManager.default.fileExists(atPath: favMD.path),
              "零收藏时**不生成空文件**（空文件会让人分不清是没收藏还是导出坏了）")

        // ── 改名要跟着导出走 ────────────────────────────
        try? store.setFavorites(afterRemove, for: id)   // 把收藏写回去，顺便修好上面那步
        let exported = Exporter.write(sessionID: id, format: .markdown, store: store)
        check(exported.ok, "导出成功")
        let md = (try? String(contentsOfFile: exported.path, encoding: .utf8)) ?? ""
        check(md.hasPrefix("# 怪奇物语 S01E01"),
              "★ 导出文档的标题用的是新名字（改名会传导到之后的导出）")

        // ── 跨会话聚合 + 收藏导出 ───────────────────────
        //
        // 会话 id 的精度是**秒**，所以连开两个会话会撞 id。等一秒，
        // 顺便也保证了下面那条"按会话时间倒序"有确定的先后。
        Thread.sleep(forTimeInterval: 1.1)
        guard let second = try? store.createSession(name: "绝命毒师 S02E03", selection: nil) else {
            print("  \u{001B}[31m✗ 第二个会话没建成\u{001B}[0m")
            return 1
        }
        let id2 = second.meta.id
        check(id2 != id, "第二个会话 id 与第一个不同（id 精度是秒，这里正好也把它验了）")

        let entries2 = [
            SubtitleEntry(index: 1, start: 0, end: 1, chinese: "说对了。",
                          english: "You got that right.", frameCount: 3, isFlash: false),
            // 故意跳号：验"编号用原 index"，重新连号的实现会在这里露馅
            SubtitleEntry(index: 7, start: 1, end: 2, chinese: "我们得走了。",
                          english: "We need to go.", frameCount: 3, isFlash: false),
        ]
        for e in entries2 { try? second.append(e) }
        second.close()

        var doc2 = FavoritesDoc()
        doc2 = doc2.adding(entries2[0], at: Date(timeIntervalSince1970: 1_760_001_000))
        doc2 = doc2.adding(entries2[1], at: Date(timeIntervalSince1970: 1_760_001_100))
        try? store.setFavorites(doc2, for: id2)

        let groups = store.listAllFavorites()
        check(groups.count == 2, "【反向对照】两个会话都有收藏 → 两组（不是只返回一组）")
        check(groups.first?.meta.id == id2, "组按会话时间倒序：最新那一集排第一")

        let favExport = Exporter.writeFavorites(format: .markdown, store: store)
        check(favExport.ok, "收藏导出成功")
        check(favExport.sentenceCount == 3, "导出报告 3 句（1 + 2）")
        check(favExport.path.hasSuffix("/favorites.md"), "落在 sessions 的**上一级**，不是某个会话目录里")

        let out = (try? String(contentsOfFile: favExport.path, encoding: .utf8)) ?? ""
        check(out.hasPrefix("# 收藏 · 背诵材料"), "标题正确")
        check(out.contains("共 3 句 · 来自 2 集"), "头部统计正确")
        check(out.contains("## 怪奇物语 S01E01（"), "★ 第一集的分组标题用的是改名后的新名字")
        check(out.contains("## 绝命毒师 S02E03（"), "第二集的分组标题也在")
        check(out.contains("\n7. **We need to go.**"),
              "★ 编号用它在原会话里的 index（第 7 句就写 7），不重新连号")
        check(!out.contains("\n2. **"),
              "【反向对照】没有重新连号才会出现的 2.（把编号改成 1..n 就会在这里红）")
        check(out.contains("**You got that right.**\n    说对了。"),
              "英文加粗、中文缩进一行，和会话导出同一种排版")

        if let a = out.range(of: "## 绝命毒师"), let b = out.range(of: "## 怪奇物语") {
            check(a.lowerBound < b.lowerBound, "导出里的分组顺序与会话时间倒序一致")
        } else {
            check(false, "两个分组标题都该在导出里")
        }

        // ── 不变量 ──────────────────────────────────────
        let entriesAfter = try? Data(contentsOf: entriesURL)
        check(entriesAfter != nil && entriesAfter == entriesBefore,
              "★★ 不变量：改完名、收藏又取消、还导出过之后，entries.jsonl 一个字节都没变")

        print("")
        if failures == 0 {
            print("\u{001B}[32m全部通过\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m失败 \(failures) 项\u{001B}[0m")
        return 1
    }
}
