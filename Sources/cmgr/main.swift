import CommandManagerCore
import Foundation

// cmgr — command-line and MCP access to Command Manager, for people and AI agents.

let version = "1.0.0"
let bundleID = "com.cezar.CommandManager"

let usage = """
cmgr \(version) — control Command Manager from the terminal or an AI agent

Usage: cmgr <command> [arguments] [--json]

Read
  list                                  all commands with state and PID
  status  <service>                     state, PID, exit code, last error, definition
  logs    <service> [-n N] [--grep TEXT] [--errors] [--source out|err|sys] [-f]
                                        tail the log (-f follows new lines)
  context [service] [-n N]              markdown snapshot for pasting into an AI chat

Run
  start | stop | restart <service>
  kill <service>                        force stop (SIGKILL)
  clear-status <service>                reset failed/unknown to stopped

Define
  add <file|folder|App.app> [--name NAME]   infer working folder + run command from the file
  add --name NAME --cmd "COMMAND" [--cwd DIR] [--env KEY=VALUE]... [--auto-start] [--restart] [--disabled]
  edit <service> [--name NEW] [--cmd "…"] [--cwd DIR] [--env KEY=VALUE]... [--clear-env]
                 [--auto-start true|false] [--restart true|false] [--enabled true|false]
                                        --restart: start again when it exits/crashes (1 s → 60 s backoff)
  enable | disable <service>
  move <service> <position>             reorder within its group / the top level (1 = top)

Groups
  group ls                              groups and their commands
  group create NAME [service…]          create a group (optionally moving commands in)
  group rename GROUP NEW_NAME
  group delete GROUP                    remove the group, keep its commands
  group add GROUP <service> [position]  move a command into a group (created if new)
  group remove <service>                take a command out of its group
  group move GROUP <position>           reorder groups among top-level rows
  group start | stop GROUP              start/stop every command in it
  add/edit … --group NAME               ("" = no group)
  delete <service> [--clear-logs]
  clear-logs <service>

AI integration
  mcp                                   run the MCP server on stdio
  mcp-config                            print an MCP client config snippet for this binary

<service> is a name (case-insensitive, a unique fragment is enough) or an id.
start/stop/restart open the app when it is not running; other commands also work with the app closed.
Environment: CMGR_HOME overrides the data folder (default ~/Library/Application Support/CommandManager).
"""

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var flags: [String: [String]] = [:]
    var switches: Set<String> = []

    static let valued: Set<String> = ["-n", "--lines", "--grep", "--source", "--name", "--cmd", "--command",
                                      "--cwd", "--env", "--file", "--auto-start", "--enabled", "--restart", "--group"]
    /// Flags that are switches when followed by another flag or nothing.
    static let optionalValue: Set<String> = ["--auto-start", "--enabled", "--restart"]

    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            if arg == "--" {
                positional += raw[(i + 1)...]
                break
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                var name = arg
                var inline: String?
                if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                    name = String(arg[..<eq])
                    inline = String(arg[arg.index(after: eq)...])
                }
                if Self.valued.contains(name) {
                    if let inline {
                        flags[name, default: []].append(inline)
                    } else if Self.optionalValue.contains(name),
                              i + 1 >= raw.count || !["true", "false", "yes", "no", "1", "0"].contains(raw[i + 1].lowercased()) {
                        flags[name, default: []].append("true")
                    } else {
                        guard i + 1 < raw.count else { throw ControlError("\(name) needs a value.") }
                        flags[name, default: []].append(raw[i + 1])
                        i += 1
                    }
                } else {
                    switches.insert(name)
                }
            } else {
                positional.append(arg)
            }
            i += 1
        }
    }

    func value(_ names: String...) -> String? { names.lazy.compactMap { flags[$0]?.last }.first }
    func has(_ names: String...) -> Bool { names.contains { switches.contains($0) } }
}

func stderrPrint(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: - Backend

let paths = AppPaths.standard()

func openApp() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", bundleID]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

let autoLaunch = ProcessInfo.processInfo.environment["CMGR_NO_LAUNCH"] == nil && ProcessInfo.processInfo.environment["CMGR_HOME"] == nil
let backend = ControlBackend(paths: paths, launchApp: autoLaunch ? openApp : nil)

// MARK: - Rendering

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
}

