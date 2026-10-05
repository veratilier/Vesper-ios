import SwiftUI
import CoreLocation
import UIKit

struct WeatherSnapshot {
    struct Hour: Identifiable {
        let date: Date
        let temperature: Double
        let code: Int
        let rainChance: Double?
        var id: Date { date }
    }
    struct Day: Identifiable {
        let date: Date
        let low: Double
        let high: Double
        let code: Int
        let rainChance: Double?
        var id: Date { date }
    }
    let temperature: Double
    let code: Int
    let isDay: Bool
    let feelsLike: Double?
    let humidity: Double?
    let wind: Double?
    let updatedAt: Date
    let timeZone: TimeZone
    let hours: [Hour]
    let days: [Day]
    var condition: String { Self.condition(code) }
    var icon: String { Self.icon(code, isDay: isDay) }
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorms"
        default: "Weather"
        }
    }
    static func icon(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0, 1: isDay ? "sun.max" : "moon.stars"
        case 2: isDay ? "cloud.sun" : "cloud.moon"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51...57: "cloud.drizzle"
        case 61...67, 80...82: "cloud.rain"
        case 71...77, 85, 86: "cloud.snow"
        case 95...99: "cloud.bolt.rain"
        default: "cloud"
        }
    }
    static func number(_ value: JSONValue) -> Double? {
        guard case .number(let n) = value, n.isFinite else { return nil }
        return n
    }
    static func parse(_ value: JSONValue, now: Date = .now) throws -> WeatherSnapshot {
        let current = value["current"]
        guard let temperature = number(current["temperature_2m"]),
              let code = number(current["weather_code"]), (0...99).contains(code),
              let time = number(current["time"]) else {
            throw ServiceError(message: "Weather returned incomplete current conditions. Try again.")
        }
        let hourly = value["hourly"], daily = value["daily"]
        func at(_ array: JSONValue, _ index: Int) -> Double? {
            guard array.array.indices.contains(index) else { return nil }
            return number(array.array[index])
        }
        let hours = hourly["time"].array.enumerated().compactMap { index, item -> Hour? in
            guard let time = number(item), let temperature = at(hourly["temperature_2m"], index),
                  let code = at(hourly["weather_code"], index), (0...99).contains(code) else { return nil }
            let date = Date(timeIntervalSince1970: time)
            guard date >= now.addingTimeInterval(-3600) else { return nil }
            return Hour(date: date, temperature: temperature, code: Int(code), rainChance: at(hourly["precipitation_probability"], index))
        }
        let days = daily["time"].array.enumerated().compactMap { index, item -> Day? in
            guard let time = number(item), let low = at(daily["temperature_2m_min"], index),
                  let high = at(daily["temperature_2m_max"], index), let code = at(daily["weather_code"], index),
                  (0...99).contains(code) else { return nil }
            return Day(date: Date(timeIntervalSince1970: time), low: low, high: high, code: Int(code), rainChance: at(daily["precipitation_probability_max"], index))
        }
        return WeatherSnapshot(temperature: temperature, code: Int(code), isDay: number(current["is_day"]) != 0,
            feelsLike: number(current["apparent_temperature"]), humidity: number(current["relative_humidity_2m"]),
            wind: number(current["wind_speed_10m"]), updatedAt: Date(timeIntervalSince1970: time),
            timeZone: TimeZone(identifier: value["timezone"].string) ?? TimeZone(secondsFromGMT: Int(number(value["utc_offset_seconds"]) ?? 0)) ?? .current,
            hours: Array(hours.prefix(24)), days: Array(days.prefix(7)))
    }
}

enum WeatherService {
    static func url(enabled: Bool, authorized: Bool, latitude: Double, longitude: Double) throws -> URL {
        guard enabled && authorized else { throw ServiceError(message: "Enable weather location to see your forecast.") }
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw ServiceError(message: "Location is unavailable. Try again.")
        }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String((latitude * 100).rounded() / 100)),
            URLQueryItem(name: "longitude", value: String((longitude * 100).rounded() / 100)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "forecast_days", value: "7"), URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime")]
        return url.url!
    }
    static func load(enabled: Bool, authorized: Bool, latitude: Double, longitude: Double,
                     now: Date = .now, transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async throws -> WeatherSnapshot {
        let url = try url(enabled: enabled, authorized: authorized, latitude: latitude, longitude: longitude)
        var request = URLRequest(url: url); request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError(message: "Weather is temporarily unavailable. Try again.")
        }
        return try WeatherSnapshot.parse(JSONDecoder().decode(JSONValue.self, from: data), now: now)
    }
}

