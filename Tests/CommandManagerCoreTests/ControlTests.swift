import Foundation
import Testing
@testable import CommandManagerCore

@MainActor
private func makeLive() -> (AppModel, FakeRunner, ControlService) {
    let runner = FakeRunner()
    let model = AppModel(paths: AppPaths(root: makeTempDirectory()), runner: runner, loginItem: FakeLoginItem(),
                         identityProvider: { ProcessIdentity(pid: $0, startTime: 1) })
    model.launch()
    return (model, runner, ControlService(model: model, isLive: true))
}

@Suite @MainActor struct ControlServiceTests {
    @Test func addListStartStopRestartDelete() async throws {
        let (model, runner, control) = makeLive()
        let added = try control.handle(op: "add", args: [
            "name": .string("API"), "command": .string("npm run dev"),
            "env": .object(["PORT": .string("3000")]), "autoStart": .bool(true),
        ])
        #expect(added["state"]?.stringValue == "stopped")
        #expect(model.services.first?.environment == ["PORT": "3000"])
        #expect(model.services.first?.autoStart == true)

        _ = try control.handle(op: "start", args: ["service": .string("api")])
        #expect(await waitUntil { model.record(model.services[0].id).state == .running })
        let status = try control.handle(op: "status", args: ["service": .string("ap")])
        #expect(status["state"]?.stringValue == "running")
        #expect(status["pid"]?.intValue == 1001)

        _ = try control.handle(op: "restart", args: ["service": .string("API")])
        runner.exits[0](.signaled(15))
        #expect(await waitUntil { runner.specs.count == 2 && model.record(model.services[0].id).state == .running })

        // Delete refuses while running, then works once stopped.
        #expect(throws: ControlError.self) { try control.handle(op: "delete", args: ["service": .string("api")]) }
        _ = try control.handle(op: "stop", args: ["service": .string("api")])
        runner.exits[1](.signaled(15))
        #expect(await waitUntil { model.record(model.services[0].id).state == .stopped })
        let deleted = try control.handle(op: "delete", args: ["service": .string("api")])
        #expect(deleted["deleted"]?.stringValue == "API")
        #expect(model.services.isEmpty)
    }

    @Test func updateDisableAndValidationErrors() throws {
        let (model, _, control) = makeLive()
        _ = try control.handle(op: "add", args: ["name": .string("a"), "command": .string("x")])
        _ = try control.handle(op: "add", args: ["name": .string("b"), "command": .string("y")])
        let updated = try control.handle(op: "update", args: [
            "service": .string("a"), "newName": .string("alpha"), "env": .array([.string("K=V")]),
        ])
        #expect(updated["name"]?.stringValue == "alpha")
        #expect(updated["command"]?.stringValue == "x")
        #expect(model.services[0].environment == ["K": "V"])

        _ = try control.handle(op: "disable", args: ["service": .string("alpha")])
        #expect(model.services[0].isEnabled == false)
        #expect(throws: (any Error).self) { try control.handle(op: "start", args: ["service": .string("alpha")]) }

        #expect(throws: ControlError.self) { try control.handle(op: "update", args: ["service": .string("b"), "newName": .string("ALPHA")]) }
        #expect(throws: ControlError.self) { try control.handle(op: "add", args: ["name": .string("c")]) }
        #expect(throws: ControlError.self) { try control.handle(op: "nope", args: [:]) }
    }

    @Test func resolveByIdNameFragmentAndAmbiguity() throws {
        let a = ServiceDefinition(displayName: "api-server", command: "x")
        let b = ServiceDefinition(displayName: "api-worker", command: "y")
        #expect(try ControlService.resolve(a.id.uuidString, in: [a, b]) == a)
        #expect(try ControlService.resolve("API-WORKER", in: [a, b]) == b)
        #expect(try ControlService.resolve("server", in: [a, b]) == a)
        #expect(throws: ControlError.self) { try ControlService.resolve("api", in: [a, b]) }
        #expect(throws: ControlError.self) { try ControlService.resolve("zzz", in: [a, b]) }
    }

