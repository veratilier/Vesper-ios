import SwiftUI
import HealthKit

private struct HealthMetric {
    let id: String
    let title: String
    let group: String
    let type: HKSampleType
    let unit: HKUnit?
    let suffix: String
    let scale: Double
    let days: Int

    static let catalog: [HealthMetric] = {
        let count = HKUnit.count()
        let minute = HKUnit.minute()
        let gram = HKUnit.gram()
        let mg = HKUnit.gramUnit(with: .milli)
        let microgram = HKUnit.gramUnit(with: .micro)
        let percent = HKUnit.percent()
        let meter = HKUnit.meter()
        let km = HKUnit.meterUnit(with: .kilo)
        let bpm = count.unitDivided(by: minute)
        let metersPerSecond = meter.unitDivided(by: .second())
        func q(_ id: String, _ title: String, _ group: String, _ type: HKQuantityTypeIdentifier, _ unit: HKUnit, _ suffix: String, _ scale: Double = 1, _ days: Int = 365) -> HealthMetric? {
            guard let sampleType = HKObjectType.quantityType(forIdentifier: type) else { return nil }
            return HealthMetric(id: id, title: title, group: group, type: sampleType, unit: unit, suffix: suffix, scale: scale, days: days)
        }
        func c(_ id: String, _ title: String, _ group: String, _ type: HKCategoryTypeIdentifier, _ days: Int = 365) -> HealthMetric? {
            guard let sampleType = HKObjectType.categoryType(forIdentifier: type) else { return nil }
            return HealthMetric(id: id, title: title, group: group, type: sampleType, unit: nil, suffix: "", scale: 1, days: days)
        }
        let nutrition: [(String, String, HKQuantityTypeIdentifier, HKUnit, String)] = [
            ("biotin", "Biotin", .dietaryBiotin, microgram, "µg"),
            ("caffeine", "Caffeine", .dietaryCaffeine, mg, "mg"),
            ("calcium", "Calcium", .dietaryCalcium, mg, "mg"),
            ("carbohydrates", "Carbohydrates", .dietaryCarbohydrates, gram, "g"),
            ("chloride", "Chloride", .dietaryChloride, mg, "mg"),
            ("chromium", "Chromium", .dietaryChromium, microgram, "µg"),
            ("copper", "Copper", .dietaryCopper, mg, "mg"),
            ("cholesterol", "Dietary cholesterol", .dietaryCholesterol, mg, "mg"),
            ("dietary_energy", "Dietary energy", .dietaryEnergyConsumed, .kilocalorie(), "kcal"),
            ("sugar", "Dietary sugar", .dietarySugar, gram, "g"),
            ("fiber", "Fiber", .dietaryFiber, gram, "g"),
            ("folate", "Folate", .dietaryFolate, microgram, "µg"),
            ("iodine", "Iodine", .dietaryIodine, microgram, "µg"),
            ("iron", "Iron", .dietaryIron, mg, "mg"),
            ("magnesium", "Magnesium", .dietaryMagnesium, mg, "mg"),
            ("manganese", "Manganese", .dietaryManganese, mg, "mg"),
            ("molybdenum", "Molybdenum", .dietaryMolybdenum, microgram, "µg"),
            ("monounsaturated_fat", "Monounsaturated fat", .dietaryFatMonounsaturated, gram, "g"),
            ("niacin", "Niacin", .dietaryNiacin, mg, "mg"),
            ("pantothenic_acid", "Pantothenic acid", .dietaryPantothenicAcid, mg, "mg"),
            ("phosphorus", "Phosphorus", .dietaryPhosphorus, mg, "mg"),
            ("polyunsaturated_fat", "Polyunsaturated fat", .dietaryFatPolyunsaturated, gram, "g"),
            ("potassium", "Potassium", .dietaryPotassium, mg, "mg"),
            ("protein", "Protein", .dietaryProtein, gram, "g"),
            ("riboflavin", "Riboflavin", .dietaryRiboflavin, mg, "mg"),
            ("saturated_fat", "Saturated fat", .dietaryFatSaturated, gram, "g"),
            ("selenium", "Selenium", .dietarySelenium, microgram, "µg"),
            ("sodium", "Sodium", .dietarySodium, mg, "mg"),
            ("thiamin", "Thiamin", .dietaryThiamin, mg, "mg"),
            ("total_fat", "Total fat", .dietaryFatTotal, gram, "g"),
            ("vitamin_a", "Vitamin A", .dietaryVitaminA, microgram, "µg"),
            ("vitamin_b12", "Vitamin B12", .dietaryVitaminB12, microgram, "µg"),
            ("vitamin_b6", "Vitamin B6", .dietaryVitaminB6, mg, "mg"),
            ("vitamin_c", "Vitamin C", .dietaryVitaminC, mg, "mg"),
            ("vitamin_d", "Vitamin D", .dietaryVitaminD, microgram, "µg"),
            ("vitamin_e", "Vitamin E", .dietaryVitaminE, mg, "mg"),
            ("vitamin_k", "Vitamin K", .dietaryVitaminK, microgram, "µg"),
            ("water", "Water", .dietaryWater, .literUnit(with: .milli), "mL"),
            ("zinc", "Zinc", .dietaryZinc, mg, "mg")
        ]
        let main: [HealthMetric?] = [
            c("menstruation", "Menstruation", "Cycle tracking", .menstrualFlow),
            c("ovulation_test", "Ovulation test result", "Cycle tracking", .ovulationTestResult),
            q("active_energy", "Active energy", "Activity", .activeEnergyBurned, .kilocalorie(), "kcal"),
            q("cycling_distance", "Cycling distance", "Activity", .distanceCycling, km, "km"),
            q("exercise_minutes", "Exercise minutes", "Activity", .appleExerciseTime, minute, "min"),
            q("flights_climbed", "Flights climbed", "Activity", .flightsClimbed, count, "flights"),
            q("resting_energy", "Resting energy", "Activity", .basalEnergyBurned, .kilocalorie(), "kcal"),
            q("stand_minutes", "Stand minutes", "Activity", .appleStandTime, minute, "min"),
            q("steps", "Steps today", "Activity", .stepCount, count, "steps"),
            q("swimming_distance", "Swimming distance", "Activity", .distanceSwimming, km, "km"),
            q("walking_running_distance", "Walking + running distance", "Activity", .distanceWalkingRunning, km, "km"),
            HealthMetric(id: "workouts", title: "Workouts", group: "Activity", type: HKObjectType.workoutType(), unit: nil, suffix: "", scale: 1, days: 365),
            q("body_fat", "Body fat percentage", "Body measurements", .bodyFatPercentage, percent, "%"),
            q("bmi", "Body mass index", "Body measurements", .bodyMassIndex, count, ""),
            q("height", "Height", "Body measurements", .height, .meterUnit(with: .centi), "cm"),
            q("lean_body_mass", "Lean body mass", "Body measurements", .leanBodyMass, .gramUnit(with: .kilo), "kg"),
            q("waist", "Waist circumference", "Body measurements", .waistCircumference, .meterUnit(with: .centi), "cm"),
            q("weight", "Weight", "Body measurements", .bodyMass, .gramUnit(with: .kilo), "kg"),
            q("environmental_sound", "Environmental sound levels", "Hearing", .environmentalAudioExposure, .decibelAWeightedSoundPressureLevel(), "dBA"),
            q("headphone_audio", "Headphone audio levels", "Hearing", .headphoneAudioExposure, .decibelAWeightedSoundPressureLevel(), "dBA"),
            q("afib_history", "AFib history", "Heart", .atrialFibrillationBurden, percent, "%"),
            HKObjectType.correlationType(forIdentifier: .bloodPressure).map { HealthMetric(id: "blood_pressure", title: "Blood pressure", group: "Heart", type: $0, unit: nil, suffix: "", scale: 1, days: 365) },
            q("cardio_fitness", "Cardio fitness", "Heart", .vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: minute), "mL/kg/min"),
            c("cardio_fitness_notification", "Cardio fitness notification", "Heart", .lowCardioFitnessEvent),
            HealthMetric(id: "ecg", title: "Electrocardiogram (ECG)", group: "Heart", type: HKObjectType.electrocardiogramType(), unit: nil, suffix: "", scale: 1, days: 365),
            q("heart_rate", "Latest heart rate", "Heart", .heartRate, bpm, "bpm", 1, 1),
            q("hrv", "Heart rate variability", "Heart", .heartRateVariabilitySDNN, .secondUnit(with: .milli), "ms"),
            c("high_heart_notification", "High heart rate notification", "Heart", .highHeartRateEvent),
            c("irregular_rhythm_notification", "Irregular rhythm notification", "Heart", .irregularHeartRhythmEvent),
            c("low_heart_notification", "Low heart rate notification", "Heart", .lowHeartRateEvent),
            q("resting_heart_rate", "Resting heart rate", "Heart", .restingHeartRate, bpm, "bpm"),
            q("walking_heart_rate", "Walking heart rate average", "Heart", .walkingHeartRateAverage, bpm, "bpm"),
            c("mindful_minutes", "Mindful minutes", "Mental wellbeing", .mindfulSession),
            q("double_support", "Double support time", "Mobility", .walkingDoubleSupportPercentage, percent, "%"),
            q("six_minute_walk", "Six-minute walk", "Mobility", .sixMinuteWalkTestDistance, meter, "m"),
            q("stair_speed_down", "Stair speed: down", "Mobility", .stairDescentSpeed, metersPerSecond, "m/s"),
            q("stair_speed_up", "Stair speed: up", "Mobility", .stairAscentSpeed, metersPerSecond, "m/s"),
            q("walking_asymmetry", "Walking asymmetry", "Mobility", .walkingAsymmetryPercentage, percent, "%"),
            q("walking_speed", "Walking speed", "Mobility", .walkingSpeed, metersPerSecond, "m/s"),
            q("step_length", "Walking step length", "Mobility", .walkingStepLength, meter, "m"),
        ]
        let tail: [HealthMetric?] = [
            q("insulin", "Insulin delivery", "Other data", .insulinDelivery, .internationalUnit(), "IU"),
            q("blood_oxygen", "Blood oxygen", "Respiratory", .oxygenSaturation, percent, "%"),
            q("respiratory_rate", "Respiratory rate", "Respiratory", .respiratoryRate, bpm, "breaths/min"),
            c("sleep", "Sleep · past 24 hours", "Sleep", .sleepAnalysis, 1),
            q("blood_glucose", "Blood glucose", "Vitals", .bloodGlucose, mg.unitDivided(by: .literUnit(with: .deci)), "mg/dL"),
            q("body_temperature", "Body temperature", "Vitals", .bodyTemperature, .degreeCelsius(), "°C"),
            q("wrist_temperature", "Sleeping wrist temperature", "Vitals", .appleSleepingWristTemperature, .degreeCelsius(), "°C", 1, 7)
        ]
        return main.compactMap { $0 } + nutrition.compactMap { q($0.0, $0.1, "Nutrition", $0.2, $0.3, $0.4) } + tail.compactMap { $0 }
    }()

    static let characteristicNames: [(String, String)] = [
        ("blood_type", "Blood type"), ("date_of_birth", "Date of birth"),
        ("skin_type", "Fitzpatrick skin type"), ("sex", "Biological sex"), ("wheelchair", "Wheelchair use")
    ]
    static let defaultIDs = ["heart_rate", "steps", "sleep", "wrist_temperature"]
}

