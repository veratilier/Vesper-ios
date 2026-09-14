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
    @StateObject private var playback = VoiceMessagePlayback()
    @EnvironmentObject private var music: MusicPlayer
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let url = URL(string: attachment["url"].string), url.scheme == "https" else { return }
                music.pause(); Task { await playback.toggle(url: url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    Image(systemName: "waveform").font(.system(size: 16))
                    let seconds = Int(max(0, attachment["duration"].number))
                    Text(playback.loading ? "Loading…" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit()
                }.font(.system(size: 14)).frame(minWidth: 100, minHeight: 32).padding(.horizontal, 10).padding(.vertical, 4).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            Button(expanded ? "Hide transcript" : "View transcript") { expanded.toggle() }.font(.caption)
            if expanded { Text(attachment["transcript"].string.isEmpty ? "Transcription unavailable." : attachment["transcript"].string).font(.subheadline).textSelection(.enabled).frame(maxWidth: 270, alignment: .leading) }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onDisappear { playback.stop() }
    }
}
