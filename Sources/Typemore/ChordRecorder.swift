import AppKit
import Foundation

/// 录制自定义组合键的控制器。
///
/// 录制期间在设置窗口内安装一个「本地事件监听」（`addLocalMonitorForEvents`），只捕获当前
/// key window 的按键，因此不需要额外的输入监控权限，也不会把按键漏给下层控件。状态以
/// `@Published` 暴露；窗口控制器同步暂停/恢复触发器，视图通过 onFinish 提交或恢复草稿。
@MainActor
final class ChordRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// 录制时实时按下的修饰键，用于给出「⌃⌥…」的即时预览。
    @Published private(set) var liveModifiers: [TriggerModifier] = []
    /// 最近一次成功录制的组合键；结束回调写回 draft。
    @Published private(set) var recordedChord: TriggerChord?
    @Published var errorHint: String?
    var onFinish: ((TriggerChord?) -> Void)?

    private var monitor: Any?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        errorHint = nil
        liveModifiers = []
        // 置空上一次结果：取消时不误提交上一次录制值。
        recordedChord = nil
        // 本地事件监听在主线程同步回调；提取 Sendable 基本量后再进入 MainActor，
        // 避免把 NSEvent 跨隔离边界传递。返回 nil 表示吞掉事件（不落到界面控件）。
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let type = event.type
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let swallow = MainActor.assumeIsolated {
                self.handle(type: type, keyCode: keyCode, flags: flags, characters: characters)
            }
            return swallow ? nil : event
        }
    }

    func cancel() {
        finish()
    }

    private func finish() {
        guard isRecording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        liveModifiers = []
        errorHint = nil
        onFinish?(recordedChord)
    }

    /// 处理一次录制事件。返回 true 表示吞掉该事件。
    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        switch type {
        case .flagsChanged:
            liveModifiers = Self.modifiers(from: flags)
            return true
        case .keyDown:
            // Esc 取消录制。
            if keyCode == 53 {
                finish()
                return true
            }
            let modifiers = Self.modifiers(from: flags)
            guard !modifiers.isEmpty else {
                errorHint = "组合键需要至少一个修饰键（⌃⌥⇧⌘）"
                return true
            }
            let chord = TriggerChord(
                modifiers: modifiers,
                keyCode: keyCode,
                keyLabel: Self.keyLabel(keyCode: keyCode, characters: characters)
            )
            recordedChord = chord
            finish()
            return true
        default:
            return false
        }
    }

    /// 按 macOS 习惯顺序（⌃⌥⇧⌘）解析修饰键。
    private static func modifiers(from flags: NSEvent.ModifierFlags) -> [TriggerModifier] {
        var result: [TriggerModifier] = []
        if flags.contains(.control) { result.append(.control) }
        if flags.contains(.option) { result.append(.option) }
        if flags.contains(.shift) { result.append(.shift) }
        if flags.contains(.command) { result.append(.command) }
        return result
    }

    /// 主键的展示名。特殊键走键码表，其余用去修饰后的字符并大写。
    private static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyLabels[keyCode] {
            return special
        }
        let trimmed = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed.uppercased()
        }
        return "Key\(keyCode)"
    }

    private static let specialKeyLabels: [UInt16: String] = [
        49: "Space",
        36: "Return",
        48: "Tab",
        51: "Delete",
        117: "Fwd Delete",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
        115: "Home",
        119: "End",
        116: "Page Up",
        121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}
