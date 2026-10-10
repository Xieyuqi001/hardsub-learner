import AppKit
import EnglishCore

/// 悬浮字幕窗：贴在视频旁边的一条滚动字幕稿。
///
/// 几个必须做对的属性（少一个就会"看起来没生效"）：
///   · `.nonactivatingPanel` —— 点它不抢走播放器的焦点
///   · `level = .floating`   —— 否则被视频窗口盖住
///   · `[.canJoinAllSpaces, .fullScreenAuxiliary]` —— 否则全屏看剧时它留在另一个 Space 上
///   · `isMovableByWindowBackground` —— 无边框窗口只能这样拖
///
/// ⚠️ 这个窗一旦和字幕区域重叠，屏上的字会被自己 OCR 一遍。
/// 防住它的是 ScreenCapturer 里的 `SCContentFilter(excludingApplications:)`
/// ——不是这个文件的责任，但改动时别忘了它们是一对。
@MainActor
final class OverlayPanel: NSObject {

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "未开始")
    private var entries: [SubtitleEntry] = []

    /// 最多渲染多少行。一集可能上千句，全铺出来没必要
    private let visibleLimit = 300

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        panel.contentView = buildContentView()
        positionAtRightEdge()
    }

    // MARK: - 对外

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    /// 窗口在 AppKit 全局坐标里的位置（**左下原点**）。
    /// 只给自检用——换算成 SCK 的左上原点是被测对象本身，别在别处依赖它。
    var screenFrame: NSRect { panel.frame }

    func append(_ entry: SubtitleEntry) {
        entries.append(entry)
        if entries.count > visibleLimit {
            entries.removeFirst(entries.count - visibleLimit)
        }
        tableView.reloadData()
        tableView.scrollRowToVisible(entries.count - 1)
    }

    func clear() {
        entries.removeAll()
        tableView.reloadData()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// 点击穿透：开着的时候鼠标事件直接穿过悬浮窗
    func setClickThrough(_ on: Bool) {
        panel.ignoresMouseEvents = on
    }

    var isClickThrough: Bool { panel.ignoresMouseEvents }

    // MARK: - 视图搭建

    private func buildContentView() -> NSView {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 10)
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let stack = NSStackView(views: [statusLabel, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        return container
    }

    private func positionAtRightEdge() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 24,
            y: frame.minY + (frame.height - size.height) / 2
        ))
    }
}

// MARK: - 表格数据源

extension OverlayPanel: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("EntryRow")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? EntryRowView)
            ?? EntryRowView(identifier: id)
        view.configure(with: entries[row])
        return view
    }
}

/// 一行字幕：英文在上、中文在下。
/// 英文给更大的字号——这份材料是拿来学英语的，中文只是对照。
private final class EntryRowView: NSView {

    private let english = NSTextField(wrappingLabelWithString: "")
    private let chinese = NSTextField(wrappingLabelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        english.font = .systemFont(ofSize: 15, weight: .medium)
        english.textColor = .labelColor
        chinese.font = .systemFont(ofSize: 12)
        chinese.textColor = .secondaryLabelColor
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        indexLabel.textColor = .tertiaryLabelColor

        for v in [indexLabel, english, chinese] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            indexLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            indexLabel.widthAnchor.constraint(equalToConstant: 26),

            english.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 4),
            english.trailingAnchor.constraint(equalTo: trailingAnchor),
            english.topAnchor.constraint(equalTo: topAnchor),

            chinese.leadingAnchor.constraint(equalTo: english.leadingAnchor),
            chinese.trailingAnchor.constraint(equalTo: trailingAnchor),
            chinese.topAnchor.constraint(equalTo: english.bottomAnchor, constant: 2),
            chinese.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: SubtitleEntry) {
        indexLabel.stringValue = "\(entry.index)"
        english.stringValue = entry.english.isEmpty ? "—" : entry.english
        chinese.stringValue = entry.chinese
    }
}
