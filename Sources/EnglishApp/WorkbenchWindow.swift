import AppKit
import EnglishCore
import Foundation
import WebKit

/// 工作台：一个 `WKWebView` 窗口，里面是会话列表 → 字幕稿 → 导出的三屏。
///
/// 为什么用 HTML 而不是纯 AppKit：这三个界面本质上是"表格 + 长文本 + 按钮"，
/// 用网页写快得多也好改；而且不用为了改一行样式重新编译整个 App。
/// 内核和采集仍然是原生的——网页拿不到 Vision，中文 OCR 只能退化成
/// Tesseract/WASM 或者把屏幕内容传到云端，那两条路都不能要。
///
/// 桥接是**极简**的：JS 发 `{cmd, ...}`，Swift 回一个 JSON 字符串，
/// 网页侧统一从 `window.Workbench.<cmd>Result(json)` 收。没有引入
/// 任何框架，也没有双向流——v1 用不上，加了只会是负担。
@MainActor
final class WorkbenchWindow: NSObject {

    private let store: SessionStore
    private var window: NSWindow?
    private var webView: WKWebView?

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sendSessions()
    }

    // MARK: - 窗口

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        // 本地文件之间需要互相读取（html → css/js），给整个 Workbench 目录的读权限
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 不要持久化缓存。这个页面是本地的 html/css/js，不用 cookie 也不用 storage，
        // 但 WKWebView 默认的持久化缓存**会把 file:// 的 app.js 也缓存起来**。
        // 后果是很难查的一种：重编译、重打包、甚至重启 App，界面还是老的。
        // 开发时"改完存盘刷新窗口就能看到效果"这个承诺也会时灵时不灵。
        config.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640),
                            configuration: config)
        web.setValue(false, forKey: "drawsBackground")   // 交给网页自己的底色

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "字幕工作台"
        win.contentView = web
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        window = win
        webView = web
        loadIndex(into: web)
    }

    /// 网页资源的位置。
    ///
    /// 正式包：`English.app/Contents/Resources/Workbench/`（由 package_app.sh 拷进去）
    /// 开发时：仓库根的 `Resources/Workbench/`（`swift run EnglishApp` 用，
    ///        那时没有 .app bundle，只能按源码路径回退）
    private func workbenchDirectory() -> URL? {
        if let url = Bundle.main.url(forResource: "Workbench", withExtension: nil) {
            return url
        }
        // #filePath 是编译期常量：开发时指向源码，装成 .app 后指向构建机上的路径
        // （那里通常已经不存在 → 自然落到上面那一支）。仅作开发回退用。
        let dev = URL(fileURLWithPath: #filePath)          // .../Sources/EnglishApp/WorkbenchWindow.swift
            .deletingLastPathComponent()                    // .../Sources/EnglishApp
            .deletingLastPathComponent()                    // .../Sources
            .deletingLastPathComponent()                    // 仓库根
            .appendingPathComponent("Resources/Workbench")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func loadIndex(into web: WKWebView) {
        guard let dir = workbenchDirectory() else {
            web.loadHTMLString(Self.missingAssetsPage, baseURL: nil)
            return
        }
        let index = dir.appendingPathComponent("index.html")
        web.loadFileURL(index, allowingReadAccessTo: dir)
    }

    private static let missingAssetsPage = """
    <!doctype html><meta charset="utf-8">
    <body style="font:14px -apple-system;padding:40px;color:#c00">
    <h2>找不到工作台资源</h2>
    <p>预期位置：<code>English.app/Contents/Resources/Workbench/</code></p>
    <p>打包时漏拷了。跑一次 <code>Scripts/package_app.sh</code> 应该会修好。</p>
    </body>
    """

    // MARK: - 回数据给网页

    private func reply(_ handler: String, _ payload: Any) {
        guard let webView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        // 用 JSON.parse 而不是直接塞字面量：字符串里的引号/换行不会撕破 JS 语法
        webView.evaluateJavaScript("window.Workbench.\(handler)(JSON.parse(\(Self.jsString(json))))")
    }

    /// 把一个 Swift 字符串转成合法的 JS 字符串字面量
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        guard let data, var out = String(data: data, encoding: .utf8) else { return "\"\"" }
        // JSONSerialization 给出的是 ["..."]，剥掉外面的方括号
        out.removeFirst()
        out.removeLast()
        return out
    }

    private func sendSessions() {
        var totalFavorites = 0
        let list = store.listSessions().map { meta -> [String: Any] in
            let entries = store.entries(of: meta.id)
            let favoriteCount = store.favorites(of: meta.id).count
            totalFavorites += favoriteCount
            return [
                "id": meta.id,
                "name": meta.name,
                // ISO8601：网页侧 `new Date(...)` 能直接解析
                "startedAt": ISO8601DateFormatter().string(from: meta.startedAt),
                "entryCount": entries.count,
                "hasChinese": entries.contains { !$0.chinese.isEmpty },
                "favoriteCount": favoriteCount,
            ]
        }
        // 侧栏那个置顶的「★ 收藏 · N」用的总数。跟着一起回，省得前端自己加总。
        reply("onSessions", ["sessions": list, "totalFavorites": totalFavorites])
    }

    /// 跨会话的收藏，按会话分组。会话顺序沿用 `listSessions()` 的（时间倒序）。
    private func sendFavorites() {
        let iso = ISO8601DateFormatter()
        let groups = store.listAllFavorites().map { group -> [String: Any] in
            [
                "id": group.meta.id,
                "name": group.meta.name,
                "startedAt": iso.string(from: group.meta.startedAt),
                "items": group.favorites.map { f -> [String: Any] in
                    ["index": f.index, "english": f.english, "chinese": f.chinese,
                     "starredAt": iso.string(from: f.starredAt)]
                },
            ]
        }
        reply("onFavorites", ["groups": groups])
    }

    /// JS 侧传数字来时会桥接成 NSNumber，直接 `as? Int` 在部分路径上会落空。
    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}

