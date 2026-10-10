import Foundation
import EnglishCore

// ─────────────────────────────────────────────────────────────────────────────
// 离线回归器
//
//   swift run core-check
//
// 不需要屏幕、不需要视频、不需要任何测试框架。夹具是真实剧集的 27 帧
// 原始 OCR 输出（docs/requirements.md §9.5），期望值是人肉核对过的。
// 改完 EnglishCore 的任何地方都跑一次。
// ─────────────────────────────────────────────────────────────────────────────

let h = Harness()

// ═══════════════════════════════════════════════════════════════════════════
h.group("归一化 · compareKey 的清洗顺序")
// ═══════════════════════════════════════════════════════════════════════════

h.equal(TextNormalizer.compareKey("You're"), "youre", "去标点：You're → youre")
h.equal(TextNormalizer.compareKey("I was"), "iwas", "去空白：I was → iwas")
h.equal(TextNormalizer.compareKey("l was"), "iwas", "孤立 l 折叠成 i：l was → iwas")
h.equal(TextNormalizer.compareKey("lwas"), "lwas",
        "粘连的 lwas 不动（它是 l+was 还是 lwas 无法从字面判断，不能瞎猜）")
h.equal(TextNormalizer.compareKey("- Oh, uh, yeah. Oh, thank you so much."),
        TextNormalizer.compareKey("Oh, uh, yeah. Oh, thank you so much."),
        "说话人标记不参与比对")
h.equal(TextNormalizer.compareKey("开启画9"), "开启画9", "汉字和数字原样保留")
h.equal(TextNormalizer.compareKey("HELLO"), "hello", "大小写折叠")

h.equal(TextNormalizer.storeText("- You're an excellent joke writer."),
        "You're an excellent joke writer.",
        "storeText 只去说话人标记，保留大小写和标点（用户要读的是这个）")
h.equal(TextNormalizer.stripSpeakerMarker("-"), "-",
        "只有破折号时不吃穿，避免把内容清空")
h.equal(TextNormalizer.storeText("  你好   世界  "), "你好 世界", "连续空白压成一个空格")

// ═══════════════════════════════════════════════════════════════════════════
h.group("相似度 · 阈值要落进实测的空档里")
// ═══════════════════════════════════════════════════════════════════════════

let samePairs: [(String, String, String)] = [
    ("Oh, uh, yeah. Oh, thank ygu so much.", "Oh, uh, yeah. Oh, thank you so much.", "you ↔ ygu"),
    ("- Honestly, l was like obsessed when lwas ten",
     "- Honestly, I was like obsessed when I was ten", "l ↔ I、粘连 lwas ↔ I was"),
    ("天啊….", "天啊…", "多出一个西文句点"),
    ("Uh, wow, that mneans so much", "Uh, wow, that means so much", "m ↔ mn"),
]
for (a, b, why) in samePairs {
    let r = Similarity.sentenceSimilarity(a, b)
    h.atLeast(r, 0.85, "同一句：\(why)")
    h.check(Similarity.isSameSentence(a, b), "同一句判定：\(why)")
}

let diffPairs: [(String, String, String)] = [
    ("谢谢夸奖", "你是个很棒的写手", "完全不同的中文句"),
    ("谢谢你", "能得到你的赞美 对我来说意义重大", "短句 vs 长句"),
    ("Oh my God.", "Oh, Thanks.", "完全不同的英文句"),
]
for (a, b, why) in diffPairs {
    let r = Similarity.sentenceSimilarity(a, b)
    h.atMost(r, 0.50, "不同句：\(why)")
    h.check(!Similarity.isSameSentence(a, b), "不同句判定：\(why)")
}

h.equal(Similarity.ratio("", ""), 1.0, "两个空串算完全一致")
h.equal(Similarity.ratio("abc", ""), 0.0, "空串对非空串算完全不一致")
h.equal(Similarity.levenshtein("kitten", "sitting"), 3, "编辑距离基准用例")

// ═══════════════════════════════════════════════════════════════════════════
h.group("语种判定")
// ═══════════════════════════════════════════════════════════════════════════

