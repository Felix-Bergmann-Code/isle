import SwiftUI

/// Small ring left of an agent row's elapsed time: how full the Claude session's context is.
/// Quiet until it matters (≥ 50 %), amber when auto-compact is getting close, red when imminent.
struct ContextRing: View {
    let session: AgentSession

    var body: some View {
        if AppSettings.shared.showUsageMeter, let c = session.context, c.fill >= 0.5 {
            ProgressRing(progress: c.fill, tint: tint(c.fill), lineWidth: 2)
                .frame(width: 12, height: 12)
                // The row's HStack spaces items 15 pt apart; sit 6 pt from the time instead.
                .padding(.trailing, -9)
                .help(c.summary)
                .transition(.opacity)
        }
    }

    private func tint(_ fill: Double) -> Color {
        if fill >= 0.92 { return .red }
        if fill >= 0.8 { return AgentPhase.waiting.color }
        return .white.opacity(0.6)
    }
}

/// Header value on the Agents tab: today's Claude Code tokens, details on hover.
struct UsageAccessory: View {
    let env: AppEnvironment

    var body: some View {
        if env.settings.showUsageMeter, env.vm.tab == .agents, let s = env.usage.snapshot, s.todayTokens > 0 {
            HStack(spacing: 3) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(TokenCount.short(s.todayTokens))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(Color.islandSecondary)
            .help(s.summary)
            .transition(.opacity)
        }
    }
}
