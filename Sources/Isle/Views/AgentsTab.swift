import SwiftUI

struct AgentsTab: View {
    let env: AppEnvironment

    var body: some View {
        let sessions = env.agents.visibleSessions
        HStack(alignment: .top, spacing: 18) {
            Group {
                if sessions.isEmpty {
                    EmptyAgents(env: env)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(sessions) { s in
                                AgentRow(session: s, monitor: env.agents)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(Anim.island, value: sessions.map(\.id))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if env.settings.showDevServers {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                DevServersPanel(ports: env.ports)
                    .frame(width: 178)
            }
        }
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let monitor: AgentMonitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 15) {
            AgentAvatar(kind: session.kind, phase: session.phase, size: 34, seed: Double(session.pid % 89))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let b = session.branch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .bold))
                            Text(b).lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.islandSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                HStack(spacing: 4) {
                    Circle().fill(session.phase.color).frame(width: 5, height: 5)
                    Text(session.detail)
                        .foregroundStyle(session.phase == .idle ? Color.islandSecondary : session.phase.color)
                        .lineLimit(1)
                    Text("·").foregroundStyle(Color.islandTertiary)
                    Text(session.title ?? (session.kind.name + (session.hostName.map { " in \($0)" } ?? "")))
                        .foregroundStyle(Color.islandTertiary)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 6)
            if hovering {
                HStack(spacing: 2) {
                    IslandIconButton(systemName: "chevron.left.forwardslash.chevron.right", size: 11, padding: 5) { monitor.openInEditor(session) }
                        .help("Open project in editor")
                    IslandIconButton(systemName: "folder", size: 11, padding: 5) { monitor.reveal(session) }
                        .help("Reveal in Finder")
                }
                .transition(.opacity)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(formatDuration(ctx.date.timeIntervalSince(session.phase == .working ? session.phaseSince : session.startedAt)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.islandTertiary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(session.phase == .waiting ? AgentPhase.waiting.color.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { monitor.focus(session) }
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
        .help(session.hostName.map { "Click to jump to \($0)" } ?? session.cwd)
    }
}

private struct EmptyAgents: View {
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: -10) {
                AgentAvatar(kind: .claude, phase: .idle, size: 40, seed: 1)
                AgentAvatar(kind: .codex, phase: .idle, size: 40, seed: 7)
                AgentAvatar(kind: .gemini, phase: .idle, size: 40, seed: 13)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("No agents running").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Start Claude Code, Codex, Gemini, Cursor Agent, Aider or opencode and they'll show up here.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.islandSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !ClaudeHookInstaller.isInstalled {
                    PillButton(title: "Enable instant Claude status", icon: "bolt.fill", tint: AgentKind.claude.color) {
                        env.openSettings()
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct DevServersPanel: View {
    let ports: PortsService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DEV SERVERS")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.islandTertiary)
                    .kerning(0.6)
                Spacer()
                if !ports.ports.isEmpty {
                    Text("\(ports.ports.count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Color.islandTertiary)
                }
            }
            if ports.ports.isEmpty {
                Text("Nothing listening on localhost.")
                    .font(.system(size: 11)).foregroundStyle(Color.islandSecondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(ports.ports) { p in PortRow(port: p, ports: ports) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { ports.beginUpdates() }
        .onDisappear { ports.endUpdates() }
    }
}

private struct PortRow: View {
    let port: DevPort
    let ports: PortsService
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: ":\(port.port)") // verbatim: no locale grouping (":3.000")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("\(port.command) · \(port.project)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.islandSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if hovering {
                IslandIconButton(systemName: "xmark", size: 9, padding: 4, tint: .red) { ports.stop(port) }
                    .help("Stop process \(port.pid)")
            }
            IslandIconButton(systemName: "arrow.up.right", size: 10, padding: 4) { ports.open(port) }
                .help("Open http://localhost:\(port.port)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
    }
}
