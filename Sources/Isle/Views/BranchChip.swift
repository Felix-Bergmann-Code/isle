import SwiftUI

/// The agent row's branch capsule. Its leading glyph doubles as the branch's CI state
/// (amber dot running, green check passed, red cross failed, branch glyph otherwise) and a
/// pull request adds its number. Clicking opens the PR, or the latest run without one.
struct BranchChip: View {
    let session: AgentSession
    let branch: String
    @State private var hovering = false

    var body: some View {
        let status = ShipService.shared.status(for: session)
        if let status, status.hasNews {
            if let url = status.url {
                Button { NSWorkspace.shared.open(url) } label: { chip(status) }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(Anim.micro) { hovering = h } }
                    .help(status.summary)
            } else {
                chip(status).help(status.summary)
            }
        } else {
            chip(nil)
        }
    }

    private func chip(_ status: ShipStatus?) -> some View {
        HStack(spacing: 2) {
            lead(status?.checks ?? .none)
            Text(branch).lineLimit(1)
            if let n = status?.prNumber {
                Text(verbatim: "#\(n)")
                    .foregroundStyle(numberTint(status?.prState))
                    .fixedSize()
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.islandSecondary)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(Color.white.opacity(hovering && status?.url != nil ? 0.14 : 0.08)))
        .animation(Anim.micro, value: status?.checks)
    }

    @ViewBuilder
    private func lead(_ checks: ShipStatus.Checks) -> some View {
        switch checks {
        case .none:
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .bold))
        case .running:
            Circle().fill(AgentPhase.waiting.color).frame(width: 5, height: 5).frame(width: 9)
        case .passed:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(AgentPhase.done.color)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(ShipStatus.failedTint)
        }
    }

    private func numberTint(_ state: ShipStatus.PRState?) -> Color {
        switch state {
        case .merged: return ShipStatus.mergedTint
        case .draft, .closed: return .islandTertiary
        default: return .islandSecondary
        }
    }
}

/// First hover button on an agent row while its branch has a preview deployment.
struct ShipPreviewButton: View {
    let session: AgentSession

    var body: some View {
        if let url = ShipService.shared.status(for: session)?.previewURL {
            IslandIconButton(systemName: "safari", size: 11, padding: 5) { NSWorkspace.shared.open(url) }
                .help("Open preview")
        }
    }
}