func lang(_ text: String) -> LineLanguage {
    FramePairer.language(of: OCRLine(text: text, confidence: 1, x: 0, y: 0))
}
h.equal(lang("谢谢夸奖"), .chinese, "纯中文")
h.equal(lang("天啊…."), .chinese, "中文 + 标点（标点不计入分母）")
h.equal(lang("开启画9"), .chinese, "中文 + 数字")
h.equal(lang("Oh my God."), .english, "纯英文")
h.equal(lang("You're an excellent joke writer."), .english, "带撇号的英文")

// ═══════════════════════════════════════════════════════════════════════════
h.group("卫生缺陷计数器")
// ═══════════════════════════════════════════════════════════════════════════

let asm = SubtitleAssembler()
h.equal(asm.defects(in: "天啊…", language: .chinese), 0, "干净的中文（中文省略号不算缺陷）")
h.equal(asm.defects(in: "天啊….", language: .chinese), 1, "中文里混进西文句点")
h.equal(asm.defects(in: "开启画9", language: .chinese), 1, "中文里混进 ASCII 数字")
h.equal(asm.defects(in: "Honestly, I was there", language: .english), 0, "干净的英文")
h.equal(asm.defects(in: "Honestly, l was there", language: .english), 1,
        "英文里孤零零的 l —— 这不是个单词，是 I 被认错了")
// 缺陷按**字符**计数，不按词。所以这里 5 个字母 = 5。
// 刻意不改成按词：这里只用来在候选之间排序，而"混进去多少"用字符数衡量
// 更单调、更不容易被分词方式影响。绝对值没有意义，相对高低才有。
h.equal(asm.defects(in: "老实说 hello", language: .chinese), 5,
        "中文里混进英文单词（按字符计数，5 个字母 = 5）")
h.check(asm.defects(in: "老实说 hello", language: .chinese)
            > asm.defects(in: "老实说", language: .chinese),
        "混了东西的一定比干净的脏（这才是这个计数器实际被用到的地方）")

// ═══════════════════════════════════════════════════════════════════════════
h.group("帧内配对 · 靠结构关系和水平一致性，不靠写死的坐标")
// ═══════════════════════════════════════════════════════════════════════════

let noisyFrame = FrameInput(timestamp: 0, lines: [
    OCRLine(text: "开启画9", confidence: 0.50, x: 0.871, y: 0.047),
    OCRLine(text: "谢谢夸奖", confidence: 1.00, x: 0.417, y: 0.081),
    OCRLine(text: "-oh, uh. yeah. Oh, thank ygu so much.", confidence: 0.30, x: 0.227, y: 0.581),
])
let noisyPair = FramePairer.pair(noisyFrame)
h.equal(noisyPair.chinese?.text, "谢谢夸奖", "第 2 帧配到的是字幕，不是右上角 UI 噪音")
h.equal(noisyPair.english?.text, "-oh, uh. yeah. Oh, thank ygu so much.", "英文行配对正确")

let emptyPair = FramePairer.pair(FrameInput(timestamp: 0, lines: []))
h.check(emptyPair.isEmpty, "空帧配对结果为空")

let junkPair = FramePairer.pair(FrameInput(timestamp: 0, lines: [
    OCRLine(text: "•", confidence: 0.9, x: 0.1, y: 0.1),
    OCRLine(text: "•P", confidence: 0.9, x: 0.9, y: 0.8),
]))
h.check(junkPair.isEmpty, "纯噪声碎片（• / •P）被挡在门外")

// ═══════════════════════════════════════════════════════════════════════════
h.group("黄金用例 · 27 帧真实剧集")
// ═══════════════════════════════════════════════════════════════════════════

let fixture: Fixture
do {
    fixture = try Fixture.load()
} catch {
    print("\n\u{001B}[31m夹具加载失败：\(error)\u{001B}[0m")
    exit(1)
}

print("  夹具：\(fixture.meta.name) — \(fixture.frames.count) 帧，来自 \(fixture.meta.source)")

let entries = assemble(fixture.frameInputs())

h.equal(entries.count, fixture.expected.sentenceCount,
        "句数（\(fixture.frames.count) 帧里切出 \(fixture.expected.sentenceCount) 句）")

