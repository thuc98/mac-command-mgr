import Foundation
import Testing
@testable import CommandManagerCore

@MainActor
@Suite struct SupervisorStateMachineTests {
    func make(timeout: TimeInterval = 10, runtime: URL? = nil) -> (ProcessSupervisor, FakeRunner, LogStore) {
        let runner = FakeRunner()
        let logs = LogStore(directory: makeTempDirectory())
        return (ProcessSupervisor(runner: runner, logStore: logs, stopTimeout: timeout, runtimeFileURL: runtime,
                                  identityProvider: { ProcessIdentity(pid: $0, startTime: 42) }), runner, logs)
    }

    @Test func startGoesStartingThenRunningWithPID() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        var seen: [RuntimeState] = []
        sup.onStateChange = { _, s in seen.append(s) }
        try sup.start(d)
        #expect(sup.record(for: d.id).state == .starting)
        #expect(await waitUntil { sup.record(for: d.id).state == .running })
        #expect(sup.record(for: d.id).pid == runner.handles[0].pid)
        #expect(sup.record(for: d.id).startedAt != nil)
        #expect(seen == [.starting, .running])
    }

    @Test func disabledServiceCannotStart() {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b", isEnabled: false)
        #expect(throws: SupervisorError.disabled) { try sup.start(d) }
        #expect(runner.specs.isEmpty)
    }

    @Test func cannotStartTwiceOrStopWhenNotRunning() async throws {
        let (sup, _, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        #expect(throws: SupervisorError.notRunning) { try sup.stop(d.id) }
        try sup.start(d)
        #expect(throws: SupervisorError.alreadyActive) { try sup.start(d) }
    }

    @Test func stopGoesStoppingThenStopped() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        try sup.stop(d.id)
        #expect(sup.record(for: d.id).state == .stopping)
        #expect(runner.handles[0].terminateCount == 1)
        runner.exits[0](.signaled(15))
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
        #expect(sup.record(for: d.id).pid == nil)
        #expect(sup.record(for: d.id).lastError == nil)
    }

    @Test func stopTimeoutOffersForceStopOnlyThen() async throws {
        let (sup, runner, _) = make(timeout: 0.1)
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        #expect(throws: SupervisorError.notRunning) { try sup.forceStop(d.id) }
        try sup.stop(d.id)
        #expect(!sup.record(for: d.id).stopTimedOut)
        #expect(await waitUntil { sup.record(for: d.id).stopTimedOut })
        try sup.forceStop(d.id)
        #expect(runner.handles[0].killCount == 1)
        runner.exits[0](.signaled(9))
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
    }

    @Test func nonZeroExitIsFailedAndZeroIsExited() async throws {
        let (sup, runner, _) = make()
        let a = ServiceDefinition(displayName: "a", command: "b")
        let b = ServiceDefinition(displayName: "b", command: "c")
        try sup.start(a); try sup.start(b)
        _ = await waitUntil { runner.exits.count == 2 }
        runner.exits[0](.exited(3))
        runner.exits[1](.exited(0))
        #expect(await waitUntil { sup.record(for: a.id).state == .failed && sup.record(for: b.id).state == .exited })
        #expect(sup.record(for: a.id).exitCode == 3)
        #expect(sup.record(for: a.id).lastError?.contains("3") == true)
        #expect(sup.record(for: b.id).exitCode == 0)
    }

    @Test func externalKillIsFailedAndNotRestarted() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b", autoStartMode: .atAppLaunch)
        try sup.start(d)
        _ = await waitUntil { runner.exits.count == 1 }
        runner.exits[0](.signaled(9))
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.specs.count == 1)
    }

    @Test func spawnFailureBecomesFailedWithMessage() async throws {
        let (sup, runner, _) = make()
        runner.error = RunnerError.workingDirectoryMissing("/gone")
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        #expect(sup.record(for: d.id).lastError?.contains("/gone") == true)
    }

    @Test func restartStopsThenStartsAgain() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        sup.definitionProvider = { _ in d }
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        try sup.restart(d)
        runner.exits[0](.signaled(15))
        #expect(await waitUntil { runner.specs.count == 2 && sup.record(for: d.id).state == .running })
        #expect(sup.record(for: d.id).pid == runner.handles[1].pid)
    }

    @Test func lateExitFromPreviousRunIsIgnored() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.exits[0](.exited(0))
        _ = await waitUntil { sup.record(for: d.id).state == .exited }
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.exits[0](.exited(1)) // stale callback
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(sup.record(for: d.id).state == .running)
        // The current run's handle must survive the stale callback.
        try sup.stop(d.id)
        #expect(runner.handles[1].terminateCount == 1)
    }

    @Test func restartUsesCurrentDefinitionAndSkipsWhenDisabled() async throws {
        let (sup, runner, _) = make()
        var current = ServiceDefinition(displayName: "a", command: "b")
        sup.definitionProvider = { _ in current }
        try sup.start(current)
        _ = await waitUntil { sup.record(for: current.id).state == .running }
        try sup.restart(current)
        current.isEnabled = false // disabled while stopping
        runner.exits[0](.signaled(15))
        #expect(await waitUntil { sup.record(for: current.id).state == .stopped })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.specs.count == 1)
        #expect(sup.record(for: current.id).lastError?.contains("disabled") == true)
    }

    @Test func quittingCancelsPendingRestartAndBlocksStart() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        sup.definitionProvider = { _ in d }
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        try sup.restart(d)
        sup.stopAll()
        #expect(throws: SupervisorError.shuttingDown) { try sup.start(d) }
        runner.exits[0](.signaled(15))
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.specs.count == 1)
        #expect(!sup.hasLiveProcesses)
    }

    @Test func leftoverGroupAfterUnexpectedExitIsStoppedOnQuit() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.handles[0].groupAlive = true
        runner.exits[0](.exited(1))
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        #expect(sup.leftoverGroupCount == 1)
        sup.stopAll()
        #expect(runner.handles[0].groupSignals == [SIGTERM])
        #expect(sup.hasLiveProcesses)
        sup.forceKillAll()
        #expect(runner.handles[0].groupSignals == [SIGTERM, SIGKILL])
    }

    @Test func emptiedLeftoverGroupIsPrunedAndNeverSignalled() async throws {
        let (sup, runner, _) = make()
        sup.leftoverPruneInterval = 0.05
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.handles[0].groupAlive = true
        runner.exits[0](.exited(1))
        #expect(await waitUntil { sup.leftoverGroupCount == 1 })
        runner.handles[0].groupAlive = false // last member exited
        #expect(await waitUntil { sup.leftoverGroupCount == 0 })
        // Even if the group ID were reused later, nothing is tracked any more.
        runner.handles[0].groupAlive = true
        sup.stopAll()
        sup.forceKillAll()
        #expect(runner.handles[0].groupSignals.isEmpty)
    }

    @Test func unknownStateRequiresClearStatusBeforeStart() async throws {
        let runtime = makeTempDirectory().appendingPathComponent("runtime.json")
        let d = ServiceDefinition(displayName: "a", command: "b")
        try JSONEncoder().encode([d.id.uuidString: ProcessIdentity(pid: 4242, startTime: 1)]).write(to: runtime)
        let (sup, runner, _) = make(runtime: runtime)
        sup.restorePreviousSession(knownServiceIDs: [d.id], isAlive: { _ in true })
        #expect(throws: SupervisorError.unverifiedProcess) { try sup.start(d) }
        #expect(runner.specs.isEmpty)
        sup.clearStatus(d.id)
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .running })
    }

    @Test func forgetIsRefusedWhileProcessIsOwned() async throws {
        let (sup, runner, _) = make()
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        #expect(throws: SupervisorError.stillActive) { try sup.forget(d.id) }
        try sup.stop(d.id)
        #expect(throws: SupervisorError.stillActive) { try sup.forget(d.id) }
        runner.exits[0](.signaled(15))
        _ = await waitUntil { sup.record(for: d.id).state == .stopped }
        try sup.forget(d.id)
        #expect(sup.records[d.id] == nil)
    }

    @Test func previousSessionPIDIsUnknownAndNeverSignalled() async throws {
        let runtime = makeTempDirectory().appendingPathComponent("runtime.json")
        let id = UUID(), gone = UUID(), deleted = UUID()
        let stored = [id.uuidString: ProcessIdentity(pid: 4242, startTime: 1),
                      gone.uuidString: ProcessIdentity(pid: 4343, startTime: 1),
                      deleted.uuidString: ProcessIdentity(pid: 4444, startTime: 1)]
        try JSONEncoder().encode(stored).write(to: runtime)
        let (sup, runner, _) = make(runtime: runtime)
        sup.restorePreviousSession(knownServiceIDs: [id, gone], isAlive: { $0.pid == 4242 || $0.pid == 4444 })
        #expect(sup.record(for: id).state == .unknown)
        #expect(sup.record(for: id).pid == 4242)
        #expect(sup.record(for: gone).state == .stopped)
        #expect(sup.record(for: deleted).state == .stopped)
        #expect(throws: SupervisorError.notRunning) { try sup.stop(id) }
        #expect(runner.handles.isEmpty)
        sup.clearStatus(id)
        #expect(sup.record(for: id).state == .stopped)
    }

    @Test func runtimeFileTracksLivePIDs() async throws {
        let runtime = makeTempDirectory().appendingPathComponent("runtime.json")
        let (sup, runner, _) = make(runtime: runtime)
        let d = ServiceDefinition(displayName: "a", command: "b")
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        let saved = try JSONDecoder().decode([String: ProcessIdentity].self, from: Data(contentsOf: runtime))
        #expect(saved[d.id.uuidString] == ProcessIdentity(pid: runner.handles[0].pid, startTime: 42))
        runner.exits[0](.exited(0))
        _ = await waitUntil { sup.record(for: d.id).state == .exited }
        let after = try JSONDecoder().decode([String: ProcessIdentity].self, from: Data(contentsOf: runtime))
        #expect(after.isEmpty)
    }
}

