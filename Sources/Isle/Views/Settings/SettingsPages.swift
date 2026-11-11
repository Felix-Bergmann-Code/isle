import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Permission hint

/// Under a feature that's on but can't work yet: what's missing and the button that fixes it.
/// Shows nothing once the permission is granted.
struct PermissionHint: View {
    let permission: Permission
    let env: AppEnvironment
    /// Optional wording when the feature still works without it, just less well.
    var fallback: String?

    var body: some View {
        let center = PermissionCenter.shared
        let status = center.status(permission)
        if status != .granted {
            HStack(spacing: 8) {
                Image(systemName: status == .denied || permission == .accessibility ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(status == .denied || permission == .accessibility ? .orange : .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message(status)).font(.callout)
                    if let fallback { Text(fallback).font(.caption).foregroundStyle(.secondary) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if status == .denied {
                    Button("Open System Settings…") { permission.pane.open() }
                } else {
                    Button(permission == .accessibility ? "Allow…" : "Ask Now") { center.request(permission, env: env) }
                }
                SettingsLink(title: "", page: .permissions, anchor: permission.rawValue)
                    .help("Details in Privacy & Permissions")
            }
            .controlSize(.small)
        }
    }

    private func message(_ status: PermissionStatus) -> String {
        switch status {
        case .denied: return "\(permission.title) access is turned off for Isle"
        default: return permission == .accessibility ? "Needs Accessibility access" : "macOS will ask for \(permission.title) access"
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .general) {
            Section("Display") {
                Picker(selection: $settings.screenMode) {
                    ForEach(ScreenMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel(title: "Show the island on", symbol: "display", color: .blue)
                }
                .settingAnchor("screen")
                SettingToggle("Pill on displays without a notch",
                              subtitle: "A small black pill at the top of external displays stands in for the notch.",
                              symbol: "capsule.fill", color: .gray, isOn: $settings.showPillOnNonNotch)
                    .settingAnchor("pill")
            }

            Section("Opening") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $settings.hoverDelay, in: 0...0.5)
                        Text("\(Int(settings.hoverDelay * 1000)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .frame(width: 210)
                } label: {
                    SettingLabel(title: "Hover delay", subtitle: "How long the pointer rests on the notch before it opens.",
                                 symbol: "cursorarrow.rays", color: .blue)
                }
                .settingAnchor("hover")
                SettingToggle("Haptic feedback",
                              subtitle: "A light tap on the trackpad as the island opens and when you swipe between tabs.",
                              symbol: "hand.tap.fill", color: .pink, isOn: $settings.haptics)
                    .settingAnchor("haptics")
            }

            Section("Gestures") {
                InfoRow(symbol: "cursorarrow.motionlines", color: .indigo, title: "Hover or click the notch",
                        detail: "Opens the island. Clicking opens it at once.")
                InfoRow(symbol: "hand.draw.fill", color: .purple, title: "Swipe with two fingers",
                        detail: "Left or right switches between Home, Agents and Shelf.")
                InfoRow(symbol: "doc.on.doc.fill", color: .yellow, title: "Drag files onto the notch",
                        detail: "Parks them on the Shelf, ready to drag out or AirDrop later.")
            }
            .settingAnchor("gestures")

            Section("Startup") {
                Toggle(isOn: $launchAtLogin) {
                    SettingLabel(title: "Launch at login", subtitle: "Start Isle when you log in to your Mac.",
                                 symbol: "power", color: .green)
                }
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                .settingAnchor("login")
                if PermissionCenter.shared.loginItem == .requiresApproval {
                    HStack {
                        SettingNote("macOS is waiting for you to allow Isle in Login Items.",
                                    symbol: "exclamationmark.triangle.fill", color: .orange)
                        Spacer()
                        Button("Open Login Items…") { SystemSettingsPane.loginItems.open() }.controlSize(.small)
                    }
                }
                if let loginError {
                    SettingNote(loginError, symbol: "xmark.octagon.fill", color: .red)
                }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        PermissionCenter.shared.refresh(env: env)
    }
}

// MARK: - Live Activities

struct ActivitiesPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .activities) {
            Section {
                SettingToggle("Now Playing", subtitle: "Album art and a visualizer while Spotify or Music plays.",
                              symbol: "music.note", color: .pink, isOn: $settings.showMusicActivity)
                    .settingAnchor("music")
                SettingToggle("Running agents", subtitle: "Avatars of the coding agents that are working, and how many.",
                              symbol: "sparkles", color: .purple, isOn: $settings.showAgentActivity)
                    .settingAnchor("agents")
                SettingToggle("Microphone & camera in use",
                              subtitle: "An orange or green dot beside the notch while any app records. Needs no permission.",
                              symbol: "mic.fill", color: .orange, isOn: $settings.showCaptureIndicator)
                    .settingAnchor("capture")
            } header: {
                Text("In the notch")
            } footer: {
                SettingNote("One more thing can join them on the right: a running timer, a download's progress or the microphone dot.")
            }

            Section("Banners") {
                SettingToggle("Charging & low battery", subtitle: "When you plug in or unplug, and when the battery runs low.",
                              symbol: "battery.100percent.bolt", color: .green, isOn: $settings.showBatteryActivity)
                    .settingAnchor("battery")
                SettingToggle("Bluetooth devices", subtitle: "When AirPods, a keyboard or a mouse connects or disconnects.",
                              symbol: "airpods", color: .blue, isOn: $settings.showBluetoothActivity)
                    .settingAnchor("bluetooth")
                if settings.showBluetoothActivity { PermissionHint(permission: .bluetooth, env: env) }
                SettingToggle("Meeting reminders", subtitle: "5 minutes before an event in your calendar starts.",
                              symbol: "calendar", color: .red, isOn: $settings.meetingReminders)
                    .settingAnchor("meetings")
                if settings.meetingReminders { PermissionHint(permission: .calendar, env: env) }
            }
        }
    }
}

