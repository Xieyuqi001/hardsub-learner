import AppKit
import EnglishCore

/// 遮挡字幕的黑块。
///
/// 职责只有一件：在屏幕上糊一块纯黑，挡住烧在画面里的字幕。它**不参与采集链路的
/// 任何一环**——抓屏、OCR、成句、落盘一行都不碰。
///
/// 窗口属性照抄 `OverlayPanel` 里那套「少一个就看不到」的组合：
///   · `.nonactivatingPanel` —— 点它不抢走播放器的焦点
///   · `level = .floating`   —— 否则被视频窗口盖住
///   · `[.canJoinAllSpaces, .fullScreenAuxiliary]` —— 否则全屏看剧时它留在另一个 Space 上
///   · `isOpaque` + 纯黑      —— 半透明会漏出字幕笔画，等于没挡
///
/// ⚠️ **这块黑为什么不会把自己的抓屏也糊掉，不是这个文件的责任。**
/// 守住它的是 `ScreenCapturer` 里的 `SCContentFilter(excludingApplications:)`
/// ——它按**应用**排除，黑块和悬浮窗一起被排掉，底下的字幕原样抓得到。
/// 这条性质由 `--selftest-block` 的四步对照实验实测钉住（见 BlockSelfTest.swift）。
///
/// 两种状态：
///   · **平时**：鼠标完全穿透（`ignoresMouseEvents = true`），绝不干扰操作播放器
///   · **调整模式**：描边 + 四角把手浮出来，可拖动移动、拖角缩放；退出即恢复穿透
@MainActor
final class OcclusionPanel: NSObject {

    private let panel: NSPanel
    private let content = BlockContentView()
    private var adjusting = false

    /// 用户挪动过黑块。调用方负责存盘。
    var onFrameChanged: ((NSRect) -> Void)?
    /// 用户在调整模式里按了 Esc / 双击。调用方负责改菜单状态。
    var onAdjustingFinished: (() -> Void)?

    /// 有没有"画过"一块。没画过时菜单点一下应当先让用户去画。
    private(set) var isPlaced = false

    override init() {
        // 先给个占位尺寸；真正的 frame 由 setFrame 设。零尺寸的窗口 AppKit 建不出来。
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true          // 平时穿透；只有调整模式才收回事件

        content.adjusting = false
        content.onDragBegan = { [weak self] in
            self?.dragStartFrame = self?.panel.frame ?? .zero
        }
        content.onDragMoved = { [weak self] delta in
            guard let self, let screen = self.boundsScreen else { return }
            self.panel.setFrame(
                OcclusionGeometry.move(self.dragStartFrame, by: delta, within: screen.frame),
                display: true
            )
        }
        content.onResizeMoved = { [weak self] handle, point in
            guard let self, let screen = self.boundsScreen else { return }
            self.panel.setFrame(
                OcclusionGeometry.resize(self.dragStartFrame, handle: handle,
                                         to: point, within: screen.frame),
                display: true
            )
        }
        content.onDragEnded = { [weak self] in
            guard let self else { return }
            self.onFrameChanged?(self.panel.frame)
        }
        content.onFinish = { [weak self] in
            self?.onAdjustingFinished?()
        }
        panel.contentView = content
    }

    // MARK: - 对外

    func show() { panel.orderFrontRegardless() }
    func hide() {
        setAdjusting(false)
        panel.orderOut(nil)
    }
    var isVisible: Bool { panel.isVisible }

    /// 窗口在 AppKit 全局坐标（**左下原点**）里的位置。
    /// 和 `OverlayPanel.screenFrame` 一样，只作坐标换算用，别在别处依赖。
    var frame: NSRect { panel.frame }

    /// 摆到指定位置。会先按原尺寸 clamp 进所在的屏幕。
    ///
    /// 装不下（比屏幕还大）或尺寸不可用时**当没画过**——调用方据此决定菜单文案。
    /// 这条对「从 UserDefaults 读回来的旧位置 + 换了显示器」是必须的：
    /// 与其把块搁在看不见的地方，不如让用户重画一块。
    func setFrame(_ rect: NSRect) {
        guard OcclusionGeometry.isUsable(rect),
              let screen = Self.screen(containing: rect),
              let fitted = OcclusionGeometry.fit(rect, into: screen.frame) else { return }
        panel.setFrame(fitted, display: true)
        isPlaced = true
    }

