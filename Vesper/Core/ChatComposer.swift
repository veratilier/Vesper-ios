import Foundation
import Combine

// Text changes are observed only by the input controls, not the transcript.
final class ChatDraftText: ObservableObject {
    @Published var value = ""
}

final class ChatComposer: ObservableObject {
    let text = ChatDraftText()
    var draft: String {
        get { text.value }
        set { text.value = newValue }
    }
    @Published var images: [Data] = []
    @Published var files: [ChatFile] = []
    @Published var pendingMusic: JSONValue?
    @Published var pendingSticker: JSONValue?

    private struct Draft {
        var text = ""
        var images: [Data] = []
        var files: [ChatFile] = []
        var music: JSONValue?
        var sticker: JSONValue?
    }
    private var saved: [String: Draft] = [:]

    func switchConversation(from: String, to: String) {
        guard from != to else { return }
        saved[from] = Draft(text: draft, images: images, files: files, music: pendingMusic, sticker: pendingSticker)
        let next = saved[to] ?? Draft()
        draft = next.text
        images = next.images
        files = next.files
        pendingMusic = next.music
        pendingSticker = next.sticker
    }
}


enum ChatStickerInput {
    static func context(text: String, sticker: JSONValue) -> String {
        let description = "Shared sticker: " + sticker["name"].string + " " + sticker["description"].string + " (assetId: " + sticker["assetId"].string + ")"
        return (text.isEmpty ? "" : text + "\n") + description
    }
}