// MARK: - Volume & Brightness

struct HUDPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .hud) {
            Section {
                SettingToggle("Show volume changes", subtitle: "A level bar beside the notch whenever the volume changes.",
                              symbol: "speaker.wave.2.fill", color: .pink, isOn: $settings.showVolumeHUD)
                    .settingAnchor("volume")
                SettingToggle("Replace the system HUD",
                              subtitle: "Isle takes over the volume and brightness keys, so only the island shows. Brightness works on the built-in display while the lid is open.",
                              symbol: "sun.max.fill", color: .orange, isOn: $settings.replaceSystemHUD)
                    .settingAnchor("replace")
                if settings.replaceSystemHUD {
                    if PermissionCenter.shared.accessibility {
                        LabeledContent {
                            StatusBadge(text: env.keyTap.isRunning ? "Active" : "Starting…",
                                        color: env.keyTap.isRunning ? .green : .secondary, symbol: "checkmark.circle.fill")
                        } label: {
                            Text(env.keyTap.isRunning ? "Isle is handling the volume and brightness keys"
                                 : "Accessibility is allowed; the keys are picked up in a moment")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        PermissionHint(permission: .accessibility, env: env)
                    }
                }
            }

            Section("Keys") {
                LabeledContent {
                    HStack(spacing: 4) {
                        KeyCap("⌥"); KeyCap("⇧"); Text("+").foregroundStyle(.secondary); KeyCap(symbol: "speaker.wave.2")
                    }
                } label: {
                    SettingLabel(title: "Fine steps", subtitle: "Hold Option and Shift while pressing a volume or brightness key for quarter steps.",
                                 symbol: "slider.horizontal.3", color: .gray)
                }
            }
        }
    }
}

/// A keyboard key, for shortcuts shown in settings.
struct KeyCap: View {
    var text: String?
    var symbol: String?

    init(_ text: String) { self.text = text }
    init(symbol: String) { self.symbol = symbol }

    var body: some View {
        Group {
            if let text { Text(text) } else if let symbol { Image(systemName: symbol) }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(minWidth: 22, minHeight: 20)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
    }
}

// MARK: - Agents

struct AgentsPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .agents, accessory: AnyView(detected)) {
            Section("Banners") {
                SettingToggle("When an agent finishes or needs you", subtitle: "Drops down from the notch with what happened.",
                              symbol: "bell.badge.fill", color: .red, isOn: $settings.agentBanners)
                    .settingAnchor("banners")
                SettingToggle("Play a sound", symbol: "speaker.wave.2.fill", color: .pink, isOn: $settings.agentSound)
                    .disabled(!settings.agentBanners)
                    .settingAnchor("sound")
                SettingToggle("Remind me when an agent keeps waiting",
                              subtitle: "Pulses the notch after 3 minutes, shows the banner again at 5 and 20, and sums up what happened while your screen was locked.",
                              symbol: "clock.badge.exclamationmark.fill", color: .orange, isOn: $settings.waitingNudges)
                    .settingAnchor("nudges")
            }

