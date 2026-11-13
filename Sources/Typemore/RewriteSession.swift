import Foundation

struct RewriteSession {
    let capture: CaptureResult
    var replacementText: String
    var replacementRange: NSRange?
    var styleID: UUID

    init(capture: CaptureResult, replacementText: String, styleID: UUID, replacementRange: NSRange? = nil) {
        self.capture = capture
        self.replacementText = replacementText
        self.styleID = styleID
        self.replacementRange = replacementRange ?? capture.replacementRange.map {
            NSRange(location: $0.location, length: (replacementText as NSString).length)
        }
    }

    func matches(_ fieldText: String) -> Bool {
        guard let range = replacementRange, range.location >= 0,
              NSMaxRange(range) <= (fieldText as NSString).length else { return false }
        return (fieldText as NSString).substring(with: range) == replacementText
    }

    func replacing(with text: String, styleID: UUID) -> RewriteSession {
        RewriteSession(capture: capture, replacementText: text, styleID: styleID,
                       replacementRange: replacementRange.map { NSRange(location: $0.location, length: (text as NSString).length) })
    }
}
