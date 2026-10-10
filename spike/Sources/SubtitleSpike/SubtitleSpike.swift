import Foundation
import Darwin
import ScreenCaptureKit
import Vision
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// 技术验证 spike
//
// 验证：ScreenCaptureKit 抓「你框出来的那块区域」+ Apple Vision 识别中英混排，
//       能不能跑通、多快、能不能拿到用于分行的坐标。
//
// 设计原则：**不预判**。框到哪就抓哪，抓到什么都原样列出来。
// 没有"底部 28%"这种写死的区域，也没有"这条算不算字幕"的过滤规则。
//
// 用法：
//   swift run SubtitleSpike                    # 全屏遮罩，拖拽框选；然后一直跑，Ctrl-C 停
//   swift run SubtitleSpike --full             # 抓整个屏幕，不框选
//   swift run SubtitleSpike --frames 6         # 只跑 6 帧就结束
//   swift run SubtitleSpike --interval 300     # 每帧间隔 300ms（默认 400）
//   swift run SubtitleSpike --rect 112,582,461,52   # 不框选，直接抓指定矩形（x,y,w,h，单位点）
//   swift run SubtitleSpike --autopick 112,582,461,52  # 走完整框选流程但自动出结果，复现/自测用
//   swift run SubtitleSpike --selftest         # 只验证遮罩窗口能建起来，不抓屏
//
// 跑之前：让一个带中英硬字幕的视频**全屏**播起来。
// ─────────────────────────────────────────────────────────────────────────────

@main
struct SubtitleSpike {

    @MainActor
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let useFullScreen = args.contains("--full")
        let maxFrames = intArg("--frames", in: args) ?? 0    // 0 = 一直跑，直到 Ctrl-C
        let intervalMs = intArg("--interval", in: args) ?? 400

        // 关掉 stdout 缓冲，保证崩溃前已经打出来的东西不会丢
        setvbuf(stdout, nil, _IONBF, 0)

        // 自检：只验证遮罩窗口能不能建起来，不抓屏、不等交互
        if args.contains("--selftest") {
            exit(RegionPicker.selfTest() ? 0 : 1)
        }

