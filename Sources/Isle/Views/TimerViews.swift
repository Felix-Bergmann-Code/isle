import SwiftUI

/// The timer's spot in the header row. Idle it is a single glyph on Home that unfolds into
/// preset chips; running it is a small ring and the time left (on every tab), with pause
/// and stop appearing on hover. Nothing at all when the feature is off.
struct TimerAccessory: View {
    let env: AppEnvironment
    @State private var picking = false

    var body: some View {
        let timer = env.timer
        Group {
            if !env.settings.timerEnabled {
                EmptyView()
            } else if let run = timer.run {
                RunningTimer(timer: timer, run: run)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            } else if env.vm.tab == .home {
                if picking {
                    PresetChips { minutes in
                        withAnimation(Anim.micro) {
                            picking = false
                            if let minutes { timer.start(minutes: minutes) }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
                } else {
                    IslandIconButton(systemName: "timer", size: 11, padding: 5, tint: .islandSecondary) {
                        withAnimation(Anim.micro) { picking = true }
                    }
                    .help("Timer")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
        }
        // A timer started elsewhere (shell) while the chips are out folds them away.
        .onChange(of: timer.run != nil) { _, running in if running { picking = false } }
    }
}

/// "5 15 25 45 ×": picking one starts it; × folds the row back into the glyph.
private struct PresetChips: View {
    /// Minutes picked, or nil to collapse.
    let pick: (Int?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimerService.presets, id: \.self) { m in
                Chip(minutes: m) { pick(m) }
            }
            IslandIconButton(systemName: "xmark", size: 8, weight: .bold, padding: 2.5, tint: .islandSecondary) { pick(nil) }
                .padding(.leading, 2)
        }
        .fixedSize()
    }
}

private struct Chip: View {
    let minutes: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(minutes)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 3)
                .frame(minWidth: 21, minHeight: 22)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
        .help("\(minutes) minutes")
    }
}

/// Ring + "18:22". The 1 s tick only exists while the island is open and the timer runs.
private struct RunningTimer: View {
    let timer: TimerService
    let run: TimerRun
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if hovering {
                HStack(spacing: 0) {
                    IslandIconButton(systemName: run.isPaused ? "play.fill" : "pause.fill", size: 9, padding: 4) {
                        withAnimation(Anim.micro) { run.isPaused ? timer.resume() : timer.pause() }
                    }
                    .contentTransition(.symbolEffect(.replace))
                    IslandIconButton(systemName: "xmark", size: 9, weight: .bold, padding: 4) {
                        withAnimation(Anim.micro) { timer.cancel() }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .trailing)))
            }
            if run.isPaused {
                readout(at: .now)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in readout(at: ctx.date) }
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
        .help(help)
    }

    private func readout(at date: Date) -> some View {
        HStack(spacing: 5) {
            ProgressRing(progress: run.progress(at: date), tint: run.tint, lineWidth: 2)
                .frame(width: 11, height: 11)
            Text(formatClock(run.remaining(at: date).rounded(.up)))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(run.isPaused ? Color.islandSecondary : .white)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    private var help: String {
        guard let end = run.end else { return "\(run.title) · paused" }
        return "\(run.title) · ends \(end.formatted(date: .omitted, time: .shortened))"
    }
}
