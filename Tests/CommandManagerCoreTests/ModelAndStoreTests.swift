import Foundation
import Testing
@testable import CommandManagerCore

@Suite struct ValidationTests {
    @Test func requiresNameAndCommand() {
        let issues = ServiceValidator.validate(ServiceDraft(), existing: [])
        #expect(issues.map(\.field) == [.displayName, .command])
    }

    @Test func rejectsDuplicateNameCaseInsensitiveButAllowsSelfWhenEditing() {
        let existing = ServiceDefinition(displayName: "API", command: "x")
        let draft = ServiceDraft(displayName: " api ", command: "y")
        #expect(ServiceValidator.validate(draft, existing: [existing]).map(\.field) == [.displayName])
        #expect(ServiceValidator.validate(draft, existing: [existing], editingID: existing.id).isEmpty)
    }

    @Test func workingDirectoryMustExistAndBeAFolder() throws {
        let dir = makeTempDirectory()
        let file = dir.appendingPathComponent("f.txt")
        try Data().write(to: file)
        func issues(_ path: String) -> [ValidationField] {
            ServiceValidator.validate(ServiceDraft(displayName: "a", command: "b", workingDirectory: path), existing: []).map(\.field)
        }
        #expect(issues(dir.path).isEmpty)
        #expect(issues("").isEmpty)
        #expect(issues(dir.appendingPathComponent("missing").path) == [.workingDirectory])
        #expect(issues(file.path) == [.workingDirectory])
        #expect(issues("relative/path") == [.workingDirectory])
    }

    @Test func normalizesDirectoryWithoutResolvingSymlinks() {
        #expect(ServiceValidator.normalizedDirectory("  ") == nil)
        #expect(ServiceValidator.normalizedDirectory("~/a/../b/") == NSHomeDirectory() + "/b")
    }

    @Test func parsesEnvironment() throws {
        let env = try ServiceValidator.parseEnvironment("# comment\nPORT=3000\n\nURL=http://x?a=b\n").get()
        #expect(env == ["PORT": "3000", "URL": "http://x?a=b"])
        #expect((try? ServiceValidator.parseEnvironment("1BAD=x").get()) == nil)
        #expect((try? ServiceValidator.parseEnvironment("NOEQUALS").get()) == nil)
        #expect((try? ServiceValidator.parseEnvironment("A=1\nA=2").get()) == nil)
    }

    @Test func makeDefinitionKeepsIdentityWhenEditing() throws {
        let original = ServiceDefinition(displayName: "a", command: "b")
        let edited = try ServiceValidator.makeDefinition(
            from: ServiceDraft(displayName: "a2", command: "c", autoStart: true),
            existing: [original], editing: original
        ).get()
        #expect(edited.id == original.id)
        #expect(edited.createdAt == original.createdAt)
        #expect(edited.autoStartMode == .atAppLaunch)
        #expect(edited.shouldAutoStart)
    }

    @Test func shouldAutoStartNeedsEnabledAndAutoStart() {
        var d = ServiceDefinition(displayName: "a", command: "b", isEnabled: false, autoStartMode: .atAppLaunch)
        #expect(!d.shouldAutoStart)
        d.isEnabled = true
        #expect(d.shouldAutoStart)
        d.autoStart = false
        #expect(!d.shouldAutoStart)
    }
}

@Suite struct ServiceStoreTests {
    @Test func missingFileLoadsEmpty() {
        let store = ServiceStore(fileURL: makeTempDirectory().appendingPathComponent("services.json"))
        let result = store.load()
        #expect(result.services.isEmpty)
        #expect(result.error == nil)
    }

    @Test func roundTripsDefinitions() throws {
        let url = makeTempDirectory().appendingPathComponent("nested/services.json")
        let d = ServiceDefinition(displayName: "API", command: "npm start", workingDirectory: "/tmp",
                                  environment: ["PORT": "1"], autoStartMode: .atAppLaunch)
        try ServiceStore(fileURL: url).save([d])
        let loaded = ServiceStore(fileURL: url).load()
        #expect(loaded.error == nil)
        #expect(loaded.services.count == 1)
        #expect(loaded.services[0].id == d.id)
        #expect(loaded.services[0].environment == ["PORT": "1"])
        #expect(loaded.services[0].autoStartMode == .atAppLaunch)
    }