@MainActor final class HealthReader: ObservableObject {
    private let health = HKHealthStore()
    @Published var rows: [(String, String)] = []
    @Published var busy = false
    @Published var error = ""
    @Published var updated: Date?
    private(set) var requestedIDs: [String] = []
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private var accessError: String? {
        guard available else { return "Health data is unavailable on this device." }
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String,
              !purpose.isEmpty else { return "This app build is missing the Health read privacy description." }
        return nil
    }
    static var catalog: JSONValue {
        .array(HealthMetric.catalog.map { .object(["id": .string($0.id), "name": .string($0.title), "group": .string($0.group)]) } + HealthMetric.characteristicNames.map { .object(["id": .string($0.0), "name": .string($0.1), "group": .string("Me")]) })
    }
    private var types: Set<HKObjectType> {
        var values = Set<HKObjectType>(HealthMetric.catalog.map { $0.type as HKObjectType })
        if let systolic = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic) { values.insert(systolic) }
        if let diastolic = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) { values.insert(diastolic) }
        for id: HKCharacteristicTypeIdentifier in [.bloodType, .dateOfBirth, .fitzpatrickSkinType, .biologicalSex, .wheelchairUse] {
            if let type = HKObjectType.characteristicType(forIdentifier: id) { values.insert(type) }
        }
        return values
    }
    func connect() async {
        guard !busy else { return }
        if let accessError { error = accessError; return }
        busy = true; error = ""; defer { busy = false }
        do {
            try await health.requestAuthorization(toShare: [], read: types)
            await read(requestedIDs: HealthMetric.defaultIDs)
        } catch { self.error = error.localizedDescription }
    }
    func refresh(requestedIDs: [String] = HealthMetric.defaultIDs) async {
        guard !busy else { return }
        if let accessError { error = accessError; return }
        busy = true; error = ""; defer { busy = false }
        await read(requestedIDs: requestedIDs)
    }
    var snapshot: JSONValue {
        .object(["available": .bool(available), "readAt": .string(updated.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
                 "requested": .array(requestedIDs.map { .string($0) }),
                 "readings": .array(rows.map { .object(["metric": .string($0.0), "value": .string($0.1)]) }),
                 "error": .string(error),
                 "note": .string("No readable data can mean no samples or no read access. These are HealthKit summaries, not diagnoses; an authorization request does not prove read access was granted.")])
    }
    private func samples(_ type: HKSampleType, since: Date, limit: Int = 1) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: since, end: .now), limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            health.execute(query)
        }
    }
    private func safeSamples(_ type: HKSampleType, since: Date, limit: Int = 1) async -> [HKSample] {
        do { return try await samples(type, since: since, limit: limit) }
        catch { self.error += (self.error.isEmpty ? "" : "\n") + error.localizedDescription; return [] }
    }
    private func read(requestedIDs ids: [String]) async {
        let all = ids.contains("all")
        let chosen = HealthMetric.catalog.filter { all || ids.contains($0.id) || ids.contains($0.group.lowercased().replacingOccurrences(of: " ", with: "_")) }
        let characteristics = HealthMetric.characteristicNames.filter { all || ids.contains($0.0) || ids.contains("me") }
        requestedIDs = ids
        let unknown = ids.filter { id in
            id != "all" && !HealthMetric.catalog.contains(where: { $0.id == id || $0.group.lowercased().replacingOccurrences(of: " ", with: "_") == id })
            && !HealthMetric.characteristicNames.contains(where: { $0.0 == id }) && id != "me"
        }
        if !unknown.isEmpty { error = "Unknown metrics: " + unknown.joined(separator: ", ") }
        var values: [(String, String)] = []
        // Keep a broad read responsive without flooding HealthKit with every query at once.
        for start in stride(from: 0, to: chosen.count, by: 8) {
            let slice = Array(chosen[start..<min(start + 8, chosen.count)])
            let batch = await withTaskGroup(of: (Int, String).self, returning: [(Int, String)].self) { group in
                for (index, metric) in slice.enumerated() {
                    group.addTask { (index, await self.value(for: metric)) }
                }
                var results: [(Int, String)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            values += batch.map { (slice[$0.0].title, $0.1) }
        }
        for (id, title) in characteristics { values.append((title, characteristic(id))) }
        rows = values; updated = Date()
    }
    private func value(for metric: HealthMetric) async -> String {
        let now = Date()
        if metric.id == "steps" { return await stepsToday() }
        if metric.id == "sleep" { return await sleepPastDay() }
        let sample = await safeSamples(metric.type, since: now.addingTimeInterval(-Double(metric.days) * 86400)).first
        guard let sample else { return "No readable data" }
        let when = sample.endDate.formatted(date: .abbreviated, time: .shortened)
        if let quantity = sample as? HKQuantitySample, let unit = metric.unit {
            let number = quantity.quantity.doubleValue(for: unit) * metric.scale
            return String(format: "%.1f %@ · %@", number, metric.suffix, when)
        }
        if let pressure = sample as? HKCorrelation {
            guard let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
                  let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else { return "No readable data" }
            let systolic = pressure.objects(for: systolicType).compactMap { $0 as? HKQuantitySample }.first?.quantity.doubleValue(for: .millimeterOfMercury())
            let diastolic = pressure.objects(for: diastolicType).compactMap { $0 as? HKQuantitySample }.first?.quantity.doubleValue(for: .millimeterOfMercury())
            if let systolic, let diastolic { return String(format: "%.0f/%.0f mmHg · %@", systolic, diastolic, when) }
        }
        if let category = sample as? HKCategorySample {
            if metric.id == "mindful_minutes" { return "\(Int(category.endDate.timeIntervalSince(category.startDate) / 60)) min · \(when)" }
            if metric.id == "menstruation" { return "Recorded · \(when)" }
            if metric.id == "ovulation_test" {
                let result: String
                switch category.value {
                case HKCategoryValueOvulationTestResult.negative.rawValue: result = "Negative"
                case HKCategoryValueOvulationTestResult.positive.rawValue: result = "Positive"
                default: result = "Recorded"
                }
                return "\(result) · \(when)"
            }
            return "Recorded · \(when)"
        }
        if sample is HKElectrocardiogram { return "ECG recorded · \(when)" } // No waveform leaves the device.
        if sample is HKWorkout { return "Workout recorded · \(when)" }
        return "Recorded · \(when)"
    }
    private func stepsToday() async -> String {
        guard let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return "No readable data" }
        let start = Calendar.current.startOfDay(for: Date())
        let steps: Double? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepsType, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: .now), options: .cumulativeSum) { _, result, _ in
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count()))
            }
            health.execute(query)
        }
        return steps.map { String(format: "%.0f steps", $0) } ?? "No readable data"
    }
    private func sleepPastDay() async -> String {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return "No readable data" }
        let now = Date(), since = now.addingTimeInterval(-86400)
        let sleep = await safeSamples(sleepType, since: since, limit: HKObjectQueryNoLimit).compactMap { $0 as? HKCategorySample }.filter {
            [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains($0.value)
        }
        let intervals = sleep.map { (max($0.startDate, since), min($0.endDate, now)) }.sorted { $0.0 < $1.0 }
        var end = since, seconds = 0.0
        for (a, b) in intervals { seconds += max(0, b.timeIntervalSince(max(a, end))); end = max(end, b) }
        return sleep.isEmpty ? "No readable data" : "\(Int(seconds) / 3600) h \(Int(seconds) % 3600 / 60) min"
    }
    private func characteristic(_ id: String) -> String {
        switch id {
        case "blood_type":
            guard let value = try? health.bloodType().bloodType else { return "No readable data" }
            let names: [HKBloodType: String] = [.aPositive: "A+", .aNegative: "A−", .bPositive: "B+", .bNegative: "B−", .abPositive: "AB+", .abNegative: "AB−", .oPositive: "O+", .oNegative: "O−"]
            return names[value] ?? "No readable data"
        case "date_of_birth":
            guard let components = try? health.dateOfBirthComponents(), let year = components.year else { return "No readable data" }
            return [String(year), components.month.map { String(format: "%02d", $0) }, components.day.map { String(format: "%02d", $0) }].compactMap { $0 }.joined(separator: "-")
        case "skin_type":
            guard let value = try? health.fitzpatrickSkinType().skinType, value != .notSet else { return "No readable data" }
            return "Fitzpatrick type \(value.rawValue)"
        case "sex":
            guard let value = try? health.biologicalSex().biologicalSex else { return "No readable data" }
            switch value { case .female: return "Female"; case .male: return "Male"; case .other: return "Other"; default: return "No readable data" }
        case "wheelchair":
            guard let value = try? health.wheelchairUse().wheelchairUse else { return "No readable data" }
            switch value { case .yes: return "Yes"; case .no: return "No"; default: return "No readable data" }
        default: return "No readable data"
        }
    }
}

