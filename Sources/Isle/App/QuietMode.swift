import Foundation
import SwiftUI
import Observation

/// One switch that keeps the island calm during focus time.
///
/// While on, banners and sounds are held back and counted; when quiet ends, one banner sums
/// up what was missed. The volume / brightness HUD and compact live activities stay: the HUD
/// answers a key press, live activities show something ongoing rather than interrupting.
/// Approval requests and meeting reminders still come through unless switched off in Settings.
///
/// The gate is central so new banners are covered without extra checks: every banner passes
/// `IslandViewModel.flash`, which asks `quietFilter` (wired to `allows(_:)` in AppEnvironment),
/// and every sound goes through `AppEnvironment.play(_:)`.
@Observable
final class QuietMode {
    /// Indigo, like macOS Focus.
    static let tint = Color(red: 0.55, green: 0.5, blue: 1.0)

    private(set) var isOn = false
    /// When quiet ends by itself (nil = until turned off).
    private(set) var until: Date?
    /// Last Shortcut failure, shown in Settings. Cleared by the next successful run.
    private(set) var shortcutError: String?
    /// What was held back since quiet started, by kind.
    private(set) var held: [Kind: Int] = [:]

    @ObservationIgnored private weak var env: AppEnvironment?
    @ObservationIgnored private let d = UserDefaults.standard
    /// Turned on by a calendar meeting, so it also turns off when the meeting ends.
    @ObservationIgnored private var auto = false
    /// The meeting that last turned quiet on; not turned on again for it after a manual "off".
    @ObservationIgnored private var autoMeetingID: String?
    @ObservationIgnored private var expiry: Timer?
    @ObservationIgnored private var meetingTimer: Timer?
    @ObservationIgnored private var pending: Timer?

    private var settings: AppSettings { .shared }

    /// Quiet is in effect: on, and the feature isn't switched off in Settings.
    var isActive: Bool { isOn && settings.quietMode }

    /// Kinds of held-back banners, in the order the summary mentions them.
    enum Kind: Int, CaseIterable {
        case agentDone, agentWaiting, approval, meeting, deviceConnected, notice, deviceDisconnected, power, shelf

        var isAgent: Bool { self == .agentDone || self == .agentWaiting || self == .approval }

        func phrase(_ n: Int) -> String {
            func count(_ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
            switch self {
            case .agentDone: return count("agent finished", "agents finished")
            case .agentWaiting: return count("agent needed you", "agents needed you")
            case .approval: return count("approval request", "approval requests")
            case .meeting: return count("meeting reminder", "meeting reminders")
            case .deviceConnected: return count("device connected", "devices connected")
            case .notice: return count("update", "updates")
            case .deviceDisconnected: return count("device disconnected", "devices disconnected")
            case .power: return count("power change", "power changes")
            case .shelf: return count("shelf update", "shelf updates")
            }
        }

        /// nil: always shown (HUD, low battery).
        init?(_ activity: Activity) {
            switch activity {
            case .volume, .brightness, .lowBattery: return nil
            case .charging: self = .power
            case .bluetooth(_, _, let connected): self = connected ? .deviceConnected : .deviceDisconnected
            case .agent(let b): self = b.isApproval ? .approval : b.phase == .done ? .agentDone : .agentWaiting
            case .meeting: self = .meeting
            case .shelf: self = .shelf
            case .notice: self = .notice
            }
        }
    }

    init() {
        guard d.bool(forKey: "quietOn"), AppSettings.shared.quietMode else { return }
        let end = d.object(forKey: "quietUntil") as? Date
        guard end.map({ $0 > Date() }) ?? true else { persist(); return }
        isOn = true
        until = end
        auto = d.bool(forKey: "quietAuto")
    }

    func start(env: AppEnvironment) {
        self.env = env
        scheduleExpiry()
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkMeetings() }
        checkMeetings()
    }

    // MARK: Gate

    /// The banner gate. Returns false (and counts it) when quiet should hold `activity` back.
    func allows(_ activity: Activity) -> Bool {
        guard isActive, let kind = Kind(activity) else { return true }
        if kind == .approval, settings.quietAllowApprovals { return true }
        if kind == .meeting, settings.quietAllowMeetings { return true }
        held[kind, default: 0] += 1
        return false
    }

    // MARK: Switching

    func toggle() { isOn ? turnOff() : turnOn() }
    func turnOn(until end: Date? = nil) { set(true, until: end) }
    func turnOff() { set(false) }

