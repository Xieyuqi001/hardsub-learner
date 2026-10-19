import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// 框选：全屏压暗遮罩，拖拽框出字幕区域。判据完全交给用户，不做任何预判。
//
// ⚠️ 和 spike 里的版本有个关键差别：**这里是 AppKit 应用，不是命令行工具。**
//
// spike 曾经因为"跑过 NSApplication 事件循环之后进程静默 exit(0)"，
// 不得不把框选丢进一个短命子进程（`--pick-only`）。那个坑的根因是
// `@main async` 的主队列驱动和 AppKit 事件循环打架——**只有裸命令行工具才有**。
//
// 正式版是正常 .app，`NSApplication.run()` 本来就在跑，事件循环一直都在，
// 所以这里直接建窗口、等回调即可，不需要手写事件循环，也不需要子进程。
// 那条子进程脚手架到这里正式退役。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
public final class RegionPicker {

    public init() {}

    /// 弹出遮罩开始框选。用户拖完（或按 Esc 取消）后回调。
    /// 回调一定在主线程上。
    ///
    /// `hint` 是顶部那行提示语。遮挡块也走这套交互（画一块黑），
    /// 但"框出字幕区域"这句话对它不成立，所以要能换。
    public func begin(hint: String = "拖拽框出字幕区域",
                      completion: @escaping (ScreenSelection?) -> Void) {
        self.completion = completion
        self.hint = hint
        buildWindows()
        guard !windows.isEmpty else {
            finish(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    public var isActive: Bool { !windows.isEmpty }

    private var windows: [NSWindow] = []
    private var completion: ((ScreenSelection?) -> Void)?
    private var hint = "拖拽框出字幕区域"

    private func buildWindows() {
        for screen in NSScreen.screens {
            let window = PickerWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = false

            // 窗口 frame == 屏幕 frame，所以视图坐标就是「屏幕局部坐标」（左下原点）。
            // NSScreen 和 displayID 提前取成值类型：回调可能很晚才触发。
            let screenHeight = screen.frame.height
            let screenDisplayID = screen.displayID

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.hint = hint
            view.onComplete = { [weak self] localRect in
                guard let self else { return }
                guard let rect = localRect, let screenDisplayID else {
                    self.finish(nil)
                    return
                }
                // 屏幕局部坐标（左下原点）→ SCK 坐标（相对显示器、左上原点）
                let sck = CGRect(
                    x: rect.minX,
                    y: screenHeight - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                let selection = ScreenSelection(rect: sck, displayID: screenDisplayID)
                self.finish(selection.isUsable ? selection : nil)
            }
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
        }
    }

    private func finish(_ selection: ScreenSelection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let c = completion
        completion = nil
        c?(selection)
    }
}

// MARK: - 遮罩视图

private final class SelectionView: NSView {
    /// 传 nil 表示取消
    var onComplete: ((CGRect?) -> Void)?
    /// 拖出选区前显示的那行提示
    var hint = "拖拽框出字幕区域"

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    private var selectionRect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                       width: abs(c.x - s.x), height: abs(c.y - s.y))
        return r.width > 4 && r.height > 4 ? r : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // 整块压暗，只在选区处挖空（even-odd 填充）
        let mask = NSBezierPath(rect: bounds)
        if let sel = selectionRect {
            mask.append(NSBezierPath(rect: sel))
        }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        mask.fill()

        if let sel = selectionRect {
            let border = NSBezierPath(rect: sel)
            border.lineWidth = 2
            NSColor.systemYellow.setStroke()
            border.stroke()

            let label = "\(Int(sel.width)) × \(Int(sel.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.systemYellow,
            ]
            let size = label.size(withAttributes: attrs)
            let origin = NSPoint(x: sel.minX, y: max(sel.minY - size.height - 6, 0))
            label.draw(at: origin, withAttributes: attrs)
        }

        drawHint()
    }

    private func drawHint() {
        let text = selectionRect == nil
            ? "\(hint)　　按 Esc 取消"
            : "松手即确认　　按 Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2,
                             y: bounds.height - size.height - 60)
        text.draw(at: origin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        if let rect = selectionRect { onComplete?(rect) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }   // Esc
    }
}

/// 无边框窗口默认不能成为 key window，需要子类打开
private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
