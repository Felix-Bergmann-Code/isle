import Foundation
import Observation

// MARK: - Context fill

/// How full a Claude session's context window is, from the last assistant entry's usage.
/// The prompt the model last saw (input + cache write + cache read) is what auto-compact
/// measures, so that is the number shown.
struct ContextFill: Equatable {
    var tokens: Int
    var limit: Int
    var model: String

    var fill: Double { min(1, Double(tokens) / Double(max(1, limit))) }

    /// "Context 84% · 168k of 200k tokens"
    var summary: String {
        "Context \(Int((fill * 100).rounded()))% · \(TokenCount.short(tokens)) of \(TokenCount.short(limit)) tokens"
    }

    /// 200k unless the session is known to run with 1M: an explicit "[1m]" marker, a model
    /// generation whose default window is 1M (Claude 5 and later, Fable, Mythos), or a prompt
    /// that is already past 200k (only possible with the larger window).
    static func limit(model: String, tokens: Int) -> Int {
        let m = model.lowercased()
        if tokens > 200_000 || m.contains("[1m]") || m.hasSuffix("-1m") || m.contains("fable") || m.contains("mythos") {
            return 1_000_000
        }
        // claude-opus-5-5, claude-sonnet-5, claude-haiku-5-5 …
        for family in ["opus-", "sonnet-", "haiku-"] {
            guard let r = m.range(of: family) else { continue }
            let major = Int(m[r.upperBound...].prefix { $0.isNumber }) ?? 0
            if major >= 5 { return 1_000_000 }
        }
        return 200_000
    }

    /// The newest main-chain assistant entry with usage in a transcript tail. Lines are
    /// newest-last; huge lines are only JSON-parsed when their ends look like an assistant entry.
    static func parse(_ lines: [Data.SubSequence]) -> ContextFill? {
        for line in lines.reversed() {
            let tail = line.suffix(4096)
            guard tail.range(of: Marker.assistant) != nil, line.range(of: Marker.usage) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let model = msg["model"] as? String ?? ""
            if model == "<synthetic>" { continue }
            let tokens = int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) + int(usage["cache_read_input_tokens"])
            guard tokens > 0 else { continue }
            return ContextFill(tokens: tokens, limit: limit(model: model, tokens: tokens), model: model)
        }
        return nil
    }

    fileprivate enum Marker {
        static let assistant = Data("\"type\":\"assistant\"".utf8)
        static let usage = Data("\"usage\":{".utf8)
    }
}

fileprivate func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

enum TokenCount {
    /// 940 · 8.4k · 168k · 3.4M · 120M
    static func short(_ n: Int) -> String {
        func trim(_ v: Double) -> String {
            let s = String(format: "%.1f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return trim(Double(n) / 1_000) + "k"
        case ..<1_000_000: return "\(Int((Double(n) / 1_000).rounded()))k"
        case ..<100_000_000: return trim(Double(n) / 1_000_000) + "M"
        default: return "\(Int((Double(n) / 1_000_000).rounded()))M"
        }
    }
}

// MARK: - Prices

/// ESTIMATE ONLY: Anthropic API list prices in USD per million tokens, used to put a rough
/// "what this would cost on the API" next to today's tokens. Subscription plans aren't billed
/// this way. Edit here when prices change; the first entry whose key the model id contains wins,
/// so keep specific versions above their family's fallback.
enum ClaudePricing {
    struct Rate { let input, output, cacheRead: Double }