    @Test func logsFilterAndLimit() throws {
        let (model, _, control) = makeLive()
        _ = try control.handle(op: "add", args: ["name": .string("svc"), "command": .string("x")])
        let id = model.services[0].id
        for i in 1...10 { model.logStore.append(Data("line \(i)\n".utf8), source: .stdout, serviceID: id) }
        model.logStore.append(Data("Error: boom\n".utf8), source: .stdout, serviceID: id)
        model.logStore.append(Data("warning on stderr\n".utf8), source: .stderr, serviceID: id)

        let tail = try control.handle(op: "logs", args: ["service": .string("svc"), "lines": .from(3)])
        guard case .array(let lines)? = tail["lines"] else { Issue.record("no lines"); return }
        #expect(lines.count == 3)
        #expect(lines.last?.stringValue?.hasSuffix("[err] warning on stderr") == true)
        #expect(tail["truncated"]?.boolValue == true)

        let errors = try control.handle(op: "logs", args: ["service": .string("svc"), "errors": .bool(true)])
        #expect(errors["matched"]?.intValue == 2)
        let grep = try control.handle(op: "logs", args: ["service": .string("svc"), "grep": .string("LINE 1")])
        #expect(grep["matched"]?.intValue == 2) // line 1, line 10

        let context = try control.handle(op: "context", args: ["service": .string("svc")]).stringValue ?? ""
        #expect(context.contains("| svc |"))
        #expect(context.contains("Error: boom"))

        _ = try control.handle(op: "clear_logs", args: ["service": .string("svc")])
        let cleared = try control.handle(op: "logs", args: ["service": .string("svc")])
        #expect(cleared["matched"]?.intValue == 0)
    }

    @Test func offlineRefusesProcessActionsButEditsDefinitions() throws {
        let model = AppModel(paths: AppPaths(root: makeTempDirectory()), runner: FakeRunner(), loginItem: FakeLoginItem())
        model.loadDefinitionsOnly()
        let control = ControlService(model: model, isLive: false)
        _ = try control.handle(op: "add", args: ["name": .string("a"), "command": .string("x")])
        #expect(try control.handle(op: "status", args: ["service": .string("a")])["state"]?.stringValue == "app-not-running")
        #expect(throws: ControlError.self) { try control.handle(op: "start", args: ["service": .string("a")]) }
        // Persisted: a fresh model sees it.
        let again = AppModel(paths: model.paths, runner: FakeRunner(), loginItem: FakeLoginItem())
        again.loadDefinitionsOnly()
        #expect(again.services.map(\.displayName) == ["a"])
    }
}

@Suite @MainActor struct ControlSocketTests {
    @Test func roundTripOverUnixSocket() async throws {
        let (model, _, control) = makeLive()
        _ = try control.handle(op: "add", args: ["name": .string("api"), "command": .string("x")])
        // Short path: sockaddr_un holds ~104 bytes and test temp folders are long.
        let path = "/tmp/cm-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(socketPath: path) { op, args in control.respond(op: op, args: args) }
        try server.start()
        defer { server.stop() }
        #expect(throws: SocketError.self) { try ControlServer(socketPath: path) { _, _ in .null }.start() }

        let list = try await Task.detached {
            try ControlClient.send(socketPath: path, op: "list", args: [:], timeout: 5)
        }.value
        #expect(list["appRunning"]?.boolValue == true)
        guard case .array(let items)? = list["services"] else { Issue.record("no services"); return }
        #expect(items.first?["name"]?.stringValue == "api")

        let failure = await Task.detached { () -> String in
            do { _ = try ControlClient.send(socketPath: path, op: "status", args: ["service": .string("zzz")], timeout: 5); return "" }
            catch { return error.localizedDescription }
        }.value
        #expect(failure.contains("No command matches"))

        let added = try await Task.detached {
            try ControlClient.send(socketPath: path, op: "add", args: ["name": .string("web"), "command": .string("y")], timeout: 5)
        }.value
        #expect(added["name"]?.stringValue == "web")
        #expect(model.services.count == 2)
    }

    @Test func clientReportsUnavailableWhenNothingListens() {
        do {
            _ = try ControlClient.send(socketPath: "/tmp/cm-missing-\(UUID().uuidString.prefix(6)).sock", op: "list", args: [:])
            Issue.record("expected failure")
        } catch {
            #expect(ControlClient.isUnavailable(error))
        }
    }

