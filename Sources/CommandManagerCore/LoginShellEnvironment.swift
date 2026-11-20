import Darwin
import Foundation

/// The environment a Terminal window would have: an app started from Finder / login item only gets
/// launchd's minimal environment (PATH=/usr/bin:/bin:/usr/sbin:/sbin), so tools whose PATH is set in
/// `~/.profile`, `~/.bash_profile`, `~/.zprofile` or `~/.zshrc` (Go, nvm, pyenv, …) are not found.
public enum LoginShellEnvironment {
    /// The user's login shell from the user database (what Terminal uses), falling back to `$SHELL`.
    public static func userShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return LaunchSpec.shell
    }

    static let marker = "__COMMAND_MANAGER_ENV__"

    /// Runs the shell as an interactive login shell (reads the same startup files as Terminal) and
    /// captures its environment. Returns nil on failure or timeout. Blocking: call off the main thread.
    public static func capture(
        shell: String = userShell(),
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) -> [String: String]? {
        let process = Process()
        if let environment { process.environment = environment }
        process.executableURL = URL(fileURLWithPath: shell)
        // Markers isolate `env -0` output from anything the startup files print.
        process.arguments = ["-i", "-l", "-c", "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        var collected = Data()
        let lock = NSLock()
        let drained = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                lock.lock(); collected.append(chunk); lock.unlock()
            }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        if drained.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        process.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        return parse(collected)
    }

    /// Extracts the NUL-separated `KEY=VALUE` pairs between the two markers.
    static func parse(_ data: Data) -> [String: String]? {
        let markerData = Data(marker.utf8)
        guard let start = data.range(of: markerData),
              let end = data.range(of: markerData, options: .backwards, in: start.upperBound..<data.endIndex)
        else { return nil }
        var environment: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let pair = String(data: Data(entry), encoding: .utf8),
                  let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            environment[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        // Shell-session bookkeeping that must not leak into launched commands.
        for key in ["_", "SHLVL", "OLDPWD", "PWD"] { environment.removeValue(forKey: key) }
        return environment.isEmpty ? nil : environment
    }

    /// The app's environment with the login shell's values on top (PATH included).
    public static func merged(app: [String: String], shell: [String: String]?) -> [String: String] {
        guard let shell else { return app }
        return app.merging(shell) { _, fromShell in fromShell }
    }
}
