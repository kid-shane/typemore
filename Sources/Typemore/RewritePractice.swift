import AppKit
import SwiftUI

/// 练习只持有窗口内的临时文本，不依赖模型、系统文本服务或剪贴板。
@MainActor
final class RewritePracticeModel: ObservableObject {
    enum Phase {
        case ready, running, done, stopped, empty
    }

    static let sample = "这个事情我想了一下，还是觉得我们可以先试试看，看看效果怎么样，然后再决定要不要继续。"
    static let sampleResult = "我建议先试一试，根据效果再决定是否继续。"

    @Published private(set) var text = sample
    @Published var selection = NSRange(location: 0, length: 0)
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var hasCompleted = false
    @Published var isFocused = false
    @Published private(set) var isCollapsed = false
    private var original: (text: String, selection: NSRange)?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var lastStartedAt: TimeInterval = -.infinity

    var isRunning: Bool { phase == .running }
    var canUndo: Bool { original != nil && !isRunning }

    func edit(_ newText: String, selection: NSRange) {
        cancel()
        text = newText
        self.selection = selection
        original = nil
        phase = .ready
    }

    func start() {
        let now = ProcessInfo.processInfo.systemUptime
        // 本地按键与全局热键可能收到同一次触发，防止启动两轮演示。
        guard !isRunning, now - lastStartedAt > 0.4 else { return }
        let source = text as NSString
        let range = selection.length > 0 && NSMaxRange(selection) <= source.length
            ? selection : NSRange(location: 0, length: source.length)
        let target = source.substring(with: range)
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .empty
            return
        }
        lastStartedAt = now
        let sourceText = text
        let sourceSelection = selection
        let id = UUID()
        operationID = id
        original = nil
        phase = .running
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 650_000_000) }
            catch { return }
            guard let self, self.operationID == id, self.text == sourceText else { return }
            let result = Self.simulatedRewrite(target)
            self.original = result != target ? (sourceText, sourceSelection) : nil
            self.text = source.replacingCharacters(in: range, with: result)
            self.selection = NSRange(location: range.location + (result as NSString).length, length: 0)
            self.phase = .done
            self.hasCompleted = true
            self.operationID = nil
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        operationID = nil
        if isRunning { phase = .stopped }
    }

    func undo() {
        guard let original else { return }
        cancel()
        text = original.text
        selection = original.selection
        self.original = nil
        phase = .ready
    }

    func reset() {
        cancel()
        text = Self.sample
        selection = NSRange(location: 0, length: 0)
        original = nil
        phase = .ready
        hasCompleted = false
        isCollapsed = false
        lastStartedAt = -.infinity
    }

    func collapse() {
        cancel()
        isCollapsed = true
    }

    /// 固定示例展示完整效果；用户编辑的内容仅做简单本地整理，不冒充真实模型输出。
    private static func simulatedRewrite(_ input: String) -> String {
        if input.trimmingCharacters(in: .whitespacesAndNewlines) == sample { return sampleResult }
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let substitutions = [
            ("这个事情我想了一下，", "我考虑后，"),
            ("还是觉得我们可以", "建议"),
            ("先试试看", "先试一试"),
            ("看看效果怎么样", "观察效果"),
            ("然后再决定要不要继续", "再决定是否继续"),
            ("我想请你帮忙", "请"),
            ("可能也许", "也许"),
            ("然后然后", "然后")
        ]
        for (before, after) in substitutions { result = result.replacingOccurrences(of: before, with: after) }
        result = result.replacingOccurrences(of: "[\\t ]{2,}", with: " ", options: .regularExpression)
        return result
    }
}

struct RewritePracticeView: View {
    @ObservedObject var model: RewritePracticeModel
    let trigger: RewriteTrigger
    let isRecording: Bool

    private var instruction: String {
        switch trigger {
        case .doubleTapRightOption: return "双击右 Option 试试 · 本地模拟"
        case .chord: return "按 \(trigger.displayText) 试试 · 本地模拟"
        }
    }

