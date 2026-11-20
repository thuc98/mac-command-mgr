import Darwin
import Foundation

/// Exactly what will be executed. Commands always run through `/bin/zsh -lc`.
public struct LaunchSpec: Equatable, Sendable {
    public static let shell = "/bin/zsh"
    /// Directories always on PATH (appended after the user's own entries), shown to the user in the form.
    public static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Base environment (normally the user's login-shell environment) keeps its PATH order, with
    /// `defaultPATH` entries appended when missing; then the service's own pairs override it.
    public static func make(
        for definition: ServiceDefinition,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> LaunchSpec {
        var env = baseEnvironment
        var path = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        for entry in defaultPATH.split(separator: ":").map(String.init) where !path.contains(entry) {
            path.append(entry)
        }
        env["PATH"] = path.joined(separator: ":")
        for (key, value) in definition.environment { env[key] = value }
        return LaunchSpec(
            executable: shell,
            arguments: ["-lc", definition.command],
            workingDirectory: definition.workingDirectory ?? homeDirectory,
            environment: env
        )
    }
}

public enum Termination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// A process the app launched in this session. Signals go only through the handle, never a stored PID.
public protocol ProcessHandle: AnyObject {
    var pid: Int32 { get }
    /// Graceful stop (SIGTERM to the command's process group).
    func terminate()
    /// Forced stop (SIGKILL to the command's process group).
    func forceKill()
    /// After the shell exited: whether other members of its process group are still alive.
    var groupStillAlive: Bool { get }
    /// After the shell exited: signal the remaining members of its process group.
    func signalRemainingGroup(_ signal: Int32)
}

public extension ProcessHandle {
    var groupStillAlive: Bool { false }
    func signalRemainingGroup(_ signal: Int32) {}
}

public enum RunnerError: Error, LocalizedError, Equatable {
    case workingDirectoryMissing(String)
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .workingDirectoryMissing(let path): return "Working directory not found: \(path)"
        case .spawnFailed(let reason): return "Could not start the command: \(reason)"
        }
    }
}

public protocol CommandRunner {
    /// Launches the spec. Callbacks arrive on background queues; `onExit` is called exactly once,
    /// after output has been drained (or a short grace period if a child keeps the pipes open).
    func launch(
        _ spec: LaunchSpec,
        onOutput: @escaping (LogSource, Data) -> Void,
        onExit: @escaping (Termination) -> Void
    ) throws -> ProcessHandle
}

/// Runs commands with `posix_spawn` in their own process group so Stop reaches the whole command.
public final class PosixCommandRunner: CommandRunner {
    public init() {}

    public func launch(
        _ spec: LaunchSpec,
        onOutput: @escaping (LogSource, Data) -> Void,
        onExit: @escaping (Termination) -> Void
    ) throws -> ProcessHandle {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RunnerError.workingDirectoryMissing(spec.workingDirectory)
        }

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw RunnerError.spawnFailed(String(cString: strerror(errno))) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw RunnerError.spawnFailed(String(cString: strerror(errno)))
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid == pid); close every fd not mapped above; reset signal state.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw RunnerError.spawnFailed(String(cString: strerror(status)))
        }
        return PosixProcessHandle(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0], onOutput: onOutput, onExit: onExit)
    }
}

final class PosixProcessHandle: ProcessHandle {
    let pid: Int32
    private let queue: DispatchQueue
    private var exitSource: DispatchSourceProcess?
    private var reaped = false
    private var delivered = false
    private let drained = DispatchGroup()
    private var readers: [FileHandle] = []
    private let onExit: (Termination) -> Void

    init(pid: Int32, stdoutFD: Int32, stderrFD: Int32,
         onOutput: @escaping (LogSource, Data) -> Void,
         onExit: @escaping (Termination) -> Void) {
        self.pid = pid
        self.onExit = onExit
        self.queue = DispatchQueue(label: "CommandManager.process.\(pid)")

        for (fd, source) in [(stdoutFD, LogSource.stdout), (stderrFD, LogSource.stderr)] {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            drained.enter()
            let group = drained
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    group.leave()
                } else {
                    onOutput(source, data)
                }
            }
            readers.append(handle)
        }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reap() }
        exitSource = source
        source.resume()
        // The process may already have exited before the source was armed.
        queue.async { [weak self] in self?.reap() }
    }

    func terminate() { signal(SIGTERM) }
    func forceKill() { signal(SIGKILL) }

    // A PID is never reused while a process group with that ID exists, so signalling the
    // *group* (never the bare PID) stays safe after the leader was reaped.
    var groupStillAlive: Bool { kill(-pid, 0) == 0 }
    func signalRemainingGroup(_ signal: Int32) { _ = kill(-pid, signal) }

    private func signal(_ sig: Int32) {
        queue.sync {
            // Never signal after reaping: the PID (and group id) may have been reused.
            guard !reaped else { return }
            if kill(-pid, sig) != 0 { _ = kill(pid, sig) }
        }
    }

    /// Queue-confined.
    private func reap() {
        guard !reaped else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return }
        reaped = true
        exitSource?.cancel()
        let low = status & 0x7f
        let termination: Termination = low == 0 ? .exited((status >> 8) & 0xff) : .signaled(low)
        drained.notify(queue: queue) { [weak self] in self?.deliver(termination) }
        // Background children may keep the pipes open; don't wait for them forever.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.deliver(termination) }
    }

    private func deliver(_ termination: Termination) {
        guard !delivered else { return }
        delivered = true
        onExit(termination)
    }

    deinit {
        readers.forEach { $0.readabilityHandler = nil }
        exitSource?.cancel()
    }
}
