import Darwin
import Foundation

/// Where a record starts on disk: the file (by inode, so it survives rotation renames) and the
/// byte offset of the record in it.
public struct LogPosition: Hashable, Sendable {
    public let file: UInt64
    public let offset: UInt64
}

/// One record of the log viewer. `id` is a sequence number in log order, unique for the lifetime
/// of one `LogTailReader` (earlier records loaded later get smaller, possibly negative, ids).
public struct LogRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let position: LogPosition
    /// Raw ISO-8601 stamp as written by `LogStore` (empty for lines without one). Parsed lazily.
    public let timestamp: String
    public let source: LogSource
    public let text: String
    /// Which log the record came from when several are merged (a group's commands); 0 otherwise.
    public let stream: Int

    public init(id: Int, position: LogPosition, timestamp: String, source: LogSource, text: String, stream: Int = 0) {
        self.id = id
        self.position = position
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.stream = stream
    }

    /// The same record with a new sequence number and stream.
    public func renumbered(_ id: Int, stream: Int) -> LogRow {
        LogRow(id: id, position: position, timestamp: timestamp, source: source, text: text, stream: stream)
    }

    /// Parsed on demand: the table only asks for rows on screen.
    public var date: Date? { LogTimestamp.parse(timestamp) }

    /// Approximate memory held by this row's strings.
    var byteCost: Int { text.utf8.count + timestamp.utf8.count + 64 }

    /// Case- and diacritic-insensitive substring match; an empty needle matches every row.
    public func matches(_ needle: String) -> Bool {
        needle.isEmpty || text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Keeps a selection only while its record is still among `rows`.
    public static func retainedSelection(_ selection: Int?, in rows: [LogRow]) -> Int? {
        guard let selection, let first = rows.first?.id, let last = rows.last?.id,
              selection >= first, selection <= last else { return nil }
        return selection
    }
}

