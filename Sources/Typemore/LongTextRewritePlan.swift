import Foundation
import NaturalLanguage

struct RewriteProgress: Sendable {
    let completed: Int
    let total: Int
}

/// 请求大小与全文长度无关；分割仅发生在 Character 边界，保留所有原始分隔符。
struct RewriteUnit: Sendable {
    let raw: String

    var text: String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    var leading: String { String(raw.prefix(while: { $0.isWhitespace })) }
    var trailing: String { String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed()) }

    func restoringWhitespace(around output: String) -> String {
        text.isEmpty ? raw : leading + output + trailing
    }
}

struct RewriteChunk: Sendable {
    let units: [RewriteUnit]
    let contextBefore: String
    let contextAfter: String
}

enum LongTextRewritePlan {
    static let chunkSize = 1800
    static let unitSize = 240
    static let contextSize = 320

    static func units(for text: String, limit: Int = unitSize) -> [RewriteUnit] {
        let characters = Array(text)
        let protectedRanges = RewriteIntegrity.atomicRanges(in: text)
        var result: [RewriteUnit] = []
        var start = 0
        while start < characters.count {
            var end = min(start + limit, characters.count)
            if let newline = (start..<end).first(where: { characters[$0].isNewline }) {
                end = newline + 1
            } else if end < characters.count {
                let minimum = start + limit / 2
                if let boundary = (minimum..<end).reversed().first(where: {
                    characters[$0].isNewline || "。！？!?；;".contains(characters[$0])
                }) {
                    end = boundary + 1
                } else if let boundary = (minimum..<end).reversed().first(where: { characters[$0].isWhitespace }) {
                    end = boundary + 1
                }
            }
            if let range = protectedRanges.first(where: { $0.lowerBound < end && end < $0.upperBound }) {
                end = range.lowerBound > start ? range.lowerBound : range.upperBound
            }
            // 一并保留切点后的空白，避免拼接时丢失换行或重复添加分隔符。
            while end < characters.count, characters[end].isWhitespace { end += 1 }
            result.append(RewriteUnit(raw: String(characters[start..<end])))
            start = end
        }
        return result
    }

    static func chunks(for source: String, before: String, after: String) -> [RewriteChunk] {
        var groups: [[RewriteUnit]] = []
        var group: [RewriteUnit] = []
        var count = 0
        for unit in units(for: source) {
            if !group.isEmpty, count + unit.raw.count > chunkSize || group.count >= 8 {
                groups.append(group)
                group = []
                count = 0
            }
            group.append(unit)
            count += unit.raw.count
        }
        if !group.isEmpty { groups.append(group) }
        var previous = String(before.suffix(contextSize))
        return groups.enumerated().map { index, units in
            let following = index + 1 < groups.count
                ? groups[index + 1].map(\.raw).joined() : after
            let chunk = RewriteChunk(units: units, contextBefore: previous,
                                     contextAfter: String(following.prefix(contextSize)))
            previous = String((previous + units.map(\.raw).joined()).suffix(contextSize))
            return chunk
        }
    }
}

/// 唯一标记验证每个分段和结束标记都返回了；标记只用于传输，不进入用户文本。
struct RewriteEnvelope {
    let units: [RewriteUnit]
    private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private func marker(_ index: Int) -> String { "[[TM_\(nonce)_\(index)]]" }
    private var endMarker: String { "[[TM_\(nonce)_END]]" }

