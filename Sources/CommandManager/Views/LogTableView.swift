import AppKit
import CommandManagerCore
import SwiftUI

/// Native, view-based table for the log viewer: only rows on screen get cells, row heights are
/// computed arithmetically (and cached) instead of laying out text, and new records are inserted
/// instead of reloading the table.
struct LogTableView: NSViewRepresentable {
    @ObservedObject var model: LogViewerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LogNSTableView()
        table.coordinator = context.coordinator
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Log records")

        var columns: [(String, String, Double)] = [("time", "Time", 96.0), ("type", "Type", 52.0)]
        if model.isMerged { columns.append(("command", "Command", 120.0)) }
        columns.append(("message", "Message", 600.0))
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            if id == "message" {
                column.minWidth = 120
                column.resizingMask = .autoresizingMask
            } else if id == "command" {
                column.minWidth = 60
                column.maxWidth = 320
                column.resizingMask = .userResizingMask
            } else {
                column.minWidth = width
                column.maxWidth = width + 60
                column.resizingMask = .userResizingMask
            }
            table.addTableColumn(column)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(LogNSTableView.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Copy Message Only", action: #selector(LogNSTableView.copyMessages(_:)), keyEquivalent: "")
        table.menu = menu

        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        context.coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: LogViewerModel
        private weak var table: NSTableView?
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        /// Wrapped heights by record id, valid for `heightWidth`.
        private var heights: [Int: CGFloat] = [:]
        private var heightWidth: CGFloat = 0
        private var applyingSelection = false

        static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let lineHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)
        static let rowHeight: CGFloat = lineHeight + 4
        static let charWidth: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width

        init(model: LogViewerModel) { self.model = model }

        func attach(table: NSTableView, scroll: NSScrollView) {
            self.table = table
            self.scroll = scroll
            table.rowHeight = Self.rowHeight
            model.onChange = { [weak self] change in self?.apply(change) }
            model.scrollToEnd = { [weak self] in self?.scrollToEnd() }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled() }
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled() }
            })
            observers.append(center.addObserver(forName: NSTableView.columnDidResizeNotification, object: table, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.widthChanged() }
            })
            table.reloadData()
            scrollToEnd()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            model.onChange = nil
            model.scrollToEnd = nil
        }

        // MARK: Changes from the model

        private func apply(_ change: LogViewerModel.TableChange) {
            guard let table else { return }
            switch change {
            case .reload:
                heights.removeAll(keepingCapacity: true)
                table.reloadData()
                restoreSelection()
                if model.follow { scrollToEnd() }
            case .appended(let count):
                let end = model.rowCount
                table.insertRows(at: IndexSet((end - count)..<end), withAnimation: [])
                if model.follow { scrollToEnd() }
            case .prepended(let count):
                guard let clip = scroll?.contentView else { return }
                let before = clip.bounds.origin.y
                table.insertRows(at: IndexSet(0..<count), withAnimation: [])
                // Keep the rows the user is looking at in place.
                let added = table.rect(ofRow: count - 1).maxY
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: before + added))
                scroll?.reflectScrolledClipView(clip)
            case .droppedFront(let count):
                guard let clip = scroll?.contentView else { return }
                let removed = table.rect(ofRow: count - 1).maxY
                let before = clip.bounds.origin.y
                table.removeRows(at: IndexSet(0..<count), withAnimation: [])
                if !model.follow {
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, before - removed)))
                    scroll?.reflectScrolledClipView(clip)
                }
            }
        }

        private func restoreSelection() {
            guard let table else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if let id = model.selection?.id, let index = model.index(of: id) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }

        private func scrollToEnd() {
            guard let table, model.rowCount > 0 else { return }
            table.scrollRowToVisible(model.rowCount - 1)
        }

        /// Scrolling away from the end pauses following (like Console); scrolling back resumes it.
        /// Reaching the top pages in older records.
        private func userScrolled() {
            guard let scroll, let document = scroll.documentView else { return }
            let visible = scroll.contentView.bounds
            let atEnd = visible.maxY >= document.frame.height - Self.rowHeight
            if model.follow != atEnd { model.follow = atEnd }
            if visible.minY < Self.rowHeight * 20 { model.loadEarlier() }
        }

        private func widthChanged() {
            guard model.wrap, let table else { return }
            heights.removeAll(keepingCapacity: true)
            table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<table.numberOfRows))
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard model.wrap, let record = model.row(at: row) else { return Self.rowHeight }
            let width = messageWidth(tableView)
            if width != heightWidth {
                heights.removeAll(keepingCapacity: true)
                heightWidth = width
            }
            if let cached = heights[record.id] { return cached }
            let height = Self.wrappedHeight(record.text, cellWidth: width)
            heights[record.id] = height
            return height
        }

        /// Width of the message cell (the text field inside is 2 pt in from each side).
        private func messageWidth(_ tableView: NSTableView) -> CGFloat {
            let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("message"))
            return max(60, column?.width ?? 400)
        }

        /// Same text cell setup as the wrapped message field, used to measure rows exactly.
        private static let measuringCell: NSTextFieldCell = {
            let cell = NSTextFieldCell(textCell: "")
            cell.font = font
            cell.wraps = true
            cell.lineBreakMode = .byCharWrapping
            cell.truncatesLastVisibleLine = false
            cell.isScrollable = false
            return cell
        }()

        /// Height of a wrapped row whose message cell is `cellWidth` wide. Short single-line ASCII
        /// rows skip measuring; everything else is laid out by the same text cell the table draws
        /// with, so long records are never clipped.
        static func wrappedHeight(_ text: String, cellWidth: CGFloat) -> CGFloat {
            let fieldWidth = max(40, cellWidth - 4)
            let count = text.utf8.count
            if count * 2 < Int(fieldWidth / charWidth), text.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x09 }) {
                return rowHeight
            }
            measuringCell.stringValue = text
            let size = measuringCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: fieldWidth,
                                                                height: .greatestFiniteMagnitude))
            return max(rowHeight, ceil(size.height) + 4)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn?.identifier.rawValue, let record = model.row(at: row) else { return nil }
            let cell = LogCell.dequeue(tableView, kind: column)
            switch column {
            case "time":
                cell.configure(text: Self.time(record), color: .secondaryLabelColor, wrap: false)
            case "type":
                cell.configureSource(record.source)
            case "command":
                cell.configure(text: model.name(of: record), color: Self.streamColor(record.stream), wrap: false)
            default:
                cell.configure(text: record.text, color: .labelColor, wrap: model.wrap, highlight: model.highlight)
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let index = table.selectedRow
            model.select(index >= 0 ? model.row(at: index) : nil)
        }

        // MARK: Copy

        func lines(for rows: IndexSet, messageOnly: Bool) -> String {
            rows.compactMap { model.row(at: $0) }.map { row in
                if messageOnly { return row.text }
                let command = model.isMerged ? "  [\(model.name(of: row))]" : ""
                return "\(Self.fullTime(row))  \(row.source.rawValue)\(command)  \(row.text)"
            }.joined(separator: "\n")
        }

        /// Stable, distinguishable color per command in a group viewer.
        static func streamColor(_ stream: Int) -> NSColor {
            let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange,
                                      .systemPink, .systemIndigo, .systemGreen, .systemBrown]
            return palette[stream % palette.count]
        }

        // MARK: Time formatting (only for rows on screen)

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        private static let fullFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return f
        }()

        static func time(_ row: LogRow) -> String {
            row.date.map { timeFormatter.string(from: $0) } ?? "—"
        }

        static func fullTime(_ row: LogRow) -> String {
            row.date.map { fullFormatter.string(from: $0) } ?? "—"
        }
    }
}

