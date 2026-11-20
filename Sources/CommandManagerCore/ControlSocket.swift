import Foundation

/// Wire format (one JSON object per line, one request per connection):
///   request  {"op": "logs", "args": {"service": "api", "lines": 50}}
///   response {"ok": true, "result": …} | {"ok": false, "error": "…"}
public enum ControlWire {
    public static let maxRequestBytes = 1024 * 1024

    public static func request(op: String, args: [String: JSONValue]) -> JSONValue {
        .object(["op": .string(op), "args": .object(args)])
    }

    public static func success(_ result: JSONValue) -> JSONValue { .object(["ok": .bool(true), "result": result]) }
    public static func failure(_ message: String) -> JSONValue { .object(["ok": .bool(false), "error": .string(message)]) }

    /// Unwraps a response: the result, or a thrown `ControlError`.
    public static func unwrap(_ response: JSONValue) throws -> JSONValue {
        if response["ok"]?.boolValue == true { return response["result"] ?? .null }
        throw ControlError(response["error"]?.stringValue ?? "Unknown error from Command Manager.")
    }
}

public enum SocketError: Error, LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case alreadyRunning(String)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let p): return "Socket path is too long: \(p)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .alreadyRunning(let p): return "Another Command Manager is already listening on \(p)"
        }
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, timeout)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("connect", code)
        }
        return fd
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads until a newline, EOF or `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }
        guard data.count <= limit else { return nil }
        if let nl = data.firstIndex(of: 0x0A) { data = data[..<nl] }
        return data.isEmpty ? nil : data
    }
}

/// Local control endpoint run by the app. Only the same user can connect (file mode 0600 and a
/// peer-uid check). Requests are executed on the main actor, one at a time.
public final class ControlServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: @MainActor (String, [String: JSONValue]) -> JSONValue
    private var listenFD: Int32 = -1
    private let lock = NSLock()

    public init(socketPath: String, handler: @escaping @MainActor (String, [String: JSONValue]) -> JSONValue) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        // A client that disconnects early must never kill the app.
        signal(SIGPIPE, SIG_IGN)
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: socketPath) {
            if let fd = try? UnixSocket.connect(socketPath, timeout: 1) {
                close(fd)
                throw SocketError.alreadyRunning(socketPath)
            }
            unlink(socketPath)
        }
        var addr = try UnixSocket.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else { let code = errno; close(fd); throw SocketError.system("bind", code) }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw SocketError.system("listen", code) }
        lock.lock(); listenFD = fd; lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "CommandManager.ControlServer"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        UnixSocket.setTimeout(client, 30)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }

        let response: JSONValue
        if let line = UnixSocket.readLine(client, limit: ControlWire.maxRequestBytes),
           let request = try? JSONValue.decode(line),
           let op = request["op"]?.stringValue {
            let args = request["args"]?.objectValue ?? [:]
            let handler = self.handler
            response = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(op, args) } }
        } else {
            response = ControlWire.failure("Malformed request: expected one JSON line {\"op\":…, \"args\":{…}}.")
        }
        var data = response.encoded()
        data.append(0x0A)
        _ = UnixSocket.writeAll(client, data)
    }
}

/// Client used by `cmgr`.
public enum ControlClient {
    /// True when nothing is listening (app not running), as opposed to a request error.
    public static func isUnavailable(_ error: Error) -> Bool {
        if case SocketError.system("connect", _)? = error as? SocketError { return true }
        return false
    }

    public static func send(socketPath: String, op: String, args: [String: JSONValue], timeout: TimeInterval = 30) throws -> JSONValue {
        let fd = try UnixSocket.connect(socketPath, timeout: timeout)
        defer { close(fd) }
        var data = ControlWire.request(op: op, args: args).encoded()
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data) else { throw SocketError.system("write", errno) }
        guard let line = UnixSocket.readLine(fd, limit: 64 * 1024 * 1024) else {
            throw ControlError("No response from Command Manager (timed out or connection closed).")
        }
        return try ControlWire.unwrap(JSONValue.decode(line))
    }
}

public extension ControlService {
    /// Adapter for `ControlServer`: turns thrown errors into wire failures.
    func respond(op: String, args: [String: JSONValue]) -> JSONValue {
        do { return ControlWire.success(try handle(op: op, args: args)) }
        catch { return ControlWire.failure(error.localizedDescription) }
    }
}

public extension AppPaths {
    var controlSocket: URL { root.appendingPathComponent("control.sock") }
}
