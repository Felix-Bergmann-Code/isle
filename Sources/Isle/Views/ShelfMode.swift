import SwiftUI

/// What the Shelf's main area shows. Files is always there; every other mode exists only while
/// its feature is switched on, and the switch hides itself when Files is the only mode left.
enum ShelfMode: String, CaseIterable, Identifiable {
    case files, clipboard, note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .clipboard: return "Clipboard"
        case .note: return "Note"
        }
    }

    func isEnabled(_ settings: AppSettings) -> Bool {
        switch self {
        case .files: return true
        case .clipboard: return settings.clipboardHistory
        case .note: return settings.scratchpadNote
        }
    }

    /// UserDefaults key of the last chosen mode (ShelfTab reads it through @AppStorage).
    static let storageKey = "shelfMode"

    /// The modes to offer, in order.
    static func available(_ settings: AppSettings) -> [ShelfMode] {
        allCases.filter { $0.isEnabled(settings) }
    }

    /// The remembered mode, or Files when that mode has since been switched off.
    func resolved(in modes: [ShelfMode]) -> ShelfMode {
        modes.contains(self) ? self : .files
    }
}

/// Content for every mode other than Files, which ShelfTab draws itself.
struct ShelfModePane: View {
    let env: AppEnvironment
    let mode: ShelfMode

    var body: some View {
        switch mode {
        case .files: EmptyView()
        case .clipboard: ClipboardList(history: env.clipboard)
        // The switch floats over the card's top-left corner, so the note starts below it.
        case .note: NoteView(env: env, topInset: ShelfMode.available(env.settings).count > 1 ? 26 : 0)
        }
    }
}

/// Small segmented switch at the top-left of the Shelf. Draws nothing with fewer than two modes.
///
/// ShelfTab overlays one instance at a fixed spot so the selection capsule can slide between
/// segments; a header row that shares the line puts a `.hidden()` copy in its place to keep room.
struct ShelfModeSwitch: View {
    let modes: [ShelfMode]
    @Binding var selection: ShelfMode
    @Namespace private var ns

    var body: some View {
        if modes.count > 1 {
            let current = selection.resolved(in: modes)
            HStack(spacing: 2) {
                ForEach(modes) { mode in
                    ShelfModeSegment(title: mode.title, selected: mode == current, ns: ns) {
                        guard mode != current else { return }
                        withAnimation(Anim.tab) { selection = mode }
                    }
                }
            }
        }
    }
}

private struct ShelfModeSegment: View {
    let title: String
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? Color.white : (hovering ? Color.white.opacity(0.85) : Color.islandSecondary))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "shelfMode", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
    }
}
