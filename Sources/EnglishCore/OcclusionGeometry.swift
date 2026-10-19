import CoreGraphics
import Foundation

// ⚠️ 这里 import CoreGraphics 是对「EnglishCore 不碰系统 API」那条规矩的一次**窄豁免**：
// 只用它的值类型（CGRect / CGPoint / CGSize 的 width、height、.zero 这些便利成员
// 定义在 CoreGraphics 里，Foundation 不带）。不碰任何屏幕、显示、绘制 API，
// 离线可跑的性质一点没丢——`swift run core-check` 就是证据。

// ─────────────────────────────────────────────────────────────────────────────
// 遮挡块的几何：拖动移动、拖四角缩放。
//
// **为什么这点算术要单独进内核层**：它是典型的手滑重灾区——
//   · 拖左边界时 origin.x 变、width 反向变，符号写反就会边拖边缩；
//   · 拖过对边会把矩形翻成负宽（画面上看起来是"块突然跳到另一边"）；
//   · clamp 的顺序写错会在贴边时跳一下。
// 这些东西放进 UI 里只能靠手点验，而手点**验不出**上面这三条边界。
// 做成纯函数就能拿 core-check 离线钉死（见 EnglishCoreCheck/main.swift）。
//
// 这一层不认识屏幕、不认识 AppKit，只做 CGRect 算术。
//
// ⚠️ **坐标系：AppKit 惯例，左下原点。**
// 所以 `.topLeft`（视觉左上角）动的是 `minX` 和 **`maxY`** 两条边，不是 minY。
// 全项目已经有三处坐标系要分（见 ScreenSelection 的注释），这是第四处，
// 所以这里指名道姓写清楚，并在 core-check 里有一条断言专门钉它。
// ─────────────────────────────────────────────────────────────────────────────

/// 用户拖的是哪个角。按**视觉位置**命名，不是按坐标轴。
public enum ResizeHandle: Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// 这个把手是否拖动较小那条 X 边（左边）
    public var movesMinX: Bool { self == .topLeft || self == .bottomLeft }
    /// 这个把手是否拖动较小那条 Y 边。
    /// **左下原点**下，视觉下方 = 数值更小的一边。
    public var movesMinY: Bool { self == .bottomLeft || self == .bottomRight }
}

public enum OcclusionGeometry {

    /// 再小就不成"块"了。和 `ScreenSelection.isUsable` 的 20×10 不同：
    /// 那个是抓取区域的下限，这个是**用户画出来的遮挡块**，得留出手抓的余地
    public static let minSize = CGSize(width: 40, height: 20)

    // MARK: - 移动

    /// 整体平移。**尺寸永远不变**，越界的部分被推回 `bounds` 内。
    ///
    /// 贴边时是"停住"而不是"挤扁"：这是拖动一个实心块的正确手感，
    /// 挤扁会让人以为块被压坏了。
    public static func move(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)

        // 先管左/下边，再管右/上边。两边都越界（块比屏幕还大）时后者说了算，
        // 于是至少保证右/上边在界内——总比把块推出屏幕外强。
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }

        return r
    }

    // MARK: - 缩放

    /// 拖某个角到 `point`：该角跟着走，**对角钉死不动**。
    ///
    /// 两条护栏：
    ///   · 拖过对边**不许翻转**，到 `minSize` 就停（翻转让块"跳"到另一侧，很难理解）；
    ///   · 移动的那两条边不许出 `bounds`。
    ///
    /// 前置条件：`rect` 已经在 `bounds` 内（由 `move` 保证）。`bounds` 比 `minSize`
    /// 还小时（理论上不会发生），以 `minSize` 优先——宁可出界，不可翻转。
    public static func resize(_ rect: CGRect,
                              handle: ResizeHandle,
                              to point: CGPoint,
                              within bounds: CGRect) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.movesMinX {
            minX = edge(point.x, isMin: true, opposite: maxX,
                        limits: bounds.minX...bounds.maxX, minSize: minSize.width)
        } else {
            maxX = edge(point.x, isMin: false, opposite: minX,
                        limits: bounds.minX...bounds.maxX, minSize: minSize.width)
        }

        if handle.movesMinY {
            minY = edge(point.y, isMin: true, opposite: maxY,
                        limits: bounds.minY...bounds.maxY, minSize: minSize.height)
        } else {
            maxY = edge(point.y, isMin: false, opposite: minY,
                        limits: bounds.minY...bounds.maxY, minSize: minSize.height)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 算一条边该落在哪。`isMin` = 移动的是较小那一条（minX / minY）。
    private static func edge(_ value: CGFloat, isMin: Bool, opposite: CGFloat,
                             limits: ClosedRange<CGFloat>, minSize: CGFloat) -> CGFloat {
        if isMin {
            // 上限取"对边 − 最小尺寸"和"屏幕内边界"里更严的那个
            let ceiling = min(opposite - minSize, limits.upperBound)
            return min(max(value, limits.lowerBound), ceiling)
        } else {
            let floor = max(opposite + minSize, limits.lowerBound)
            return max(min(value, limits.upperBound), floor)
        }
    }

    // MARK: - 校验

    /// 画出来的 / 从 UserDefaults 读回来的矩形值不值得用。
    /// 太小（多半是手抖点了一下）或者尺寸是负数（数据坏了）都不算数。
    ///
    /// ⚠️ **必须用 `.size.width`，不能用 `.width`。** 实测（core-check 里有断言钉着）：
    /// `CGRect(x: 0, y: 0, width: -400, height: 60)` 的 `.width` 返回 **400**（绝对值），
    /// 负号只藏在 `.size.width` 里，而 `minX/maxX` 却是按 −400 算的（−400 / 0）。
    /// 用 `.width` 判，翻转的矩形会被当成好数据放行——而它画到屏幕上是空的。
    public static func isUsable(_ rect: CGRect) -> Bool {
        rect.size.width >= minSize.width && rect.size.height >= minSize.height
    }

    /// 把一个可能落在已拔掉的显示器上的矩形，按原尺寸拉回给定屏幕内。
    /// 返回 nil 表示这块屏幕根本装不下它，调用方应当当作"没有遮挡块"处理。
    public static func fit(_ rect: CGRect, into bounds: CGRect) -> CGRect? {
        // 尺寸比较同样用 .size.*：翻转的矩形在这里就该被挡掉（见 isUsable 的注释）
        guard rect.size.width <= bounds.size.width,
              rect.size.height <= bounds.size.height else { return nil }
        return move(rect, by: .zero, within: bounds)
    }
}
