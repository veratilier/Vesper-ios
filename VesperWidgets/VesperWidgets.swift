import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit
import UIKit

private struct CallIslandAvatar: View {
    let size: CGFloat
    let name: String
    var avatarKey = "activeCallAvatar"
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.28, green: 0.27, blue: 0.37))
            Text(String(name.prefix(1))).font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let data = UserDefaults(suiteName: "group.com.vera.vesper.native")?.data(forKey: avatarKey),
               let avatar = UIImage(data: data) {
                Image(uiImage: avatar).resizable().scaledToFill()
            }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

private struct CompanionLeadingIcon: View {
    let size: CGFloat
    let state: VesperCompanionAttributes.ContentState
    let avatarKey: String
    private var snakePose: Int {
        state.pokeStatus == nil ? 0 : state.pokeStatus?.contains("正在") == true ? 1 : 2
    }

    var body: some View {
        Group {
            if CompanionLeadingStyle.current == .pixelSnake {
                CompanionPixelSnake(size: size, pose: snakePose)
                    .id("snake-\(snakePose)-\(state.avatarRevision)")
                    .transition(.opacity)
            } else {
                CallIslandAvatar(size: size, name: state.displayName, avatarKey: avatarKey)
                    .id("avatar-\(state.avatarRevision)")
            }
        }
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

struct LockEntry: TimelineEntry {
    let date: Date
    let snapshot: LockWidgetSnapshot
}

struct LockProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockEntry { LockEntry(date: .now, snapshot: LockWidgetSnapshot()) }
    func getSnapshot(in context: Context, completion: @escaping (LockEntry) -> Void) {
        completion(LockEntry(date: .now, snapshot: LockWidgetSnapshot.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LockEntry>) -> Void) {
        completion(Timeline(entries: [LockEntry(date: .now, snapshot: LockWidgetSnapshot.read())],
                            policy: .after(Date().addingTimeInterval(900))))
    }
}

private struct LockAshAvatar: View {
    let snapshot: LockWidgetSnapshot
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.13))
            Text(String(snapshot.name.prefix(1))).font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            if let data = snapshot.avatarData, let picture = UIImage(data: data) {
                Image(uiImage: picture).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct LockAshView: View {
    let entry: LockEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular {
                LockAshAvatar(snapshot: entry.snapshot, size: 54)
            } else {
                HStack(spacing: 8) {
                    LockAshAvatar(snapshot: entry.snapshot, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.snapshot.name).font(.headline).lineLimit(1)
                        Text("Open Chat").font(.caption).lineLimit(1)
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "vesper://chat?backend=vps"))
    }
}

struct VesperLockAshWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VesperLockAshWidget", provider: LockProvider()) { LockAshView(entry: $0) }
            .configurationDisplayName("Vesper · Ash")
            .description("Ash's portrait and a shortcut to Chat.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct LockMessageView: View {
    let entry: LockEntry
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bubble.left.fill").font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.snapshot.name).font(.system(.caption, weight: .semibold)).lineLimit(1)
                Text(entry.snapshot.message.isEmpty ? "Open Chat to see the latest message" : entry.snapshot.message)
                    .font(.caption).lineLimit(2).privacySensitive()
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "vesper://chat?backend=vps"))
    }
}

struct VesperLockMessageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VesperLockMessageWidget", provider: LockProvider()) { LockMessageView(entry: $0) }
            .configurationDisplayName("Vesper · Latest Message")
            .description("The latest Ash message on this iPhone.")
            .supportedFamilies([.accessoryRectangular])
    }
}

struct LockMusicView: View {
    let entry: LockEntry
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: entry.snapshot.isPlaying ? "music.note" : "pause.fill").font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.snapshot.isPlaying ? "Playing" : "Music").font(.system(.caption, weight: .semibold))
                Text(entry.snapshot.song.isEmpty ? "Open Vesper Music" : entry.snapshot.song)
                    .font(.caption).lineLimit(1)
                if !entry.snapshot.artist.isEmpty { Text(entry.snapshot.artist).font(.caption2).lineLimit(1) }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "vesper://music"))
    }
}

struct VesperLockMusicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VesperLockMusicWidget", provider: LockProvider()) { LockMusicView(entry: $0) }
            .configurationDisplayName("Vesper · Music")
            .description("The current song and a shortcut to Music.")
            .supportedFamilies([.accessoryRectangular])
    }
}

enum CompanionCardCharacter: String, AppEnum {
    case snake, avatar

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Companion character"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .snake: "Pixel snake", .avatar: "Ash avatar"
    ]
}