func printService(_ s: JSONValue) {
    func v(_ key: String) -> String { s[key]?.stringValue ?? "" }
    print("\(v("name"))  [\(v("state"))]")
    print("  id:        \(v("id"))")
    print("  command:   \(v("command"))")
    print("  folder:    \(s["workingDirectory"]?.stringValue ?? "~")")
    if let env = s["env"]?.objectValue, !env.isEmpty {
        print("  env:       " + env.keys.sorted().map { "\($0)=\(env[$0]?.stringValue ?? "")" }.joined(separator: " "))
    }
    print("  enabled:   \(v("enabled"))   auto-start: \(v("autoStart"))   restart on exit: \(v("restartOnExit"))")
    if !v("nextRestartAt").isEmpty { print("  restart:   at \(v("nextRestartAt")) (attempt \(v("restartAttempt")))") }
    if !v("pid").isEmpty { print("  pid:       \(v("pid"))") }
    if !v("exitCode").isEmpty { print("  exit code: \(v("exitCode"))") }
    if !v("startedAt").isEmpty { print("  started:   \(v("startedAt"))") }
    if !v("lastError").isEmpty { print("  error:     \(v("lastError"))") }
    print("  log:       \(v("logFile"))")
}

func printList(_ result: JSONValue) {
    if result["appRunning"]?.boolValue == false {
        print("(Command Manager app is not running — states unknown)")
    }
    guard case .array(let items)? = result["services"], !items.isEmpty else {
        print("No commands yet. Add one: cmgr add --name api --cmd \"npm run dev\" --cwd ~/code/api")
        return
    }
    var byName: [String: JSONValue] = [:]
    for s in items { if let n = s["name"]?.stringValue { byName[n] = s } }
    func line(_ s: JSONValue, indent: String) {
        var state = s["state"]?.stringValue ?? ""
        if s["enabled"]?.boolValue == false { state += " (off)" }
        print(pad(indent + (s["name"]?.stringValue ?? ""), 24) + pad(state, 16) + pad(s["pid"]?.stringValue ?? "", 8)
              + (s["command"]?.stringValue ?? ""))
    }
    print(pad("NAME", 24) + pad("STATE", 16) + pad("PID", 8) + "COMMAND")
    guard case .array(let rows)? = result["rows"] else { items.forEach { line($0, indent: "") }; return }
    for row in rows {
        if row["type"]?.stringValue == "group" {
            guard case .array(let members)? = row["services"] else { continue }
            print("▸ \(row["name"]?.stringValue ?? "") (\(members.count))")
            for m in members { if let s = m.stringValue.flatMap({ byName[$0] }) { line(s, indent: "  ") } }
        } else if let s = row["name"]?.stringValue.flatMap({ byName[$0] }) {
            line(s, indent: "")
        }
    }
}

func output(_ result: JSONValue, json: Bool, human: (JSONValue) -> Void) {
    if json {
        print(result.encodedString(pretty: true))
    } else {
        human(result)
    }
}

// MARK: - Follow

