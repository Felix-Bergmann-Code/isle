import AppKit
import ServiceManagement
import SwiftUI

/// Settings → Privacy & Permissions: each macOS permission with what uses it, what it's for
/// and what it's never used for; then every file Isle changes, every network request it makes,
/// and what it reads but keeps on this Mac.
struct PermissionsPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared
    private var center: PermissionCenter { PermissionCenter.shared }
    @State private var expanded: Set<Permission> = []
    @State private var didAutoExpand = false

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        SettingsPageForm(page: .permissions, accessory: AnyView(PermissionSummary(settings: settings))) {
            Section {
                ForEach(Permission.allCases) { p in
                    PermissionRow(permission: p, env: env, expanded: binding(for: p))
                        .settingAnchor(p.rawValue)
                }
            } header: {
                Text("macOS permissions")
            } footer: {
                SettingNote("Isle asks for a permission only when a feature that needs it is on. Click a row for details. You can withdraw any of them in System Settings → Privacy & Security.")
            }

            Section("Works without a permission") {
                InfoRow(symbol: "mic.fill", color: .orange, title: "Microphone & camera indicator",
                        detail: "Reads only whether a microphone or camera is in use (the signal behind the orange and green dots), never the audio or video.")
                InfoRow(symbol: "cloud.sun.fill", color: .cyan, title: "Weather",
                        detail: "No location access: the city comes from your time zone, or the one you type.")
                InfoRow(symbol: "battery.75percent", color: .green, title: "Battery, volume & brightness",
                        detail: "Read from public system interfaces that every app can use.")
            }

            Section {
                FileRow(symbol: "sparkles", color: .orange, title: "Claude Code hooks",
                        path: ClaudeHookInstaller.settingsURL,
                        detail: "Only when you click Install. Adds a silent curl to the local server for each hook event and keeps a backup as settings.json.isle-backup. Remove takes out exactly those entries.",
                        isActive: center.claudeHooks, activeText: "Installed", inactiveText: "Not installed",
                        link: (.integrations, "claude"))
                FileRow(symbol: "terminal.fill", color: Color(white: 0.3), title: "zsh hook",
                        path: ShellHookInstaller.zshrcURL,
                        detail: "Only when you click Install. Writes ~/.config/isle/isle.zsh and adds one line to ~/.zshrc that loads it (with a backup). Remove takes out only that line.",
                        isActive: center.zshHook, activeText: "Installed", inactiveText: "Not installed",
                        link: (.integrations, "zsh"))
                FileRow(symbol: "note.text", color: Color(red: 0.93, green: 0.66, blue: 0.05), title: "Shelf note",
                        path: NoteStore.fileURL,
                        detail: "Your note, saved as you type.",
                        isActive: settings.scratchpadNote, activeText: "On", inactiveText: "Off",
                        link: (.shelf, "note"))
                FileRow(symbol: "power", color: .gray, title: "Login item",
                        path: nil,
                        detail: "Registered with macOS while Launch at login is on, listed in System Settings → General → Login Items.",
                        isActive: center.loginItem == .enabled, activeText: "Registered", inactiveText: "Off",
                        link: (.general, "login"))
            } header: {
                Text("Files Isle changes")
            } footer: {
                SettingNote("Nothing outside Isle's own folders is changed unless you click Install.")
            }
            .settingAnchor("files")

            Section {
                InfoRow(symbol: "network", color: .blue, title: "Local hook server",
                        detail: "Listens on 127.0.0.1:\(String(IsleInstance.hookPort)), on this Mac only, for agent status, approvals and finished commands. Requests from web pages are rejected.",
                        badge: center.serverListening
                            ? StatusBadge(text: "Listening", color: .green, symbol: "circle.fill")
                            : StatusBadge(text: "Not listening", color: .orange, symbol: "exclamationmark.triangle.fill"))
                InfoRow(symbol: "cloud.sun.fill", color: .cyan, title: "Open-Meteo",
                        detail: "Gets only the city name, to look up its coordinates, and those coordinates for the forecast.",
                        badge: onOff(settings.showWeather))
                InfoRow(symbol: "arrow.triangle.pull", color: Color(white: 0.2), title: "GitHub, through the GitHub CLI",
                        detail: "Your signed-in gh asks GitHub about the branches your agents work on: checks, pull requests and previews. Read-only.",
                        badge: onOff(settings.showShipStatus))
                InfoRow(symbol: "music.note", color: .green, title: "Album artwork",
                        detail: "The cover of the current Spotify track, from the address Spotify provides.",
                        badge: onOff(settings.showMusicActivity))
                InfoRow(symbol: "server.rack", color: .teal, title: "Your dev servers",
                        detail: "A quick HEAD request to your own servers on 127.0.0.1 while the Agents tab is open, to show their health.",
                        badge: onOff(settings.showDevServers))
            } header: {
                Text("Network")
            } footer: {
                SettingNote("No analytics, no accounts, no tracking. Isle has no server of its own.", symbol: "lock.fill")
            }
            .settingAnchor("network")

            Section {
                InfoRow(symbol: "doc.on.clipboard.fill", color: .blue, title: "Clipboard history",
                        detail: "Kept in memory only and cleared when Isle quits. Password managers and items marked concealed or transient are skipped.",
                        badge: onOff(settings.clipboardHistory))
                InfoRow(symbol: "text.bubble.fill", color: .purple, title: "Agent transcripts",
                        detail: "Claude Code transcripts in ~/.claude/projects and Codex session files are read for status, context fill and token counts.")
                InfoRow(symbol: "cpu.fill", color: .gray, title: "Processes & ports",
                        detail: "The process list and listening ports, to find agents and dev servers.")
                InfoRow(symbol: "plusminus", color: .orange, title: "Uncommitted changes",
                        detail: "git diff --numstat in the repos your agents work in, without taking locks.",
                        badge: onOff(settings.showAgentDiffs))
            } header: {
                Text("Read, and kept on this Mac")
            }
            .settingAnchor("local")
        }
        .onAppear(perform: autoExpand)
        .onChange(of: navigator.highlight) { expandHighlighted() }
    }

    private func onOff(_ on: Bool) -> StatusBadge {
        on ? StatusBadge(text: "On", color: .blue) : StatusBadge(text: "Off", color: .secondary)
    }

    private func binding(for p: Permission) -> Binding<Bool> {
        Binding(get: { expanded.contains(p) },
                set: { on in if on { expanded.insert(p) } else { expanded.remove(p) } })
    }

    @Environment(SettingsNavigator.self) private var navigator

    /// A search result or summary tile for a permission opens its row.
    private func expandHighlighted() {
        if let id = navigator.highlight, let p = Permission(rawValue: id) { expanded.insert(p) }
    }

    /// Rows that need something from you start open.
    private func autoExpand() {
        if !didAutoExpand {
            didAutoExpand = true
            expanded = Set(Permission.allCases.filter { center.badge($0, settings).needsAttention })
        }
        expandHighlighted()
    }
}

