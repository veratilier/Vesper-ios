import SwiftUI
import AVFoundation
import Speech

@MainActor final class VoiceMessageRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recording = false
    @Published var processing = false
    @Published var file: ChatFile?
    @Published var error: String?
    @Published var startedAt: Date?
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var recognition: SFSpeechRecognitionTask?
    private var generation = UUID()
    func start() async {
        guard !recording, !processing, file == nil else { return }
        processing = true; error = nil
        let id = UUID(); generation = id
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard generation == id else { return }
        defer { processing = false }
        guard allowed else { error = "Allow microphone access in Settings."; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            url = target
            let recorder = try AVAudioRecorder(url: target, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            self.recorder = recorder; recorder.delegate = self
            guard recorder.record(forDuration: 120) else { throw ServiceError(message: "Recording could not start") }
            startedAt = Date(); recording = true
        } catch { self.error = error.localizedDescription }
    }
    func stop() async {
        guard recording, let recorder, let url else { return }
        recording = false; processing = true
        let duration = recorder.currentTime > 0 ? recorder.currentTime : Date().timeIntervalSince(startedAt ?? Date())
        recorder.stop(); self.recorder = nil
        let id = generation
        defer { if generation == id { processing = false }; try? FileManager.default.removeItem(at: url) }
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 0, duration >= 0.2 else { throw ServiceError(message: "The recording was too short. Try again.") }
            // Audio is retained even if speech permission or recognition is unavailable.
            let allowed = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
            guard generation == id else { return }
            var transcript = ""
            if allowed { transcript = await transcribe(url) }
            guard generation == id else { return }
            file = ChatFile(name: "Voice-" + UUID().uuidString + ".m4a", mime: "audio/mp4", data: data, transcript: transcript, duration: duration)
        } catch { self.error = error.localizedDescription }
    }
    func transcribeAttachment(_ attachment: JSONValue) async throws -> String {
        guard let source = URL(string: attachment["url"].string), source.scheme == "https" else { throw ServiceError(message: "这条语音没有可读取的音频。") }
        let allowed = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        guard allowed else { throw ServiceError(message: "请在 iOS 设置中允许语音识别后重试。") }
        let (data, response) = try await URLSession.shared.data(from: source)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        try Task.checkCancellation()
        let ext = (attachment["name"].string as NSString).pathExtension
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "m4a" : ext)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = await transcribe(file)
        try Task.checkCancellation()
        guard !text.isEmpty else { throw ServiceError(message: "暂时未能识别这条语音，可以再次长按转文字。") }
        return text
    }
    private func transcribe(_ url: URL) async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else { return "" }
        return await withCheckedContinuation { continuation in
            var finished = false
            var latest = ""
            let finish: (String) -> Void = { value in
                guard !finished else { return }; finished = true; continuation.resume(returning: value)
            }
            recognition = recognizer.recognitionTask(with: SFSpeechURLRecognitionRequest(url: url)) { result, error in
                let value = result?.bestTranscription.formattedString; let final = result?.isFinal == true
                Task { @MainActor in
                    if let value { latest = value }
                    if final || error != nil { finish(latest) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if !finished { self.recognition?.cancel(); finish(latest) }
            }
        }
    }
    func cancel() {
        generation = UUID(); recorder?.stop(); recorder = nil; recognition?.cancel(); recognition = nil
        recording = false; processing = false; file = nil; startedAt = nil
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if self.recording { await self.stop() } }
    }
}

@MainActor final class VoiceMessagePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var loading = false
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var generation = UUID()
    func toggle(url: URL) async {
        if playing || loading { stop(); return }
        let id = UUID(); generation = id; loading = true; error = nil
        defer { if generation == id { loading = false } }
        do {
            let data: Data
            if url.isFileURL { data = try Data(contentsOf: url) }
            else {
                let (body, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                data = body
            }
            guard generation == id else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data); player?.delegate = self
            playing = player?.play() == true
            if !playing { throw ServiceError(message: "Audio could not play") }
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
    func stop() { generation = UUID(); player?.stop(); player = nil; playing = false; loading = false }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor in self.playing = false } }
}

struct VoiceMessageBar: View {
    let attachment: JSONValue
    var messageID: String = "voice"
    var messageActions: () -> [ChatMessageAction] = { [] }
    var onTranscript: (String) -> Void = { _ in }
    @StateObject private var playback = VoiceMessagePlayback()
    @StateObject private var transcriber = VoiceMessageRecorder()
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var chat: ChatSession
    @State private var expanded = false
    @State private var transcript = ""
    @State private var transcribing = false
    @State private var transcriptionTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                HStack(spacing: 14) {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.system(size: 20))
                    HStack(spacing: 3) {
                        ForEach(0..<17) { index in
                            Capsule().fill(VesperTheme.accent.opacity(playback.playing ? 0.9 : 0.6))
                                .frame(width: 2.5, height: CGFloat(7 + (index * 7 % 19)))
                        }
                    }.accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Text(playback.loading ? "…" : "\(Int(max(0, attachment["duration"].number)))″").monospacedDigit()
                }.font(.system(size: 14)).frame(height: 32).padding(12)
                    .vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
                .modifier(ChatLongPress(id: messageID, actions: {
                    messageActions() + [ChatMessageAction(title: expanded ? "收起文字" : "转文字", icon: "text.bubble", run: toggleTranscript)]
                }, onTap: {
                    guard let url = URL(string: attachment["url"].string), url.scheme == "https" else { return }
                    music.pause(); Task { await playback.toggle(url: url) }
                }))
            if expanded {
                VoiceTranscriptPanel(text: transcript, loading: transcribing) { expanded = false }
            }
        }.frame(maxWidth: 250)
        .onChange(of: playback.error) { _, value in if let value { chat.error = value } }
        .onDisappear { playback.stop(); transcriptionTask?.cancel(); transcriptionTask = nil; transcriber.cancel(); transcribing = false }
    }
    private func toggleTranscript() {
        if expanded { expanded = false; return }
        transcript = transcript.isEmpty ? attachment["transcript"].string : transcript
        expanded = true
        guard transcript.isEmpty, !transcribing else { return }
        transcribing = true
        transcriptionTask = Task {
            defer { transcribing = false }
            do {
                let text = try await transcriber.transcribeAttachment(attachment)
                try Task.checkCancellation()
                transcript = text; onTranscript(text)
            } catch is CancellationError { }
            catch { expanded = false; chat.error = error.localizedDescription }
        }
    }
}

struct VoiceTranscriptPanel: View {
    let text: String
    var loading = false
    let onCollapse: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语音转写").font(.caption2).foregroundStyle(VesperTheme.muted)
            if loading { HStack { ProgressView(); Text("正在转文字…").font(.caption) } }
            else { Text(text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Button(action: onCollapse) { Label("收起", systemImage: "chevron.up").font(.caption).frame(maxWidth: .infinity, alignment: .trailing) }
                .buttonStyle(.plain).foregroundStyle(VesperTheme.muted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
