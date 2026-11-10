import SwiftUI
import UniformTypeIdentifiers

struct OpenIslandView: View {
    let env: AppEnvironment

    var body: some View {
        let vm = env.vm
        let g = vm.geometry
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabBar(env: env)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: g.hasNotch ? g.notchWidth + 12 : 24)
                HeaderTrailing(env: env)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: max(g.notchHeight, 30))

            ZStack {
                switch vm.tab {
                case .home: HomeTab(env: env).transition(.tabSlide(vm.tabDirection))
                case .agents: AgentsTab(env: env).transition(.tabSlide(vm.tabDirection))
                case .shelf: ShelfTab(env: env).transition(.tabSlide(vm.tabDirection))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { vm.dropTargeted }, set: { t in
            withAnimation(Anim.micro) { vm.dropTargeted = t }
            if t, vm.tab != .shelf { vm.select(.shelf) }
        })) { providers in
            ShelfStore.loadURLs(from: providers) { urls in env.shelf.add(urls: urls) }
            return true
        }
    }
}

private struct TabBar: View {
    let env: AppEnvironment
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases) { tab in
                TabButton(tab: tab, selected: env.vm.tab == tab, badge: badge(for: tab), ns: ns) {
                    env.vm.select(tab)
                }
            }
        }
    }

    private func badge(for tab: IslandTab) -> (Int, Color)? {
        switch tab {
        case .agents:
            let n = env.agents.activeCount
            return n > 0 ? (n, env.agents.needsAttention ? AgentPhase.waiting.color : AgentPhase.working.color) : nil
        case .shelf:
            let n = env.shelf.items.count
            return n > 0 ? (n, Color.white.opacity(0.35)) : nil
        case .home:
            return nil
        }
    }
}

private struct TabButton: View {
    let tab: IslandTab
    let selected: Bool
    let badge: (Int, Color)?
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                if selected {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize() // otherwise it can stay truncated ("Ho…") after opening straight into a tab
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
                if let badge, !selected {
                    Text("\(badge.0)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4.5).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(badge.1))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(hovering ? 0.85 : 0.5))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: ns)
                } else if hovering {
                    Capsule().fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
    }
}

private struct HeaderTrailing: View {
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 10) {
            if case .volume(let level, let muted) = env.vm.activity {
                HStack(spacing: 6) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                    LevelBar(value: muted ? 0 : Double(level), tint: .white)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if case .brightness(let level) = env.vm.activity {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .semibold))
                    LevelBar(value: Double(level), tint: .yellow)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if env.battery.hasBattery {
                BatteryGlyph(level: env.battery.level, charging: env.battery.isPluggedIn, showPercent: true)
                    .transition(.opacity)
            }
            IslandIconButton(systemName: "gearshape.fill", size: 12, padding: 6) { env.openSettings() }
        }
        .animation(Anim.micro, value: env.vm.activity)
    }
}
