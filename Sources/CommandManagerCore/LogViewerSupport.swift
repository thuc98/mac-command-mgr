import Foundation

/// How the inspector shows a record: JSON pretty-printed when the text is (or ends with) a JSON
/// object or array, the original text otherwise.
public struct LogDetail: Equatable, Sendable {
    /// Text before the JSON payload (e.g. "INFO request done"), nil when the whole line is JSON.
    public let prefix: String?
    /// Pretty-printed JSON, nil when the record is plain text.
    public let json: String?
    public let original: String

    public var isJSON: Bool { json != nil }

    /// Candidate start positions tried for a JSON payload after a text prefix.
    static let maxCandidates = 16

    public init(_ text: String) {
        original = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pretty = Self.prettyJSON(trimmed) {
            prefix = nil
            json = pretty
            return
        }
        // "<prefix> {json}" — try each "{" / "[" (left to right) whose remainder parses.
        var tried = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, tried < Self.maxCandidates {
            let char = trimmed[index]
            if char == "{" || char == "[", index != trimmed.startIndex {
                tried += 1
                let candidate = String(trimmed[index...])
                if Self.isStructuredPayload(candidate), let pretty = Self.prettyJSON(candidate) {
                    let head = trimmed[..<index].trimmingCharacters(in: .whitespaces)
                    prefix = head.isEmpty ? nil : head
                    json = pretty
                    return
                }
            }
            index = trimmed.index(after: index)
        }
        prefix = nil
        json = nil
    }

    /// Pretty-prints `text` when it is exactly one JSON object or array; nil otherwise. The original
    /// tokens are kept (numbers, escapes and key order are shown as logged, not re-encoded).
    public static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last,
              (first == "{" && last == "}") || (first == "[" && last == "]"),
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        else { return nil }
        return reindent(trimmed)
    }

    /// A JSON payload after a text prefix must look like structured data — a non-empty object or a
    /// non-empty array of objects/arrays — so "items [3]" or "args: []" stay plain text.
    static func isStructuredPayload(_ text: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return false }
        if let dictionary = object as? [String: Any] { return !dictionary.isEmpty }
        if let array = object as? [Any] {
            return !array.isEmpty && array.allSatisfy { $0 is [String: Any] || $0 is [Any] }
        }
        return false
    }

    /// Re-indents valid JSON by two spaces without re-encoding any token.
    static func reindent(_ json: String) -> String {
        let chars = Array(json)
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(c)
                    out.append(chars[j])
                    i = j + 1
                    continue
                }
                out.append(c)
                depth += 1
                newline()
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out += ": "
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }
}
