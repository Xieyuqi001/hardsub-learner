import AppKit
import CoreGraphics

/// 一次框选的结果。rect 已经换算成 ScreenCaptureKit 能直接用的形式：
/// 相对该显示器、左上角原点、单位是「点」。
struct ScreenSelection {
    let rect: CGRect
    let displayID: CGDirectDisplayID
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 为什么框选要跑在**子进程**里
//
// 在 `@main async` 的命令行工具里，只要跑过 NSApplication 的事件循环
// （`NSApplication.nextEvent`），进程就会在几秒后**静默 exit(0)**：
// 后面的抓屏一帧都跑不到，退出码 0，没有任何报错。
//
// 实测（30 帧长跑，不是短测试）：
//   · 不跑事件循环  → 30/30 帧全活        ✅
//   · 跑事件循环    → 8–12 帧后必死       ❌
//   · 摘掉 activate / 摘掉拆窗 / 挂 delegate 拦 terminate → 都没用
//
// 结论：AppKit 的事件循环和 async main 的主队列驱动没法共存。
// 所以把框选丢给一个**短命子进程**（`--pick-only`），它跑完就把结果打到 stdout
// 然后自己退出；主进程从此再也不碰 AppKit。
//
// 注：正式版是正常的 .app + NSApplicationMain()，不会有这个问题。
// ─────────────────────────────────────────────────────────────────────────────

/// 全屏半透明遮罩，拖拽框选一块区域。
/// 不做任何预判——框到哪就是哪，判据完全交给用户。
@MainActor
final class RegionPicker {

    /// 阻塞式框选（**在子进程里**调用，见文件顶部说明）。返回 nil 表示用户按 Esc 取消。
    static func pick() -> ScreenSelection? {
        let picker = RegionPicker()   // 必须持有强引用，否则闭包回调时 self 已经没了
        return picker.run()
    }

    /// 在子进程里框选，把结果读回来。主进程用这个。
    /// childArgs 会透传给子进程（自测时用来让子进程自动出结果，不用人拖鼠标）。
    static func pickViaChildProcess(childArgs: [String] = []) -> ScreenSelection? {
        guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first.map({
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }) else {
            print("❌ 找不到自己的可执行文件路径，无法起框选子进程")
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["--pick-only"] + childArgs
        let pipe = Pipe()
        proc.standardOutput = pipe

        do {
            try proc.run()
        } catch {
            print("❌ 起不了框选子进程：\(error)")
            return nil
        }

        // 子进程先于我们退出，读干为止再 wait，避免管道写满卡住
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let out = String(decoding: data, as: UTF8.self)
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("RESULT ") }) else {
            return nil   // 用户 Esc 取消，或子进程异常
        }
        let fields = line.dropFirst("RESULT ".count).split(separator: ",").compactMap { Double($0) }
        guard fields.count == 5 else { return nil }
        return ScreenSelection(
            rect: CGRect(x: fields[0], y: fields[1], width: fields[2], height: fields[3]),
            displayID: CGDirectDisplayID(fields[4])
        )
    }

    /// 只验证遮罩能不能正常建起来、能不能反映真实屏幕，不做交互。
    /// 命令行工具里 NSScreen.screens 有可能是空的，所以值得单独验一下。
    static func selfTest() -> Bool {
        let picker = RegionPicker()
        picker.buildWindows()

        guard !picker.windows.isEmpty else {
            print("❌ 一个遮罩窗口都没建起来（NSScreen.screens 是空的？）")
            return false
        }

        print("✅ 建起了 \(picker.windows.count) 个遮罩窗口：")
        for (i, window) in picker.windows.enumerated() {
            print(String(format: "   #%d  frame = x=%.0f y=%.0f w=%.0f h=%.0f",
                         i + 1,
                         window.frame.origin.x, window.frame.origin.y,
                         window.frame.width, window.frame.height))
        }
        print("   屏幕数：\(NSScreen.screens.count)")

        picker.teardown()
        return true
    }