    @Test func corruptFileIsMovedAsideNotLost() throws {
        let dir = makeTempDirectory()
        let url = dir.appendingPathComponent("services.json")
        try Data("{not json".utf8).write(to: url)
        let result = ServiceStore(fileURL: url).load()
        #expect(result.services.isEmpty)
        guard case .corrupted(let backup) = result.error else { Issue.record("expected corrupted"); return }
        #expect(FileManager.default.fileExists(atPath: backup))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func migratesLegacyBareArray() throws {
        let url = makeTempDirectory().appendingPathComponent("services.json")
        var legacy = ServiceDefinition(displayName: "old", command: "x")
        legacy.schemaVersion = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: url)
        let result = ServiceStore(fileURL: url).load()
        #expect(result.error == nil)
        #expect(result.services.map(\.displayName) == ["old"])
        #expect(result.services[0].schemaVersion == ServiceDefinition.currentSchemaVersion)
    }

    @Test func corruptFileThatCannotBeMovedIsLeftUntouchedAndNotOverwritten() throws {
        let dir = makeTempDirectory()
        let url = dir.appendingPathComponent("services.json")
        let original = Data("{not json".utf8)
        try original.write(to: url)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let store = ServiceStore(fileURL: url)
        #expect(store.load().error == .unreadable(path: url.path))
        #expect(store.isReadOnly)
        #expect(throws: ServiceStoreError.readOnly) { try store.save([]) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func newerVersionIsReadOnlyAndNotOverwritten() throws {
        let url = makeTempDirectory().appendingPathComponent("services.json")
        let original = Data(#"{"schemaVersion": 99, "services": []}"#.utf8)
        try original.write(to: url)
        let store = ServiceStore(fileURL: url)
        #expect(store.load().error == .unsupportedVersion(99))
        #expect(throws: ServiceStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: url) == original)
    }
}

@Suite struct LogStoreTests {
    @Test func clearDeletesCurrentAndRotatedFilesAndKeepsLoggingAfter() {
        let store = LogStore(directory: makeTempDirectory(), maxBytesPerFile: 64, maxFiles: 3)
        let id = UUID()
        for i in 0..<10 { store.append(Data("line \(i) padding padding\n".utf8), source: .stdout, serviceID: id) }
        store.append(Data("partial".utf8), source: .stdout, serviceID: id)
        store.sync()
        #expect(FileManager.default.fileExists(atPath: store.logFileURL(for: id).path + ".1"))
        store.clear(serviceID: id)
        #expect(store.tail(serviceID: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.logFileURL(for: id).path + ".1"))
        store.append(Data("after\n".utf8), source: .stdout, serviceID: id)
        #expect(store.tail(serviceID: id).map(\.text) == ["after"])
    }

    @Test func lineMatchesQueryCaseAndDiacriticInsensitive() {
        let line = LogLine(id: 0, timestamp: "", source: .stdout, text: "Server started on PORT 8080 — Kết nối")
        #expect(line.matches(""))
        #expect(line.matches("  "))
        #expect(line.matches("port 80"))
        #expect(line.matches("ket noi"))
        #expect(!line.matches("error"))
    }

    @Test func tagsSourcesAndKeepsReceiptOrder() {
        let store = LogStore(directory: makeTempDirectory())
        let id = UUID()
        store.append(Data("out1\n".utf8), source: .stdout, serviceID: id)
        store.append(Data("err1\n".utf8), source: .stderr, serviceID: id)
        store.append(Data("out".utf8), source: .stdout, serviceID: id)
        store.append(Data("2\n".utf8), source: .stdout, serviceID: id)
        store.appendEvent("done", serviceID: id)
        let lines = store.tail(serviceID: id)
        #expect(lines.map(\.text) == ["out1", "err1", "out2", "done"])
        #expect(lines.map(\.source) == [.stdout, .stderr, .stdout, .system])
        #expect(!lines[0].timestamp.isEmpty)
    }

    @Test func flushWritesPartialLine() {
        let store = LogStore(directory: makeTempDirectory())
        let id = UUID()
        store.append(Data("no newline".utf8), source: .stderr, serviceID: id)
        store.flush(serviceID: id)
        #expect(store.tail(serviceID: id).map(\.text) == ["no newline"])
    }

