import AppKit
import Combine
import CommandManagerCore

/// State of one log viewer: one command's log, or a group's logs merged in time order. Records
/// are read incrementally on a background queue and handed to the view as small change events,
/// so neither opening the viewer nor following a busy log re-reads, re-parses or re-diffs what is
/// already on screen.
@MainActor
final class LogViewerModel: ObservableObject {
    /// What the table must do to catch up with `rowCount`/`row(at:)`.
    enum TableChange {
        case reload
        case appended(Int)
        case prepended(Int)
        case droppedFront(Int)
    }

    /// One log being shown (a command).
    struct Source: Equatable {
        let serviceID: UUID
        var name: String
    }

    /// Memory budget: the oldest records are dropped beyond either limit (they stay in the file
    /// and page back in when scrolling up).
    nonisolated static let maxRows = 50_000
    nonisolated static let maxTextBytes = 32 * 1024 * 1024

    /// Per-instance budget (the popover's compact panel keeps far fewer records than the window).
    let maxRows: Int
    let maxTextBytes: Int
    private let initialBytes: Int

    /// Commands whose logs are shown; stream `i` of a row is `sources[i]`.
    @Published private(set) var sources: [Source]
    var isMerged: Bool { sources.count > 1 }
    /// First command (the only one outside group viewers).
    var serviceID: UUID { sources.first?.serviceID ?? UUID() }

    private let store: LogStore
    private let queue: DispatchQueue
    private var readers: [LogTailReader]

    @Published private(set) var loading = true
    @Published private(set) var totalCount = 0
    @Published private(set) var visibleCount = 0
    @Published private(set) var canLoadEarlier = false
    @Published private(set) var loadingEarlier = false
    @Published private(set) var atMemoryLimit = false
    @Published private(set) var selection: LogRow?
    @Published private(set) var detail: LogDetail?
    /// Filter text the visible rows were last filtered with; views highlight it.
    @Published private(set) var highlight = ""
    @Published var follow = true {
        didSet { if follow != oldValue, follow { scrollToEnd?() } }
    }
    /// Remembered across windows and launches.
    @Published var wrap = UserDefaults.standard.bool(forKey: LogViewerModel.wrapKey) {
        didSet {
            guard wrap != oldValue else { return }
            UserDefaults.standard.set(wrap, forKey: Self.wrapKey)
            onChange?(.reload)
        }
    }
    nonisolated static let wrapKey = "logViewer.wrapRows"
    @Published var filter: LogFilter = .all {
        didSet { if filter != oldValue { refilter(debounce: false) } }
    }
    @Published var query = "" {
        didSet { if query != oldValue { refilter(debounce: true) } }
    }

    /// Set by the view showing the records.
    var onChange: ((TableChange) -> Void)?
    /// Selectable text view showing this log's text (detail pane or popover log), for Cmd+F.
    weak var textView: NSTextView?
    var scrollToEnd: (() -> Void)?

    private var rows: [LogRow] = []
    /// Only allocated while a filter is active; otherwise the table reads `rows` directly.
    private var filtered: [LogRow]?
    private var textBytes = 0
    /// Ids are assigned here (in display order) so merged logs number consistently.
    private var nextID = 0
    private var firstID = 0
    private var pollInFlight = false
    private var filterGeneration = 0
    /// Bumped whenever rows are renumbered, so a filter computed before is not applied.
    private var rowsVersion = 0
    /// Bumped by Clear: results read before it are discarded.
    private var generation = 0
    private var timer: Timer?

    init(sources: [Source], store: LogStore, maxRows: Int = LogViewerModel.maxRows,
         maxTextBytes: Int = LogViewerModel.maxTextBytes, initialBytes: Int = 256 * 1024) {
        self.maxRows = maxRows
        self.maxTextBytes = maxTextBytes
        self.sources = sources
        self.store = store
        // A group shares the initial read budget between its commands.
        self.initialBytes = max(32 * 1024, initialBytes / max(1, sources.count))
        queue = DispatchQueue(label: "CommandManager.LogViewer", qos: .userInitiated)
        readers = []
        readers = sources.map(makeReader)
    }

    convenience init(serviceID: UUID, store: LogStore, maxRows: Int = LogViewerModel.maxRows,
                     maxTextBytes: Int = LogViewerModel.maxTextBytes, initialBytes: Int = 256 * 1024) {
        self.init(sources: [Source(serviceID: serviceID, name: "")], store: store, maxRows: maxRows,
                  maxTextBytes: maxTextBytes, initialBytes: initialBytes)
    }

    private func makeReader(_ source: Source) -> LogTailReader {
        LogTailReader(logFile: store.logFileURL(for: source.serviceID), maxFiles: store.maxFiles,
                      initialBytes: initialBytes)
    }

