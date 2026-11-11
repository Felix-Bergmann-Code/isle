import SwiftUI

/// The Shelf's Clipboard mode: recent copies, newest first. Click a row to copy it again;
/// hover shows the one shortcut that fits what was copied (format JSON, decode a JWT…).
struct ClipboardList: View {
    let history: ClipboardHistory
    /// Row showing a checkmark after a copy.
    @State private var confirmed: UUID?
    @State private var confirmReset: DispatchWorkItem?

    var body: some View {
        ZStack {
            if history.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text("Nothing copied yet").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text("Copy something and it shows up here").font(.system(size: 10.5)).foregroundStyle(Color.islandSecondary)
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // Same line as the mode switch, which ShelfTab overlays on the left.
                    HStack {
                        Spacer()
                        Button("Clear") { history.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.islandSecondary)
                    }
                    .frame(height: 20)
                    // Relative times only need to tick while the list is on screen.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 4) {
                                ForEach(history.items) { item in
                                    ClipRow(item: item, now: context.date, confirmed: confirmed == item.id,
                                            copy: { copy(item) },
                                            perform: { run($0, from: item) },
                                            remove: { history.remove(item) },
                                            clearAll: { history.clear() })
                                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
        .animation(Anim.island, value: history.items.map(\.id))
    }

    private func copy(_ item: ClipItem) {
        history.copy(item)
        confirm(item.id)
    }

    private func run(_ action: ClipAction, from item: ClipItem) {
        history.perform(action)
        if case .copy = action.effect { confirm(item.id) }
    }

    private func confirm(_ id: UUID) {
        confirmReset?.cancel()
        withAnimation(Anim.micro) { confirmed = id }
        let reset = DispatchWorkItem { withAnimation(Anim.micro) { confirmed = nil } }
        confirmReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let now: Date
    let confirmed: Bool
    let copy: () -> Void
    let perform: (ClipAction) -> Void
    let remove: () -> Void
    let clearAll: () -> Void
    @State private var hovering = false

    var body: some View {
        let action = hovering && !confirmed ? item.action : nil
        HStack(spacing: 8) {
            // Only this part copies on click, so a click on the action pill never also copies
            // the original back over the pill's result.
            HStack(spacing: 8) {
                leading.frame(width: 22, height: 22)
                preview
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            Group {
                if confirmed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if let action {
                    PillButton(title: action.title) { perform(action) }
                } else {
                    Text(ClipDetector.compactInterval(now.timeIntervalSince(item.date)))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.islandTertiary)
                }
            }
            .transition(.opacity)
        }
        .padding(.leading, 4)
        .padding(.trailing, action == nil ? 9 : 3)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Remove", action: remove)
            Divider()
            Button("Clear history", action: clearAll)
        }
    }

    @ViewBuilder private var leading: some View {
        if let thumb = item.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandSecondary)
        }
    }

    private var glyph: String {
        switch item.kind {
        case .json: return "curlybraces"
        case .url: return "link"
        case .timestamp: return "clock"
        case .jwt: return "key"
        case .image: return "photo"
        case .text, .code, .base64: return "doc.text"
        }
    }

    private var preview: Text {
        let detail = Color.islandSecondary
        switch item.kind {
        case .timestamp(let date):
            return Text("\(item.preview)\(Text(" → \(ClipDetector.shortDate(date, now: now))").foregroundStyle(detail))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white)
        case .jwt(let alg, let expires, _):
            return Text("JWT\(Text(" · \(alg)\(expiry(expires))").foregroundStyle(detail))")
                .font(.system(size: 12))
                .foregroundStyle(.white)
        case .image(let w, let h):
            return Text("Image\(Text(" \(w) × \(h)").foregroundStyle(detail))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white)
        default:
            return Text(item.preview)
                .font(item.kind.isCodeLike ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.white)
        }
    }

    private func expiry(_ date: Date?) -> String {
        guard let date else { return "" }
        let left = date.timeIntervalSince(now)
        return left > 0 ? " · expires in \(ClipDetector.compactInterval(max(60, left)))"
                        : " · expired \(ClipDetector.compactInterval(max(60, -left))) ago"
    }
}
