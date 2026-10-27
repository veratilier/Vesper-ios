import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

private struct VesperEntry: TimelineEntry {
    let date: Date
    let agentName: String
    let canPoke: Bool
    let greeting: String
    let avatarData: Data?
}

private struct VesperProvider: TimelineProvider {
    func placeholder(in context: Context) -> VesperEntry {
        VesperEntry(date: .now, agentName: "Vesper", canPoke: true,
                    greeting: "Come as you are.", avatarData: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (VesperEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VesperEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> VesperEntry {
        VesperEntry(date: .now, agentName: WatchWidgetSettings.agentName,
                    canPoke: WatchWidgetSettings.canPoke,
                    greeting: WatchWidgetSettings.greeting,
                    avatarData: WatchWidgetSettings.avatarData)
    }
}

struct VesperPokeIntent: AppIntent {
    static var title: LocalizedStringResource = "拍一拍"
    static var description = IntentDescription("从表盘轻轻拍一拍")

    func perform() async throws -> some IntentResult {
        try await WatchWidgetSettings.poke()
        return .result()
    }
}

private struct OpenVesperWidget: Widget {
    let kind = "com.vera.vesper.watch.open"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VesperProvider()) { entry in
            WatchWidgetFace(symbol: "bubble.left.and.bubble.right.fill",
                            title: entry.agentName, detail: "打开聊天")
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("打开 Vesper")
        .description("点一下进入手表上的聊天")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

private struct PokeVesperWidget: Widget {
    let kind = "com.vera.vesper.watch.poke"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VesperProvider()) { entry in
            Button(intent: VesperPokeIntent()) {
                WatchWidgetFace(symbol: "hand.tap.fill", title: "拍一拍",
                                detail: entry.canPoke ? entry.agentName : "先打开 Vesper")
            }
            .buttonStyle(.plain)
            .disabled(!entry.canPoke)
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("拍一拍")
        .description("点一下直接拍一拍，不必打开 Vesper")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

/// A portrait complication for a circular slot on the watch face.
private struct AvatarVesperWidget: Widget {
    let kind = "com.vera.vesper.watch.avatar"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VesperProvider()) { entry in
            CompanionAvatar(data: entry.avatarData, name: entry.agentName, size: 48)
                .widgetAccentable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(.clear, for: .widget)
                .accessibilityLabel("\(entry.agentName)，打开 Vesper")
        }
        .configurationDisplayName("Vesper 头像")
        .description("在表盘放上头像，点一下打开 Vesper")
        .supportedFamilies([.accessoryCircular])
    }
}

/// The wide Smart Stack card mirrors the iPhone Lock Screen companion banner.
private struct CompanionVesperWidget: Widget {
    let kind = "com.vera.vesper.watch.companion"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VesperProvider()) { entry in
            HStack(spacing: 8) {
                CompanionAvatar(data: entry.avatarData, name: entry.agentName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.agentName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.greeting)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(intent: VesperPokeIntent()) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 32, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.canPoke)
                .accessibilityLabel("拍一拍 \(entry.agentName)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color(red: 0.24, green: 0.39, blue: 0.54),
                                        Color(red: 0.12, green: 0.19, blue: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .configurationDisplayName("Vesper 横幅")
        .description("在智能叠放里看见陪伴横幅；点卡片聊天，点手势拍一拍")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct CompanionAvatar: View {
    let data: Data?
    let name: String
    var size: CGFloat = 38

    private var cgImage: CGImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var body: some View {
        Group {
            if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(name.prefix(1)))
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.7))
        .accessibilityHidden(true)
    }
}

private struct WatchWidgetFace: View {
    @Environment(\.widgetFamily) private var family

    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        if family == .accessoryRectangular {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(detail).font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .widgetAccentable()
                .accessibilityLabel(title)
        }
    }
}

@main struct VesperWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenVesperWidget()
        PokeVesperWidget()
        AvatarVesperWidget()
        CompanionVesperWidget()
    }
}
