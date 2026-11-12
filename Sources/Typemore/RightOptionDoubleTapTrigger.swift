import Foundation
import CoreGraphics

@MainActor
final class RightOptionDoubleTapTrigger {
    private let rightOptionKeyCode: CGKeyCode = 61
    private let doubleTapInterval: TimeInterval = 0.35
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastTapAt: Date?
    private var isRightOptionDown = false
    private var shouldFireOnKeyUp = false
    private var callback: (() -> Void)?

    func start(callback: @escaping () -> Void) throws {
        stop()
        self.callback = callback

        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            throw TriggerError.inputMonitoringRequired
        }

        let mask = 1 << CGEventType.flagsChanged.rawValue
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, userInfo in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let userInfo {
                        let trigger = Unmanaged<RightOptionDoubleTapTrigger>.fromOpaque(userInfo).takeUnretainedValue()
                        Task { @MainActor in
                            trigger.enableEventTap()
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .flagsChanged, let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let trigger = Unmanaged<RightOptionDoubleTapTrigger>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                Task { @MainActor in
                    trigger.handleFlagsChanged(keyCode: keyCode, flags: event.flags)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            throw TriggerError.registrationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        callback = nil
        lastTapAt = nil
        isRightOptionDown = false
        shouldFireOnKeyUp = false
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard keyCode == rightOptionKeyCode else { return }
        let isDown = flags.contains(.maskAlternate)
        guard isDown != isRightOptionDown else { return }
        isRightOptionDown = isDown

        if isDown {
            let now = Date()
            if let lastTapAt, now.timeIntervalSince(lastTapAt) <= doubleTapInterval {
                self.lastTapAt = nil
                shouldFireOnKeyUp = true
            } else {
                lastTapAt = now
            }
            return
        }

        guard shouldFireOnKeyUp else { return }
        shouldFireOnKeyUp = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.callback?()
        }
    }

    private func enableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }
}

enum TriggerError: LocalizedError {
    case registrationFailed
    case inputMonitoringRequired
    case invalidChord

    var errorDescription: String? {
        switch self {
        case .registrationFailed: return "触发键监听注册失败，请确认已开启输入监控权限，或换一个组合键"
        case .inputMonitoringRequired: return "需要开启 macOS 输入监控权限"
        case .invalidChord: return "自定义组合键至少需要一个修饰键（⌃⌥⇧⌘）"
        }
    }
}