@MainActor final class WeatherController: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherController()
    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var loading = false
    @Published var snapshot: WeatherSnapshot?
    @Published private(set) var error: String?
    private let manager: CLLocationManager
    private var request: Task<Void, Never>?
    private var fetchedAt: Date?
    private var generation = UUID()
    var authorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    override init() {
        let locationManager = CLLocationManager()
        manager = locationManager
        let status = locationManager.authorizationStatus
        authorization = status
        // Keep existing weather access for a device that already granted location.
        enabled = UserDefaults.standard.object(forKey: "weatherLocationEnabled") as? Bool
            ?? (status == .authorizedWhenInUse || status == .authorizedAlways)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "weatherLocationEnabled")
        generation = UUID(); request?.cancel(); request = nil
        snapshot = nil; fetchedAt = nil; error = nil; loading = false
        manager.stopUpdatingLocation()
        guard value else { return }
        authorization = manager.authorizationStatus
        if authorization == .notDetermined { loading = true; manager.requestWhenInUseAuthorization() }
        else { refresh(force: true) }
    }
    func refresh(force: Bool = false) {
        authorization = manager.authorizationStatus
        guard enabled else { return }
        guard authorized else {
            snapshot = nil
            if authorization == .denied || authorization == .restricted { error = "Allow location access in iPhone Settings to see local weather." }
            return
        }
        guard !loading else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 15 * 60 { return }
        loading = true; error = nil
        manager.requestLocation()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorization = self.manager.authorizationStatus
            self.generation = UUID(); self.request?.cancel(); self.request = nil
            self.loading = false
            if !self.authorized { self.snapshot = nil; self.fetchedAt = nil }
            if self.enabled { self.refresh(force: true) }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            guard self.enabled && self.authorized, let coordinate else { self.loading = false; return }
            let generation = UUID(); self.generation = generation
            self.request?.cancel()
            self.request = Task {
                defer { if self.generation == generation { self.loading = false; self.request = nil } }
                do {
                    let snapshot = try await WeatherService.load(enabled: self.enabled, authorized: self.authorized,
                        latitude: coordinate.latitude, longitude: coordinate.longitude)
                    guard self.generation == generation, self.enabled && self.authorized else { return }
                    self.snapshot = snapshot; self.fetchedAt = .now
                } catch {
                    if !Task.isCancelled && self.generation == generation { self.error = error.localizedDescription }
                }
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.enabled else { return }
            self.loading = false; self.error = "Location is unavailable. Try again."
        }
    }
}

