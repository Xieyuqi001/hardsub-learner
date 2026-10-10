import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 判"是不是同一句"
//
// 阈值 0.85 不是拍脑袋来的——它落在 9.5 实测数据的空档正中间：
//
//   同一句跨帧的真实差异   ≥ 0.83   （`thank ygu` / `l was` / `天啊….`）
//   不同句之间             ≤ 0.40   （`谢谢你` vs `能得到你的赞美…` 只有 0.08）
//
// 中间那段空档有 0.4 宽，所以阈值不敏感，取中间值就行。
// ─────────────────────────────────────────────────────────────────────────────

public enum Similarity {

    /// 编辑距离。用 Character 而不是 UnicodeScalar —— 汉字和 emoji 要按"一个字"算
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)

        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    /// 归一化相似度，0–1。1 = 完全一致
    public static func ratio(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let d = Double(levenshtein(a, b))
        return 1 - d / Double(max(a.count, b.count))
    }

    /// 已经过 compareKey 的骨架之间比对
    public static func keyRatio(_ keyA: String, _ keyB: String) -> Double {
        ratio(keyA, keyB)
    }

    /// 两句原文本的相似度（内部先走 compareKey）。
    /// 要拿数值做判断用这个；只要布尔结论用 `isSameSentence`。
    public static func sentenceSimilarity(_ a: String, _ b: String) -> Double {
        keyRatio(TextNormalizer.compareKey(a), TextNormalizer.compareKey(b))
    }

    /// 判同一句。两串会各自走一遍 compareKey。
    public static func isSameSentence(_ a: String, _ b: String,
                                      threshold: Double = 0.85) -> Bool {
        let ka = TextNormalizer.compareKey(a)
        let kb = TextNormalizer.compareKey(b)
        let r = keyRatio(ka, kb)
        if r >= threshold { return true }

        // 短串放宽：`天啊…` / `谢谢你` 这种只有两三个字，
        // 一个字的差异（`天啊….`）就能把相似度压到 0.75，
        // 但那明明是同一句。这里允许"只要编辑距离够小"。
        if max(ka.count, kb.count) <= 8, r >= 0.70, levenshtein(ka, kb) <= 2 {
            return true
        }
        return false
    }
}
