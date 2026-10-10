// swift-tools-version: 6.0
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────────
// 为什么没有 testTarget、而是一个 EnglishCoreCheck 可执行目标
//
// 这台机器只有 CommandLineTools，没有完整 Xcode。在这种工具链下
// `swift test` **不会真的执行测试**：
//
//   · 编译、链接全部通过，`swift test` 退出码 0
//   · 但一条测试都不跑，零输出
//   · 把测试改成**故意失败**，依然退出 0、零输出   ← 决定性证据
//
// 试图修它要同时补三处路径（Testing.framework 的 -F、宏插件的 -plugin-path、
// lib_TestingInterop.dylib 的运行时 rpath），前两处补完编译能过，第三处补完
// 二进制能加载——**但测试仍然不执行**。这是个填不完的坑。
//
// 所以回归测试不用框架，用最笨也最可靠的办法：一个普通可执行文件。
//
//   swift run core-check
//
// 它读真实剧集夹具、跑断言、打印可读报告，失败时退出码非 0。
// 不依赖任何测试框架，任何机器、任何 agent 都能跑。
// ─────────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "English",
    platforms: [.macOS(.v15)],
    products: [
        // 给个短名字，日常敲的是 `swift run core-check`
        .executable(name: "core-check", targets: ["EnglishCoreCheck"]),
        // 采集链路的体检工具，需要真实屏幕，不参与离线回归
        .executable(name: "capture-check", targets: ["EnglishCaptureCheck"]),
    ],
    targets: [
        // 纯逻辑内核：不碰屏幕、不碰 UI、不碰系统 API，可离线回归
        .target(name: "EnglishCore"),

        // 采集层：ScreenCaptureKit 抓屏 + Vision OCR + 框选。依赖系统 API，不可离线测
        .target(name: "EnglishCapture", dependencies: ["EnglishCore"]),

        // 菜单栏 App：悬浮窗 + HTML 工作台
        .executableTarget(
            name: "EnglishApp",
            dependencies: ["EnglishCore", "EnglishCapture"]
        ),

        // 离线回归器：喂夹具、跑断言、打印报告
        .executableTarget(
            name: "EnglishCoreCheck",
            dependencies: ["EnglishCore"],
            resources: [.copy("Fixtures")]
        ),

        // 采集体检：把「抓屏 → 缩放 → OCR → 成句」的每一步中间产物打出来。
        // 这些断言没法离线做（要真实屏幕），所以它不叫 check 而叫体检——
        // 人看输出判断，不做自动断言。
        .executableTarget(
            name: "EnglishCaptureCheck",
            dependencies: ["EnglishCapture"]
        ),
    ]
)