    private func protectedIntents(in index: Int) -> [(literal: String, marker: String, range: NSRange)] {
        let text = units[index].text
        let regex = try! NSRegularExpression(pattern: RewriteIntegrity.intentPattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map { offset, match in
            let literal = (text as NSString).substring(with: match.range)
            return (literal, "[[TM_\(nonce)_INTENT_\(index)_\(offset)_\(literal)]]", match.range)
        }
    }

    private func transportText(in index: Int) -> String {
        let text = NSMutableString(string: units[index].text)
        for value in protectedIntents(in: index).reversed() {
            text.replaceCharacters(in: value.range, with: value.marker)
        }
        return text as String
    }

    var instruction: String {
        """
        Transport format for this request: return each rewritten block after its exact marker, \
        in the original order, and finish with the exact end marker. These transport markers \
        override the plain-text-only output format. Do not translate or change the markers. \
        Rewrite EVERY block in full; never summarize, skip, merge, or repeat a block. \
        Preserve all facts and qualifications, and all paragraphs inside each block. \
        Keep every occurrence of each number in digit form, identifier, URL, path and emoji \
        literally unchanged. Repeated details must remain at each original occurrence; \
        do not deduplicate them. Never shorten a URL or split its query string. \
        Keep every occurrence of the source words 希望, 期望, 计划, 可能, 如果, 除非, 假如, \
        may, might and unless literally unchanged; do not replace or omit these \
        intent, uncertainty and condition anchors. \
        An INTENT marker inside target_text stands for the word named at its end, \
        e.g. an INTENT marker ending in 希望 means 希望. Keep each entire INTENT marker \
        exactly once in the same block, with the meaning of that word. \
        Rewrite around the marker; the client restores the original word afterward. \
        Keep requests and proposals as requests: 希望/期望/计划 must never become 已实现/已完成. \
        Preserve each action and its condition, including sending after verification. \
        Keep an if/unless clause and its dependent action together in the same sentence \
        or bullet; do not split them into separate unconditional instructions. \
        An English if clause may use an equivalent condition such as provided that; \
        keep it attached to the original action and never attach it to another action. \
        Do not remove an action just because its condition or a related restriction is stated. \
        Keep the paragraph and list structure inside each block. Do not add headings, \
        bullet points or numbered lists unless the custom writing style explicitly asks for them. \
        Blocks are contiguous parts of one document, not independent reports. \
        source_language is the original language of each block. This is a same-language \
        rewrite: keep English blocks in English and Chinese blocks in Chinese. \
        Do not translate unless the custom style explicitly requests translation. \
        Context is for reference only and must not appear in the output.
        """
    }

    func payload(before: String, after: String) -> String {
        let blocks = units.enumerated().map {
            ["marker": marker($0.offset), "target_text": transportText(in: $0.offset),
             "source_language": NLLanguageRecognizer.dominantLanguage(for: $0.element.text)?.rawValue ?? "und"]
        }
        let value: [String: Any] = ["blocks": blocks, "context_before": String(before.suffix(320)),
                                  "context_after": String(after.prefix(320)), "end_marker": endMarker]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func decode(_ output: String, preserveLanguage: Bool = false) throws -> String {
        let markers = units.indices.map(marker) + [endMarker]
        var cursor = output.startIndex
        var pieces: [String] = []
        for (index, tag) in markers.enumerated() {
            guard let range = output.range(of: tag, range: cursor..<output.endIndex),
                  output.range(of: tag, range: range.upperBound..<output.endIndex) == nil else {
                throw RewriteError.incompleteOutput
            }
            let between = String(output[cursor..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 {
                guard between.isEmpty else { throw RewriteError.incompleteOutput }
            } else {
                guard !between.isEmpty || units[index - 1].text.isEmpty else { throw RewriteError.incompleteOutput }
                var restored = between
                for value in protectedIntents(in: index - 1) {
                    guard restored.components(separatedBy: value.marker).count - 1 == 1 else {
                        throw RewriteError.incompleteOutput
                    }
                    restored = restored.replacingOccurrences(of: value.marker, with: value.literal)
                }
                guard !restored.contains("[[TM_\(nonce)_") else { throw RewriteError.incompleteOutput }
                try RewriteIntegrity.validate(source: units[index - 1].text, output: restored,
                                              preserveLanguage: preserveLanguage)
                pieces.append(units[index - 1].restoringWhitespace(around: restored))
            }
            cursor = range.upperBound
        }
        guard output[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewriteError.incompleteOutput
        }
        return pieces.joined()
    }
}

enum RewriteIntegrity {
    // 将 URL、路径、编号视为原子内容，不在其中切分。中文标点不属于 URL。
    private static let patterns = [
        #"[A-Za-z][A-Za-z0-9+.-]*://[^\s\p{Han}，。！？；、<>\"“”]+"#,
        #"(?<![A-Za-z0-9])/(?:[A-Za-z0-9_.~%+-]+/)*[A-Za-z0-9_.~%+-]+"#,
        #"\b[A-Za-z]+(?:[-_][A-Za-z0-9]+)+\b"#,
        #"\bv?\d+(?:[.,:/_-]\d+)+(?:%|\b)"#
    ]
    fileprivate static let intentPattern = #"希望|期望|计划|可能|如果|除非|假如|\b(?:may|might|[Uu]nless)\b"#
    private static let ifPattern = #"\bif\b"#
    private static let equivalentIfPattern = #"\b(?:if|provided(?:\s+that)?|on\s+condition\s+that|assuming|as\s+long\s+as|conditional\s+(?:on|upon)|contingent\s+(?:on|upon))\b"#
    private static let numberPattern = #"(?<![A-Za-z0-9])[$¥€£]?\d+(?:[.,:]\d+)*%?(?![A-Za-z0-9])"#

    static func atomicRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offsets = [0: 0]
        var utf16Offset = 0
        for (index, character) in text.enumerated() {
            utf16Offset += String(character).utf16.count
            offsets[utf16Offset] = index + 1
        }
        for pattern in patterns + [intentPattern, ifPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let start = offsets[match.range.location], let end = offsets[NSMaxRange(match.range)] else { continue }
                ranges.append(start..<end)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func validate(source: String, output: String, preserveLanguage: Bool = false) throws {
        func conditionCount(in text: String, pattern: String) -> Int {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        // 接受 if → provided that 等同义改写，仍拒绝没有条件关系的独立指令。
        guard conditionCount(in: output, pattern: equivalentIfPattern) >= conditionCount(in: source, pattern: ifPattern) else {
            throw RewriteError.incompleteOutput
        }
        if preserveLanguage, source.count >= 20, output.count >= 20,
           let before = NLLanguageRecognizer.dominantLanguage(for: source),
           let after = NLLanguageRecognizer.dominantLanguage(for: output),
           before != after {
            let chinese: Set<NLLanguage> = [.simplifiedChinese, .traditionalChinese]
            guard chinese.contains(before) && chinese.contains(after) else { throw RewriteError.incompleteOutput }
        }
        func literals(in text: String) -> [String: Int] {
            var literals: [String: Int] = [:]
            for pattern in patterns + [numberPattern, intentPattern] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                var occurrences: [String: Int] = [:]
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    occurrences[String(text[range]), default: 0] += 1
                }
                for (literal, count) in occurrences { literals[literal] = max(literals[literal, default: 0], count) }
            }
            for character in text {
                if character.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F }) {
                    literals[String(character), default: 0] += 1
                }
            }
            return literals
        }
        let expected = literals(in: source)
        let actual = literals(in: output)
        for (literal, count) in expected where actual[literal, default: 0] < count {
            throw RewriteError.incompleteOutput
        }
    }
}
