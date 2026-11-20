import Foundation

public enum ServiceStoreError: Error, Equatable, LocalizedError {
    /// The file was unreadable/corrupt; it was moved aside to `backupPath`.
    case corrupted(backupPath: String)
    /// Written by a newer app version; left untouched and the store is read-only.
    case unsupportedVersion(Int)
    case writeFailed(path: String, reason: String)
    /// The file was unreadable and could not be moved aside; saving is refused to protect it.
    case unreadable(path: String)
    /// Saving refused because the file could not be safely loaded.
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .corrupted(let backup):
            return "The saved commands file was damaged. It was moved to \(backup) and an empty list was started."
        case .unsupportedVersion(let version):
            return "The saved commands file uses a newer format (version \(version)). Update Command Manager; changes will not be saved."
        case .writeFailed(let path, let reason):
            return "Could not save commands to \(path): \(reason)"
        case .unreadable(let path):
            return "The saved commands file at \(path) could not be read. It was left untouched and changes will not be saved until it is fixed or removed."
        case .readOnly:
            return "Changes are not saved because the saved commands file could not be loaded safely."
        }
    }
}

/// Versioned JSON persistence for service definitions with atomic writes.
public final class ServiceStore {
    public static let fileVersion = 1

    private struct FileV1: Codable {
        var schemaVersion: Int
        var services: [ServiceDefinition]
        // Added later in version 1; older files lack them and older apps ignore them.
        var groups: [ServiceGroup]?
        var order: [ListItem]?
    }

    /// Layout read by the last successful `load()`.
    public private(set) var loadedLayout = ListLayout()

    private struct Probe: Decodable { var schemaVersion: Int? }

    public let fileURL: URL
    private let fileManager: FileManager
    /// Set when the on-disk file came from a newer version; saving is refused so it is not clobbered.
    public private(set) var isReadOnly = false

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Loads definitions. Returns `[]` with no error when the file does not exist yet.
    /// On corruption the file is moved aside and `.corrupted` is reported alongside an empty list.
    public func load() -> (services: [ServiceDefinition], error: ServiceStoreError?) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try decodeFile(data)
            loadedLayout = ListLayout(groups: file.groups ?? [], order: file.order ?? [])
            return (file.services, nil)
        } catch let error as ServiceStoreError {
            if case .unsupportedVersion = error { isReadOnly = true }
            return ([], error)
        } catch {
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try fileManager.moveItem(at: fileURL, to: backup)
                return ([], .corrupted(backupPath: backup.path))
            } catch {
                isReadOnly = true
                return ([], .unreadable(path: fileURL.path))
            }
        }
    }

    /// Reads definitions without ever moving or rewriting the file (used by `cmgr` while the app
    /// is not running). A missing file is an empty list.
    public func loadReadOnly() throws -> [ServiceDefinition] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try decodeFile(Data(contentsOf: fileURL)).services
    }

    public func save(_ services: [ServiceDefinition], layout: ListLayout = ListLayout()) throws {
        if isReadOnly { throw ServiceStoreError.readOnly }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(FileV1(schemaVersion: Self.fileVersion, services: services,
                                                 groups: layout.groups, order: layout.order))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ServiceStoreError.writeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    private func decodeFile(_ data: Data) throws -> FileV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Version 0: a bare array of definitions (pre-versioned format).
        if let legacy = try? decoder.decode([ServiceDefinition].self, from: data) {
            return FileV1(schemaVersion: Self.fileVersion,
                          services: legacy.map { var d = $0; d.schemaVersion = ServiceDefinition.currentSchemaVersion; return d })
        }
        let probe = try decoder.decode(Probe.self, from: data)
        let version = probe.schemaVersion ?? 0
        guard version <= Self.fileVersion else { throw ServiceStoreError.unsupportedVersion(version) }
        return try decoder.decode(FileV1.self, from: data)
    }
}