    /// Follows renames without reloading.
    func rename(_ serviceID: UUID, to name: String) {
        guard let index = sources.firstIndex(where: { $0.serviceID == serviceID }),
              sources[index].name != name else { return }
        sources[index].name = name
        if isMerged { onChange?(.reload) }
    }

    func name(of row: LogRow) -> String {
        sources.indices.contains(row.stream) ? sources[row.stream].name : ""
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // A model dropped without stop() must not leave its timer running.
                guard let self else { timer.invalidate(); return }
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Table data

    var rowCount: Int { filtered?.count ?? rows.count }

    func row(at index: Int) -> LogRow? {
        let source = filtered ?? rows
        return source.indices.contains(index) ? source[index] : nil
    }

    /// Index of `id` among the visible rows (ids ascend in display order).
    func index(of id: Int) -> Int? {
        let source = filtered ?? rows
        var low = 0, high = source.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = source[mid].id
            if value == id { return mid }
            if value < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    func select(_ row: LogRow?) {
        guard row?.id != selection?.id else { return }
        selection = row
        detail = row.map { LogDetail($0.text) }
    }

    // MARK: Reading

    private func poll() {
        guard !pollInFlight, !readers.isEmpty else {
            if readers.isEmpty { loading = false }
            return
        }
        pollInFlight = true
        let readers = readers
        let started = generation
        queue.async { [weak self] in
            let updates = readers.map { $0.poll() }
            let earlier = readers.contains { $0.canLoadEarlier }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pollInFlight = false
                    guard started == self.generation else { return }
                    self.apply(updates, canLoadEarlier: earlier)
                }
            }
        }
    }

    private func apply(_ updates: [LogTailReader.Update], canLoadEarlier earlier: Bool) {
        loading = false
        var resets: [Int: [LogRow]] = [:]
        var appended: [[LogRow]] = Array(repeating: [], count: updates.count)
        for (stream, update) in updates.enumerated() {
            switch update {
            case .none: break
            case .reset(let fresh): resets[stream] = fresh
            case .appended(let new): appended[stream] = new
            }
        }
        if !resets.isEmpty {
            // Rare (first load, clear, truncation): rebuild everything in time order.
            var batches: [[LogRow]] = sources.indices.map { stream in rows.filter { $0.stream == stream } }
            for (stream, fresh) in resets { batches[stream] = fresh }
            for (stream, new) in appended.enumerated() where resets[stream] == nil { batches[stream] += new }
            replaceAll(LogMerge.merge(batches, firstID: 0))
        } else if appended.contains(where: { !$0.isEmpty }) {
            let new = LogMerge.merge(appended, firstID: nextID)
            nextID += new.count
            rows.append(contentsOf: new)
            textBytes += new.reduce(0) { $0 + Self.cost($1) }
            var added = new.count
            if filtered != nil {
                let matching = new.filter(matcher)
                filtered?.append(contentsOf: matching)
                added = matching.count
            }
            if added > 0 { onChange?(.appended(added)) }
            enforceMemoryLimit()
        }
        canLoadEarlier = earlier && !atMemoryLimit
        publishCounts()
    }

    private func replaceAll(_ fresh: [LogRow]) {
        rows = fresh
        firstID = 0
        nextID = fresh.count
        rowsVersion += 1
        textBytes = fresh.reduce(0) { $0 + Self.cost($1) }
        filtered = isFiltering ? fresh.filter(matcher) : nil
        highlight = isFiltering ? needle : ""
        // Renumbered ids could point an old selection at a different record.
        select(nil)
        onChange?(.reload)
    }

