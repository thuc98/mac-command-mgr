import Foundation

/// Turns escaped JSON found in logs (`{\"a\":\"b\"}`, `"{\"a\":1}"`, double-escaped variants)
/// back into plain text.
public enum JSONUnescape {
    /// Maximum escaping levels undone (`\\\"` inside `\"` …).
    static let maxLevels = 3

    /// The unescaped text, or nil when `text` has nothing to unescape.
    public static func unescape(_ text: String) -> String? {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        for _ in 0..<maxLevels {
            if isJSONContainer(current) { break }
            guard let decoded = decodeLiteral(current) ?? decodeEmbedded(current) else { break }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == current { break }
            current = trimmed
            changed = true
        }
        return changed ? current : nil
    }

    /// Unescaped and, when the result is a JSON object or array, indented (tokens kept as logged).
    public static func unescapeFormatted(_ text: String) -> String? {
        guard let plain = unescape(text) else { return nil }
        return LogDetail.prettyJSON(plain) ?? plain
    }

    /// Reads `text` as the contents of a JSON string literal (with or without its quotes).
    static func decodeLiteral(_ text: String) -> String? {
        let literal = text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") ? text : "\"\(text)\""
        return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
    }

    /// For selections with surrounding text (`payload="{\"a\":1}" ok`): decode from the first
    /// `{`/`[` to the last matching bracket.
    static func decodeEmbedded(_ text: String) -> String? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let close: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: close), end > start else { return nil }
        let inner = String(text[start...end])
        guard inner != text else { return nil }
        return decodeLiteral(inner)
    }

    static func isJSONContainer(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }
}
