import Foundation

/// Error returned to `cmgr` / MCP callers as a plain message.
public struct ControlError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Operations exposed over the control socket, the `cmgr` CLI and the MCP server.
public enum ControlOp: String, CaseIterable, Sendable {
    case list, status, logs, context
    case start, stop, restart, forceStop = "force_stop", clearStatus = "clear_status"
    case add, update, enable, disable, delete, clearLogs = "clear_logs", move
    case groupCreate = "group_create", groupRename = "group_rename", groupDelete = "group_delete"
    case groupSet = "group_set", groupMove = "group_move", groupStart = "group_start", groupStop = "group_stop"

    /// Needs the running app because it touches processes it owns.
    public var needsLiveApp: Bool {
        switch self {
        case .start, .stop, .restart, .forceStop, .clearStatus, .groupStart, .groupStop: return true
        default: return false
        }
    }

    public var isReadOnly: Bool { [.list, .status, .logs, .context].contains(self) }
}

/// Executes control operations against an `AppModel`.
///
/// Inside the app (`isLive == true`) it sees real runtime state. In `cmgr` with the app closed it
/// runs on a definitions-only model: reads and definition edits work, process actions are refused.
/// Policy (agreed with the user): callers — including AI agents — have full read/write access;
/// no confirmation flags are required.
@MainActor
public final class ControlService {
    public static let defaultLogLines = 100
    public static let maxLogLines = 2000
    /// Cap on log text returned in one response, so an AI context is not flooded.
    public static let maxLogCharacters = 200_000

    public let model: AppModel
    public let isLive: Bool

    public init(model: AppModel, isLive: Bool) {
        self.model = model
        self.isLive = isLive
    }

