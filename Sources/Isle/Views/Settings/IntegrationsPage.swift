import AppKit
import SwiftUI

/// Settings → Hooks & Scripts: the Claude Code hooks, the zsh hook behind long-command banners,
/// and the endpoint any other tool can post its status to.
struct IntegrationsPage: View {
    let env: AppEnvironment
    @Bindable private var settings = AppSettings.shared
    @State private var claudeError: String?
    @State private var zshError: String?
    @State private var copied = false

    init(env: AppEnvironment) { self.env = env }

    var body: some View {
        let center = PermissionCenter.shared
        SettingsPageForm(page: .integrations) {
            Section {
                InstallRow(symbol: "sparkles", color: .orange, title: "Claude Code hooks",
                           installed: center.claudeHooks,
                           summary: center.claudeHooks
                               ? "\"Needs you\" and \"finished\" are exact and instant, and tool calls can be approved from the island."
                               : "Makes status exact and instant, and lets you allow or deny tool calls from the island.",
                           install: { claudeError = attempt { try ClaudeHookInstaller.install() } },
                           remove: { claudeError = attempt { try ClaudeHookInstaller.uninstall() } })
                    .settingAnchor("claude")
                PathRow(url: ClaudeHookInstaller.settingsURL)
                if let claudeError { SettingNote(claudeError, symbol: "xmark.octagon.fill", color: .red) }
                LabeledContent {
                    Button("Send Test Banner") {
                        env.vm.flash(.agent(AgentBanner(kind: .claude, phase: .done, title: "Your agent is done",
                                                        subtitle: "This is what a finished agent looks like.")), duration: 4)
                    }
                } label: {
                    SettingLabel(title: "Try it", subtitle: "Shows a finished-agent banner in the notch.", symbol: "bell.badge.fill", color: .red)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                SettingNote("Install adds a silent curl to 127.0.0.1:\(String(HookServer.defaultPort)) for each hook event and saves a backup next to the file. Restart running Claude sessions to pick it up. Without hooks, Isle infers status from transcripts and CPU activity.")
            }

            Section {
                SettingToggle("Banner when a long command finishes",
                              subtitle: "Start a build or a test run, look away, and the notch tells you when it finished or failed.",
                              symbol: "checkmark.rectangle.stack.fill", color: .green, isOn: $settings.commandBanners)
                    .settingAnchor("commands")
                Picker(selection: $settings.commandThreshold) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                } label: {
                    SettingLabel(title: "For commands longer than", symbol: "stopwatch.fill", color: .orange)
                }
                .disabled(!settings.commandBanners)
                InstallRow(symbol: "terminal.fill", color: Color(white: 0.3), title: "zsh hook",
                           installed: center.zshHook,
                           summary: "Reports finished commands to Isle. Open a new terminal tab after installing.",
                           install: { zshError = attempt { try ShellHookInstaller.install() } },
                           remove: { zshError = attempt { try ShellHookInstaller.uninstall() } })
                    .settingAnchor("zsh")
                PathRow(url: ShellHookInstaller.zshrcURL)
                if !ShellHookInstaller.loginShellIsZsh {
                    SettingNote("Your login shell isn't zsh, so the hook only runs in zsh sessions.",
                                symbol: "exclamationmark.triangle.fill", color: .orange)
                }
                if let zshError { SettingNote(zshError, symbol: "xmark.octagon.fill", color: .red) }
            } header: {
                Text("Terminal commands")
            } footer: {
                SettingNote("Install writes ~/.config/isle/isle.zsh and adds one line to ~/.zshrc that loads it (with a backup). Editors, pagers, ssh, REPLs and Ctrl-C are skipped, and nothing shows while that terminal is in front.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    SettingLabel(title: "Report any task to the island",
                                 subtitle: "Deploys, long scripts, other agents: post their status and they show up like an agent.",
                                 symbol: "chevron.left.forwardslash.chevron.right", color: .indigo)
                    Text(customSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(customSnippet, forType: .string)
                                withAnimation { copied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .controlSize(.small)
                            .padding(6)
                        }
                }
                .settingAnchor("custom")
            } header: {
                Text("Other agents & scripts")
            } footer: {
                SettingNote("phase is one of working, waiting, done, idle or end. Only programs on this Mac can reach the server.")
            }
        }
    }

    private var customSnippet: String {
        "curl -s -X POST localhost:\(HookServer.defaultPort)/hook/custom \\\n  -d '{\"id\":\"build\",\"name\":\"Deploy\",\"phase\":\"working\",\"detail\":\"Uploading…\"}'"
    }

    /// Runs an install step and returns its error message, if any.
    private func attempt(_ op: () throws -> Void) -> String? {
        defer { PermissionCenter.shared.refresh(env: env) }
        do { try op(); return nil } catch { return error.localizedDescription }
    }
}

/// Something Isle can install: its state and the one button that changes it.
private struct InstallRow: View {
    let symbol: String
    let color: Color
    let title: String
    let installed: Bool
    let summary: String
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            SettingsIcon(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    StatusBadge(text: installed ? "Installed" : "Not installed",
                                color: installed ? .green : .orange,
                                symbol: installed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if installed {
                Button("Remove", action: remove)
            } else {
                Button("Install", action: install).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The file an install changes, with a Finder button.
private struct PathRow: View {
    let url: URL

    var body: some View {
        LabeledContent {
            Button("Show in Finder") { revealInFinder(url) }.controlSize(.small)
        } label: {
            Label {
                Text(url.tildePath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
        }
    }
}
