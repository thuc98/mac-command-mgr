import Foundation
import Testing
@testable import CommandManagerCore

@Suite struct LogDetailTests {
    @Test func plainTextStaysOriginal() {
        let detail = LogDetail("  server listening on :3000  ")
        #expect(!detail.isJSON)
        #expect(detail.json == nil)
        #expect(detail.prefix == nil)
        #expect(detail.original == "  server listening on :3000  ")
    }

    @Test func wholeLineObjectIsPrettyPrintedKeepingTokensAndOrder() {
        let detail = LogDetail(#" {"b":1.1,"a":{"url":"http:\/\/x/y","s":"a, {b}: \"c\""},"e":[],"n":null} "#)
        #expect(detail.prefix == nil)
        #expect(detail.json == #"""
        {
          "b": 1.1,
          "a": {
            "url": "http:\/\/x/y",
            "s": "a, {b}: \"c\""
          },
          "e": [],
          "n": null
        }
        """#)
    }

    @Test func arrayIsPrettyPrinted() {
        #expect(LogDetail("[1, 2]").json == "[\n  1,\n  2\n]")
    }

    @Test func invalidOrPartialJSONStaysPlain() {
        for text in [#"{"a":1"#, "{not json}", "[INFO] done", #"{"a":1} trailing"#, "42", #""str""#, "{}x"] {
            #expect(LogDetail(text).json == nil, "\(text)")
        }
    }

    @Test func jsonAfterTextPrefixIsDetected() {
        let detail = LogDetail(#"[INFO] request done {"status":200}"#)
        #expect(detail.prefix == "[INFO] request done")
        #expect(detail.json == "{\n  \"status\": 200\n}")
    }

    @Test func bracketedTextAfterPrefixStaysPlain() {
        for text in ["Loaded items [3]", "args: []", "retry {}", "values [1, 2]"] {
            #expect(LogDetail(text).json == nil, "\(text)")
        }
        #expect(LogDetail(#"rows [{"id":1}]"#).prefix == "rows")
    }

    @Test func prettyJSONRejectsScalars() {
        #expect(LogDetail.prettyJSON("true") == nil)
        #expect(LogDetail.prettyJSON("{ }") == "{}")
    }
}

@Suite struct LogTailReaderTests {
    private let dir = makeTempDirectory()
    private var file: URL { dir.appendingPathComponent("svc.log") }

    private func line(_ n: Int, _ source: String = "out") -> String {
        "2026-01-01T00:00:\(String(format: "%02d", n % 60)).000Z [\(source)] line \(n)\n"
    }

    private func write(_ text: String, to url: URL? = nil) throws {
        let url = url ?? file
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func texts(_ update: LogTailReader.Update) -> [String] {
        switch update {
        case .none: return []
        case .appended(let rows), .reset(let rows): return rows.map(\.text)
        }
    }

    @Test func firstPollLoadsTailThenOnlyNewLines() throws {
        try write(line(1) + line(2))
        let reader = LogTailReader(logFile: file)
        let first = reader.poll()
        guard case .reset(let rows) = first else { Issue.record("expected reset"); return }
        #expect(rows.map(\.text) == ["line 1", "line 2"])
        #expect(rows.map(\.id) == [0, 1])
        #expect(reader.poll() == .none)
        try write(line(3, "err"))
        guard case .appended(let more) = reader.poll() else { Issue.record("expected append"); return }
        #expect(more.map(\.text) == ["line 3"])
        #expect(more[0].source == .stderr)
        #expect(more[0].id == 2)
    }

    @Test func partialLineWaitsForItsNewline() throws {
        try write(line(1))
        let reader = LogTailReader(logFile: file)
        _ = reader.poll()
        try write("2026-01-01T00:00:02.000Z [out] half")
        #expect(reader.poll() == .none)
        try write(" done\n")
        #expect(texts(reader.poll()) == ["half done"])
    }

    @Test func rotationKeepsEveryLineOnce() throws {
        try write(line(1))
        let reader = LogTailReader(logFile: file)
        _ = reader.poll()
        try write(line(2))
        // LogStore rotation: current file becomes .1, a fresh file takes its name.
        try FileManager.default.moveItem(at: file, to: URL(fileURLWithPath: file.path + ".1"))
        try write(line(3))
        #expect(texts(reader.poll()) == ["line 2", "line 3"])
        try write(line(4))
        #expect(texts(reader.poll()) == ["line 4"])
    }

    @Test func clearedLogResets() throws {
        try write(line(1))
        let reader = LogTailReader(logFile: file)
        _ = reader.poll()
        try FileManager.default.removeItem(at: file)
        #expect(reader.poll() == .reset([]))
        try write(line(2))
        #expect(texts(reader.poll()) == ["line 2"])
    }

    @Test func truncatedLogResets() throws {
        try write(line(1) + line(2))
        let reader = LogTailReader(logFile: file)
        _ = reader.poll()
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try write(line(9))
        guard case .reset(let rows) = reader.poll() else { Issue.record("expected reset"); return }
        #expect(rows.map(\.text) == ["line 9"])
    }

    @Test func earlierRecordsPageInAcrossRotatedFiles() throws {
        let older = URL(fileURLWithPath: file.path + ".1")
        try write((0..<50).map { line($0) }.joined(), to: older)
        try write((50..<100).map { line($0) }.joined())
        let chunk = line(0).utf8.count * 20 + 10
        let reader = LogTailReader(logFile: file, initialBytes: chunk, chunkBytes: chunk)
        guard case .reset(var rows) = reader.poll() else { Issue.record("expected reset"); return }
        #expect((15...20).contains(rows.count))
        #expect(rows.last?.text == "line 99")
        while reader.canLoadEarlier {
            let earlier = reader.loadEarlier()
            #expect(!earlier.isEmpty)
            rows = earlier + rows
        }
        #expect(rows.map(\.text) == (0..<100).map { "line \($0)" })
        #expect(rows.map(\.id) == Array(rows.first!.id...rows.last!.id))
    }

    @Test func forgetBeforeReloadsDroppedRows() throws {
        try write((0..<10).map { line($0) }.joined())
        let reader = LogTailReader(logFile: file)
        guard case .reset(let rows) = reader.poll() else { Issue.record("expected reset"); return }
        #expect(!reader.canLoadEarlier)
        reader.forgetBefore(rows[4].position)
        #expect(reader.canLoadEarlier)
        #expect(reader.loadEarlier().map(\.text) == (0..<4).map { "line \($0)" })
    }

    @Test func linesWithoutStampAreSystemRows() throws {
        try write("plain text\n\n2026-01-01T00:00:00.000Z [sys] Started\n")
        let reader = LogTailReader(logFile: file)
        guard case .reset(let rows) = reader.poll() else { Issue.record("expected reset"); return }
        #expect(rows.map(\.text) == ["plain text", "Started"])
        #expect(rows.map(\.timestamp) == ["", "2026-01-01T00:00:00.000Z"])
        #expect(rows[0].date == nil)
    }

    @Test func retainedSelectionFollowsLoadedRange() throws {
        try write(line(1) + line(2))
        let reader = LogTailReader(logFile: file)
        guard case .reset(let rows) = reader.poll() else { Issue.record("expected reset"); return }
        #expect(LogRow.retainedSelection(1, in: rows) == 1)
        #expect(LogRow.retainedSelection(0, in: Array(rows.dropFirst())) == nil)
        #expect(LogRow.retainedSelection(nil, in: rows) == nil)
    }
}

@Suite struct LogTimestampTests {
    @Test func parsesStoreStamps() {
        #expect(LogTimestamp.parse("2026-01-01T00:00:00.250Z") == Date(timeIntervalSince1970: 1_767_225_600.25))
        #expect(LogTimestamp.parse("1999-12-31T23:59:59Z") == Date(timeIntervalSince1970: 946_684_799))
        #expect(LogTimestamp.parse("2024-02-29T12:00:00.5Z") == Date(timeIntervalSince1970: 1_709_208_000.5))
    }

    @Test func rejectsGarbage() {
        #expect(LogTimestamp.parse("") == nil)
        #expect(LogTimestamp.parse("not a date") == nil)
    }
}

@Suite struct LogHighlightTests {
    private func pieces(_ needle: String, _ text: String) -> [String] {
        LogHighlight.ranges(of: needle, in: text).map { (text as NSString).substring(with: $0) }
    }

    @Test func findsEveryMatchIgnoringCaseAndDiacritics() {
        #expect(pieces("error", "Error: x ERROR y error") == ["Error", "ERROR", "error"])
        #expect(pieces("don hang", "Đơn hàng mới, don hang cũ") == ["don hang"])
        #expect(pieces("hang", "Đơn hàng mới") == ["hàng"])
    }

    @Test func emptyOrMissingNeedleFindsNothing() {
        #expect(LogHighlight.ranges(of: "", in: "abc").isEmpty)
        #expect(LogHighlight.ranges(of: "zzz", in: "abc").isEmpty)
    }

    @Test func overlappingCandidatesDoNotLoop() {
        #expect(pieces("aa", "aaaa") == ["aa", "aa"])
        #expect(LogHighlight.ranges(of: "a", in: String(repeating: "a", count: 5000)).count == LogHighlight.maxRanges)
    }

    @Test func rangesUseUTF16Offsets() {
        let text = "😀 ok"
        #expect(LogHighlight.ranges(of: "ok", in: text) == [NSRange(location: 3, length: 2)])
    }
}

@Suite struct LogMergeTests {
    private func row(_ ts: String, _ text: String) -> LogRow {
        LogRow(id: 0, position: LogPosition(file: 1, offset: 0), timestamp: ts, source: .stdout, text: text)
    }

    @Test func interleavesByTimeAndNumbersInOrder() {
        let a = [row("2026-01-01T00:00:01.000Z", "a1"), row("2026-01-01T00:00:03.000Z", "a3")]
        let b = [row("2026-01-01T00:00:02.000Z", "b2"), row("2026-01-01T00:00:04.000Z", "b4")]
        let merged = LogMerge.merge([a, b], firstID: 10)
        #expect(merged.map(\.text) == ["a1", "b2", "a3", "b4"])
        #expect(merged.map(\.stream) == [0, 1, 0, 1])
        #expect(merged.map(\.id) == [10, 11, 12, 13])
    }

    @Test func unstampedLinesStayWithTheirPredecessor() {
        let a = [row("2026-01-01T00:00:01.000Z", "a1"), row("", "a1-continued"), row("2026-01-01T00:00:05.000Z", "a5")]
        let b = [row("2026-01-01T00:00:02.000Z", "b2")]
        #expect(LogMerge.merge([a, b], firstID: 0).map(\.text) == ["a1", "a1-continued", "b2", "a5"])
    }

    @Test func tiesKeepStreamOrderAndSingleBatchKeepsItsStream() {
        let ts = "2026-01-01T00:00:01.000Z"
        #expect(LogMerge.merge([[row(ts, "a")], [row(ts, "b")]], firstID: 0).map(\.text) == ["a", "b"])
        let single = LogMerge.merge([[], [row(ts, "x")]], firstID: -3)
        #expect(single.map(\.stream) == [1])
        #expect(single.map(\.id) == [-3])
    }
}

@Suite struct JSONUnescapeTests {
    @Test func unescapesEscapedObject() {
        #expect(JSONUnescape.unescape(#"{\"a\":\"b\",\"n\":1.10}"#) == #"{"a":"b","n":1.10}"#)
    }

    @Test func unescapesQuotedStringLiteral() {
        #expect(JSONUnescape.unescape(#""{\"a\":[1,2]}""#) == #"{"a":[1,2]}"#)
    }

    @Test func undoesDoubleEscaping() {
        #expect(JSONUnescape.unescape(#"{\\\"a\\\":\\\"x\\\"}"#) == #"{"a":"x"}"#)
    }

    @Test func decodesEscapesInsideValues() {
        #expect(JSONUnescape.unescape(#"{\"msg\":\"line1\\nline2 caf\\u00e9\"}"#) == "{\"msg\":\"line1\\nline2 caf\\u00e9\"}")
        #expect(JSONUnescape.unescape(#"line1\nline2 café"#) == "line1\nline2 café")
    }

    @Test func findsJSONInsideSurroundingText() {
        #expect(JSONUnescape.unescape(#"payload="{\"id\":7}" ok"#) == #"{"id":7}"#)
    }

    @Test func plainTextAndPlainJSONAreLeftAlone() {
        #expect(JSONUnescape.unescape(#"{"a":1}"#) == nil)
        #expect(JSONUnescape.unescape("server started") == nil)
        #expect(JSONUnescape.unescape("") == nil)
    }

    @Test func formattedIndentsKeepingTokens() {
        #expect(JSONUnescape.unescapeFormatted(#"{\"b\":1.10,\"a\":[]}"#) == "{\n  \"b\": 1.10,\n  \"a\": []\n}")
        #expect(JSONUnescape.unescapeFormatted(#"tab\there"#) == "tab\there")
    }
}