struct CompanionCardConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vesper companion"
    static var description = IntentDescription("A little hello from Ash on your Home Screen.")
    @Parameter(title: "Character", default: .snake) var character: CompanionCardCharacter
}

struct RefreshCompanionCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Another hello"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        CompanionCardSnapshot.advance()
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperCompanionCardWidget")
        return .result()
    }
}

struct CompanionCardEntry: TimelineEntry {
    let date: Date
    let configuration: CompanionCardConfiguration
    let card: CompanionCardSnapshot
    let profile: LockWidgetSnapshot
}

struct CompanionCardProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CompanionCardEntry {
        CompanionCardEntry(date: .now, configuration: CompanionCardConfiguration(),
                           card: .init(greeting: "Here, with you.", pose: 0, updatedAt: .now),
                           profile: LockWidgetSnapshot())
    }

    func snapshot(for configuration: CompanionCardConfiguration, in context: Context) async -> CompanionCardEntry {
        CompanionCardEntry(date: .now, configuration: configuration,
                           card: CompanionCardSnapshot.current(), profile: LockWidgetSnapshot.read())
    }

    func timeline(for configuration: CompanionCardConfiguration, in context: Context) async -> Timeline<CompanionCardEntry> {
        let now = Date()
        let entry = CompanionCardEntry(date: now, configuration: configuration,
                                       card: CompanionCardSnapshot.current(at: now), profile: LockWidgetSnapshot.read())
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(CompanionCardSnapshot.refreshInterval)))
    }
}

struct CompanionCardView: View {
    let entry: CompanionCardEntry

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 5)
            Button(intent: RefreshCompanionCardIntent()) {
                Group {
                    if entry.configuration.character == .snake {
                        CompanionPixelSnake(size: 78, pose: entry.card.pose)
                            .rotationEffect(.degrees(entry.card.pose == 1 ? -7 : entry.card.pose == 2 ? 7 : 0))
                    } else {
                        LockAshAvatar(snapshot: entry.profile, size: 78)
                    }
                }
                .frame(width: 88, height: 88)
                .id(entry.card.pose)
                .transition(.opacity.combined(with: .scale(scale: 0.93)))
                .animation(.spring(duration: 0.55, bounce: 0.38), value: entry.card.pose)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change greeting")
            Spacer(minLength: 5)
            Text(entry.card.greeting)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 9)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.17, green: 0.17, blue: 0.18),
                                    Color(red: 0.08, green: 0.08, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
        }
        .widgetURL(URL(string: "vesper://chat?backend=vps"))
        .accessibilityElement(children: .contain)
    }
}

struct VesperCompanionCardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VesperCompanionCardWidget", intent: CompanionCardConfiguration.self,
                               provider: CompanionCardProvider()) { CompanionCardView(entry: $0) }
            .configurationDisplayName("Vesper · Companion")
            .description("Choose the pixel snake or Ash's avatar. Tap to see another greeting.")
            .supportedFamilies([.systemSmall])
            .contentMarginsDisabled()
    }
}

// These pictures are bundled with the widget extension. Selecting one needs
// neither a connection to Vesper nor access to its shared App Group.
enum VesperPicture: String, AppEnum {
    case custom, coast, marble, veil

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Vesper picture"
    static var caseDisplayRepresentations: [VesperPicture: DisplayRepresentation] = [
        .custom: "Saved photo", .coast: "Coast", .marble: "Blue marble", .veil: "Soft light"
    ]

    var assetName: String {
        switch self {
        case .custom: "WidgetCoast"
        case .coast: "WidgetCoast"
        case .marble: "WidgetMarble"
        case .veil: "WidgetVeil"
        }
    }
}

enum VesperPictureStyle: String, AppEnum {
    case dark, photo

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Vesper picture style"
    static var caseDisplayRepresentations: [VesperPictureStyle: DisplayRepresentation] = [
        .dark: "Dark", .photo: "Photo"
    ]
}

struct SavedWidgetPhotoOptions: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        let items = WidgetPictureStore.items().map { item in
            IntentItem(item.id, title: LocalizedStringResource(stringLiteral: item.name))
        }
        return IntentItemCollection(sections: [IntentItemSection(items: items)])
    }
}

