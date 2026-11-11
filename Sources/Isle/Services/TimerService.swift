import AppKit
import SwiftUI
import Observation

/// One running (or paused) timer. Codable so it survives a relaunch.
struct TimerRun: Codable, Equatable {
    /// The preset it was started with; names it ("25-minute timer") even after `add(minutes:)`.
    var minutes: Int
    var label: String?
    /// Length of the whole run in seconds, including added minutes. Drives the ring.
    var total: TimeInterval
    /// When it ends; nil while paused.
    var end: Date?
    /// Seconds left at the moment it was paused (only meaningful while `end` is nil).
    var remaining: TimeInterval

    static let breakLabel = "Break"

    var isPaused: Bool { end == nil }
    var isBreak: Bool { label == Self.breakLabel }
    var title: String { isBreak ? "\(minutes)-minute break" : (label ?? "\(minutes)-minute timer") }
    var tint: Color { isBreak ? AgentPhase.done.color : TimerService.tint }
    var icon: String { isBreak ? "cup.and.saucer.fill" : "timer" }

    func remaining(at date: Date) -> TimeInterval {
        end.map { max(0, $0.timeIntervalSince(date)) } ?? remaining
    }

    func progress(at date: Date) -> Double {
        total > 0 ? remaining(at: date) / total : 0
    }
}

/// A single countdown timer with an optional Pomodoro break. There is no per-second work
/// here: the end (and the switch to high priority in the final minute) are each one
/// scheduled work item on the wall clock, so they fire correctly after sleep. The ticking
/// digits are drawn by views that exist only while visible.
@Observable
final class TimerService {
    static let tint = Color(red: 1.0, green: 0.62, blue: 0.22)
    static let presets = [5, 15, 25, 45]

    private(set) var run: TimerRun?

    @ObservationIgnored private weak var vm: IslandViewModel?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var endWork: DispatchWorkItem?
    @ObservationIgnored private var urgentWork: DispatchWorkItem?
    @ObservationIgnored private let defaultsKey = "timerRun"
    /// A timer that ended while Isle wasn't running is still announced if it ended this recently.
    @ObservationIgnored private let lateGrace: TimeInterval = 5 * 60

    func start(vm: IslandViewModel, settings: AppSettings) {
        self.vm = vm
        self.settings = settings
        // Turning the feature off in Settings cancels whatever is running.
        settings.onTimerChange = { [weak self] in
            if self?.settings?.timerEnabled == false { self?.cancel() }
        }
        guard settings.timerEnabled,
              let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(TimerRun.self, from: data) else {
            persist()
            return
        }
        run = saved
        if let end = saved.end, end <= .now {
            if Date.now.timeIntervalSince(end) < lateGrace { finish() } else { update(nil) }
        } else {
            update(saved)
        }
    }

    // MARK: Controls

    func start(minutes: Int, label: String? = nil) {
        guard settings?.timerEnabled ?? false, minutes > 0 else { return }
        let total = TimeInterval(minutes * 60)
        update(TimerRun(minutes: minutes, label: label, total: total, end: .now + total, remaining: total))
    }

    func pause() {
        guard var r = run, let end = r.end else { return }
        r.remaining = max(0, end.timeIntervalSinceNow)
        r.end = nil
        update(r)
    }

    func resume() {
        guard var r = run, r.isPaused else { return }
        r.end = .now + r.remaining
        update(r)
    }

    func add(minutes: Int) {
        guard var r = run else { return }
        let extra = TimeInterval(minutes * 60)
        r.total += extra
        if let end = r.end { r.end = end + extra } else { r.remaining += extra }
        update(r)
    }

    func cancel() { update(nil) }

    // MARK: State

    /// The one place state changes: reschedule, publish to the compact slot, persist.
    private func update(_ new: TimerRun?) {
        run = new
        endWork?.cancel(); endWork = nil
        urgentWork?.cancel(); urgentWork = nil
        if let end = new?.end {
            endWork = schedule(at: end) { [weak self] in self?.finish() }
            let urgent = end - 60
            if urgent > .now { urgentWork = schedule(at: urgent) { [weak self] in self?.publish() } }
        }
        publish()
        persist()
    }

    private func schedule(at date: Date, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), execute: work)
        return work
    }

    /// Mirror the run into the compact slot. Paused shows a plain "Paused" (a ring beside it
    /// doesn't fit the slot), running shows the live countdown.
    private func publish() {
        guard let vm else { return }
        guard let r = run else { vm.clearLive("timer"); return }
        if let end = r.end {
            let finalMinute = end.timeIntervalSinceNow < 60.5
            vm.setLive(LiveItem(id: "timer", priority: finalMinute ? 90 : 60, icon: r.icon, tint: r.tint,
                                countdown: DateInterval(start: end - r.total, end: end), tab: .home))
        } else {
            vm.setLive(LiveItem(id: "timer", priority: 60, icon: r.icon, tint: r.tint, text: "Paused", tab: .home))
        }
    }

    private func persist() {
        if let run, let data = try? JSONEncoder().encode(run) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    private func finish() {
        guard let r = run, let settings else { return }
        withAnimation(Anim.micro) { update(nil) }
        if settings.timerSound { IsleSound.play("Glass") }
        if settings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        if settings.timerPomodoro, !r.isBreak, r.minutes == 25 {
            start(minutes: 5, label: TimerRun.breakLabel)
            vm?.notify(Notice(icon: "cup.and.saucer.fill", tint: AgentPhase.done.color,
                              title: "Time for a break", subtitle: "5 minutes", tab: .home), duration: 8)
        } else {
            vm?.notify(Notice(icon: "timer", tint: Self.tint, title: "Time's up",
                              subtitle: r.isBreak ? "Break's over" : r.title, tab: .home), duration: 8)
        }
    }
}
