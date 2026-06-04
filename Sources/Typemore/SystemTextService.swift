import AppKit
import ApplicationServices

enum TMLog {
    private static let queue = DispatchQueue(label: "com.typemore.diaglog")
    private static let maxLogBytes: UInt64 = 512 * 1024
    private static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Typemore.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            rotateIfNeeded()
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let data = line.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    static func boot(_ message: String) {
        write("=== boot === \(message)")
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size > maxLogBytes else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}

struct CaptureResult {
    let sessionID: Int
    let text: String
    let contextBefore: String
    let contextAfter: String
    let replacementRange: NSRange?
    let sourceBundleID: String?
    let previousClipboard: ClipboardSnapshot
}

struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        self.items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []
    }

    var stringValue: String {
        for item in items {
            if let data = item[.string], let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return ""
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems = items.map { storedItem in
            let item = NSPasteboardItem()
            for (type, data) in storedItem {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}

@MainActor
final class SystemTextService {
    private let keyboardAllSelectionMaxCharacters = 3_000
    private var nextSessionID = 0

    func captureText(onCopySent: @escaping (Int) -> Void) async throws -> CaptureResult {
        nextSessionID += 1
        let sessionID = nextSessionID
        let pasteboard = NSPasteboard.general
        let previousClipboard = ClipboardSnapshot(pasteboard: pasteboard)
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let trusted = AXIsProcessTrusted()
        TMLog.write("capture#\(sessionID) start bundle=\(sourceBundleID ?? "nil") trusted=\(trusted) prevClipboardLen=\(previousClipboard.stringValue.count)")

        let focusedDiag = await readFocusedTextDiagnosticWithRetry(sessionID: sessionID)
        TMLog.write("capture#\(sessionID) ax: source=\(focusedDiag.focusedSource ?? "nil") frontmost=\(focusedDiag.frontmostBundleID ?? "nil") pid=\(focusedDiag.frontmostPID) lookup=\(focusedDiag.focusLookup) attr=\(focusedDiag.attributeLookup) focusedOK=\(focusedDiag.focusedOK) role=\(focusedDiag.role ?? "nil") subrole=\(focusedDiag.subrole ?? "nil") valueOK=\(focusedDiag.valueOK) valueLen=\(focusedDiag.valueLen) selRangeOK=\(focusedDiag.selRangeOK) selLoc=\(focusedDiag.selLocation) selLen=\(focusedDiag.selLength)")

        if let focusedText = focusedDiag.focused, let capture = buildAXCapture(
            focusedText: focusedText,
            sessionID: sessionID,
            sourceBundleID: sourceBundleID,
            previousClipboard: previousClipboard
        ) {
            TMLog.write("capture#\(sessionID) ax-path: targetLen=\(capture.text.count) ctxBefore=\(capture.contextBefore.count) ctxAfter=\(capture.contextAfter.count) range=\(String(describing: capture.replacementRange))")
            onCopySent(sessionID)
            return capture
        }
        TMLog.write("capture#\(sessionID) ax-path: not usable, fallback to Cmd+C")

        let sentinel = "__TYPEMORE_EMPTY_\(Date().timeIntervalSince1970)__"

        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        let sentinelChangeCount = pasteboard.changeCount

        do {
            try await sendCommandKeystroke("c")
            onCopySent(sessionID)
            TMLog.write("capture#\(sessionID) cmd+c posted")
        } catch {
            TMLog.write("capture#\(sessionID) cmd+c failed: \(error.localizedDescription)")
            previousClipboard.restore()
            throw accessibilityError(error)
        }

        let waited = (try? await waitForCopiedText(sentinel: sentinel, sentinelChangeCount: sentinelChangeCount)) ?? ""
        let fallbackSel = readFocusedSelectedTextFallback()?.trimmedSelection ?? ""
        var copiedText = waited.trimmedSelection.ifEmpty(fallbackSel)
        TMLog.write("capture#\(sessionID) copied chars=\(copiedText.count) waitedChars=\(waited.count) fallbackSelChars=\(fallbackSel.count)")

        if copiedText.isEmpty || copiedText == sentinel {
            if shouldTryFocusedAllSelectionFallback(for: sourceBundleID) {
                do {
                    copiedText = try await copyFocusedEditableContentViaKeyboard(
                        sessionID: sessionID,
                        maxCharacters: keyboardAllSelectionMaxCharacters
                    )
                } catch {
                    previousClipboard.restore()
                    throw error
                }
            }
            if copiedText.isEmpty, shouldTryLineSelectionFallback(for: sourceBundleID) {
                copiedText = (try? await copyCurrentLineViaKeyboard(sessionID: sessionID)) ?? ""
            }
        }
        previousClipboard.restore()

        guard !copiedText.isEmpty, copiedText != sentinel else {
            TMLog.write("capture#\(sessionID) noSelectedText after fallback")
            throw TypemoreError.noSelectedText
        }

        return CaptureResult(
            sessionID: sessionID,
            text: copiedText,
            contextBefore: "",
            contextAfter: "",
            replacementRange: nil,
            sourceBundleID: sourceBundleID,
            previousClipboard: previousClipboard
        )
    }

    func paste(_ text: String, into bundleID: String?, replacementRange: NSRange?, previousClipboard: ClipboardSnapshot) async throws {
        TMLog.write("paste start bundle=\(bundleID ?? "nil") textLen=\(text.count) range=\(String(describing: replacementRange))")
        if let bundleID {
            try await activateIfNeeded(bundleID: bundleID)
        }

        if let replacementRange {
            do {
                try setFocusedSelectedRange(replacementRange)
                TMLog.write("paste: setFocusedSelectedRange ok loc=\(replacementRange.location) len=\(replacementRange.length)")
            } catch {
                TMLog.write("paste: setFocusedSelectedRange failed: \(error.localizedDescription)")
                throw error
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        do {
            try await sendCommandKeystroke("v")
            TMLog.write("paste: cmd+v posted")
            try await Task.sleep(nanoseconds: 90_000_000)
        } catch {
            TMLog.write("paste: cmd+v failed: \(error.localizedDescription)")
            throw accessibilityError(error)
        }

        previousClipboard.restore()
        TMLog.write("paste end")
    }

    func undo(in bundleID: String?) async throws {
        TMLog.write("undo start bundle=\(bundleID ?? "nil")")
        if let bundleID {
            try await activateIfNeeded(bundleID: bundleID)
        }
        do {
            try await sendCommandKeystroke("z")
            try await Task.sleep(nanoseconds: 80_000_000)
            TMLog.write("undo: cmd+z posted")
        } catch {
            TMLog.write("undo: cmd+z failed: \(error.localizedDescription)")
            throw accessibilityError(error)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func requestAccessibilityAccessIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func waitForCopiedText(sentinel: String, sentinelChangeCount: Int) async throws -> String {
        let pasteboard = NSPasteboard.general
        let maxAttempts = 28
        for attempt in 0..<maxAttempts {
            if pasteboard.changeCount != sentinelChangeCount {
                let value = pasteboard.string(forType: .string) ?? ""
                if !value.isEmpty, value != sentinel {
                    return value
                }
            }
            let delay = attempt < 8 ? 20_000_000 : 35_000_000
            try await Task.sleep(nanoseconds: UInt64(delay))
        }
        return pasteboard.string(forType: .string) ?? ""
    }

    private func activate(bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate(options: [.activateIgnoringOtherApps])
    }

    private func activateIfNeeded(bundleID: String) async throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID else { return }
        activate(bundleID: bundleID)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func sendCommandKeystroke(_ key: String) async throws {
        try await sendKeystroke(key, flags: .maskCommand)
    }

    private func sendKeystroke(_ key: String, flags: CGEventFlags = []) async throws {
        guard AXIsProcessTrusted() else {
            throw TypemoreError.accessibilityRequired
        }
        guard let keyCode = keyCode(for: key) else {
            throw TypemoreError.appleScript("Unsupported shortcut key: \(key)")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 25_000_000)
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "a": return 0
        case "c": return 8
        case "v": return 9
        case "z": return 6
        case "left": return 123
        case "right": return 124
        default: return nil
        }
    }

    private func shouldTryLineSelectionFallback(for bundleID: String?) -> Bool {
        true
    }

    private func shouldTryFocusedAllSelectionFallback(for bundleID: String?) -> Bool {
        true
    }

    private func copyFocusedEditableContentViaKeyboard(sessionID: Int, maxCharacters: Int) async throws -> String {
        let pasteboard = NSPasteboard.general
        let sentinel = "__TYPEMORE_ALL_EMPTY_\(Date().timeIntervalSince1970)__"
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        let sentinelChangeCount = pasteboard.changeCount

        TMLog.write("capture#\(sessionID) all-select fallback start max=\(maxCharacters)")
        try await sendCommandKeystroke("a")
        try await Task.sleep(nanoseconds: 55_000_000)
        try await sendCommandKeystroke("c")

        let copied = (try? await waitForCopiedText(sentinel: sentinel, sentinelChangeCount: sentinelChangeCount)) ?? ""
        let trimmed = copied.trimmedSelection
        TMLog.write("capture#\(sessionID) all-select fallback copied chars=\(trimmed.count) rawChars=\(copied.count)")
        guard trimmed != sentinel else { return "" }
        guard trimmed.count <= maxCharacters else {
            TMLog.write("capture#\(sessionID) all-select fallback tooLong chars=\(trimmed.count) max=\(maxCharacters)")
            try? await sendKeystroke("right")
            throw TypemoreError.inputTooLong(maxCharacters)
        }
        return trimmed
    }

    private func copyCurrentLineViaKeyboard(sessionID: Int) async throws -> String {
        let pasteboard = NSPasteboard.general
        let sentinel = "__TYPEMORE_LINE_EMPTY_\(Date().timeIntervalSince1970)__"
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        let sentinelChangeCount = pasteboard.changeCount

        TMLog.write("capture#\(sessionID) line-select fallback start")
        try await sendKeystroke("left", flags: .maskCommand)
        try await Task.sleep(nanoseconds: 35_000_000)
        try await sendKeystroke("right", flags: [.maskCommand, .maskShift])
        try await Task.sleep(nanoseconds: 35_000_000)
        try await sendCommandKeystroke("c")

        let copied = (try? await waitForCopiedText(sentinel: sentinel, sentinelChangeCount: sentinelChangeCount)) ?? ""
        let trimmed = copied.trimmedSelection
        TMLog.write("capture#\(sessionID) line-select fallback copied chars=\(trimmed.count) rawChars=\(copied.count)")
        return trimmed == sentinel ? "" : trimmed
    }

    private func readFocusedText() -> FocusedText? {
        readFocusedTextDiagnostic().focused
    }

    private func readFocusedTextDiagnosticWithRetry(sessionID: Int) async -> FocusedDiagnostic {
        // 先尝试唤醒 frontmost 应用的 AX 树（针对 Chromium / Electron 这类懒加载 a11y 的应用）
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 0 {
            wakeUpAccessibility(pid: pid, sessionID: sessionID)
        }
        let delays: [UInt64] = [0, 30_000_000, 50_000_000, 70_000_000, 90_000_000, 120_000_000]
        var last = FocusedDiagnostic()
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            let diag = readFocusedTextDiagnostic()
            last = diag
            if diag.focused != nil {
                if attempt > 0 {
                    TMLog.write("capture#\(sessionID) ax retry recovered attempt=\(attempt + 1)")
                }
                return diag
            }
            TMLog.write("capture#\(sessionID) ax retry attempt=\(attempt + 1) frontmost=\(diag.frontmostBundleID ?? "nil") source=\(diag.focusedSource ?? "nil") lookup=\(diag.focusLookup) attr=\(diag.attributeLookup) focusedOK=\(diag.focusedOK) valueOK=\(diag.valueOK) selRangeOK=\(diag.selRangeOK)")
        }
        return last
    }

    /// 唤醒 Chromium / Electron 类应用的 a11y 树。这些应用默认不向 macOS 暴露 AX 树，
    /// 必须收到 AXManualAccessibility 或 AXEnhancedUserInterface 信号后才会构建。
    private func wakeUpAccessibility(pid: pid_t, sessionID: Int) {
        let appAX = AXUIElementCreateApplication(pid)
        let manualStatus = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhancedStatus = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        TMLog.write("capture#\(sessionID) ax-wakeup pid=\(pid) manual=\(describeAXError(manualStatus)) enhanced=\(describeAXError(enhancedStatus))")
    }

    private func readFocusedTextDiagnostic() -> FocusedDiagnostic {
        var diag = FocusedDiagnostic()
        guard AXIsProcessTrusted() else { return diag }

        let frontmost = NSWorkspace.shared.frontmostApplication
        diag.frontmostBundleID = frontmost?.bundleIdentifier
        diag.frontmostPID = frontmost?.processIdentifier ?? -1

        // 主路径：systemWide -> focused element
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        var focusedAX: AXUIElement?
        let systemWideStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        var focusedAppStatus: AXError?
        var focusedAppElementStatus: AXError?
        var appPIDStatus: AXError?
        if systemWideStatus == .success,
           let focusedElement,
           CFGetTypeID(focusedElement) == AXUIElementGetTypeID() {
            focusedAX = (focusedElement as! AXUIElement)
            diag.focusedSource = "systemWide"
        } else {
            // 兜底：先通过 systemWide 拿 focused application，再问该 app 的 focused element。
            // 这和 NSWorkspace.frontmostApplication 不完全等价，某些场景里前台 app 与键盘输入接收方会短暂不同步。
            var focusedApp: CFTypeRef?
            let appStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
            focusedAppStatus = appStatus
            if appStatus == .success,
               let focusedApp,
               CFGetTypeID(focusedApp) == AXUIElementGetTypeID() {
                var fromFocusedApp: CFTypeRef?
                let elementStatus = AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &fromFocusedApp)
                focusedAppElementStatus = elementStatus
                if elementStatus == .success,
                   let fromFocusedApp,
                   CFGetTypeID(fromFocusedApp) == AXUIElementGetTypeID() {
                    focusedAX = (fromFocusedApp as! AXUIElement)
                    diag.focusedSource = "focusedApp"
                }
            }
        }

        if focusedAX == nil, let pid = frontmost?.processIdentifier, pid > 0 {
            // 兜底：直接通过 frontmost app PID 拿 focused
            let appAX = AXUIElementCreateApplication(pid)
            var fromApp: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &fromApp)
            appPIDStatus = status
            if status == .success,
               let fromApp,
               CFGetTypeID(fromApp) == AXUIElementGetTypeID() {
                focusedAX = (fromApp as! AXUIElement)
                diag.focusedSource = "appPID"
            }
        }
        diag.focusLookup = "systemWide=\(describeAXError(systemWideStatus));focusedApp=\(describeOptionalAXError(focusedAppStatus));focusedAppElement=\(describeOptionalAXError(focusedAppElementStatus));appPID=\(describeOptionalAXError(appPIDStatus))"

        guard let element = focusedAX else { return diag }
        diag.focusedOK = true

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success {
            diag.role = roleValue as? String
        }
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success {
            diag.subrole = subroleValue as? String
        }

        var value: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard valueStatus == .success,
              let text = value as? String else {
            diag.attributeLookup = "value=\(describeAXError(valueStatus))"
            return diag
        }
        diag.valueOK = true
        diag.valueLen = (text as NSString).length

        var selectedRangeValue: CFTypeRef?
        let selectedRangeStatus = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)
        guard selectedRangeStatus == .success,
              let selectedRangeAX = selectedRangeValue else {
            diag.attributeLookup = "value=\(describeAXError(valueStatus));selectedRange=\(describeAXError(selectedRangeStatus))"
            return diag
        }
        var cfRange = CFRange()
        guard CFGetTypeID(selectedRangeAX) == AXValueGetTypeID(),
              AXValueGetValue(selectedRangeAX as! AXValue, .cfRange, &cfRange) else {
            return diag
        }
        diag.selRangeOK = true
        diag.selLocation = cfRange.location
        diag.selLength = cfRange.length
        diag.attributeLookup = "value=\(describeAXError(valueStatus));selectedRange=\(describeAXError(selectedRangeStatus))"
        diag.focused = FocusedText(
            text: text,
            selectedRange: NSRange(location: cfRange.location, length: cfRange.length)
        )
        return diag
    }

    private func readFocusedSelectedTextFallback() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        var selectedText: CFTypeRef?
        let element = focusedElement as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success else {
            return nil
        }
        return selectedText as? String
    }

    private func buildAXCapture(
        focusedText: FocusedText,
        sessionID: Int,
        sourceBundleID: String?,
        previousClipboard: ClipboardSnapshot
    ) -> CaptureResult? {
        let nsText = focusedText.text as NSString
        let textLength = nsText.length
        guard textLength > 0 else { return nil }

        let selectedRange = clampedRange(focusedText.selectedRange, in: textLength)
        let targetRange: NSRange
        if let selectedRange, selectedRange.length > 0 {
            targetRange = trimWhitespace(in: selectedRange, text: nsText)
        } else {
            let cursor = min(max(selectedRange?.location ?? textLength, 0), textLength)
            targetRange = trimWhitespace(in: nearbyParagraphRange(cursor: cursor, text: nsText), text: nsText)
        }

        guard targetRange.length > 0 else { return nil }
        let targetText = nsText.substring(with: targetRange).trimmedSelection
        guard !targetText.isEmpty else { return nil }

        let contextBeforeStart = max(0, targetRange.location - 500)
        let contextBeforeRange = NSRange(location: contextBeforeStart, length: targetRange.location - contextBeforeStart)
        let targetEnd = targetRange.location + targetRange.length
        let contextAfterEnd = min(textLength, targetEnd + 300)
        let contextAfterRange = NSRange(location: targetEnd, length: contextAfterEnd - targetEnd)

        return CaptureResult(
            sessionID: sessionID,
            text: targetText,
            contextBefore: nsText.substring(with: contextBeforeRange),
            contextAfter: nsText.substring(with: contextAfterRange),
            replacementRange: targetRange,
            sourceBundleID: sourceBundleID,
            previousClipboard: previousClipboard
        )
    }

    private func nearbyParagraphRange(cursor: Int, text: NSString) -> NSRange {
        let textLength = text.length
        let windowStart = max(0, cursor - 500)
        let windowEnd = min(textLength, cursor + 300)
        var start = cursor
        while start > windowStart, !isNewline(text.character(at: start - 1)) {
            start -= 1
        }
        var end = cursor
        while end < windowEnd, !isNewline(text.character(at: end)) {
            end += 1
        }
        if start == end {
            return NSRange(location: windowStart, length: windowEnd - windowStart)
        }
        return NSRange(location: start, length: end - start)
    }

    private func clampedRange(_ range: NSRange, in textLength: Int) -> NSRange? {
        guard range.location >= 0, range.location <= textLength else { return nil }
        let length = max(0, min(range.length, textLength - range.location))
        return NSRange(location: range.location, length: length)
    }

    private func trimWhitespace(in range: NSRange, text: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, isWhitespace(text.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private func setFocusedSelectedRange(_ range: NSRange) throws {
        guard AXIsProcessTrusted() else {
            throw TypemoreError.accessibilityRequired
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            throw TypemoreError.noSelectedText
        }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            throw TypemoreError.noSelectedText
        }
        let element = focusedElement as! AXUIElement
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        guard status == .success else {
            throw TypemoreError.noSelectedText
        }
    }

    private func isWhitespace(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(value)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func isNewline(_ value: unichar) -> Bool {
        value == 10 || value == 13 || value == 0x2028 || value == 0x2029
    }

    private func accessibilityError(_ error: Error) -> Error {
        let message = String(describing: error)
        if message.contains("not allowed assistive access") || message.contains("System Events") {
            return TypemoreError.accessibilityRequired
        }
        return error
    }

    private func describeOptionalAXError(_ error: AXError?) -> String {
        guard let error else { return "notTried" }
        return describeAXError(error)
    }

    private func describeAXError(_ error: AXError) -> String {
        let name: String
        switch error {
        case .success: name = "success"
        case .failure: name = "failure"
        case .illegalArgument: name = "illegalArgument"
        case .invalidUIElement: name = "invalidUIElement"
        case .invalidUIElementObserver: name = "invalidUIElementObserver"
        case .cannotComplete: name = "cannotComplete"
        case .attributeUnsupported: name = "attributeUnsupported"
        case .actionUnsupported: name = "actionUnsupported"
        case .notificationUnsupported: name = "notificationUnsupported"
        case .notImplemented: name = "notImplemented"
        case .notificationAlreadyRegistered: name = "notificationAlreadyRegistered"
        case .notificationNotRegistered: name = "notificationNotRegistered"
        case .apiDisabled: name = "apiDisabled"
        case .noValue: name = "noValue"
        case .parameterizedAttributeUnsupported: name = "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: name = "notEnoughPrecision"
        @unknown default: name = "unknown"
        }
        return "\(name)(\(error.rawValue))"
    }
}

private struct FocusedText {
    let text: String
    let selectedRange: NSRange
}

private struct FocusedDiagnostic {
    var focusedOK = false
    var focusedSource: String?
    var frontmostBundleID: String?
    var frontmostPID: Int32 = -1
    var focusLookup = "notTried"
    var attributeLookup = "notTried"
    var role: String?
    var subrole: String?
    var valueOK = false
    var valueLen: Int = 0
    var selRangeOK = false
    var selLocation: Int = -1
    var selLength: Int = -1
    var focused: FocusedText?
}

private extension String {
    var trimmedSelection: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

enum TypemoreError: LocalizedError {
    case noSelectedText
    case accessibilityRequired
    case appleScript(String)
    case inputTooLong(Int)
    case invalidModelResponse
    case reasoningOnlyModelResponse

    var errorDescription: String? {
        switch self {
        case .noSelectedText: return "没有检测到选中文字"
        case .accessibilityRequired: return "需要开启 macOS 辅助功能权限"
        case .appleScript(let message): return message
        case .inputTooLong(let maxCharacters): return "当前输入框内容超过 \(maxCharacters) 字，请手动选中要改写的部分"
        case .invalidModelResponse: return "模型没有返回可用文本"
        case .reasoningOnlyModelResponse: return "模型只返回了思考内容，请关闭思考/推理模式或选择非思考模型后重试"
        }
    }
}
