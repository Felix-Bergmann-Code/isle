import AppKit
import Foundation
import Observation

/// Where the weather is for. `query` is what was searched, so a changed city setting is
/// noticed and geocoded again.
struct WeatherPlace: Codable, Equatable {
    var query: String
    var name: String
    var country: String?
    var latitude: Double
    var longitude: Double
}

/// Today's weather at one place, in the unit it was fetched in.
struct WeatherSnapshot: Codable, Equatable {
    var temperature: Double
    var high: Double?
    var low: Double?
    var code: Int
    var isDay: Bool
    var fahrenheit: Bool
    var fetchedAt: Date

    var symbol: String { WeatherCode.symbol(code, isDay: isDay) }
    var condition: String { WeatherCode.condition(code) }
    var temperatureText: String { Self.degrees(temperature) }

    static func degrees(_ t: Double) -> String { "\(Int(t.rounded()))°" }
}

/// Current conditions from Open-Meteo (free, no key). No location permission: the place is
/// a city name (by default the one in the Mac's time zone, "Europe/Berlin" → "Berlin"),
/// geocoded once and cached. Only that name and its coordinates leave the Mac.
/// Refreshes every 30 min while "Weather on Home" is on, and after wake. A failed request
/// keeps the last value; values older than 3 h are hidden.
@Observable
final class WeatherService {
    /// City typed in Settings; empty means `defaultCity`.
    var city: String {
        didSet {
            guard city != oldValue else { return }
            d.set(city, forKey: Keys.city)
            cityChanged()
        }
    }
    private(set) var place: WeatherPlace?
    private(set) var snapshot: WeatherSnapshot?
    /// The last lookup of the current city found nothing.
    private(set) var notFound = false

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    private enum Keys {
        static let city = "weatherCity"
        static let place = "weatherPlace"
        static let snapshot = "weatherSnapshot"
    }

    static let refreshInterval: TimeInterval = 30 * 60
    static let retryInterval: TimeInterval = 5 * 60
    static let maxAge: TimeInterval = 3 * 60 * 60

    init() {
        city = d.string(forKey: Keys.city) ?? ""
        place = Self.load(WeatherPlace.self, d.data(forKey: Keys.place))
        snapshot = Self.load(WeatherSnapshot.self, d.data(forKey: Keys.snapshot))
    }

    private var enabled: Bool { AppSettings.shared.showWeather }

    /// The city from the time zone ("America/New_York" → "New York"); nil for UTC and friends.
    static var defaultCity: String? {
        let parts = TimeZone.current.identifier.split(separator: "/")
        guard parts.count > 1, parts[0] != "Etc", let last = parts.last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    static var usesFahrenheit: Bool { Locale.current.measurementSystem == .us }

    private var query: String? {
        let typed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? Self.defaultCity : typed
    }

    /// What to show: the last snapshot unless it's too old to be honest about.
    var current: WeatherSnapshot? {
        guard let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < Self.maxAge else { return nil }
        return snapshot
    }

    /// "Berlin · Partly cloudy · high 16°, low 9°"
    var summary: String {
        guard let s = current else { return "" }
        var parts = [s.condition]
        if let name = place?.name { parts.insert(name, at: 0) }
        if let hi = s.high, let lo = s.low {
            parts.append("high \(WeatherSnapshot.degrees(hi)), low \(WeatherSnapshot.degrees(lo))")
        }
        return parts.joined(separator: " · ")
    }

    /// One line for Settings: "Berlin, Germany" or "City not found".
    var status: String? {
        if notFound { return "City not found" }
        guard let place, place.query == query else { return nil }
        return [place.name, place.country].compactMap { $0 }.joined(separator: ", ")
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            // The network usually needs a moment after wake.
            self?.schedule(after: 8)
        }
        applyEnabled()
    }

    /// Called when the weather comes on screen: catches up if a refresh was missed.
    func refreshIfStale() {
        guard enabled, !inFlight, Date().timeIntervalSince(lastAttempt) > 60 else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < Self.refreshInterval,
           snapshot.fahrenheit == Self.usesFahrenheit { return }
        refresh()
    }

    // MARK: Scheduling

