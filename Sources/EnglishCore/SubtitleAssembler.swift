import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 组装器：一帧一帧的 (中文, 英文) → 一句一句的 SubtitleEntry
//
// 干两件事：
//   A. 切句    —— 判断这一帧还是不是上一句（靠 compareKey 的模糊相似度）
//   B. 择优    —— 同一句在几十帧里有几十个略有出入的版本，挑一个入库
//
// 设计上是个**纯状态机**：喂 FrameInput，吐已经定稿的 SubtitleEntry。
// 不认识时间从哪来、不认识屏幕。所以可以在没有视频的情况下回归。
// ─────────────────────────────────────────────────────────────────────────────

public struct AssemblerConfig: Sendable {
    /// 相似度 ≥ 此值 → 还是同一句
    public var sameThreshold: Double = 0.85
    /// 相似度 < 此值 → 明确是新句；中间那段留一帧观察
    public var newSentenceThreshold: Double = 0.50
    /// 容忍几帧空白（转场黑场）。超过就强制收句
    public var emptyFrameTolerance: Int = 1
    /// 一句最长持续多久。防止暂停/卡屏时这一句永远收不了尾
    public var maxSentenceDuration: TimeInterval = 30
    /// 单句的候选变体上限，防止卡屏时内存无限涨
    public var maxVariants: Int = 30

    public init() {}
}

public struct SubtitleAssembler {

    public private(set) var config: AssemblerConfig

    public init(config: AssemblerConfig = AssemblerConfig()) {
        self.config = config
    }

    // MARK: - 对外的两个入口

    /// 喂一帧，返回这一帧**新定稿**的句子（通常是 0 或 1 条）
    public mutating func consume(_ frame: FrameInput) -> [SubtitleEntry] {
        let pair = FramePairer.pair(frame)

        // ── 空白帧 ──────────────────────────────────────────────────
        guard !pair.isEmpty else {
            emptyRun += 1
            if emptyRun > config.emptyFrameTolerance, let acc = current {
                pending = nil
                current = nil
                return [finalize(acc)]
            }
            return []
        }
        emptyRun = 0

        // ── 有一帧在观察中 ──────────────────────────────────────────
        // 上一帧落进了"不确定"区间，缓存了一帧。现在看这一帧站哪边。
        if let held = pending {
            pending = nil

            if pairSimilarity(pair, held.pair) >= config.sameThreshold {
                // 确认切句：held 确实是新句的开头
                var out: [SubtitleEntry] = []
                if let acc = current { out.append(finalize(acc)) }
                startNew(held.pair, at: held.timestamp)
                append(pair, at: frame.timestamp)
                return out
            }
            // held 是噪声抖动 → 并回上一句，再按正常流程处理当前帧
            append(held.pair, at: held.timestamp)
            return handle(pair, at: frame.timestamp)
        }

        return handle(pair, at: frame.timestamp)
    }

    /// 采集结束/手动停止时收尾，把没定稿的那句吐出来
    public mutating func flush() -> [SubtitleEntry] {
        pending = nil
        guard let acc = current else { return [] }
        current = nil
        return [finalize(acc)]
    }

    // MARK: - 状态

    private struct Variant {
        var text: String        // storeText 之后的样子，将来直接给用户看
        var key: String         // compareKey，只用于比对
        var count: Int
        var confidenceSum: Double
    }

    private struct Accumulator {
        var start: TimeInterval
        var end: TimeInterval
        var frameCount: Int
        var chinese: [Variant]
        var english: [Variant]
        /// 最后一次看到的配对，用来和下一帧比相似度
        var lastPair: SubtitlePair

        init(pair: SubtitlePair, at timestamp: TimeInterval) {
            start = timestamp
            end = timestamp
            frameCount = 0
            chinese = []
            english = []
            lastPair = pair
        }
    }

    private var current: Accumulator?
    private var pending: (pair: SubtitlePair, timestamp: TimeInterval)?
    private var emptyRun = 0
    private var nextIndex = 1

    // MARK: - 切句

