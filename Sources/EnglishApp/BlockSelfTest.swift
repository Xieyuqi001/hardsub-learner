import AppKit
import EnglishCapture
import EnglishCore
import ImageIO
import UniformTypeIdentifiers

/// `English --selftest-block`
///
/// 验证「遮挡字幕」这个功能**整个前提**所依赖的那一条性质：
///
/// > 本 App 画的不透明黑块**只挡用户的眼睛，挡不住自己的抓屏**。
///
/// 挡不住才成立：抓屏若被自己的黑块糊掉，OCR 就什么都读不到，
/// 于是「挡着原字幕练听力、字幕稿照常积累」这件事根本不成立。
///
/// 守住这条性质的是 `ScreenCapturer` 里的
/// `SCContentFilter(display:excludingApplications:exceptingWindows:)`。
/// 它按**应用**（不是按像素）排除，所以理论上透明悬浮窗和不透明黑块待遇相同——
/// **但这是推断，不是实测**。已有的 `--selftest-capture` 只验过透明的悬浮窗；
/// 不透明窗口会不会被"排除"成一个黑洞，只能实测。
///
/// 四步对照，每一步都缺一不可：
///
///   ① 黑块隐藏 + 不排除自己 → 哨兵**必须**被认出
///      （证明哨兵真在屏幕上、区域框对了、OCR 读得到）
///   ② 黑块隐藏 + 排除自己   → 记下**背景真实内容**，作为基准
///   ③ 黑块显示 + 不排除自己 → 哨兵**必须**认不出，且亮度**必须**比 ① 掉八成以上
///      （证明黑块真的把这块屏幕糊住了，不是没显示出来）
///      ⚠️ 亮度判据用的是**相对 ① 的下降**，不是绝对阈值——本 App 的窗口在
///      `.floating` 层，压不住层级更高的窗口（实测遇到过别的 App 的置顶浮标），
///      绝对阈值会被那种东西误判成"黑块没画上"。
///   ④ 黑块显示 + 排除自己   → 内容**必须与②逐行一致**
///      ←  这一步才是结论。它同时排掉了两种假通过：
///          · 黑块漏进了抓屏 → ④ 会变成一片黑、②里那些行全没了
///          · 黑块压根没画上 → ③ 就过不了
///
/// 少了 ③，④ 的"内容一致"完全可能只是黑块没显示出来——那是一个假通过。
@MainActor
enum BlockSelfTest {

    /// 塞进悬浮窗的哨兵文本。用生僻字母组合，杜绝和屏幕上别的内容撞车。
    private static let sentinel = "SELFTEST SENTINEL ZQXJ"
    private static let sentinelKey = TextNormalizer.compareKey(sentinel)