struct PictureWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vesper picture"
    static var description = IntentDescription("Choose a saved photo and a short line for your Home Screen.")

    @Parameter(title: "Picture", default: .custom) var picture: VesperPicture
    @Parameter(title: "Saved Photo", optionsProvider: SavedWidgetPhotoOptions()) var savedPhotoID: String?
    @Parameter(title: "Style", default: .dark) var style: VesperPictureStyle
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

    private var picture: Image? {
        if entry.configuration.picture != .custom {
            return Image(entry.configuration.picture.assetName)
        }
        let selectedID = entry.configuration.savedPhotoID ?? WidgetPictureStore.items().first?.id
        guard let selectedID, let data = WidgetPictureStore.image(for: selectedID),
              let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            if entry.configuration.style == .dark {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 11, weight: .medium))
                        Text("VESPER")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(2)
                        Spacer()
                    }
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(18)
            }
            if !entry.configuration.caption.isEmpty {
                Text(entry.configuration.caption)
                    .font(.system(size: entry.configuration.style == .dark ? 18 : 15,
                                  weight: .medium, design: .serif))
                    .lineLimit(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(entry.configuration.style == .dark ? 0 : 0.7), radius: 8)
                    .padding(entry.configuration.style == .dark ? 18 : 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            GeometryReader { geometry in
                ZStack {
                    Color(red: 0.065, green: 0.07, blue: 0.08)
                    if let picture {
                        picture
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .saturation(entry.configuration.style == .dark ? 0.1 : 1)
                            .opacity(entry.configuration.style == .dark ? 0.23 : 1)
                    }
                    if entry.configuration.style == .dark {
                        LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.82)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
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
        .description("Choose one of your saved photos and a line for your Home Screen.")
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
            Text(key == "desire" ? "Desire · 此刻" : "Weekly Usage").font(.headline)
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
                    if snapshot.values["joy"] == nil { Text("等待情绪评估").font(.caption) }
                }
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
struct VesperCallWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VesperCallAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.isVideo ? "video.fill" : "phone.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.displayName + " · Vesper").font(.headline)
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
                        CallIslandAvatar(size: 46, name: context.state.displayName)
                            .id(context.state.avatarRevision)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.displayName).font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
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
                CallIslandAvatar(size: 22, name: context.state.displayName)
                    .id(context.state.avatarRevision)
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

private struct CompanionBanner: View {
    let attributes: VesperCompanionAttributes
    let state: VesperCompanionAttributes.ContentState
    private var contents: some View {
        HStack(spacing: 12) {
            CompanionLeadingIcon(size: 42, state: state, avatarKey: attributes.avatarKey)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(state.pokeStatus ?? state.greeting ?? "")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Link(destination: URL(string: "vesper://companion?backend=" + (attributes.backend ?? "vps"))!) {
                Image(systemName: "bubble.left").frame(width: 38, height: 42)
            }.accessibilityLabel("聊天")
            Button(intent: PokeVesperCompanionIntent(attributes.avatarKey)) {
                Image(systemName: "hand.tap").frame(width: 38, height: 42)
            }.accessibilityLabel("敲一下")
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }
    var body: some View {
        // Keep labels and controls out of the glass effect's captured content.
        // The Lock Screen's remote renderer can display the glass but omit that
        // captured content. Only the decorative background needs the effect.
        contents.background {
            if #available(iOS 26.0, *) {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
            } else {
                RoundedRectangle(cornerRadius: 24).fill(.regularMaterial)
            }
        }
    }
}

struct VesperCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VesperCompanionAttributes.self) { context in
            CompanionBanner(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string: "vesper://companion"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CompanionLeadingIcon(size: 46, state: context.state, avatarKey: context.attributes.avatarKey).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.displayName).font(.headline)
                        Text(context.state.pokeStatus ?? context.state.greeting ?? "")
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: PokeVesperCompanionIntent(context.attributes.avatarKey)) {
                        Image(systemName: "hand.tap").font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 44).background(.white.opacity(0.12), in: Circle())
                    }.buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("敲一下")
                }
            } compactLeading: {
                CompanionLeadingIcon(size: 24, state: context.state, avatarKey: context.attributes.avatarKey)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                CompanionLeadingIcon(size: 22, state: context.state, avatarKey: context.attributes.avatarKey)
            }
            .widgetURL(URL(string: "vesper://companion"))
            .keylineTint(.white.opacity(0.4))
        }
    }
}

@main struct VesperWidgetBundle: WidgetBundle {
    var body: some Widget {
        VesperDayWidget(); VesperPictureWidget(); VesperCompanionCardWidget(); VesperDesireWidget(); VesperUsageWidget()
        VesperLockAshWidget(); VesperLockMessageWidget(); VesperLockMusicWidget()
        VesperCallWidget(); VesperCompanionWidget()
    }
}
