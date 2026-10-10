import AppKit
import EnglishCapture
import EnglishCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = CaptureCoordinator()
    private let picker = RegionPicker()
    private let overlay = OverlayPanel()
    private var workbench: WorkbenchWindow?

    private var statusItem: NSStatusItem!
    private var selection: ScreenSelection?
    private var lastEntry: SubtitleEntry?
    private var statusText = "未开始"
    private var statusMenuItem: NSMenuItem?

    private static let selectionKey = "SavedSelection"

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
            self.statusText = text
            self.overlay.setStatus(text)
            self.rebuildMenu()
        }

        loadSavedSelection()
        rebuildMenu()

        if Self.demoOverlay { runOverlayDemo() }

        if let sel = Self.autoStart {
            selection = sel
            startCapture()
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
        lastEntry = nil
        overlay.clear()
        overlay.show()
        coordinator.start(selection: selection)
        rebuildMenu()
    }

    @objc private func stopCapture() {
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
