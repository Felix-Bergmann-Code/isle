import Combine
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let env: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettings(env: env).tabItem { Label("General", systemImage: "gearshape") }
            ActivitiesSettings(env: env).tabItem { Label("Live Activities", systemImage: "capsule.fill") }
            AgentSettings(env: env).tabItem { Label("Agents", systemImage: "sparkles") }
            HUDSettings(env: env).tabItem { Label("HUD", systemImage: "speaker.wave.2.fill") }
        }
        .frame(width: 540, height: 500)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings = AppSettings.shared
    let env: AppEnvironment
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        Form {
            Section("Display") {
                Picker("Show island on", selection: $settings.screenMode) {
                    ForEach(ScreenMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show a pill on displays without a notch", isOn: $settings.showPillOnNonNotch)
            }
            Section("Interaction") {
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $settings.hoverDelay, in: 0...0.5)
                        Text("\(Int(settings.hoverDelay * 1000)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Haptic feedback on the trackpad", isOn: $settings.haptics)
                Text("Hover the notch to open · swipe left/right with two fingers to switch tabs · drag files onto the notch to shelve them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Button("Quit Isle") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActivitiesSettings: View {
    @Bindable var settings = AppSettings.shared
    let env: AppEnvironment

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        Form {
            Section("Live Activities") {
                Toggle("Now Playing (Spotify & Music)", isOn: $settings.showMusicActivity)
                Toggle("Running agents", isOn: $settings.showAgentActivity)
                Toggle("Charging & low battery", isOn: $settings.showBatteryActivity)
                Toggle("Bluetooth devices (AirPods, keyboards…)", isOn: $settings.showBluetoothActivity)
                Toggle("Meeting reminders (5 min before)", isOn: $settings.meetingReminders)
            }
            Section("Calendar") {
                switch env.calendar.access {
                case .granted: Label("Calendar access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .unknown: Button("Allow Calendar access") { env.calendar.requestAccess() }
                case .denied: Button("Open Privacy Settings…") { env.calendar.openPrivacySettings() }
                }
            }
            Section("Shelf") {
                LabeledContent("Items on shelf", value: "\(env.shelf.items.count)")
                Button("Clear shelf") { env.shelf.clear() }.disabled(env.shelf.items.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    @Bindable var settings = AppSettings.shared
    let env: AppEnvironment
    @State private var installed = ClaudeHookInstaller.isInstalled
    @State private var error: String?
    @State private var copied = false

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        Form {
            Section("Agents") {
                Toggle("Banner when an agent finishes or needs you", isOn: $settings.agentBanners)
                Toggle("Play a sound with banners", isOn: $settings.agentSound)
                Toggle("Approve Claude Code tool calls from the island", isOn: $settings.agentApprovals)
                    .help("Requests wait up to \(Int(HookServer.permissionHold / 60)) minutes in the island, then go back to Claude Code's own prompt.")
                Toggle("Show background agents (e.g. Codex in VS Code) when idle", isOn: $settings.showBackgroundAgents)
                Toggle("Show local dev servers in the Agents tab", isOn: $settings.showDevServers)
                LabeledContent("Detected right now", value: "\(env.agents.visibleSessions.count)")
            }
            Section {
                HStack {
                    Image(systemName: installed ? "checkmark.circle.fill" : "bolt.circle")
                        .foregroundStyle(installed ? .green : .orange)
                    Text(installed ? "Claude Code hooks installed" : "Claude Code hooks not installed")
                    Spacer()
                    if installed {
                        Button("Remove") { run { try ClaudeHookInstaller.uninstall() } }
                    } else {
                        Button("Install") { run { try ClaudeHookInstaller.install() } }.buttonStyle(.borderedProminent)
                    }
                }
                Text("Without hooks Isle infers status from transcripts and CPU activity. Hooks make \"needs permission\" and \"finished\" instant and exact, and let you allow or deny tool calls from the island. Install adds a quiet `curl` to localhost:\(String(HookServer.defaultPort)) for each hook event in ~/.claude/settings.json (a backup is saved next to it). Restart running Claude sessions to pick it up.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Send a test banner") {
                    env.vm.flash(.agent(AgentBanner(kind: .claude, phase: .done, title: "dynamic_island is done",
                                                    subtitle: "This is what a finished agent looks like.")), duration: 4)
                }
            } header: { Text("Claude Code — instant status") }

            Section {
                Text("Any tool can report itself:")
                    .font(.caption)
                Text(customSnippet)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(customSnippet, forType: .string)
                    copied = true
                }
            } header: { Text("Other agents & scripts") }
        }
        .formStyle(.grouped)
    }

    private var customSnippet: String {
        "curl -s -X POST localhost:\(HookServer.defaultPort)/hook/custom \\\n  -d '{\"id\":\"build\",\"name\":\"Deploy\",\"phase\":\"working\",\"detail\":\"Uploading…\"}'\n# phase: working | waiting | done | idle | end"
    }

    private func run(_ op: () throws -> Void) {
        do { try op(); error = nil } catch { self.error = error.localizedDescription }
        installed = ClaudeHookInstaller.isInstalled
    }
}

private struct HUDSettings: View {
    @Bindable var settings = AppSettings.shared
    let env: AppEnvironment
    @State private var trusted = MediaKeyTap.isTrusted
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        Form {
            Section("Volume & Brightness") {
                Toggle("Show volume changes in the island", isOn: $settings.showVolumeHUD)
                Toggle("Replace the system volume & brightness HUD", isOn: $settings.replaceSystemHUD)
                Text("Isle takes over the media keys so only the island HUD shows. ⌥⇧ + key for fine steps. Brightness works on the built-in display (lid open). This needs Accessibility access.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.replaceSystemHUD {
                    HStack {
                        Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(trusted ? .green : .orange)
                        Text(trusted ? (env.keyTap.isRunning ? "Active" : "Accessibility granted") : "Accessibility access needed")
                        Spacer()
                        if !trusted {
                            Button("Open Settings…") {
                                MediaKeyTap.requestTrust()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in trusted = MediaKeyTap.isTrusted }
    }
}
