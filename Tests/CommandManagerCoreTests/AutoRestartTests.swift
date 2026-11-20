import Foundation
import Testing
@testable import CommandManagerCore

@MainActor
@Suite struct AutoRestartTests {
    /// Supervisor with a tiny backoff (scaled-down 1 s → 60 s) and a mutable definition.
    func make(_ definition: ServiceDefinition) -> (ProcessSupervisor, FakeRunner, Box) {
        let runner = FakeRunner()
        let sup = ProcessSupervisor(runner: runner, logStore: LogStore(directory: makeTempDirectory()),
                                    identityProvider: { ProcessIdentity(pid: $0, startTime: 1) })
        sup.restartBackoffMin = 0.05
        sup.restartBackoffMax = 0.2
        sup.restartStableAfter = 10
        let box = Box(definition)
        sup.definitionProvider = { [box] id in box.value?.id == id ? box.value : nil }
        return (sup, runner, box)
    }

    final class Box { var value: ServiceDefinition?; init(_ v: ServiceDefinition) { value = v } }

    @Test func backoffDoublesFromMinAndCapsAtMax() {
        let sup = ProcessSupervisor(runner: FakeRunner(), logStore: LogStore(directory: makeTempDirectory()))
        #expect(sup.restartBackoffMin == 1 && sup.restartBackoffMax == 60)
        #expect((0...7).map { sup.restartDelay(attempt: $0) } == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(sup.restartDelay(attempt: 1000) == 60)
    }

    @Test func crashRestartsWithGrowingDelayAndCleanExitToo() async throws {
        let d = ServiceDefinition(displayName: "a", command: "b", restartOnExit: true)
        let (sup, runner, _) = make(d)
        try sup.start(d)
        #expect(await waitUntil { sup.record(for: d.id).state == .running })

        runner.exits[0](.exited(1))
        #expect(await waitUntil { sup.record(for: d.id).nextRestartAt != nil })
        #expect(sup.record(for: d.id).state == .failed)
        #expect(sup.record(for: d.id).restartAttempt == 1)
        #expect(await waitUntil { runner.specs.count == 2 && sup.record(for: d.id).state == .running })
        #expect(sup.record(for: d.id).nextRestartAt == nil)

        runner.exits[1](.signaled(9))
        #expect(await waitUntil { sup.record(for: d.id).restartAttempt == 2 })
        #expect(await waitUntil { runner.specs.count == 3 && sup.record(for: d.id).state == .running })

        runner.exits[2](.exited(0)) // a clean exit also restarts
        #expect(await waitUntil { runner.specs.count == 4 })
        #expect(sup.record(for: d.id).restartAttempt == 3)
    }

    @Test func manualStopNeverRestartsAndStopCancelsPendingRestart() async throws {
        let d = ServiceDefinition(displayName: "a", command: "b", restartOnExit: true)
        let (sup, runner, _) = make(d)
        sup.restartBackoffMin = 0.3
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        try sup.stop(d.id)
        runner.exits[0](.signaled(15))
        #expect(await waitUntil { sup.record(for: d.id).state == .stopped })
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(runner.specs.count == 1)

        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.exits[1](.exited(3))
        #expect(await waitUntil { sup.record(for: d.id).nextRestartAt != nil })
        try sup.stop(d.id) // cancels the scheduled restart, no throw
        #expect(sup.record(for: d.id).nextRestartAt == nil)
        #expect(sup.record(for: d.id).restartAttempt == 0)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(runner.specs.count == 2)
    }

    @Test func turningOffOrDisablingCancelsAndNoRestartWithoutFlag() async throws {
        let d = ServiceDefinition(displayName: "a", command: "b", restartOnExit: true)
        let (sup, runner, box) = make(d)
        sup.restartBackoffMin = 0.3
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.exits[0](.exited(1))
        #expect(await waitUntil { sup.record(for: d.id).nextRestartAt != nil })
        box.value?.isEnabled = false
        sup.definitionsChanged()
        #expect(sup.record(for: d.id).nextRestartAt == nil)
        try? await Task.sleep(nanoseconds: 450_000_000)
        #expect(runner.specs.count == 1)

        box.value?.isEnabled = true
        box.value?.restartOnExit = false
        try sup.start(box.value!)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.exits[1](.exited(1))
        #expect(await waitUntil { sup.record(for: d.id).state == .failed })
        #expect(sup.record(for: d.id).nextRestartAt == nil)
    }

    @Test func quitCancelsPendingRestart() async throws {
        let d = ServiceDefinition(displayName: "a", command: "b", restartOnExit: true)
        let (sup, runner, _) = make(d)
        sup.restartBackoffMin = 0.2
        try sup.start(d)
        _ = await waitUntil { sup.record(for: d.id).state == .running }
        runner.exits[0](.exited(1))
        #expect(await waitUntil { sup.record(for: d.id).nextRestartAt != nil })
        sup.stopAll()
        try? await Task.sleep(nanoseconds: 350_000_000)
        #expect(runner.specs.count == 1)
    }

    @Test func definitionDecodesWithoutRestartFlagAndRoundTrips() throws {
        let legacy = #"{"id":"8C1B6A6E-1D7B-4E59-9A55-0E9E9C7B1C11","displayName":"a","command":"b","environment":{},"isEnabled":true,"autoStartMode":"manual","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","schemaVersion":1}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let d = try decoder.decode(ServiceDefinition.self, from: Data(legacy.utf8))
        #expect(d.restartOnExit == false)
        var on = d; on.restartOnExit = true
        #expect(try decoder.decode(ServiceDefinition.self, from: encoder.encode(on)) == on)
        #expect(ServiceDraft(on).restartOnExit)
    }
}