        // 框选子进程：只做框选，结果打到 stdout，然后退出。
        // 主进程用 RegionPicker.pickViaChildProcess() 起它（原因见 RegionPicker.swift 顶部）。
        if args.contains("--pick-only") {
            var sel: ScreenSelection?
            if let ap = strArg("--autopick", in: args) {
                // 自测用：不等人拖鼠标，到点自动出结果，把整条子进程链路也一起验了
                let n = ap.split(separator: ",").compactMap { Double($0) }
                let delay = strArg("--pickdelay", in: args).flatMap { Double($0) } ?? 0.8
                if n.count == 4 {
                    sel = RegionPicker.autoTest(
                        rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]),
                        displayID: CGMainDisplayID(),
                        after: delay
                    )
                }
            } else {
                sel = RegionPicker.pick()
            }
            if let s = sel {
                print("RESULT \(s.rect.origin.x),\(s.rect.origin.y),"
                      + "\(s.rect.width),\(s.rect.height),\(s.displayID)")
            } else {
                print("RESULT CANCEL")
            }
            exit(0)
        }

        // ── 1. 屏幕录制权限 ──────────────────────────────────────────
        guard CGPreflightScreenCaptureAccess() else {
            print("""

            ⚠️  当前进程没有「屏幕录制」权限。

            从终端运行时，系统把这个权限记在**终端 App** 头上。
            请打开：系统设置 → 隐私与安全性 → 屏幕录制
            勾选你正在用的终端（Terminal / iTerm / VS Code），然后重启该 App 再跑一次。

            """)
            CGRequestScreenCaptureAccess()
            exit(1)
        }

        // ── 2. 拿到可捕获的内容 ──────────────────────────────────────
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else {
            print("❌ 找不到可用显示器")
            exit(1)
        }

        // ── 3. 框选（或不框，抓整屏）────────────────────────────────
        let display: SCDisplay
        let sourceRect: CGRect

        if useFullScreen {
            guard let d = content.displays.first else { exit(1) }
            display = d
            sourceRect = CGRect(x: 0, y: 0, width: CGFloat(d.width), height: CGFloat(d.height))
            print("模式：整屏（未框选）")
        } else if let rectArg = strArg("--rect", in: args) {
            // 跳过框选，直接用给定矩形。方便复现 / 脚本化，也用来定位框选路径的问题。
            let n = rectArg.split(separator: ",").compactMap { Double($0) }
            guard n.count == 4, let d = content.displays.first else {
                print("❌ --rect 需要四个数字：x,y,w,h"); exit(1)
            }
            display = d
            sourceRect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            print("模式：--rect \(rectArg)")
        } else if let ap = strArg("--autopick", in: args) {
            // 复现用：完整走一遍框选的 run() 路径，但到点自动结束
            let n = ap.split(separator: ",").compactMap { Double($0) }
            guard n.count == 4, let d = content.displays.first else {
                print("❌ --autopick 需要四个数字：x,y,w,h"); exit(1)
            }
            let delay = strArg("--pickdelay", in: args).flatMap { Double($0) } ?? 0.8
            print("模式：--autopick \(ap)（走完整子进程框选流程，复现/自测用，delay=\(delay)s）")
            guard let sel = RegionPicker.pickViaChildProcess(
                childArgs: ["--autopick", ap, "--pickdelay", "\(delay)"]
            ) else {
                print("已取消。"); exit(0)
            }
            display = d
            sourceRect = sel.rect
        } else {
            print("请在弹出的遮罩上拖拽框出字幕区域…\n")
            guard let selection = RegionPicker.pickViaChildProcess() else {
                print("已取消。")
                exit(0)
            }
            guard let d = content.displays.first(where: { $0.displayID == selection.displayID })
                ?? content.displays.first else { exit(1) }
            display = d
            sourceRect = selection.rect
            print("模式：框选")
        }

        // ── 4. 关键：把本 App 自己排除掉 ────────────────────────────
        // ScreenCaptureKit 抓的是合成后的帧缓冲，不排除自己的话，
        // 将来悬浮窗上的文字会被自己 OCR 一遍，污染字幕稿。
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myApps = content.applications.filter { $0.processID == myPID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: myApps,
            exceptingWindows: []
        )

        // ── 5. 算真实的屏幕缩放系数 ─────────────────────────────────
        // 坑：CGDisplayPixelsWide() 在缩放显示模式下返回的是「点」不是「像素」，
        // 会导致算出来 scale = 1.0，把 Retina 画面白白降采样一半。
        let pointWidth = CGFloat(display.width)
        let pixelWidth = realPixelWidth(of: display)
        let scale = pixelWidth / pointWidth

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width  = Int(sourceRect.width  * scale)
        config.height = Int(sourceRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        print("显示器    : \(Int(pointWidth))×\(Int(display.height)) 点")
        print("真实像素  : \(Int(pixelWidth)) 宽  →  缩放 \(String(format: "%.2f", scale))x")
        if scale <= 1.01 {
            print("           ⚠️  scale 算出 1.0。若屏幕是 Retina，说明抓取被降采样了，OCR 精度会打折。")
        }
        print("框选区域  : \(fmt(sourceRect))  (点)")
        print("输出像素  : \(config.width)×\(config.height)\n")

        // ── 6. 连续采集 ────────────────────────────────────────────
        print(maxFrames == 0
              ? "开始连续采集，Ctrl-C 停止。\n"
              : "开始采集，共 \(maxFrames) 帧。\n")

        var captureTotal = 0.0
        var ocrTotal = 0.0
        var measured = 0
        var allTexts: [String: Int] = [:]
        var consecutiveErrors = 0
        var frame = 0

        while maxFrames == 0 || frame < maxFrames {
            frame += 1
            do {
                let t0 = Date()
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                let tCapture = Date().timeIntervalSince(t0)

                if frame == 1 && image.width != config.width {
                    print("⚠️  实际输出宽度 \(image.width) 与期望 \(config.width) 不符 —— sourceRect 可能没生效\n")
                }

                let t1 = Date()
                let lines = try recognize(image)
                let tOCR = Date().timeIntervalSince(t1)

                captureTotal += tCapture
                ocrTotal += tOCR
                measured += 1
                consecutiveErrors = 0
                for text in Set(lines.map(\.text)) { allTexts[text, default: 0] += 1 }

                print("── 第 \(frame) 帧 ──  抓屏 \(ms(tCapture)) ms │ OCR \(ms(tOCR)) ms │ \(lines.count) 行")
                if lines.isEmpty {
                    print("   （没识别到文字）")
                }
                for line in lines {
                    print("   [\(line.tag)] y=\(String(format: "%.3f", line.y))"
                          + "  x=\(String(format: "%.3f", line.x))"
                          + "  conf=\(String(format: "%.2f", line.confidence))"
                          + "  \(line.text)")
                }
                print("")

            } catch {
                // 单帧失败不中断整个采集，否则一帧抖动就什么都测不到了
                consecutiveErrors += 1
                print("⚠️  第 \(frame) 帧失败（连续 \(consecutiveErrors) 次）：\(error)\n")
                if consecutiveErrors >= 5 {
                    print("连续失败 5 次，停止。")
                    break
                }
            }

            fflush(stdout)
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }

        // ── 7. 汇总 ────────────────────────────────────────────────
        print("\n采集结束：共 \(frame) 帧，成功 \(measured) 帧")
        if measured > 0 {
            let n = Double(measured)
            print(String(format: "平均：抓屏 %.0f ms │ OCR %.0f ms │ 端到端约 %d ms（≈%.1f fps）",
                         captureTotal / n * 1000,
                         ocrTotal / n * 1000,
                         Int((captureTotal + ocrTotal) / n * 1000),
                         n / (captureTotal + ocrTotal)))
        }

        // 纯观察：哪些文本在多帧里重复出现。**这只是给你看的，不影响任何行为。**
        let repeated = allTexts.filter { $0.value > 1 }.sorted { $0.value > $1.value }
        print("\n── 观察：出现在多帧里的文本（\(measured) 帧共采集 \(allTexts.count) 条不同文本）──")
        if repeated.isEmpty {
            print("   （没有重复——画面里每帧的文字都不一样）")
        } else {
            for (text, count) in repeated {
                print("   \(count)/\(measured) 帧   \(text)")
            }
        }

        print("""

        ── 怎么看 ──────────────────────────────────────
        · 有文字                → 抓屏正常，没有黑屏              ✅
        · [中] / [英] 都在      → 中英识别正常                    ✅
        · 字幕两行的 y 上下分开  → 可以按位置把中英配对成一组      ✅
        · 重复出现的文本         → 大概率是 UI / 水印（仅参考）

        这一版不做任何过滤。先看你框准之后还剩多少噪音，再决定要不要处理。
        """)
    }

    // MARK: - 命令行参数

    static func intArg(_ name: String, in args: [String]) -> Int? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    static func strArg(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - 显示器真实像素宽

    static func realPixelWidth(of display: SCDisplay) -> CGFloat {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            let w = mode.pixelWidth
            if w > 0 { return CGFloat(w) }
        }
        return CGFloat(display.width) * 2  // 兜底：按 Retina 猜
    }

    // MARK: - Vision OCR

    struct Line {
        let text: String
        let confidence: Float
        let y: CGFloat        // 归一化，已转成「上小下大」
        let x: CGFloat        // 归一化，左小右大
        let hanRatio: Double  // 汉字占比
        var tag: String {     // 仅供人眼查看，不参与任何判断
            if hanRatio > 0.5 { return "中" }
            if hanRatio > 0.15 { return "混" }
            return "英"
        }
    }

    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        // 中文必须用 .accurate —— .fast 等级完全不支持中文
        request.recognitionLevel = .accurate
        // 中文必须排在英文前面；English 是唯一能与中文配对的语言
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        return observations
            .compactMap { obs -> Line? in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox   // 归一化，左下原点
                return Line(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    y: 1 - box.origin.y - box.height,   // 上小下大，取行的顶端
                    x: box.origin.x,
                    hanRatio: hanRatio(candidate.string)
                )
            }
            .sorted { $0.y < $1.y }
    }

    /// 去掉空白后，汉字字符占的比例
    static func hanRatio(_ s: String) -> Double {
        let scalars = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return 0 }
        let han = scalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return Double(han) / Double(scalars.count)
    }

    static func ms(_ t: TimeInterval) -> String {
        String(format: "%.0f", t * 1000)
    }

    static func fmt(_ r: CGRect) -> String {
        String(format: "x=%.0f y=%.0f w=%.0f h=%.0f",
               r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
}
