import Darwin
import Foundation
import Observation
import SwiftUI

/// How a listed dev server answers a plain HTTP request, drawn as the dot in its row.
enum ServerHealthState: Equatable {
    /// Not checked yet.
    case unknown
    case ok(status: Int, ms: Int)
    /// 5xx, or an answer slower than `ServerHealth.slowMs`.
    case degraded(status: Int, ms: Int)
    /// One check timed out. Dev servers often compile on the first request, so a single miss
    /// is only amber; a second one in a row turns red.
    case slow
    /// Timed out twice, or refuses connections although the port is still listed.
    case unresponsive
    /// The first answer wasn't HTTP (a database, a TLS-only server…). Never checked again.
    case notHTTP
    /// Ghost row of a server that went away.
    case stopped

    var color: Color {
        switch self {
        case .ok: return AgentPhase.done.color
        case .degraded, .slow: return AgentPhase.waiting.color
        case .unresponsive, .stopped: return .red
        case .unknown, .notHTTP: return Color.islandTertiary
        }
    }

    var help: String {
        switch self {
        case .unknown: return "Not checked yet"
        case let .ok(status, ms): return "\(status) · \(ms) ms"
        case let .degraded(status, ms): return status >= 500 ? "Server error \(status)" : "Slow · \(status) · \(ms) ms"
        case .slow: return "No answer within 2 s"
        case .unresponsive: return "Not responding"
        case .notHTTP: return "Not an HTTP server"
        case .stopped: return "Stopped"
        }
    }
}

/// Health dots and crash warnings for the dev servers `PortsService` lists.
///
/// Health checks run only while the Dev Servers panel is on screen (every 10 s, plus once on
/// appear and once for each new port). Crash warnings need a scan while the island is closed, so
/// this keeps a slow 30 s `lsof` scan going, but only while the warning is on and the last scan
/// saw at least one server: with nothing listening there is nothing that can stop.
///
/// Main-thread confined like the other services; probes run detached and hop back with
/// `DispatchQueue.main`, hence the unchecked Sendable.
@Observable
final class ServerHealth: @unchecked Sendable {
    private(set) var states: [Int: ServerHealthState] = [:]
    /// Servers that went away without the person stopping them in Isle, kept for `ghostLife`.
    private(set) var ghosts: [DevPort] = []

    static let slowMs = 1500
    static let ghostLife: TimeInterval = 60

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private weak var ports: PortsService?
    @ObservationIgnored private weak var vm: IslandViewModel?
    @ObservationIgnored private var pids: [Int: pid_t] = [:]
    @ObservationIgnored private var misses: [Int: Int] = [:]
    @ObservationIgnored private var answered = Set<Int>()
    @ObservationIgnored private var inFlight = Set<Int>()
    @ObservationIgnored private var visible = 0
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var lastSeedScan = Date.distantPast
    /// Processes ended with Isle's stop button (by pid, since one process can hold several
    /// ports): their exit is expected, not a crash.
    @ObservationIgnored private var stoppedByUser: [pid_t: Date] = [:]
    /// Ghosts waiting for a second look before the warning goes out.
    @ObservationIgnored private var pending: [Int: DispatchWorkItem] = [:]
    @ObservationIgnored private var ghostExpiry: [Int: DispatchWorkItem] = [:]
    @ObservationIgnored private var toWarn: [DevPort] = []

    private var warns: Bool { settings.showDevServers && settings.warnDevServerStops }

    func state(for port: DevPort) -> ServerHealthState {
        // Demo servers aren't real, so nothing checks them; show them healthy for screenshots.
        if Demo.isEnabled { return .ok(status: 200, ms: 12) }
        return states[port.port] ?? .unknown
    }

    func start(ports: PortsService, vm: IslandViewModel) {
        self.ports = ports
        self.vm = vm
        ports.onChange = { [weak self] old, new in self?.portsChanged(from: old, to: new) }
        ports.onStop = { [weak self] p in self?.stoppedByUser[p.pid] = Date() }
        observe()
        if warns { ports.refresh() }
    }

    // MARK: Panel visibility