@MainActor
@Suite struct AppModelTests {
    func make(runner: FakeRunner = FakeRunner(), login: FakeLoginItem = FakeLoginItem(), root: URL = makeTempDirectory()) -> AppModel {
        AppModel(paths: AppPaths(root: root), runner: runner, loginItem: login,
                 identityProvider: { ProcessIdentity(pid: $0, startTime: 42) })
    }

    @Test func savePersistsAcrossRelaunchAndDoesNotStart() throws {
        let root = makeTempDirectory()
        let runner = FakeRunner()
        let model = make(runner: runner, root: root)
        model.launch()
        let saved = try model.save(ServiceDraft(displayName: "API", command: "npm start", workingDirectory: root.path), editing: nil).get()
        #expect(runner.specs.isEmpty)
        let relaunched = make(root: root)
        relaunched.launch()
        #expect(relaunched.services.map(\.id) == [saved.id])
        #expect(relaunched.services[0].workingDirectory == root.path)
    }

    @Test func invalidWorkingDirectoryIsNotSaved() {
        let model = make()
        model.launch()
        let result = model.save(ServiceDraft(displayName: "x", command: "y", workingDirectory: "/definitely/missing"), editing: nil)
        guard case .failure(let error as ValidationFailure) = result else { Issue.record("expected failure"); return }
        #expect(error.issues.first?.field == .workingDirectory)
        #expect(model.services.isEmpty)
    }