/// Prints lines appended to the log file after the initial tail (handles rotation by size drop).
func follow(serviceID: String, grep: String, errorsOnly: Bool, source: String?) -> Never {
    let url = paths.logsDirectory.appendingPathComponent("\(serviceID).log")
    var offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    var pending = Data()
    signal(SIGINT) { _ in exit(0) }
    while true {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        if size < offset { offset = 0; pending = Data() }
        if size > offset, let handle = try? FileHandle(forReadingFrom: url) {
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            offset += UInt64(data.count)
            pending.append(data)
            while let nl = pending.firstIndex(of: 0x0A) {
                let raw = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending = Data(pending[(nl + 1)...])
                let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                let src = parts.count > 1 ? String(parts[1].dropFirst().dropLast()) : ""
                let text = parts.count > 2 ? String(parts[2]) : raw
                if let source, !source.hasPrefix(src.isEmpty ? "?" : src) { continue }
                if !grep.isEmpty, text.range(of: grep, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
                if errorsOnly, src != "err",
                   text.range(of: #"error|exception|fatal|panic|traceback|failed|refused|denied|not found"#,
                              options: [.regularExpression, .caseInsensitive]) == nil { continue }
                print(raw)
                fflush(stdout)
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

// MARK: - Commands

func serviceArg(_ args: Arguments) throws -> [String: JSONValue] {
    guard let name = args.positional.dropFirst().first else { throw ControlError("Missing <service>. See: cmgr help") }
    return ["service": .string(name)]
}

func envArgs(_ args: Arguments) -> JSONValue? {
    guard let pairs = args.flags["--env"] else { return args.has("--clear-env") ? .null : nil }
    return .array(pairs.map { .string($0) })
}

func boolFlag(_ args: Arguments, _ name: String) -> JSONValue? {
    args.value(name).map { .bool(["true", "yes", "1"].contains($0.lowercased())) }
}

func run(_ raw: [String]) throws -> Int32 {
    let args = try Arguments(raw)
    let json = args.has("--json")
    guard let command = args.positional.first else {
        print(usage)
        return args.has("-h", "--help", "--version", "-v") ? 0 : 1
    }

    switch command {
    case "help", "-h", "--help":
        print(usage)
    case "version", "--version":
        print("cmgr \(version)")
    case "list", "ls", "ps":
        output(try backend.call("list"), json: json, human: printList)
    case "status", "show", "info":
        output(try backend.call("status", serviceArg(args)), json: json, human: printService)
    case "logs", "log", "tail":
        var request = try serviceArg(args)
        if let n = args.value("-n", "--lines") { request["lines"] = .string(n) }
        if let grep = args.value("--grep") { request["grep"] = .string(grep) }
        if args.has("--errors", "-e") { request["errors"] = .bool(true) }
        if let source = args.value("--source") { request["source"] = .string(source) }
        let result = try backend.call("logs", request)
        output(result, json: json) { r in
            if case .array(let lines)? = r["lines"] { lines.compactMap(\.stringValue).forEach { print($0) } }
            if r["truncated"]?.boolValue == true, !args.has("-f", "--follow") {
                stderrPrint("(\(r["returned"]?.stringValue ?? "?") of \(r["matched"]?.stringValue ?? "?") matching lines; use -n for more)")
            }
        }
        if args.has("-f", "--follow") {
            let status = try backend.call("status", serviceArg(args))
            fflush(stdout)
            follow(serviceID: status["id"]?.stringValue ?? "", grep: args.value("--grep") ?? "",
                   errorsOnly: args.has("--errors", "-e"), source: args.value("--source"))
        }
    case "context", "snapshot", "prompt":
        var request: [String: JSONValue] = [:]
        if let name = args.positional.dropFirst().first { request["service"] = .string(name) }
        if let n = args.value("-n", "--lines") { request["lines"] = .string(n) }
        let result = try backend.call("context", request)
        print(result.stringValue ?? result.encodedString(pretty: true))
    case "start", "stop", "restart", "kill", "force-stop", "clear-status", "enable", "disable", "clear-logs":
        let op: String = ["kill": "force_stop", "force-stop": "force_stop", "clear-status": "clear_status",
                          "clear-logs": "clear_logs"][command] ?? command
        let result = try backend.call(op, serviceArg(args))
        output(result, json: json) { r in
            if let name = r["name"]?.stringValue {
                print("\(name): \(r["state"]?.stringValue ?? "ok")")
            } else {
                print(r.encodedString())
            }
        }
    case "group", "groups":
        let sub = args.positional.dropFirst().first ?? "ls"
        let rest = Array(args.positional.dropFirst(2))
        func need(_ n: Int, _ usage: String) throws { if rest.count < n { throw ControlError("Usage: cmgr group \(usage)") } }
        func showGroup(_ r: JSONValue) {
            let name = r["name"]?.stringValue ?? ""
            var extra = ""
            if let n = r["started"]?.stringValue { extra = " — started \(n)" }
            if let n = r["stopped"]?.stringValue { extra = " — stopped \(n)" }
            print("[\(name)]\(extra)")
            if case .array(let members)? = r["services"] {
                for m in members { print("  \(pad(m["name"]?.stringValue ?? "", 22))\(m["state"]?.stringValue ?? "")") }
            }
        }
        switch sub {
        case "ls", "list":
            output(try backend.call("list"), json: json, human: printList)
        case "create", "new":
            try need(1, "create NAME [service…]")
            output(try backend.call("group_create", ["name": .string(rest[0]), "services": .array(rest.dropFirst().map { .string($0) })]),
                   json: json, human: showGroup)
        case "rename":
            try need(2, "rename GROUP NEW_NAME")
            output(try backend.call("group_rename", ["group": .string(rest[0]), "newName": .string(rest[1])]), json: json, human: showGroup)
        case "delete", "rm", "ungroup":
            try need(1, "delete GROUP")
            output(try backend.call("group_delete", ["group": .string(rest[0])]), json: json) { r in
                print("Removed group \(r["ungrouped"]?.stringValue ?? ""); its commands are kept.")
            }
        case "add":
            try need(2, "add GROUP <service> [position]")
            var request: [String: JSONValue] = ["group": .string(rest[0]), "service": .string(rest[1])]
            if rest.count > 2 { request["position"] = .string(rest[2]) }
            output(try backend.call("group_set", request), json: json) { r in
                print("\(r["name"]?.stringValue ?? "") → [\(r["group"]?.stringValue ?? "")]")
            }
        case "remove":
            try need(1, "remove <service>")
            output(try backend.call("group_set", ["service": .string(rest[0]), "group": .string("")]), json: json) { r in
                print("\(r["name"]?.stringValue ?? "") is no longer in a group")
            }
        case "move", "mv":
            try need(2, "move GROUP <position>")
            output(try backend.call("group_move", ["group": .string(rest[0]), "position": .string(rest[1])]), json: json) { r in
                if case .array(let names)? = r["order"] {
                    for (i, n) in names.enumerated() { print("\(i + 1). \(n.stringValue ?? "")") }
                }
            }
        case "start", "stop":
            try need(1, "\(sub) GROUP")
            output(try backend.call("group_" + sub, ["group": .string(rest[0])]), json: json, human: showGroup)
        default:
            throw ControlError("Unknown group command \"\(sub)\". See: cmgr help")
        }
    case "move", "mv":
        var request = try serviceArg(args)
        guard let position = args.positional.dropFirst(2).first else { throw ControlError("Missing <position> (1 = top).") }
        request["position"] = .string(position)
        let result = try backend.call("move", request)
        output(result, json: json) { r in
            if case .array(let names)? = r["order"] {
                for (i, n) in names.enumerated() { print("\(i + 1). \(n.stringValue ?? "")") }
            }
        }
    case "delete", "rm", "remove":
        var request = try serviceArg(args)
        if args.has("--clear-logs") { request["clearLogs"] = .bool(true) }
        let result = try backend.call("delete", request)
        output(result, json: json) { r in print("Deleted \(r["deleted"]?.stringValue ?? "")") }
    case "add", "create", "new":
        var request: [String: JSONValue] = [:]
        // Also accepts: cmgr add NAME -- command words…
        var rest = Array(args.positional.dropFirst())
        // cmgr add ./server.sh  |  cmgr add --file ~/app  → infer folder + command from the file.
        var file = args.value("--file")
        if file == nil, rest.count == 1, args.value("--cmd", "--command") == nil,
           FileManager.default.fileExists(atPath: (rest[0] as NSString).expandingTildeInPath) {
            file = rest.removeFirst()
        }
        if let file {
            let expanded = (file as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            request["file"] = .string((absolute as NSString).standardizingPath)
        }
        if let name = args.value("--name") {
            request["name"] = .string(name)
        } else if !rest.isEmpty {
            request["name"] = .string(rest.removeFirst())
        }
        if let cmd = args.value("--cmd", "--command") ?? (rest.isEmpty ? nil : rest.joined(separator: " ")) {
            request["command"] = .string(cmd)
        }
        if let cwd = args.value("--cwd") { request["workingDirectory"] = .string(cwd) }
        if let env = envArgs(args) { request["env"] = env }
        if let auto = boolFlag(args, "--auto-start") { request["autoStart"] = auto }
        if args.has("--disabled") { request["enabled"] = .bool(false) }
        if let restart = boolFlag(args, "--restart") { request["restartOnExit"] = restart }
        if let group = args.value("--group") { request["group"] = .string(group) }
        if let enabled = boolFlag(args, "--enabled") { request["enabled"] = enabled }
        let result = try backend.call("add", request)
        output(result, json: json) { r in
            print("Added \(r["name"]?.stringValue ?? "") (\(r["id"]?.stringValue ?? "")). Start it: cmgr start \"\(r["name"]?.stringValue ?? "")\"")
        }
    case "edit", "update", "set":
        var request = try serviceArg(args)
        if let name = args.value("--name") { request["newName"] = .string(name) }
        if let cmd = args.value("--cmd", "--command") { request["command"] = .string(cmd) }
        if let cwd = args.value("--cwd") { request["workingDirectory"] = .string(cwd) }
        if let env = envArgs(args) { request["env"] = env }
        if let auto = boolFlag(args, "--auto-start") { request["autoStart"] = auto }
        if let enabled = boolFlag(args, "--enabled") { request["enabled"] = enabled }
        if let restart = boolFlag(args, "--restart") { request["restartOnExit"] = restart }
        if let group = args.value("--group") { request["group"] = .string(group) }
        output(try backend.call("update", request), json: json, human: printService)
    case "mcp":
        let server = MCPServer(version: version) { op, arguments in try backend.call(op, arguments) }
        server.runStdio()
    case "mcp-config":
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        let config: JSONValue = .object(["mcpServers": .object([
            "command-manager": .object(["command": .string(binary), "args": .array([.string("mcp")])]),
        ])])
        print(config.encodedString(pretty: true))
        stderrPrint("Claude Code: claude mcp add command-manager -- \(binary) mcp")
    default:
        stderrPrint("Unknown command \"\(command)\".\n")
        print(usage)
        return 1
    }
    return 0
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch {
    stderrPrint("cmgr: \(error.localizedDescription)")
    exit(1)
}
