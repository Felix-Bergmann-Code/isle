import SwiftUI

struct AgentsTab: View {
    let env: AppEnvironment

    var body: some View {
        let monitor = env.agents
        let sessions = monitor.visibleSessions
        // Prompts no visible row claims (e.g. a session Isle hasn't matched yet) still need answering.
        let orphans = monitor.prompts.filter { p in !sessions.contains { monitor.prompts(for: $0).contains(p) } }
        HStack(alignment: .top, spacing: 18) {
            Group {
                if sessions.isEmpty && orphans.isEmpty {
                    EmptyAgents(env: env)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(orphans) { p in
                                PermissionCard(prompt: p, monitor: monitor, showProject: true)
                            }
                            ForEach(sessions) { s in
                                AgentRow(session: s, monitor: monitor)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(Anim.island, value: sessions.map(\.id))
                        .animation(Anim.island, value: monitor.prompts.map(\.id))
                    }
                    .environment(\.isleEnv, env)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if env.settings.showDevServers {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                DevServersPanel(ports: env.ports, health: env.serverHealth)
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
        let prompts = monitor.prompts(for: session)
        VStack(spacing: 6) {
            row
            ForEach(prompts) { p in
                PermissionCard(prompt: p, monitor: monitor, showProject: false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let q = AgentReplier.question(for: session, monitor: monitor) {
                ReplyCard(session: session, question: q).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if !session.subagents.isEmpty {
                SubagentList(subagents: session.subagents)
                    .padding(.leading, 49) // under the text column: avatar 34 + spacing 15
                    .transition(.opacity)
            }
        }
        .animation(Anim.island, value: session.subagents.map(\.id))
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
        .help(session.hostName.map { "Click to open this chat in \($0)" } ?? session.cwd)
    }

    private var header: some View {
        HStack(spacing: 15) {
            AgentAvatar(kind: session.kind, phase: session.phase, size: 34, seed: Double(session.pid % 89))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let b = session.branch {
                        BranchChip(session: session, branch: b)
                    }
                    AgentDiffLabel(session: session)
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
                    ShipPreviewButton(session: session)
                    AgentDiffButton(session: session, monitor: monitor)
                    IslandIconButton(systemName: "chevron.left.forwardslash.chevron.right", size: 11, padding: 5) { monitor.openInEditor(session) }
                        .help("Open project in editor")
                    IslandIconButton(systemName: "folder", size: 11, padding: 5) { monitor.reveal(session) }
                        .help("Reveal in Finder")
                }
                .transition(.opacity)
            } else {
                ContextRing(session: session)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(agentRowTime(session, now: ctx.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(session.phase == .waiting ? AgentPhase.waiting.color : Color.islandTertiary)
                }
                .transition(.opacity)
            }
        }
    }
}

/// The subagents a session is running, one compact line each.
private struct SubagentList: View {
    let subagents: [Subagent]
    private let limit = 4

    var body: some View {
        // Running ones first; finished ones linger a few seconds with a check.
        let ordered = subagents.filter(\.isRunning) + subagents.filter { !$0.isRunning }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(ordered.prefix(limit)) { a in SubagentLine(agent: a) }
            if ordered.count > limit {
                Text("+\(ordered.count - limit) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.islandTertiary)
                    .padding(.leading, 15)
            }
        }
    }
}

private struct SubagentLine: View {
    let agent: Subagent

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if agent.isRunning {
                    Circle().fill(AgentPhase.working.color).frame(width: 5, height: 5)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(AgentPhase.done.color)
                }
            }
            .frame(width: 10)
            Text(agent.type)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(agent.isRunning ? 0.85 : 0.5))
                .lineLimit(1)
                .layoutPriority(1)
            if let label = agent.label {
                Text(label)
                    .foregroundStyle(Color.islandSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(agent.isRunning && agent.isBackground && agent.detail == "Working in the background" ? "Background" : agent.detail)
                .foregroundStyle(agent.isRunning ? AgentPhase.working.color.opacity(0.9) : Color.islandTertiary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.system(size: 10.5))
        .help([agent.type, agent.label, agent.isBackground ? "running in the background" : nil].compactMap { $0 }.joined(separator: " · "))
    }
}

/// Allow / Deny for a tool call that's waiting on the person.
private struct PermissionCard: View {
    let prompt: PermissionPrompt
    let monitor: AgentMonitor
    let showProject: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentPhase.waiting.color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentPhase.waiting.color)
                    .lineLimit(1)
                if !prompt.summary.isEmpty {
                    Text(prompt.summary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                IslandIconButton(systemName: "arrow.up.right", size: 10, padding: 5) {
                    // focus() hands every held prompt of that chat back to the app first.
                    if let s = monitor.sessions.first(where: matches) { monitor.focus(s) } else { monitor.respond(prompt, .deferToApp) }
                }
                .help("Answer in the app instead")
                PromptButton(title: "Deny", tint: .white.opacity(0.14), text: .white) { monitor.respond(prompt, .deny) }
                PromptButton(title: "Allow", tint: AgentPhase.done.color, text: .black) { monitor.respond(prompt, .allow) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AgentPhase.waiting.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AgentPhase.waiting.color.opacity(0.45), lineWidth: 1)
        )
    }

    private var title: String {
        var who = showProject && !prompt.cwd.isEmpty ? (prompt.cwd as NSString).lastPathComponent : ""
        if let type = prompt.agentType { who += who.isEmpty ? "Subagent \(type)" : " · subagent \(type)" }
        return who.isEmpty ? "Wants to use \(prompt.toolLabel)" : "\(who) wants to use \(prompt.toolLabel)"
    }

    private func matches(_ s: AgentSession) -> Bool {
        if let sid = prompt.sessionID, let mine = s.sessionID { return sid == mine }
        return s.cwd == prompt.cwd
    }
}

private struct PromptButton: View {
    let title: String
    let tint: Color
    let text: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(hovering ? 1 : 0.88)))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
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
                        env.showSettings(.integrations, highlight: "claude")
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct DevServersPanel: View {
    let ports: PortsService
    let health: ServerHealth

    var body: some View {
        // Ghosts of servers that stopped on their own sit in their old slot for a minute.
        let ghosts = Set(health.ghosts.map(\.port)).subtracting(ports.ports.map(\.port))
        let rows = (ports.ports + health.ghosts.filter { ghosts.contains($0.port) }).sorted { $0.port < $1.port }
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
            if rows.isEmpty {
                Text("Nothing listening on localhost.")
                    .font(.system(size: 11)).foregroundStyle(Color.islandSecondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(rows) { p in
                            PortRow(port: p, ports: ports, health: ghosts.contains(p.port) ? .stopped : health.state(for: p))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { ports.beginUpdates(); health.beginUpdates() }
        .onDisappear { ports.endUpdates(); health.endUpdates() }
    }
}

private struct PortRow: View {
    let port: DevPort
    let ports: PortsService
    var health: ServerHealthState = .unknown
    @State private var hovering = false

    var body: some View {
        let stopped = health == .stopped
        HStack(spacing: 6) {
            Circle().fill(health.color).frame(width: 6, height: 6)
                .animation(Anim.micro, value: health.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: ":\(port.port)") // verbatim: no locale grouping (":3.000")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(stopped ? "Stopped" : "\(port.command) · \(port.project)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.islandSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if hovering && !stopped {
                IslandIconButton(systemName: "xmark", size: 9, padding: 4, tint: .red) { ports.stop(port) }
                    .help("Stop process \(port.pid)")
            }
            IslandIconButton(systemName: "arrow.up.right", size: 10, padding: 4) { ports.open(port) }
                .help(Text(verbatim: "Open http://localhost:\(port.port)"))
                .opacity(stopped ? 0 : 1)
                .allowsHitTesting(!stopped)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
        .opacity(stopped ? 0.5 : 1)
        .animation(Anim.micro, value: stopped)
        .help(stopped ? "\(port.command) · \(port.project)" : health.help)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
    }
}
