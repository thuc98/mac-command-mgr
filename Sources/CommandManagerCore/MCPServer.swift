import Foundation

/// One MCP tool mapped onto a control operation.
public struct MCPTool: Sendable {
    public let name: String
    public let op: ControlOp
    public let description: String
    public let properties: [String: JSONValue]
    public let required: [String]

    public var definition: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(op.isReadOnly),
                "destructiveHint": .bool([.delete, .clearLogs, .forceStop, .stop].contains(op)),
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}

/// Model Context Protocol server (JSON-RPC 2.0, newline-delimited over stdio) exposing
/// Command Manager to AI clients. Transport-agnostic: feed it messages with `handle(_:)`.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let version: String
    private let call: (String, [String: JSONValue]) throws -> JSONValue

    public init(version: String, call: @escaping (String, [String: JSONValue]) throws -> JSONValue) {
        self.version = version
        self.call = call
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let service = prop("string", "Command name (case-insensitive, a unique fragment is enough) or id.")

    public static let tools: [MCPTool] = [
        MCPTool(name: "list_services", op: .list,
                description: "List every command managed by Command Manager with its state (running/stopped/failed/…), PID, exit code, last error, folder, environment and log file path.",
                properties: [:], required: []),
        MCPTool(name: "get_context", op: .context,
                description: "Markdown snapshot for diagnosis: a table of all commands and states plus recent error lines of failing commands (or of `service`). Good first call.",
                properties: ["service": service, "lines": prop("integer", "Error lines per command (default 20, max 200).")], required: []),
        MCPTool(name: "service_status", op: .status,
                description: "State, PID, exit code, last error and definition of one command.",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "read_logs", op: .logs,
                description: "Tail of one command's log (stdout [out], stderr [err], Command Manager events [sys]) with optional filters. Logs may contain secrets.",
                properties: [
                    "service": service,
                    "lines": prop("integer", "How many matching lines to return from the end (default 100, max 2000)."),
                    "grep": prop("string", "Case-insensitive substring filter."),
                    "errors": prop("boolean", "Only stderr lines and lines that look like errors (error, exception, failed, panic, …)."),
                    "source": .object(["type": .string("string"), "enum": .array(["out", "err", "sys"].map { .string($0) }),
                                       "description": .string("Only lines from this stream.")]),
                ], required: ["service"]),
        MCPTool(name: "start_service", op: .start,
                description: "Start a stopped/exited/failed command. Returns immediately in state `starting`; check service_status or read_logs afterwards.",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "stop_service", op: .stop,
                description: "Gracefully stop a running command (SIGTERM to its process group), or cancel its scheduled automatic restart.",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "restart_service", op: .restart,
                description: "Restart a running command (or start it if it is not running).",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "force_stop_service", op: .forceStop,
                description: "Kill a command immediately (SIGKILL to its process group). Use when stop_service hangs.",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "clear_status", op: .clearStatus,
                description: "Reset a failed/exited/unknown command back to stopped (sends no signal). Needed before starting a command shown as `unknown`.",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "create_service", op: .add,
                description: "Create a new command. Give `file` (a script, executable, .app or project folder) to fill name, working folder and run command automatically, or give `name` + `command`. It runs as `/bin/zsh -lc <command>` in `workingDirectory` with the user's login-shell environment plus `env`. Creating does not start it.",
                properties: [
                    "file": prop("string", "Absolute path of a file/folder to run; infers name, workingDirectory and command (explicit fields override)."),
                    "name": prop("string", "Unique display name."),
                    "command": prop("string", "Shell command, e.g. `npm run dev`."),
                    "workingDirectory": prop("string", "Absolute folder (or ~/…). Empty = home folder."),
                    "env": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")]),
                                    "description": .string("Extra environment variables {KEY: value}.")]),
                    "enabled": prop("boolean", "Default true."),
                    "autoStart": prop("boolean", "Start when Command Manager opens. Default false."),
                    "restartOnExit": prop("boolean", "Restart automatically when it exits or crashes (backoff 1 s doubling to 60 s). Default false."),
                    "group": prop("string", "Group name or id to put it in (created if new)."),
                ], required: []),
        MCPTool(name: "update_service", op: .update,
                description: "Edit a command. Only the given fields change; `env` replaces the whole environment. Restart it for changes to take effect on a running command.",
                properties: [
                    "service": service,
                    "newName": prop("string", "Rename."),
                    "command": prop("string", "New shell command."),
                    "workingDirectory": prop("string", "New folder (empty string = home)."),
                    "env": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")]),
                                    "description": .string("Replaces all extra environment variables.")]),
                    "enabled": prop("boolean", "Enable or disable."),
                    "autoStart": prop("boolean", "Start when Command Manager opens."),
                    "restartOnExit": prop("boolean", "Restart automatically when it exits or crashes (backoff 1 s doubling to 60 s)."),
                    "group": prop("string", "Group name/id (created if new); empty string = no group."),
                ], required: ["service"]),
        MCPTool(name: "enable_service", op: .enable, description: "Enable a command so it can be started.",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "disable_service", op: .disable, description: "Disable a command (it can no longer be started or auto-started).",
                properties: ["service": service], required: ["service"]),
        MCPTool(name: "delete_service", op: .delete,
                description: "Delete a command definition. The command must be stopped first. Log files are kept unless clearLogs is true.",
                properties: ["service": service, "clearLogs": prop("boolean", "Also delete its log files.")], required: ["service"]),
        MCPTool(name: "move_service", op: .move,
                description: "Change a command's position within its group, or among top-level rows when it has no group (1 = top). Returns the new order.",
                properties: ["service": service, "position": prop("integer", "New 1-based position; out-of-range values clamp to top/bottom.")],
                required: ["service", "position"]),
        MCPTool(name: "create_group", op: .groupCreate,
                description: "Create a list group, optionally moving commands into it.",
                properties: ["name": prop("string", "Group name."),
                             "services": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                                  "description": .string("Commands to put in it.")])],
                required: ["name"]),
        MCPTool(name: "rename_group", op: .groupRename, description: "Rename a group.",
                properties: ["group": prop("string", "Group name or id."), "newName": prop("string", "New name.")],
                required: ["group", "newName"]),
        MCPTool(name: "delete_group", op: .groupDelete,
                description: "Remove a group. Its commands are kept and move to the top level where the group was.",
                properties: ["group": prop("string", "Group name or id.")], required: ["group"]),
        MCPTool(name: "set_service_group", op: .groupSet,
                description: "Move a command into a group (created if the name is new) or out of any group (empty group).",
                properties: ["service": service, "group": prop("string", "Group name/id; empty string = no group."),
                             "position": prop("integer", "1-based position inside the destination (default: last).")],
                required: ["service", "group"]),
        MCPTool(name: "move_group", op: .groupMove, description: "Change a group's position among top-level rows (1 = top).",
                properties: ["group": prop("string", "Group name or id."), "position": prop("integer", "1-based position.")],
                required: ["group", "position"]),
        MCPTool(name: "start_group", op: .groupStart, description: "Start every enabled, stopped command in a group.",
                properties: ["group": prop("string", "Group name or id.")], required: ["group"]),
        MCPTool(name: "stop_group", op: .groupStop, description: "Stop every running command in a group.",
                properties: ["group": prop("string", "Group name or id.")], required: ["group"]),
        MCPTool(name: "clear_logs", op: .clearLogs, description: "Delete a command's log files.",
                properties: ["service": service], required: ["service"]),
    ]

    /// Handles one JSON-RPC message; nil for notifications (no reply).
    public func handle(_ message: JSONValue) -> JSONValue? {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            return id.map { error($0, code: -32600, "Invalid request") }
        }
        guard let id else { return nil } // notification (initialized, cancelled, …)
        let params = message["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("command-manager"), "version": .string(self.version)]),
                "instructions": .string("Manage local dev services run by the Command Manager macOS app. Start with get_context or list_services, then read_logs (errors=true) to diagnose. Start/stop/restart require the app to be running. Logs may contain secrets."),
            ]))
        case "ping":
            return result(id, .object([:]))
        case "tools/list":
            return result(id, .object(["tools": .array(Self.tools.map(\.definition))]))
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = Self.tools.first(where: { $0.name == name }) else {
                return error(id, code: -32602, "Unknown tool: \(params["name"]?.stringValue ?? "(none)")")
            }
            let args = params["arguments"]?.objectValue ?? [:]
            do {
                let output = try call(tool.op.rawValue, args)
                let text: String
                if case .string(let s) = output { text = s } else { text = output.encodedString(pretty: true) }
                return result(id, .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                           "isError": .bool(false)]))
            } catch {
                return result(id, .object(["content": .array([.object(["type": .string("text"), "text": .string(error.localizedDescription)])]),
                                           "isError": .bool(true)]))
            }
        default:
            return error(id, code: -32601, "Method not found: \(method)")
        }
    }

    /// Runs the stdio loop until stdin closes.
    public func runStdio() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply: JSONValue?
            if let message = try? JSONValue.decode(Data(line.utf8)) {
                reply = handle(message)
            } else {
                reply = error(.null, code: -32700, "Parse error")
            }
            if let reply {
                FileHandle.standardOutput.write(reply.encoded() + Data([0x0A]))
            }
        }
    }

    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private func error(_ id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .from(code), "message": .string(message)])])
    }
}