struct HealthView: View {
    @StateObject private var reader = HealthReader()
    var body: some View {
        Page(title: "Health", subtitle: "A little care for your day.") {
            GlassCard { VStack(alignment: .leading, spacing: 14) {
                Text("Choose which Health data Vesper may read. Rowan can request authorized summaries through the native Health tool in chat. Only requested summaries are sent to the Vesper chat service and become part of the conversation.").font(.subheadline)
                Button { Task { await reader.connect() } } label: { Text("Choose Health permissions").foregroundStyle(.white).padding(14).background(VesperTheme.ink, in: Capsule()) }.buttonStyle(.plain).disabled(reader.busy || !reader.available)
                Button("Read all Health categories on this iPhone") { Task { await reader.refresh(requestedIDs: ["all"]) } }.disabled(reader.busy || !reader.available)
                if !reader.available { Text("HealthKit is not available on this device.") }
                Text("No readable data can mean no recorded samples or no read permission. Vesper cannot tell which; change access in the Health app.").font(.caption).foregroundStyle(VesperTheme.muted)
                if reader.busy { ProgressView() }
                if !reader.error.isEmpty { Text(reader.error).font(.caption).foregroundStyle(.red) }
            } }
            ForEach(Array(reader.rows.enumerated()), id: \.offset) { _, row in GlassCard { VStack(alignment: .leading, spacing: 8) { Text(row.0).font(.caption).foregroundStyle(VesperTheme.muted); Text(row.1).font(.title3) }.frame(maxWidth: .infinity, alignment: .leading) } }
            if let updated = reader.updated { Text("Read at " + updated.formatted()).font(.caption); Button("Refresh") { Task { await reader.refresh(requestedIDs: reader.requestedIDs) } }.disabled(reader.busy) }
        }
    }
}