/// Table with ⌘C / context-menu copy of the selected records.
final class LogNSTableView: NSTableView {
    weak var coordinator: LogTableView.Coordinator?

    @objc func copy(_ sender: Any?) { copyRows(messageOnly: false) }
    @objc func copyMessages(_ sender: Any?) { copyRows(messageOnly: true) }

    private func copyRows(messageOnly: Bool) {
        var rows = selectedRowIndexes
        // Context menu on an unselected row copies that row.
        if clickedRow >= 0, !rows.contains(clickedRow) { rows = IndexSet(integer: clickedRow) }
        guard !rows.isEmpty, let text = coordinator?.lines(for: rows, messageOnly: messageOnly) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(copyMessages(_:)) {
            return !selectedRowIndexes.isEmpty || clickedRow >= 0
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Reusable cell: one text field (plus an icon for the Type column).
final class LogCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    static func dequeue(_ table: NSTableView, kind: String) -> LogCell {
        let id = NSUserInterfaceItemIdentifier("LogCell.\(kind)")
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? LogCell { return cell }
        let cell = LogCell(kind: kind)
        cell.identifier = id
        return cell
    }

    private init(kind: String) {
        super.init(frame: .zero)
        label.font = LogTableView.Coordinator.font
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.setContentHuggingPriority(.defaultLow, for: .vertical)
        addSubview(label)
        textField = label
        if kind == "type" {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.widthAnchor.constraint(equalToConstant: 11),
                icon.heightAnchor.constraint(equalToConstant: 11),
                icon.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            // Fill the row: its height comes from heightOfRow, never from a stale wrap width.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, color: NSColor, wrap: Bool, highlight: String = "") {
        let lineBreak: NSLineBreakMode = wrap ? .byCharWrapping : .byTruncatingTail
        label.maximumNumberOfLines = wrap ? 0 : 1
        label.lineBreakMode = lineBreak
        label.cell?.wraps = wrap
        label.cell?.truncatesLastVisibleLine = !wrap
        label.preferredMaxLayoutWidth = 0
        label.textColor = color
        // Plain text for the common case; an attributed value (set last, so textColor does not
        // overwrite it) only when the record contains the filter text.
        let matches = LogHighlight.ranges(of: highlight, in: text)
        if matches.isEmpty {
            label.stringValue = text
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = lineBreak
            let styled = NSMutableAttributedString(string: text, attributes: [
                .font: LogTableView.Coordinator.font, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
            for range in matches { styled.addAttributes(LogHighlightStyle.attributes, range: range) }
            label.attributedStringValue = styled
        }
        label.toolTip = nil
        setAccessibilityLabel(nil)
    }

    func configureSource(_ source: LogSource) {
        let (symbol, color, name): (String, NSColor, String) = {
            switch source {
            case .stdout: return ("text.alignleft", .labelColor, "standard output")
            case .stderr: return ("exclamationmark.triangle.fill", .systemRed, "standard error")
            case .system: return ("gearshape", .secondaryLabelColor, "Command Manager event")
            }
        }()
        label.stringValue = source.rawValue
        label.textColor = color
        label.maximumNumberOfLines = 1
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        setAccessibilityLabel(name)
    }
}

/// How filter matches are marked everywhere logs are shown: the system find-highlight
/// (yellow) with dark text, readable in light and dark mode and on a selected row.
enum LogHighlightStyle {
    static let attributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: NSColor.findHighlightColor,
        .foregroundColor: NSColor.black,
    ]

    /// Applies the highlight to `needle` matches inside `storage[range]`.
    static func apply(_ needle: String, to storage: NSMutableAttributedString, in range: NSRange, text: String) {
        for match in LogHighlight.ranges(of: needle, in: text) {
            storage.addAttributes(attributes, range: NSRange(location: range.location + match.location, length: match.length))
        }
    }
}
