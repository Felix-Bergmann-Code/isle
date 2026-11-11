import AppKit
import Observation

/// An agent waiting on you is wasted time. This makes long waits harder to miss without nagging:
///  - re-raises the agent banner once at 5 min and once at 20 min of the same waiting period
///  - while the screen is locked or asleep, holds agent banners back (nobody would see them)
///    and on return shows one "While you were away" summary instead
///
/// The 3-minute pulse on the closed island is drawn by `LayerPulseHalo` from
/// `AgentMonitor.longestWaitSince`, so it needs no timer at all.
/// Everything here is gated by `AppSettings.waitingNudges`.
/// Main thread only (`@unchecked` so Observation and notification callbacks can hop back to it).
final class WaitingNudger: @unchecked Sendable {
    private let settings = AppSettings.shared
    private let agents: AgentMonitor
    private let vm: IslandViewModel

    /// Runs only while some agent is waiting; started and stopped from session changes.
    private var timer: Timer?
    /// Reminders already given per waiting period: session id → (phaseSince, 1 = 5 min, 2 = 20 min).
    private var reminded: [String: (since: Date, level: Int)] = [:]

    private var locked = false
    private var asleep = false
    private var awaySince: Date?
    private var awayWaiting = Set<String>()
    private var awayDone = Set<String>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static let reminderMarks: [TimeInterval] = [5 * 60, 20 * 60]
    static let minimumAway: TimeInterval = 2 * 60

    init(agents: AgentMonitor, vm: IslandViewModel) {
        self.agents = agents
        self.vm = vm
    }

    func start() {
        observeSessions()
        sessionsChanged()

        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (WaitingNudger) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                body(self)
                self.awayChanged()
            }
            observers.append((center, token))
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.asleep = false }
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    /// True while agent banners should be held back because nobody is looking at the screen.
    var suppressesBanners: Bool { settings.waitingNudges && awaySince != nil }

    /// Called first thing for every agent transition (AppEnvironment.announce). Remembers what
    /// happened while away; returns true when the banner should be skipped.
    func absorb(_ s: AgentSession, phase: AgentPhase) -> Bool {
        guard awaySince != nil, counts(s) else { return false }
        DevLog.write("away: noted \(s.project) \(phase.rawValue)")
        switch phase {
        case .waiting: awayWaiting.insert(s.id)
        case .done: awayDone.insert(s.id)
        default: break
        }
        return suppressesBanners
    }

    // MARK: Reminders

    /// Sessions whose waits we care about: the same set `announce` banners for.
    private func counts(_ s: AgentSession) -> Bool { !s.isBackground || settings.showBackgroundAgents }

    private var waitingSessions: [AgentSession] {
        agents.sessions.filter { $0.phase == .waiting && counts($0) }
    }

    /// Re-registers after every change (Observation fires once per registration).
    private func observeSessions() {
        withObservationTracking { _ = agents.sessions } onChange: { [weak self] in
            // onChange runs before the new value is stored: read it on the next turn.
            DispatchQueue.main.async {
                self?.sessionsChanged()
                self?.observeSessions()
            }
        }
    }

    private func sessionsChanged() {
        let waiting = waitingSessions
        let ids = Set(waiting.map(\.id))
        reminded = reminded.filter { ids.contains($0.key) }
        if waiting.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        guard settings.waitingNudges else { return }
        let now = Date()
        // Longest wait first; at most one banner per tick so two reminders never overwrite each other.
        for s in waitingSessions.sorted(by: { $0.phaseSince < $1.phaseSince }) {
            let waited = now.timeIntervalSince(s.phaseSince)
            let level = Self.reminderMarks.filter { waited >= $0 }.count
            var r = reminded[s.id].flatMap { $0.since == s.phaseSince ? $0 : nil } ?? (since: s.phaseSince, level: 0)
            guard level > r.level else { continue }
            r.level = level
            reminded[s.id] = r
            if remind(s, waited: waited) { break }
        }
    }

    /// Skipped (but still counted as given) while the island is open, the person is away,
    /// or agent banners are off.
    private func remind(_ s: AgentSession, waited: TimeInterval) -> Bool {
        guard settings.agentBanners, !vm.isOpen, awaySince == nil else { return false }
        let what = s.detail.isEmpty ? (s.lastMessage ?? "\(s.kind.name) needs you") : s.detail
        vm.flash(.agent(AgentBanner(kind: s.kind, phase: .waiting, title: "\(s.project) is still waiting",
                                    subtitle: "\(what) · \(formatWait(waited))")), duration: 7)
        if settings.agentSound { IsleSound.play("Submarine") }
        return true
    }

    // MARK: Away summary

    private func awayChanged() {
        let away = locked || asleep
        DevLog.write("away: locked=\(locked) asleep=\(asleep)")
        if away, awaySince == nil {
            awaySince = Date()
            awayWaiting = []
            awayDone = []
        } else if !away, let since = awaySince {
            awaySince = nil
            summarize(since: since)
        }
    }

    private func summarize(since: Date) {
        DevLog.write("away: back after \(Int(Date().timeIntervalSince(since)))s, waiting \(awayWaiting.count), done \(awayDone.count)")
        guard settings.waitingNudges, Date().timeIntervalSince(since) >= Self.minimumAway,
              !(awayWaiting.isEmpty && awayDone.isEmpty) else { return }
        let waitingIDs = Set(waitingSessions.map(\.id))
        let needYou = waitingIDs.count
        let finished = awayDone.subtracting(waitingIDs).count
        guard needYou + finished > 0 else { return }
        var parts: [String] = []
        if needYou > 0 { parts.append(needYou == 1 ? "1 agent needs you" : "\(needYou) agents need you") }
        if finished > 0 { parts.append("\(finished) finished") }
        let notice = Notice(icon: "person.crop.circle.badge.clock",
                            tint: needYou > 0 ? AgentPhase.waiting.color : AgentPhase.done.color,
                            title: "While you were away", subtitle: parts.joined(separator: " · "), tab: .agents)
        // Let the unlock animation finish first, or the banner drops while nobody's looking yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.vm.notify(notice, duration: 8)
        }
    }
}

extension AgentMonitor {
    /// Start of the longest current wait, for the closed island's pulse (which begins 3 min
    /// after it). Nil when nothing waits or reminders are off.
    var longestWaitSince: Date? {
        guard AppSettings.shared.waitingNudges else { return nil }
        return visibleSessions.filter { $0.phase == .waiting }.map(\.phaseSince).min()
    }
}

/// Compact wait time: "45s", "4m", "1h 12m".
func formatWait(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    let m = (s % 3600) / 60
    return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
}

/// The agent row's trailing time: how long it has waited on you, else how long it has worked
/// (or run, when done or idle).
func agentRowTime(_ s: AgentSession, now: Date) -> String {
    switch s.phase {
    case .waiting: return formatWait(now.timeIntervalSince(s.phaseSince))
    case .working: return formatDuration(now.timeIntervalSince(s.phaseSince))
    case .done, .idle: return formatDuration(now.timeIntervalSince(s.startedAt))
    }
}