    @Test func carriageReturnsEndLinesAndLongLinesAreCapped() {
        let store = LogStore(directory: makeTempDirectory())
        let id = UUID()
        store.append(Data("10%\r50%\r100%\r\ndone\r\n".utf8), source: .stdout, serviceID: id)
        let big = Data(repeating: UInt8(ascii: "x"), count: LogStore.maxPartialLineBytes + 10)
        store.append(big, source: .stderr, serviceID: id)
        let lines = store.tail(serviceID: id, maxBytes: 1024 * 1024)
        #expect(Array(lines.prefix(4)).map(\.text) == ["10%", "50%", "100%", "done"])
        // The capped chunk is written without waiting for a newline; the 10-byte rest stays buffered.
        #expect(lines.count == 5)
        #expect(lines[4].text.count == LogStore.maxPartialLineBytes)
    }

    @Test func crlfSplitAcrossReadsIsOneLineBreak() {
        let store = LogStore(directory: makeTempDirectory())
        let id = UUID()
        store.append(Data("first\r".utf8), source: .stdout, serviceID: id)
        store.append(Data("\nsecond\n".utf8), source: .stdout, serviceID: id)
        #expect(store.tail(serviceID: id).map(\.text) == ["first", "second"])
    }

    @Test func cappedLineDoesNotSplitMultiByteCharacter() {
        let store = LogStore(directory: makeTempDirectory())
        let id = UUID()
        // "é" is 2 bytes; an odd-length ASCII prefix puts a character across the cap boundary.
        let text = String(repeating: "a", count: 1) + String(repeating: "é", count: LogStore.maxPartialLineBytes / 2 + 4)
        store.append(Data(text.utf8), source: .stdout, serviceID: id)
        store.flush(serviceID: id)
        let lines = store.tail(serviceID: id, maxBytes: 1024 * 1024)
        #expect(lines.count == 2)
        #expect(!lines.contains { $0.text.contains("\u{FFFD}") })
        #expect(lines.map(\.text).joined() == text)
    }

    @Test func unwritableLogDoesNotCrashOrAffectOtherServices() throws {
        let dir = makeTempDirectory()
        let store = LogStore(directory: dir)
        let broken = UUID(), healthy = UUID()
        // A directory where the log file should be makes every open/write fail.
        try FileManager.default.createDirectory(at: store.logFileURL(for: broken), withIntermediateDirectories: true)
        store.append(Data("lost\n".utf8), source: .stdout, serviceID: broken)
        store.appendEvent("also lost", serviceID: broken)
        store.append(Data("kept\n".utf8), source: .stdout, serviceID: healthy)
        store.sync()
        #expect(store.tail(serviceID: broken).isEmpty)
        #expect(store.tail(serviceID: healthy).map(\.text) == ["kept"])
    }

    @Test func tailContinuesIntoRotatedFile() {
        let store = LogStore(directory: makeTempDirectory(), maxBytesPerFile: 300, maxFiles: 3)
        let id = UUID()
        for i in 0..<8 { store.append(Data("entry \(i) padded to make it longer\n".utf8), source: .stdout, serviceID: id) }
        let texts = store.tail(serviceID: id).map(\.text)
        #expect(texts.last == "entry 7 padded to make it longer")
        #expect(texts.count > 1)
        #expect(texts == texts.sorted())
    }

    @Test func rotatesAndCapsFileCount() {
        let dir = makeTempDirectory()
        let store = LogStore(directory: dir, maxBytesPerFile: 200, maxFiles: 3)
        let id = UUID()
        for i in 0..<100 {
            store.append(Data("line number \(i) with some padding text\n".utf8), source: .stdout, serviceID: id)
        }
        store.sync()
        let base = store.logFileURL(for: id).path
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: base + ".1"))
        #expect(fm.fileExists(atPath: base + ".2"))
        #expect(!fm.fileExists(atPath: base + ".3"))
        let size = (try? fm.attributesOfItem(atPath: base)[.size] as? UInt64) ?? 0
        #expect(size < 400)
        #expect(store.tail(serviceID: id).last?.text.contains("99") == true)
    }
}

@Suite struct LoginItemTests {
    @Test func launchAgentAdapterWritesAndRemovesAppLevelPlist() throws {
        let dir = makeTempDirectory()
        let item = LaunchAgentLoginItem(bundleIdentifier: "com.example.cm", appPath: "/Applications/CM.app", launchAgentsDirectory: dir)
        #expect(item.status == .disabled)
        try item.setEnabled(true)
        #expect(item.status == .enabled)
        let plist = dir.appendingPathComponent("com.example.cm.login.plist")
        let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        #expect(dict?["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-a", "/Applications/CM.app"])
        try item.setEnabled(false)
        #expect(item.status == .disabled)
    }