// MARK: - Summary

/// Under the page title: one tile per permission with its state, and a one-line verdict.
private struct PermissionSummary: View {
    let settings: AppSettings
    @Environment(SettingsNavigator.self) private var nav

    var body: some View {
        let center = PermissionCenter.shared
        let attention = center.attentionCount(settings)
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ForEach(Permission.allCases) { p in
                    let badge = center.badge(p, settings)
                    Button {
                        nav.show(.permissions, highlight: p.rawValue)
                    } label: {
                        VStack(spacing: 5) {
                            SettingsIcon(symbol: p.symbol, color: p.color, size: 30)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: badge.symbol)
                                        .font(.system(size: 11, weight: .bold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, badge.color == .secondary ? Color.gray : badge.color)
                                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                                        .offset(x: 4, y: 4)
                                }
                            Text(p == .downloads ? "Downloads" : p.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 66)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(p.title): \(badge.text)")
                }
            }
            Group {
                if attention == 0 {
                    Label("Everything your features need is allowed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(attention == 1 ? "1 permission needs your attention" : "\(attention) permissions need your attention",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout.weight(.medium))
        }
    }
}

// MARK: - Permission row

private struct PermissionRow: View {
    let permission: Permission
    let env: AppEnvironment
    @Binding var expanded: Bool
    @Bindable private var settings = AppSettings.shared

    init(permission: Permission, env: AppEnvironment, expanded: Binding<Bool>) {
        self.permission = permission
        self.env = env
        _expanded = expanded
    }

    var body: some View {
        let center = PermissionCenter.shared
        let badge = center.badge(permission, settings)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    SettingsIcon(symbol: permission.symbol, color: permission.color, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).fontWeight(.medium)
                        Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    StatusBadge(text: badge.text, color: badge.color, symbol: badge.symbol)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                details(center: center, badge: badge)
                    .padding(.leading, 39)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func details(center: PermissionCenter, badge: PermissionBadge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if permission == .automation {
                DetailBlock(title: "Apps") {
                    ForEach(AutomationTarget.all) { t in AutomationTargetRow(target: t, env: env) }
                }
            }

            DetailBlock(title: "Used for") {
                ForEach(center.uses(permission, settings)) { use in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(use.isOn ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(use.title)
                        Spacer()
                        Text(use.isOn ? "On" : "Off").foregroundStyle(.secondary)
                        SettingsLink(title: "", page: use.page, anchor: use.anchor)
                            .help("Show this setting")
                    }
                    .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label { Text(permission.does) } icon: {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                }
                Label { Text(permission.never) } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if permission == .calendar, center.calendarWriteOnly {
                SettingNote("Isle has \"Add Events Only\" access, which can't read your events. Choose Full Access for Isle in System Settings.",
                            symbol: "exclamationmark.triangle.fill", color: .orange)
            }

            HStack(spacing: 8) {
                if let primary = primaryAction(center: center) {
                    Button(primary) { center.request(permission, env: env) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Open System Settings…") { permission.pane.open() }
                Spacer()
            }
            .controlSize(.regular)

            Text("System Settings → \(permission.settingsPath)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// The button that moves things forward, when there's one besides opening System Settings.
    private func primaryAction(center: PermissionCenter) -> String? {
        switch (permission, center.status(permission)) {
        case (.accessibility, .notDetermined): return "Allow…"
        case (.calendar, .notDetermined), (.bluetooth, .notDetermined), (.camera, .notDetermined): return "Ask Now"
        case (.downloads, .unchecked): return "Ask Now"
        default: return nil
        }
    }
}

private struct DetailBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            VStack(alignment: .leading, spacing: 7) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }
}

private struct AutomationTargetRow: View {
    let target: AutomationTarget
    let env: AppEnvironment

    var body: some View {
        let center = PermissionCenter.shared
        let status = center.automation[target.bundleID] ?? .unknown
        HStack(spacing: 9) {
            Group {
                if let url = target.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).font(.callout)
                Text(target.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted: StatusBadge(text: "Allowed", color: .green, symbol: "checkmark.circle.fill")
            case .denied: StatusBadge(text: "Denied", color: .red, symbol: "xmark.circle.fill")
            case .notDetermined:
                Button("Ask Now") { center.requestAutomation(target, env: env) }.controlSize(.small)
            case .notRunning:
                StatusBadge(text: "Asked on first use", color: .secondary)
                    .help("macOS can only report this while \(target.name) is open.")
            case .notInstalled: StatusBadge(text: "Not installed", color: .secondary)
            case .unknown: StatusBadge(text: "Unknown", color: .secondary)
            }
        }
    }
}

// MARK: - Info rows

/// Icon, title, explanation and an optional badge; for things that aren't switches.
struct InfoRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var badge: StatusBadge?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let badge { badge }
        }
        .padding(.vertical, 1)
    }
}

/// A file Isle may change: its path, state, a Finder button and a link to its setting.
private struct FileRow: View {
    let symbol: String
    let color: Color
    let title: String
    let path: URL?
    let detail: String
    let isActive: Bool
    let activeText: String
    let inactiveText: String
    let link: (SettingsPage, String)
    @Environment(SettingsNavigator.self) private var nav

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    StatusBadge(text: isActive ? activeText : inactiveText, color: isActive ? .green : .secondary)
                }
                if let path {
                    Button { revealInFinder(path) } label: {
                        HStack(spacing: 3) {
                            Text(path.tildePath).font(.system(.caption, design: .monospaced))
                            Image(systemName: "arrow.up.forward.square").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Show in Finder")
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Settings") { nav.show(link.0, highlight: link.1) }
                .controlSize(.small)
                .help("Show the setting")
        }
        .padding(.vertical, 1)
    }
}