for (i, e) in fixture.expected.entries.enumerated() {
    guard i < entries.count else {
        h.check(false, "第 \(i + 1) 句缺失")
        continue
    }
    let actual = entries[i]
    h.equal(actual.chinese, e.chinese, "第 \(i + 1) 句中文")
    h.equal(actual.english, e.english, "第 \(i + 1) 句英文")
    h.close(actual.start, fixture.timestamp(ofFrame: e.firstFrame), tolerance: 0.001,
            "第 \(i + 1) 句起始时间")
    h.close(actual.end, fixture.timestamp(ofFrame: e.lastFrame), tolerance: 0.001,
            "第 \(i + 1) 句结束时间")
}

// 针对性的几条，写清楚"为什么这么测"，免得将来被人当成冗余删掉
let allChinese = entries.map(\.chinese).joined(separator: " ")
let allEnglish = entries.map(\.english).joined(separator: " ")
h.check(!allChinese.contains("开启画9") && !allEnglish.contains("开启画9"),
        "UI 噪音「开启画9」没有混进任何一句")
h.check(entries.allSatisfy { !$0.chinese.isEmpty && !$0.english.isEmpty },
        "没有出现只有半边（缺中或缺英）的句子")
h.check(!entries.contains { $0.chinese.contains("天啊….") },
        "第 4 句选中了「天啊…」而不是票数更多但更脏的「天啊….」")

let last = entries.last
h.equal(last?.english.contains("I was like obsessed"), true,
        "第 7 句选中了 I 版本（不是 l 版本）")
h.equal(entries[4].chinese, "能得到你的赞美 对我来说意义重大",
        "中文 y 从 0.116 漂到 0.042 的 5 帧仍然算同一句")
h.equal(entries[4].frameCount, 5, "上面那句确实由 5 帧构成")
h.check(entries.allSatisfy { !$0.isFlash }, "27 帧里没有单帧闪句（第 9 帧黑场没被当成一句）")

// ═══════════════════════════════════════════════════════════════════════════
h.group("不变量 · 改这些输入，输出必须纹丝不动")
// ═══════════════════════════════════════════════════════════════════════════

// ① confidence 全部拉平 → 结果必须完全一样。
//    这是把"confidence 不能当过滤阀"（9.5 结论 ③）钉死在代码里。
let flatConfidence = assemble(fixture.frameInputs(confidenceOverride: 0.42))
h.equal(flatConfidence, entries, "所有 confidence 改成同一个值 → 输出逐字段不变")

let zeroConfidence = assemble(fixture.frameInputs(confidenceOverride: 0.0))
h.equal(zeroConfidence, entries, "所有 confidence 归零 → 输出逐字段不变（它根本没有区分度）")

// ② 时间戳整体 ×2 → 句数和文本不变，时间戳等比缩放
let stretched = assemble(fixture.frameInputs(timestampScale: 2))
h.equal(stretched.count, entries.count, "时间戳整体 ×2 → 句数不变")
h.equal(stretched.map(\.chinese), entries.map(\.chinese), "时间戳整体 ×2 → 中文文本不变")
h.equal(stretched.map(\.english), entries.map(\.english), "时间戳整体 ×2 → 英文文本不变")
h.close(stretched[0].start, entries[0].start * 2, tolerance: 0.001, "时间戳整体 ×2 → 起始时间也 ×2")

// ③ 确定性
h.equal(assemble(fixture.frameInputs()), entries, "连跑两遍结果完全一致")

// ═══════════════════════════════════════════════════════════════════════════
h.group("成句边界 · 中英两行 OCR 质量互不相关")
// ═══════════════════════════════════════════════════════════════════════════
//
// 这一组是被真实数据逼出来的：46 句里有一句被切成了两条。
//
// ⚠️ 黄金夹具对这条路径的覆盖是 **0**（27 帧一次都没落进 pending）。
// 所以不能靠它守这条路径 —— 下面这些用例是唯一的防线。
//
// 每个正例都配一个**反向对照**：只验"别切开"的话，把逻辑改成"永不切句"
// 也能全绿。所以「真换句」的几例是必需的，不是凑数。

func pairFrame(_ t: TimeInterval, _ zh: String, _ en: String) -> FrameInput {
    FrameInput(timestamp: t, lines: [
        OCRLine(text: zh, confidence: 0.5, x: 0.10, y: 0.30),
        OCRLine(text: en, confidence: 0.5, x: 0.10, y: 0.70),
    ])
}
func assemblePairs(_ pairs: [(String, String)]) -> [SubtitleEntry] {
    assemble(pairs.enumerated().map { pairFrame(Double($0.offset) * 0.4, $0.element.0, $0.element.1) })
}

