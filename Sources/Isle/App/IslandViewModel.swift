import AppKit
import SwiftUI
import Observation

enum IslandTab: String, CaseIterable, Identifiable {
    case home, agents, shelf
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .agents: return "sparkles"
        case .shelf: return "tray.fill"
        }
    }
    var title: String {
        switch self {
        case .home: return "Home"
        case .agents: return "Agents"
        case .shelf: return "Shelf"
        }
    }
}

/// Short-lived things the island announces while closed (iOS "live activity" style).
enum Activity: Equatable {
    case volume(level: Float, muted: Bool)
    case brightness(level: Float)
    case charging(level: Int, pluggedIn: Bool)
    case lowBattery(level: Int)
    case bluetooth(name: String, icon: String, connected: Bool)
    case agent(AgentBanner)
    case meeting(title: String, minutes: Int)
    case shelf(count: Int)
    /// Generic banner any feature can raise (see `IslandViewModel.notify`).
    case notice(Notice)

    var preferredTab: IslandTab? {
        switch self {
        case .agent: return .agents
        case .shelf: return .shelf
        case .meeting: return .home
        case .notice(let n): return n.tab
        default: return nil
        }
    }

    var isHUD: Bool {
        if case .volume = self { return true }
        if case .brightness = self { return true }
        return false
    }
}

struct AgentBanner: Equatable {
    var id = UUID()
    var kind: AgentKind
    var phase: AgentPhase
    var title: String
    var subtitle: String
    /// A tool call waiting for approval (quiet mode can let these through).
    var isApproval = false
}

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 32
    var hasNotch = false
    var screenFrame: CGRect = .zero
}

/// What sits left and right of the notch while the island is closed.
/// Left says *who* (album art, agent faces, a live item's icon); right says *how it's going*.
enum CompactLead: Equatable { case artwork, agents, live(String) }
enum CompactTrail: Equatable { case audioBars, agentCount, live(String) }
struct CompactContent: Equatable {
    var lead: CompactLead
    var trail: CompactTrail
}

enum IslandMode: Equatable {
    case closed, compact(CompactContent), sides, banner, open
}

struct IslandLayout: Equatable {
    var mode: IslandMode
    /// Width of the body, without the concave "ears" at the top corners.
    var bodyWidth: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var sideWidth: CGFloat = 0
    var visible = true
    var width: CGFloat { bodyWidth + topRadius * 2 }
}

@Observable
final class IslandViewModel {
    var isOpen = false
    var isHovering = false
    var tab: IslandTab = .home
    var tabDirection: CGFloat = 1
    var activity: Activity?
    var dropTargeted = false
    var geometry = NotchGeometry()
    /// Ongoing things that compete for the compact slot beside the notch (timer, download…).
    var live: [LiveItem] = []
    /// Views with a text field on screen claim the keyboard by id (onAppear / onDisappear), so
    /// two such views swapping can't clear each other's claim. While any claim exists the panel
    /// may take the keyboard when clicked.
    private(set) var keyboardClaims: Set<String> = []
    var wantsKeyboard: Bool { !keyboardClaims.isEmpty }
    func claimKeyboard(_ id: String, _ claim: Bool = true) {
        if claim { keyboardClaims.insert(id) } else { keyboardClaims.remove(id) }
    }
    /// A text field has focus: the island stays open until Esc, Return or a click outside.
    /// Bind it to the field's @FocusState.
    var isEditingText = false

    /// Quiet mode's gate, set by AppEnvironment: return false to hold a banner back.
    /// Every banner passes `flash`, so new ones are covered; HUDs skip it (they answer a key press).
    @ObservationIgnored var quietFilter: ((Activity) -> Bool)?

    @ObservationIgnored private var token = 0
    @ObservationIgnored private var dismissWork: DispatchWorkItem?

    func flash(_ activity: Activity, duration: TimeInterval) {
        if !activity.isHUD, let quietFilter, !quietFilter(activity) {
            DevLog.write("held back by quiet: \(DevLog.describe(activity))")
            return
        }
        if !activity.isHUD { DevLog.write("banner: \(DevLog.describe(activity))") }
        token &+= 1
        let current = token
        // Re-flashing the same HUD (e.g. holding volume up) should retarget, not re-pop.
        withAnimation(Anim.island) { self.activity = activity }
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.token == current else { return }
            withAnimation(Anim.close) { self.activity = nil }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Raise a banner. Skipped while the island is open (the open island already shows everything).
    /// This is the one door every feature's banner goes through.
    func notify(_ notice: Notice, duration: TimeInterval = 4.5) {
        guard !isOpen else {
            DevLog.write("skipped (island open): \(notice.title)")
            return
        }
        flash(.notice(notice), duration: duration)
    }

    /// The live item that wins the compact slot: highest priority, newest on ties.
    var topLive: LiveItem? {
        live.enumerated().max { a, b in
            a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.offset < b.offset
        }?.element
    }

    func liveItem(_ id: String) -> LiveItem? { live.first { $0.id == id } }

    /// Add or update a live item (matched by id).
    func setLive(_ item: LiveItem) {
        if let i = live.firstIndex(where: { $0.id == item.id }) {
            guard live[i] != item else { return }
            if live[i].text != item.text || live[i].icon != item.icon || live[i].priority != item.priority {
                DevLog.write("live update: \(DevLog.describe(item))")
            }
            live[i] = item
        } else {
            DevLog.write("live add: \(DevLog.describe(item))")
            withAnimation(Anim.island) { live.append(item) }
        }
    }

    func clearLive(_ id: String) {
        guard live.contains(where: { $0.id == id }) else { return }
        DevLog.write("live clear: \(id)")
        withAnimation(Anim.island) { live.removeAll { $0.id == id } }
    }

    func dismissActivity() {
        dismissWork?.cancel()
        withAnimation(Anim.close) { activity = nil }
    }

    func open(tab: IslandTab? = nil) {
        withAnimation(Anim.open) {
            if let tab { self.tab = tab }
            else if let preferred = activity?.preferredTab ?? (activity == nil ? topLive?.tab : nil) { self.tab = preferred }
            isOpen = true
            if !(activity?.isHUD ?? false) { activity = nil }
        }
    }

    func close() {
        withAnimation(Anim.close) {
            isOpen = false
            isHovering = false
        }
    }

    func select(_ newTab: IslandTab) {
        guard newTab != tab else { return }
        let all = IslandTab.allCases
        tabDirection = (all.firstIndex(of: newTab) ?? 0) > (all.firstIndex(of: tab) ?? 0) ? 1 : -1
        withAnimation(Anim.tab) { tab = newTab }
    }

    func cycleTab(_ delta: Int) {
        let all = IslandTab.allCases
        guard let i = all.firstIndex(of: tab) else { return }
        let next = i + delta
        guard all.indices.contains(next) else { return }
        select(all[next])
    }
}