// MARK: - JS → Swift

extension WorkbenchWindow: WKScriptMessageHandler {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }

        switch cmd {
        case "list":
            sendSessions()

        case "load":
            guard let id = body["id"] as? String else { return }
            let entries = store.entries(of: id)
            let favorites = store.favorites(of: id)
            reply("onSession", [
                "id": id,
                "favoriteCount": favorites.count,
                "entries": entries.map { e -> [String: Any] in
                    ["index": e.index, "start": e.start, "end": e.end,
                     "chinese": e.chinese, "english": e.english,
                     "frameCount": e.frameCount, "isFlash": e.isFlash,
                     "favorited": favorites.contains(index: e.index)]
                },
            ])

        case "loadFavorites":
            sendFavorites()

        case "favorite", "unfavorite":
            guard let id = body["id"] as? String,
                  let index = Self.intValue(body["index"]) else { return }
            // 快照从 entries.jsonl 现取，**不信前端传过来的文本** —— 单一事实来源
            guard let entry = store.entries(of: id).first(where: { $0.index == index }) else {
                reply("onFavoriteToggled", ["ok": false, "id": id, "index": index,
                                            "error": "找不到这一句"])
                return
            }
            var doc = store.favorites(of: id)
            doc = cmd == "favorite"
                ? doc.adding(entry, at: Date())
                : doc.removing(index: index)
            do {
                try store.setFavorites(doc, for: id)
                let total = store.listAllFavorites().reduce(0) { $0 + $1.favorites.count }
                reply("onFavoriteToggled", ["ok": true, "id": id, "index": index,
                                            "favorited": doc.contains(index: index),
                                            "count": doc.count, "totalFavorites": total])
            } catch {
                reply("onFavoriteToggled", ["ok": false, "id": id, "index": index,
                                            "error": error.localizedDescription])
            }

        case "export":
            let format = Exporter.Format(rawValue: body["format"] as? String ?? "md") ?? .markdown
            // 收藏导出没有会话 id —— 它是跨会话的，得在取 id 之前先分流
            if body["scope"] as? String == "favorites" {
                reply("onExported", Exporter.writeFavorites(format: format, store: store).json)
                return
            }
            guard let id = body["id"] as? String else { return }
            reply("onExported", Exporter.write(sessionID: id, format: format, store: store).json)

        case "rename":
            guard let id = body["id"] as? String,
                  let name = body["name"] as? String else { return }
            do {
                let meta = try store.rename(id: id, to: name)
                reply("onRenamed", ["ok": true, "id": meta.id, "name": meta.name])
            } catch {
                reply("onRenamed", ["ok": false, "id": id,
                                    "error": error.localizedDescription])
            }

        case "reveal":
            // 三种意图：会话目录（侧栏右键）/ 导出的会话文档（页头 Finder，默认）/
            // 导出的收藏文档（收藏视图的 Finder）。默认 export 是为了向后兼容。
            let target = body["target"] as? String ?? "export"
            let url: URL?
            switch target {
            case "session":
                url = (body["id"] as? String).map { store.root.appendingPathComponent($0) }
            case "favorites":
                url = store.root.deletingLastPathComponent()
                    .appendingPathComponent(Exporter.Format.markdown.favoritesFilename)
            default:
                url = (body["id"] as? String).map {
                    store.root.appendingPathComponent($0).appendingPathComponent("export.md")
                }
            }
            guard let url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])

        default:
            break
        }
    }
}

// MARK: - 关窗

extension WorkbenchWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 窗口留着复用，只是藏起来——下次打开要保住滚动位置和当前选中的会话
        window?.orderOut(nil)
    }
}