/// Fast, allocation-free parser for the `yyyy-MM-ddTHH:mm:ss.SSSZ` stamps `LogStore` writes,
/// falling back to `ISO8601DateFormatter` for anything else.
public enum LogTimestamp {
    public static func parse(_ stamp: String) -> Date? {
        if stamp.isEmpty { return nil }
        var copy = stamp
        if let fast = copy.withUTF8(parseFast) { return fast }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp)
    }

    private static func parseFast(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
        // 2026-01-01T00:00:00.250Z
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
              b[b.count - 1] == 0x5A else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var value = 0
            for i in from..<(from + len) {
                let d = Int(b[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2),
              let mi = num(14, 2), let s = num(17, 2), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var fraction = 0.0
        if b.count > 20 {
            guard b[19] == 0x2E, b.count - 21 >= 1, b.count - 21 <= 9, let f = num(20, b.count - 21) else { return nil }
            fraction = Double(f) / pow(10, Double(b.count - 21))
        } else if b.count != 20 {
            return nil
        }
        // Days from civil (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days * 86_400 + h * 3_600 + mi * 60 + s) + fraction
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Reads a `LogStore` log incrementally: the first `poll()` loads the newest `initialBytes`, later
/// polls read only bytes appended since, following rotation (`x.log` → `x.log.1`) without losing
/// or repeating records. `loadEarlier()` pages older records in on demand.
///
/// Not thread-safe: use one instance from one serial queue.
public final class LogTailReader: @unchecked Sendable {
    public enum Update: Equatable, Sendable {
        case none
        /// New records after the last one returned.
        case appended([LogRow])
        /// The log was cleared, truncated or jumped too far ahead: replace everything.
        case reset([LogRow])
    }

    public let base: URL
    public let maxFiles: Int
    public let initialBytes: Int
    public let chunkBytes: Int
    /// Appends larger than this are not read through; the view resets to the newest tail instead.
    public let maxCatchUpBytes: Int

    /// Next byte to read; `file == nil` while waiting for the log file to (re)appear.
    private var cursor: (file: UInt64?, offset: UInt64)?
    /// First byte already returned; `file == nil` means "start of a missing current file".
    private var earliest: (file: UInt64?, offset: UInt64)?
    private var nextID = 0
    private var firstID = 0

    public init(logFile: URL, maxFiles: Int = 5, initialBytes: Int = 256 * 1024,
                chunkBytes: Int = 256 * 1024, maxCatchUpBytes: Int = 8 * 1024 * 1024) {
        base = logFile
        self.maxFiles = max(1, maxFiles)
        self.initialBytes = initialBytes
        self.chunkBytes = chunkBytes
        self.maxCatchUpBytes = maxCatchUpBytes
    }

    // MARK: Public

    public func poll() -> Update {
        guard let cursor else { return .reset(initialLoad()) }
        let now = Self.stat(base)
        if let file = cursor.file, now?.inode != file {
            // Our file left the current name: rotated (still on disk as .N) or deleted (cleared).
            guard let moved = locate(file), moved.index > 0 else { return .reset(initialLoad()) }
            guard moved.size >= cursor.offset, moved.size - cursor.offset <= UInt64(maxCatchUpBytes) else {
                return .reset(initialLoad())
            }
            var rows = readForward(moved.url, file: file, from: cursor.offset, to: moved.size).rows
            self.cursor = (nil, 0)
            if case .appended(let more) = poll() { rows += more }
            return rows.isEmpty ? .none : .appended(rows)
        }
        guard let now else { return .none }
        var offset = cursor.offset
        if cursor.file == nil { offset = 0 }
        if now.size < offset { return .reset(initialLoad()) }
        if now.size == offset { self.cursor = (now.inode, offset); return .none }
        if now.size - offset > UInt64(maxCatchUpBytes) { return .reset(initialLoad()) }
        let read = readForward(base, file: now.inode, from: offset, to: now.size)
        self.cursor = (now.inode, read.next)
        return read.rows.isEmpty ? .none : .appended(read.rows)
    }

    /// Whether older records exist before the first one returned.
    public var canLoadEarlier: Bool {
        guard let earliest else { return false }
        if earliest.offset > 0 { return true }
        let index = earliest.file.flatMap { locate($0)?.index } ?? 0
        return olderFile(after: index) != nil
    }

    /// Up to `maxBytes` of records immediately before the first one returned (oldest first).
    public func loadEarlier(maxBytes: Int? = nil) -> [LogRow] {
        let limit = UInt64(max(1, maxBytes ?? chunkBytes))
        guard var start = earliest else { return [] }
        var url: URL
        if start.offset == 0 {
            let index = start.file.flatMap { locate($0)?.index } ?? 0
            guard let older = olderFile(after: index) else { return [] }
            start = (older.inode, older.size)
            url = older.url
        } else {
            guard let file = start.file, let found = locate(file) else { earliest = nil; return [] }
            url = found.url
        }
        guard let file = start.file else { return [] }
        let from = start.offset > limit ? start.offset - limit : 0
        guard let bytes = Self.read(url, from: from, to: start.offset) else { return [] }
        var skip = 0
        if from > 0 {
            // Drop the partial first line; it is read with the next chunk.
            guard let newline = bytes.firstIndex(of: 0x0A) else { earliest = (file, from); return [] }
            skip = newline + 1
        }
        let count = Self.lineCount(bytes, from: skip)
        firstID -= count
        let rows = Self.parse(bytes, from: skip, file: file, baseOffset: from, firstID: firstID)
        earliest = (file, from + UInt64(skip))
        return rows
    }

    /// Moves the "earliest loaded" mark forward after the caller dropped its oldest rows, so a
    /// later `loadEarlier()` re-reads them instead of skipping them.
    public func forgetBefore(_ position: LogPosition) {
        earliest = (position.file, position.offset)
    }

    // MARK: Reading

    private func initialLoad() -> [LogRow] {
        nextID = 0
        firstID = 0
        guard let now = Self.stat(base) else {
            cursor = (nil, 0)
            earliest = (nil, 0)
            return fillUp([])
        }
        let from = now.size > UInt64(initialBytes) ? now.size - UInt64(initialBytes) : 0
        guard let bytes = Self.read(base, from: from, to: now.size) else {
            cursor = (nil, 0)
            earliest = (nil, 0)
            return []
        }
        var skip = 0
        if from > 0, let newline = bytes.firstIndex(of: 0x0A) { skip = newline + 1 }
        let end = bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? skip
        let usable = end > skip ? bytes[..<end] : bytes[..<skip]
        let rows = Self.parse(usable, from: skip, file: now.inode, baseOffset: from, firstID: 0)
        nextID = rows.count
        cursor = (now.inode, from + UInt64(max(end, skip)))
        earliest = (now.inode, from + UInt64(skip))
        return fillUp(rows)
    }

    /// Right after a rotation the current file is short: top up from older files.
    private func fillUp(_ rows: [LogRow]) -> [LogRow] {
        var rows = rows
        var bytes = rows.reduce(0) { $0 + $1.text.utf8.count + 32 }
        while bytes < initialBytes, canLoadEarlier {
            let earlier = loadEarlier(maxBytes: initialBytes - bytes)
            if earlier.isEmpty { break }
            bytes += earlier.reduce(0) { $0 + $1.text.utf8.count + 32 }
            rows = earlier + rows
        }
        return rows
    }

    /// Complete lines in `[from, to)`; `next` is where reading should continue.
    private func readForward(_ url: URL, file: UInt64, from: UInt64, to: UInt64) -> (rows: [LogRow], next: UInt64) {
        guard to > from, let bytes = Self.read(url, from: from, to: to),
              let last = bytes.lastIndex(of: 0x0A) else { return ([], from) }
        let usable = bytes[...last]
        let rows = Self.parse(usable, from: 0, file: file, baseOffset: from, firstID: nextID)
        nextID += rows.count
        return (rows, from + UInt64(last + 1))
    }

    // MARK: Files

    private struct FileInfo { let url: URL; let index: Int; let inode: UInt64; let size: UInt64 }

    private func url(_ index: Int) -> URL {
        index == 0 ? base : URL(fileURLWithPath: base.path + ".\(index)")
    }

    private func locate(_ inode: UInt64) -> FileInfo? {
        for index in 0..<maxFiles {
            let u = url(index)
            if let s = Self.stat(u), s.inode == inode { return FileInfo(url: u, index: index, inode: inode, size: s.size) }
        }
        return nil
    }

    private func olderFile(after index: Int) -> FileInfo? {
        let next = index + 1
        guard next < maxFiles else { return nil }
        let u = url(next)
        guard let s = Self.stat(u) else { return nil }
        return FileInfo(url: u, index: next, inode: s.inode, size: s.size)
    }

    private static func stat(_ url: URL) -> (inode: UInt64, size: UInt64)? {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return (UInt64(info.st_ino), UInt64(max(0, info.st_size)))
    }

    private static func read(_ url: URL, from: UInt64, to: UInt64) -> Data? {
        guard to > from, let handle = try? FileHandle(forReadingFrom: url) else { return to == from ? Data() : nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: from)
            return try handle.read(upToCount: Int(to - from)) ?? Data()
        } catch {
            return nil
        }
    }

    // MARK: Parsing

    /// Number of non-blank lines in `bytes[start...]` (matches what `parse` returns).
    static func lineCount(_ bytes: Data, from start: Int) -> Int {
        bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var count = 0
            var lineStart = start
            for i in start..<b.count where b[i] == 0x0A {
                if i > lineStart { count += 1 }
                lineStart = i + 1
            }
            return lineStart < b.count ? count + 1 : count
        }
    }

    /// Parses `<timestamp> [src] text` lines; blank lines are skipped. A trailing line without a
    /// newline is parsed too (callers pass only complete data).
    static func parse(_ bytes: Data, from start: Int, file: UInt64, baseOffset: UInt64, firstID: Int) -> [LogRow] {
        var rows: [LogRow] = []
        rows.reserveCapacity(max(0, (bytes.count - start) / 80))
        var id = firstID
        bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var lineStart = start
            var i = start
            func emit(_ end: Int) {
                if end > lineStart {
                    rows.append(parseLine(b, lineStart, end, id: id,
                                          position: LogPosition(file: file, offset: baseOffset + UInt64(lineStart))))
                    id += 1
                }
            }
            while i < b.count {
                if b[i] == 0x0A {
                    emit(i)
                    lineStart = i + 1
                }
                i += 1
            }
            emit(b.count)
        }
        return rows
    }

    private static func parseLine(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, id: Int,
                                  position: LogPosition) -> LogRow {
        func string(_ from: Int, _ to: Int) -> String {
            to > from ? String(decoding: UnsafeBufferPointer(rebasing: b[from..<to]), as: UTF8.self) : ""
        }
        // Format: "<timestamp> [out] text"
        var space = start
        while space < end, b[space] != 0x20 { space += 1 }
        if space + 6 <= end, b[space + 1] == 0x5B, b[space + 5] == 0x5D,
           space + 6 == end || b[space + 6] == 0x20,
           let source = LogSource(rawValue: string(space + 2, space + 5)) {
            let textStart = min(end, space + 7)
            return LogRow(id: id, position: position, timestamp: string(start, space), source: source,
                          text: string(textStart, end))
        }
        return LogRow(id: id, position: position, timestamp: "", source: .system, text: string(start, end))
    }
}
