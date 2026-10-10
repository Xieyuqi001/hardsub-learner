import Foundation
import EnglishCore

/// 真实剧集夹具：27 帧原始 OCR 输出 + 人肉核对的期望结果
struct Fixture: Decodable {
    struct Meta: Decodable {
        var name: String
        var source: String
        var note: String
        var frameInterval: TimeInterval
    }
    struct Frame: Decodable {
        var lines: [OCRLine]
    }
    struct ExpectedEntry: Decodable {
        var chinese: String
        var english: String
        /// 1-based，对应 frames 数组的下标 + 1
        var firstFrame: Int
        var lastFrame: Int
    }
    struct Expected: Decodable {
        var sentenceCount: Int
        var entries: [ExpectedEntry]
    }

    var meta: Meta
    var frames: [Frame]
    var expected: Expected

    /// 把帧序号（1-based）换算成时间戳。夹具里不存时间戳，
    /// 这样"时间戳整体缩放"那类不变量测试才好构造。
    func timestamp(ofFrame index1Based: Int) -> TimeInterval {
        TimeInterval(index1Based - 1) * meta.frameInterval
    }

    /// 按夹具的帧间隔把 frames 变成组装器的输入
    func frameInputs(timestampScale: Double = 1, confidenceOverride: Float? = nil) -> [FrameInput] {
        frames.enumerated().map { i, f in
            let lines = f.lines.map { line -> OCRLine in
                var l = line
                if let c = confidenceOverride { l.confidence = c }
                return l
            }
            return FrameInput(timestamp: timestamp(ofFrame: i + 1) * timestampScale,
                              lines: lines)
        }
    }

    static func load() throws -> Fixture {
        guard let url = Bundle.module.url(forResource: "episode_ep01",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            throw FixtureError.notFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound
        var description: String {
            "找不到 Fixtures/episode_ep01.json。检查 Package.swift 里 EnglishCoreCheck 的 resources 配置。"
        }
    }
}

/// 跑一遍完整的组装流程，返回最终定稿的句子
func assemble(_ frames: [FrameInput],
              config: AssemblerConfig = AssemblerConfig()) -> [SubtitleEntry] {
    var assembler = SubtitleAssembler(config: config)
    var out: [SubtitleEntry] = []
    for frame in frames {
        out.append(contentsOf: assembler.consume(frame))
    }
    out.append(contentsOf: assembler.flush())
    return out
}