    private mutating func handle(_ pair: SubtitlePair,
                                 at timestamp: TimeInterval) -> [SubtitleEntry] {
        guard let acc = current else {
            startNew(pair, at: timestamp)
            return []
        }

        // 卡屏/暂停保护：这一句拖太久了，切开
        if timestamp - acc.start > config.maxSentenceDuration {
            let done = finalize(acc)
            startNew(pair, at: timestamp)
            return [done]
        }

        let sim = pairSimilarity(pair, acc.lastPair)
        if sim >= config.sameThreshold {
            append(pair, at: timestamp)
            return []
        }
        if sim < config.newSentenceThreshold {
            let done = finalize(acc)
            startNew(pair, at: timestamp)
            return [done]
        }

        // 不确定 —— 挂起一帧，看下一帧站哪边
        pending = (pair, timestamp)
        return []
    }

    private mutating func startNew(_ pair: SubtitlePair, at timestamp: TimeInterval) {
        current = Accumulator(pair: pair, at: timestamp)
        append(pair, at: timestamp)
    }

    /// 两组配对是不是同一句字幕。
    ///
    /// **不能取平均。** 中英两行的 OCR 质量互不相关，一行干净一行崩是常态
    /// （中文笔画密，比英文更容易崩）。取平均等于让崩的那一边单独否决：
    /// 实测 `一个脑油烫j尼一个脑` / `一个闷油烫与J店：一个闷` 是同一句，
    /// 英文还是**一字不差**，均值却被中文拖到 0.818 → 挂起 → 下一帧又切句，
    /// 一句变两条。真实数据 46 句里中了 1 次。
    ///
    /// 判据是两边的**结构**，不是两边的平均：
    ///
    ///   - 有一边几乎一字未变（≥ sameThreshold），另一边也没差到"明显是另一句"
    ///     （≥ newSentenceThreshold）→ 同一句。这是主力情形。
    ///   - 否则以**弱的那一边**为准：只要有一边明显不同，就不判同一句。
    ///
    /// 第二条是必须的，它挡住了"相邻两句英文恰好一模一样"：
    /// `我不知道。` 和 `别问我。` 都配 `I don't know.`，英文相似度 1.0，
    /// 但中文相似度只有 0.2 —— 取弱值就正确地判成两句。
    private func pairSimilarity(_ a: SubtitlePair, _ b: SubtitlePair) -> Double {
        var parts: [Double] = []
        if let az = a.chinese, let bz = b.chinese {
            parts.append(Similarity.sentenceSimilarity(az.text, bz.text))
        }
        if let ae = a.english, let be = b.english {
            parts.append(Similarity.sentenceSimilarity(ae.text, be.text))
        }
        guard let strong = parts.max() else { return 0 }
        let weak = parts.min()!

        if strong >= config.sameThreshold, weak >= config.newSentenceThreshold {
            return 1.0
        }
        return weak
    }

    private mutating func append(_ pair: SubtitlePair, at timestamp: TimeInterval) {
        guard current != nil else { return }
        current!.end = timestamp
        current!.frameCount += 1
        current!.lastPair = pair
        if let z = pair.chinese { addVariant(z, to: &current!.chinese) }
        if let e = pair.english { addVariant(e, to: &current!.english) }
    }

    private func addVariant(_ line: OCRLine, to pool: inout [Variant]) {
        let text = TextNormalizer.storeText(line.text)
        let key = TextNormalizer.compareKey(line.text)
        if let i = pool.firstIndex(where: { $0.text == text }) {
            pool[i].count += 1
            pool[i].confidenceSum += Double(line.confidence)
            return
        }
        guard pool.count < config.maxVariants else { return }
        pool.append(Variant(text: text, key: key, count: 1,
                            confidenceSum: Double(line.confidence)))
    }

    // MARK: - 定稿 & 择优

    private mutating func finalize(_ acc: Accumulator) -> SubtitleEntry {
        let entry = SubtitleEntry(
            index: nextIndex,
            start: acc.start,
            end: acc.end,
            chinese: pick(acc.chinese, language: .chinese),
            english: pick(acc.english, language: .english),
            frameCount: acc.frameCount,
            isFlash: acc.frameCount <= 1
        )
        nextIndex += 1
        return entry
    }

