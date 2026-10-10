import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case noPermission

    public var description: String {
        switch self {
        case .noDisplay: "找不到对应显示器（外接屏拔了？）"
        case .noPermission: "没有屏幕录制权限"
        }
    }
}

/// 抓屏。围绕一次固定的框选区域构建，可以反复抓。
///
/// 用**定时轮询 `SCScreenshotManager.captureImage`**，不用 `SCStream`：
/// 字幕区域长期静止，低频轮询比常驻流省电得多；而且 `SCStream` 有
/// "暂停时仍持续发帧"的毛病，那些帧全是重复的，白烧 OCR。
///
/// `@unchecked Sendable`：内部持有的 `SCContentFilter` / `SCStreamConfiguration`
/// 不是 Sendable，但本类型**只被单一采集任务串行使用**，不并发访问。
public final class ScreenCapturer: @unchecked Sendable {

    public let geometry: Geometry

    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    public struct Geometry: Sendable {
        public let selection: ScreenSelection
        /// 真实像素 / 点。Retina 上通常是 2.0
        public let scale: CGFloat
        public let outputWidth: Int
        public let outputHeight: Int
    }

    public init(selection: ScreenSelection, excludeOwnApp: Bool = true) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // 关键：把本 App 自己排除掉。
        // SCK 抓的是合成后的帧缓冲；不排除自己的话，将来悬浮窗上的文字会被
        // 自己 OCR 一遍再喂回字幕稿，形成自我污染。macOS 15+ 里
        // `sharingType = .none` 已经失效，只剩下这个办法。
        let ownApps = excludeOwnApp
            ? content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            : []

        self.filter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )

        let scale = Self.realScale(of: display)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = selection.rect
        cfg.width = max(1, Int((selection.width * scale).rounded()))
        cfg.height = max(1, Int((selection.height * scale).rounded()))
        cfg.showsCursor = false
        cfg.captureResolution = .best
        self.config = cfg

        self.geometry = Geometry(
            selection: selection,
            scale: scale,
            outputWidth: cfg.width,
            outputHeight: cfg.height
        )
    }

    public func capture() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 显示器的**真实像素**宽度 ÷ 点宽度。
    ///
    /// 坑：`CGDisplayPixelsWide()` 在缩放显示模式下返回的是**点**不是像素，
    /// 用它算出来永远是 1.0，会把 Retina 画面白白降采样一半，OCR 精度打折。
    /// 必须走 `CGDisplayCopyDisplayMode`。
    static func realScale(of display: SCDisplay) -> CGFloat {
        let pointWidth = CGFloat(display.width)
        guard pointWidth > 0 else { return 1 }
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.pixelWidth > 0 {
            return CGFloat(mode.pixelWidth) / pointWidth
        }
        return 1
    }
}

// MARK: - 变化检测

/// 帧指纹。用来跳过"画面根本没变"的帧，省掉那次 OCR。
public enum FrameHasher {

    /// 降采样到很窄的灰度图，再把每个像素量化到 16 级，最后 FNV-1a。
    ///
    /// 量化是必要的：视频有压缩噪点，不量化的话每一帧的原始像素都不同，
    /// 指纹永远在变，这个优化就完全失效。量化到 16 级能吃掉绝大部分压缩噪声，
    /// 而字幕文字的变化（笔画有无）仍然会显著改变像素。
    public static func hash(_ image: CGImage, width: Int = 64) -> UInt64 {
        let aspect = Double(image.height) / Double(max(1, image.width))
        let w = max(1, width)
        let hgt = max(1, Int((Double(w) * aspect).rounded()))

        var pixels = [UInt8](repeating: 0, count: w * hgt)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: hgt,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }

        ctx.interpolationQuality = CGInterpolationQuality.medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: hgt))

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a offset basis
        for px in pixels {
            hash ^= UInt64(px >> 4)                // 量化到 16 级
            hash = hash &* 0x0000_0100_0000_01B3   // FNV prime
        }
        return hash
    }
}
