import SwiftUI
import HealthKit

@MainActor final class HealthReader: ObservableObject {
    private let health = HKHealthStore()
    @Published var rows: [(String, String)] = []
    @Published var busy = false
    @Published var error = ""
    @Published var updated: Date?
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private var types: Set<HKObjectType> {
        let requested: [HKObjectType?] = [HKObjectType.quantityType(forIdentifier: .heartRate), HKObjectType.quantityType(forIdentifier: .stepCount), HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature), HKObjectType.categoryType(forIdentifier: .sleepAnalysis)]
        return Set(requested.compactMap { $0 })
    }
    func connect() async {
        guard available, !busy else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            try await health.requestAuthorization(toShare: [], read: types)
            try await read()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard available, !busy else { return }
        busy = true; error = ""; defer { busy = false }
        do { try await read() } catch { self.error = error.localizedDescription }
    }
    private func samples(_ type: HKSampleType, since: Date, limit: Int = HKObjectQueryNoLimit) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: since, end: .now), limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            health.execute(query)
        }
    }
    private func read() async throws {
        let now = Date(); let start = Calendar.current.startOfDay(for: now)
        var values: [(String, String)] = []
        let heart = try await samples(HKQuantityType.quantityType(forIdentifier: .heartRate)!, since: now.addingTimeInterval(-86400), limit: 1).first as? HKQuantitySample
        values.append(("Latest heart rate · 24 hours", heart.map { String(format: "%.0f bpm", $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) + " · " + $0.endDate.formatted(date: .omitted, time: .shortened) } ?? "No readable data"))
        let steps: Double? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: HKQuantityType.quantityType(forIdentifier: .stepCount)!, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: now), options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count())) }
            }; health.execute(query)
        }
        values.append(("Steps today", steps.map { String(format: "%.0f", $0) } ?? "No readable data"))
        let since = now.addingTimeInterval(-86400)
        let sleep = try await samples(HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!, since: since).compactMap { $0 as? HKCategorySample }.filter { [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains($0.value) }
        // Union overlapping intervals so watch/phone sources never double-count sleep.
        let intervals = sleep.map { (max($0.startDate, since), min($0.endDate, now)) }.sorted { $0.0 < $1.0 }
        var end = since; var seconds = 0.0
        for (a,b) in intervals { seconds += max(0, b.timeIntervalSince(max(a,end))); end = max(end,b) }
        values.append(("Sleep · past 24 hours", sleep.isEmpty ? "No readable data" : "\(Int(seconds) / 3600) h \(Int(seconds) % 3600 / 60) min"))
        let wrist = try await samples(HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature)!, since: now.addingTimeInterval(-7 * 86400), limit: 1).first as? HKQuantitySample
        values.append(("Sleeping wrist temperature · latest 7 days", wrist.map { String(format: "%.2f °C", $0.quantity.doubleValue(for: .degreeCelsius())) + " · " + $0.endDate.formatted(date: .abbreviated, time: .omitted) } ?? "No readable data"))
        rows = values; updated = now
    }
}

struct HealthView: View {
    @StateObject private var reader = HealthReader()
    var body: some View {
        Page(title: "Health", subtitle: "A little care for your day.") {
            GlassCard { VStack(alignment: .leading, spacing: 14) {
                Text("Choose which Health data Vesper may read. These readings stay on this device; they are not sent to Rowan or the server.").font(.subheadline)
                Button { Task { await reader.connect() } } label: { Text("Choose Health permissions").foregroundStyle(.white).padding(14).background(VesperTheme.ink, in: Capsule()) }.buttonStyle(.plain).disabled(reader.busy || !reader.available)
                if !reader.available { Text("HealthKit is not available on this device.") }
                Text("No readable data can mean no recorded samples or no read permission. Vesper cannot tell which; change access in the Health app.").font(.caption).foregroundStyle(VesperTheme.muted)
                if reader.busy { ProgressView() }
                if !reader.error.isEmpty { Text(reader.error).font(.caption).foregroundStyle(.red) }
            } }
            ForEach(Array(reader.rows.enumerated()), id: \.offset) { _, row in GlassCard { VStack(alignment: .leading, spacing: 8) { Text(row.0).font(.caption).foregroundStyle(VesperTheme.muted); Text(row.1).font(.title3) }.frame(maxWidth: .infinity, alignment: .leading) } }
            if let updated = reader.updated { Text("Read at " + updated.formatted()).font(.caption); Button("Refresh") { Task { await reader.refresh() } }.disabled(reader.busy) }
        }
    }
}
