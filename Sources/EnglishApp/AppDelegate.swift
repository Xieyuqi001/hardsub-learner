import AppKit
import EnglishCapture
import EnglishCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = CaptureCoordinator()
    private let picker = RegionPicker()
    private let overlay = OverlayPanel()
    private let occlusion = OcclusionPanel()
    private var workbench: WorkbenchWindow?

    private var statusItem: NSStatusItem!
    private var selection: ScreenSelection?
    private var lastEntry: SubtitleEntry?
    private var statusText = "未开始"
    private var statusMenuItem: NSMenuItem?

    private static let selectionKey = "SavedSelection"
    private static let occlusionRectKey = "OcclusionRect"
    private static let occlusionOnKey = "OcclusionOn"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯命令行的落盘自检：在建菜单栏图标之前就退掉，什么都不碰
        if Self.selfTestStore {
            exit(StoreSelfTest.run())
        }

        // 菜单栏 App：不要 Dock 图标、不要主窗口
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "captions.bubble",
            accessibilityDescription: "硬字幕学习工具"
        )
        statusItem.button?.image?.isTemplate = true

        coordinator.onEntry = { [weak self] entry in
            guard let self else { return }
            self.lastEntry = entry
            self.overlay.append(entry)
            self.rebuildMenu()
        }
        coordinator.onStatus = { [weak self] text in
            guard let self else { return }
            // 无头诊断模式下也打到 stdout，否则状态只在悬浮窗上，脚本看不见
            if Self.autoStop != nil { print("▸ 状态：\(text)") }
            self.statusText = text
            self.overlay.setStatus(text)
            self.rebuildMenu()
        }

        // 黑块挪过位置就存盘；调整模式结束（Esc / 双击 / 菜单）也存一次——
        // 拖动过程中会连续触发，但那只是一次 UserDefaults 写入，不值得做节流
        occlusion.onFrameChanged = { [weak self] rect in
            self?.saveOcclusionRect(rect)
        }
        occlusion.onAdjustingFinished = { [weak self] in
            guard let self else { return }
            self.occlusion.setAdjusting(false)
            self.saveOcclusionRect(self.occlusion.frame)
            self.statusText = "遮挡块已锁定"
            self.rebuildMenu()
        }

        loadSavedSelection()
        loadSavedOcclusion()
        rebuildMenu()

        if Self.demoOverlay { runOverlayDemo() }

        if let sel = Self.autoStart {
            selection = sel
            startCapture()
        }

        if let secs = Self.autoStop {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(secs))
                print("▸ auto-stop：到点，调 stopCapture()（与 ⌘S 同一个方法）")
                self.stopCapture()
                // 等采集任务收尾完再退，否则会把收尾截断、看不到最终状态
                for _ in 0..<50 where self.coordinator.isRunning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                print("▸ auto-stop：收尾完成，isRunning=\(self.coordinator.isRunning)")
                NSApp.terminate(nil)
            }
        }

        if CommandLine.arguments.contains("--workbench") { openWorkbench() }

        if let req = Self.exportRequest {
            // 纯命令行用法：跑完就退，不弹任何界面
            runExport(req)
            NSApp.terminate(nil)
            return
        }

        if Self.selfTest {
            // 窗口得先合成到屏幕上，自检才有意义。交给 run loop 跑，不能在这里同步做。
            Task { @MainActor in
                let code = await SelfTest.run(overlay: overlay)
                NSApp.terminate(nil)          // 退出码这里给不了，看 stdout
                _ = code
            }
        }

        if Self.selfTestBlock {
            Task { @MainActor in
                let code = await BlockSelfTest.run(overlay: overlay, occlusion: occlusion)
                print("▸ 退出码：\(code)（0 = 通过）")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    // MARK: - 菜单

    /// NSMenuItem 没有带 target 的便利构造器，只能建完再挂
    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = disabled(statusText)
        menu.addItem(status)
        statusMenuItem = status

        if let s = selection {
            menu.addItem(disabled(String(format: "字幕区域：%.0f, %.0f · %.0f×%.0f",
                                         s.x, s.y, s.width, s.height)))
        }

        menu.addItem(.separator())

        let pick = item(picker.isActive ? "框选中…" : "框选字幕区域…", #selector(pickRegion), "r")
        pick.isEnabled = !picker.isActive
        menu.addItem(pick)

        if coordinator.isRunning {
            menu.addItem(item("停止采集", #selector(stopCapture), "s"))
        } else {
            let start = item("开始采集", #selector(startCapture), "s")
            start.isEnabled = selection != nil
            menu.addItem(start)
        }

        menu.addItem(.separator())

        if let e = lastEntry {
            menu.addItem(disabled("中  \(e.chinese)"))
            menu.addItem(disabled("英  \(e.english)"))
        } else {
            menu.addItem(disabled("（还没有识别到字幕）"))
        }

        menu.addItem(.separator())

        menu.addItem(item(overlay.isVisible ? "隐藏悬浮窗" : "显示悬浮窗",
                          #selector(toggleOverlay), "o"))
        let through = item("悬浮窗点击穿透", #selector(toggleClickThrough))
        through.state = overlay.isClickThrough ? .on : .off
        menu.addItem(through)

        menu.addItem(.separator())

        let occlude = item("遮挡字幕", #selector(toggleOcclusion), "b")
        occlude.state = occlusion.isVisible ? .on : .off
        menu.addItem(occlude)

        let adjust = item(occlusion.isAdjusting ? "完成调整遮挡块" : "调整遮挡块…",
                          #selector(toggleAdjustOcclusion))
        adjust.isEnabled = occlusion.isPlaced && occlusion.isVisible
        menu.addItem(adjust)

        // 重画独立成一项：块画歪了或换了片源，重画比拖着挪快。
        // 没画过时置灰——那时候点「遮挡字幕」本身就是进入绘制，不必两个入口
        let redraw = item("重新画遮挡块…", #selector(drawOcclusion))
        redraw.isEnabled = occlusion.isPlaced
        menu.addItem(redraw)

        menu.addItem(.separator())
        menu.addItem(item("打开工作台…", #selector(openWorkbench), "w"))
        menu.addItem(item("打开会话文件夹", #selector(openSessionsFolder)))
        menu.addItem(item("退出", #selector(NSApplication.terminate(_:)), "q"))

        statusItem.menu = menu
    }

    // MARK: - 动作

    @objc private func pickRegion() {
        guard !picker.isActive else { return }
        // 框选期间把采集停掉，免得遮罩自己被抓进去
        if coordinator.isRunning { coordinator.stop() }

        picker.begin { [weak self] result in
            guard let self else { return }
            if let result {
                self.selection = result
                self.saveSelection(result)
                self.statusText = "已框选，可以开始采集"
            } else {
                self.statusText = "已取消框选"
            }
            self.rebuildMenu()
        }
    }

    @objc private func startCapture() {
        guard let selection else { return }
        guard CGPreflightScreenCaptureAccess() else {
            statusText = "正在申请屏幕录制权限…"
            rebuildMenu()
            // 系统只会在第一次弹窗；之后需要用户自己去系统设置里勾。
            // 这个调用会阻塞到用户答复为止，返回值就是答复。
            let granted = CGRequestScreenCaptureAccess()
            statusText = granted
                // 授权了也**不能**接着跑：macOS 要求进程重启后新权限才生效。
                // 不说清楚的话，用户点了授权、画面却什么都没发生，会以为工具坏了。
                ? "已授权 → 请退出 App 再重开（macOS 要求）"
                : "没拿到权限 → 系统设置 › 隐私与安全性 › 屏幕录制"
            rebuildMenu()
            return
        }
        // 调整模式会吃掉鼠标事件（点播放器没反应）。开始看剧之前必须让它退出去，
        // 否则用户会以为播放器坏了——而屏幕上只有一圈黄边在提示
        occlusion.setAdjusting(false)
        lastEntry = nil
        overlay.clear()
        overlay.show()
        coordinator.start(selection: selection)
        rebuildMenu()
    }

    @objc private func stopCapture() {
        occlusion.setAdjusting(false)
        coordinator.stop()
    }

    @objc private func toggleOverlay() {
        if overlay.isVisible { overlay.hide() } else { overlay.show() }
        rebuildMenu()
    }

    @objc private func toggleClickThrough() {
        overlay.setClickThrough(!overlay.isClickThrough)
        rebuildMenu()
    }

    // MARK: - 遮挡字幕

    /// 一键开关。**没画过的时候这一下是"去画"**——这是唯一的绘制入口，
    /// 因为用户第一次点它的时候，能做的只能是画一块出来。
    @objc private func toggleOcclusion() {
        if occlusion.isVisible {
            occlusion.hide()
            saveOcclusionOn(false)
            statusText = "遮挡已取消"
        } else if occlusion.isPlaced {
            occlusion.show()
            saveOcclusionOn(true)
            statusText = "遮挡已打开"
        } else {
            statusText = "拖出一块要遮挡的字幕范围"
            drawOcclusion()
            return                      // 回调里会 rebuildMenu
        }
        rebuildMenu()
    }

    @objc private func drawOcclusion() {
        guard !picker.isActive else { return }
        occlusion.setAdjusting(false)   // 描边和把手别混进遮罩里

        // 和「框选字幕区域」共用同一套交互：全屏压暗 + 拖拽 + Esc 取消
        picker.begin(hint: "拖拽画出要遮挡的字幕范围") { [weak self] result in
            guard let self else { return }
            guard let result, let rect = Self.appKitRect(from: result),
                  OcclusionGeometry.isUsable(rect) else {
                self.statusText = "已取消画遮挡块"
                self.rebuildMenu()
                return
            }
            self.occlusion.setFrame(rect)
            self.occlusion.show()
            self.saveOcclusionOn(true)
            self.statusText = "遮挡块已就位，可点「调整遮挡块…」挪位置"
            self.rebuildMenu()
        }
    }

    @objc private func toggleAdjustOcclusion() {
        occlusion.setAdjusting(!occlusion.isAdjusting)
        statusText = occlusion.isAdjusting
            ? "拖动黑块挪位置，拖四个角缩放；按 Esc 或双击完成"
            : "遮挡块已锁定"
        rebuildMenu()
    }

    /// 框选结果是 SCK 坐标（**相对显示器、左上原点**），黑块窗口要的是
    /// AppKit 全局坐标（**左下原点**）。全项目第四处坐标系换算，别省这一步。
    private static func appKitRect(from selection: ScreenSelection) -> NSRect? {
        let screen = NSScreen.screens.first { $0.displayID == selection.displayID }
            ?? NSScreen.main
        guard let screen else { return nil }
        let f = screen.frame
        let r = selection.rect
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY,
                      width: r.width, height: r.height)
    }

    private func saveOcclusionRect(_ rect: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: Self.occlusionRectKey)
    }

    private func saveOcclusionOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.occlusionOnKey)
    }

    private func loadSavedOcclusion() {
        guard let s = UserDefaults.standard.string(forKey: Self.occlusionRectKey) else { return }
        occlusion.setFrame(NSRectFromString(s))
        // setFrame 装不下就什么都不做；这时候 isPlaced 仍是 false，
        // 菜单会把「遮挡字幕」当成"还没画过"，引导用户重画一块而不是静默失灵
        guard occlusion.isPlaced else { return }
        if UserDefaults.standard.bool(forKey: Self.occlusionOnKey) {
            occlusion.show()
        }
    }

    @objc private func openSessionsFolder() {
        NSWorkspace.shared.open(coordinator.sessionStore.root)
    }

    @objc private func openWorkbench() {
        // 懒建：没点过就不占内存，也不提前拉 WKWebView 那套进程
        if workbench == nil {
            workbench = WorkbenchWindow(store: coordinator.sessionStore)
        }
        workbench?.show()
    }

    // MARK: - 命令行导出

    /// `English --export <会话id|all> [md|txt]`
    /// 不开界面直接导出，跑完打印结果并退出。验导出格式用，也方便批量导出。
    static var exportRequest: (id: String, format: Exporter.Format)? {
        guard let i = CommandLine.arguments.firstIndex(of: "--export"),
              CommandLine.arguments.count > i + 1 else { return nil }
        let id = CommandLine.arguments[i + 1]
        let fmt = CommandLine.arguments.count > i + 2
            ? Exporter.Format(rawValue: CommandLine.arguments[i + 2]) ?? .markdown
            : .markdown
        return (id, fmt)
    }

    private func runExport(_ req: (id: String, format: Exporter.Format)) {
        let store = coordinator.sessionStore
        let ids = req.id == "all" ? store.listSessions().map(\.id) : [req.id]

        guard !ids.isEmpty else {
            print("没有会话可导出。")
            return
        }
        for id in ids {
            let r = Exporter.write(sessionID: id, format: req.format, store: store)
            if r.ok {
                print("✓ \(id) → \(r.sentenceCount) 句 · \(r.characterCount) 字\n  \(r.path)")
            } else {
                print("✗ \(id)：\(r.error)")
            }
        }
    }

    // MARK: - 演示模式

    /// `English --demo-overlay`：不开视频、不要权限，直接把悬浮窗摆满假数据。
    /// 调排版/配色时不用真的去放一集剧。正常启动完全不受影响。
    static let demoOverlay = CommandLine.arguments.contains("--demo-overlay")

    /// `English --selftest-capture`：验自排除（见 SelfTest.swift）
    static let selfTest = CommandLine.arguments.contains("--selftest-capture")

    /// `English --selftest-store`：验改名与收藏的落盘（见 StoreSelfTest.swift）
    static let selfTestStore = CommandLine.arguments.contains("--selftest-store")

    /// `English --selftest-block`：验遮挡黑块只挡眼睛、不挡抓屏（见 BlockSelfTest.swift）
    static let selfTestBlock = CommandLine.arguments.contains("--selftest-block")

    /// `English --auto-start x y w h`：跳过框选，直接拿这个区域开始采集。
    /// 诊断用——不用手点菜单就能跑通「采集→成句→落盘」整条链路。
    static var autoStart: ScreenSelection? {
        guard let i = CommandLine.arguments.firstIndex(of: "--auto-start"),
              CommandLine.arguments.count > i + 4,
              let x = Double(CommandLine.arguments[i + 1]),
              let y = Double(CommandLine.arguments[i + 2]),
              let w = Double(CommandLine.arguments[i + 3]),
              let h = Double(CommandLine.arguments[i + 4]) else { return nil }
        return ScreenSelection(rect: CGRect(x: x, y: y, width: w, height: h),
                               displayID: CGMainDisplayID())
    }

    /// `English --auto-stop <秒>`：配合 `--auto-start` 用，N 秒后自动停止采集并退出。
    ///
    /// 调的是**和 ⌘S 完全同一个** `stopCapture()`，所以走的是同一条取消路径。
    /// 存在的理由：停止采集这条路以前没有任何无头跑法，只能手点菜单，
    /// 于是「点停止就报采集出错、还丢最后一句」这个 bug 一直没人测到。
    static var autoStop: Double? {
        guard let i = CommandLine.arguments.firstIndex(of: "--auto-stop"),
              CommandLine.arguments.count > i + 1 else { return nil }
        return Double(CommandLine.arguments[i + 1])
    }

    private func runOverlayDemo() {
        let samples: [(String, String)] = [
            ("你最近见过他吗？", "Have you seen him lately?"),
            ("老实说，我不太确定。", "To be honest, I'm not sure."),
            ("天啊……你不是认真的吧？", "Oh my God... you can't be serious."),
            ("谢谢夸奖，我只是运气好。", "Thanks for the compliment, I just got lucky."),
            ("如果我是你，我会再想想。", "If I were you, I'd think twice."),
            ("别担心，一切都会好起来的。", "Don't worry, everything's going to be fine."),
        ]
        for (i, s) in samples.enumerated() {
            overlay.append(SubtitleEntry(
                index: i + 1,
                start: Double(i) * 3,
                end: Double(i) * 3 + 2.4,
                chinese: s.0,
                english: s.1,
                frameCount: 4,
                isFlash: false
            ))
        }
        overlay.setStatus("演示模式 · 未采集")
        overlay.show()
    }

    // MARK: - 框选结果持久化

    private func saveSelection(_ s: ScreenSelection) {
        if let data = try? JSONEncoder.session.encode(s) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
    }

    private func loadSavedSelection() {
        guard let data = UserDefaults.standard.data(forKey: Self.selectionKey),
              let s = try? JSONDecoder.session.decode(ScreenSelection.self, from: data) else {
            return
        }
        selection = s
        statusText = "已恢复上次的字幕区域"
    }
}
