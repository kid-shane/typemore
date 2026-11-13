import Foundation

struct WritingStyle: Codable, Equatable, Identifiable {
    static let defaultID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let personalID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let standard = WritingStyle(id: defaultID, name: "默认表达", instructions: "")

    var id = UUID()
    var name: String
    var instructions: String
    var isBuiltIn: Bool { id == Self.defaultID }
}

extension AppSettings {
    var selectedWritingStyle: WritingStyle {
        writingStyles.first { $0.id == selectedWritingStyleID } ?? .standard
    }

    var hasInvalidWritingStyle: Bool {
        writingStyles.contains {
            !$0.isBuiltIn && ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                $0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    mutating func prepareWritingStyles() {
        if writingStyles.isEmpty {
            writingStyles = [.standard, WritingStyle(id: WritingStyle.personalID, name: "我的风格", instructions: customStyle)]
            selectedWritingStyleID = defaultMode == .custom ? WritingStyle.personalID : WritingStyle.defaultID
        }
        if !writingStyles.contains(where: \.isBuiltIn) { writingStyles.insert(.standard, at: 0) }
        if !writingStyles.contains(where: { $0.id == selectedWritingStyleID }) {
            selectedWritingStyleID = WritingStyle.defaultID
        }
        selectWritingStyle(selectedWritingStyleID ?? WritingStyle.defaultID)
    }

    mutating func selectWritingStyle(_ id: UUID) {
        guard let style = writingStyles.first(where: { $0.id == id }) else { return }
        selectedWritingStyleID = id
        defaultMode = style.isBuiltIn ? .clear : .custom
        if !style.isBuiltIn { customStyle = style.instructions }
    }
}
