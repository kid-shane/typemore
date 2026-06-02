import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class TypemoreApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settingsStore = SettingsStore()
    private lazy var settingsWindow = SettingsWindowController(store: settingsStore)
    private let trigger = RightOptionDoubleTapTrigger()
    private let textService = SystemTextService()
    private let rewriteService = RewriteService()
    private let capsule = CapsuleController()
    private let toast = ToastController()
    private var isProcessing = false
    private var activeSession: ActiveSession?
    private let debugEnabled = ProcessInfo.processInfo.environment["TYPEMORE_DEBUG"] == "1"
    private let perfEnabled = ProcessInfo.processInfo.environment["TYPEMORE_PERF"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")
        let accessibilityTrusted = textService.requestAccessibilityAccessIfNeeded()
        TMLog.boot("launch path=\(Bundle.main.bundleURL.path) trusted=\(accessibilityTrusted) listenEvent=\(CGPreflightListenEventAccess())")
        NSApp.setActivationPolicy(.accessory)
        debugLog("activationPolicy set to accessory")
        installEditMenu()
        createStatusItem()
        registerTrigger()
        showSettingsOnLaunchIfNeeded()
    }

    /// 状态栏应用没有默认主菜单，导致设置窗口里的 Cmd+C/V/X/A 失效（只能右键）。
    /// 这里补一个标准「编辑」菜单，让系统能把这些快捷键分发到当前输入框。
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("applicationWillTerminate")
        trigger.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func createStatusItem() {
        debugLog("creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "T+"
        statusItem.button?.toolTip = "Typemore"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openSettings)
        statusItem.isVisible = true
        debugLog("status item allocated, button exists: \(statusItem.button != nil)")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Permissions", action: #selector(openPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        debugLog("status item menu attached, items: \(menu.items.count)")
        debugStatusItem()
    }

    private func registerTrigger() {
        debugLog("registering right option double tap trigger")
        do {
            try trigger.start { [weak self] in
                Task { @MainActor in self?.handleRewriteShortcut() }
            }
            debugLog("right option double tap trigger registered")
            TMLog.write("trigger registered")
        } catch {
            debugLog("right option double tap trigger failed: \(error.localizedDescription)")
            let message = error.localizedDescription
            TMLog.write("trigger register failed: \(message)")
            showErrorToast(message)
        }
    }

    private func showSettingsOnLaunchIfNeeded() {
        let isPackagedApp = Bundle.main.bundleURL.pathExtension == "app"
        let needsSetup = settingsStore.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let welcomeKey = "hasShownSettingsForVersion.\(version)"
        let shouldShowPackagedWelcome = isPackagedApp && !UserDefaults.standard.bool(forKey: welcomeKey)
        guard needsSetup || shouldShowPackagedWelcome else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.openSettings()
            if shouldShowPackagedWelcome {
                UserDefaults.standard.set(true, forKey: welcomeKey)
            }
        }
    }

    private func handleRewriteShortcut() {
        guard !isProcessing else {
            TMLog.write("shortcut: skipped, busy")
            return
        }
        isProcessing = true
        TMLog.write("shortcut triggered, frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")

        Task { @MainActor in
            let totalStartedAt = Date()
            defer { isProcessing = false }
            do {
                let captureStartedAt = Date()
                let capture = try await textService.captureText { [weak self] _ in
                    Task { @MainActor in self?.capsule.showLoading("读取中") }
                }
                perfLog("capture: \(formatDuration(since: captureStartedAt)), chars=\(capture.text.count)")
                activeSession = ActiveSession(capture: capture)
                capsule.showLoading("改写中")

                let rewriteStartedAt = Date()
                let rewritten = try await rewriteService.rewrite(capture, settings: settingsStore.settings)
                perfLog("rewrite: \(formatDuration(since: rewriteStartedAt)), chars=\(rewritten.count)")
                TMLog.write("rewrite ok chars=\(rewritten.count)")
                let pasteStartedAt = Date()
                try await textService.paste(
                    rewritten,
                    into: capture.sourceBundleID,
                    replacementRange: capture.replacementRange,
                    previousClipboard: capture.previousClipboard
                )
                perfLog("paste: \(formatDuration(since: pasteStartedAt))")

                capsule.showDone { [weak self] in
                    Task { @MainActor in await self?.undoLastReplacement() }
                }
                capsule.hide()
                perfLog("total: \(formatDuration(since: totalStartedAt))")
                TMLog.write("flow done total=\(formatDuration(since: totalStartedAt))")
            } catch {
                let message = error.localizedDescription
                TMLog.write("flow error: \(message)")
                capsule.hide(after: 0)
                showErrorToast(message)
            }
        }
    }

    private func undoLastReplacement() async {
        guard let activeSession else { return }
        capsule.showLoading("撤回中")
        do {
            try await textService.undo(in: activeSession.sourceBundleID)
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

    @objc private func openPermissions() {
        textService.openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.textService.openInputMonitoringSettings()
        }
    }

    @objc private func quit() {
        debugLog("quit called")
        NSApp.terminate(nil)
    }

    private func debugStatusItem() {
        let button = statusItem?.button
        let frame = button?.frame ?? .zero
        let windowVisible = button?.window?.isVisible ?? false
        debugLog("status item debug: visible=\(statusItem?.isVisible ?? false), title=\(button?.title ?? "nil"), frame=\(NSStringFromRect(frame)), buttonWindowVisible=\(windowVisible), menuItems=\(statusItem?.menu?.items.count ?? -1)")
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

private struct ActiveSession {
    let sessionID: Int
    let sourceBundleID: String?
    let previousClipboard: ClipboardSnapshot

    init(capture: CaptureResult) {
        self.sessionID = capture.sessionID
        self.sourceBundleID = capture.sourceBundleID
        self.previousClipboard = capture.previousClipboard
    }
}