    @Test func backendFallsBackToFilesWhenAppIsClosed() throws {
        let root = URL(fileURLWithPath: "/tmp/cm-off-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ControlBackend(paths: AppPaths(root: root), timeout: 2)
        _ = try backend.call("add", ["name": .string("api"), "command": .string("x")])
        let list = try backend.call("list")
        #expect(list["appRunning"]?.boolValue == false)
        #expect(throws: ControlError.self) { try backend.call("start", ["service": .string("api")]) }
    }
}

@Suite struct MCPServerTests {
    @Test func initializeListAndCall() {
        var calls: [(String, [String: JSONValue])] = []
        let server = MCPServer(version: "t") { op, args in
            calls.append((op, args))
            if op == "status" { throw ControlError("No command matches") }
            return .string("snapshot")
        }
        let initialize = server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .from(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-06-18")]),
        ]))
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(server.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])) == nil)

        let list = server.handle(.object(["jsonrpc": .string("2.0"), "id": .from(2), "method": .string("tools/list")]))
        guard case .array(let tools)? = list?["result"]?["tools"] else { Issue.record("no tools"); return }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names.contains("read_logs") && names.contains("delete_service") && names.contains("create_service"))
        #expect(Set(MCPServer.tools.map(\.op)) == Set(ControlOp.allCases))

        let ok = server.handle(.object(["jsonrpc": .string("2.0"), "id": .from(3), "method": .string("tools/call"),
                                        "params": .object(["name": .string("get_context"), "arguments": .object([:])])]))
        #expect(ok?["result"]?["isError"]?.boolValue == false)
        if case .array(let content)? = ok?["result"]?["content"] { #expect(content.first?["text"]?.stringValue == "snapshot") }
        #expect(calls.first?.0 == "context")

        let failed = server.handle(.object(["jsonrpc": .string("2.0"), "id": .from(4), "method": .string("tools/call"),
                                            "params": .object(["name": .string("service_status"),
                                                               "arguments": .object(["service": .string("x")])])]))
        #expect(failed?["result"]?["isError"]?.boolValue == true)

        let unknown = server.handle(.object(["jsonrpc": .string("2.0"), "id": .from(5), "method": .string("nope")]))
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
    }
}

