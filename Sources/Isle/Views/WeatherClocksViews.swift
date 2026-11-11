import SwiftUI

// MARK: - Weather glance

/// Today's weather in the open header, on Home only: one multicolor glyph and the
/// temperature. Details live in the tooltip. Nothing at all without fresh data.
struct WeatherAccessory: View {
    let env: AppEnvironment

    var body: some View {
        if env.vm.tab == .home, AppSettings.shared.showWeather, let w = env.weather.current {
            HStack(spacing: 4) {
                Image(systemName: w.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 12))
                Text(w.temperatureText)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .help(env.weather.summary)
            .transition(.opacity)
            .onAppear { env.weather.refreshIfStale() }
        }
    }
}

// MARK: - World clocks

/// Teammates' local times in one row at the bottom of the Calendar column, e.g. "NYC 04:12",
/// with a small moon when it's night there. Only exists once a clock is added in Settings.
/// The TimelineView ticks once a minute and only while the island is open.
struct WorldClocksRow: View {
    let env: AppEnvironment

    var body: some View {
        let clocks = env.worldClocks.valid
        if AppSettings.shared.showWorldClocks, !clocks.isEmpty {
            TimelineView(.everyMinute) { ctx in
                // Three clocks with moons can be wider than the column: tighten, then drop moons.
                ViewThatFits(in: .horizontal) {
                    row(clocks, at: ctx.date, spacing: 12, moons: true)
                    row(clocks, at: ctx.date, spacing: 8, moons: true)
                    row(clocks, at: ctx.date, spacing: 8, moons: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ clocks: [WorldClock], at date: Date, spacing: CGFloat, moons: Bool) -> some View {
        HStack(spacing: spacing) {
            ForEach(clocks) { clock in
                ClockItem(clock: clock, date: date, showMoon: moons)
            }
        }
        .lineLimit(1)
    }
}

private struct ClockItem: View {
    let clock: WorldClock
    let date: Date
    let showMoon: Bool

    var body: some View {
        let tz = clock.timeZone ?? .current
        HStack(spacing: 4) {
            Text(clock.displayLabel.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Color.islandTertiary)
            Text(date.formatted(Self.style(tz, hour: .defaultDigits(amPM: .omitted))))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.islandSecondary)
            if showMoon && isNight(in: tz) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.islandTertiary)
            }
        }
        .help("\(WorldClock.placeName(clock.zone)) · \(date.formatted(Self.style(tz, hour: .defaultDigits(amPM: .abbreviated)).weekday(.abbreviated)))")
    }

    private func isNight(in tz: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let h = cal.component(.hour, from: date)
        return h >= 22 || h < 7
    }

    private static func style(_ tz: TimeZone, hour: Date.FormatStyle.Symbol.Hour) -> Date.FormatStyle {
        var f = Date.FormatStyle.dateTime.hour(hour).minute(.twoDigits)
        f.timeZone = tz
        return f
    }
}

// MARK: - Settings

/// Settings → Home: the weather glance and the world clocks.
struct WeatherClocksSettings: View {
    @Bindable var settings = AppSettings.shared
    @Bindable var weather: WeatherService
    @Bindable var store: WorldClockStore

    init(env: AppEnvironment) {
        weather = env.weather
        store = env.worldClocks
    }

    var body: some View {
        Section {
            SettingToggle("Weather on Home", subtitle: "Today's weather in the Home header; hover it for the high and low.",
                          symbol: "cloud.sun.fill", color: .cyan, isOn: $settings.showWeather)
                .onChange(of: settings.showWeather) { weather.applyEnabled() }
                .settingAnchor("weather")
            TextField(text: $weather.city, prompt: Text(WeatherService.defaultCity ?? "City")) {
                SettingLabel(title: "City", subtitle: "Empty uses the city of your time zone.", symbol: "mappin.and.ellipse", color: .red)
            }
            .disabled(!settings.showWeather)
            if settings.showWeather, let status = weather.status {
                SettingNote(status)
            }
        } header: {
            Text("Weather")
        } footer: {
            SettingNote("From Open-Meteo, with no location access. Only the city and its coordinates are sent, nothing about you.", symbol: "lock.fill")
        }

        Section {
            SettingToggle("Clocks on Home", subtitle: "Up to \(WorldClockStore.limit) teammate clocks at the bottom of the calendar, with a moon at night there.",
                          symbol: "globe.europe.africa.fill", color: .blue, isOn: $settings.showWorldClocks)
                .settingAnchor("clocks")
            ForEach($store.clocks) { $clock in
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    TextField("Label", text: Binding(
                        get: { clock.label },
                        set: { clock.label = String($0.prefix(WorldClockStore.labelLength)) }
                    ), prompt: Text(clock.timeZone?.abbreviation() ?? "NYC"))
                    .labelsHidden()
                    .frame(width: 64)
                    TimeZoneMenu(selection: $clock.zone)
                    Spacer(minLength: 0)
                    Button { store.remove(clock.id) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .disabled(!settings.showWorldClocks)
            }
            if store.clocks.count < WorldClockStore.limit {
                Button { store.add() } label: { Label("Add Clock", systemImage: "plus") }
                    .disabled(!settings.showWorldClocks)
            }
        } header: {
            Text("World clocks")
        }
    }
}

/// Native menu of every known time zone, one submenu per region ("Europe" → "Berlin").
private struct TimeZoneMenu: View {
    @Binding var selection: String

    var body: some View {
        Menu(WorldClock.placeName(selection)) {
            ForEach(Self.regions, id: \.name) { region in
                Menu(region.name) {
                    ForEach(region.zones, id: \.self) { zone in
                        Button(WorldClock.placeName(zone)) { selection = zone }
                    }
                }
            }
        }
        .fixedSize()
    }

    private static let regions: [(name: String, zones: [String])] = {
        let grouped = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers) { id in
            id.contains("/") ? String(id.prefix { $0 != "/" }) : "Other"
        }
        return grouped.keys.sorted { a, b in a == "Other" ? false : b == "Other" ? true : a < b }.map { key in
            (key, grouped[key]!.sorted { WorldClock.placeName($0) < WorldClock.placeName($1) })
        }
    }()
}
