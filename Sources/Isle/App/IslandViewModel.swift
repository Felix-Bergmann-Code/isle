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

    var preferredTab: IslandTab? {
        switch self {
        case .agent: return .agents
        case .shelf: return .shelf
        case .meeting: return .home
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
}

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 32
    var hasNotch = false
    var screenFrame: CGRect = .zero
}

enum CompactKind: Equatable { case music, agents, musicAndAgents }

enum IslandMode: Equatable {
    case closed, compact(CompactKind), sides, banner, open
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

    @ObservationIgnored private var token = 0
    @ObservationIgnored private var dismissWork: DispatchWorkItem?

    func flash(_ activity: Activity, duration: TimeInterval) {
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

    func dismissActivity() {
        dismissWork?.cancel()
        withAnimation(Anim.close) { activity = nil }
    }

    func open(tab: IslandTab? = nil) {
        withAnimation(Anim.open) {
            if let tab { self.tab = tab }
            else if let preferred = activity?.preferredTab { self.tab = preferred }
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