// ① 报告的 bug：同一句，英文全程一字不差，中文是同一句的两个噪声版本。
//    修前产出 2 条（`一个脑油烫j尼一个脑` 被单独切出去），修后 1 条。
let oneSidedZh = assemblePairs([
    ("一个脑油烫j尼一个脑",        "No dirty martini？"),
    ("一个闷油烫与J店：一个闷",     "No dirty martini？"),
    ("一个闷油烫与J店：一个闷",     "No dirty martini？"),
    ("一个闷油烫与J店：一个闷",     "No dirty martini？"),
    ("一个脑油烫j尼一个脑",        "No dirty martini？"),
])
h.equal(oneSidedZh.count, 1, "英文一字不差、中文乱认 → 仍是同一句（真实数据里就是这一条被切开了）")
h.equal(oneSidedZh[0].frameCount, 5, "那 5 帧全都记在同一句名下")

// ② 反向对照：真换句，两边都差很多 → 必须切开
let farApart = assemblePairs([
    ("谢谢夸奖，我只是运气好。", "Thanks, I just got lucky."),
    ("谢谢夸奖，我只是运气好。", "Thanks, I just got lucky."),
    ("如果我是你，我会再想想。", "If I were you, I'd think twice."),
    ("如果我是你，我会再想想。", "If I were you, I'd think twice."),
    ("如果我是你，我会再想想。", "If I were you, I'd think twice."),
])
h.equal(farApart.count, 2, "两边都差很多的换句 → 仍然切开")

// ③ 反向对照：真换句，但两边只是"中等相似"（会落进 pending 观察区）→ 也必须切开。
//    这一例是拿来挡住"把判据改成离当前句远就算"那种过度修正的：
//    ①的"离当前句距离"比这里还大，任何绝对阈值都分不开这两者。
let moderatelySimilar = assemblePairs([
    ("我们明天去公园散步吧", "Let's take a walk in the park tomorrow."),
    ("我们明天去公园散步吧", "Let's take a walk in the park tomorrow."),
    ("我们明天去公园野餐吧", "Let's have a picnic in the park tomorrow."),
    ("我们明天去公园野餐吧", "Let's have a picnic in the park tomorrow."),
    ("我们明天去公园野餐吧", "Let's have a picnic in the park tomorrow."),
])
h.equal(moderatelySimilar.count, 2, "中等相似的换句（pending 观察区）→ 仍然切开")

// ④ 反向对照：相邻两句英文**恰好一模一样**，但确实是两句不同的话。
//    这是"单边一字不差就算同一句"这个规则的对偶风险，拿中文的低相似度挡掉。
let sameEnglishTwice = assemblePairs([
    ("我不知道。", "I don't know."),
    ("我不知道。", "I don't know."),
    ("别问我。",   "I don't know."),
    ("别问我。",   "I don't know."),
    ("别问我。",   "I don't know."),
])
h.equal(sameEnglishTwice.count, 2, "相邻异句、英文恰好相同 → 不能并成一句")

// ⑤ 反向：换成中文一字不差、英文乱认 → 同样不该切开
let oneSidedEn = assemblePairs([
    ("我们明天去公园散步吧", "Let's take a walk in the park tomorrou."),
    ("我们明天去公园散步吧", "Let's take a walk in the park tomorrow."),
    ("我们明天去公园散步吧", "Let's take a walk in the parik tomorrow."),
    ("我们明天去公园散步吧", "Let's take a walk in the park tomorrow."),
])
h.equal(oneSidedEn.count, 1, "中文一字不差、英文乱认 → 仍是同一句")

// ═══════════════════════════════════════════════════════════════════════════
h.group("边界情况")
// ═══════════════════════════════════════════════════════════════════════════

// 全空输入
h.equal(assemble([]).count, 0, "一帧都没有 → 零句，不崩")

// 只有一帧
let single = assemble([FrameInput(timestamp: 0, lines: [
    OCRLine(text: "你好", confidence: 0.9, x: 0.4, y: 0.1),
    OCRLine(text: "Hello there.", confidence: 0.9, x: 0.4, y: 0.6),
])])
h.equal(single.count, 1, "单帧也能定稿一句")
h.check(single[0].isFlash, "单帧句被标记为 flash（不丢，但标记出来）")

