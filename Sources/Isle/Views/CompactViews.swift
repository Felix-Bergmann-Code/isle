import SwiftUI

// MARK: - Compact live activity (music / agents) beside the notch

struct CompactView: View {
    let env: AppEnvironment
    let kind: CompactKind
    let side: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: side, height: height, alignment: .leading)
            Spacer(minLength: 0)
            trailing
                .frame(width: side, height: height, alignment: .trailing)
        }
    }

    @ViewBuilder private var leading: some View {
        switch kind {
        case .music, .musicAndAgents:
            ArtworkView(image: env.media.artwork, size: height - 12, radius: 5)
                .padding(.leading, 6)
        case .agents:
            AgentStack(sessions: env.agents.activeSessions, size: height - 12)
                .padding(.leading, 6)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch kind {
        case .music:
            LayerAudioBars(playing: env.media.now?.isPlaying ?? false, color: env.media.accent)
                .frame(width: 20, height: height * 0.46)
                .padding(.trailing, 8)
        case .agents, .musicAndAgents:
            AgentCountBadge(monitor: env.agents, size: height - 14)
                .padding(.trailing, 8)
        }
    }
}

struct AgentStack: View {
    let sessions: [AgentSession]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.45) {
            ForEach(Array(sessions.prefix(3).enumerated()), id: \.element.id) { i, s in
                // Static face + render-server motion: free while the island is closed.
                LayerMotionView(motion: motion(for: s.phase), amplitude: size * 0.12, phase: Double(i) * 0.21) {
                    AgentAvatar(kind: s.kind, phase: s.phase, size: size, seed: Double(s.pid % 97), animated: false)
                }
                .frame(width: size, height: size)
                .zIndex(Double(3 - i))
            }
        }
    }
}

private func motion(for phase: AgentPhase) -> LayerMotion {
    switch phase {
    case .working: return .bob
    case .waiting: return .wiggle
    case .done, .idle: return .breathe
    }
}

struct AgentCountBadge: View {
    let monitor: AgentMonitor
    let size: CGFloat

    var body: some View {
        let attention = monitor.needsAttention
        let tint = attention ? AgentPhase.waiting.color : AgentPhase.working.color
        HStack(spacing: 5) {
            ZStack {
                if attention {
                    Circle().stroke(tint.opacity(0.22), lineWidth: 2)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: size * 0.55, weight: .heavy))
                        .foregroundStyle(tint)
                } else {
                    LayerThinkingDots(color: tint)
                }
            }
            .frame(width: size, height: size)
            Text("\(monitor.activeCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.islandSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Lightweight fake spectrum. Pauses its timeline entirely when not playing.
struct AudioBars: View {
    let playing: Bool
    let color: Color
    var count = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(color)
                            .frame(width: 3, height: max(3, geo.size.height * level(t, i)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .frame(width: CGFloat(count) * 5.5)
    }

    private func level(_ t: Double, _ i: Int) -> CGFloat {
        guard playing else { return 0.22 }
        let d = Double(i)
        let a = sin(t * (6.1 + d * 1.9) + d * 1.7) * 0.5 + 0.5
        let b = sin(t * (2.3 + d * 0.7) + d * 0.9) * 0.5 + 0.5
        let c = sin(t * 11.0 + d * 2.3) * 0.5 + 0.5
        return CGFloat(0.18 + 0.82 * (a * 0.5 + b * 0.35 + c * 0.15))
    }
}

// MARK: - HUD / power / bluetooth (content on both sides of the notch)

struct SidesActivityView: View {
    let env: AppEnvironment
    let side: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: side, height: height, alignment: .leading).padding(.leading, 10)
            Spacer(minLength: 0)
            trailing.frame(width: side, height: height, alignment: .trailing).padding(.trailing, 10)
        }
    }

