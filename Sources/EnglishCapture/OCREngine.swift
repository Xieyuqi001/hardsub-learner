import CoreGraphics
import EnglishCore
import Foundation
import Vision

/// Apple Vision 的 OCR 封装。
///
/// 参数是从 spike 实测里定下来的，改之前先看注释：
///   · `.accurate` 是**必须**的 —— `.fast` 完全不支持中文（识别结果为空）
///   · `zh-Hans` 必须排在 `en-US` 前面 —— English 是唯一能与中文配对的语言，
///     顺序反了识别质量会掉
public enum OCREngine {

    public static let recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    /// 识别一帧。返回的行已按 y 升序排好（从上到下）。
    public static func recognize(_ image: CGImage,
                                 customWords: [String] = []) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = true
        if !customWords.isEmpty {
            request.customWords = customWords
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        return observations
            .compactMap { obs -> OCRLine? in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox   // 归一化，**左下**原点
                return OCRLine(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    x: box.origin.x,
                    // 翻成左上原点，并取行的**顶端**（后续配对比较的是行顶端）
                    y: 1 - box.origin.y - box.height
                )
            }
            .sorted { $0.y < $1.y }
    }
}