// 连续空帧要收句
let withGap = assemble([
    FrameInput(timestamp: 0.0, lines: [OCRLine(text: "你好", confidence: 1, x: 0.4, y: 0.1),
                                       OCRLine(text: "Hello.", confidence: 1, x: 0.4, y: 0.6)]),
    FrameInput(timestamp: 0.4, lines: []),
    FrameInput(timestamp: 0.8, lines: []),
    FrameInput(timestamp: 1.2, lines: []),
])
h.equal(withGap.count, 1, "连续空帧后收句，不会永远挂着")

// 全屏模式（噪音行多）不应该让配对崩掉
let crowded = FramePairer.pair(FrameInput(timestamp: 0, lines: [
    OCRLine(text: "腾讯视频", confidence: 0.9, x: 0.05, y: 0.93),
    OCRLine(text: "1080P", confidence: 0.9, x: 0.92, y: 0.93),
    OCRLine(text: "第 3 集", confidence: 0.9, x: 0.48, y: 0.02),
    OCRLine(text: "谢谢夸奖", confidence: 1.0, x: 0.42, y: 0.10),
    OCRLine(text: "Oh, thank you so much.", confidence: 0.5, x: 0.23, y: 0.58),
]))
h.equal(crowded.chinese?.text, "谢谢夸奖", "满屏噪音时仍然挑中真正的字幕中文行")
h.equal(crowded.english?.text, "Oh, thank you so much.", "满屏噪音时仍然挑中真正的字幕英文行")

// ═══════════════════════════════════════════════════════════════════════════
h.group("收藏 · 增删是幂等的")
// ═══════════════════════════════════════════════════════════════════════════

// 收藏是「明确意图」而不是 toggle：网页发「收藏这条」/「取消这条」，
// 重复发同一条不能产生第二条。所以这一组的每个正例都必须配反向对照，
// 否则把 adding 写成「永远返回单条」也能全绿。

func entry(_ i: Int, _ en: String, _ zh: String = "") -> SubtitleEntry {
    SubtitleEntry(index: i, start: Double(i), end: Double(i) + 1,
                  chinese: zh, english: en, frameCount: 3, isFlash: false)
}

let t0 = Date(timeIntervalSince1970: 1_760_000_000)

var doc = FavoritesDoc()
doc = doc.adding(entry(12, "I'm not gonna lie to you.", "我不会骗你的"), at: t0)
h.equal(doc.count, 1, "收藏一句 → 一条")
h.check(doc.contains(index: 12), "contains 认得出刚收藏的那条")
h.equal(doc.favorite(at: 12)?.english, "I'm not gonna lie to you.", "英文快照存下来了")
h.equal(doc.favorite(at: 12)?.chinese, "我不会骗你的", "中文快照存下来了")
h.equal(doc.favorite(at: 12)?.starredAt, t0, "收藏时刻用的是传入的值（内核不自己读时钟）")

let twice = doc.adding(entry(12, "换个写法的同一句"), at: Date(timeIntervalSince1970: 0))
h.equal(twice.count, 1, "同一 index 收藏两次 → 仍然只有一条")
h.equal(twice.favorite(at: 12)?.english, "I'm not gonna lie to you.",
        "重复收藏不覆盖原有快照（幂等 = 原样返回）")

let twoDifferent = doc.adding(entry(13, "Another line."), at: t0)
h.equal(twoDifferent.count, 2, "【反向对照】不同 index 必须变成两条（证明去重没把不同的也吃掉）")

h.equal(doc.removing(index: 12).count, 0, "取消收藏 → 空")
h.equal(twoDifferent.removing(index: 12).count, 1,
        "【反向对照】取消一条要真的少一条（不是永远原样返回）")
h.equal(twoDifferent.removing(index: 12).favorite(at: 13)?.english, "Another line.",
        "取消的是指定那条，别的条不受影响")

let removeAbsent = doc.removing(index: 999)
h.equal(removeAbsent.count, 1, "取消一个没收藏过的 index → 不崩、也不变")
h.equal(removeAbsent, doc, "取消不存在的 index 返回内容完全相同的文档")

