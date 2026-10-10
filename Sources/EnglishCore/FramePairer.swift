import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 帧内配对：一帧里的散行 → 一组 (中文, 英文)
//
// ⚠️ 关键约束（9.5 结论 ①）：**不能用绝对 y 阈值配对**。
//
// 实测：同一句 "能得到你的赞美…" 连续 5 帧，中文行的 y 从 0.116 漂到 0.042，
// 漂了 0.074；而英文行稳定在 0.58。所以"中英相差 N 个像素"这类阈值一定脆。
//
// 但**上下顺序 100% 稳定**，且 gap 极大（0.5 左右）。所以配对靠的是：
//   结构关系（中文在英文上方）+ 水平位置一致（中英字幕通常居中对齐）
//
// 噪音 `开启画9`（x=0.871）就是这么被干掉的——它跟英文行（x=0.227）
// 水平差了 0.64，水平一致性项直接归零，**不需要任何写死的坐标**。
// ─────────────────────────────────────────────────────────────────────────────

public enum FramePairer {

    /// 汉字占比超过这个值就算中文行。
    /// `天啊….` 这种带标点的算下来是 0.5，`开启画9` 是 0.75，英文行是 0。
    public static let chineseRatioThreshold = 0.3

    /// 一行至少要能提炼出这么多字符才算数。
    /// 挡掉 OCR 吐出来的 `•` / `•P` 这类纯噪声碎片。
    public static let minKeyLength = 2

    // MARK: - 语种判定

    /// 去掉空白/标点/符号后，汉字字符占的比例
    public static func hanRatio(_ s: String) -> Double {
        let meaningful = s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        guard !meaningful.isEmpty else { return 0 }
        let han = meaningful.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return Double(han) / Double(meaningful.count)
    }

    public static func language(of line: OCRLine) -> LineLanguage {
        hanRatio(line.text) >= chineseRatioThreshold ? .chinese : .english
    }

    // MARK: - 配对

    public static func pair(_ frame: FrameInput) -> SubtitlePair {
        let usable = frame.lines.filter {
            TextNormalizer.compareKey($0.text).count >= minKeyLength
        }
        let zhLines = usable.filter { language(of: $0) == .chinese }
        let enLines = usable.filter { language(of: $0) == .english }

        if zhLines.isEmpty && enLines.isEmpty {
            return SubtitlePair(chinese: nil, english: nil, score: 0)
        }

        // 暴力枚举取最优。一帧最多两三行，不值得上更聪明的算法
        var best: SubtitlePair?
        for z in zhLines {
            for e in enLines {
                let s = pairScore(z, e)
                if s > (best?.score ?? -1) {
                    best = SubtitlePair(chinese: z, english: e, score: s)
                }
            }
        }

        if let best { return best }

        // 只配上一半。仍然返回，让组装器能在单边继续判断是不是同一句
        if let z = zhLines.first { return SubtitlePair(chinese: z, english: nil, score: 0) }
        if let e = enLines.first { return SubtitlePair(chinese: nil, english: e, score: 0) }
        return SubtitlePair(chinese: nil, english: nil, score: 0)
    }

    /// 配对打分。三项权重是照着实测数据夹出来的，不是拍脑袋：
    /// 水平一致性是主力（噪音行靠它被淘汰），gap 合理性只用来挡掉
    /// "中文跑到英文下面去了"这种结构错误。
    static func pairScore(_ zh: OCRLine, _ en: OCRLine) -> Double {
        let xConsistency = max(0, 1 - abs(zh.x - en.x) / 0.5)
        let gap = en.y - zh.y
        let purity = min(hanRatio(zh.text), 1 - hanRatio(en.text))
        return 0.6 * xConsistency + 0.3 * gapScore(gap) + 0.1 * purity
    }

    /// gap 合理性是个梯形：太近（可能压行）或太远（可能跨了区域）都降分。
    /// 实测正常 gap 在 0.44–0.54 之间。
    static func gapScore(_ gap: Double) -> Double {
        if gap <= 0.10 { return 0 }        // 中文在英文下方 → 结构错
        if gap < 0.25 { return (gap - 0.10) / 0.15 }
        if gap <= 0.85 { return 1 }
        if gap < 1.0 { return (1.0 - gap) / 0.15 }
        return 0
    }
}
