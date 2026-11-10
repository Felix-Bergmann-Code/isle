import SwiftUI

struct HomeTab: View {
    let env: AppEnvironment

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            NowPlayingView(env: env)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            CalendarWidget(env: env)
                .frame(width: 214)
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    let env: AppEnvironment
    @State private var artHover = false

    var body: some View {
        let media = env.media
        Group {
            if let np = media.now {
                HStack(spacing: 16) {
                    Button { media.activateSource() } label: {
                        ArtworkView(image: media.artwork, size: 96, radius: 16)
                            .overlay(alignment: .bottomTrailing) {
                                if let icon = np.source.appIcon {
                                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                                        .shadow(color: .black.opacity(0.5), radius: 3)
                                        .offset(x: 7, y: 7)
                                }
                            }
                            .shadow(color: media.accent.opacity(np.isPlaying ? 0.45 : 0), radius: 18, y: 6)
                            .scaleEffect(np.isPlaying ? (artHover ? 1.03 : 1) : 0.9)
                            .animation(Anim.open, value: np.isPlaying)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(Anim.micro) { artHover = h } }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(np.title.isEmpty ? "Unknown" : np.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(np.artist)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color.islandSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            LayerAudioBars(playing: np.isPlaying, color: media.accent)
                                .frame(width: 20, height: 14)
                                .padding(.top, 3)
                        }
                        Spacer(minLength: 6)
                        ProgressScrubber(env: env)
                        Spacer(minLength: 4)
                        HStack(spacing: 18) {
                            Spacer()
                            IslandIconButton(systemName: "backward.fill", size: 15) { media.previous() }
                            IslandIconButton(systemName: np.isPlaying ? "pause.fill" : "play.fill", size: 22, padding: 6) {
                                media.togglePlayPause()
                            }
                            .contentTransition(.symbolEffect(.replace))
                            IslandIconButton(systemName: "forward.fill", size: 15) { media.next() }
                            Spacer()
                        }
                    }
                    .frame(maxHeight: 112)
                }
                .onAppear { media.beginLiveUpdates() }
                .onDisappear { media.endLiveUpdates() }
            } else {
                EmptyPlayer(env: env)
            }
        }
    }
}

private struct ProgressScrubber: View {
    let env: AppEnvironment
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        let np = env.media.now
        let duration = max(np?.duration ?? 0, 1)
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = dragValue ?? np?.elapsed(at: ctx.date) ?? 0
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let frac = min(1, max(0, elapsed / duration))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(env.media.accent.opacity(0.95))
                            .frame(width: max(4, w * frac))
                    }
                    .frame(height: hovering || dragValue != nil ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragValue = min(1, max(0, v.location.x / w)) * duration }
                        .onEnded { v in
                            env.media.seek(to: min(1, max(0, v.location.x / w)) * duration)
                            dragValue = nil
                        })
                }
                .frame(height: 12)
                HStack {
                    Text(formatClock(elapsed))
                    Spacer()
                    Text("-" + formatClock(duration - elapsed))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.islandTertiary)
            }
        }
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
    }
}

private struct EmptyPlayer: View {
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.islandFill)
                Image(systemName: "music.note").font(.system(size: 30, weight: .semibold)).foregroundStyle(Color.islandTertiary)
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Start something in Spotify or Music and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(Color.islandSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: "Spotify", icon: "play.fill") { env.media.launch(.spotify) }
                    PillButton(title: "Music", icon: "music.note") { env.media.launch(.music) }
                }
            }
        }
    }
}

struct PillButton: View {
    let title: String
    var icon: String?
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(hovering ? 0.22 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
    }
}

// MARK: - Calendar

struct CalendarWidget: View {
    let env: AppEnvironment

    var body: some View {
        let cal = env.calendar
        VStack(alignment: .leading, spacing: 8) {
            WeekStrip()
            switch cal.access {
            case .granted:
                if cal.events.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No more events").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        Text("Enjoy the focus time.").font(.system(size: 11.5)).foregroundStyle(Color.islandSecondary)
                    }
                    .padding(.top, 4)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(cal.events.prefix(8)) { ev in EventRow(event: ev) }
                        }
                    }
                }
            case .unknown, .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("See your next meetings here").font(.system(size: 12)).foregroundStyle(Color.islandSecondary)
                    PillButton(title: "Allow Calendar", icon: "calendar") {
                        cal.access == .unknown ? cal.requestAccess() : cal.openPrivacySettings()
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WeekStrip: View {
    var body: some View {
        let cal = Calendar.current
        let today = Date()
        let days = (-2...4).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { d in
                let isToday = cal.isDateInToday(d)
                VStack(spacing: 2) {
                    Text(d.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isToday ? Color.red : Color.islandTertiary)
                    Text(d.formatted(.dateTime.day()))
                        .font(.system(size: 12, weight: isToday ? .bold : .medium, design: .rounded))
                        .foregroundStyle(isToday ? Color.white : Color.islandSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isToday ? Color.red : Color.clear))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct EventRow: View {
    let event: CalEvent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(event.isOngoing ? event.color : Color.islandSecondary)
            }
            Spacer(minLength: 4)
            if let url = event.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(Color.green.opacity(hovering ? 0.75 : 0.55)))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Join meeting")
            }
        }
    }

    private var timeText: String {
        if event.isAllDay { return Calendar.current.isDateInToday(event.start) ? "All day" : "Tomorrow · all day" }
        let fmt = Date.FormatStyle(date: .omitted, time: .shortened)
        let range = "\(event.start.formatted(fmt)) – \(event.end.formatted(fmt))"
        if event.isOngoing { return "Now · until \(event.end.formatted(fmt))" }
        if Calendar.current.isDateInTomorrow(event.start) { return "Tomorrow \(range)" }
        let mins = Int(event.start.timeIntervalSinceNow / 60)
        if mins < 60 { return "in \(max(1, mins))m · \(range)" }
        return range
    }
}
