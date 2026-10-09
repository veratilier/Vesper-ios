import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit
import UIKit

private struct CallIslandAvatar: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.28, green: 0.27, blue: 0.37))
            Text("R").font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let data = UserDefaults(suiteName: "group.com.vera.vesper.native")?.data(forKey: "activeCallAvatar"),
               let avatar = UIImage(data: data) {
                Image(uiImage: avatar).resizable().scaledToFill()
            }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

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

// These pictures are bundled with the widget extension. Selecting one needs
// neither a connection to Vesper nor access to its shared App Group.
enum VesperPicture: String, AppEnum {
    case coast, marble, veil

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Vesper picture"
    static var caseDisplayRepresentations: [VesperPicture: DisplayRepresentation] = [
        .coast: "Coast", .marble: "Blue marble", .veil: "Soft light"
    ]

    var assetName: String {
        switch self {
        case .coast: "WidgetCoast"
        case .marble: "WidgetMarble"
        case .veil: "WidgetVeil"
        }
    }
}

struct PictureWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vesper picture"
    static var description = IntentDescription("Choose a picture and a short line for your Home Screen.")

    @Parameter(title: "Picture", default: .coast) var picture: VesperPicture
    @Parameter(title: "Caption", default: "Somewhere we belong.") var caption: String
}

struct PictureEntry: TimelineEntry {
    let date: Date
    let configuration: PictureWidgetConfiguration
}

struct PictureProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PictureEntry {
        PictureEntry(date: .now, configuration: PictureWidgetConfiguration())
    }
    func snapshot(for configuration: PictureWidgetConfiguration, in context: Context) async -> PictureEntry {
        PictureEntry(date: .now, configuration: configuration)
    }
    func timeline(for configuration: PictureWidgetConfiguration, in context: Context) async -> Timeline<PictureEntry> {
        Timeline(entries: [PictureEntry(date: .now, configuration: configuration)], policy: .never)
    }
}

struct PictureWidgetView: View {
    let entry: PictureEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            if !entry.configuration.caption.isEmpty {
                Text(entry.configuration.caption)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .lineLimit(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            GeometryReader { geometry in
                Image(entry.configuration.picture.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
    }
}

struct VesperPictureWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VesperPictureWidget", intent: PictureWidgetConfiguration.self, provider: PictureProvider()) {
            PictureWidgetView(entry: $0)
        }
        .configurationDisplayName("Vesper · Picture")
        .description("A picture and a line to keep on your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
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
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach([("joy", "愉悦"), ("calm", "平静"), ("sadness", "低落"), ("anxiety", "焦虑"), ("anger", "生气"), ("closeness", "亲近"), ("curiosity", "好奇"), ("hurt", "委屈")], id: \.0) { field, label in
                            if let value = snapshot.values[field] {
                                HStack { Text(label); Spacer(minLength: 2); Text(value.formatted(.number.precision(.fractionLength(0)))).monospacedDigit() }.font(.system(size: 11))
                            }
                        }
                    }
                    if snapshot.values.isEmpty { Text("等待情绪评估").font(.caption) }
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

struct VesperCallWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VesperCallAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.isVideo ? "video.fill" : "phone.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rowan · Vesper").font(.headline)
                    Text(context.attributes.startedAt, style: .timer).monospacedDigit()
                }
                Spacer()
                Text("Return to call").font(.caption)
            }
            .foregroundStyle(.white).padding()
            .activityBackgroundTint(Color(red: 0.08, green: 0.12, blue: 0.16))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "vesper://call"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    HStack(spacing: 10) {
                        CallIslandAvatar(size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rowan").font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            Text(context.attributes.startedAt, style: .timer)
                                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isVideo ? "video.fill" : "waveform")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 16) {
                        Button(intent: VesperCallControlIntent("speaker")) {
                            Image(systemName: context.state.speakerEnabled ? "speaker.wave.2.fill" : "speaker.fill")
                                .frame(width: 42, height: 42)
                                .background(.white.opacity(context.state.speakerEnabled ? 0.26 : 0.12), in: Circle())
                        }.accessibilityLabel(context.state.speakerEnabled ? "Turn speaker off" : "Turn speaker on")
                        Button(intent: VesperCallControlIntent("mute")) {
                            Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                                .frame(width: 42, height: 42)
                                .background(.white.opacity(context.state.muted ? 0.26 : 0.12), in: Circle())
                        }.accessibilityLabel(context.state.muted ? "Unmute" : "Mute")
                        Spacer(minLength: 0)
                        Link(destination: URL(string: "vesper://call")!) {
                            Image(systemName: "arrow.up.right").frame(width: 42, height: 42)
                                .background(.white.opacity(0.12), in: Circle())
                        }.accessibilityLabel("Return to call")
                        Button(intent: VesperCallControlIntent("end")) {
                            Image(systemName: "phone.down.fill").frame(width: 46, height: 46)
                                .background(.red, in: Circle())
                        }.accessibilityLabel("End call")
                    }
                    .buttonStyle(.plain).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                }
            } compactLeading: {
                CallIslandAvatar(size: 22)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.green)
            }
            .widgetURL(URL(string: "vesper://call"))
        }
    }
}
@main struct VesperWidgetBundle: WidgetBundle {
    var body: some Widget { VesperDayWidget(); VesperPictureWidget(); VesperDesireWidget(); VesperUsageWidget(); VesperNotesWidget(); VesperCallWidget() }
}