    /// 从一堆变体里挑一个入库。
    ///
    /// **卫生缺陷是过滤器，不是分数项。** 这一条是拿实测数据逼出来的：
    /// 中文 `天啊….` 出现 2 次、`天啊…` 只出现 1 次，按票数应该选前者——
    /// 但前者是错的（多出来一个西文句点）。任何"投票类"的信号都救不了这个，
    /// 只有"这条明显脏"能救。所以先按缺陷数筛，再在干净的里面投票。
    private func pick(_ pool: [Variant], language: LineLanguage) -> String {
        guard !pool.isEmpty else { return "" }
        if pool.count == 1 { return pool[0].text }

        let scored = pool.map { ($0, defects(in: $0.text, language: language)) }
        let minDefects = scored.map(\.1).min()!
        let candidates = scored.filter { $0.1 == minDefects }.map(\.0)

        let totalFrames = pool.reduce(0) { $0 + $1.count }

        let ranked = candidates.sorted { a, b in
            let sa = variantScore(a, totalFrames: totalFrames, pool: pool)
            let sb = variantScore(b, totalFrames: totalFrames, pool: pool)
            if sa != sb { return sa > sb }
            // 同分时保证确定性：短的优先，再按字典序
            if a.text.count != b.text.count { return a.text.count < b.text.count }
            return a.text < b.text
        }
        return ranked[0].text
    }

    /// 投票为主、共识为辅。
    /// confidence 只给 0.15 —— 9.5 结论 ③：英文 confidence 常年 0.30–0.50
    /// 却识别正确，中文噪音也能到 0.50，这个信号几乎没有区分度。
    /// 它存在只是为了让"都差不多"的时候有个稳定的兜底，权重刻意压低。
    private func variantScore(_ v: Variant, totalFrames: Int, pool: [Variant]) -> Double {
        let support = Double(v.count) / Double(max(1, totalFrames))
        let consensus = consensusScore(v, pool: pool)
        let meanConfidence = v.confidenceSum / Double(max(1, v.count))
        return 0.60 * support + 0.25 * consensus + 0.15 * meanConfidence
    }

    /// 这个变体和池子里其它变体的平均相似度。"长得像大多数"的版本得分高，
    /// 能挡住那种只在某一帧冒出来的畸变。
    private func consensusScore(_ v: Variant, pool: [Variant]) -> Double {
        let others = pool.filter { $0.text != v.text }
        let weight = others.reduce(0) { $0 + $1.count }
        guard weight > 0 else { return 1 }
        let sum = others.reduce(0.0) { $0 + Double($1.count) * Similarity.keyRatio(v.key, $1.key) }
        return sum / Double(weight)
    }

    /// 数这条文本有多"脏"。0 = 干净。
    ///
    /// 只数**确定的**错误，不做风格判断：中文行里混进西文字母/数字/标点，
    /// 英文行里混进汉字，英文里出现孤零零的 `l`（英文里根本没有这个单词，
    /// 是 `I` 被认错的——实测帧 23 的 `l was` vs 帧 26 的 `I was`）。
    public func defects(in text: String, language: LineLanguage) -> Int {
        let t = TextNormalizer.storeText(text)
        if t.isEmpty { return 1000 }

        var n = 0
        switch language {
        case .chinese:
            for u in t.unicodeScalars where u.isASCII {
                if CharacterSet.alphanumerics.contains(u) { n += 1 }
                else if CharacterSet.punctuationCharacters.contains(u) { n += 1 }
                else if CharacterSet.symbols.contains(u) { n += 1 }
            }
        case .english:
            for u in t.unicodeScalars where (0x4E00...0x9FFF).contains(u.value) { n += 1 }
            for token in t.split(whereSeparator: { $0.isWhitespace }) {
                let bare = token.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                if ["l", "1", "|"].contains(bare) { n += 1 }
            }
        }
        return n
    }
}
