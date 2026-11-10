import AppKit
import EventKit
import SwiftUI
import Observation

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let meetingURL: URL?

    var isOngoing: Bool { start <= Date() && end > Date() }
}

@Observable
final class CalendarService {
    enum Access { case unknown, granted, denied }

    var access: Access = .unknown
    var events: [CalEvent] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?

    func start() {
        refreshAccess()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            requestAccess()
        } else {
            reload()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.reload() }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAccess()
                self?.reload()
            }
        }
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    func reload() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let mapped: [CalEvent] = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { ev in
                CalEvent(
                    id: (ev.eventIdentifier ?? UUID().uuidString) + "\(ev.startDate.timeIntervalSince1970)",
                    title: ev.title ?? "Untitled",
                    start: ev.startDate,
                    end: ev.endDate,
                    isAllDay: ev.isAllDay,
                    color: Color(cgColor: ev.calendar.cgColor),
                    meetingURL: Self.meetingURL(for: ev)
                )
            }
        if mapped != events { events = mapped }
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "whereby.com", "around.co", "meet.jit.si", "gotomeeting.com",
                                       "chime.aws", "slack.com/huddle", "discord.gg", "facetime.apple.com"]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func meetingURL(for ev: EKEvent) -> URL? {
        var candidates: [URL] = []
        if let u = ev.url { candidates.append(u) }
        for text in [ev.location, ev.notes].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            detector?.enumerateMatches(in: text, range: range) { m, _, _ in
                if let u = m?.url { candidates.append(u) }
            }
        }
        return candidates.first { u in meetingHosts.contains { u.absoluteString.contains($0) } }
    }
}