    static func run(overlay: OverlayPanel, occlusion: OcclusionPanel) async -> Int32 {
        print("── 遮挡块自排除对照实验 ──\n")

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

        // 哨兵写进悬浮窗，摆出来。黑块就盖在悬浮窗上面。
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

        var failures = 0

        // 黑块用**正式实现**，不是这里另建一个裸 NSWindow。
        // 探针和正式版必须是同一个东西，否则探针验的是探针——
        // 今天过了，明天 OcclusionPanel 改个属性就悄悄失效了。
        occlusion.setFrame(overlay.screenFrame)
        guard occlusion.isPlaced else {
            print("✗ 黑块摆不上去（屏幕装不下悬浮窗那么大的一块？）")
            return 1
        }
        defer { occlusion.hide() }
        // 故意先不显示：① ② 两步要的是"黑块不存在"的状态

        print(String(format: "  黑块 %.0f×%.0f @ (%.0f, %.0f)（对准悬浮窗）\n",
                     occlusion.frame.width, occlusion.frame.height,
                     occlusion.frame.minX, occlusion.frame.minY))
        if occlusion.frame != overlay.screenFrame {
            print("  ⚠️ 黑块被 clamp 过，和悬浮窗没完全重合——③ 那步的「哨兵消失」")
            print("     可能是只盖住了一部分。结论要打折扣。\n")
            failures += 1
        }

        // 等窗口真的合成到屏幕上。窗口从 orderFront 到进入帧缓冲有一段延迟，
        // 少了这个等待，① 就会"没找到"——然后整个实验失去意义。
        try? await Task.sleep(for: .seconds(2))

        // SCK 要的是**显示器相对、左上原点、点**；AppKit 是左下原点。
        let f = overlay.screenFrame
        let s = screen.frame
        let selection = ScreenSelection(
            rect: CGRect(x: f.minX - s.minX, y: s.maxY - f.maxY,
                         width: f.width, height: f.height),
            displayID: screen.displayID ?? CGMainDisplayID()
        )

        // ── ① 黑块隐藏 + 不排除自己：哨兵必须在 ──────────────────────────
        let background: [String]
        let baselineBrightness: Double
        do {
            let shot = try await grabWithBrightness(selection, excludeOwnApp: false)
            baselineBrightness = shot.brightness
            let lines = shot.lines
            print(String(format: "  ① 无黑块 · 不排除自己 —— 平均亮度 %.1f/255，OCR 到 %d 行：",
                         baselineBrightness, lines.count))
            for l in lines { print("       \(l)") }
            if lines.contains(where: { TextNormalizer.compareKey($0).contains(sentinelKey) }) {
                print("     ✓ 认出哨兵 —— 实验组成立，后面的结论才有意义\n")
            } else {
                print("     ✗ 没认出哨兵 —— 多半是窗口没合成 / 区域框歪了 / 字太小")
                print("       这一步不过，后面全部不可信\n")
                failures += 1
            }
        } catch {
            print("  ✗ ① 采集失败：\(error)\n")
            return 1
        }

        // ── ② 黑块隐藏 + 排除自己：记下背景真实内容，当基准 ────────────────
        do {
            background = try await grab(selection, excludeOwnApp: true)
            print("  ② 无黑块 · 排除自己 —— 抓到 \(background.count) 行背景内容（基准）")
            if background.isEmpty {
                print("     ⚠️ 背景一个字都没有 —— ④ 的比对会退化成空对空，信息量很低。")
                print("        把悬浮窗挪到有文字的画面上（比如一个打开的文本窗口）再跑一次。")
            }
            print("")
        } catch {
            print("  ✗ ② 采集失败：\(error)\n")
            return 1
        }

        // ── ③ 黑块显示 + 不排除自己：哨兵必须消失，画面必须变黑 ────────────
        occlusion.show()
        try? await Task.sleep(for: .seconds(1))
        do {
            let shot = try await grabWithBrightness(selection, excludeOwnApp: false)
            print(String(format: "  ③ 有黑块 · 不排除自己 —— 平均亮度 %.1f/255，OCR 到 %d 行",
                         shot.brightness, shot.lines.count))
            print("       \(shot.bright.text)")
            for l in shot.lines { print("       \(l)") }

            let stillThere = shot.lines.contains {
                TextNormalizer.compareKey($0).contains(sentinelKey)
            }
            // 亮度判据是**相对 ①**的：屏幕上有没有别的 App 的置顶浮窗不归我们管
            // （实测踩到过——一个「拖拽至此上传」的药丸就压在黑块上面），
            // 用绝对阈值会被它误判。黑块画没画上去，看的是"亮度掉了多少"。
            let drop = baselineBrightness > 1 ? 1 - shot.brightness / baselineBrightness : 0

            if stillThere {
                print("     ✗ 哨兵还在 —— 黑块没挡住，功能无从谈起")
                failures += 1
            } else if drop < 0.8 {
                print(String(format: "     ✗ 哨兵虽没了，但亮度只掉了 %.0f%%（%.1f → %.1f）——",
                             drop * 100, baselineBrightness, shot.brightness))
                print("       黑块多半没铺满或不是不透明。挡字幕会漏边")
                failures += 1
            } else {
                print(String(format: "     ✓ 哨兵看不见了，亮度掉了 %.0f%%（%.1f → %.1f）",
                             drop * 100, baselineBrightness, shot.brightness))
                print("       —— 黑块确实糊住了这块屏幕")
                if shot.bright.fraction > 0.02 {
                    print("       ⚠️ 但有 \(Int(shot.bright.fraction * 100))% 的面积还是亮的。")
                    print("          本 App 的窗口在 `.floating` 层，压不住层级更高的窗口")
                    print("          （实测遇到过别的 App 的置顶浮标）。跑这个自检时设")
                    print("          BLOCK_DUMP=<目录>，把图存下来看一眼就知道是什么")
                }
            }
            print("")
        } catch {
            print("  ✗ ③ 采集失败：\(error)\n")
            return 1
        }

        // ── ④ 黑块显示 + 排除自己：结论。必须与 ② 逐行一致 ─────────────────
        do {
            let lines = try await grab(selection, excludeOwnApp: true)
            print("  ④ 有黑块 · 排除自己 —— 抓到 \(lines.count) 行：")
            for l in lines { print("       \(l)") }

            if lines == background {
                print("     ✓ 与 ② 逐行一致 —— **黑块被排除了，底下的字幕原样抓得到**")
                if background.isEmpty {
                    print("       （注意：这次是空对空，严格说没验到东西，见 ② 的警告）")
                }
            } else {
                print("     ✗ 与 ② 不一致 —— 黑块漏进了抓屏")
                print("       ② 有 \(background.count) 行、④ 有 \(lines.count) 行，差集：")
                for l in Set(background).subtracting(lines) { print("         ②有④无：\(l)") }
                for l in Set(lines).subtracting(background) { print("         ④有②无：\(l)") }
                failures += 1
            }
            print("")
        } catch {
            print("  ✗ ④ 采集失败：\(error)\n")
            return 1
        }

        occlusion.hide()
        overlay.hide()
        print("")
        if failures == 0 {
            print("── 通过：黑块只挡眼睛，不挡抓屏 ──")
        } else {
            print("── 失败 \(failures) 项 ──")
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: - 工具

    private static func grab(_ selection: ScreenSelection,
                             excludeOwnApp: Bool) async throws -> [String] {
        try await grabWithBrightness(selection, excludeOwnApp: excludeOwnApp).lines
    }

    private static func grabWithBrightness(_ selection: ScreenSelection, excludeOwnApp: Bool)
        async throws -> (lines: [String], brightness: Double,
                         bright: (text: String, fraction: Double)) {
        let capturer = try await ScreenCapturer(selection: selection, excludeOwnApp: excludeOwnApp)
        let image = try await capturer.capture()

        // `BLOCK_DUMP=<目录>` 时把每次抓到的图存下来。
        // 这张图就是这次调试的转折点：光看"平均亮度 6.6"只能瞎猜，
        // 存下来一眼就看见漏出来的是**别的 App 的置顶浮标**。
        if let dir = ProcessInfo.processInfo.environment["BLOCK_DUMP"] {
            let name = "\(dir)/\(excludeOwnApp ? "排除自己" : "不排除")-\(UUID().uuidString.prefix(4)).png"
            if let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: name) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                print("       （图已存 \(name)）")
            }
        }

        let lines = try OCREngine.recognize(image).map(\.text)
        return (lines, averageBrightness(of: image), brightRegion(of: image))
    }

