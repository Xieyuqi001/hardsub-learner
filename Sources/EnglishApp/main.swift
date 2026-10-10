import AppKit

// 正式的 .app 入口。走标准 NSApplication.run()，事件循环从头到尾都在。
//
// 注意：spike 里那个「跑过 AppKit 事件循环后进程静默 exit(0)」的坑，
// 根因是 `@main async` 的主队列驱动和 AppKit 事件循环打架。
// 这里是普通 .app + 顶层代码 + run()，没有那个问题。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
