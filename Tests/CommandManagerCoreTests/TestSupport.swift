import Foundation
@testable import CommandManagerCore

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cm-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls the main actor until `condition` holds or the timeout elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

final class FakeHandle: ProcessHandle {
    let pid: Int32
    var terminateCount = 0
    var killCount = 0
    var onTerminate: (() -> Void)?
    /// Simulates members of the process group outliving the shell.
    var groupAlive = false
    var groupSignals: [Int32] = []
    init(pid: Int32) { self.pid = pid }
    func terminate() { terminateCount += 1; onTerminate?() }
    func forceKill() { killCount += 1 }
    var groupStillAlive: Bool { groupAlive }
    func signalRemainingGroup(_ signal: Int32) { groupSignals.append(signal) }
}

/// Records launches and lets tests drive output/exit manually.
final class FakeRunner: CommandRunner {
    var specs: [LaunchSpec] = []
    var handles: [FakeHandle] = []
    var exits: [(Termination) -> Void] = []
    var outputs: [(LogSource, Data) -> Void] = []
    var error: Error?
    var nextPID: Int32 = 1000

    func launch(_ spec: LaunchSpec, onOutput: @escaping (LogSource, Data) -> Void,
                onExit: @escaping (Termination) -> Void) throws -> ProcessHandle {
        if let error { throw error }
        specs.append(spec)
        nextPID += 1
        let handle = FakeHandle(pid: nextPID)
        handles.append(handle)
        exits.append(onExit)
        outputs.append(onOutput)
        return handle
    }
}

final class FakeLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var failWith: Error?
    func setEnabled(_ enabled: Bool) throws {
        if let failWith { throw failWith }
        status = enabled ? .enabled : .disabled
    }
}