    /// 降采样成灰度图求平均。用来判断"这块画面是不是全黑"。
    private static func averageBrightness(of image: CGImage) -> Double {
        guard let g = grayscale(of: image, width: 64) else { return -1 }
        let total = g.pixels.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(g.pixels.count)
    }

    /// 亮像素（> 40）占的那块区域 + 占全图多少。
    ///
    /// ③ 一旦"没全黑"，光看平均亮度只知道**有**漏光、不知道**漏在哪**——
    /// 而"沿边缘一圈细线"和"右上角一坨东西"是完全不同的毛病。
    /// 这个函数就是用来分的：它直接指出漏光的形状。
    private static func brightRegion(of image: CGImage) -> (text: String, fraction: Double) {
        guard let g = grayscale(of: image, width: 64) else { return ("（读不到像素）", 0) }
        var minX = g.width, minY = g.height, maxX = -1, maxY = -1, count = 0
        for y in 0..<g.height {
            for x in 0..<g.width where g.pixels[y * g.width + x] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
            }
        }
        let pct = Double(count) / Double(g.pixels.count)
        guard maxX >= 0 else { return ("一个亮像素都没有", 0) }
        let fx = { (v: Int, of: Int) in Double(v) / Double(of) }
        return (String(format: "亮区占 x %.2f–%.2f、y %.2f–%.2f（归一化）、面积 %.1f%%",
                       fx(minX, g.width), fx(maxX + 1, g.width),
                       fx(minY, g.height), fx(maxY + 1, g.height), pct * 100), pct)
    }

    private static func grayscale(of image: CGImage, width: Int)
        -> (pixels: [UInt8], width: Int, height: Int)? {
        let aspect = Double(image.height) / Double(max(1, image.width))
        let h = max(1, Int((Double(width) * aspect).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * h)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: h,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: h))
        return (pixels, width, h)
    }
}