    @Test func unavailableAdapterRefusesToEnable() {
        let item = UnavailableLoginItem(reason: "no bundle")
        #expect(throws: LoginItemError.self) { try item.setEnabled(true) }
        #expect(item.status == .unavailable("no bundle"))
    }
}

@Suite struct ProcessIdentityTests {
    @Test func identifiesLiveProcessByPIDAndStartTime() throws {
        let me = try #require(ProcessIdentity.current(pid: getpid()))
        #expect(me.startTime > 0)
        #expect(ProcessIdentity.isSameProcessAlive(me))
        #expect(!ProcessIdentity.isSameProcessAlive(ProcessIdentity(pid: me.pid, startTime: me.startTime + 1)))
        #expect(ProcessIdentity.current(pid: -1) == nil)
    }
}

@Suite struct LaunchSpecTests {
    @Test func runsThroughZshWithExplicitPathAndOverrides() {
        let d = ServiceDefinition(displayName: "a", command: "echo $FOO | cat", workingDirectory: "/tmp", environment: ["FOO": "bar"])
        let spec = LaunchSpec.make(for: d, baseEnvironment: ["PATH": "/custom/bin:/usr/bin", "FOO": "base"], homeDirectory: "/Users/x")
        #expect(spec.executable == "/bin/zsh")
        #expect(spec.arguments == ["-lc", "echo $FOO | cat"])
        #expect(spec.workingDirectory == "/tmp")
        #expect(spec.environment["FOO"] == "bar")
        // The user's PATH order is kept (their tools win); defaults are appended only when missing.
        #expect(spec.environment["PATH"] == "/custom/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func emptyBaseGetsDefaultPATH() {
        let d = ServiceDefinition(displayName: "a", command: "b")
        #expect(LaunchSpec.make(for: d, baseEnvironment: [:], homeDirectory: "/x").environment["PATH"] == LaunchSpec.defaultPATH)
    }

    @Test func defaultsToHomeDirectory() {
        let d = ServiceDefinition(displayName: "a", command: "b")
        #expect(LaunchSpec.make(for: d, baseEnvironment: [:], homeDirectory: "/Users/x").workingDirectory == "/Users/x")
    }
}

@Suite struct LoginShellEnvironmentTests {
    @Test func parsesOnlyBetweenMarkersAndDropsShellBookkeeping() {
        let m = LoginShellEnvironment.marker
        var data = Data("motd noise \(m)".utf8)
        data.append(Data("PATH=/a:/b\0MULTI=x\ny\0EQ=k=v\0_=/usr/bin/env\0SHLVL=2\0".utf8))
        data.append(Data("\(m) trailing".utf8))
        let env = LoginShellEnvironment.parse(data)
        #expect(env == ["PATH": "/a:/b", "MULTI": "x\ny", "EQ": "k=v"])
    }

    @Test func parseFailsWithoutMarkers() {
        #expect(LoginShellEnvironment.parse(Data("PATH=/a\0".utf8)) == nil)
    }

    @Test func shellValuesOverrideApp() {
        let merged = LoginShellEnvironment.merged(app: ["PATH": "/usr/bin", "APP": "1"], shell: ["PATH": "/go/bin:/usr/bin"])
        #expect(merged == ["PATH": "/go/bin:/usr/bin", "APP": "1"])
        #expect(LoginShellEnvironment.merged(app: ["A": "1"], shell: nil) == ["A": "1"])
    }

    /// Real shell: a variable exported from a login-profile file must be captured.
    @Test func capturesProfileFromRealShell() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "export CM_TEST_VAR=from_profile\nexport PATH=\"$PATH:/cm/test/go/bin\"\necho noise\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        // ZDOTDIR redirects zsh's startup files, so the test never reads the developer's real profile.
        var base = ProcessInfo.processInfo.environment
        base["ZDOTDIR"] = home.path
        let env = try #require(LoginShellEnvironment.capture(shell: "/bin/zsh", environment: base, timeout: 10))
        #expect(env["CM_TEST_VAR"] == "from_profile")
        #expect(env["PATH"]?.hasSuffix(":/cm/test/go/bin") == true)
    }
}