    /// 自动化测试：走完整的 run() 路径（建窗 → activate → 事件循环 → teardown），
    /// 但到点自动用给定矩形结束，不需要人拖鼠标。
    /// rect 直接用 SCK 坐标系（相对显示器、左上原点、点），原样返回。
    static func autoTest(rect: CGRect, displayID: CGDirectDisplayID,
                         after seconds: TimeInterval = 0.8) -> ScreenSelection? {
        let picker = RegionPicker()
        picker.autoFinish = (rect, displayID, seconds)
        return picker.run()
    }

    private var windows: [NSWindow] = []
    private var result: ScreenSelection?
    private var finished = false
    private var autoFinish: (rect: CGRect, displayID: CGDirectDisplayID, delay: TimeInterval)?

    // MARK: - 遮罩窗口

    private func buildWindows() {
        // 注意：命令行工具里 NSApp 是 nil，必须用 NSApplication.shared 触发懒创建
        NSApplication.shared.setActivationPolicy(.accessory)

        for screen in NSScreen.screens {
            let window = KeyableWindow(
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

            // 窗口 frame == 屏幕 frame，所以视图坐标就是「屏幕局部坐标」（左下原点）
            // NSScreen 和 displayID 都提前取成值类型：闭包可能在很久之后才触发，
            // 那时遍历出来的 screen 引用未必还成立。self 用强引用，teardown() 会断开环。
            let screenHeight = screen.frame.height
            let screenDisplayID = screen.displayID

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onComplete = { localRect in
                guard let rect = localRect, let screenDisplayID else {
                    self.finish(nil)
                    return
                }
                // 屏幕局部坐标（左下原点）→ SCK 坐标（左上原点）
                let sck = CGRect(
                    x: rect.minX,
                    y: screenHeight - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                self.finish(ScreenSelection(rect: sck, displayID: screenDisplayID))
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
    }

    /// 遮罩跑在子进程里（见文件顶部说明），子进程框完就 exit，
    /// 所以这里可以放心用最干净的方式拆窗。
    private func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func finish(_ selection: ScreenSelection?) {
        result = selection
        finished = true
    }

    // MARK: - 交互主循环

    private func run() -> ScreenSelection? {
        buildWindows()
        guard !windows.isEmpty else {
            print("❌ 无法创建遮罩窗口")
            return nil
        }

        // 让遮罩拿到键盘焦点（Esc 取消要靠它）。它跑在子进程里，不会有主进程那个坑。
        NSApplication.shared.activate(ignoringOtherApps: true)

        // 自动模式且 delay ≤ 0：完全不跑事件循环，直接出结果。
        // 专门用来二分「到底是事件循环坏事，还是别的地方坏事」。
        if let auto = autoFinish, auto.delay <= 0 {
            finish(ScreenSelection(rect: auto.rect, displayID: auto.displayID))
        } else {
            let started = Date()
            // 手写事件循环：不能调 NSApplication.shared.run()，否则回不来
            while !finished {
                // 自动模式：到点就用预置矩形结束，用来复现框选之后的路径
                if let auto = autoFinish, Date().timeIntervalSince(started) >= auto.delay {
                    finish(ScreenSelection(rect: auto.rect, displayID: auto.displayID))
                    break
                }
                guard let event = NSApplication.shared.nextEvent(
                    matching: .any,
                    until: Date(timeIntervalSinceNow: 0.05),
                    inMode: .default,
                    dequeue: true
                ) else { continue }
                NSApplication.shared.sendEvent(event)
            }
        }

        teardown()
        return result
    }
}

// MARK: - 遮罩视图

private final class SelectionView: NSView {
    /// 传 nil 表示取消
    var onComplete: ((CGRect?) -> Void)?

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
                .foregroundColor: NSColor.systemYellow
            ]
            let size = label.size(withAttributes: attrs)
            let origin = NSPoint(x: sel.minX, y: max(sel.minY - size.height - 6, 0))
            label.draw(at: origin, withAttributes: attrs)
        }

        drawHint()
    }

    private func drawHint() {
        let text = selectionRect == nil
            ? "拖拽框出字幕区域　　按 Esc 取消"
            : "松手即确认　　按 Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 60)
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
        if let rect = selectionRect {
            onComplete?(rect)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onComplete?(nil)
        }
    }
}

// MARK: - 无边框窗口默认不能成为 key window，需要子类打开

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
