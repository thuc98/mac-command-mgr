import Foundation

/// Finds the parts of a log record that match the filter text, with the same rules as
/// `LogRow.matches` (case- and diacritic-insensitive), as `NSRange`s for attributed strings.
public enum LogHighlight {
    /// Cap so a pathological record (e.g. one character repeated 64 KB) stays cheap to style.
    public static let maxRanges = 200

    public static func ranges(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        let haystack = text as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: haystack.length)
        while ranges.count < maxRanges, search.length > 0 {
            let found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            let next = found.location + found.length
            search = NSRange(location: next, length: haystack.length - next)
        }
        return ranges
    }
}