    private var hint: String {
        if isRecording { return "快捷键录制中…" }
        switch model.phase {
        case .running: return "模拟润色中…"
        case .done: return model.canUndo ? "已替换 · 本地模拟" : "已完成 · 本地模拟"
        case .stopped: return "已停止"
        case .empty: return "先输入一点文字"
        case .ready:
            return model.hasCompleted ? "本地模拟" : instruction
        }
    }

    var body: some View {
        Group {
            if model.isCollapsed {
                HStack {
                    Text("模拟练习")
                        .foregroundStyle(UITheme.secondary)
                    Spacer()
                    practiceButton("再试一次", action: model.reset)
                }
                .font(.system(size: 11))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text("在这里输入文字…")
                                .font(.system(size: 13))
                                .foregroundStyle(UITheme.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .allowsHitTesting(false)
                        }
                        RewritePracticeEditor(model: model, trigger: trigger, isRecording: isRecording)
                    }
                    .frame(height: 90)
                    .background(UITheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(model.isFocused ? UITheme.accent.opacity(0.65) : UITheme.border, lineWidth: 1)
                    )
                    HStack(spacing: 12) {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(UITheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if model.isRunning {
                            practiceButton("停止", action: model.cancel)
                        } else {
                            if model.canUndo {
                                practiceButton("撤回", symbol: .undo, action: model.undo)
                            }
                            practiceButton("重试", action: model.reset)
                        }
                        practiceButton("收起", action: model.collapse)
                    }
                    .frame(minHeight: 24)
                }
            }
        }
        .onChange(of: isRecording) { recording in
            if recording { model.cancel() }
        }
        .onDisappear { model.cancel() }
    }

    private func practiceButton(_ title: String, symbol: AppSymbol? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { AppIcon(symbol: symbol, size: .small) }
                Text(title)
            }
            .font(.system(size: 11))
            .foregroundStyle(UITheme.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 本地编辑器直接识别按键，因此新手无需先授予输入监控权限才能练习。
struct RewritePracticeEditor: NSViewRepresentable {
    @ObservedObject var model: RewritePracticeModel
    let trigger: RewriteTrigger
    let isRecording: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = RewritePracticeTextView(frame: .zero)
        editor.model = model
        editor.string = model.text
        editor.setSelectedRange(model.selection)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 7, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("润色练习输入框")
        editor.setAccessibilityHelp("在这里输入或选择文字，按润色快捷键体验本地模拟效果。")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? RewritePracticeTextView else { return }
        editor.trigger = trigger
        editor.isRecording = isRecording
        editor.textColor = NSColor(UITheme.text)
        editor.insertionPointColor = NSColor(UITheme.text)
        context.coordinator.isSynchronizing = true
        defer { context.coordinator.isSynchronizing = false }
        if editor.string != model.text {
            let entireRange = NSRange(location: 0, length: (editor.string as NSString).length)
            if editor.shouldChangeText(in: entireRange, replacementString: model.text) {
                editor.textStorage?.replaceCharacters(in: entireRange, with: model.text)
                editor.didChangeText()
            }
        }
        let length = (editor.string as NSString).length
        if NSMaxRange(model.selection) <= length, editor.selectedRange() != model.selection {
            editor.setSelectedRange(model.selection)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: RewritePracticeModel
        var isSynchronizing = false

        init(model: RewritePracticeModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing, let editor = notification.object as? NSTextView else { return }
            model.edit(editor.string, selection: editor.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSynchronizing, let editor = notification.object as? NSTextView else { return }
            if model.selection != editor.selectedRange() { model.selection = editor.selectedRange() }
        }
    }
}

final class RewritePracticeTextView: NSTextView {
    var model: RewritePracticeModel?
    var trigger: RewriteTrigger = .default {
        didSet { if trigger != oldValue { resetTaps() } }
    }
    var isRecording = false {
        didSet { if isRecording { resetTaps() } }
    }
    private var lastTapAt: TimeInterval?
    private var isRightOptionDown = false
    private var fireOnRelease = false
    private var eventMonitor: Any?

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        resetTaps()
        guard let window else {
            let model = model
            DispatchQueue.main.async { model?.isFocused = false }
            return
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameInactive), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameActive),
            name: NSWindow.didBecomeKeyNotification, object: window)
        // 设置刚打开时焦点通常还在窗口上；在本窗口接收按键，不依赖全局监听权限。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.acceptsPracticeShortcut,
                  event.window == nil || event.window === self.window else { return event }
            if event.type == .flagsChanged {
                self.handleFlagsChanged(event)
            } else {
                self.resetTaps()
                if self.matchesChord(event) {
                    if !event.isARepeat { self.performPracticeShortcut() }
                    return nil
                }
            }
            return event
        }
    }

    @objc private func windowBecameActive() {
        model?.isFocused = window?.firstResponder === self
    }

    @objc private func windowBecameInactive() {
        resetTaps()
        model?.cancel()
        model?.isFocused = false
    }

    private var acceptsPracticeShortcut: Bool {
        guard !isRecording, let window, window.isKeyWindow,
              !isHiddenOrHasHiddenAncestor, model?.isCollapsed != true else { return false }
        // 自定义文风、服务配置等其他编辑器有焦点时，不能抢走其操作。
        if let editor = window.firstResponder as? NSTextView { return editor === self }
        if window.firstResponder is NSTextField { return false }
        return true
    }

    static func performShortcut(in window: NSWindow?) {
        guard let window, window.isKeyWindow, let content = window.contentView else { return }
        practiceEditor(in: content)?.performPracticeShortcut()
    }

    private static func practiceEditor(in view: NSView) -> RewritePracticeTextView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let editor = view as? RewritePracticeTextView { return editor }
        for child in view.subviews {
            if let editor = practiceEditor(in: child) { return editor }
        }
        return nil
    }

    func performPracticeShortcut() {
        guard acceptsPracticeShortcut, let window else { return }
        if window.firstResponder !== self, !window.makeFirstResponder(self) { return }
        model?.selection = selectedRange()
        model?.start()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            resetTaps()
            DispatchQueue.main.async { [weak self] in self?.model?.isFocused = true }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            resetTaps()
            DispatchQueue.main.async { [weak self] in self?.model?.isFocused = false }
        }
        return resigned
    }

    override func flagsChanged(with event: NSEvent) {
        handleFlagsChanged(event)
        super.flagsChanged(with: event)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard acceptsPracticeShortcut, trigger == .doubleTapRightOption,
              event.keyCode == 61 else { return }
        if !event.modifierFlags.intersection([.command, .control, .shift]).isEmpty {
            resetTaps()
            return
        }
        let down = event.modifierFlags.contains(.option)
        guard down != isRightOptionDown else { return }
        isRightOptionDown = down
        if down {
            if let lastTapAt, event.timestamp - lastTapAt <= 0.35 {
                self.lastTapAt = nil
                fireOnRelease = true
            } else {
                lastTapAt = event.timestamp
            }
        } else if fireOnRelease {
            fireOnRelease = false
            performPracticeShortcut()
        }
    }

    override func keyDown(with event: NSEvent) {
        resetTaps()
        if event.keyCode == 53, model?.isRunning == true {
            model?.cancel()
            return
        }
        if matchesChord(event) {
            if !event.isARepeat { performPracticeShortcut() }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if matchesChord(event) {
            if !event.isARepeat { performPracticeShortcut() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func matchesChord(_ event: NSEvent) -> Bool {
        guard acceptsPracticeShortcut,
              case .chord(let chord) = trigger, event.keyCode == chord.keyCode else { return false }
        var expected: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { expected.insert(.command) }
        if chord.modifiers.contains(.control) { expected.insert(.control) }
        if chord.modifiers.contains(.option) { expected.insert(.option) }
        if chord.modifiers.contains(.shift) { expected.insert(.shift) }
        return event.modifierFlags.intersection([.command, .control, .option, .shift]) == expected
    }

    private func resetTaps() {
        lastTapAt = nil
        isRightOptionDown = false
        fireOnRelease = false
    }
}
