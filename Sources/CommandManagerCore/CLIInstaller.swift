import Foundation

/// Makes the `cmgr` binary shipped inside the app bundle reachable from the terminal by
/// symlinking it into a folder on the user's PATH. Runs on every app launch, so moving the app
/// just re-points the link. Never overwrites a regular file it did not create.
public enum CLIInstaller {
    public enum Outcome: Equatable, Sendable {
        /// Link created or re-pointed.
        case installed(String)
        /// Link already pointed at this binary.
        case unchanged(String)
        /// Linked into ~/.local/bin, which is not on PATH yet.
        case notOnPath(String)
        case failed(String)
    }

    public static let linkName = "cmgr"

    /// Folders tried in order, but only those on the login-shell PATH (except the last-resort fallback).
    public static func candidates(home: String) -> [String] {
        ["/usr/local/bin", "/opt/homebrew/bin", home + "/.local/bin", home + "/bin"]
    }

    public static func install(
        binary: String,
        pathEnvironment: String?,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) -> Outcome {
        guard fm.isExecutableFile(atPath: binary) else { return .failed("cmgr is missing from the app bundle (\(binary)).") }
        let pathDirs = (pathEnvironment ?? "").split(separator: ":").map { normalize(String($0)) }
        let onPath = candidates(home: home).filter { pathDirs.contains(normalize($0)) }

        // Already linked somewhere on PATH?
        for dir in onPath {
            let link = dir + "/" + linkName
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link), normalize(dest) == normalize(binary) {
                return .unchanged(link)
            }
        }
        for dir in onPath {
            if let link = link(binary, in: dir, fm: fm) { return .installed(link) }
        }
        let fallback = home + "/.local/bin"
        try? fm.createDirectory(atPath: fallback, withIntermediateDirectories: true)
        if let link = link(binary, in: fallback, fm: fm) {
            return pathDirs.contains(normalize(fallback)) ? .installed(link) : .notOnPath(link)
        }
        return .failed("No writable folder for the cmgr link (tried \(candidates(home: home).joined(separator: ", "))).")
    }

    /// Creates `dir/cmgr` → binary. Replaces only an existing symlink (stale or another copy of the app).
    private static func link(_ binary: String, in dir: String, fm: FileManager) -> String? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir) else { return nil }
        let link = dir + "/" + linkName
        if let attrs = try? fm.attributesOfItem(atPath: link) {
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return nil }
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link), normalize(dest) == normalize(binary) { return link }
            guard (try? fm.removeItem(atPath: link)) != nil else { return nil }
        } else if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            // Dangling symlink (attributesOfItem follows links and fails).
            guard (try? fm.removeItem(atPath: link)) != nil else { return nil }
        }
        return (try? fm.createSymbolicLink(atPath: link, withDestinationPath: binary)) != nil ? link : nil
    }

    private static func normalize(_ path: String) -> String {
        let p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}
