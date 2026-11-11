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
    let hooks = HookServer(port: IsleInstance.hookPort)
    let ports = PortsService()
    let serverHealth = ServerHealth()
    let shelf = ShelfStore()
    lazy var nudger = WaitingNudger(agents: agents, vm: vm)
    let usage = UsageService()
    lazy var commands = CommandWatcher(vm: vm, settings: settings)
    let timer = TimerService()
    let downloads = DownloadsWatcher()
    let weather = WeatherService()
    let worldClocks = WorldClockStore()
    lazy var mirror = MirrorService(vm: vm, settings: settings)
    let quiet = QuietMode()
    let capture = CaptureMonitor()
    let ship = ShipService.shared
    let clipboard = ClipboardHistory()

    /// The page and search of the settings window, kept while it's closed.
    let settingsNav = SettingsNavigator()
    var openSettings: () -> Void = {}
    /// Closes the island and hands the keyboard back (set by NotchWindowManager).
    var closeIsland: () -> Void = {}
    private var meetingTimer: Timer?
    private var alertedMeetings = Set<String>()

    /// Opens the settings window on a page, optionally scrolled to (and flashing) one setting.
    func showSettings(_ page: SettingsPage, highlight: String? = nil) {
        settingsNav.search = ""
        settingsNav.show(page, highlight: highlight)
        openSettings()
    }

    func start() {
        vm.quietFilter = { [weak self] in self?.quiet.allows($0) ?? true }
        quiet.start(env: self)
        IsleSound.isMuted = { [weak self] in self?.quiet.isActive ?? false }
        media.start()
        calendar.start()
        weather.start()

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
        DiffService.shared.start(agents: agents, vm: vm)
        nudger.start()
        ship.start(agents: agents, vm: vm)
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
        hooks.onCommand = { [weak self] payload in self?.commands.ingest(payload) }
        hooks.start()
        if !IsleInstance.isDev { ShellHookInstaller.refreshIfInstalled() }
        // Hooks installed by an older Isle lack newer events (approvals, subagents): add them (a backup is kept).
        if !IsleInstance.isDev, ClaudeHookInstaller.needsUpgrade { try? ClaudeHookInstaller.install() }
        usage.start(vm: vm)

        serverHealth.start(ports: ports, vm: vm)

        timer.start(vm: vm, settings: settings)

        startDownloads()

        startCaptureIndicator()

        clipboard.setWatching(settings.clipboardHistory)
        settings.onClipboardChange = { [weak self] in
            guard let self else { return }
            self.clipboard.setWatching(self.settings.clipboardHistory)
        }

        meetingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkMeetings() }
    }

    // MARK: Agents

    /// A tool call is waiting for approval: show it right away, longer than other banners.
    private func announcePrompt(_ id: UUID) {
        guard let p = agents.prompts.first(where: { $0.id == id }), !nudger.suppressesBanners else { return }
        if settings.agentSound { play("Submarine") }
        guard settings.agentBanners, !vm.isOpen else { return }
        let project = p.cwd.isEmpty ? "Claude Code" : (p.cwd as NSString).lastPathComponent
        let what = p.summary.isEmpty ? p.toolLabel : "\(p.toolLabel): \(p.summary)"
        let who = p.agentType.map { "\(project) · \($0)" } ?? project
        vm.flash(.agent(AgentBanner(kind: .claude, phase: .waiting, title: "\(who) wants approval",
                                    subtitle: "\(what) · hover to answer", isApproval: true)), duration: 12)
    }

    private func announce(_ s: AgentSession, phase: AgentPhase) {
        if nudger.absorb(s, phase: phase) { return } // screen locked: summed up on return
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
            play(phase == .waiting ? "Submarine" : "Glass")
        }
    }

    /// Every sound goes through here, so quiet mode silences all of them.
    func play(_ soundName: String) { IsleSound.play(soundName) }

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

    /// Who gets the two sides of the notch while closed. Left: music art, else agent faces,
    /// else the top live item's icon. Right: agents that need you, else the top live item,
    /// else the agent count, else the audio bars.
    func compactContent() -> CompactContent? {
        let playing = settings.showMusicActivity && (media.now?.isPlaying ?? false)
        let agentsActive = settings.showAgentActivity && agents.activeCount > 0
        let top = vm.topLive
        let lead: CompactLead
        if playing { lead = .artwork }
        else if agentsActive { lead = .agents }
        else if let top { lead = .live(top.id) }
        else { return nil }

        let trail: CompactTrail
        if agentsActive && agents.needsAttention { trail = .agentCount }
        else if let top { trail = .live(top.id) }
        else if agentsActive { trail = .agentCount }
        else { trail = .audioBars }
        return CompactContent(lead: lead, trail: trail)
    }

    /// Single source of truth for the island's size and shape.
    func currentLayout() -> IslandLayout {
        let g = vm.geometry
        let nw = g.notchWidth
        let nh = g.notchHeight

        if vm.isOpen {
            // 700 wide leaves each header half ~240 pt beside a hardware notch: room for the
            // tab's glance, a running timer and quiet mode next to the battery.
            return IslandLayout(mode: .open, bodyWidth: max(700, nw + 460), height: nh + 178,
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
            case .agent, .meeting, .shelf, .notice:
                return IslandLayout(mode: .banner, bodyWidth: max(nw + 200, 400), height: nh + 66,
                                    topRadius: 11, bottomRadius: 24)
            }
        }

        if let content = compactContent() {
            func need(_ lead: CompactLead) -> CGFloat {
                switch lead {
                case .artwork: return nh + 6
                case .agents: return nh + 22
                case .live(let id): return vm.liveItem(id)?.style == .dot ? LiveDot.side : nh + 6
                }
            }
            func need(_ trail: CompactTrail) -> CGFloat {
                switch trail {
                case .audioBars: return nh + 6
                case .agentCount: return nh + 22
                case .live(let id):
                    // Room for the ring and ~5 characters; longer text ("2 · 68%") widens the sides.
                    guard let item = vm.liveItem(id) else { return nh + 6 }
                    if item.style == .dot { return LiveDot.side }
                    guard item.hasText else { return nh + 6 }
                    // Sized from the text, not the notch height, so "24:13" or "2 · 68%" never
                    // truncates on short menu bars: ~7 pt per character at 12 pt rounded semibold,
                    // plus the ring and paddings.
                    let chars = item.countdown != nil ? 5 : (item.text?.count ?? 0)
                    return max(nh + 6, 34 + CGFloat(max(4, chars)) * 7)
                }
            }
            let side = max(need(content.lead), need(content.trail))
            var l = IslandLayout(mode: .compact(content), bodyWidth: nw + side * 2, height: nh,
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

/// The one place Isle plays sounds, so services without an `env` reference still respect
/// quiet mode. `AppEnvironment.start()` sets `isMuted`.
enum IsleSound {
    static var isMuted: () -> Bool = { false }
    static func play(_ name: String) {
        guard !isMuted() else { return }
        NSSound(named: name)?.play()
    }
}

/// Development aid: launched with `ISLE_INSTANCE=<name>` (e.g. `open -n --env ISLE_INSTANCE=dev
/// build/Isle.app`), a build runs beside the installed Isle without fighting it: it listens on
/// the next hook port, takes commands on its own channel (`ISLE_INSTANCE=dev scripts/isle …`)
/// and never rewrites the Claude Code or shell hook installs.
enum IsleInstance {
    static let name: String? = ProcessInfo.processInfo.environment["ISLE_INSTANCE"].flatMap { $0.isEmpty ? nil : $0 }
    static var isDev: Bool { name != nil }
    static var commandName: String { "io.github.felix-bergmann-code.isle.command" + (name.map { ".\($0)" } ?? "") }
    static var hookPort: UInt16 { isDev ? HookServer.defaultPort + 1 : HookServer.defaultPort }
}

/// Dev builds (`ISLE_INSTANCE`) log every banner and live item to
/// ~/Library/Logs/Isle-<instance>.log, so features can be checked from a script.
enum DevLog {
    private static let url: URL? = IsleInstance.name.map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Isle-\($0).log")
    }
    private static let queue = DispatchQueue(label: "isle.devlog")

    static func write(_ line: String) {
        guard let url else { return }
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: url) }
        }
    }

    static func describe(_ a: Activity) -> String {
        switch a {
        case .notice(let n): return "notice “\(n.title)” · \(n.subtitle)\(n.trailing.map { " · \($0)" } ?? "")"
        case .agent(let b): return "agent “\(b.title)” · \(b.subtitle)"
        case .meeting(let t, let m): return "meeting “\(t)” in \(m)m"
        case .shelf(let n): return "shelf \(n)"
        case .charging(let l, let p): return "charging \(l)% plugged=\(p)"
        case .lowBattery(let l): return "low battery \(l)%"
        case .bluetooth(let n, _, let c): return "bluetooth \(n) connected=\(c)"
        case .volume, .brightness: return "hud"
        }
    }

    static func describe(_ i: LiveItem) -> String {
        "\(i.id) p\(i.priority) \(i.icon) text=\(i.text ?? "-") progress=\(i.progress.map { String(format: "%.2f", $0) } ?? "-")\(i.countdown != nil ? " countdown" : "")"
    }
}
