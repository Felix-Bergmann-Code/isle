import AppKit
import SwiftUI

/// Owns every service and wires their events into the island.
final class AppEnvironment {
    let settings = AppSettings.shared
    let vm = IslandViewModel()
    let media = MediaService()
    let calendar = CalendarService()
    let battery = BatteryService()
    let volume = VolumeService()
    let keyTap = MediaKeyTap()
    let bluetooth = BluetoothWatcher()
    let agents = AgentMonitor()
    let hooks = HookServer(port: HookServer.defaultPort)
    let ports = PortsService()
    let shelf = ShelfStore()

    var openSettings: () -> Void = {}
    private var meetingTimer: Timer?
    private var alertedMeetings = Set<String>()

    func start() {
        media.start()
        calendar.start()

        battery.onPowerChange = { [weak self] plugged, level in
            guard let self, self.settings.showBatteryActivity else { return }
            self.vm.flash(.charging(level: level, pluggedIn: plugged), duration: 2.6)
        }
        battery.onLowBattery = { [weak self] level in
            self?.vm.flash(.lowBattery(level: level), duration: 3.5)
        }
        battery.start()

        volume.onChange = { [weak self] level, muted in
            guard let self, self.settings.showVolumeHUD else { return }
            self.vm.flash(.volume(level: level, muted: muted), duration: 1.6)
        }
        volume.start()

        keyTap.handler = { [weak self] key, isDown, fine in self?.handleMediaKey(key, isDown: isDown, fine: fine) ?? false }
        configureKeyTap(prompt: false)
        settings.onHUDChange = { [weak self] in self?.configureKeyTap(prompt: true) }

        bluetooth.onEvent = { [weak self] name, icon, connected in
            guard let self, self.settings.showBluetoothActivity else { return }
            self.vm.flash(.bluetooth(name: name, icon: icon, connected: connected), duration: 2.8)
        }
        if settings.showBluetoothActivity { bluetooth.start() }
        settings.onBluetoothChange = { [weak self] in
            guard let self else { return }
            self.settings.showBluetoothActivity ? self.bluetooth.start() : self.bluetooth.stop()
        }

        agents.onTransition = { [weak self] s, phase in self?.announce(s, phase: phase) }
        agents.start()
        hooks.onEvent = { [weak self] source, pid, payload in
            self?.agents.ingestHook(source: source, pid: pid, payload: payload)
        }
        hooks.onPermission = { [weak self] id, pid, payload in
            guard let self else { return false }
            guard self.agents.addPrompt(id: id, pid: pid, payload: payload) else { return false }
            self.announcePrompt(id)
            return true
        }
        hooks.onPermissionGone = { [weak self] id in self?.agents.dropPrompt(id: id) }
        agents.onPermissionDecision = { [weak self] id, decision in self?.hooks.decide(id, decision) }
        hooks.start()
        // Hooks installed by an older Isle lack the approval hook: add it (a backup is kept).
        if ClaudeHookInstaller.needsUpgrade { try? ClaudeHookInstaller.install() }

        meetingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkMeetings() }
    }

    // MARK: Agents

    /// A tool call is waiting for approval: show it right away, longer than other banners.
    private func announcePrompt(_ id: UUID) {
        guard let p = agents.prompts.first(where: { $0.id == id }) else { return }
        if settings.agentSound { NSSound(named: "Submarine")?.play() }
        guard settings.agentBanners, !vm.isOpen else { return }
        let project = p.cwd.isEmpty ? "Claude Code" : (p.cwd as NSString).lastPathComponent
        let what = p.summary.isEmpty ? p.toolLabel : "\(p.toolLabel): \(p.summary)"
        vm.flash(.agent(AgentBanner(kind: .claude, phase: .waiting, title: "\(project) wants approval",
                                    subtitle: "\(what) · hover to answer")), duration: 12)
    }

    private func announce(_ s: AgentSession, phase: AgentPhase) {
        guard settings.agentBanners, !vm.isOpen, !s.isBackground || settings.showBackgroundAgents else { return }
        let banner: AgentBanner
        switch phase {
        case .waiting:
            // Approval requests get their own banner (announcePrompt).
            guard agents.prompts(for: s).isEmpty else { return }
            banner = AgentBanner(kind: s.kind, phase: .waiting, title: "\(s.project) needs you", subtitle: s.detail)
        case .done:
            banner = AgentBanner(kind: s.kind, phase: .done, title: "\(s.project) is done",
                                 subtitle: s.lastMessage ?? "\(s.kind.name) finished its turn")
        default: return
        }
        vm.flash(.agent(banner), duration: phase == .waiting ? 7 : 4.5)
        if settings.agentSound {
            NSSound(named: phase == .waiting ? "Submarine" : "Glass")?.play()
        }
    }

    // MARK: HUD

    func configureKeyTap(prompt: Bool) {
        if settings.replaceSystemHUD { keyTap.start(prompt: prompt) } else { keyTap.stop() }
    }

    private func handleMediaKey(_ key: MediaKey, isDown: Bool, fine: Bool) -> Bool {
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard volume.canSetVolume else { return false }
            guard isDown else { return true }
            let step: Float = fine ? 1 / 64 : 1 / 16
            switch key {
            case .mute:
                volume.isMuted.toggle()
            case .volumeUp:
                if volume.isMuted { volume.isMuted = false }
                volume.volume = min(1, ((volume.volume + step) / step).rounded() * step)
            default:
                volume.volume = max(0, ((volume.volume - step) / step).rounded() * step)
                if volume.volume <= 0.001 { volume.isMuted = true }
            }
            // CoreAudio listener flashes the HUD; flash directly too in case the device doesn't notify.
            vm.flash(.volume(level: volume.volume, muted: volume.isMuted), duration: 1.6)
            return true
        case .brightnessUp, .brightnessDown:
            guard let cur = Brightness.current else { return false }
            guard isDown else { return true }
            let step: Float = fine ? 1 / 64 : 1 / 16
            let next = key == .brightnessUp ? min(1, cur + step) : max(0, cur - step)
            Brightness.set(next)
            vm.flash(.brightness(level: next), duration: 1.6)
            return true
        }
    }

    // MARK: Calendar

    private func checkMeetings() {
        guard settings.meetingReminders else { return }
        let now = Date()
        for ev in calendar.events where !ev.isAllDay && !alertedMeetings.contains(ev.id) {
            let mins = ev.start.timeIntervalSince(now) / 60
            if mins > 0 && mins <= 5 {
                alertedMeetings.insert(ev.id)
                vm.flash(.meeting(title: ev.title, minutes: max(1, Int(mins.rounded(.up)))), duration: 6)
                break
            }
        }
    }

    // MARK: Layout

    /// Single source of truth for the island's size and shape.
    func currentLayout() -> IslandLayout {
        let g = vm.geometry
        let nw = g.notchWidth
        let nh = g.notchHeight

        if vm.isOpen {
            return IslandLayout(mode: .open, bodyWidth: max(660, nw + 420), height: nh + 178,
                                topRadius: 14, bottomRadius: 30)
        }

        if let a = vm.activity {
            func sides(_ w: CGFloat) -> IslandLayout {
                IslandLayout(mode: .sides, bodyWidth: nw + w * 2, height: nh, topRadius: 7, bottomRadius: 11, sideWidth: w)
            }
            switch a {
            case .volume, .brightness: return sides(92)
            case .charging, .lowBattery: return sides(100)
            case .bluetooth: return sides(122)
            case .agent, .meeting, .shelf:
                return IslandLayout(mode: .banner, bodyWidth: max(nw + 200, 400), height: nh + 66,
                                    topRadius: 11, bottomRadius: 24)
            }
        }

        let playing = settings.showMusicActivity && (media.now?.isPlaying ?? false)
        let agentsActive = settings.showAgentActivity && agents.activeCount > 0
        if playing || agentsActive {
            let kind: CompactKind = playing && agentsActive ? .musicAndAgents : (playing ? .music : .agents)
            let side = kind == .music ? nh + 6 : nh + 22
            var l = IslandLayout(mode: .compact(kind), bodyWidth: nw + side * 2, height: nh,
                                 topRadius: 7, bottomRadius: 11, sideWidth: side)
            if vm.isHovering { l.bodyWidth += 12; l.height += 2 }
            return l
        }

        var l = IslandLayout(mode: .closed, bodyWidth: nw, height: nh, topRadius: 6, bottomRadius: 10)
        if vm.isHovering { l.bodyWidth += 18; l.height += 3 }
        l.visible = g.hasNotch || settings.showPillOnNonNotch || vm.isHovering
        return l
    }
}
