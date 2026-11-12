import Foundation

/// 统一的润色触发器：根据用户配置在「双击右 Option」与「自定义组合键」之间切换。
///
/// 对外暴露一个 `apply(trigger:)` 入口，方便设置保存后热更新绑定，而无需重建整个应用状态。
/// 内部持有两种底层实现，任一时刻只有一种处于激活状态。
@MainActor
final class RewriteTriggerCoordinator {
    private let doubleTap = RightOptionDoubleTapTrigger()
    private let chord = ChordHotKeyTrigger()
    private var callback: (() -> Void)?
    private(set) var current: RewriteTrigger = .default

    /// 应用一个触发配置。首次调用需传入 callback；后续热更新可省略，沿用上次的 callback。
    func apply(trigger: RewriteTrigger, callback: (() -> Void)? = nil) throws {
        if let callback { self.callback = callback }
        guard let fire = self.callback else { return }

        // 先停掉全部，避免两种触发器同时存在。
        doubleTap.stop()
        chord.stop()

        switch trigger {
        case .doubleTapRightOption:
            try doubleTap.start(callback: fire)
        case .chord(let chord):
            try self.chord.start(chord: chord, callback: fire)
        }
        current = trigger
    }

    func stop() {
        doubleTap.stop()
        chord.stop()
        callback = nil
    }

    /// 暂停底层监听但保留回调与当前配置。用于录制自定义快捷键时，避免已注册的 Carbon 热键
    /// 抢先消费按键或误触发改写。
    func pause() {
        doubleTap.stop()
        chord.stop()
    }

    /// 恢复到 `current` 配置（沿用已保存的回调）。best-effort，失败仅记录日志。
    func resume() {
        do {
            try apply(trigger: current)
        } catch {
            TMLog.write("trigger resume failed: \(error.localizedDescription)")
        }
    }
}