struct WeatherPermissionsView: View {
    @ObservedObject private var weather = WeatherController.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        PermissionPage(title: "Location") {
            PermissionPanel {
                Toggle("Use location for weather", isOn: Binding(get: { weather.enabled }, set: { weather.setEnabled($0) }))
                    .accessibilityIdentifier("weather-location-permission")
                Text(status).font(.subheadline).foregroundStyle(VesperTheme.muted)
                if weather.enabled && !weather.authorized {
                    if weather.authorization == .notDetermined {
                        Button("Allow location") { weather.setEnabled(true) }.buttonStyle(PermissionActionStyle())
                    } else { Button("Open iPhone Settings") { openSettings() }.buttonStyle(PermissionActionStyle()) }
                }
            }
            PermissionPanel {
                Text("Uses your approximate location while Vesper is open. Coordinates rounded to about 1 km are sent to Open-Meteo to fetch weather. Turning this off stops weather location requests.")
            }
        }
            .onChange(of: phase) { _, value in if value == .active { weather.refresh() } }
    }
    private var status: String {
        if !weather.enabled { return "Weather location is off." }
        if weather.authorized { return "Location allowed while using Vesper." }
        if weather.authorization == .notDetermined { return "Waiting for location permission." }
        return "Location access is unavailable."
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct WeatherView: View {
    @ObservedObject var weather = WeatherController.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let snapshot = weather.snapshot {
                    current(snapshot)
                    if !snapshot.hours.isEmpty { hourly(snapshot) }
                    if !snapshot.days.isEmpty { daily(snapshot) }
                    details(snapshot)
                    if let error = weather.error { Text(error).font(.caption).foregroundStyle(VesperTheme.muted) }
                    Link("Weather data by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                } else if weather.loading {
                    ProgressView("Finding your local weather…").frame(minHeight: 220)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "cloud.sun").font(.system(size: 52, weight: .ultraLight))
                        Text("The sky, where you are.").font(.system(.title3, design: .serif)).italic()
                        if let error = weather.error { Text(error).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(VesperTheme.muted) }
                        if weather.enabled && weather.authorized { Button("Try again") { weather.refresh(force: true) } }
                        NavigationLink("Weather access") { WeatherPermissionsView() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 55)
                }
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .navigationTitle("Weather").navigationBarTitleDisplayMode(.inline)
        .transparentNavigationTop().background { Background() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { WeatherPermissionsView() } label: { Image(systemName: "location") }.accessibilityLabel("Weather location permission")
            }
        }
        .refreshable { weather.refresh(force: true) }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                weather.refresh()
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }
    private func current(_ snapshot: WeatherSnapshot) -> some View {
        VStack(spacing: 8) {
            Text("Current location").font(.system(.title3, design: .serif)).foregroundStyle(VesperTheme.muted)
            Image(systemName: snapshot.icon).font(.system(size: 48, weight: .ultraLight)).padding(.top, 10)
            Text("\(Int(snapshot.temperature.rounded()))°").font(.system(size: 76, weight: .ultraLight, design: .serif))
            Text(snapshot.condition).font(.system(.title3, design: .serif))
            if let day = snapshot.days.first { Text("H: \(Int(day.high.rounded()))°   L: \(Int(day.low.rounded()))°").font(.subheadline).foregroundStyle(VesperTheme.muted) }
            Text("Updated " + date(snapshot.updatedAt, format: "HH:mm", zone: snapshot.timeZone))
                .font(.caption2).foregroundStyle(VesperTheme.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 14)
    }
    private func hourly(_ snapshot: WeatherSnapshot) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Next 24 hours").font(.system(.subheadline, design: .serif))
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(snapshot.hours) { hour in
                            VStack(spacing: 11) {
                                Text(date(hour.date, format: "HH:mm", zone: snapshot.timeZone)).font(.caption2)
                                Image(systemName: WeatherSnapshot.icon(hour.code, isDay: localHour(hour.date, zone: snapshot.timeZone) >= 6 && localHour(hour.date, zone: snapshot.timeZone) < 18))
                                    .font(.system(size: 22))
                                Text("\(Int(hour.temperature.rounded()))°").font(.subheadline)
                                Text(hour.rainChance.map { "\(Int($0))%" } ?? "—").font(.caption2).foregroundStyle(VesperTheme.muted)
                            }.frame(width: 45)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
    }
    private func daily(_ snapshot: WeatherSnapshot) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("7-day forecast").font(.system(.subheadline, design: .serif))
                ForEach(snapshot.days) { day in
                    HStack(spacing: 12) {
                        Text(date(day.date, format: "EEE", zone: snapshot.timeZone)).font(.subheadline).frame(width: 40, alignment: .leading)
                        Image(systemName: WeatherSnapshot.icon(day.code)).frame(width: 28)
                        Text(day.rainChance.map { "\(Int($0))%" } ?? "—").font(.caption2).foregroundStyle(VesperTheme.muted)
                        Spacer()
                        Text("\(Int(day.low.rounded()))°").foregroundStyle(VesperTheme.muted)
                        Text("\(Int(day.high.rounded()))°").frame(width: 34, alignment: .trailing)
                    }.font(.subheadline).frame(minHeight: 30)
                }
            }
        }
    }
    private func details(_ snapshot: WeatherSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                detail("Feels like", snapshot.feelsLike.map { "\(Int($0.rounded()))°" } ?? "—", "thermometer.medium")
                detail("Humidity", snapshot.humidity.map { "\(Int($0))%" } ?? "—", "humidity")
                detail("Wind", snapshot.wind.map { "\(Int($0.rounded())) km/h" } ?? "—", "wind")
            }
            VStack(spacing: 10) {
                detail("Feels like", snapshot.feelsLike.map { "\(Int($0.rounded()))°" } ?? "—", "thermometer.medium")
                detail("Humidity", snapshot.humidity.map { "\(Int($0))%" } ?? "—", "humidity")
                detail("Wind", snapshot.wind.map { "\(Int($0.rounded())) km/h" } ?? "—", "wind")
            }
        }
    }
    private func detail(_ title: String, _ value: String, _ icon: String) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(VesperTheme.muted)
                Text(value).font(.system(.subheadline, design: .serif)).fixedSize()
            }
        }
    }
    private func date(_ value: Date, format: String, zone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = format; formatter.timeZone = zone
        return formatter.string(from: value)
    }
    private func localHour(_ date: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.component(.hour, from: date)
    }
}
