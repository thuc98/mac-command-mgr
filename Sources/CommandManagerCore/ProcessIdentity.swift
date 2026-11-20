import Darwin
import Foundation

/// PID plus the kernel's process start time. A PID alone is not an identity: after a reboot or
/// long uptime the same number can belong to an unrelated process.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Microseconds since 1970 when the process started (from `proc_pidinfo`).
    public var startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    /// Identity of a live process, or nil if it does not exist / is not visible to this user.
    public static func current(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    /// True only when the same process (same PID *and* start time) is still alive.
    public static func isSameProcessAlive(_ identity: ProcessIdentity) -> Bool {
        current(pid: identity.pid) == identity
    }
}
