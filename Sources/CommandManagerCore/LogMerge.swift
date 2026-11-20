import Foundation

/// Interleaves records read from several logs (one per command of a group) in time order.
public enum LogMerge {
    /// Merges `batches` (each already in log order; batch index = stream) by timestamp and numbers
    /// the result from `firstID`. Ties keep stream order; a record without a timestamp stays right
    /// after the record before it in its own log.
    public static func merge(_ batches: [[LogRow]], firstID: Int) -> [LogRow] {
        let nonEmpty = batches.enumerated().filter { !$0.element.isEmpty }
        if nonEmpty.count <= 1 {
            guard let (stream, rows) = nonEmpty.first else { return [] }
            return rows.enumerated().map { $0.element.renumbered(firstID + $0.offset, stream: stream) }
        }
        var keyed: [(key: String, stream: Int, order: Int, row: LogRow)] = []
        keyed.reserveCapacity(nonEmpty.reduce(0) { $0 + $1.element.count })
        for (stream, rows) in nonEmpty {
            var last = ""
            for (order, row) in rows.enumerated() {
                if !row.timestamp.isEmpty { last = row.timestamp }
                keyed.append((last, stream, order, row))
            }
        }
        // ISO-8601 UTC stamps of one fixed format sort correctly as strings.
        keyed.sort { a, b in
            if a.key != b.key { return a.key < b.key }
            if a.stream != b.stream { return a.stream < b.stream }
            return a.order < b.order
        }
        return keyed.enumerated().map { $0.element.row.renumbered(firstID + $0.offset, stream: $0.element.stream) }
    }
}