            Section("Answer from the island") {
                SettingToggle("Approve Claude Code tool calls",
                              subtitle: "Allow or deny in the island. Requests wait up to \(Int(HookServer.permissionHold / 60)) minutes, then go back to Claude Code's own prompt.",
                              symbol: "checkmark.shield.fill", color: .green, isOn: $settings.agentApprovals)
                    .settingAnchor("approvals")
                if settings.agentApprovals, !PermissionCenter.shared.claudeHooks {
                    HStack {
                        SettingNote("Needs the Claude Code hooks.", symbol: "exclamationmark.triangle.fill", color: .orange)
                        Spacer()
                        SettingsLink(title: "Install", page: .integrations, anchor: "claude")
                    }
                }
                SettingToggle("Reply to questions",
                              subtitle: "When Claude Code ends a turn on a question, answer it under the session. iTerm2 gets it typed in; Terminal and the Claude app get it pasted.",
                              symbol: "arrowshape.turn.up.left.fill", color: .blue, isOn: $settings.agentReplies)
                    .settingAnchor("replies")
                if settings.agentReplies {
                    PermissionHint(permission: .accessibility, env: env,
                                   fallback: "Without it, your reply is copied for you to paste.")
                }
            }

            Section("On each agent") {
                SettingToggle("Uncommitted changes", subtitle: "Lines added and removed in the agent's repo (+12 −3), refreshed while it works.",
                              symbol: "plusminus", color: .orange, isOn: $settings.showAgentDiffs)
                    .settingAnchor("diffs")
                SettingToggle("Context & token usage",
                              subtitle: "A ring once a Claude session's context is half full, and today's tokens in the header. The cost is an estimate at API prices.",
                              symbol: "gauge.with.dots.needle.50percent", color: .teal, isOn: $settings.showUsageMeter)
                    .settingAnchor("usage")
                SettingToggle("Checks, pull requests & deploys",
                              subtitle: "CI status and the PR on each branch, with banners when checks fail, a PR merges or a preview is ready. Uses the GitHub CLI.",
                              symbol: "arrow.triangle.pull", color: Color(white: 0.25), isOn: $settings.showShipStatus)
                    .settingAnchor("github")
                    .onAppear { ShipService.shared.recheckCLI() }
                    .onChange(of: settings.showShipStatus) { ShipService.shared.recheckCLI() }
                if settings.showShipStatus, ShipService.shared.cli == .missing || ShipService.shared.cli == .signedOut {
                    SettingNote(ShipService.shared.cli == .missing
                                ? "Install the [GitHub CLI](https://cli.github.com), then run `gh auth login`."
                                : "Run `gh auth login` in a terminal to sign in.",
                                symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }

            Section {
                SettingToggle("Background agents when idle", subtitle: "Also list agents with no terminal of their own, such as Codex in VS Code.",
                              symbol: "eye.fill", color: .gray, isOn: $settings.showBackgroundAgents)
                    .settingAnchor("background")
                HStack(spacing: 11) {
                    SettingsIcon(symbol: "bolt.fill", color: .yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instant status for Claude Code")
                        Text(PermissionCenter.shared.claudeHooks
                             ? "Hooks are installed: \"needs you\" and \"finished\" are exact and instant."
                             : "Without hooks, status is inferred from transcripts and CPU activity.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if PermissionCenter.shared.claudeHooks {
                        StatusBadge(text: "Installed", color: .green, symbol: "checkmark.circle.fill")
                    } else {
                        SettingsLink(title: "Set up", page: .integrations, anchor: "claude")
                    }
                }
            } header: {
                Text("Detection")
            } footer: {
                SettingNote("Claude Code, Codex, Gemini CLI, Cursor Agent, Aider, opencode, Copilot CLI, Amp and Goose are found automatically.")
            }

            Section("Dev servers") {
                SettingToggle("Show local dev servers", subtitle: "Every localhost port started from a project folder, with its health and open and stop buttons.",
                              symbol: "server.rack", color: .teal, isOn: $settings.showDevServers)
                    .settingAnchor("devservers")
                SettingToggle("Warn when a dev server stops", subtitle: "A banner if a server goes away without you stopping it in Isle.",
                              symbol: "exclamationmark.triangle.fill", color: .orange, isOn: $settings.warnDevServerStops)
                    .disabled(!settings.showDevServers)
                    .settingAnchor("devwarn")
            }
        }
    }

    private var detected: some View {
        let n = env.agents.visibleSessions.count
        return HStack(spacing: 6) {
            Circle().fill(n > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(n == 0 ? "No agents running right now" : n == 1 ? "1 agent running right now" : "\(n) agents running right now")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Home

struct HomePage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .home) {
            WeatherClocksSettings(env: env)

            Section("Calendar") {
                HStack(spacing: 11) {
                    SettingsIcon(symbol: "calendar", color: .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today and tomorrow on Home")
                        Text(calendarText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch env.calendar.access {
                    case .granted: Button("Open Calendar") { env.calendar.openCalendarApp() }
                    case .unknown: Button("Allow Access…") { env.calendar.requestAccess() }.buttonStyle(.borderedProminent)
                    case .denied: Button("Open System Settings…") { env.calendar.openPrivacySettings() }
                    }
                }
                .settingAnchor("calendar")
                LabeledContent {
                    SettingsLink(title: settings.meetingReminders ? "On" : "Off", page: .activities, anchor: "meetings")
                } label: {
                    SettingLabel(title: "Meeting reminders", symbol: "bell.fill", color: .red)
                }
            }

            Section("Timer") {
                SettingToggle("Timer", subtitle: "The timer glyph in the Home header unfolds into 5, 15, 25 and 45 minute presets.",
                              symbol: "timer", color: .orange, isOn: $settings.timerEnabled)
                    .settingAnchor("timer")
                SettingToggle("Play a sound when it ends", symbol: "speaker.wave.2.fill", color: .pink, isOn: $settings.timerSound)
                    .disabled(!settings.timerEnabled)
                SettingToggle("Take a 5-minute break after 25 minutes", subtitle: "Starts a short break timer after each 25-minute one.",
                              symbol: "cup.and.saucer.fill", color: .brown, isOn: $settings.timerPomodoro)
                    .disabled(!settings.timerEnabled)
            }

            Section("Camera mirror") {
                SettingToggle("Camera mirror before meetings",
                              subtitle: "A camera button on meetings with a video link that start within 15 minutes. The camera runs only while the mirror is on screen.",
                              symbol: "camera.fill", color: .green, isOn: $settings.cameraMirror)
                    .settingAnchor("mirror")
                if settings.cameraMirror { PermissionHint(permission: .camera, env: env) }
            }
        }
    }

    private var calendarText: String {
        switch env.calendar.access {
        case .granted: return "Events from all your calendars, with their video call links."
        case .unknown: return "Isle needs access to your calendars to show them."
        case .denied: return "Calendar access is turned off for Isle."
        }
    }
}

// MARK: - Shelf

struct ShelfPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .shelf) {
            Section("Files") {
                HStack(spacing: 11) {
                    SettingsIcon(symbol: "tray.full.fill", color: Color(red: 0.93, green: 0.66, blue: 0.05))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.shelf.items.isEmpty ? "The Shelf is empty"
                             : env.shelf.items.count == 1 ? "1 item on the Shelf" : "\(env.shelf.items.count) items on the Shelf")
                        Text("Drag files onto the notch to park them; drag them out or AirDrop them later.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Shelf") { env.shelf.clear() }.disabled(env.shelf.items.isEmpty)
                }
                .settingAnchor("items")
            }

            Section {
                SettingToggle("Clipboard history",
                              subtitle: "Your last 30 copies, text and images, with shortcuts to format JSON, decode a JWT or open a link.",
                              symbol: "doc.on.clipboard.fill", color: .blue, isOn: $settings.clipboardHistory)
                    .settingAnchor("clipboard")
            } header: {
                Text("Clipboard")
            } footer: {
                SettingNote("Kept in memory only and cleared when Isle quits. Password managers are skipped.", symbol: "lock.fill")
            }

            Section("Note") {
                SettingToggle("Note", subtitle: "One plain-text note beside your files, saved as you type. `isle note` opens it ready to type.",
                              symbol: "note.text", color: Color(red: 0.93, green: 0.66, blue: 0.05), isOn: $settings.scratchpadNote)
                    .settingAnchor("note")
                LabeledContent {
                    Button("Show in Finder") { revealInFinder(NoteStore.fileURL) }.controlSize(.small)
                } label: {
                    Text(NoteStore.fileURL.tildePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Downloads") {
                SettingToggle("Download progress in the notch",
                              subtitle: "A ring beside the notch while Safari, Chrome, Firefox and others download to ~/Downloads.",
                              symbol: "arrow.down.circle.fill", color: .cyan, isOn: $settings.showDownloads)
                    .settingAnchor("downloads")
                SettingToggle("Put finished downloads on the Shelf", symbol: "tray.and.arrow.down.fill", color: .blue,
                              isOn: $settings.downloadsToShelf)
                    .disabled(!settings.showDownloads)
                if settings.showDownloads { PermissionHint(permission: .downloads, env: env) }
            }
        }
    }
}

// MARK: - Quiet mode

struct QuietPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .quiet) {
            Section {
                SettingToggle("Quiet mode", subtitle: "A moon in the open island's header. Click it to go quiet; right-click for 1 hour or until tomorrow.",
                              symbol: "moon.fill", color: .indigo, isOn: $settings.quietMode)
                    .onChange(of: settings.quietMode) { _, on in if !on { env.quiet.turnOff() } }
                    .settingAnchor("quiet")
                if settings.quietMode {
                    LabeledContent {
                        Button(env.quiet.isActive ? "Turn Off" : "Go Quiet Now") { env.quiet.toggle() }
                    } label: {
                        Text(env.quiet.isActive ? "Quiet right now" : "Not quiet right now")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                SettingNote("Holds back banners and sounds, then sums them up when quiet ends. Volume, brightness and live activities still show.")
            }

            Group {
                Section("While quiet") {
                    SettingToggle("Still show approval requests", symbol: "checkmark.shield.fill", color: .green,
                                  isOn: $settings.quietAllowApprovals)
                        .settingAnchor("exceptions")
                    SettingToggle("Still show meeting reminders", symbol: "calendar", color: .red, isOn: $settings.quietAllowMeetings)
                }

                Section("Automatically") {
                    SettingToggle("During calendar meetings", subtitle: "While an event with a video call link is running.",
                                  symbol: "video.fill", color: .green, isOn: $settings.quietDuringMeetings)
                        .settingAnchor("meetings")
                    if settings.quietDuringMeetings { PermissionHint(permission: .calendar, env: env) }
                }

                Section {
                    shortcutField("When quiet starts", symbol: "play.fill", text: $settings.quietStartShortcut)
                        .settingAnchor("shortcuts")
                    shortcutField("When quiet ends", symbol: "stop.fill", text: $settings.quietEndShortcut)
                    if let error = env.quiet.shortcutError {
                        SettingNote(error, symbol: "xmark.octagon.fill", color: .red)
                    }
                } header: {
                    Text("Run a Shortcut")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        SettingNote("Apps can't switch macOS Focus, but a Shortcut can, for example one that turns on Do Not Disturb.")
                        Spacer()
                        Button("Open Shortcuts") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .disabled(!settings.quietMode)
        }
    }

    private func shortcutField(_ title: String, symbol: String, text: Binding<String>) -> some View {
        TextField(text: text, prompt: Text("Shortcut name")) {
            SettingLabel(title: title, symbol: symbol, color: .indigo)
        }
    }
}

// MARK: - About

struct AboutPage: View {
    let env: AppEnvironment

    init(env: AppEnvironment) { self.env = env }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        return short
    }

    private static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–" }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    IsleMark(size: 84)
                    Text("Isle").font(.title.weight(.semibold))
                    Text("Version \(Self.version) (\(Self.build))")
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let instance = IsleInstance.name {
                        StatusBadge(text: "Dev build · \(instance)", color: .orange, symbol: "hammer.fill")
                    }
                    Text("A Dynamic Island for the notch of your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    HStack(spacing: 10) {
                        Link(destination: URL(string: "https://felix-bergmann-code.github.io/isle")!) {
                            Label("Website", systemImage: "safari")
                        }
                        Link(destination: URL(string: "https://github.com/Felix-Bergmann-Code/isle")!) {
                            Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .settingAnchor("version")
            }

            Section {
                ForEach(Self.commands, id: \.0) { command, detail in
                    LabeledContent {
                        Text(detail).foregroundStyle(.secondary)
                    } label: {
                        Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Shell commands")
            } footer: {
                SettingNote("`scripts/isle` in the repository. Put it on your PATH, or call it from Raycast or a Shortcut.")
            }
            .settingAnchor("cli")

            Section {
                HStack {
                    SettingLabel(title: "Quit Isle", subtitle: "The island and its banners go away until you open Isle again.",
                                 symbol: "power", color: .red)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .settingAnchor("quit")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private static let commands: [(String, String)] = [
        ("isle open", "Open the island (open:agents, open:shelf)"),
        ("isle toggle", "Open or close it"),
        ("isle timer:25", "Start a 25-minute timer (timer:stop)"),
        ("isle quiet", "Toggle quiet mode (quiet:on, quiet:off)"),
        ("isle note", "Open the note, ready to type"),
        ("isle mirror", "Show the camera mirror"),
        ("isle settings", "Open these settings (settings:permissions)"),
    ]
}