    public func handle(op rawOp: String, args: [String: JSONValue]) throws -> JSONValue {
        guard let op = ControlOp(rawValue: rawOp) else {
            throw ControlError("Unknown operation \"\(rawOp)\". Known: \(ControlOp.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if op.needsLiveApp, !isLive {
            throw ControlError("Command Manager app is not running, so \(op.rawValue) is unavailable. Open the app and retry.")
        }
        switch op {
        case .list:
            return .object([
                "appRunning": .bool(isLive),
                "services": .array(model.orderedServices.map(info)),
                "rows": .array(model.rows.map { row -> JSONValue in
                    switch row {
                    case .group(let g, let members):
                        return .object(["type": .string("group"), "id": .string(g.id.uuidString), "name": .string(g.name),
                                        "collapsed": .bool(g.isCollapsed),
                                        "services": .array(members.map { .string($0.displayName) })])
                    case .service(let s):
                        return .object(["type": .string("service"), "name": .string(s.displayName)])
                    }
                }),
            ])
        case .status:
            return info(try resolve(args))
        case .logs:
            return logs(try resolve(args), args: args)
        case .context:
            return .string(context(args: args))
        case .start:
            let d = try resolve(args)
            try model.supervisor.start(d)
            return info(d)
        case .stop:
            let d = try resolve(args)
            try model.supervisor.stop(d.id)
            return info(d)
        case .restart:
            let d = try resolve(args)
            if model.record(d.id).state == .running {
                try model.supervisor.restart(d)
            } else {
                try model.supervisor.start(d)
            }
            return info(d)
        case .forceStop:
            let d = try resolve(args)
            let state = model.record(d.id).state
            if state == .running { try model.supervisor.stop(d.id) }
            try model.supervisor.forceStop(d.id)
            return info(d)
        case .clearStatus:
            let d = try resolve(args)
            model.clearStatus(d.id)
            return info(d)
        case .add:
            var draft = ServiceDraft()
            if let path = args["file"]?.stringValue, !path.isEmpty {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let inferred = LaunchInference.draft(for: url, existing: model.services) else {
                    throw ControlError("File not found: \(url.path)")
                }
                draft = inferred
                if inferred.command.isEmpty, args["command"] == nil {
                    throw ControlError("Could not tell how to run \(url.path); pass a command too.")
                }
            }
            try apply(args, to: &draft, requireCore: true)
            try applyGroup(args, to: &draft, editing: nil)
            return info(try save(draft, editing: nil))
        case .update:
            let d = try resolve(args)
            var draft = ServiceDraft(d)
            try apply(args, to: &draft, requireCore: false)
            try applyGroup(args, to: &draft, editing: d.id)
            return info(try save(draft, editing: d.id))
        case .enable, .disable:
            let d = try resolve(args)
            try model.setEnabled(op == .enable, for: d.id)
            return info(model.service(d.id) ?? d)
        case .delete:
            let d = try resolve(args)
            let state = model.record(d.id).state
            if state.isActive {
                throw ControlError("\(d.displayName) is \(state.label.lowercased()). Stop it first (stop / force_stop), then delete.")
            }
            try model.delete(d.id)
            if args["clearLogs"]?.boolValue == true { model.logStore.clear(serviceID: d.id) }
            return .object(["deleted": .string(d.displayName), "id": .string(d.id.uuidString)])
        case .groupCreate:
            guard let name = args["name"]?.stringValue else { throw ControlError("Missing \"name\".") }
            var ids: [UUID] = []
            if case .array(let names)? = args["services"] {
                ids = try names.compactMap(\.stringValue).map { try Self.resolve($0, in: model.services).id }
            }
            let g = try model.createGroup(named: name, with: ids)
            return groupInfo(g.id)
        case .groupRename:
            let g = try resolveGroup(args)
            guard let name = (args["newName"] ?? args["name"])?.stringValue else { throw ControlError("Missing \"newName\".") }
            try model.renameGroup(g.id, to: name)
            return groupInfo(g.id)
        case .groupDelete:
            let g = try resolveGroup(args)
            try model.ungroup(g.id)
            return .object(["ungrouped": .string(g.name)])
        case .groupSet:
            let d = try resolve(args)
            var target: UUID?
            if let name = args["group"]?.stringValue, !name.isEmpty {
                target = try Self.resolveGroup(name, in: model.layout.groups)?.id ?? model.createGroup(named: name).id
            }
            let members = target.map { model.members(of: $0).filter { $0.id != d.id }.count } ?? model.layout.order.count
            let position = args["position"]?.intValue.map { $0 - 1 } ?? members
            try model.place(d.id, inGroup: target, at: position)
            return info(d)
        case .groupMove:
            let g = try resolveGroup(args)
            guard let position = args["position"]?.intValue else { throw ControlError("Missing \"position\" (1 = top).") }
            try model.moveGroup(g.id, to: position - 1)
            return .object(["order": .array(model.rows.map { row -> JSONValue in
                switch row {
                case .group(let g, _): return .string("[\(g.name)]")
                case .service(let s): return .string(s.displayName)
                }
            })])
        case .groupStart:
            let g = try resolveGroup(args)
            let n = model.startGroup(g.id)
            var result = groupInfo(g.id)
            if case .object(var o) = result { o["started"] = .from(n); result = .object(o) }
            return result
        case .groupStop:
            let g = try resolveGroup(args)
            let n = model.stopGroup(g.id)
            var result = groupInfo(g.id)
            if case .object(var o) = result { o["stopped"] = .from(n); result = .object(o) }
            return result
        case .move:
            let d = try resolve(args)
            guard let position = args["position"]?.intValue else {
                throw ControlError("Missing \"position\" (1 = top, \(model.services.count) = bottom).")
            }
            try model.move(d.id, to: position - 1)
            let siblings = d.groupID.map { model.members(of: $0) } ?? model.rows.compactMap {
                if case .service(let s) = $0 { return s } else { return nil }
            }
            return .object(["order": .array(siblings.map { .string($0.displayName) })])
        case .clearLogs:
            let d = try resolve(args)
            model.logStore.clear(serviceID: d.id)
            return .object(["cleared": .string(d.displayName)])
        }
    }

    // MARK: - Resolution

    /// Finds a service by id, exact name (case-insensitive) or a unique name fragment.
    public func resolve(_ args: [String: JSONValue]) throws -> ServiceDefinition {
        guard let query = (args["service"] ?? args["id"] ?? args["name"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ControlError("Missing \"service\" (name or id).")
        }
        return try Self.resolve(query, in: model.services)
    }

    public static func resolve(_ query: String, in services: [ServiceDefinition]) throws -> ServiceDefinition {
        if let id = UUID(uuidString: query), let match = services.first(where: { $0.id == id }) { return match }
        if let match = services.first(where: { $0.displayName.caseInsensitiveCompare(query) == .orderedSame }) { return match }
        let lower = query.lowercased()
        let idPrefix = services.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
        if lower.count >= 4, idPrefix.count == 1 { return idPrefix[0] }
        let fuzzy = services.filter { $0.displayName.lowercased().contains(lower) }
        if fuzzy.count == 1 { return fuzzy[0] }
        let names = services.map(\.displayName).joined(separator: ", ")
        if fuzzy.isEmpty {
            throw ControlError("No command matches \"\(query)\". Known: \(names.isEmpty ? "(none)" : names).")
        }
        throw ControlError("\"\(query)\" matches several commands: \(fuzzy.map(\.displayName).joined(separator: ", ")). Use the exact name or id.")
    }

    // MARK: - Groups

    public func resolveGroup(_ args: [String: JSONValue]) throws -> ServiceGroup {
        guard let query = args["group"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw ControlError("Missing \"group\" (name or id).")
        }
        guard let g = try Self.resolveGroup(query, in: model.layout.groups) else {
            let names = model.layout.groups.map(\.name).joined(separator: ", ")
            throw ControlError("No group matches \"\(query)\". Known: \(names.isEmpty ? "(none)" : names).")
        }
        return g
    }

    /// Exact id or name, else a unique name fragment; nil when nothing matches.
    public static func resolveGroup(_ query: String, in groups: [ServiceGroup]) throws -> ServiceGroup? {
        if let id = UUID(uuidString: query), let g = groups.first(where: { $0.id == id }) { return g }
        if let g = groups.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return g }
        let fuzzy = groups.filter { $0.name.lowercased().contains(query.lowercased()) }
        if fuzzy.count > 1 {
            throw ControlError("\"\(query)\" matches several groups: \(fuzzy.map(\.name).joined(separator: ", ")).")
        }
        return fuzzy.first
    }

    private func groupInfo(_ id: UUID) -> JSONValue {
        guard let g = model.group(id) else { return .null }
        let members = model.members(of: id)
        return .object([
            "id": .string(g.id.uuidString), "name": .string(g.name), "collapsed": .bool(g.isCollapsed),
            "services": .array(members.map(info)),
        ])
    }

    /// `group` on add/update: a group name or id (created when unknown), or "" / null for none.
    /// Validates the rest of the draft first so a failed save never leaves an empty new group.
    private func applyGroup(_ args: [String: JSONValue], to draft: inout ServiceDraft, editing id: UUID?) throws {
        guard let value = args["group"] else { return }
        guard let name = value.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            draft.groupID = nil
            return
        }
        if let g = try Self.resolveGroup(name, in: model.layout.groups) {
            draft.groupID = g.id
            return
        }
        let issues = model.validate(draft, editing: id)
        if !issues.isEmpty {
            throw ControlError(issues.map { "\($0.field.rawValue): \($0.message)" }.joined(separator: " "))
        }
        draft.groupID = try model.createGroup(named: name).id
    }

