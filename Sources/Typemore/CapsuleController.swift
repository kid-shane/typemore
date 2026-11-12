import AppKit
import SwiftUI

@MainActor
final class CapsuleModel: ObservableObject {
    @Published var state: CapsuleState = .loading("读取中")
    @Published var cancelAction: (() -> Void)?
    var undoAction: (() -> Void)?
}

enum CapsuleState: Equatable {
    case loading(String)
    case done
    case undone

    var title: String {
        switch self {
        case .loading(let title): return title
        case .done: return "已润色"
        case .undone: return "已撤回"
        }
    }
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    var compactTitle: String {
        // 极长文只显示完整分段数字，避免为了状态词截掉实际进度。
        if case .loading(let title) = self, title.hasPrefix("润色中 "), title.count > 11 {
            return String(title.dropFirst(4))
        }
        return title
    }
}

private enum CapsuleLayout {
    static let width: CGFloat = 156
    static let height: CGFloat = 34
    static let shadowPadding: CGFloat = 10
    static let bottomGap: CGFloat = 12
}

@MainActor
final class CapsuleController {
    private let model = CapsuleModel()
    private var visibilityToken = 0
    private var placementScreen: NSScreen?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: CapsuleLayout.width + CapsuleLayout.shadowPadding * 2,
                height: CapsuleLayout.height + CapsuleLayout.shadowPadding * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: CapsuleView(model: model))
        return panel
    }()

    func showLoading(_ title: String, cancel: (() -> Void)? = nil) {
        model.undoAction = nil
        model.cancelAction = cancel
        model.state = .loading(title)
        show()
    }
    func showDone(undo: @escaping () -> Void) {
        model.cancelAction = nil
        model.undoAction = undo
        model.state = .done
        show()
    }
    func showUndone() {
        model.cancelAction = nil
        model.undoAction = nil
        model.state = .undone
        show()
        hide(after: 0.9)
    }
    func hide(after seconds: TimeInterval = 4.2) {
        let token = visibilityToken
        if seconds <= 0 {
            visibilityToken += 1
            model.cancelAction = nil
            panel.orderOut(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.visibilityToken == token else { return }
            self.panel.orderOut(nil)
        }
    }
    private func show() {
        visibilityToken += 1
        // 触发时记录输入所在屏幕，后续进度与完成状态沿用，避免鼠标移动导致跳屏。
        if !panel.isVisible {
            placementScreen = NSScreen.main ?? NSScreen.screens.first
        }
        FloatingPanelPosition.bottomCenter(
            panel,
            on: placementScreen,
            bottomInset: CapsuleLayout.bottomGap - CapsuleLayout.shadowPadding
        )
        panel.orderFrontRegardless()
    }
}

struct CapsuleView: View {
    @ObservedObject var model: CapsuleModel

    var body: some View {
        HStack(spacing: 6) {
            if model.state.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
            } else {
                AppIcon(symbol: model.state == .done ? .connected : .undo, size: .small)
                    .foregroundStyle(UITheme.success)
            }
            Text(model.state.compactTitle)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                .accessibilityLabel(model.state.title)
            Spacer(minLength: 0)
            if model.state == .done {
                Rectangle().fill(UITheme.border).frame(width: 1, height: 14)
                Button("撤回") {
                    let action = model.undoAction
                    model.undoAction = nil
                    action?()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UITheme.accent)
                .frame(height: 26)
                .contentShape(Rectangle())
            } else if model.state.isLoading, model.cancelAction != nil {
                Button {
                    let action = model.cancelAction
                    model.cancelAction = nil
                    action?()
                } label: {
                    AppIcon(symbol: .close, size: .small)
                        .foregroundStyle(UITheme.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止润色")
                .help("停止润色，保留原文")
            } else {
                TypemoreMark(size: 18, badge: false)
            }
        }
        .foregroundStyle(UITheme.text)
        .padding(.horizontal, 10)
        .frame(width: CapsuleLayout.width, height: CapsuleLayout.height)
        .modifier(FloatingSurface(
            cornerRadius: CapsuleLayout.height / 2,
            shadowPadding: CapsuleLayout.shadowPadding
        ))
    }
}
