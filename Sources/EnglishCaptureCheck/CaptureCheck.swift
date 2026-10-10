import CoreGraphics
import EnglishCapture
import EnglishCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 采集链路的离线体检工具。
//
// 为什么需要它：采集这一段（抓屏 → 缩放 → OCR）**没有夹具可以回归**——
// 它依赖真实屏幕。而 AppDelegate 里那条路要授权、要框选、要放视频，
// 出问题时根本分不清是「区域框错了」「缩放算错了」还是「OCR 认错了」。
//
// 这个 CLI 复用 EnglishCapture 的**同一份代码**，把中间产物全打出来：
// 每一帧 OCR 到了什么、跳过了几帧、成句结果是什么，外加可选的原始截图。
//
// 用法：
//   swift run capture-check                      # 用默认区域
//   swift run capture-check 940 780 540 150 12   # x y 宽 高 秒数
//   swift run capture-check ... --dump /tmp/frames   # 把每帧原图存下来

@main
struct CaptureCheck {

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())

        var dumpDir: String?
        if let i = args.firstIndex(of: "--dump") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("--dump 后面要跟一个目录\n".utf8))
                exit(2)
            }
            dumpDir = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }

        // ── 权限 ────────────────────────────────────────────────────────────
        // 必须在建 Session 之前查。SCK 在没有权限时抛的错很含糊，
        // 提前查一次能把「没授权」和「代码写错了」彻底分开。
        guard CGPreflightScreenCaptureAccess() else {
            print("""
            ✗ 没有屏幕录制权限。

              这个 CLI 从终端启动，用的是**终端自己的**权限，不是 English.app 的。
              给终端开一下：系统设置 → 隐私与安全性 → 屏幕录制 → 勾上你用的终端，
              然后**完全退出终端再重开**（授权后不重启不生效）。

              已确认能用的旁证：`screencapture -x /tmp/x.png` 能出图，就有权限。
            """)
            exit(1)
        }
        print("✓ 屏幕录制权限 OK")

        // ── 区域 ────────────────────────────────────────────────────────────
        let numbers = args.prefix(5).compactMap(Double.init)
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)

        let selection: ScreenSelection
        if numbers.count >= 4 {
            selection = ScreenSelection(
                rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                displayID: displayID
            )
        } else {
            // 默认：主屏下半部的一块横幅——正是字幕通常待的位置
            selection = ScreenSelection(
                rect: CGRect(x: bounds.width * 0.25, y: bounds.height * 0.72,
                             width: bounds.width * 0.5, height: bounds.height * 0.12),
                displayID: displayID
            )
        }
        let seconds = numbers.count >= 5 ? numbers[4] : 10
        let interval = Duration.milliseconds(400)

        print(String(format: "  主屏 %.0f×%.0f 点", bounds.width, bounds.height))
        print(String(format: "  区域 x=%.0f y=%.0f %.0f×%.0f，跑 %.0f 秒",
                     selection.x, selection.y, selection.width, selection.height, seconds))

        // ── 开跑 ────────────────────────────────────────────────────────────
        let session: CaptureSession
        do {
            session = try await CaptureSession(selection: selection, interval: interval)
        } catch {
            print("✗ 建采集会话失败：\(error)")
            exit(1)
        }

        let g = session.geometry
        print(String(format: "  缩放 %.1fx → 送进 OCR 的位图 %d×%d 像素",
                     g.scale, g.outputWidth, g.outputHeight))
        // 字幕笔画高度低于约 20px 时 Vision 的中文识别会明显掉。这个数就是判据。
        print(String(format: "  （中文行笔画高度需 ≥ 约 20px；区域高 %.0f 点 ≈ %.0f 像素）",
                     selection.height, selection.height * g.scale))
        print("")

        if let dumpDir {
            try? FileManager.default.createDirectory(
                atPath: dumpDir, withIntermediateDirectories: true
            )
        }

        var assembler = SubtitleAssembler()
        var frames = 0, skipped = 0, withText = 0
        let deadline = Date().addingTimeInterval(seconds)

        do {
            while Date() < deadline {
                try await session.waitForNextPoll()

                guard let frame = try await session.nextFrame() else {
                    skipped += 1
                    continue
                }
                frames += 1

                if let dumpDir {
                    if let image = try? await session.captureRawImage() {
                        writePNG(image, to: "\(dumpDir)/frame-\(String(format: "%03d", frames)).png")
                    }
                }

                if frame.lines.isEmpty {
                    print(String(format: "  [%6.2fs] （空帧）", frame.timestamp))
                } else {
                    withText += 1
                    print(String(format: "  [%6.2fs] %d 行：", frame.timestamp, frame.lines.count))
                    for line in frame.lines {
                        let lang = FramePairer.language(of: line) == .chinese ? "中" : "英"
                        print(String(format: "           %@ x=%.2f y=%.2f conf=%.2f  %@",
                                     lang, line.x, line.y, line.confidence, line.text))
                    }
                }

                for entry in assembler.consume(frame) {
                    print(String(format: "    ┌ 成句 #%d [%.1f–%.1fs] 中文 %d 帧",
                                 entry.index, entry.start, entry.end, entry.frameCount))
                    print("    │ 中  \(entry.chinese)")
                    print("    │ 英  \(entry.english)")
                    print("    └")
                }
            }
            for entry in assembler.flush() {
                print(String(format: "    ┌ 收尾 #%d [%.1f–%.1fs]", entry.index, entry.start, entry.end))
                print("    │ 中  \(entry.chinese)")
                print("    │ 英  \(entry.english)")
                print("    └")
            }
        } catch {
            print("✗ 采集中断：\(error)")
            exit(1)
        }

        print("")
        print("── 统计 ──")
        print("  OCR 帧 \(frames) · 指纹跳过 \(skipped) 帧 · 有文字 \(withText) 帧")
        if frames + skipped > 0 {
            let ratio = Double(skipped) / Double(frames + skipped) * 100
            print(String(format: "  跳帧率 %.0f%%（字幕区静止时越高越省电）", ratio))
        }
        if frames == 0 {
            print("  ⚠️  一帧都没抓到——权限刚给的话，完全退出终端重开再试")
        } else if withText == 0 {
            print("  ⚠️  抓到帧但一行都没认出来：区域里多半没文字，或字太小")
        }
    }

    static func writePNG(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
