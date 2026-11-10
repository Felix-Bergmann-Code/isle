import Foundation

/// Links Claude Code sessions to their chats in the Claude desktop app.
///
/// The app keeps one JSON file per Code chat in
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`,
/// each naming the Claude Code session it runs (`cliSessionId`, the transcript's file name).
/// `claude://code/continue?session=local_<id>` opens that chat.
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"

    private static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private static var cache: [String: String] = [:] // cliSessionId → local_ id
    private static let lock = NSLock()

    static func chatURL(forCLISession id: String) -> URL? {
        guard let local = localID(forCLISession: id) else { return nil }
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/continue"
        c.queryItems = [URLQueryItem(name: "session", value: local)]
        return c.url
    }

    static func localID(forCLISession id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[id] { return hit }
        reload()
        return cache[id]
    }

    private static func reload() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var next: [String: String] = [:]
        for case let url as URL in e {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cli = obj["cliSessionId"] as? String,
                  let local = obj["sessionId"] as? String,
                  local.hasPrefix("local_"),
                  obj["isArchived"] as? Bool != true else { continue }
            next[cli] = local
        }
        cache = next
    }
}