    /// Starts or stops the refresh timer to match the "Weather on Home" toggle.
    func applyEnabled() {
        if enabled {
            let age = snapshot.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
            let fresh = age < Self.refreshInterval && snapshot?.fahrenheit == Self.usesFahrenheit && place?.query == query
            schedule(after: fresh ? Self.refreshInterval - age : 0)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        guard enabled else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    private func cityChanged() {
        notFound = false
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            self.refresh()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Network

    private func refresh() {
        guard enabled else { return }
        guard let query else { place = nil; return }
        generation &+= 1
        let gen = generation
        inFlight = true
        lastAttempt = Date()
        if let place, place.query == query {
            fetchForecast(for: place, generation: gen)
        } else {
            geocode(query, generation: gen)
        }
    }

    private func finish(_ gen: Int, ok: Bool) {
        guard gen == generation else { return }
        inFlight = false
        schedule(after: ok ? Self.refreshInterval : Self.retryInterval)
    }

    private func geocode(_ query: String, generation gen: Int) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "1")]
        get(c.url!, as: GeoResponse.self) { [weak self] result in
            guard let self, gen == self.generation else { return }
            guard let result else { return self.finish(gen, ok: false) }
            guard let r = result.results?.first else {
                // A typo won't fix itself: look again on the normal schedule, not every 5 min.
                self.notFound = true
                return self.finish(gen, ok: true)
            }
            let place = WeatherPlace(query: query, name: r.name, country: r.country,
                                     latitude: r.latitude, longitude: r.longitude)
            self.notFound = false
            self.place = place
            // Weather from the old place would now be labelled with the new name.
            self.snapshot = nil
            self.d.set(try? JSONEncoder().encode(place), forKey: Keys.place)
            self.d.removeObject(forKey: Keys.snapshot)
            self.fetchForecast(for: place, generation: gen)
        }
    }

    private func fetchForecast(for place: WeatherPlace, generation gen: Int) {
        let fahrenheit = Self.usesFahrenheit
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        if fahrenheit { c.queryItems?.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit")) }
        get(c.url!, as: ForecastResponse.self) { [weak self] result in
            guard let self, gen == self.generation else { return }
            guard let result else { return self.finish(gen, ok: false) }
            let snap = WeatherSnapshot(temperature: result.current.temperature, high: result.daily.high.first ?? nil,
                                       low: result.daily.low.first ?? nil, code: result.current.code,
                                       isDay: result.current.isDay != 0, fahrenheit: fahrenheit, fetchedAt: Date())
            self.snapshot = snap
            self.d.set(try? JSONEncoder().encode(snap), forKey: Keys.snapshot)
            self.finish(gen, ok: true)
        }
    }

    /// GET + decode off the main thread; the completion runs on main with nil on any failure.
    private func get<T: Decodable>(_ url: URL, as: T.Type, completion: @escaping (T?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let value = ok ? data.flatMap { try? JSONDecoder().decode(T.self, from: $0) } : nil
            DispatchQueue.main.async { completion(value) }
        }.resume()
    }

    private static func load<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

private struct GeoResponse: Decodable {
    struct Result: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
    }
    let results: [Result]?
}

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let code: Int
        let isDay: Int
        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m", code = "weather_code", isDay = "is_day"
        }
    }
    struct Daily: Decodable {
        let high: [Double?]
        let low: [Double?]
        enum CodingKeys: String, CodingKey {
            case high = "temperature_2m_max", low = "temperature_2m_min"
        }
    }
    let current: Current
    let daily: Daily
}

/// WMO weather interpretation codes (what Open-Meteo returns) → SF Symbol and plain words.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func condition(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Cloudy"
        }
    }
}

// MARK: - World clocks

/// A teammate's time zone with a short label ("NYC").
struct WorldClock: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var zone: String

    var timeZone: TimeZone? { TimeZone(identifier: zone) }

    /// The label, or the zone's abbreviation ("EST") when none was typed.
    var displayLabel: String {
        let l = label.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? (timeZone?.abbreviation() ?? "") : l
    }

    /// "America/Argentina/Buenos_Aires" → "Buenos Aires, Argentina".
    static func placeName(_ zone: String) -> String {
        let parts = zone.split(separator: "/").map { $0.replacingOccurrences(of: "_", with: " ") }
        return parts.count > 1 ? parts.dropFirst().reversed().joined(separator: ", ") : zone
    }
}

/// Up to three teammate clocks, persisted. Empty by default so nothing shows until added.
@Observable
final class WorldClockStore {
    static let limit = 3
    static let labelLength = 5

    var clocks: [WorldClock] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(clocks), forKey: "worldClocks") }
    }

    init() {
        clocks = UserDefaults.standard.data(forKey: "worldClocks")
            .flatMap { try? JSONDecoder().decode([WorldClock].self, from: $0) } ?? []
    }

    /// Clocks with a zone this Mac knows.
    var valid: [WorldClock] { clocks.filter { $0.timeZone != nil } }

    func add() {
        guard clocks.count < Self.limit else { return }
        clocks.append(WorldClock(label: "", zone: TimeZone.current.identifier))
    }

    func remove(_ id: UUID) { clocks.removeAll { $0.id == id } }
}
