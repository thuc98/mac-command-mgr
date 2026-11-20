import Foundation
import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// macOS needs the user to approve the item in System Settings › Login Items.
    case requiresApproval
    /// Registration is impossible here (e.g. running outside an .app bundle).
    case unavailable(String)

    public var label: String {
        switch self {
        case .enabled: return "Opens at login"
        case .disabled: return "Does not open at login"
        case .requiresApproval: return "Needs approval in System Settings › Login Items"
        case .unavailable(let reason): return "Open at login unavailable: \(reason)"
        }
    }
}

/// App-level "open at login". Individual commands are never registered with launchd.
public protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

public enum LoginItemFactory {
    public static func make(bundle: Bundle = .main) -> LoginItemManaging {
        guard bundle.bundleURL.pathExtension == "app", let bundleID = bundle.bundleIdentifier else {
            return UnavailableLoginItem(reason: "run the packaged CommandManager.app")
        }
        if #available(macOS 13.0, *) {
            return AppServiceLoginItem()
        }
        return LaunchAgentLoginItem(
            bundleIdentifier: bundleID,
            appPath: bundle.bundlePath,
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
        )
    }
}

public final class UnavailableLoginItem: LoginItemManaging {
    private let reason: String
    public init(reason: String) { self.reason = reason }
    public var status: LoginItemStatus { .unavailable(reason) }
    public func setEnabled(_ enabled: Bool) throws {
        throw LoginItemError.unavailable(reason)
    }
}

public enum LoginItemError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Open at login is unavailable: \(reason)."
        case .failed(let reason): return "Could not change Open at login: \(reason)"
        }
    }
}

/// macOS 13+: `SMAppService.mainApp`.
@available(macOS 13.0, *)
public final class AppServiceLoginItem: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // macOS can report .notFound before the first registration.
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
    }
}

/// macOS 12 fallback: a single per-user LaunchAgent that opens the app at login.
/// It launches only the app itself; commands are still started by the app.
public final class LaunchAgentLoginItem: LoginItemManaging {
    private let plistURL: URL
    private let appPath: String
    private let label: String

    public init(bundleIdentifier: String, appPath: String, launchAgentsDirectory: URL) {
        self.label = "\(bundleIdentifier).login"
        self.appPath = appPath
        self.plistURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    public var status: LoginItemStatus {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], args.contains(appPath) else {
            return .disabled
        }
        return .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath],
                    "RunAtLoad": true,
                    "LimitLoadToSessionType": "Aqua",
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
    }
}
