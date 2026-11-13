import AppKit
import ApplicationServices
import Combine
import CoreGraphics

@MainActor
final class TypemoreApp: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private lazy var settingsWindow = SettingsWindowController(store: settingsStore, triggerController: trigger)
    private let trigger = RewriteTriggerCoordinator()
    private let textService = SystemTextService()
    private let rewriteService = RewriteService()
    private let capsule = CapsuleController()
    private let toast = ToastController()
    private var isProcessing = false
    private var rewriteTask: Task<Void, Never>?
    private var rewriteOperationID: UUID?
    private var rewritePhase: RewritePhase = .reading
    private var activeSession: RewriteSession?
    private var cancellables = Set<AnyCancellable>()
    private var reopenObserver: NSObjectProtocol?
    private let debugEnabled = ProcessInfo.processInfo.environment["TYPEMORE_DEBUG"] == "1"
    private let perfEnabled = ProcessInfo.processInfo.environment["TYPEMORE_PERF"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")
        let accessibilityTrusted = textService.requestAccessibilityAccessIfNeeded()
        TMLog.boot("launch path=\(Bundle.main.bundleURL.path) trusted=\(accessibilityTrusted) listenEvent=\(CGPreflightListenEventAccess())")
        NSApp.setActivationPolicy(.regular)
        debugLog("activationPolicy set to regular")
        installEditMenu()
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: .typemoreOpenSettings, object: Bundle.main.bundleIdentifier, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }
        registerTrigger()
        showSettingsOnLaunchIfNeeded()
    }

    /// Dock 应用使用标准菜单，保留编辑快捷键并提供设置、关闭窗口与退出入口。
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Typemore")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Typemore", action: #selector(openAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Typemore 设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Typemore", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Typemore", action: #selector(quit), keyEquivalent: "q").target = self

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("applicationWillTerminate")
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
        trigger.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开设置", action: #selector(openSettings), keyEquivalent: "").target = self
        return menu
    }

    private func registerTrigger() {
        debugLog("registering rewrite trigger: \(settingsStore.settings.rewriteTrigger.displayText)")
        do {
            try trigger.apply(trigger: settingsStore.settings.rewriteTrigger) { [weak self] in
                Task { @MainActor in self?.handleRewriteShortcut() }
            }
            debugLog("rewrite trigger registered")
            TMLog.write("trigger registered: \(settingsStore.settings.rewriteTrigger.displayText)")
        } catch {
            debugLog("rewrite trigger failed: \(error.localizedDescription)")
            let message = error.localizedDescription
            TMLog.write("trigger register failed: \(message)")
            showErrorToast(message)
        }
        observeTriggerChanges()
    }

    /// 设置里改了触发键后热更新绑定，无需重启应用。仅在触发键真正变化时重新注册，
    /// 避免每次保存（改模型 / 风格等）都重建监听。
    private func observeTriggerChanges() {
        settingsStore.$settings
            .map(\.rewriteTrigger)
            .removeDuplicates()
            .sink { [weak self] newTrigger in
                guard let self, newTrigger != self.trigger.current else { return }
                self.rebindTrigger(to: newTrigger)
            }
            .store(in: &cancellables)
    }

    private func rebindTrigger(to newTrigger: RewriteTrigger) {
        do {
            try trigger.apply(trigger: newTrigger)
            TMLog.write("trigger rebound: \(newTrigger.displayText)")
        } catch {
            let message = error.localizedDescription
            TMLog.write("trigger rebind failed: \(message)")
            showErrorToast(message)
        }
    }

    /// 用户主动打开 .app 时展示主窗口；关闭后保持 Dock 与触发器运行。
    private func showSettingsOnLaunchIfNeeded() {
        let isPackagedApp = Bundle.main.bundleURL.pathExtension == "app"
        guard isPackagedApp else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.openSettings()
        }
    }

    private func handleRewriteShortcut() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // 应用内仅允许练习编辑器响应，始终在读取文本和调用模型之前返回。
            RewritePracticeTextView.performShortcut(in: NSApp.keyWindow)
            return
        }
        guard !isProcessing else {
            TMLog.write("shortcut: skipped, busy")
            return
        }
        isProcessing = true
        let operationID = UUID()
        rewriteOperationID = operationID
        rewritePhase = .reading
        toast.dismiss()
        capsule.hide(after: 0)
        activeSession = nil
        showRewriteLoading("读取中", operationID: operationID)
        TMLog.write("shortcut triggered, frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")

        rewriteTask = Task { @MainActor in
            let totalStartedAt = Date()
            defer {
                if rewriteOperationID == operationID {
                    rewriteTask = nil
                    rewriteOperationID = nil
                    isProcessing = false
                }
            }
            do {
                try Task.checkCancellation()
                let captureStartedAt = Date()
                let capture = try await textService.captureText { _ in }
                try Task.checkCancellation()
                perfLog("capture: \(formatDuration(since: captureStartedAt)), chars=\(capture.text.count)")
                rewritePhase = .rewriting
                showRewriteLoading("润色中", operationID: operationID)

                let rewriteStartedAt = Date()
                let settings = settingsStore.settings
                let rewritten = try await rewriteService.rewrite(capture, settings: settings) { @MainActor [weak self] progress in
                    if progress.total > 1 {
                        self?.showRewriteLoading("润色中 \(progress.completed)/\(progress.total)", operationID: operationID)
                    }
                }
                try Task.checkCancellation()
                perfLog("rewrite: \(formatDuration(since: rewriteStartedAt)), chars=\(rewritten.count)")
                TMLog.write("rewrite ok chars=\(rewritten.count)")
                let pasteStartedAt = Date()
                try await textService.paste(
                    rewritten,
                    into: capture.sourceBundleID,
                    replacementRange: capture.replacementRange,
                    previousClipboard: capture.previousClipboard,
                    onWillCommit: { [weak self] in
                        guard let self, self.rewriteOperationID == operationID else { return }
                        // 与 Cmd+V 同步执行；提交后改用“撤回”，不再允许取消。
                        self.rewritePhase = .applying
                        self.capsule.showLoading("润色中")
                    }
                )
                perfLog("paste: \(formatDuration(since: pasteStartedAt))")
                activeSession = textService.recordReplacement(capture: capture, text: rewritten,
                                                             styleID: settings.selectedWritingStyle.id)
                showCompletedRewrite()
                perfLog("total: \(formatDuration(since: totalStartedAt))")
                TMLog.write("flow done total=\(formatDuration(since: totalStartedAt))")
            } catch {
                guard rewriteOperationID == operationID else { return }
                if error is CancellationError || Task.isCancelled {
                    TMLog.write("flow cancelled")
                    capsule.hide(after: 0)
                    return
                }
                let message = error.localizedDescription
                TMLog.write("flow error: \(message)")
                capsule.hide(after: 0)
                showErrorToast(message)
            }
        }
    }

    private func showRewriteLoading(_ title: String, operationID: UUID) {
        guard rewriteOperationID == operationID, rewriteTask?.isCancelled != true,
              rewritePhase == .reading || rewritePhase == .rewriting else { return }
        capsule.showLoading(title) { [weak self] in self?.cancelRewrite(operationID: operationID) }
    }

    private func cancelRewrite(operationID: UUID) {
        guard rewriteOperationID == operationID,
              rewritePhase == .reading || rewritePhase == .rewriting else { return }
        rewritePhase = .cancelled
        rewriteTask?.cancel()
        capsule.hide(after: 0)
        // 等读取/剪贴板与后端清理完成再释放 busy，避免下一次触发与旧任务交叉写回。
    }

    private func showCompletedRewrite() {
        guard let session = activeSession else { return }
        capsule.showDone(styles: settingsStore.settings.writingStyles, selectedStyleID: session.styleID,
                         changeStyle: { [weak self] id in self?.rewriteWithStyle(id) }) { [weak self] in
            Task { @MainActor in await self?.undoLastReplacement() }
        }
        capsule.hide()
    }

    private func rewriteWithStyle(_ styleID: UUID) {
        guard !isProcessing, let session = activeSession else { return }
        var settings = settingsStore.settings
        guard settings.writingStyles.contains(where: { $0.id == styleID }) else { return }
        settings.selectWritingStyle(styleID)
        do { try settingsStore.save(settings) }
        catch { showErrorToast(error.localizedDescription); return }

        isProcessing = true
        let operationID = UUID()
        rewriteOperationID = operationID
        rewritePhase = .rewriting
        toast.dismiss()
        showRewriteLoading("润色中", operationID: operationID)
        rewriteTask = Task { @MainActor in
            defer {
                if rewriteOperationID == operationID {
                    rewriteTask = nil
                    rewriteOperationID = nil
                    isProcessing = false
                }
            }
            do {
                // 每种风格均使用最初的原文与上下文，连续切换时保持同一份输入。
                let rewritten = try await rewriteService.rewrite(session.capture, settings: settings) { @MainActor [weak self] progress in
                    if progress.total > 1 {
                        self?.showRewriteLoading("润色中 \(progress.completed)/\(progress.total)", operationID: operationID)
                    }
                }
                try Task.checkCancellation()
                try await textService.replace(rewritten, in: session) { [weak self] in
                    self?.rewritePhase = .applying
                    self?.capsule.showLoading("润色中")
                }
                activeSession = session.replacing(with: rewritten, styleID: styleID)
                showCompletedRewrite()
            } catch {
                guard rewriteOperationID == operationID else { return }
                showCompletedRewrite()
                if !(error is CancellationError) && !Task.isCancelled {
                    showErrorToast(error.localizedDescription)
                }
            }
        }
    }

    private func undoLastReplacement() async {
        guard !isProcessing, let activeSession else { return }
        isProcessing = true
        defer { isProcessing = false }
        self.activeSession = nil
        capsule.showLoading("撤回中")
        do {
            try await textService.replace(activeSession.capture.text, in: activeSession)
            capsule.showUndone()
        } catch {
            let message = error.localizedDescription
            capsule.hide(after: 0)
            showErrorToast(message)
        }
    }

    private func showErrorToast(_ message: String) {
        if isPermissionError(message) {
            toast.showError(message, actionTitle: "打开设置") { [weak self] in
                self?.openPermissionSettings(for: message)
            }
        } else if message.contains("登录") || message.contains("API Key") || message.contains("模型") || message.contains("Base URL") {
            toast.showError(message, actionTitle: "设置") { [weak self] in self?.openSettings() }
        } else {
            toast.showError(message)
        }
    }

    private func isPermissionError(_ message: String) -> Bool {
        message.contains("辅助功能权限") || message.contains("输入监控权限")
    }

    private func openPermissionSettings(for message: String) {
        if message.contains("输入监控权限") {
            textService.openInputMonitoringSettings()
        } else {
            textService.openAccessibilitySettings()
        }
    }

    @objc private func openSettings() {
        debugLog("openSettings called")
        settingsWindow.show()
    }

    @objc private func openAbout() {
        settingsWindow.showAbout()
    }

    @objc private func quit() {
        debugLog("quit called")
        NSApp.terminate(nil)
    }

    private func debugLog(_ message: String) {
        guard debugEnabled else { return }
        printLog("[Typemore][\(timestamp())] \(message)")
    }

    private func perfLog(_ message: String) {
        guard perfEnabled else { return }
        printLog("[Typemore][perf] \(message)")
    }

    private func printLog(_ line: String) {
        let value = "\(line)\n"
        if let data = value.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func formatDuration(since date: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(date) * 1000)
    }
}

private enum RewritePhase {
    case reading, rewriting, applying, cancelled
}
