import AppKit
import SwiftUI

@MainActor
final class CapsuleModel: ObservableObject {
    @Published var state: CapsuleState = .loading("读取中")
    var undoAction: (() -> Void)?
}

enum CapsuleState: Equatable {
    case loading(String)
    case done
    case undone

    var title: String {
        switch self {
        case .loading(let title): return title
        case .done: return "已改写"
        case .undone: return "已撤回"
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var showDivider: Bool {
        if case .done = self { return true }
        return false
    }

    var showAction: Bool {
        if case .done = self { return true }
        return false
    }

    var actionTitle: String {
        if case .done = self { return "撤回" }
        return ""
    }
}

@MainActor
final class CapsuleController {
    private let model = CapsuleModel()
    private var visibilityToken = 0
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 30),
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

    func showLoading(_ title: String) {
        model.state = .loading(title)
        show()
    }

    func showDone(undo: @escaping () -> Void) {
        model.undoAction = undo
        model.state = .done
        show()
    }

    func showUndone() {
        model.state = .undone
        show()
        hide(after: 0.9)
    }

    func hide(after seconds: TimeInterval = 4.2) {
        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.visibilityToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    private func show() {
        visibilityToken += 1
        panel.setContentSize(NSSize(width: 132, height: 30))
        positionBottomCenter()
        panel.orderFrontRegardless()
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

struct CapsuleView: View {
    @ObservedObject var model: CapsuleModel

    var body: some View {
        HStack(spacing: 5) {
            if model.state.isLoading {
                BreathingOrb()
                Text(model.state.title)
                    .font(.system(size: 12, weight: .bold))
                LoadingDots()
            } else {
                Text(model.state.title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if model.state.showDivider {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 13)
                }
                if model.state.showAction {
                    Button(model.state.actionTitle) {
                        model.undoAction?()
                    }
                    .buttonStyle(CapsuleActionButtonStyle())
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 132, height: 30)
        .foregroundStyle(foregroundColor)
        .background(background)
    }

    private var foregroundColor: Color {
        Color(red: 0.92, green: 1.0, blue: 0.95)
    }

    private var background: some View {
        TimelineView(.animation) { context in
            let pulse = model.state.isLoading ? breathingProgress(context.date.timeIntervalSinceReferenceDate) : 0
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.1, blue: 0.09).opacity(0.99),
                            Color(red: 0.02, green: 0.04, blue: 0.035).opacity(0.97)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(Color.typemoreGreen.opacity(model.state.isLoading ? 0.22 + pulse * 0.16 : 0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 18, y: 10)
                .shadow(color: .typemoreGreen.opacity(model.state.isLoading ? 0.08 + pulse * 0.14 : 0), radius: 18 + pulse * 10)
        }
    }

    private func breathingProgress(_ time: TimeInterval) -> Double {
        (sin(time * .pi * 2 / 1.45) + 1) / 2
    }
}

struct BreathingOrb: View {
    var body: some View {
        TimelineView(.animation) { context in
            let pulse = (sin(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 1.15) + 1) / 2
            Circle()
                .fill(Color.typemoreGreen)
                .frame(width: 7, height: 7)
                .scaleEffect(0.86 + pulse * 0.18)
                .opacity(0.62 + pulse * 0.38)
                .shadow(color: .typemoreGreen.opacity(0.35 + pulse * 0.35), radius: 5 + pulse * 6)
        }
        .frame(width: 9, height: 10)
    }
}

struct LoadingDots: View {
    private let cycle: TimeInterval = 1.32
    private let delays: [TimeInterval] = [0, 0.22, 0.44]

    var body: some View {
        TimelineView(.animation) { context in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = localProgress(context.date.timeIntervalSinceReferenceDate, delay: delays[index])
                    Circle()
                        .fill(Color.typemoreGreen)
                        .frame(width: 3, height: 3)
                        .opacity(opacity(progress))
                        .offset(y: yOffset(progress))
                        .scaleEffect(scale(progress))
                }
            }
            .frame(width: 15, height: 10)
        }
    }

    private func localProgress(_ time: TimeInterval, delay: TimeInterval) -> Double {
        let shifted = time - delay
        let remainder = shifted - floor(shifted / cycle) * cycle
        return remainder / cycle
    }

    private func yOffset(_ progress: Double) -> CGFloat {
        if progress < 0.10 { return CGFloat(-3.5 * (progress / 0.10)) }
        if progress < 0.20 { return CGFloat(-3.5 * (1 - (progress - 0.10) / 0.10)) }
        return 0
    }

    private func opacity(_ progress: Double) -> Double {
        progress < 0.30 ? 1.0 : 0.34
    }

    private func scale(_ progress: Double) -> CGFloat {
        progress < 0.20 ? 1.08 : 1
    }
}

struct CapsuleActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.typemoreGreen.opacity(configuration.isPressed ? 0.2 : 0.1))
            .foregroundStyle(Color.typemoreGreen)
            .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
    }
}

private extension Color {
    static let typemoreGreen = Color(red: 0.27, green: 0.96, blue: 0.61)
}
