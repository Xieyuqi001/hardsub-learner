import AppKit
import CoreGraphics
import Foundation

/// 一次框选的结果。
///
/// `rect` 已经换算成 ScreenCaptureKit 能直接用的形式：
/// **相对该显示器、左上角为原点、单位是「点」**。
/// 注意和其它坐标系的三处差异，别混：
///   · NSScreen.frame —— 全局坐标、左下原点
///   · 视图内坐标     —— 左下原点
///   · SCK sourceRect —— 相对显示器、**左上**原点
public struct ScreenSelection: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var displayID: UInt32

    public init(rect: CGRect, displayID: CGDirectDisplayID) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
        self.displayID = displayID
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public var display: CGDirectDisplayID { displayID }

    /// 太小了必然框错了（下界取 20×10 点，正常字幕带远大于此）
    public var isUsable: Bool { width >= 20 && height >= 10 }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
