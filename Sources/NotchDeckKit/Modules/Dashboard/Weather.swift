import Foundation

public struct WeatherSnapshot: Equatable, Sendable {
    public var tempC: Double
    /// WMO weather interpretation code.
    public var code: Int
    public var hiC: Double
    public var loC: Double

    public init(tempC: Double, code: Int, hiC: Double, loC: Double) {
        self.tempC = tempC
        self.code = code
        self.hiC = hiC
        self.loC = loC
    }
}

/// Parses Open-Meteo forecast responses. Pure and tested.
public enum WeatherParser {
    public static func parse(data: Data) -> WeatherSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? NSNumber,
              let code = current["weather_code"] as? NSNumber else { return nil }
        var hi = temp.doubleValue
        var lo = temp.doubleValue
        if let daily = root["daily"] as? [String: Any] {
            hi = (daily["temperature_2m_max"] as? [NSNumber])?.first?.doubleValue ?? hi
            lo = (daily["temperature_2m_min"] as? [NSNumber])?.first?.doubleValue ?? lo
        }
        return WeatherSnapshot(
            tempC: temp.doubleValue, code: code.intValue, hiC: hi, loC: lo
        )
    }

    /// WMO code → SF Symbol. Tested for representative buckets.
    public static func symbol(for code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57, 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

@MainActor
final class WeatherService: ObservableObject {
    static let enabledKey = "dashboard.weather.enabled"

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var locationName: String?
    /// Off → no requests to ipinfo.io or open-meteo.com at all.
    @Published private(set) var isEnabled =
        UserDefaults.standard.object(forKey: WeatherService.enabledKey) as? Bool ?? true

    private var refreshTask: Task<Void, Never>?
    private var isActive = false

    func activate() {
        isActive = true
        startIfNeeded()
    }

    func deactivate() {
        isActive = false
        stop()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startIfNeeded()
        } else {
            stop()
            snapshot = nil
            locationName = nil
        }
    }

    private func startIfNeeded() {
        guard isActive, isEnabled, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() async {
        // Keyless IP geolocation; good enough for weather granularity.
        guard let ipData = try? await URLSession.shared.data(
            from: URL(string: "https://ipinfo.io/json")!
        ).0,
            let ipJSON = try? JSONSerialization.jsonObject(with: ipData) as? [String: Any],
            let loc = ipJSON["loc"] as? String else { return }
        let parts = loc.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return }
        guard isEnabled else { return }
        locationName = ipJSON["city"] as? String

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!) else { return }
        if isEnabled, let parsed = WeatherParser.parse(data: data) {
            snapshot = parsed
        }
    }
}
