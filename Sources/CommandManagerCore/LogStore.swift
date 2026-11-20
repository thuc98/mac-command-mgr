import Foundation

public enum LogSource: String, Codable, CaseIterable, Sendable {
    case stdout = "out"
    case stderr = "err"
    /// Lifecycle events written by Command Manager itself (start, stop, exit...).
    case system = "sys"
}

public struct LogLine: Equatable, Identifiable, Sendable {
    public let id: Int
    public let timestamp: String
    public let source: LogSource
    public let text: String

    /// Case- and diacritic-insensitive substring match on the line's text; an empty or
    /// whitespace-only query matches every line.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Per-service log files with timestamp/source tagging and size-capped rotation.
/// All writes are serialized on one queue so lines keep the order they were received in.
public final class LogStore: @unchecked Sendable {
    public let directory: URL
    public let maxBytesPerFile: UInt64
    public let maxFiles: Int

    /// A line without a newline is written out once it reaches this size (progress bars, binary output).
    static let maxPartialLineBytes = 64 * 1024

    private let queue = DispatchQueue(label: "CommandManager.LogStore")
    private var reportedWriteFailure: Set<UUID> = []
    private var handles: [UUID: FileHandle] = [:]
    private var partial: [String: Data] = [:]
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Defaults follow the plan: 10 MiB per file, 5 files kept per service.
    public init(directory: URL, maxBytesPerFile: UInt64 = 10 * 1024 * 1024, maxFiles: Int = 5) {
        self.directory = directory
        self.maxBytesPerFile = maxBytesPerFile
        self.maxFiles = max(1, maxFiles)
    }

    public func logFileURL(for serviceID: UUID) -> URL {
        directory.appendingPathComponent("\(serviceID.uuidString).log")
    }

    /// Appends raw process output; complete lines are written, a trailing partial line is buffered.
    public func append(_ data: Data, source: LogSource, serviceID: UUID) {
        queue.async { [self] in
            let key = "\(serviceID.uuidString)|\(source.rawValue)"
            let bytes = [UInt8]((partial[key] ?? Data()) + data)
            var lineStart = 0
            var index = 0
            // "\n", "\r\n" and a bare "\r" (progress redraws) all end a line. Single pass, no re-copying.
            while index < bytes.count {
                let byte = bytes[index]
                guard byte == 0x0A || byte == 0x0D else { index += 1; continue }
                // A trailing "\r" may be the first half of a "\r\n" split across reads: wait for more.
                if byte == 0x0D, index == bytes.count - 1 { break }
                let line = bytes[lineStart..<index]
                // Empty segments between carriage returns are redraw noise; keep real blank lines.
                if !(line.isEmpty && byte == 0x0D) {
                    writeLine(String(decoding: line, as: UTF8.self), source: source, serviceID: serviceID)
                }
                index += (byte == 0x0D && bytes[index + 1] == 0x0A) ? 2 : 1
                lineStart = index
            }
            // Cap a line that never ends, cutting on a UTF-8 character boundary.
            while bytes.count - lineStart > Self.maxPartialLineBytes {
                var cut = lineStart + Self.maxPartialLineBytes
                while cut < bytes.count, cut > lineStart + 1, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
                writeLine(String(decoding: bytes[lineStart..<cut], as: UTF8.self), source: source, serviceID: serviceID)
                lineStart = cut
            }
            partial[key] = lineStart < bytes.count ? Data(bytes[lineStart...]) : nil
        }
    }

    public func appendEvent(_ message: String, serviceID: UUID) {
        queue.async { [self] in writeLine(message, source: .system, serviceID: serviceID) }
    }

    /// Writes any buffered partial lines (call when a process ends).
    public func flush(serviceID: UUID) {
        queue.async { [self] in
            for source in [LogSource.stdout, .stderr] {
                let key = "\(serviceID.uuidString)|\(source.rawValue)"
                if let rest = partial.removeValue(forKey: key), !rest.isEmpty {
                    writeLine(String(decoding: rest, as: UTF8.self), source: source, serviceID: serviceID)
                }
            }
        }
    }

