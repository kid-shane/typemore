import Carbon.HIToolbox
import Foundation

/// 自定义组合键触发器（例如 ⌃⌥R）。
///
/// 用 Carbon `RegisterEventHotKey` 注册全局热键，而不是 CGEventTap：热键会被系统正常
/// 消费，不会有多余字符落到当前输入框；且无需输入监控权限即可命中（真正的改写流程仍需
/// 辅助功能权限来发送复制/粘贴）。对状态栏 / accessory 应用同样有效。
@MainActor
final class ChordHotKeyTrigger {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var callback: (() -> Void)?

    // 'TMHK' —— Typemore HotKey。四字符签名，用于区分本应用注册的热键。
    private let signature: OSType = 0x544D_484B

    func start(chord: TriggerChord, callback: @escaping () -> Void) throws {
        stop()
        guard chord.hasModifier else { throw TriggerError.invalidChord }
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userInfo -> OSStatus in
                guard let userInfo else { return noErr }
                let trigger = Unmanaged<ChordHotKeyTrigger>.fromOpaque(userInfo).takeUnretainedValue()
                // Carbon 事件在主线程分发；跳到 MainActor 以满足隔离要求。
                Task { @MainActor in trigger.fire() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            stop()
            throw TriggerError.registrationFailed
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(chord.keyCode),
            chord.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr, hotKeyRef != nil else {
            stop()
            throw TriggerError.registrationFailed
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        callback = nil
    }

    private func fire() {
        callback?()
    }
}

extension TriggerChord {
    /// Carbon `RegisterEventHotKey` 所需的修饰键位掩码。
    var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