@Suite struct CLIInstallerTests {
    private func fakeBinary(_ root: URL) throws -> String {
        let app = root.appendingPathComponent("App.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let bin = app.appendingPathComponent("cmgr").path
        FileManager.default.createFile(atPath: bin, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return bin
    }

    @Test func linksIntoFolderOnPathAndIsIdempotent() throws {
        let home = makeTempDirectory()
        let bin = try fakeBinary(home)
        let local = home.appendingPathComponent(".local/bin").path
        try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        let path = "/nonexistent:\(local)"
        #expect(CLIInstaller.install(binary: bin, pathEnvironment: path, home: home.path) == .installed(local + "/cmgr"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local + "/cmgr") == bin)
        #expect(CLIInstaller.install(binary: bin, pathEnvironment: path, home: home.path) == .unchanged(local + "/cmgr"))
    }

    @Test func repointsStaleLinkButNeverOverwritesARealFile() throws {
        let home = makeTempDirectory()
        let bin = try fakeBinary(home)
        let homeBin = home.appendingPathComponent("bin").path
        let local = home.appendingPathComponent(".local/bin").path
        for dir in [homeBin, local] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        // ~/.local/bin has a user's own cmgr file: left alone, ~/bin is used instead.
        FileManager.default.createFile(atPath: local + "/cmgr", contents: Data("mine".utf8))
        try FileManager.default.createSymbolicLink(atPath: homeBin + "/cmgr", withDestinationPath: "/old/App.app/cmgr")
        let outcome = CLIInstaller.install(binary: bin, pathEnvironment: "\(local):\(homeBin)", home: home.path)
        #expect(outcome == .installed(homeBin + "/cmgr"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: homeBin + "/cmgr") == bin)
        #expect(try String(contentsOfFile: local + "/cmgr", encoding: .utf8) == "mine")
    }

    @Test func fallsBackToLocalBinWhenNothingOnPathIsWritable() throws {
        let home = makeTempDirectory()
        let bin = try fakeBinary(home)
        let outcome = CLIInstaller.install(binary: bin, pathEnvironment: "/usr/bin:/bin", home: home.path)
        #expect(outcome == .notOnPath(home.path + "/.local/bin/cmgr"))
        #expect(CLIInstaller.install(binary: home.path + "/missing", pathEnvironment: nil, home: home.path)
                    == .failed("cmgr is missing from the app bundle (\(home.path)/missing)."))
    }
}

@Suite struct LaunchInferenceTests {
    private func write(_ url: URL, _ text: String = "", executable: Bool = false) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: executable ? 0o755 : 0o644])
    }

    @Test func executableScriptRunsDirectlyFromItsFolder() throws {
        let dir = makeTempDirectory()
        let file = dir.appendingPathComponent("run server.sh")
        write(file, "#!/bin/sh\necho hi\n", executable: true)
        let draft = try #require(LaunchInference.draft(for: file))
        #expect(draft.displayName == "run server")
        #expect(draft.command == "'./run server.sh'")
        #expect(draft.workingDirectory == dir.standardizedFileURL.path)
        #expect(ServiceValidator.validate(draft, existing: []).isEmpty)
    }

    @Test func nonExecutableFilesUseTheirInterpreter() {
        #expect(LaunchInference.fileCommand("a.py", ext: "py", executable: false) == "python3 ./a.py")
        #expect(LaunchInference.fileCommand("a.sh", ext: "sh", executable: false) == "bash ./a.sh")
        #expect(LaunchInference.fileCommand("a.js", ext: "js", executable: false) == "node ./a.js")
        #expect(LaunchInference.fileCommand("a.jar", ext: "jar", executable: true) == "java -jar ./a.jar")
        #expect(LaunchInference.fileCommand("server", ext: "", executable: true) == "./server")
        #expect(LaunchInference.quote("it's") == #"'it'\''s'"#)
    }

    @Test func projectFolderOrMarkerFileGuessesDevCommand() throws {
        let dir = makeTempDirectory().appendingPathComponent("web")
        write(dir.appendingPathComponent("package.json"), #"{"scripts":{"build":"x","dev":"vite"}}"#)
        write(dir.appendingPathComponent("pnpm-lock.yaml"))
        let fromFolder = try #require(LaunchInference.draft(for: dir))
        #expect(fromFolder.command == "pnpm run dev")
        #expect(fromFolder.displayName == "web")
        let fromMarker = try #require(LaunchInference.draft(for: dir.appendingPathComponent("package.json")))
        #expect(fromMarker.command == "pnpm run dev")
        #expect(fromMarker.workingDirectory == dir.standardizedFileURL.path)
    }

    @Test func appBundleRunsItsExecutableAndNamesAreUnique() throws {
        let app = makeTempDirectory().appendingPathComponent("Tool.app")
        write(app.appendingPathComponent("Contents/MacOS/ToolBin"), "", executable: true)
        try (["CFBundleExecutable": "ToolBin"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let existing = [ServiceDefinition(displayName: "Tool", command: "x")]
        let draft = try #require(LaunchInference.draft(for: app, existing: existing))
        #expect(draft.command.hasSuffix("Tool.app/Contents/MacOS/ToolBin"))
        #expect(draft.displayName == "Tool 2")
        #expect(LaunchInference.draft(for: app.appendingPathComponent("missing")) == nil)
    }

    @Test @MainActor func controlAddFromFile() throws {
        let dir = makeTempDirectory()
        let file = dir.appendingPathComponent("worker.py")
        write(file, "print(1)")
        let model = AppModel(paths: AppPaths(root: makeTempDirectory()), runner: FakeRunner(), loginItem: FakeLoginItem())
        model.loadDefinitionsOnly()
        let control = ControlService(model: model, isLive: false)
        let added = try control.handle(op: "add", args: ["file": .string(file.path), "restartOnExit": .bool(true)])
        #expect(added["name"]?.stringValue == "worker")
        #expect(added["command"]?.stringValue == "python3 ./worker.py")
        #expect(added["restartOnExit"]?.boolValue == true)
        let renamed = try control.handle(op: "add", args: ["file": .string(file.path), "name": .string("w2")])
        #expect(renamed["name"]?.stringValue == "w2")
        #expect(throws: ControlError.self) { try control.handle(op: "add", args: ["file": .string(dir.appendingPathComponent("nope").path)]) }
        #expect(throws: ControlError.self) { try control.handle(op: "add", args: ["file": .string(makeTempDirectory().path)]) }
    }
}

@Suite @MainActor struct ReorderTests {
    @Test func moveReordersClampsAndPersists() throws {
        let (model, _, control) = makeLive()
        for n in ["a", "b", "c", "d"] { _ = try control.handle(op: "add", args: ["name": .string(n), "command": .string("x")]) }
        func names(_ m: AppModel) -> [String] { m.orderedServices.map(\.displayName) }
        func id(_ n: String) -> UUID { model.services.first { $0.displayName == n }!.id }

        try model.move(id("d"), to: 0)
        #expect(names(model) == ["d", "a", "b", "c"])
        try model.move(id("d"), to: 99) // clamps to bottom
        #expect(names(model) == ["a", "b", "c", "d"])

        let result = try control.handle(op: "move", args: ["service": .string("c"), "position": .from(1)])
        #expect(result["order"] == .array(["c", "a", "b", "d"].map { .string($0) }))
        #expect(throws: ControlError.self) { try control.handle(op: "move", args: ["service": .string("c")]) }

        let reloaded = AppModel(paths: model.paths, runner: FakeRunner(), loginItem: FakeLoginItem())
        reloaded.loadDefinitionsOnly()
        #expect(names(reloaded) == ["c", "a", "b", "d"])
    }
}

@Suite @MainActor struct GroupTests {
    private func names(_ model: AppModel) -> [String] {
        model.rows.map { row in
            switch row {
            case .group(let g, let m): return "[\(g.name): \(m.map(\.displayName).joined(separator: ","))]"
            case .service(let s): return s.displayName
            }
        }
    }

    @Test func createPlaceMoveUngroupAndPersist() throws {
        let (model, _, control) = makeLive()
        for n in ["a", "b", "c", "d"] { _ = try control.handle(op: "add", args: ["name": .string(n), "command": .string("x")]) }
        let g = try model.createGroup(named: "web", with: [model.services[1].id, model.services[2].id])
        #expect(names(model) == ["a", "[web: b,c]", "d"])
        #expect(model.group(g.id)?.isCollapsed == false)

        try model.place(model.services.first { $0.displayName == "d" }!.id, inGroup: g.id, at: 0) // into, first
        #expect(names(model) == ["a", "[web: d,b,c]"])
        try model.move(model.services.first { $0.displayName == "c" }!.id, to: 0) // sort inside group
        #expect(names(model) == ["a", "[web: c,d,b]"])
        try model.place(model.services.first { $0.displayName == "b" }!.id, inGroup: nil, at: 0) // drag out
        #expect(names(model) == ["b", "a", "[web: c,d]"])
        try model.moveGroup(g.id, to: 0)
        #expect(names(model) == ["[web: c,d]", "b", "a"])
        try model.setGroupCollapsed(g.id, true)
        try model.renameGroup(g.id, to: "frontend")

        let reloaded = AppModel(paths: model.paths, runner: FakeRunner(), loginItem: FakeLoginItem())
        reloaded.loadDefinitionsOnly()
        #expect(names(reloaded) == ["[frontend: c,d]", "b", "a"])
        #expect(reloaded.layout.groups.first?.isCollapsed == true)

        try model.ungroup(g.id)
        #expect(names(model) == ["c", "d", "b", "a"])
        #expect(model.services.allSatisfy { $0.groupID == nil })
    }

    @Test func normalizeRepairsInconsistentLayout() {
        let g = ServiceGroup(name: "g")
        var services = [ServiceDefinition(displayName: "a", command: "x", groupID: UUID()), // unknown group
                        ServiceDefinition(displayName: "b", command: "x", groupID: g.id),
                        ServiceDefinition(displayName: "c", command: "x")]
        var layout = ListLayout(groups: [g, g], order: [.service(services[1].id), .service(UUID()), .service(services[2].id)])
        layout.normalize(services: &services)
        #expect(services[0].groupID == nil)
        #expect(layout.groups.count == 1)
        #expect(layout.order == [.service(services[2].id), .group(g.id), .service(services[0].id)])
    }

    @Test func controlGroupOpsAndDeleteRemovesFromOrder() async throws {
        let (model, runner, control) = makeLive()
        _ = try control.handle(op: "add", args: ["name": .string("api"), "command": .string("x"), "group": .string("backend")])
        _ = try control.handle(op: "add", args: ["name": .string("db"), "command": .string("y"), "group": .string("back")])
        _ = try control.handle(op: "add", args: ["name": .string("web"), "command": .string("z")])
        #expect(names(model) == ["[backend: api,db]", "web"])
        #expect(try control.handle(op: "status", args: ["service": .string("db")])["group"]?.stringValue == "backend")

        let started = try control.handle(op: "group_start", args: ["group": .string("backend")])
        #expect(started["started"]?.intValue == 2)
        #expect(await waitUntil { runner.specs.count == 2 })

        _ = try control.handle(op: "group_set", args: ["service": .string("web"), "group": .string("backend"), "position": .from(1)])
        #expect(names(model) == ["[backend: web,api,db]"])
        _ = try control.handle(op: "update", args: ["service": .string("web"), "group": .string("")])
        #expect(names(model) == ["[backend: api,db]", "web"])
        _ = try control.handle(op: "group_rename", args: ["group": .string("backend"), "newName": .string("svc")])
        _ = try control.handle(op: "group_move", args: ["group": .string("svc"), "position": .from(2)])
        #expect(names(model) == ["web", "[svc: api,db]"])
        _ = try control.handle(op: "delete", args: ["service": .string("web")])
        #expect(model.layout.order.count == 1)
        _ = try control.handle(op: "group_delete", args: ["group": .string("svc")])
        #expect(names(model) == ["api", "db"])
        #expect(throws: ControlError.self) { try control.handle(op: "group_start", args: ["group": .string("svc")]) }
    }
}
