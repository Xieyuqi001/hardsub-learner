import CoreGraphics
import EnglishCore
import Foundation

/// 一次采集会话：反复抓同一块区域，产出 FrameInput。
///
/// 轮询 + 指纹跳帧。字幕区域在两句之间是**完全静止**的，那些帧重跑 OCR
/// 纯属浪费（OCR 是整个链路里最贵的一步，占端到端 ~70%）。
///
/// `@unchecked Sendable`：只被单一采集任务串行使用。
public final class CaptureSession: @unchecked Sendable {

    public let geometry: ScreenCapturer.Geometry
    public let interval: Duration

    private let capturer: ScreenCapturer
    private let customWords: [String]
    private let startedAt = Date()
    private var lastHash: UInt64?

    public init(selection: ScreenSelection,
                interval: Duration = .milliseconds(400),
                customWords: [String] = []) async throws {
        self.capturer = try await ScreenCapturer(selection: selection)
        self.interval = interval
        self.customWords = customWords
        self.geometry = capturer.geometry
    }

    /// 抓一帧。
    /// 返回 nil 表示画面和上一帧**完全一致**，已经跳过识别（省一次 OCR）。
    public func nextFrame() async throws -> FrameInput? {
        let image = try await capturer.capture()
        let hash = FrameHasher.hash(image)
        if hash == lastHash { return nil }
        lastHash = hash

        let lines = try OCREngine.recognize(image, customWords: customWords)
        return FrameInput(timestamp: Date().timeIntervalSince(startedAt), lines: lines)
    }

    /// 强制下一帧必须走完整 OCR（比如刚恢复播放时）
    public func invalidate() { lastHash = nil }

    public func waitForNextPoll() async throws {
        try await Task.sleep(for: interval)
    }

    /// 抓一帧原图，用于诊断/预览
    public func captureRawImage() async throws -> CGImage {
        try await capturer.capture()
    }
}
