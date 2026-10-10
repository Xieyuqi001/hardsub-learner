import AppKit
import EnglishCapture
import EnglishCore
import Foundation

/// `English --selftest-capture`
///
/// 验证一条**只靠读代码确认不了**的性质：悬浮窗和字幕区重叠时，
/// 悬浮窗上的字不会被自己 OCR 一遍再喂回字幕稿。
///
/// 守这条性质的是 `ScreenCapturer` 里的
/// `SCContentFilter(display:excludingApplications:exceptingWindows:)` 自排除
/// （macOS 15+ 里更省事的 `sharingType = .none` 已失效）。它到底排掉了什么，
/// 只能实测。
///
/// 这是个**对照实验**，两步缺一不可：
///
///   1. `excludeOwnApp: false` → 哨兵文本**必须**被认出来
///      （证明哨兵确实画在了屏幕上、OCR 确实读得到、区域确实框对了）
///   2. `excludeOwnApp: true`  → 哨兵文本**必须**认不出来
///      （这才是要验证的性质）
///
/// 少了第 1 步，第 2 步的"没找到"完全可能只是窗口没显示出来 / 区域框歪了 /
/// 字太小——那是一个**假通过**。有对照，结论才成立。
@MainActor
enum SelfTest {

    /// 塞进悬浮窗的哨兵文本。用生僻字母组合，杜绝和屏幕上别的内容撞车。
    private static let sentinel = "SELFTEST SENTINEL ZQXJ"
    /// 比对用的小写去空白形式
    private static let sentinelKey = TextNormalizer.compareKey(sentinel)

    static func run(overlay: OverlayPanel) async -> Int32 {
        print("── 自排除对照实验 ──\n")

        guard CGPreflightScreenCaptureAccess() else {
            print("""
            ✗ English.app 还没有屏幕录制权限，自检跑不了。

              给这个 bundle 授权（不是给终端）：
                系统设置 → 隐私与安全性 → 屏幕录制 → 加上 English.app
              然后**退出 App 再重开**。

              想重新触发系统弹窗：tccutil reset ScreenCapture \(Bundle.main.bundleIdentifier ?? "dev.hardsub.english")
            """)
            return 1
        }

        // 哨兵写进悬浮窗，摆出来
        let entry = SubtitleEntry(
            index: 1, start: 0, end: 3,
            chinese: sentinel, english: sentinel,
            frameCount: 3, isFlash: false
        )
        overlay.clear()
        overlay.append(entry)
        overlay.setStatus("自检中")
        overlay.show()

        guard let screen = NSScreen.main else {
            print("✗ 拿不到主屏")
            return 1
        }

        // 等窗口真的合成到屏幕上。窗口从 orderFront 到进入帧缓冲有一段延迟，
        // 少了这个等待，第 1 步就会"没找到"——然后整个实验失去意义。
        try? await Task.sleep(for: .seconds(2))

        // 悬浮窗在 AppKit 全局坐标里是**左下原点**，SCK 要的是
        // **显示器相对、左上原点、点**。这是全项目第三处容易搞混的坐标系。
        let f = overlay.screenFrame
        let s = screen.frame
        let selection = ScreenSelection(
            rect: CGRect(x: f.minX - s.minX, y: s.maxY - f.maxY,
                         width: f.width, height: f.height),
            displayID: screen.displayID ?? CGMainDisplayID()
        )
        print(String(format: "  悬浮窗位置 x=%.0f y=%.0f %.0f×%.0f（点，左上原点）",
                     selection.x, selection.y, selection.width, selection.height))
        print("  预期：这块区域里充满着哨兵文本「\(sentinel)」\n")

        var failures = 0

        // ── 第 1 步：对照组，不排除自己 ─────────────────────────────────────
        let controlFound: Bool
        do {
            let capturer = try await ScreenCapturer(selection: selection, excludeOwnApp: false)
            let image = try await capturer.capture()
            let lines = try OCREngine.recognize(image)
            print("  1) 不排除自己 —— OCR 到 \(lines.count) 行：")
            for l in lines { print("       \(l.text)") }
            controlFound = lines.contains { TextNormalizer.compareKey($0.text).contains(sentinelKey) }
            if controlFound {
                print("     ✓ 认出哨兵 —— 对照组成立，说明哨兵真的在画面上\n")
            } else {
                print("     ✗ 没认出哨兵 —— 对照组失败，后面的结论一律不可信")
                print("       （多半是窗口没合成、区域框歪了、或字太小）\n")
                failures += 1
            }
        } catch {
            print("  ✗ 对照组采集失败：\(error)\n")
            return 1
        }

        // ── 第 2 步：实验组，排除自己 ──────────────────────────────────────
        do {
            let capturer = try await ScreenCapturer(selection: selection, excludeOwnApp: true)
            let image = try await capturer.capture()
            let lines = try OCREngine.recognize(image)
            print("  2) 排除自己 —— OCR 到 \(lines.count) 行：")
            for l in lines { print("       \(l.text)") }
            let leaked = lines.contains { TextNormalizer.compareKey($0.text).contains(sentinelKey) }
            if leaked {
                print("     ✗ 哨兵还是被认出来了 —— **自排除失效**，悬浮窗会自我污染字幕稿")
                failures += 1
            } else {
                print("     ✓ 认不出哨兵 —— 自排除生效")
                print("       （上面这些行是悬浮窗背后真正的内容，可以借此确认区域没框歪）")
            }
        } catch {
            print("  ✗ 实验组采集失败：\(error)")
            return 1
        }

        overlay.hide()
        print("")
        if failures == 0 {
            print("── 通过：自排除确实生效 ──")
        } else {
            print("── 失败 \(failures) 项 ──")
        }
        return failures == 0 ? 0 : 1
    }
}
