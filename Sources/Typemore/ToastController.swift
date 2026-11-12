import AppKit
import SwiftUI

@MainActor
final class ToastController {
    private let model = ToastModel()
    private var visibilityToken = 0
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 90),
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
        model.dismissAction = { [weak self] in self?.dismiss() }
        visibilityToken += 1
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 384, height: 90))
        FloatingPanelPosition.bottomCenter(panel)
        panel.orderFrontRegardless()
        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + (actionTitle == nil ? 4.0 : 6.0)) { [weak self] in
            guard let self, self.visibilityToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    func dismiss() {
        visibilityToken += 1
        panel.orderOut(nil)
    }
}

@MainActor
final class ToastModel: ObservableObject {
    @Published var message = ""
    @Published var actionTitle: String?
    var action: (() -> Void)?
    var dismissAction: (() -> Void)?
}

struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(symbol: .warning)
                .foregroundStyle(UITheme.error)
            Text(model.message)
                .font(.system(size: 12))
                .foregroundStyle(UITheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let title = model.actionTitle {
                Button(title) { model.action?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UITheme.accent)
            }
            Button { model.dismissAction?() } label: {
                AppIcon(symbol: .close, size: .small)
                    .foregroundStyle(UITheme.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(16)
        .frame(width: 380)
        .modifier(FloatingSurface())
        .fixedSize(horizontal: false, vertical: true)
    }
}
