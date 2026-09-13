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
@main struct VesperDayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VesperDayWidget", intent: DateWidgetConfiguration.self, provider: DayProvider()) { DayWidgetView(entry: $0) }
            .configurationDisplayName("Vesper · Days")
            .description("An ocean view and a day worth remembering.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
