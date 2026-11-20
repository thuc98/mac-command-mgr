import Foundation

/// Turns a dropped file or folder into a prefilled command: working folder = where it lives,
/// command = how to run it, name = its name. The result is a draft the user reviews before saving.
public enum LaunchInference {
    /// Files that stand for "run this project" rather than "run this file".
    static let projectMarkers: Set<String> = [
        "package.json", "Cargo.toml", "go.mod", "manage.py", "docker-compose.yml", "docker-compose.yaml",
        "compose.yml", "compose.yaml", "Makefile",
    ]

    public static func draft(for url: URL, existing: [ServiceDefinition] = [], fileManager fm: FileManager = .default) -> ServiceDraft? {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        let name: String
        let folder: URL
        let command: String
        if isDir.boolValue, url.pathExtension.lowercased() == "app" {
            // Run the bundle's executable directly so Stop really stops the app.
            folder = url.deletingLastPathComponent()
            name = url.deletingPathExtension().lastPathComponent
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let exe = (info?["CFBundleExecutable"] as? String) ?? name
            command = quote(url.appendingPathComponent("Contents/MacOS").appendingPathComponent(exe).path)
        } else if isDir.boolValue {
            folder = url
            name = url.lastPathComponent
            command = projectCommand(in: url, fm: fm) ?? ""
        } else if projectMarkers.contains(url.lastPathComponent), let project = projectCommand(in: url.deletingLastPathComponent(), fm: fm) {
            folder = url.deletingLastPathComponent()
            name = folder.lastPathComponent
            command = project
        } else {
            folder = url.deletingLastPathComponent()
            let file = url.lastPathComponent
            name = url.pathExtension.isEmpty ? file : url.deletingPathExtension().lastPathComponent
            command = fileCommand(file, ext: url.pathExtension.lowercased(), executable: fm.isExecutableFile(atPath: url.path))
        }
        return ServiceDraft(displayName: uniqueName(name.isEmpty ? "command" : name, existing: existing),
                            command: command, workingDirectory: folder.path)
    }

    /// How to run a single file sitting in the working folder.
    static func fileCommand(_ file: String, ext: String, executable: Bool) -> String {
        let local = quote("./" + file)
        if executable, ext != "jar" { return local } // honours its shebang
        switch ext {
        case "sh", "bash": return "bash \(local)"
        case "zsh", "command", "tool": return "zsh \(local)"
        case "py": return "python3 \(local)"
        case "js", "mjs", "cjs": return "node \(local)"
        case "ts", "mts": return "npx tsx \(local)"
        case "rb": return "ruby \(local)"
        case "php": return "php \(local)"
        case "pl": return "perl \(local)"
        case "jar": return "java -jar \(local)"
        case "go": return "go run \(local)"
        case "swift": return "swift \(local)"
        default: return local
        }
    }

    /// Typical "start the dev server" command for a project folder, if one is recognisable.
    static func projectCommand(in folder: URL, fm: FileManager) -> String? {
        func has(_ file: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(file).path) }
        if has("package.json") {
            let runner = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
            var scripts: [String: Any] = [:]
            if let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scripts = json["scripts"] as? [String: Any] ?? [:]
            }
            for script in ["dev", "start", "serve"] where scripts[script] != nil {
                return runner == "npm" && script == "start" ? "npm start" : "\(runner) run \(script)"
            }
            return "\(runner) start"
        }
        if has("docker-compose.yml") || has("docker-compose.yaml") || has("compose.yml") || has("compose.yaml") {
            return "docker compose up"
        }
        if has("Cargo.toml") { return "cargo run" }
        if has("go.mod") { return "go run ." }
        if has("manage.py") { return "python3 manage.py runserver" }
        if has("Makefile") { return "make" }
        return nil
    }

    static func uniqueName(_ base: String, existing: [ServiceDefinition]) -> String {
        let taken = Set(existing.map { $0.displayName.trimmingCharacters(in: .whitespaces).lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Single-quotes for zsh when the word has anything beyond safe characters.
    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-@%:,=")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
