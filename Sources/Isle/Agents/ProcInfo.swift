import Darwin
import Foundation

/// Thin, allocation-light wrappers over libproc / sysctl.
enum ProcInfo {
    static let ticksToNanos: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 128)
        let count = buf.withUnsafeMutableBufferPointer { ptr in
            proc_listallpids(ptr.baseAddress, Int32(ptr.count * MemoryLayout<pid_t>.size))
        }
        return Array(buf.prefix(Int(max(0, count))))
    }

    struct BSD {
        let pid: pid_t
        let ppid: pid_t
        let uid: uid_t
        let startSec: UInt64
    }

    /// All processes of one user in a single sysctl (instead of one syscall per pid).
    static func userProcesses(uid: uid_t) -> [BSD] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(n).map {
            BSD(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid, uid: uid,
                startSec: UInt64(max(0, $0.kp_proc.p_starttime.tv_sec)))
        }
    }

    /// Parent of any process, including root-owned ones (`login`) that `proc_pidinfo` refuses.
    static func parent(_ pid: pid_t) -> pid_t? {
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &len, nil, 0) == 0, len > 0 else { return nil }
        return kp.kp_eproc.e_ppid
    }

    static func bsd(_ pid: pid_t) -> BSD? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return BSD(pid: pid, ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid, startSec: info.pbi_start_tvsec)
    }

    /// Total CPU time (user + system) in nanoseconds.
    static func cpuNanos(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return UInt64(Double(info.pti_total_user + info.pti_total_system) * ticksToNanos)
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        return r > 0 ? String(cString: buf) : nil
    }

    static func cwd(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        return withUnsafePointer(to: &vpi.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 } // exec path
        while i < size && buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        var start = i
        while i < size && args.count < Int(argc) {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }
}
