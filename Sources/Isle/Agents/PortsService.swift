import AppKit
import Observation

struct DevPort: Identifiable, Equatable {
    var id: Int { port }
    let port: Int
    let pid: pid_t
    let command: String
    let project: String
}

/// Local dev servers (TCP listeners started from a project directory).
@Observable
final class PortsService {
    var ports: [DevPort] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clients = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "isle.ports", qos: .utility)
    @ObservationIgnored private var running = false

    func beginUpdates() {
        clients += 1
        guard clients == 1 else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func endUpdates() {
        clients = max(0, clients - 1)
        if clients == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            let found = Self.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if found != self.ports { self.ports = found }
            }
        }
    }

    func open(_ p: DevPort) {
        if let url = URL(string: "http://localhost:\(p.port)") { NSWorkspace.shared.open(url) }
    }

    func stop(_ p: DevPort) {
        kill(p.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    private static func scan() -> [DevPort] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-u", String(getuid()), "-Fpcn"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        var result: [Int: DevPort] = [:]
        var pid: pid_t = 0
        var command = ""
        var cwdCache: [pid_t: String?] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = pid_t(value) ?? 0
            case "c": command = value
            case "n":
                guard let portStr = value.split(separator: ":").last, let port = Int(portStr),
                      port >= 1024, port < 49152, result[port] == nil else { continue }
                let cwd: String?
                if let c = cwdCache[pid] { cwd = c } else { cwd = ProcInfo.cwd(pid); cwdCache[pid] = cwd }
                // Dev servers are launched from a project folder; system/app helpers run from "/".
                guard let dir = cwd, dir.hasPrefix(home), dir != home, !dir.contains("/Library/") else { continue }
                result[port] = DevPort(port: port, pid: pid, command: command, project: (dir as NSString).lastPathComponent)
            default: break
            }
        }
        return result.values.sorted { $0.port < $1.port }
    }
}
