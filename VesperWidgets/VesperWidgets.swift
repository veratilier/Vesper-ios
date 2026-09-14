import WidgetKit
import SwiftUI
import AppIntents

struct DateWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vesper day"
    static var description = IntentDescription("Choose a date to keep close. This date is configured separately from the app.")
    @Parameter(title: "Title", default: "A day to remember") var eventTitle: String
    @Parameter(title: "Date") var targetDate: Date?
}
struct DayEntry: TimelineEntry { let date: Date; let configuration: DateWidgetConfiguration }
struct DayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DayEntry { DayEntry(date: .now, configuration: DateWidgetConfiguration()) }
    func snapshot(for configuration: DateWidgetConfiguration, in context: Context) async -> DayEntry { DayEntry(date: .now, configuration: configuration) }
    func timeline(for configuration: DateWidgetConfiguration, in context: Context) async -> Timeline<DayEntry> {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        return Timeline(entries: [DayEntry(date: now, configuration: configuration)], policy: .after(tomorrow))
    }
}
struct DayWidgetView: View {
    let entry: DayEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vesper").font(.system(.caption, design: .serif).italic())
            Spacer(minLength: 0)
            if let target = entry.configuration.targetDate {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date), to: Calendar.current.startOfDay(for: target)).day ?? 0
                Text(entry.configuration.eventTitle).font(.headline).lineLimit(2)
                HStack(alignment: .firstTextBaseline) { Text("\(abs(days))").font(.system(size: 44, weight: .light, design: .rounded)).minimumScaleFactor(0.5); Text(days >= 0 ? "days to go" : "days since").font(.caption) }
            } else { Text("Keep a day close.").font(.headline); Text("Touch and hold → Edit Widget to choose a date.").font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color(red: 0.13, green: 0.22, blue: 0.27))
        .containerBackground(for: .widget) {
            ZStack { Image("WidgetCoast").resizable().scaledToFill(); Color.white.opacity(0.58) }
        }
    }
}
struct VesperDayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VesperDayWidget", intent: DateWidgetConfiguration.self, provider: DayProvider()) { DayWidgetView(entry: $0) }
            .configurationDisplayName("Vesper · Days")
            .description("An ocean view and a day worth remembering.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StatusEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot? }
struct StatusProvider: TimelineProvider {
    let key: String
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: WidgetSnapshot.read(key)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        completion(Timeline(entries: [StatusEntry(date: .now, snapshot: WidgetSnapshot.read(key))], policy: .after(Date().addingTimeInterval(900))))
    }
}
struct StatusWidgetView: View {
    let entry: StatusEntry
    let key: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(key == "desire" ? "Desire · 此刻" : key == "usage" ? "Weekly Usage" : "Notes").font(.headline)
            if let snapshot = entry.snapshot {
                if key == "usage", let remaining = snapshot.values["remaining"] {
                    Text("\(Int(remaining))%").font(.system(size: 38, weight: .light, design: .rounded))
                    Text("remaining").font(.caption)
                    ProgressView(value: remaining, total: 100)
                } else if key == "desire" {
                    ForEach(["longing", "tenderness", "playfulness", "intensity", "attachment", "possessiveness"], id: \.self) { field in
                        if let value = snapshot.values[field] {
                            HStack { Text(field.capitalized); Spacer(); Text(value.formatted(.number.precision(.fractionLength(0...1)))).monospacedDigit() }.font(.system(size: 10))
                        }
                    }
                } else { Text(snapshot.text).font(.system(size: 15, design: .serif)).lineLimit(5) }
                Spacer(minLength: 0)
                Text("Synced \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundStyle(.secondary)
            } else { Spacer(); Text("Open Vesper to sync.").font(.caption); Spacer() }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color(red: 0.13, green: 0.22, blue: 0.27))
        .containerBackground(for: .widget) { ZStack { Image("WidgetCoast").resizable().scaledToFill(); Color.white.opacity(0.8) } }
        .widgetURL(URL(string: "vesper://" + key))
    }
}
struct VesperDesireWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VesperDesireWidget", provider: StatusProvider(key: "desire")) { StatusWidgetView(entry: $0, key: "desire") }
            .configurationDisplayName("Vesper · Desire").description("Latest synced Desire, with its update time.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct VesperUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VesperUsageWidget", provider: StatusProvider(key: "usage")) { StatusWidgetView(entry: $0, key: "usage") }
            .configurationDisplayName("Vesper · Weekly Usage").description("Your latest synced weekly allowance.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct VesperNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VesperNotesWidget", provider: StatusProvider(key: "notes")) { StatusWidgetView(entry: $0, key: "notes") }
            .configurationDisplayName("Vesper · Notes").description("Keep your latest note close.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main struct VesperWidgetBundle: WidgetBundle {
    var body: some Widget { VesperDayWidget(); VesperDesireWidget(); VesperUsageWidget(); VesperNotesWidget() }
}