    /// Deletes the service's log (current and rotated files). Output already queued before this
    /// call is discarded too; a running command keeps logging into a fresh file.
    public func clear(serviceID: UUID) {
        queue.sync {
            try? handles.removeValue(forKey: serviceID)?.close()
            for source in [LogSource.stdout, .stderr] { partial.removeValue(forKey: "\(serviceID.uuidString)|\(source.rawValue)") }
            let base = logFileURL(for: serviceID)
            try? FileManager.default.removeItem(at: base)
            for n in 1...max(1, maxFiles) {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: base.path + ".\(n)"))
            }
        }
    }

    /// Waits until all queued writes are on disk (used by tests and before reading).
    public func sync() { queue.sync {} }

    /// Last lines of the log (up to `maxBytes` from the end), continuing into the
    /// most recent rotated file when the current one is short.
    public func tail(serviceID: UUID, maxBytes: Int = 256 * 1024) -> [LogLine] {
        // Only the file reads wait for queued writes; parsing runs outside the queue so a large
        // tail never holds up logging.
        let (data, truncated): (Data, Bool) = queue.sync {
            let base = logFileURL(for: serviceID)
            var (data, truncated) = Self.readTail(of: base, maxBytes: maxBytes)
            if !truncated, data.count < maxBytes {
                let previous = Self.readTail(of: URL(fileURLWithPath: base.path + ".1"), maxBytes: maxBytes - data.count)
                data = previous.data + data
                truncated = previous.truncated
            }
            return (data, truncated)
        }
        var text = String(decoding: data, as: UTF8.self)
        if truncated, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .map { Self.parse(String($0.element), id: $0.offset) }
    }

    private static func readTail(of url: URL, maxBytes: Int) -> (data: Data, truncated: Bool) {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return ((try? handle.readToEnd()) ?? Data(), start > 0)
    }

    public func closeAll() {
        queue.sync {
            handles.values.forEach { try? $0.close() }
            handles.removeAll()
        }
    }

    static func parse(_ line: String, id: Int) -> LogLine {
        // Format: "<timestamp> [out] text"
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count >= 2, parts[1].count == 5, parts[1].hasPrefix("["), parts[1].hasSuffix("]"),
           let source = LogSource(rawValue: String(parts[1].dropFirst().dropLast())) {
            return LogLine(id: id, timestamp: String(parts[0]), source: source, text: parts.count > 2 ? String(parts[2]) : "")
        }
        return LogLine(id: id, timestamp: "", source: .system, text: line)
    }

    // MARK: - Queue-confined helpers

    private func writeLine(_ text: String, source: LogSource, serviceID: UUID) {
        let sanitized = text.replacingOccurrences(of: "\r", with: "")
        let line = "\(formatter.string(from: Date())) [\(source.rawValue)] \(sanitized)\n"
        guard let handle = handle(for: serviceID) else { return }
        // Throwing APIs only: a full disk must not raise an Objective-C exception and crash the app.
        do {
            try handle.write(contentsOf: Data(line.utf8))
            if try handle.offset() >= maxBytesPerFile { rotate(serviceID) }
            reportedWriteFailure.remove(serviceID)
        } catch {
            try? handles.removeValue(forKey: serviceID)?.close()
            if reportedWriteFailure.insert(serviceID).inserted {
                NSLog("Command Manager: cannot write log for %@: %@", serviceID.uuidString, error.localizedDescription)
            }
        }
    }

    private func handle(for serviceID: UUID) -> FileHandle? {
        if let existing = handles[serviceID] { return existing }
        let url = logFileURL(for: serviceID)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        guard (try? handle.seekToEnd()) != nil else { try? handle.close(); return nil }
        handles[serviceID] = handle
        return handle
    }

    private func rotate(_ serviceID: UUID) {
        try? handles.removeValue(forKey: serviceID)?.close()
        let fm = FileManager.default
        let base = logFileURL(for: serviceID)
        func rotated(_ n: Int) -> URL { URL(fileURLWithPath: base.path + ".\(n)") }
        let keep = maxFiles - 1
        if keep == 0 { try? fm.removeItem(at: base); return }
        try? fm.removeItem(at: rotated(keep))
        if keep > 1 {
            for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: rotated(n).path) {
                try? fm.moveItem(at: rotated(n), to: rotated(n + 1))
            }
        }
        try? fm.moveItem(at: base, to: rotated(1))
    }
}
