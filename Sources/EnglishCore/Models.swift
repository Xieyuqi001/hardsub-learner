import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// EnglishCore 的数据模型
//
// 这一层刻意**不认识**屏幕、Vision、AppKit、时间。所有系统交互都发生在
// 调用方：抓屏层负责把 Vision 的左下原点坐标翻成左上原点，再喂进来。
// 这样整个内核可以拿一份 JSON 夹具离线回归，不需要屏幕、不需要视频。
// ─────────────────────────────────────────────────────────────────────────────

/// OCR 出来的一行。坐标已归一化到抓取区域，**左上角为原点**。
public struct OCRLine: Sendable, Equatable, Codable {
    public var text: String
    public var confidence: Float
    /// 行左端。0 = 区域最左，1 = 区域最右
    public var x: Double
    /// 行顶端。0 = 区域最上，1 = 区域最下
    public var y: Double

    public init(text: String, confidence: Float, x: Double, y: Double) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
    }
}

/// 行的语种。只有两种——中英混排的字幕里没有"第三种"。
public enum LineLanguage: String, Sendable, Codable {
    case chinese
    case english
}

/// 一帧的输入
public struct FrameInput: Sendable, Equatable, Codable {
    public var timestamp: TimeInterval
    public var lines: [OCRLine]

    public init(timestamp: TimeInterval, lines: [OCRLine]) {
        self.timestamp = timestamp
        self.lines = lines
    }
}

/// 帧内配对的结果。一边缺失是允许的（OCR 偶尔只认出一行）。
public struct SubtitlePair: Sendable, Equatable {
    public var chinese: OCRLine?
    public var english: OCRLine?
    /// 配对的置信分，仅用于在多个候选里选最优；单边配对时为 0
    public var score: Double

    public init(chinese: OCRLine?, english: OCRLine?, score: Double) {
        self.chinese = chinese
        self.english = english
        self.score = score
    }

    public var isEmpty: Bool { chinese == nil && english == nil }
}

/// 最终沉淀下来的一条字幕
public struct SubtitleEntry: Sendable, Equatable, Codable {
    /// 会话内的序号，从 1 开始
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    /// 中文（清洗掉说话人标记后）。没有中文行时为空串
    public var chinese: String
    /// 英文（清洗掉说话人标记后）。没有英文行时为空串
    public var english: String
    /// 这一句在多少帧里出现过。1 = 只在单帧闪过
    public var frameCount: Int
    /// 单帧句。可能是转场闪帧，也可能是真的很短的一句——不丢，只标记
    public var isFlash: Bool

    public init(index: Int, start: TimeInterval, end: TimeInterval,
                chinese: String, english: String,
                frameCount: Int, isFlash: Bool) {
        self.index = index
        self.start = start
        self.end = end
        self.chinese = chinese
        self.english = english
        self.frameCount = frameCount
        self.isFlash = isFlash
    }
}
