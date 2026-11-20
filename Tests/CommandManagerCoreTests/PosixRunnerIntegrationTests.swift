import Foundation
import Testing
@testable import CommandManagerCore

/// Real processes through /bin/zsh -lc (integration fixtures from the plan §9).
@MainActor
@Suite(.serialized) struct PosixRunnerIntegrationTests {
    func make(timeout: TimeInterval = 5) -> (ProcessSupervisor, LogStore) {
        let logs = LogStore(directory: makeTempDirectory())
        return (ProcessSupervisor(runner: PosixCommandRunner(), logStore: logs, stopTimeout: timeout), logs)
    }

    @Test func capturesStdoutAndStderrInOrderAndExitsCleanly() async throws {
        let (sup, logs) = make()
        let dir = makeTempDirectory()
        let d = ServiceDefinition(displayName: "echo", command: "echo out-$FOO; sleep 0.2; echo err >&2; sleep 0.2; pwd",
                                  workingDirectory: dir.path, environment: ["FOO": "bar"])
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .exited })
        #expect(sup.record(for: d.id).exitCode == 0)
        logs.sync()
        let lines = logs.tail(serviceID: d.id).filter { $0.source != .system }
        // Login-shell startup files may print extra lines; check our three lines keep their order.
        let texts = lines.map(\.text)
        let out = try #require(texts.firstIndex(of: "out-bar"))
        let err = try #require(texts.firstIndex(of: "err"))
        // `pwd` may report /private/var/... for a /var/... temp folder.
        let cwd = try #require(texts.lastIndex { $0.hasSuffix(dir.lastPathComponent) })
        #expect(out < err && err < cwd)
        #expect(lines[out].source == .stdout && lines[err].source == .stderr && lines[cwd].source == .stdout)
    }

    @Test func nonZeroExitIsFailed() async throws {
        let (sup, _) = make()
        let d = ServiceDefinition(displayName: "fail", command: "echo boom >&2; exit 7")
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        #expect(sup.record(for: d.id).exitCode == 7)
    }

    @Test func stopTerminatesWholeProcessGroup() async throws {
        let (sup, _) = make()
        let marker = makeTempDirectory().appendingPathComponent("child.pid")
        // zsh stays as parent of `sleep` here; the child must die too.
        let d = ServiceDefinition(displayName: "long", command: "sleep 30 & echo $! > '\(marker.path)'; wait")
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .running && FileManager.default.fileExists(atPath: marker.path) })
        _ = await waitUntil { ((try? String(contentsOf: marker)) ?? "").hasSuffix("\n") }
        let childPID = Int32((try String(contentsOf: marker)).trimmingCharacters(in: .whitespacesAndNewlines))!
        try sup.stop(d.id)
        #expect(sup.record(for: d.id).state == .stopping)
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
        #expect(await waitUntil { kill(childPID, 0) != 0 })
    }

    @Test func stopFinishesLeftoverGroupMembersAfterShellExits() async throws {
        let (sup, _) = make()
        let marker = makeTempDirectory().appendingPathComponent("child.pid")
        // The child ignores SIGTERM for a moment and outlives the shell, which exits on SIGTERM.
        let d = ServiceDefinition(displayName: "leftover",
                                  command: "zsh -c 'trap \"\" TERM; sleep 30' & echo $! > '\(marker.path)'; wait")
        try sup.start(d)
        #expect(await waitUntil { ((try? String(contentsOf: marker)) ?? "").hasSuffix("\n") })
        let childPID = Int32((try String(contentsOf: marker)).trimmingCharacters(in: .whitespacesAndNewlines))!
        try? await Task.sleep(nanoseconds: 200_000_000)
        try sup.stop(d.id)
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
        // SIGTERM is ignored by the child, so it is SIGKILLed after the grace period.
        #expect(await waitUntil(timeout: 10) { kill(childPID, 0) != 0 })
        #expect(await waitUntil { !sup.hasLiveProcesses })
    }

    @Test func unresponsiveProcessNeedsForceStop() async throws {
        let (sup, _) = make(timeout: 0.5)
        let d = ServiceDefinition(displayName: "stubborn", command: "trap '' TERM; echo ready; while true; do sleep 0.1; done")
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .running })
        try? await Task.sleep(nanoseconds: 300_000_000)
        try sup.stop(d.id)
        #expect(await waitUntil { sup.record(for: d.id).stopTimedOut })
        #expect(sup.record(for: d.id).state == .stopping)
        try sup.forceStop(d.id)
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
    }

    @Test func quitEscalatesToKillForStubbornCommands() async throws {
        let model = AppModel(paths: AppPaths(root: makeTempDirectory()), loginItem: FakeLoginItem())
        model.launch()
        let d = try model.save(ServiceDraft(displayName: "stubborn", command: "trap '' TERM; while true; do sleep 0.1; done"), editing: nil).get()
        model.start(d.id)
        #expect(await waitUntil { model.record(d.id).state == .running })
        let pid = try #require(model.record(d.id).pid)
        try? await Task.sleep(nanoseconds: 300_000_000)
        var finished = false
        model.stopAllForQuit(grace: 0.5) { finished = true }
        #expect(await waitUntil { finished })
        #expect(await waitUntil { kill(pid, 0) != 0 })
    }

    @Test func deletedWorkingDirectoryFailsWithReason() async throws {
        let (sup, _) = make()
        let dir = makeTempDirectory()
        let d = ServiceDefinition(displayName: "gone", command: "true", workingDirectory: dir.path)
        try FileManager.default.removeItem(at: dir)
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        #expect(sup.record(for: d.id).lastError?.contains(dir.path) == true)
    }

    @Test func missingExecutableIsFailedNotCrash() async throws {
        let (sup, _) = make()
        let d = ServiceDefinition(displayName: "nope", command: "definitely-not-a-real-binary-xyz")
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        #expect(sup.record(for: d.id).exitCode == 127)
    }
}
