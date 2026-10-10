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

                // 取消不是故障。这个循环里**唯一的取消检查点**是下面那个
                // `waitForNextPoll()` 里的 `Task.sleep`——`capture()` 和 OCR 都不查取消。
                // 所以点「停止采集」时，取消**必然**落在 sleep 上、必然抛错，
                // `while !Task.isCancelled` 那条正常出口几乎永远走不到。
                //
                // 之前这里是裸的 `try await`，那个错一路逃到最外层 catch，
                // 于是每次停止都报「采集出错：CancellationError()」，
                // 而且**收尾整段被跳过**——`flush()` 吐不出最后那句没定稿的字幕。
                // 实测：连点 5 次停止，5 次都报错、5 次都丢最后一句。
                var failure: Error?
                while !Task.isCancelled {
                    do {
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
                    } catch {
                        // 被取消时不管抛的是什么，都是「正常停止」
                        if !Task.isCancelled { failure = error }
                        break
                    }
                }

                // 收尾：**正常停止和出错两条路都要走到这里**。
                // 把没定稿的那句吐出来，再关掉文件句柄。
                for entry in assembler.flush() {
                    try session.append(entry)
                    await MainActor.run { self.onEntry?(entry) }
                }
                session.close()

                if let failure {
                    await self.report("采集出错：\(failure)")
                } else {
                    let entries = session.loadEntries()
                    await self.report("已停止 · 识别 \(ocrCount) 帧 / 跳过 \(skipped) 帧静止画面 · 沉淀 \(entries.count) 句")
                }

            } catch {
                // 走到这里的是循环**外面**的失败：建会话、开采集等
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
