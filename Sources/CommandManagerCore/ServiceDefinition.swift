import Foundation

/// When the app should start a command on its own.
public enum AutoStartMode: String, Codable, CaseIterable, Sendable {
    /// Only started when the user presses Start.
    case manual
    /// Started automatically every time Command Manager launches (including at login).
    case atAppLaunch
}

/// Persistent definition of a managed command. Runtime state lives in `RuntimeRecord`.
public struct ServiceDefinition: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var displayName: String
    /// Raw shell snippet, executed through `/bin/zsh -lc`.
    public var command: String
    /// Absolute, standardized path, or nil to use the user's home directory.
    public var workingDirectory: String?
    public var environment: [String: String]
    public var isEnabled: Bool
    public var autoStartMode: AutoStartMode
    /// Start again (with exponential backoff) whenever the command exits or crashes on its own.
    public var restartOnExit: Bool
    /// The list group it belongs to, if any.
    public var groupID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        isEnabled: Bool = true,
        autoStartMode: AutoStartMode = .manual,
        restartOnExit: Bool = false,
        groupID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = ServiceDefinition.currentSchemaVersion
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.isEnabled = isEnabled
        self.autoStartMode = autoStartMode
        self.restartOnExit = restartOnExit
        self.groupID = groupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, command, workingDirectory, environment, isEnabled, autoStartMode, restartOnExit, groupID
        case createdAt, updatedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        command = try c.decode(String.self, forKey: .command)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        autoStartMode = try c.decodeIfPresent(AutoStartMode.self, forKey: .autoStartMode) ?? .manual
        // Added after schema 1 shipped: older files simply lack it.
        restartOnExit = try c.decodeIfPresent(Bool.self, forKey: .restartOnExit) ?? false
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ServiceDefinition.currentSchemaVersion
    }

    public var autoStart: Bool {
        get { autoStartMode == .atAppLaunch }
        set { autoStartMode = newValue ? .atAppLaunch : .manual }
    }

    /// True when the app should start this command right after it launches.
    public var shouldAutoStart: Bool { isEnabled && autoStart }
}

/// Editable, unvalidated form input.
public struct ServiceDraft: Equatable, Sendable {
    public var displayName: String
    public var command: String
    public var workingDirectory: String
    /// One `KEY=VALUE` per line. Blank lines and lines starting with `#` are ignored.
    public var environmentText: String
    public var isEnabled: Bool
    public var autoStart: Bool
    public var restartOnExit: Bool
    public var groupID: UUID?

    public init(
        displayName: String = "",
        command: String = "",
        workingDirectory: String = "",
        environmentText: String = "",
        isEnabled: Bool = true,
        autoStart: Bool = false,
        restartOnExit: Bool = false,
        groupID: UUID? = nil
    ) {
        self.displayName = displayName
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentText = environmentText
        self.isEnabled = isEnabled
        self.autoStart = autoStart
        self.restartOnExit = restartOnExit
        self.groupID = groupID
    }

    public init(_ definition: ServiceDefinition) {
        self.init(
            displayName: definition.displayName,
            command: definition.command,
            workingDirectory: definition.workingDirectory ?? "",
            environmentText: definition.environment
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n"),
            isEnabled: definition.isEnabled,
            autoStart: definition.autoStart,
            restartOnExit: definition.restartOnExit,
            groupID: definition.groupID
        )
    }
}

public enum ValidationField: String, Sendable {
    case displayName, command, workingDirectory, environment
}

public struct ValidationIssue: Error, Equatable, Sendable {
    public let field: ValidationField
    public let message: String
}

/// Validates a draft against the rules in the plan (§4) and produces a definition.
public enum ServiceValidator {
    private static let envKeyPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")

    public static func validate(
        _ draft: ServiceDraft,
        existing: [ServiceDefinition],
        editingID: UUID? = nil,
        fileManager: FileManager = .default
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            issues.append(.init(field: .displayName, message: "Name is required."))
        } else if existing.contains(where: {
            $0.id != editingID && $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        }) {
            issues.append(.init(field: .displayName, message: "Another command already uses this name."))
        }

        if draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .command, message: "Command is required."))
        }

        if let path = normalizedDirectory(draft.workingDirectory) {
            var isDirectory: ObjCBool = false
            if !path.hasPrefix("/") {
                issues.append(.init(field: .workingDirectory, message: "Use an absolute path (or start with ~)."))
            } else if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                issues.append(.init(field: .workingDirectory, message: "Folder does not exist: \(path)"))
            } else if !isDirectory.boolValue {
                issues.append(.init(field: .workingDirectory, message: "Path is not a folder: \(path)"))
            }
        }

        switch parseEnvironment(draft.environmentText) {
        case .success: break
        case .failure(let issue): issues.append(issue)
        }
        return issues
    }

    /// Returns a saved definition when the draft is valid.
    public static func makeDefinition(
        from draft: ServiceDraft,
        existing: [ServiceDefinition],
        editing original: ServiceDefinition? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Result<ServiceDefinition, ValidationFailure> {
        let issues = validate(draft, existing: existing, editingID: original?.id, fileManager: fileManager)
        guard issues.isEmpty, case .success(let env) = parseEnvironment(draft.environmentText) else {
            return .failure(ValidationFailure(issues: issues))
        }
        var definition = original ?? ServiceDefinition(displayName: "", command: "", createdAt: now)
        definition.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.workingDirectory = normalizedDirectory(draft.workingDirectory)
        definition.environment = env
        definition.isEnabled = draft.isEnabled
        definition.autoStart = draft.autoStart
        definition.restartOnExit = draft.restartOnExit
        definition.groupID = draft.groupID
        definition.updatedAt = now
        definition.schemaVersion = ServiceDefinition.currentSchemaVersion
        return .success(definition)
    }

    /// Expands `~` and standardizes `.`/`..` without resolving symlinks. Nil for blank input.
    public static func normalizedDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    public static func parseEnvironment(_ text: String) -> Result<[String: String], ValidationIssue> {
        var result: [String: String] = [:]
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                return .failure(.init(field: .environment, message: "Line \(index + 1): expected KEY=VALUE."))
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
            let range = NSRange(key.startIndex..., in: key)
            guard envKeyPattern.firstMatch(in: key, range: range) != nil else {
                return .failure(.init(field: .environment, message: "Line \(index + 1): invalid variable name \"\(key)\"."))
            }
            if result[key] != nil {
                return .failure(.init(field: .environment, message: "Line \(index + 1): \(key) is defined twice."))
            }
            result[key] = value
        }
        return .success(result)
    }
}

public struct ValidationFailure: Error, Equatable, Sendable {
    public let issues: [ValidationIssue]
}