    /// The Dev Servers panel appeared: check every port now and every 10 s after.
    func beginUpdates() {
        visible += 1
        guard visible == 1 else { return }
        reschedule() // the panel scans every 4 s itself
        checkAll()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.checkAll() }
        checkTimer?.tolerance = 1
    }

    func endUpdates() {
        visible = max(0, visible - 1)
        guard visible == 0 else { return }
        checkTimer?.invalidate()
        checkTimer = nil
        reschedule()
    }

    // MARK: Port changes

    private func portsChanged(from old: [DevPort], to new: [DevPort]) {
        let now = Set(new.map(\.port))
        for p in new {
            // Back again (or restarted): drop any ghost or pending warning without a word.
            pending.removeValue(forKey: p.port)?.cancel()
            if ghosts.contains(where: { $0.port == p.port }) { removeGhost(p.port) }
            if pids[p.port] != p.pid {
                forget(p.port)
                pids[p.port] = p.pid
                if visible > 0 { check(p) }
            }
        }
        stoppedByUser = stoppedByUser.filter { Date().timeIntervalSince($0.value) < 60 }
        for p in old where !now.contains(p.port) {
            forget(p.port)
            pids[p.port] = nil
            if warns && stoppedByUser[p.pid] == nil { stopped(p) }
        }
        reschedule()
    }

    private func forget(_ port: Int) {
        states[port] = nil
        misses[port] = nil
        answered.remove(port)
    }

    /// The row turns into a ghost at once. The warning waits 2 s for a second look with a plain
    /// connect, because a scan can land in the gap of a restart (nodemon, a config reload).
    private func stopped(_ p: DevPort) {
        ghosts.removeAll { $0.port == p.port }
        ghosts.append(p)
        ghostExpiry[p.port]?.cancel()
        let expire = DispatchWorkItem { [weak self] in self?.removeGhost(p.port) }
        ghostExpiry[p.port] = expire
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ghostLife, execute: expire)

        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let back = Self.isListening(p.port)
                DispatchQueue.main.async {
                    guard let self, self.pending.removeValue(forKey: p.port) != nil else { return }
                    if back {
                        self.removeGhost(p.port)
                        self.ports?.refresh()
                    } else {
                        self.warn(p)
                    }
                }
            }
        }
        pending[p.port]?.cancel()
        pending[p.port] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Servers that go down together (a closed terminal, `docker compose down`) share one banner.
    private func warn(_ p: DevPort) {
        guard warns else { return }
        toWarn.append(p)
        guard toWarn.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let all = self.toWarn.sorted { $0.port < $1.port }
            self.toWarn.removeAll()
            guard let first = all.first else { return }
            let notice = all.count == 1
                ? Notice(icon: "exclamationmark.triangle.fill", tint: .red, title: "localhost:\(first.port) stopped",
                         subtitle: "\(first.command) · \(first.project)", tab: .agents)
                : Notice(icon: "exclamationmark.triangle.fill", tint: .red, title: "\(all.count) dev servers stopped",
                         subtitle: all.map { ":\($0.port)" }.joined(separator: ", "), tab: .agents)
            self.vm?.notify(notice, duration: 6)
        }
    }

    private func removeGhost(_ port: Int) {
        ghostExpiry.removeValue(forKey: port)?.cancel()
        ghosts.removeAll { $0.port == port }
    }

    // MARK: Background scan

    private func reschedule() {
        let want = warns && visible == 0 && !(ports?.ports.isEmpty ?? true)
        if want, scanTimer == nil {
            scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.ports?.refresh() }
            scanTimer?.tolerance = 5
        } else if !want {
            scanTimer?.invalidate()
            scanTimer = nil
        }
    }

    /// Re-evaluates on setting changes, and seeds a scan when the island opens with no server
    /// known (at most once a minute), so servers started later get watched too.
    private func observe() {
        withObservationTracking {
            _ = settings.showDevServers
            _ = settings.warnDevServerStops
            _ = vm?.isOpen
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.warns {
                    self.pending.values.forEach { $0.cancel() }
                    self.pending.removeAll()
                    self.ghosts.map(\.port).forEach(self.removeGhost)
                } else if self.vm?.isOpen == true, self.ports?.ports.isEmpty == true,
                          Date().timeIntervalSince(self.lastSeedScan) > 60 {
                    self.lastSeedScan = Date()
                    self.ports?.refresh()
                }
                self.reschedule()
                self.observe()
            }
        }
    }

    // MARK: Health checks

    private func checkAll() {
        for p in ports?.ports ?? [] { check(p) }
    }

    private func check(_ p: DevPort) {
        guard states[p.port] != .notHTTP, !inFlight.contains(p.port) else { return }
        inFlight.insert(p.port)
        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.probe(port: p.port)
            DispatchQueue.main.async { self?.apply(result, port: p.port, pid: p.pid) }
        }
    }

    private func apply(_ result: Probe, port: Int, pid: pid_t) {
        inFlight.remove(port)
        // The port went away or changed hands while the request was out.
        guard pids[port] == pid else { return }
        let state: ServerHealthState
        switch result {
        case let .answer(status, ms):
            answered.insert(port)
            misses[port] = 0
            state = status >= 500 || ms >= Self.slowMs ? .degraded(status: status, ms: ms) : .ok(status: status, ms: ms)
        case .timeout:
            let n = (misses[port] ?? 0) + 1
            misses[port] = n
            state = n >= 2 ? .unresponsive : .slow
        case .refused:
            state = .unresponsive
        case .garbled:
            state = answered.contains(port) ? .unresponsive : .notHTTP
        }
        if states[port] != state { states[port] = state }
    }

    // MARK: Probing (off the main thread)

    private enum Probe { case answer(status: Int, ms: Int), timeout, refused, garbled }

    /// No cache, cookies, proxies or redirects: one bare request to the server itself.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.connectionProxyDictionary = [:]
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 3
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Servers started with `localhost` often bind only to ::1, so try IPv6 when IPv4 refuses.
    private static func probe(port: Int) async -> Probe {
        for host in ["127.0.0.1", "[::1]"] {
            var r = await request(host: host, port: port, method: "HEAD")
            if case let .answer(status, _) = r, status == 405 || status == 501 {
                r = await request(host: host, port: port, method: "GET")
            }
            if case .refused = r { continue }
            return r
        }
        return .refused
    }

    private static func request(host: String, port: Int, method: String) async -> Probe {
        guard let url = URL(string: "http://\(host):\(port)/") else { return .garbled }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 2)
        req.httpMethod = method
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            // Returns once the headers are in; the body is never read.
            let (bytes, response) = try await session.bytes(for: req)
            bytes.task.cancel()
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard let http = response as? HTTPURLResponse else { return .garbled }
            return .answer(status: http.statusCode, ms: ms)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: return .timeout
            case .cannotConnectToHost: return .refused
            default: return .garbled
            }
        } catch {
            return .garbled
        }
    }

    /// A bare TCP connect to loopback (v4, then v6), used to confirm a server is really gone.
    private static func isListening(_ port: Int) -> Bool {
        connects(port: port, v6: false) || connects(port: port, v6: true)
    }

    private static func connects(port: Int, v6: Bool) -> Bool {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let r: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(UInt16(port).bigEndian)
            a.sin6_addr = in6addr_loopback
            r = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(UInt16(port).bigEndian)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            r = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 500) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
