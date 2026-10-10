import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 两套清洗，用途完全不同，**不要混用**
//
//   storeText   —— 入库/显示用。保留大小写和标点，只干掉行首说话人标记。
//                  用户要读的就是这个，不能被"归一化"成看不懂的样子。
//
//   compareKey  —— 只用来判断"两帧说的是不是同一句"。激进到几乎只剩骨架。
//
// 为什么比对要这么激进：同一句字幕跨帧的真实 OCR 差异（9.5 实测）——
//
//     帧 2  `-oh, uh. yeah. Oh, thank ygu so much.`
//     帧 3  `- oh, uh, yeah. Oh, thank you so much.`
//     帧 23 `- Honestly, l was like obsessed ... when lwas ten`
//     帧 26 `- Honestly, I was like obsessed ... when I was ten`
//
// 差异全是**前导 `- ` 有无、大小写、标点、`I`↔`l`、`you`↔`ygu`**。
// 字符串相等在这里完全失效——每帧都对不上，同一句话会被切成一堆碎片入库。
// ─────────────────────────────────────────────────────────────────────────────

public enum TextNormalizer {

    /// 行首的说话人切换标记。字幕里 `- ` 表示换人说话（9.5 结论 ⑤）
    private static let speakerMarkers: Set<Character> = ["-", "–", "—", "•"]

    /// 长得像 `I` 的单字符代词。OCR 在 `I` / `l` / `1` / `|` 之间反复横跳
    private static let ambiguousPronouns: Set<String> = ["i", "l", "1", "|", "丨"]

    /// 去掉行首说话人标记。只去一个，且后面必须还有内容，
    /// 免得把一句本来就是破折号开头的句子吃穿。
    public static func stripSpeakerMarker(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, speakerMarkers.contains(first) {
            let rest = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { t = rest }
        }
        return t
    }

    /// 入库/显示用。保留大小写和标点，只做最小必要清理。
    public static func storeText(_ s: String) -> String {
        collapseWhitespace(stripSpeakerMarker(s))
    }

    /// 比对用。步骤顺序是有意义的，改动前先看下面的检查器单测。
    ///
    ///   1. NFC 归一
    ///   2. 去说话人标记
    ///   3. 大小写折叠
    ///   4. 去标点/符号（`You're` → `Youre`）
    ///   5. **按词**折叠 `i`/`l`/`1`/`|` —— 必须在去空白之前做，
    ///      否则词边界没了，`l was` 和 `I was` 的差异会被当成普通替换
    ///   6. 去全部空白（`lwas` ↔ `I was` 靠这一步才能对上）
    ///
    /// 刻意**没有**做 rn→m / vv→w 这类连字折叠：实测数据里没出现过，
    /// 而它们会货真价实地抹掉差异。等真见到了再加。
    public static func compareKey(_ s: String) -> String {
        let folded = stripSpeakerMarker(s)
            .precomposedStringWithCanonicalMapping
            .lowercased()

        // 去标点与符号，保留字母/数字/空白/汉字
        var kept = String.UnicodeScalarView()
        for u in folded.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(u) { continue }
            if CharacterSet.symbols.contains(u) { continue }
            kept.append(u)
        }

        // 按词折叠歧义代词
        let tokens = String(kept)
            .split(whereSeparator: { $0.isWhitespace })
            .map { ambiguousPronouns.contains(String($0)) ? "i" : String($0) }

        // 去全部空白
        return tokens.joined()
    }

    /// 把连续空白压成单个空格，并去首尾
    public static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
