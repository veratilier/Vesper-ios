import WidgetKit
import Foundation
import UIKit

@MainActor enum WidgetSync {
    static func desire(_ data: JSONValue) {
        var values: [String: Double] = [:]
        for (key, _) in DesireEmotion.fields {
            if case .number(let value) = data["values"][key] { values[key] = value }
        }
        WidgetSnapshot(updatedAt: AlbumPresentation.date(data["updatedAt"].string) ?? Date(), text: data["reason"].string.isEmpty ? "等待情绪评估" : data["reason"].string, values: values).save("desire")
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperDesireWidget")
    }
    static func usage(_ remaining: Int?) {
        guard let remaining else { return }
        WidgetSnapshot(updatedAt: Date(), text: "Weekly usage", values: ["remaining": Double(remaining)]).save("usage")
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperUsageWidget")
    }
    static func pictureChanged() {
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperPictureWidget")
    }
    static func clear() {
        for key in ["desire", "usage", "notes", LockWidgetSnapshot.key, CompanionCardSnapshot.key] { UserDefaults(suiteName: WidgetSnapshot.group)?.removeObject(forKey: key) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func profile(name: String, avatar: String, baseURL: String) async {
        var snapshot = LockWidgetSnapshot.read()
        let resolvedName = name.isEmpty ? "Ash" : name
        let avatarSource = baseURL + "\n" + avatar
        if snapshot.name != resolvedName || snapshot.avatarSource != avatarSource {
            snapshot.name = resolvedName
            if snapshot.avatarSource != avatarSource { snapshot.avatarSource = avatarSource; snapshot.avatarData = nil }
            snapshot.save()
            reloadLockWidgets()
        }
        guard !avatar.isEmpty else { return }
        let request = ChatAvatarSource(source: avatar, baseURL: baseURL)
        guard let image = await ChatAvatarImageCache.shared.image(for: request),
              !Task.isCancelled else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 72), format: format).image { _ in
            let scale = max(72 / image.size.width, 72 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (72 - size.width) / 2, y: (72 - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        guard let data = thumbnail.jpegData(compressionQuality: 0.7) else { return }
        snapshot = LockWidgetSnapshot.read()
        guard snapshot.avatarSource == avatarSource else { return }
        if snapshot.avatarData != data {
            snapshot.avatarData = data
            snapshot.save()
            reloadLockWidgets()
        }
    }

    static func message(_ messages: [JSONValue], busy: Bool) {
        guard !busy, let latest = messages.last(where: {
            ["agent", "assistant"].contains($0["role"].string.lowercased()) &&
            $0["metadata"]["phase"].string != "commentary" &&
            !$0["content"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return }
        let content = String(latest["content"].string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        let date = AlbumPresentation.date(latest["createdAt"].string) ?? Date()
        var snapshot = LockWidgetSnapshot.read()
        guard snapshot.messageDate == nil || date >= snapshot.messageDate! else { return }
        guard snapshot.message != content || snapshot.messageDate != date else { return }
        snapshot.message = content
        snapshot.messageDate = date
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperLockMessageWidget")
    }

    static func music(track: JSONValue, playing: Bool) {
        var snapshot = LockWidgetSnapshot.read()
        let song = track["title"].string
        let artist = track["artist"].string
        guard snapshot.song != song || snapshot.artist != artist || snapshot.isPlaying != playing else { return }
        snapshot.song = song
        snapshot.artist = artist
        snapshot.isPlaying = playing
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperLockMusicWidget")
    }

    private static func reloadLockWidgets() {
        for kind in ["VesperLockAshWidget", "VesperLockMessageWidget", "VesperCompanionCardWidget"] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
