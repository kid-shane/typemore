import AppKit
import XCTest
@testable import Typemore

final class WritingStyleTests: XCTestCase {
    func testLegacyCustomStyleAndSelectionSurviveMigrationAndReload() throws {
        let legacy = Data(#"{"defaultMode":"custom","customStyle":"保留条件和不确定语气，先说结论。"}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: legacy).sanitized()
        XCTAssertEqual(settings.selectedWritingStyle.name, "我的风格")
        XCTAssertEqual(settings.selectedWritingStyle.instructions, "保留条件和不确定语气，先说结论。")
        let english = WritingStyle(name: "英文表达", instructions: "用自然英文表达，保留原意。")
        settings.writingStyles.append(english)
        settings.selectWritingStyle(english.id)
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).sanitized()
        XCTAssertEqual(reloaded.selectedWritingStyle, english)
        XCTAssertEqual(reloaded.customStyle, english.instructions)
        XCTAssertEqual(reloaded.defaultMode, .custom)
        XCTAssertEqual(reloaded.writingStyles.first { $0.id == WritingStyle.personalID }?.instructions,
                       "保留条件和不确定语气，先说结论。")
    }

    func testDefaultSelectionAndDeletedStyleFallBackToStandard() throws {
        let legacy = Data(#"{"defaultMode":"clear","customStyle":"我的旧规则"}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: legacy).sanitized()
        XCTAssertEqual(settings.selectedWritingStyle.id, WritingStyle.defaultID)
        XCTAssertEqual(settings.writingStyles.last?.instructions, "我的旧规则")
        settings.selectWritingStyle(WritingStyle.personalID)
        settings.writingStyles.removeAll { $0.id == WritingStyle.personalID }
        settings = settings.sanitized()
        XCTAssertEqual(settings.selectedWritingStyle.id, WritingStyle.defaultID)
        XCTAssertEqual(settings.defaultMode, .clear)
    }

    @MainActor func testStyleLibraryPersistsAcrossSettingsStoreRestarts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: file, secretReader: { _ in nil }, secretWriter: { _, _ in })
        XCTAssertEqual(store.settings.writingStyles.count, 2)
        XCTAssertEqual(store.settings.selectedWritingStyle.id, WritingStyle.defaultID)
        var draft = store.settings
        let style = WritingStyle(name: "简短直接", instructions: "句子简短，保留原语言、事实和条件。")
        draft.writingStyles.append(style)
        draft.selectWritingStyle(style.id)
        try store.save(draft)
        let reloaded = SettingsStore(fileURL: file, secretReader: { _ in nil }, secretWriter: { _, _ in })
        XCTAssertEqual(reloaded.settings.selectedWritingStyle, style)
    }

    @MainActor func testRepeatedVariantsKeepOriginalInputAndTrackUTF16Range() {
        let clipboard = ClipboardSnapshot(pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
        let capture = CaptureResult(sessionID: 1, text: "原文🙂", contextBefore: "前文：", contextAfter: "；后文",
                                    replacementRange: NSRange(location: 3, length: 4),
                                    sourceBundleID: nil, previousClipboard: clipboard)
        let first = RewriteSession(capture: capture, replacementText: "第一版👩‍💻", styleID: WritingStyle.defaultID)
        XCTAssertTrue(first.matches("前文：第一版👩‍💻；后文"))
        let second = first.replacing(with: "第二版表达更长一些。", styleID: WritingStyle.personalID)
        XCTAssertEqual(second.capture.text, "原文🙂")
        XCTAssertEqual(second.capture.contextBefore, "前文：")
        XCTAssertTrue(second.matches("前文：第二版表达更长一些。；后文"))
        XCTAssertFalse(second.matches("前文：用户已编辑这段文字；后文"))
        XCTAssertFalse(second.matches("短文本"))
    }
}
