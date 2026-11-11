import SwiftUI
import UniformTypeIdentifiers

struct ShelfTab: View {
    let env: AppEnvironment
    @State private var airdropTargeted = false
    @AppStorage("shelfMode") private var mode: ShelfMode = .files

    var body: some View {
        let shelf = env.shelf
        let modes = ShelfMode.available(env.settings)
        let current = mode.resolved(in: modes)
        HStack(spacing: 14) {
            ZStack {
                if current != .files {
                    ShelfModePane(env: env, mode: current)
                } else if shelf.items.isEmpty {
                    DropZone(icon: "tray.and.arrow.down.fill", title: "Drop files here",
                             subtitle: "They'll wait on the shelf until you drag them out",
                             targeted: env.vm.dropTargeted)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ShelfModeSwitch(modes: modes, selection: $mode).hidden()
                            Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.islandSecondary)
                            Spacer()
                            Button("Clear") { withAnimation(Anim.island) { shelf.clear() } }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.islandSecondary)
                        }
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(74), spacing: 6), count: 6), spacing: 6) {
                                ForEach(shelf.items) { item in
                                    ShelfItemView(item: item, shelf: shelf)
                                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(env.vm.dropTargeted ? 0.08 : 0.04))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Anim.island, value: shelf.items)
            .overlay(alignment: .topLeading) { ShelfModeSwitch(modes: modes, selection: $mode).padding(10) }
            .onChange(of: env.vm.dropTargeted, initial: true) { _, targeted in
                // Files dragged onto the island land in the files shelf, so show it.
                if targeted, mode != .files { withAnimation(Anim.tab) { mode = .files } }
            }

            DropZone(icon: "airplayaudio", title: "AirDrop", subtitle: "Drop to send", targeted: airdropTargeted, tint: .blue)
                .frame(width: 118)
                .onDrop(of: [.fileURL], isTargeted: $airdropTargeted) { providers in
                    ShelfStore.loadURLs(from: providers) { ShelfStore.airDrop($0) }
                    return true
                }
                .onTapGesture { ShelfStore.airDrop(shelf.items.map(\.url)) }
                .help("Drop files to AirDrop them — or click to AirDrop everything on the shelf")
        }
    }
}

private struct DropZone: View {
    let icon: String
    let title: String
    let subtitle: String
    let targeted: Bool
    var tint: Color = .white

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(targeted ? tint : tint.opacity(0.55))
                .symbolEffect(.bounce, value: targeted)
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Color.islandSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(targeted ? 0.14 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(targeted ? 0.6 : 0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(Anim.micro, value: targeted)
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    let shelf: ShelfStore
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let img = shelf.thumbnails[item.url] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc").font(.system(size: 22)).foregroundStyle(Color.islandSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
            Text(item.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 74, height: 70)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { withAnimation(Anim.island) { shelf.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("AirDrop") { ShelfStore.airDrop([item.url]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
    }
}
