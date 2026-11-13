import SwiftUI

struct WritingStyleView: View {
    @Binding var draft: AppSettings
    @State private var confirmingRemoval = false

    private var selectedIndex: Int? {
        draft.writingStyles.firstIndex { $0.id == draft.selectedWritingStyleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("当前风格").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    SettingsChoice(title: "选择表达风格", selection: Binding(
                        get: { draft.selectedWritingStyleID ?? WritingStyle.defaultID },
                        set: { draft.selectWritingStyle($0) }
                    ), options: draft.writingStyles.map { ($0.id, $0.name) })
                    Button("＋ 新建风格") {
                        let style = WritingStyle(name: "新风格", instructions: "")
                        draft.writingStyles.append(style)
                        draft.selectWritingStyle(style.id)
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                Text("快捷键直接使用当前风格润色。")
                    .font(.system(size: 12)).foregroundStyle(UITheme.secondary)
            }
            if let index = selectedIndex, !draft.writingStyles[index].isBuiltIn {
                SettingsSection("表达偏好", icon: .edit) {
                    SettingsRow("风格名称") {
                        TextField("给这套风格起个名字", text: $draft.writingStyles[index].name)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 12).frame(width: 256, height: 34)
                            .background(UITheme.field).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
                            .accessibilityLabel("风格名称")
                    }
                    ZStack(alignment: .topLeading) {
                        if draft.writingStyles[index].instructions.isEmpty {
                            Text("例如：自然简洁，先说结论，适当分点。")
                                .foregroundStyle(UITheme.secondary).padding(12).allowsHitTesting(false)
                        }
                        TextEditor(text: $draft.writingStyles[index].instructions)
                            .scrollContentBackground(.hidden).padding(8)
                            .accessibilityLabel("表达偏好")
                    }
                    .font(.system(size: 13)).foregroundStyle(UITheme.text)
                    .frame(height: 200)
                    .background(UITheme.field).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
                    HStack(spacing: 16) {
                        Button("复制风格") {
                            var copy = draft.writingStyles[index]
                            copy.id = UUID(); copy.name += " 副本"
                            draft.writingStyles.append(copy)
                            draft.selectWritingStyle(copy.id)
                        }
                        Button("删除风格") { confirmingRemoval = true }
                            .foregroundStyle(UITheme.error)
                        Spacer()
                        if draft.hasInvalidWritingStyle {
                            Text("填写名称和表达偏好后即可保存")
                                .foregroundStyle(UITheme.secondary)
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 12))
                }
            } else {
                Text("让表达更清晰、自然、有条理，保留原意和事实。你也可以创建自己的表达风格。")
                    .font(.system(size: 13)).foregroundStyle(UITheme.secondary)
            }
        }
        .confirmationDialog("删除「\(draft.selectedWritingStyle.name)」？", isPresented: $confirmingRemoval) {
            Button("删除风格", role: .destructive) {
                draft.writingStyles.removeAll { $0.id == draft.selectedWritingStyleID && !$0.isBuiltIn }
                draft.selectWritingStyle(WritingStyle.defaultID)
            }
            Button("取消", role: .cancel) {}
        }
    }
}
