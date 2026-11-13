import AppKit
import SwiftUI

@MainActor
final class CapsuleModel: ObservableObject {
    @Published var state: CapsuleState = .loading("读取中")
    @Published var cancelAction: (() -> Void)?
    var undoAction: (() -> Void)?
    @Published var styles: [WritingStyle] = []
    @Published var selectedStyleID: UUID?
    @Published var pickerPresented = false
    var isHovering = false
    var changeStyleAction: ((UUID) -> Void)?
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
    static let completedWidth: CGFloat = 208
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
        model.pickerPresented = false
        model.undoAction = nil
        model.cancelAction = cancel
        model.state = .loading(title)
        show()
    }
    func showDone(styles: [WritingStyle] = [], selectedStyleID: UUID? = nil,
                  changeStyle: ((UUID) -> Void)? = nil, undo: @escaping () -> Void) {
        model.styles = styles
        model.selectedStyleID = selectedStyleID
        model.changeStyleAction = changeStyle
        model.cancelAction = nil
        model.undoAction = undo
        model.state = .done
        show()
    }
    func showUndone() {
        model.cancelAction = nil
        model.undoAction = nil
        model.changeStyleAction = nil
        model.pickerPresented = false
        model.state = .undone
        show()
        hide(after: 0.9)
    }
    func hide(after seconds: TimeInterval = 4.2) {
        let token = visibilityToken
        if seconds <= 0 {
            visibilityToken += 1
            model.cancelAction = nil
            model.pickerPresented = false
            panel.orderOut(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.visibilityToken == token else { return }
            if self.model.isHovering || self.model.pickerPresented {
                self.hide(after: seconds)
                return
            }
            self.panel.orderOut(nil)
        }
    }
    private func show() {
        visibilityToken += 1
        let width = model.state == .done && model.changeStyleAction != nil ? CapsuleLayout.completedWidth : CapsuleLayout.width
        panel.setContentSize(NSSize(width: width + CapsuleLayout.shadowPadding * 2,
                                    height: CapsuleLayout.height + CapsuleLayout.shadowPadding * 2))
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
                AppIcon(symbol: model.state == .done ? .check : .undo, size: .small)
                    .foregroundStyle(UITheme.secondary)
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
                if model.changeStyleAction != nil {
                    Button { model.pickerPresented = true } label: {
                        HStack(spacing: 3) {
                            Text("换一个")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(UITheme.secondary)
                        }
                    }
                        .buttonStyle(CapsuleActionButtonStyle(filled: true))
                        .accessibilityLabel("换一个")
                        .help("选择其他表达风格")
                        .popover(isPresented: $model.pickerPresented, arrowEdge: .bottom) {
                            stylePicker
                        }
                }
                Button {
                    let action = model.undoAction
                    model.undoAction = nil
                    action?()
                } label: {
                    AppIcon(symbol: .undo, size: .small)
                        .foregroundStyle(UITheme.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(CapsuleActionButtonStyle())
                .accessibilityLabel("撤回")
                .help("撤回到原文")
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
        .frame(width: model.state == .done && model.changeStyleAction != nil ? CapsuleLayout.completedWidth : CapsuleLayout.width,
               height: CapsuleLayout.height)
        .background(UITheme.background)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(UITheme.border.opacity(0.65), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
        .padding(CapsuleLayout.shadowPadding)
        .onHover { model.isHovering = $0 }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择风格").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.top, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.styles) { style in
                        Button {
                            model.pickerPresented = false
                            model.changeStyleAction?(style.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(style.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if model.selectedStyleID == style.id { AppIcon(symbol: .check, size: .small) }
                            }
                            .font(.system(size: 13)).foregroundStyle(UITheme.text)
                            .padding(.horizontal, 10).frame(height: 36)
                            .background(model.selectedStyleID == style.id ? UITheme.selection : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selectedStyleID == style.id ? .isSelected : [])
                    }
                }
            }
            .frame(height: min(CGFloat(model.styles.count) * 38, 228))
        }
        .padding(8).frame(width: 232).background(UITheme.background)
        .onExitCommand { model.pickerPresented = false }
    }
}

private struct CapsuleActionButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(configuration: configuration, filled: filled)
    }

    private struct ActionLabel: View {
        let configuration: ButtonStyleConfiguration
        let filled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UITheme.text)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(hovering || configuration.isPressed ? UITheme.selection : filled ? UITheme.field : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.65 : 1)
                .onHover { hovering = $0 }
        }
    }
}
