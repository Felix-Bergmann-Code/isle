import Foundation
import Network

/// Tiny loopback-only HTTP server that receives agent hook events.
///   POST /hook/claude  – Claude Code hook JSON on the body (header X-Isle-PID: $PPID)
///   POST /hook/permission – Claude Code PermissionRequest hook; held open until the person
///                        decides in the island, then answered with the hook's decision JSON
///                        (an empty body leaves the decision to Claude Code's own prompt)
///   POST /hook/custom  – {"id","name","phase":"working|waiting|done|idle|end","detail","cwd"}
///   GET  /health
final class HookServer {
    static let defaultPort: UInt16 = 47823

    var onEvent: ((_ source: String, _ pid: pid_t?, _ payload: [String: Any]) -> Void)?
    /// A permission request arrived (main thread). Return false to answer "no decision" at once.
    var onPermission: ((_ id: UUID, _ pid: pid_t?, _ payload: [String: Any]) -> Bool)?
    /// A held permission request ended without a decision from the island (main thread).
    var onPermissionGone: ((_ id: UUID) -> Void)?
    /// How long the island holds a request before handing it back to Claude Code's prompt.
    static let permissionHold: TimeInterval = 120

    private(set) var isListening = false
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "isle.hooks")
    private var held: [UUID: NWConnection] = [:] // queue only

    init(port: UInt16) { self.port = port }

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else { return }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.isListening = true }
            if case .failed = state { self?.isListening = false }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.held.values.contains(where: { $0 === c }) else { return }
            c.cancel()
        }
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                // Browsers attach Origin / Sec-Fetch-Site to requests made by web pages; curl and hooks don't.
                // Rejecting those stops a website from posting fake agent events to this loopback port.
                if req.headers["origin"] != nil || req.headers["sec-fetch-site"] != nil {
                    self.respond(c, status: "403 Forbidden", body: "forbidden")
                    return
                }
                if req.method == "POST", req.path == "/hook/permission" {
                    self.hold(c, req)
                } else {
                    self.respond(c, status: "200 OK", body: "ok")
                    self.dispatch(req)
                }
                return
            }
            if done || error != nil || buf.count > 4_000_000 { c.cancel(); return }
            self.receive(c, buffer: buf)
        }
    }

    // MARK: Permission requests

    private func hold(_ c: NWConnection, _ r: Request) {
        let id = UUID()
        let payload = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        let pid = r.headers["x-isle-pid"].flatMap { Int32($0) }
        held[id] = c
        watchForHangup(c, id: id)
        queue.asyncAfter(deadline: .now() + Self.permissionHold) { [weak self] in self?.release(id, body: "", notify: true) }
        DispatchQueue.main.async {
            let wanted = self.onPermission?(id, pid, payload) ?? false
            if !wanted { self.queue.async { self.release(id, body: "", notify: false) } }
        }
    }

    /// The hook's curl closes its end when Claude Code stops waiting (answered in the app, interrupted).
    private func watchForHangup(_ c: NWConnection, id: UUID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            guard let self, self.held[id] != nil else { return }
            if done || error != nil { self.release(id, body: nil, notify: true) } else { self.watchForHangup(c, id: id) }
        }
    }

    /// Answers a held request. Safe to call from any thread, and more than once.
    func decide(_ id: UUID, _ decision: PermissionPrompt.Decision) {
        let body: String
        switch decision {
        case .allow: body = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny: body = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user denied this from the Isle notch app."}}}"#
        case .deferToApp: body = ""
        }
        queue.async { self.release(id, body: body, notify: false) }
    }

    /// queue only. `body == nil` means the peer is gone: just close.
    private func release(_ id: UUID, body: String?, notify: Bool) {
        guard let c = held.removeValue(forKey: id) else { return }
        if let body {
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
        } else {
            c.cancel()
        }
        if notify { DispatchQueue.main.async { self.onPermissionGone?(id) } }
    }

    private func respond(_ c: NWConnection, status: String, body: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let idx = l.firstIndex(of: ":") else { continue }
            headers[l[..<idx].lowercased()] = l[l.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    private func dispatch(_ r: Request) {
        guard r.method == "POST", r.path.hasPrefix("/hook/") else { return }
        let source = String(r.path.dropFirst("/hook/".count))
        let payload = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        let pid = r.headers["x-isle-pid"].flatMap { Int32($0) }
        DispatchQueue.main.async { self.onEvent?(source, pid, payload) }
    }
}

/// Adds/removes Isle's hook entries in ~/.claude/settings.json (with a backup).
enum ClaudeHookInstaller {
    static let markerBase = "127.0.0.1:\(HookServer.defaultPort)/hook/"
    static let marker = markerBase + "claude"
    static let permissionMarker = markerBase + "permission"
    static var command: String {
        "curl -s -m 1 -X POST -H \"X-Isle-PID: $PPID\" -H 'Content-Type: application/json' --data-binary @- http://\(marker) >/dev/null 2>&1 || true"
    }
    /// Waits for the island's decision and prints it for Claude Code. If Isle isn't running,
    /// curl fails at once and prints nothing, so Claude Code shows its own prompt as usual.
    static var permissionCommand: String {
        "curl -s -m \(Int(HookServer.permissionHold) + 10) -X POST -H \"X-Isle-PID: $PPID\" -H 'Content-Type: application/json' --data-binary @- http://\(permissionMarker) 2>/dev/null || true"
    }
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "SessionStart", "SessionEnd", "PermissionRequest"]
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    static var isInstalled: Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.contains(marker)
    }

    /// Installed by an older Isle without the approval hook.
    static var needsUpgrade: Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.contains(marker) && !s.contains(permissionMarker)
    }

    enum InstallError: LocalizedError {
        case unreadable
        var errorDescription: String? { "~/.claude/settings.json isn't valid JSON, so Isle left it untouched." }
    }

    static func install() throws {
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !containsMarker($0) }
            var entry: [String: Any] = event == "PermissionRequest"
                ? ["hooks": [["type": "command", "command": permissionCommand, "timeout": Int(HookServer.permissionHold) + 15]]]
                : ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PreToolUse" || event == "PostToolUse" || event == "PermissionRequest" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try write(root)
    }

    static func uninstall() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !containsMarker($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try write(root)
    }

    private static func containsMarker(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String)?.contains(markerBase) == true }
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw InstallError.unreadable }
        return obj
    }

    private static func write(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("isle-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
