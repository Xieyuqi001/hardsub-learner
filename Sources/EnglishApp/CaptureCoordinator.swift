import AppKit
import EnglishCapture
import EnglishCore
import Foundation

/// 把 采集 → 组装 → 落盘 → UI 串起来。
///
/// 采集循环跑在**后台任务**里（`Task.detached`）——如果用普通的 `Task {}`，
/// 在 @MainActor 类型里会继承主线程隔离，整个 OCR 循环会堵住 UI。
@MainActor
final class CaptureCoordinator {

    private(set) var isRunning = false
    private(set) var currentSession: Session?

    /// 每定稿一句回调一次（主线程）
    var onEntry: ((SubtitleEntry) -> Void)?
    /// 状态文案变化（主线程）
    var onStatus: ((String) -> Void)?

    private let store = SessionStore()
    private var task: Task<Void, Never>?
    private var sessionCount = 0

    var sessionStore: SessionStore { store }

    func start(selection: ScreenSelection, interval: Duration = .milliseconds(400)) {
        guard !isRunning else { return }
        isRunning = true
        onStatus?("正在启动采集…")

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let capture = try await CaptureSession(selection: selection, interval: interval)
                let session = try await MainActor.run {
                    try self.store.createSession(selection: selection)
                }
                await MainActor.run { self.currentSession = session }

                let g = capture.geometry
                await self.report(String(
                    format: "采集已开始 · 区域 %.0f×%.0f 点 → %d×%d 像素（%.2fx）",
                    g.selection.width, g.selection.height,
                    g.outputWidth, g.outputHeight, g.scale))

                var assembler = SubtitleAssembler()
                var skipped = 0
                var ocrCount = 0

                while !Task.isCancelled {
                    if let frame = try await capture.nextFrame() {
                        ocrCount += 1
                        for entry in assembler.consume(frame) {
                            try session.append(entry)
                            await MainActor.run { self.onEntry?(entry) }
                        }
                    } else {
                        skipped += 1
                    }
                    try await capture.waitForNextPoll()
                }

                // 停下时把没定稿的那句吐出来
                for entry in assembler.flush() {
                    try session.append(entry)
                    await MainActor.run { self.onEntry?(entry) }
                }
                session.close()

                let entries = session.loadEntries()
                await self.report("已停止 · 识别 \(ocrCount) 帧 / 跳过 \(skipped) 帧静止画面 · 沉淀 \(entries.count) 句")

            } catch {
                await self.report("采集出错：\(error)")
            }
            await MainActor.run {
                self.isRunning = false
                self.task = nil
                self.currentSession = nil
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        task?.cancel()
    }

    private func report(_ text: String) {
        onStatus?(text)
    }
}
