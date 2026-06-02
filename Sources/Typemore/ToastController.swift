import AppKit
import SwiftUI

/// 错误用经典深色 tip 呈现，和服务于主链路状态的胶囊区分开。
@MainActor
final class ToastController {
    private let model = ToastModel()
    private var visibilityToken = 0
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
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
        panel.contentView = NSHostingView(rootView: ToastView(model: model))
        return panel
    }()

    func showError(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        model.message = message
        model.actionTitle = actionTitle
        model.action = action
        sizeAndShow()
        hide(after: actionTitle == nil ? 3.0 : 6.0)
    }

    private func sizeAndShow() {
        visibilityToken += 1
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 44)
        let width = min(max(size.width, 200), 420)
        let height = max(size.height, 40)
        panel.setContentSize(NSSize(width: width, height: height))
        positionBottomCenter()
        panel.orderFrontRegardless()
    }

    private func hide(after seconds: TimeInterval) {
        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.visibilityToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 104
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class ToastModel: ObservableObject {
    @Published var message: String = ""
    @Published var actionTitle: String?
    var action: (() -> Void)?
}

struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)
            if let actionTitle = model.actionTitle {
                Button(actionTitle) { model.action?() }
                    .buttonStyle(ToastActionButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        )
        .fixedSize()
    }
}

private struct ToastActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1))
            .foregroundStyle(Color.white.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