    @Test func launchAutoStartsOnlyEnabledAutoStartCommands() async throws {
        let root = makeTempDirectory()
        let seed = make(root: root)
        seed.launch()
        let combos: [(String, Bool, Bool)] = [("on-auto", true, true), ("on-manual", true, false), ("off-auto", false, true), ("off-manual", false, false)]
        for (name, enabled, auto) in combos {
            _ = try seed.save(ServiceDraft(displayName: name, command: "true", isEnabled: enabled, autoStart: auto), editing: nil).get()
        }
        let runner = FakeRunner()
        let model = make(runner: runner, root: root)
        model.launch()
        #expect(await waitUntil { runner.specs.count == 1 })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.specs.count == 1)
        let started = model.services.first { model.record($0.id).state.isActive }
        #expect(started?.displayName == "on-auto")
    }

    @Test func launchSkipsAutoStartWhenPreviousProcessIsUnverified() async throws {
        let root = makeTempDirectory()
        let seed = make(root: root)
        seed.launch()
        let d = try seed.save(ServiceDraft(displayName: "svc", command: "true", autoStart: true), editing: nil).get()
        // Our own process is certainly alive, standing in for a leftover from a crashed session.
        let me = try #require(ProcessIdentity.current(pid: getpid()))
        try JSONEncoder().encode([d.id.uuidString: me]).write(to: AppPaths(root: root).runtimeFile)
        let runner = FakeRunner()
        let model = make(runner: runner, root: root)
        model.launch()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.specs.isEmpty)
        #expect(model.record(d.id).state == .unknown)
    }

    @Test func disableBlocksStartAndReenableAllowsIt() async throws {
        let runner = FakeRunner()
        let model = make(runner: runner)
        model.launch()
        let d = try model.save(ServiceDraft(displayName: "svc", command: "true"), editing: nil).get()
        try model.setEnabled(false, for: d.id)
        model.start(d.id)
        #expect(model.banner != nil)
        #expect(model.record(d.id).state == .stopped)
        #expect(model.service(d.id) != nil)
        model.banner = nil
        try model.setEnabled(true, for: d.id)
        model.start(d.id)
        #expect(model.banner == nil)
        #expect(await waitUntil { model.record(d.id).state == .running })
    }

    @Test func deleteRequiresStopThenRemovesDefinitionAndKeepsFolder() async throws {
        let root = makeTempDirectory()
        let runner = FakeRunner()
        let model = make(runner: runner, root: root)
        model.launch()
        let d = try model.save(ServiceDraft(displayName: "svc", command: "true", workingDirectory: root.path, autoStart: true), editing: nil).get()
        model.start(d.id)
        _ = await waitUntil { model.record(d.id).state == .running }
        #expect(throws: SupervisorError.stillActive) { try model.delete(d.id) }
        #expect(model.services.count == 1)
        model.stop(d.id)
        runner.exits[0](.signaled(15))
        _ = await waitUntil { model.record(d.id).state == .stopped }
        try model.delete(d.id)
        #expect(model.services.isEmpty)
        #expect(model.supervisor.records[d.id] == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
        let relaunched = make(root: root)
        relaunched.launch()
        #expect(relaunched.services.isEmpty)
    }

    @Test func loginItemFailureIsReportedAndStatusNotFaked() {
        let login = FakeLoginItem()
        login.failWith = LoginItemError.failed("denied")
        let model = make(login: login)
        model.launch()
        model.setOpenAtLogin(true)
        #expect(model.loginItemStatus == .disabled)
        #expect(model.banner?.contains("denied") == true)
        login.failWith = nil
        model.setOpenAtLogin(true)
        #expect(model.loginItemStatus == .enabled)
    }

    @Test func reusedPIDFromAnotherBootIsNotUnknown() async throws {
        let root = makeTempDirectory()
        let seed = make(root: root)
        seed.launch()
        let d = try seed.save(ServiceDraft(displayName: "svc", command: "true", autoStart: true), editing: nil).get()
        // Same live PID, different start time: an unrelated process now owns that number.
        let me = try #require(ProcessIdentity.current(pid: getpid()))
        let stale = ProcessIdentity(pid: me.pid, startTime: me.startTime &- 1_000_000)
        try JSONEncoder().encode([d.id.uuidString: stale]).write(to: AppPaths(root: root).runtimeFile)
        let runner = FakeRunner()
        let model = make(runner: runner, root: root)
        model.launch()
        #expect(await waitUntil { runner.specs.count == 1 })
        #expect(model.record(d.id).state != .unknown)
    }
}