    static let table: [(match: String, rate: Rate)] = [
        ("fable-5-2", Rate(input: 8, output: 40, cacheRead: 0.20)),
        ("mythos-5-2", Rate(input: 8, output: 40, cacheRead: 0.20)),
        ("fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("fable", Rate(input: 10, output: 50, cacheRead: 1.00)),
        ("mythos", Rate(input: 10, output: 50, cacheRead: 1.00)),
        ("opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20)),
        ("opus", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.10)),
        ("sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("sonnet", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("haiku-5-5", Rate(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("haiku", Rate(input: 1, output: 5, cacheRead: 0.10)),
    ]
    /// Cache writes cost a multiple of input: 1.25× for the 5-minute cache, 2× for 1 hour.
    static let cacheWrite5m = 1.25
    static let cacheWrite1h = 2.0

    static func rate(for model: String) -> Rate? {
        let m = model.lowercased()
        return table.first { m.contains($0.match) }?.rate
    }

    /// Estimated USD for one assistant entry's `usage`. Unknown models cost 0.
    static func cost(model: String, usage: [String: Any]) -> Double {
        guard let r = rate(for: model) else { return 0 }
        let write = int(usage["cache_creation_input_tokens"])
        var write1h = 0
        if let split = usage["cache_creation"] as? [String: Any] {
            write1h = min(write, int(split["ephemeral_1h_input_tokens"]))
        }
        let perToken = Double(int(usage["input_tokens"])) * r.input
            + Double(int(usage["output_tokens"])) * r.output
            + Double(int(usage["cache_read_input_tokens"])) * r.cacheRead
            + Double(write - write1h) * r.input * cacheWrite5m
            + Double(write1h) * r.input * cacheWrite1h
        return perToken / 1_000_000
    }
}

// MARK: - Today's usage

/// Sums Claude Code token usage for today and the last 5 hours from every transcript under
/// ~/.claude/projects (subagents included). Incremental: remembers how far each file was read
/// and only parses the bytes appended since, and only looks at files touched inside the window.
/// The same API response is often logged on several lines (and in several files), so entries
/// are deduped by message id + request id.
///
/// Refreshes every 10 minutes, or every 60 s while the island is open on the Agents tab
/// (where the number is shown), and right away when that view opens with stale data.
/// State is touched on the main thread only (the scanner lives on its own queue), hence
/// the unchecked Sendable for the observation callback.
@Observable
final class UsageService: @unchecked Sendable {
    struct Snapshot: Equatable {
        var todayTokens: Int
        var todayCost: Double
        var recentTokens: Int

        /// "Today: 3.4M tokens · ≈ $12.40 at API prices\nLast 5 hours: 1.1M tokens"
        var summary: String {
            "Today: \(TokenCount.short(todayTokens)) tokens, not counting cache reads · ≈ $\(String(format: "%.2f", todayCost)) at API prices\n"
                + "Last 5 hours: \(TokenCount.short(recentTokens)) tokens"
        }
    }

    private(set) var snapshot: Snapshot?

    @ObservationIgnored private weak var vm: IslandViewModel?
    @ObservationIgnored private let queue = DispatchQueue(label: "isle.usage", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var interval: TimeInterval = 0
    @ObservationIgnored private var lastRefresh = Date.distantPast

    static let recentWindow: TimeInterval = 5 * 3600

    func start(vm: IslandViewModel) {
        self.vm = vm
        track()
        reschedule()
    }

    /// Re-plan the timer whenever the island opens/closes, the tab changes or the setting flips.
    private func track() {
        guard let vm else { return }
        withObservationTracking {
            _ = vm.isOpen
            _ = vm.tab
            _ = AppSettings.shared.showUsageMeter
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.track()
                self?.reschedule()
            }
        }
    }

    private func reschedule() {
        guard AppSettings.shared.showUsageMeter, let vm else {
            timer?.cancel(); timer = nil; interval = 0
            if snapshot != nil { snapshot = nil }
            lastRefresh = .distantPast
            queue.async { [scanner] in scanner.reset() }
            return
        }
        let wanted: TimeInterval = vm.isOpen && vm.tab == .agents ? 60 : 600
        guard timer == nil || wanted != interval else { return }
        timer?.cancel()
        interval = wanted
        let due = max(0.5, lastRefresh.addingTimeInterval(wanted).timeIntervalSinceNow)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + due, repeating: wanted, leeway: .seconds(wanted > 60 ? 30 : 3))
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    private func refresh() {
        lastRefresh = Date()
        queue.async { [weak self, scanner] in
            let snap = scanner.scan(now: Date())
            DispatchQueue.main.async {
                guard let self, AppSettings.shared.showUsageMeter, self.snapshot != snap else { return }
                self.snapshot = snap
            }
        }
    }

    @ObservationIgnored private let scanner = UsageScanner()
}

/// File reading and parsing for UsageService. Only ever touched on its queue.
private final class UsageScanner {
    private struct Entry { let date: Date; let tokens: Int; let cost: Double }

    private var offsets: [URL: UInt64] = [:]
    private var entries: [String: Entry] = [:]
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    func reset() {
        offsets = [:]
        entries = [:]
    }

    func scan(now: Date) -> UsageService.Snapshot {
        let today = Calendar.current.startOfDay(for: now)
        let recent = now.addingTimeInterval(-UsageService.recentWindow)
        let cutoff = min(today, recent)

        var live: Set<URL> = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    // Tool output and other side folders hold no transcripts.
                    if url.lastPathComponent == "tool-results" { e.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "jsonl", let m = v.contentModificationDate, m >= cutoff else { continue }
                live.insert(url)
                read(url, size: UInt64(v.fileSize ?? 0), cutoff: cutoff)
            }
        }
        offsets = offsets.filter { live.contains($0.key) }
        entries = entries.filter { $0.value.date >= cutoff }

        var snap = UsageService.Snapshot(todayTokens: 0, todayCost: 0, recentTokens: 0)
        for e in entries.values {
            if e.date >= today { snap.todayTokens += e.tokens; snap.todayCost += e.cost }
            if e.date >= recent { snap.recentTokens += e.tokens }
        }
        return snap
    }

    /// Parse the complete lines appended since the last read, in bounded chunks.
    private func read(_ url: URL, size: UInt64, cutoff: Date) {
        var offset = offsets[url] ?? 0
        if size < offset { offset = 0 } // rewritten
        guard size > offset, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let chunk = 8 * 1024 * 1024
        while offset < size {
            try? fh.seek(toOffset: offset)
            guard let data = try? fh.read(upToCount: chunk), !data.isEmpty else { break }
            guard let lastNL = data.lastIndex(of: 0x0A) else {
                // A line longer than the chunk: only worth reading when it's finished.
                if data.count < chunk { break }
                guard let whole = try? fh.readToEnd(), let nl = whole.firstIndex(of: 0x0A) else { break }
                ingest(data + whole[..<nl], cutoff: cutoff)
                offset += UInt64(data.count + (nl - whole.startIndex) + 1)
                continue
            }
            let complete = data[data.startIndex...lastNL]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) { ingest(line, cutoff: cutoff) }
            offset += UInt64(complete.count)
        }
        offsets[url] = offset
    }

    private func ingest(_ line: Data, cutoff: Date) {
        guard line.suffix(4096).range(of: ContextFill.Marker.assistant) != nil,
              line.range(of: ContextFill.Marker.usage) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp), date >= cutoff else { return }
        let model = msg["model"] as? String ?? ""
        if model == "<synthetic>" { return }
        let id = msg["id"] as? String ?? obj["uuid"] as? String ?? ""
        let key = id + ":" + (obj["requestId"] as? String ?? "")
        guard entries[key] == nil else { return }
        // Cache reads are left out: they re-count the same context on every turn and would
        // dwarf everything else (they're still priced into the cost estimate).
        let tokens = int(usage["input_tokens"]) + int(usage["output_tokens"])
            + int(usage["cache_creation_input_tokens"])
        guard tokens > 0 else { return }
        entries[key] = Entry(date: date, tokens: tokens, cost: ClaudePricing.cost(model: model, usage: usage))
    }
}