    /// Pages in older records (called when the table is scrolled to the top).
    func loadEarlier() {
        guard canLoadEarlier, !loadingEarlier, !loading else { return }
        guard !nearMemoryLimit else {
            atMemoryLimit = true
            canLoadEarlier = false
            return
        }
        loadingEarlier = true
        let readers = readers
        let started = generation
        let share = max(32 * 1024, 256 * 1024 / max(1, readers.count))
        queue.async { [weak self] in
            let batches = readers.map { $0.canLoadEarlier ? $0.loadEarlier(maxBytes: share) : [] }
            let more = readers.contains { $0.canLoadEarlier }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loadingEarlier = false
                    guard started == self.generation else { return }
                    let count = batches.reduce(0) { $0 + $1.count }
                    let earlier = LogMerge.merge(batches, firstID: self.firstID - count)
                    self.firstID -= count
                    self.rows.insert(contentsOf: earlier, at: 0)
                    self.textBytes += earlier.reduce(0) { $0 + Self.cost($1) }
                    var added = earlier.count
                    if self.filtered != nil {
                        let matching = earlier.filter(self.matcher)
                        self.filtered?.insert(contentsOf: matching, at: 0)
                        added = matching.count
                    }
                    if added > 0 { self.onChange?(.prepended(added)) }
                    self.atMemoryLimit = self.nearMemoryLimit && more
                    self.canLoadEarlier = more && !self.atMemoryLimit
                    self.publishCounts()
                }
            }
        }
    }

    /// Deletes the log files of every command shown.
    func clear() {
        generation += 1
        let store = store
        let ids = sources.map(\.serviceID)
        queue.async { [weak self] in
            ids.forEach { store.clear(serviceID: $0) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.generation += 1
                    self.readers = self.sources.map(self.makeReader)
                    self.atMemoryLimit = false
                    self.canLoadEarlier = false
                    self.replaceAll([])
                    self.publishCounts()
                    self.poll()
                }
            }
        }
    }

    // MARK: Memory

    private static func cost(_ row: LogRow) -> Int { row.text.utf8.count + row.timestamp.utf8.count + 80 }

    private var nearMemoryLimit: Bool {
        rows.count >= maxRows * 9 / 10 || textBytes >= maxTextBytes * 9 / 10
    }

    /// Drops the oldest records (with 10% slack, so this runs rarely) once over budget.
    private func enforceMemoryLimit() {
        guard rows.count > maxRows || textBytes > maxTextBytes else { return }
        var drop = max(0, rows.count - maxRows * 9 / 10)
        var bytes = textBytes
        for row in rows.prefix(drop) { bytes -= Self.cost(row) }
        while bytes > maxTextBytes * 9 / 10, drop < rows.count - 1 {
            bytes -= Self.cost(rows[drop])
            drop += 1
        }
        guard drop > 0 else { return }
        rows.removeFirst(drop)
        textBytes = bytes
        let firstKept = rows.first
        var droppedVisible = drop
        if var list = filtered, let firstKept {
            let cut = list.firstIndex { $0.id >= firstKept.id } ?? list.count
            list.removeFirst(cut)
            filtered = list
            droppedVisible = cut
        }
        if let selected = selection, let firstKept, selected.id < firstKept.id { select(nil) }
        // Each log pages back in from its own first kept record.
        var seen = Set<Int>()
        var marks: [(LogTailReader, LogPosition)] = []
        for row in rows where seen.insert(row.stream).inserted {
            if readers.indices.contains(row.stream) { marks.append((readers[row.stream], row.position)) }
            if seen.count == readers.count { break }
        }
        queue.async { [marks] in marks.forEach { $0.0.forgetBefore($0.1) } }
        if droppedVisible > 0 { onChange?(.droppedFront(droppedVisible)) }
    }

    // MARK: Filtering

    private var isFiltering: Bool { filter != .all || !needle.isEmpty }
    private var needle: String { query.trimmingCharacters(in: .whitespaces) }

    private var matcher: (LogRow) -> Bool {
        let filter = filter
        let needle = needle
        return { row in Self.includes(filter, row.source) && row.matches(needle) }
    }

    private static func includes(_ filter: LogFilter, _ source: LogSource) -> Bool {
        switch filter {
        case .all: return true
        case .stdout: return source == .stdout
        case .stderr: return source == .stderr
        }
    }

    /// Filters off the main thread; typing is debounced so each keystroke does not rescan.
    private func refilter(debounce: Bool) {
        filterGeneration += 1
        let started = filterGeneration
        guard isFiltering else {
            filtered = nil
            highlight = ""
            onChange?(.reload)
            publishCounts()
            return
        }
        let snapshot = rows
        let version = rowsVersion
        let matcher = matcher
        let applied = needle
        let delay: DispatchTime = .now() + (debounce ? 0.15 : 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: delay) { [weak self] in
            // A newer keystroke supersedes this one before any work is done.
            let current = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.filterGeneration } }
            guard current == started else { return }
            let result = snapshot.filter(matcher)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, started == self.filterGeneration, version == self.rowsVersion else { return }
                    // Rows that arrived (or were dropped) while filtering are reconciled here.
                    let lastID = snapshot.last?.id ?? Int.min
                    let firstID = self.rows.first?.id ?? Int.max
                    var list = result.filter { $0.id >= firstID }
                    list.append(contentsOf: self.rows.filter { $0.id > lastID }.filter(matcher))
                    let earlier = self.rows.prefix { $0.id < (snapshot.first?.id ?? Int.max) }.filter(matcher)
                    self.filtered = earlier + list
                    self.highlight = applied
                    self.onChange?(.reload)
                    self.publishCounts()
                }
            }
        }
    }

    private func publishCounts() {
        if totalCount != rows.count { totalCount = rows.count }
        if visibleCount != rowCount { visibleCount = rowCount }
    }
}