    /// 进/出调整模式。进出都要让 AppDelegate 知道，所以外面通过
    /// `onAdjustingFinished` 回调收尾，而不是直接改这个 bool。
    func setAdjusting(_ on: Bool) {
        guard on != adjusting else { return }
        adjusting = on
        panel.ignoresMouseEvents = !on          // 关键：平时穿透，调整时收回
        content.adjusting = on
        content.needsDisplay = true
        panel.invalidateCursorRects(for: content)

        if on {
            // 为了收 Esc。`.nonactivatingPanel` 拿到 key **不会**激活本 App，
            // 但播放器会暂时失去键盘焦点——所以调整模式必须一眼看得出来，
            // 且开始/停止采集时强制退出（见 AppDelegate）。
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(content)
        } else {
            panel.resignKey()
            panel.orderFrontRegardless()        // 退出调整后仍然要visible
        }
    }

    var isAdjusting: Bool { adjusting }

    // MARK: - 内部

    /// 拖动开始时的 frame。位移和缩放都相对它算，避免逐帧累加误差。
    private var dragStartFrame: NSRect = .zero

    /// 黑块现在压在哪块屏幕上。用它当 clamp 的边界。
    ///
    /// v1 不支持一个块跨两块屏：拖动时边界跟着块所在的屏走，
    /// 想挪到另一块屏就重新画一块（见计划的「这个版本不做」）。
    private var boundsScreen: NSScreen? { Self.screen(containing: panel.frame) }

    /// 一个矩形主要落在哪块屏幕上。先看中心点，中心点谁都不在（跨屏 / 在缝里）
    /// 就退而求其次看相交，最后兜底主屏。
    private static func screen(containing rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.main
    }
}

// MARK: - 黑色内容视图

/// 一整块黑，加上调整模式下的描边和四角把手。
///
/// 拖动/缩放的**数学全在 `OcclusionGeometry` 里**（EnglishCore，core-check 离线钉过），
/// 这里只负责把鼠标事件翻译成调用。别把几何搬进这个文件——搬进来就只能手点验了。
private final class BlockContentView: NSView {

    var adjusting = false

    // 这几个闭包都标 @MainActor：它们要改 OcclusionPanel 上的状态，
    // 而 Swift 6 严格并发下，一个普通 `() -> Void` 闭包**不会**从上下文继承隔离。
    var onDragBegan: (@MainActor () -> Void)?
    /// 位移，相对按下那一点（屏幕坐标）
    var onDragMoved: (@MainActor (CGSize) -> Void)?
    /// 拖的是哪个角 + 鼠标当前在哪（屏幕坐标）
    var onResizeMoved: (@MainActor (ResizeHandle, CGPoint) -> Void)?
    var onDragEnded: (@MainActor () -> Void)?
    var onFinish: (@MainActor () -> Void)?

    /// 角上多大一块算"抓到把手了"。比画出来的方块大一圈，好抓。
    private let handleSize: CGFloat = 14
    private let handleHitSlop: CGFloat = 6

    private var activeHandle: ResizeHandle?
    private var dragStartMouse = NSPoint.zero
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard adjusting else { return }         // 平时：一块纯黑，什么都不画

        let ring = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        NSColor.systemYellow.setStroke()
        ring.stroke()

        NSColor.systemYellow.setFill()
        for handle in ResizeHandle.allCases {
            handleRect(for: handle).fill()
        }
    }

    override func resetCursorRects() {
        guard adjusting else { return }
        for handle in ResizeHandle.allCases {
            addCursorRect(handleRect(for: handle), cursor: .crosshair)
        }
        addCursorRect(bounds, cursor: .openHand)
    }

    private func handleRect(for handle: ResizeHandle) -> NSRect {
        let x = handle.movesMinX ? bounds.minX + 1 : bounds.maxX - handleSize - 1
        let y = handle.movesMinY ? bounds.minY + 1 : bounds.maxY - handleSize - 1
        return NSRect(x: x, y: y, width: handleSize, height: handleSize)
    }

    private func handle(at point: NSPoint) -> ResizeHandle? {
        ResizeHandle.allCases.first {
            handleRect(for: $0).insetBy(dx: -handleHitSlop, dy: -handleHitSlop).contains(point)
        }
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        guard adjusting else { return }
        if event.clickCount == 2 { onFinish?(); return }   // 双击 = 完成，不用去点菜单

        activeHandle = handle(at: convert(event.locationInWindow, from: nil))
        dragStartMouse = NSEvent.mouseLocation         // 屏幕坐标：窗口在动，窗口内坐标不可靠
        dragging = true
        NSCursor.closedHand.set()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard adjusting, dragging else { return }
        let now = NSEvent.mouseLocation
        if let handle = activeHandle {
            onResizeMoved?(handle, now)
        } else {
            onDragMoved?(CGSize(width: now.x - dragStartMouse.x,
                                height: now.y - dragStartMouse.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        activeHandle = nil
        NSCursor.openHand.set()
        onDragEnded?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?() }          // Esc
    }
}