    // MARK: - Editing

    private func apply(_ args: [String: JSONValue], to draft: inout ServiceDraft, requireCore: Bool) throws {
        let newName = args[requireCore ? "name" : "newName"] ?? (requireCore ? nil : args["rename"])
        if let name = newName?.stringValue { draft.displayName = name }
        if let command = args["command"]?.stringValue { draft.command = command }
        if let cwd = (args["workingDirectory"] ?? args["cwd"])?.stringValue { draft.workingDirectory = cwd }
        if let env = args["env"] ?? args["environment"] {
            switch env {
            case .object(let pairs):
                draft.environmentText = pairs.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: "\n")
            case .string(let text):
                draft.environmentText = text
            case .array(let lines):
                draft.environmentText = lines.compactMap(\.stringValue).joined(separator: "\n")
            case .null:
                draft.environmentText = ""
            default:
                throw ControlError("\"env\" must be an object {KEY: value}, a list of KEY=VALUE or a string.")
            }
        }
        if let enabled = args["enabled"]?.boolValue { draft.isEnabled = enabled }
        if let auto = args["autoStart"]?.boolValue { draft.autoStart = auto }
        if let restart = args["restartOnExit"]?.boolValue { draft.restartOnExit = restart }
        if requireCore, draft.displayName.isEmpty || draft.command.isEmpty {
            throw ControlError("\"name\" and \"command\" are required.")
        }
    }

    private func save(_ draft: ServiceDraft, editing id: UUID?) throws -> ServiceDefinition {
        switch model.save(draft, editing: id) {
        case .success(let d): return d
        case .failure(let failure as ValidationFailure):
            throw ControlError(failure.issues.map { "\($0.field.rawValue): \($0.message)" }.joined(separator: " "))
        case .failure(let error):
            throw ControlError(error.localizedDescription)
        }
    }

    // MARK: - Output

    private static let isoFormatter = ISO8601DateFormatter()

    public func info(_ d: ServiceDefinition) -> JSONValue {
        let current = model.service(d.id) ?? d
        var o: [String: JSONValue] = [
            "id": .string(current.id.uuidString),
            "name": .string(current.displayName),
            "command": .string(current.command),
            "workingDirectory": .from(current.workingDirectory),
            "env": .object(current.environment.mapValues { .string($0) }),
            "enabled": .bool(current.isEnabled),
            "autoStart": .bool(current.autoStart),
            "group": .from(current.groupID.flatMap { model.group($0)?.name }),
            "restartOnExit": .bool(current.restartOnExit),
            "logFile": .string(model.logStore.logFileURL(for: current.id).path),
        ]
        if isLive {
            let r = model.record(current.id)
            o["state"] = .string(r.state.rawValue)
            o["pid"] = .from(r.pid.map(Int.init))
            o["exitCode"] = .from(r.exitCode.map(Int.init))
            o["lastError"] = .from(r.lastError)
            o["startedAt"] = .from(r.startedAt.map(Self.isoFormatter.string(from:)))
            o["endedAt"] = .from(r.endedAt.map(Self.isoFormatter.string(from:)))
            if r.stopTimedOut { o["stopTimedOut"] = .bool(true) }
            if r.restartAttempt > 0 { o["restartAttempt"] = .from(r.restartAttempt) }
            if let next = r.nextRestartAt { o["nextRestartAt"] = .string(Self.isoFormatter.string(from: next)) }
        } else {
            o["state"] = .string("app-not-running")
        }
        return .object(o)
    }

    /// Words that mark a line as an error when `errors` is requested (besides stderr).
    static let errorPattern = try! NSRegularExpression(
        pattern: #"\b(error|err!|exception|fatal|panic|traceback|failed|failure|refused|denied|cannot|can't|not found|unhandled|segfault|exited with code [1-9])"#,
        options: [.caseInsensitive])

    public static func isErrorLine(_ line: LogLine) -> Bool {
        if line.source == .stderr { return true }
        let range = NSRange(line.text.startIndex..., in: line.text)
        return errorPattern.firstMatch(in: line.text, range: range) != nil
    }

    public func logs(_ d: ServiceDefinition, args: [String: JSONValue]) -> JSONValue {
        let wanted = min(max(args["lines"]?.intValue ?? Self.defaultLogLines, 1), Self.maxLogLines)
        let grep = args["grep"]?.stringValue ?? ""
        let errorsOnly = args["errors"]?.boolValue ?? false
        let source = args["source"]?.stringValue.flatMap { raw -> LogSource? in
            switch raw.lowercased() {
            case "out", "stdout": return .stdout
            case "err", "stderr": return .stderr
            case "sys", "system": return .system
            default: return nil
            }
        }
        model.logStore.sync()
        // Filtering needs more history than the lines finally returned.
        let filtering = !grep.isEmpty || errorsOnly || source != nil
        let all = model.logStore.tail(serviceID: d.id, maxBytes: filtering ? 4 * 1024 * 1024 : 1024 * 1024)
        let matched = all.filter { line in
            (source == nil || line.source == source) && line.matches(grep) && (!errorsOnly || Self.isErrorLine(line))
        }
        var selected = Array(matched.suffix(wanted))
        var rendered = selected.map(Self.render)
        var total = rendered.reduce(0) { $0 + $1.count + 1 }
        while total > Self.maxLogCharacters, !rendered.isEmpty {
            total -= rendered.removeFirst().count + 1
            selected.removeFirst()
        }
        return .object([
            "service": .string(d.displayName),
            "logFile": .string(model.logStore.logFileURL(for: d.id).path),
            "matched": .from(matched.count),
            "returned": .from(rendered.count),
            "truncated": .bool(rendered.count < matched.count),
            "lines": .array(rendered.map { .string($0) }),
        ])
    }

    static func render(_ line: LogLine) -> String {
        line.timestamp.isEmpty ? line.text : "\(line.timestamp) [\(line.source.rawValue)] \(line.text)"
    }

    /// Markdown snapshot an AI can read in one go: every command, its state, and recent errors
    /// of the ones that are failing (or of `service` when given).
    public func context(args: [String: JSONValue]) -> String {
        let errorLines = min(max(args["lines"]?.intValue ?? 20, 1), 200)
        var out = "# Command Manager snapshot\n\n"
        out += isLive ? "App: running.\n" : "App: NOT running — states unknown; start/stop need the app.\n"
        out += "Logs may contain secrets; treat them carefully.\n\n"
        out += "| Name | Group | State | PID | Enabled | Auto-start | Restart on exit | Command | Folder |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
        for d in model.orderedServices {
            let r = model.record(d.id)
            var state = isLive ? r.state.rawValue + (r.exitCode.map { " (exit \($0))" } ?? "") : "?"
            if isLive, let next = r.nextRestartAt {
                state += ", restarting in \(max(0, Int(next.timeIntervalSinceNow.rounded())))s (attempt \(r.restartAttempt))"
            }
            out += "| \(d.displayName) | \(d.groupID.flatMap { model.group($0)?.name } ?? "") | \(state) | \(r.pid.map(String.init) ?? "") | \(d.isEnabled ? "yes" : "no") | \(d.autoStart ? "yes" : "no") | \(d.restartOnExit ? "yes" : "no") | `\(d.command.replacingOccurrences(of: "|", with: "\\|"))` | \(d.workingDirectory ?? "~") |\n"
        }
        if model.services.isEmpty { out += "| (no commands) | | | | | | | | |\n" }

        let focus: [ServiceDefinition]
        if let one = try? resolve(args) {
            focus = [one]
        } else {
            focus = model.services.filter { [.failed, .unknown].contains(model.record($0.id).state) || (!isLive) }
        }
        for d in focus {
            let lines = logs(d, args: ["errors": .bool(true), "lines": .from(errorLines)])["lines"]
            guard case .array(let items)? = lines, !items.isEmpty else { continue }
            out += "\n## Recent errors — \(d.displayName)\n"
            if let e = model.record(d.id).lastError { out += "Last error: \(e)\n" }
            out += "```\n" + items.compactMap(\.stringValue).joined(separator: "\n") + "\n```\n"
        }
        return out
    }
}
