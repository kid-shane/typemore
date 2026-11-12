import SwiftUI

struct SettingsChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var expanded = false

    var body: some View {
        Button { expanded = true } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AppIcon(symbol: .expand, size: .small)
                    .foregroundStyle(UITheme.secondary)
            }
            .frame(width: 256, alignment: .leading)
        }
        .buttonStyle(SettingsButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(options, id: \.0) { value, label in
                    Button {
                        selection = value
                        expanded = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(label)
                            Spacer()
                            if selection == value { AppIcon(symbol: .check, size: .small) }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(UITheme.text)
                        .padding(10)
                        .frame(width: 256)
                        .background(selection == value ? UITheme.selection : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
            .padding(8)
            .background(UITheme.background)
            .onExitCommand { expanded = false }
        }
    }
}