// ═══════════════════════════════════════════════════════════════════════════
h.group("收藏 · 排序是不变量")
// ═══════════════════════════════════════════════════════════════════════════

var shuffled = FavoritesDoc()
for i in [5, 3, 9, 1] { shuffled = shuffled.adding(entry(i, "line \(i)"), at: t0) }
h.equal(shuffled.favorites.map(\.index), [1, 3, 5, 9], "乱序收藏 → 落盘顺序按 index 升序")
h.equal(shuffled.sorted().favorites.map(\.index), [1, 3, 5, 9], "sorted() 对已排序的文档是恒等的")
h.equal(shuffled.sorted(), shuffled.sorted().sorted(), "sorted() 幂等（跑两遍结果相同，确定性）")

// ═══════════════════════════════════════════════════════════════════════════
h.group("收藏 · 坏数据不传染")
// ═══════════════════════════════════════════════════════════════════════════

// 哲学同 entries.jsonl 的「坏一行只坏一行」：一个会话的收藏坏了，
// 只该少那一集，不该让整个收藏视图失败。
h.equal(FavoritesDoc.decode(nil).count, 0, "文件不存在（nil）→ 空收藏")
h.equal(FavoritesDoc.decode(Data()).count, 0, "空文件 → 空收藏")
h.equal(FavoritesDoc.decode(Data("这不是 json".utf8)).count, 0, "不是 JSON → 空收藏")
h.equal(FavoritesDoc.decode(Data("{\"favorites\": [".utf8)).count, 0, "JSON 被截断 → 空收藏")
h.equal(FavoritesDoc.decode(Data("{}".utf8)).count, 0, "缺字段 → 空收藏（而不是抛错崩掉）")

// 【反向对照】上面全在证明「坏数据 → 空」，必须再有「好数据 → 非空」，
// 否则把 decode 写成永远返回空文档也能全部通过。
let goodData = try? doc.encoded()
h.equal(FavoritesDoc.decode(goodData).count, 1, "【反向对照】正常数据 → 解得出内容（解码真的在干活）")
h.equal(FavoritesDoc.decode(goodData), doc, "编解码往返后与原文档逐字段相等")

let dupJSON = Data("""
{"favorites":[
 {"index":7,"english":"a","chinese":"甲","starredAt":"2026-10-05T12:00:00Z"},
 {"index":7,"english":"b","chinese":"乙","starredAt":"2026-10-05T13:00:00Z"},
 {"index":2,"english":"c","chinese":"丙","starredAt":"2026-10-05T11:00:00Z"}
]}
""".utf8)
h.equal(FavoritesDoc.decode(dupJSON).count, 2, "手改出的重复 index 被去掉一条")
h.equal(FavoritesDoc.decode(dupJSON).favorites.map(\.index), [2, 7], "解码结果也已按 index 升序")
h.equal(FavoritesDoc.decode(dupJSON).favorite(at: 7)?.starredAt,
        ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z"),
        "重复 index 保留的是排序后的第一条，不是随机的某条")

// ═══════════════════════════════════════════════════════════════════════════
h.group("收藏 · 时间与缺失中文")
// ═══════════════════════════════════════════════════════════════════════════

h.equal(FavoritesDoc.decode(try? doc.encoded()).favorite(at: 12)?.starredAt, t0,
        "整秒时刻往返后不差一秒")

let fracDoc = FavoritesDoc(favorites: [
    Favorite(index: 1, english: "a", chinese: "", starredAt: Date(timeIntervalSince1970: 1_760_000_000.7))
])
h.equal(FavoritesDoc.decode(try? fracDoc.encoded()).favorite(at: 1)?.starredAt,
        Date(timeIntervalSince1970: 1_760_000_000),
        "iso8601 不带小数秒：starredAt 落盘截到整秒（已知行为，收藏精确到秒足够）")

let noChinese = doc.adding(entry(20, "No subtitle for this one."), at: t0)
h.equal(FavoritesDoc.decode(try? noChinese.encoded()).favorite(at: 20)?.chinese, "",
        "片源没中字时，空中文快照也能正常往返")

h.equal(FavoritesDoc(favorites: []).isEmpty, true, "空文档 isEmpty 为真")
h.check(!doc.isEmpty, "【反向对照】有内容时 isEmpty 为假")

exit(h.finish())