    @ViewBuilder private var leading: some View {
        switch env.vm.activity {
        case .volume(let level, let muted):
            Image(systemName: volumeIcon(level, muted))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .brightness:
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        case .charging(_, let plugged):
            HStack(spacing: 5) {
                Image(systemName: plugged ? "bolt.fill" : "powerplug")
                    .foregroundStyle(plugged ? Color.green : Color.islandSecondary)
                Text(plugged ? "Charging" : "On Battery")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .semibold))
        case .lowBattery:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Low Battery").foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .semibold))
        case .bluetooth(let name, let icon, _):
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch env.vm.activity {
        case .volume(let level, let muted):
            LevelBar(value: muted ? 0 : Double(level), tint: .white)
        case .brightness(let level):
            LevelBar(value: Double(level), tint: .yellow)
        case .charging(let level, let plugged):
            BatteryGlyph(level: level, charging: plugged, showPercent: true)
        case .lowBattery(let level):
            BatteryGlyph(level: level, charging: false, showPercent: true)
        case .bluetooth(_, _, let connected):
            Text(connected ? "Connected" : "Disconnected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(connected ? Color.blue : Color.islandSecondary)
        default:
            EmptyView()
        }
    }

    private func volumeIcon(_ v: Float, _ muted: Bool) -> String {
        if muted || v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct LevelBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint)
                    .frame(width: max(6, geo.size.width * value))
            }
        }
        .frame(width: 64, height: 6)
        .animation(Anim.micro, value: value)
    }
}

struct BatteryGlyph: View {
    let level: Int
    let charging: Bool
    var showPercent = false

    var body: some View {
        HStack(spacing: 5) {
            if showPercent {
                Text("\(level)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            BatteryShape(level: level, charging: charging, color: fill)
        }
    }

    private var fill: Color {
        if charging { return .green }
        if level <= 20 { return .red }
        return .white
    }
}

// MARK: - Banner (grows below the notch)

struct BannerView: View {
    let env: AppEnvironment
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.islandSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var icon: some View {
        switch env.vm.activity {
        case .agent(let b):
            AgentAvatar(kind: b.kind, phase: b.phase, size: 34, seed: 3)
        case .meeting:
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.red.opacity(0.16)))
        case .shelf:
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.blue.opacity(0.16)))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch env.vm.activity {
        case .agent(let b):
            Text(b.phase.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(b.phase.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(b.phase.color.opacity(0.16)))
        case .meeting(_, let m):
            Text("in \(m)m")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var title: String {
        switch env.vm.activity {
        case .agent(let b): return b.title
        case .meeting(let t, _): return t
        case .shelf(let n): return n == 1 ? "1 file on your shelf" : "\(n) files on your shelf"
        default: return ""
        }
    }

    private var subtitle: String {
        switch env.vm.activity {
        case .agent(let b): return b.subtitle
        case .meeting: return "Hover to join"
        case .shelf: return "Drag them out whenever you need them"
        default: return ""
        }
    }
}

/// The macOS 27 menu bar battery: a solid rounded block whose charged part is
/// opaque and the rest translucent, with a small nub on the right. Proportions
/// are measured from the system icon (body ≈ 2:1, corner ≈ ⅓ of the height,
/// nub ⅓ tall). There is no SF Symbol for this look, so it is drawn here.
struct BatteryShape: View {
    let level: Int
    let charging: Bool
    let color: Color
    var height: CGFloat = 11

    var body: some View {
        let w = height * 1.96
        let radius = height * 0.32
        let fraction = CGFloat(min(max(level, 0), 100)) / 100
        HStack(spacing: height * 0.08) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(0.4))
                Rectangle()
                    .fill(color)
                    .frame(width: w * fraction)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.78, weight: .bold))
                        .frame(width: w, height: height)
                        .blendMode(.destinationOut)
                }
            }
            .frame(width: w, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .compositingGroup()
            UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: height * 0.16, topTrailing: height * 0.16), style: .continuous)
                .fill(color.opacity(0.4))
                .frame(width: height * 0.13, height: height * 0.34)
        }
        .animation(Anim.micro, value: level)
        .accessibilityElement()
        .accessibilityLabel(charging ? "Battery \(level) percent, charging" : "Battery \(level) percent")
    }
}