    /// Shell control: "on", "off", anything else toggles.
    func perform(_ arg: String) {
        switch arg {
        case "on": turnOn()
        case "off": turnOff()
        default: toggle()
        }
    }

    /// Tomorrow at 8:00, for "Quiet until tomorrow".
    static var tomorrowMorning: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Hover text for the header button.
    var help: String {
        guard isActive else { return "Quiet mode" }
        var text = until.map { "Quiet until \(Self.format($0))" } ?? "Quiet mode is on"
        let n = held.values.reduce(0, +)
        if n > 0 { text += " · \(n) held back" }
        return text
    }

    private static func format(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow, \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func set(_ on: Bool, until end: Date? = nil, auto: Bool = false) {
        guard !on || settings.quietMode else { return }
        let was = isOn
        withAnimation(Anim.micro) {
            isOn = on
            until = on ? end : nil
        }
        self.auto = on && auto
        scheduleExpiry()
        persist()
        guard was != on else { return }
        runShortcut(on ? settings.quietStartShortcut : settings.quietEndShortcut)
        if !on { summarize() }
    }

    private func persist() {
        d.set(isOn, forKey: "quietOn")
        d.set(until, forKey: "quietUntil")
        d.set(auto, forKey: "quietAuto")
    }

    private func scheduleExpiry() {
        expiry?.invalidate()
        expiry = nil
        guard isOn, let until else { return }
        // A Timer whose date passed during sleep fires on wake.
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in self?.expire() }
        RunLoop.main.add(t, forMode: .common)
        expiry = t
    }

    private func expire() {
        // Back-to-back meetings: stay quiet into the next one instead of flickering off and on.
        if auto, let next = ongoingMeeting() {
            autoMeetingID = next.id
            until = next.end
            persist()
            scheduleExpiry()
        } else {
            turnOff()
        }
    }

    // MARK: Meetings

    private func ongoingMeeting() -> CalEvent? {
        guard settings.quietMode, settings.quietDuringMeetings else { return nil }
        return env?.calendar.events.first { !$0.isAllDay && $0.isOngoing && $0.meetingURL != nil }
    }

    /// "Turn on during calendar meetings": on while a call is running, off when it ends —
    /// but only if quiet was turned on by the meeting, and never again for a meeting the
    /// person un-quieted by hand.
    private func checkMeetings() {
        if let m = ongoingMeeting() {
            if !isOn, m.id != autoMeetingID {
                autoMeetingID = m.id
                set(true, until: m.end, auto: true)
            } else if auto, m.end != until {
                autoMeetingID = m.id
                set(true, until: m.end, auto: true)
            }
        } else if auto, isOn {
            turnOff()
        }
    }

    // MARK: Summary

    /// One banner for everything held back. Waits until the island is closed (quiet is often
    /// turned off from the open island, where banners don't show).
    private func summarize() {
        let counts = Kind.allCases.compactMap { k in held[k].map { (kind: k, n: $0) } }
        held = [:]
        guard !counts.isEmpty else { return }
        var parts = counts.prefix(2).map { $0.kind.phrase($0.n) }
        let rest = counts.dropFirst(2).reduce(0) { $0 + $1.n }
        if rest > 0 { parts.append("\(rest) more") }
        let notice = Notice(icon: "moon.fill", tint: Self.tint, title: "While you were quiet",
                            subtitle: parts.joined(separator: " · "),
                            tab: counts.contains { $0.kind.isAgent } ? .agents : nil)
        whenClosed { [weak self] in
            // Quiet off ⇒ the gate lets it through.
            guard let self, !self.isActive else { return }
            self.env?.vm.notify(notice, duration: 6)
        }
    }

    /// Runs `body` once the island is closed, checking every 0.4 s (about one close animation).
    private func whenClosed(_ body: @escaping () -> Void) {
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] t in
            guard let vm = self?.env?.vm else { t.invalidate(); return }
            guard !vm.isOpen else { return }
            t.invalidate()
            body()
        }
    }

    // MARK: Shortcuts

    /// System Focus can't be switched with public API, so the person names a Shortcut that
    /// does it. Runs off main; a failure is kept for Settings, never interrupts.
    private func runShortcut(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            let err = Pipe()
            p.standardError = err
            var failure: String?
            do {
                try p.run()
                let data = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let reason = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = "Shortcut “\(name)” failed" + (reason.isEmpty ? "." : ": \(reason)")
                }
            } catch {
                failure = "Shortcut “\(name)” couldn't run: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { self?.shortcutError = failure }
        }
    }
}
