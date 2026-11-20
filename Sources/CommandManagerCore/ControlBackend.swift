import Foundation

/// How `cmgr` and the MCP server reach Command Manager: the running app over its control
/// socket, or — when the app is closed — the saved files directly (reads and definition edits).
/// Process actions (start/stop/…) can launch the app first via `launchApp`.
public final class ControlBackend {
    public let paths: AppPaths
    private let launchApp: (() -> Bool)?
    private let timeout: TimeInterval

    /// - Parameter launchApp: opens the app and returns true once it was asked to launch; nil disables auto-launch.
    public init(paths: AppPaths, timeout: TimeInterval = 30, launchApp: (() -> Bool)? = nil) {
        self.paths = paths
        self.timeout = timeout
        self.launchApp = launchApp
    }

    public var appIsRunning: Bool {
        guard let fd = try? UnixSocket.connect(paths.controlSocket.path, timeout: 1) else { return false }
        close(fd)
        return true
    }

    public func call(_ op: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        do {
            return try ControlClient.send(socketPath: paths.controlSocket.path, op: op, args: args, timeout: timeout)
        } catch let error where ControlClient.isUnavailable(error) {
            if ControlOp(rawValue: op)?.needsLiveApp == true, let launchApp {
                guard launchApp() else {
                    throw ControlError("Command Manager app is not running and could not be opened. Open it and retry.")
                }
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    if appIsRunning { return try ControlClient.send(socketPath: paths.controlSocket.path, op: op, args: args, timeout: timeout) }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                throw ControlError("Command Manager was opened but did not answer within 15 s.")
            }
            return try offline(op, args)
        }
    }

    private func offline(_ op: String, _ args: [String: JSONValue]) throws -> JSONValue {
        let paths = self.paths
        let work: @MainActor () throws -> JSONValue = {
            let model = AppModel(paths: paths, loginItem: OfflineLoginItem())
            if let error = model.loadDefinitionsOnly() { throw ControlError(error.localizedDescription) }
            return try ControlService(model: model, isLive: false).handle(op: op, args: args)
        }
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try work() }
        }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated { try work() } }
    }
}

private final class OfflineLoginItem: LoginItemManaging {
    var status: LoginItemStatus { .unavailable("cmgr") }
    func setEnabled(_ enabled: Bool) throws {}
}
