import SwiftUI
import UIKit
import Speech
import AVFoundation
import CoreLocation
import UniformTypeIdentifiers

struct ChatFile: Identifiable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
    var transcript: String? = nil
    var duration: Double? = nil
}

@MainActor final class SpeechInput: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var installed = false
    private var generation = UUID()
    func start() async {
        stop(); text = ""; error = nil
        let id = UUID(); generation = id
        let granted = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        guard granted, generation == id else { if !granted { error = "Allow speech recognition in Settings." }; return }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic, generation == id else { if !mic { error = "Allow microphone access in Settings." }; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else { error = "Speech recognition is unavailable."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true; self.request = request
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw ServiceError(message: "No microphone is available.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; installed = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    if let transcript { self.text = transcript }
                    if finished || error != nil { self.stop(); if let error { self.error = error.localizedDescription } }
                }
            }
            engine.prepare(); try engine.start(); listening = true
        } catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        generation = UUID(); engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; listening = false
    }
}

@MainActor final class ChatLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var error: String?
    @Published var loading = false
    private let manager = CLLocationManager()
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func locateIfAuthorized() {
        guard !loading else { return }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse { locate() }
    }
    func locate() {
        loading = true; error = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: loading = false; error = "Allow location access in Settings."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if loading && manager.authorizationStatus != .notDetermined { locate() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { coordinate = locations.last?.coordinate; loading = false }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { self.error = error.localizedDescription; loading = false }
}

struct ChatCameraPicker: UIViewControllerRepresentable {
    let completion: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void
        init(_ completion: @escaping (Data?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.8)) }
    }
}

final class CallCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vesper.call.camera")
    private let lock = NSLock()
    private var frame: Data?
    private var configured = false
    private var lastFrame = Date.distantPast
    private let context = CIContext()
    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw ServiceError(message: "Allow camera access in Settings.") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured {
                        self.session.beginConfiguration(); defer { self.session.commitConfiguration() }
                        self.session.sessionPreset = .medium
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { throw ServiceError(message: "Camera unavailable.") }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else { throw ServiceError(message: "Camera unavailable.") }
                        self.session.addInput(input)
                        let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                        output.setSampleBufferDelegate(self, queue: self.queue)
                        guard self.session.canAddOutput(output) else { throw ServiceError(message: "Camera output unavailable.") }
                        self.session.addOutput(output)
                        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                        self.configured = true
                    }
                    self.session.startRunning(); c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }
    func stop() { queue.async { self.session.stopRunning(); self.lock.lock(); self.frame = nil; self.lock.unlock() } }
    func snapshot() -> Data? { lock.lock(); defer { lock.unlock() }; return frame }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastFrame) > 0.7, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date(); let image = CIImage(cvPixelBuffer: pixel)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.65)
        lock.lock(); frame = data; lock.unlock()
    }
}
struct CallCameraPreview: UIViewRepresentable {
    let camera: CallCamera
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); let layer = view.layer as! AVCaptureVideoPreviewLayer
        layer.session = camera.session; layer.videoGravity = .resizeAspectFill; return view
    }
    func updateUIView(_ view: Preview, context: Context) {}
}

@MainActor final class CallVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var speaking = false
    @Published var error: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var audio: AVAudioPlayer?
    private var generation = UUID()
    var finished: (() -> Void)?
    override init() { super.init(); synthesizer.delegate = self }
    func play(_ text: String, store: AppStore, connectionOverride: JSONValue? = nil) async {
        stop(); error = nil; let id = UUID(); generation = id; speaking = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            let connection = VoiceConfiguration.normalized(connectionOverride ?? VoiceConfiguration.connection(store))
            if !connection["apiKey"].string.isEmpty {
                var request = URLRequest(url: try APIClient.validatedURL(store.baseURL, path: "/api/tts"))
                request.httpMethod = "POST"; request.timeoutInterval = 30
                request.setValue(store.token, forHTTPHeaderField: "x-vesper-device-token")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(JSONValue.object(["text": .string(text), "connection": connection]))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard generation == id else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServiceError(message: VoiceConfiguration.failure(data, response: response, connection: connection)) }
                audio = try AVAudioPlayer(data: data); audio?.delegate = self
                guard audio?.play() == true else { throw ServiceError(message: "Voice playback failed.") }
            } else {
                let utterance = AVSpeechUtterance(string: text); utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN"); synthesizer.speak(utterance)
            }
        } catch { guard generation == id else { return }; self.error = error.localizedDescription; speaking = false }
    }
    func stop() { generation = UUID(); audio?.stop(); audio = nil; synthesizer.stopSpeaking(at: .immediate); speaking = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.speaking = false; self.finished?() } }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor in self.speaking = false; self.finished?() } }
}

struct NativeCallView: View {
    var initiator = "user"
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechInput()
    @StateObject private var voice = CallVoice()
    @StateObject private var camera = CallCamera()
    @Environment(\.scenePhase) private var phase
    @State private var startedAt: Date?
    @State private var callConversation = ""
    @State private var usedVideo = false
    @State private var transcript: [JSONValue] = []
    @State private var visible = true
    @State private var active = false
    @State private var muted = false
    @State private var video = false
    @State private var cameraBusy = false
    @State private var caption = ""
    @State private var waiting = false
    @State private var previousMessages = Set<String>()
    @State private var silence: Task<Void, Never>?
    @State private var sendingTask: Task<Void, Never>?
    @State private var notice: String?
    var body: some View {
        ZStack {
            Background()
            VStack(spacing: 16) {
                Text("Call").font(.headline)
                if video { CallCameraPreview(camera: camera).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 24)) }
                else { Image(systemName: "person.crop.circle").font(.system(size: 90)).foregroundStyle(VesperTheme.muted) }
                Text(voice.speaking ? "Speaking…" : waiting ? "Thinking…" : speech.listening ? "Listening…" : active ? "Paused" : "Rowan").font(VesperTheme.title(32))
                if let startedAt { Text(startedAt, style: .timer).monospacedDigit().font(.subheadline) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(transcript.enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry["speaker"].string).font(.caption).foregroundStyle(VesperTheme.muted)
                                    Text(entry["text"].string).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if speech.listening { Text("Vera · " + (speech.text.isEmpty ? "Listening…" : speech.text)).foregroundStyle(VesperTheme.muted) }
                            if waiting { Text("Rowan · " + liveAnswer).foregroundStyle(VesperTheme.muted) }
                            Color.clear.frame(height: 1).id("call-bottom")
                        }
                    }.frame(maxHeight: .infinity)
                    .onChange(of: speech.text) { _, _ in proxy.scrollTo("call-bottom", anchor: .bottom) }
                    .onChange(of: transcript.count) { _, _ in proxy.scrollTo("call-bottom", anchor: .bottom) }
                    .onChange(of: liveAnswer) { _, _ in proxy.scrollTo("call-bottom", anchor: .bottom) }
                }
                if video { Text("A camera frame is shared with each spoken message.").font(.caption).foregroundStyle(.secondary) }
                if VoiceConfiguration.connection(store)["apiKey"].string.isEmpty { Text("Using the iPhone voice. Configure Agent Voice for your custom voice.").font(.caption).foregroundStyle(.secondary) }
                if let error = notice ?? speech.error ?? voice.error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
                if !active { Button { player.pause(); active = true; chat.callActive = true; startedAt = Date(); callConversation = chat.conversationID; Task { await speech.start() } } label: { Text("Start call").foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 12).background(VesperTheme.ink, in: Capsule()) }.buttonStyle(.plain).disabled(chat.busy) }
                HStack(spacing: 30) {
                    Button { muted.toggle(); silence?.cancel(); if muted { speech.stop() } else if !waiting && !voice.speaking { Task { await speech.start() } } } label: { Label(muted ? "Unmute" : "Mute", systemImage: muted ? "mic.slash" : "mic") }.disabled(!active)
                    Button { toggleCamera() } label: { Label(video ? "Camera off" : "Camera", systemImage: video ? "video.slash" : "video") }.disabled(cameraBusy)
                    Button { end(); dismiss() } label: { Label("End", systemImage: "phone.down.fill") }.foregroundStyle(.red)
                }.labelStyle(.titleAndIcon).font(.subheadline).frame(minHeight: 50).padding(.bottom, 12)
                if active && !waiting && !voice.speaking && !muted {
                    Button(speech.listening ? "Send now" : "Resume listening") {
                        if speech.listening && !speech.text.isEmpty { submit() } else { Task { await speech.start() } }
                    }
                }
            }.padding(24)
        }.onAppear { chat.configure(store); voice.finished = { if active && !muted { Task { await speech.start() } } } }
        .onChange(of: speech.text) { _, text in
            silence?.cancel(); guard active, !muted, !waiting, !voice.speaking, !text.isEmpty else { return }
            silence = Task { try? await Task.sleep(for: .milliseconds(1400)); guard !Task.isCancelled else { return }; submit() }
        }
        .onChange(of: chat.busy) { old, new in
            guard old && !new && waiting && active else { return }
            waiting = false
            let replies = chat.messages.filter { !previousMessages.contains($0.id) && $0["role"].string != "user" && !ChatPresentation.isActivity($0) }
            let answer = replies.map { $0["content"].string }.joined(separator: "\n")
            guard !answer.isEmpty else { notice = chat.error ?? "No reply received. Resume when ready."; return }
            caption = answer; transcript.append(.object(["speaker": .string("Rowan"), "text": .string(answer), "at": .string(ISO8601DateFormatter().string(from: Date()))])); Task { await voice.play(answer, store: store) }
        }
        .onDisappear { visible = false; end() }
        .onChange(of: phase) { _, phase in if phase == .background { end() } }
    }
    private func submit() {
        let text = speech.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !waiting, !chat.busy, !text.isEmpty else { return }
        silence?.cancel(); speech.stop(); caption = text; waiting = true; notice = nil
        transcript.append(.object(["speaker": .string("Vera"), "text": .string(text), "at": .string(ISO8601DateFormatter().string(from: Date()))]))
        previousMessages = Set(chat.messages.map(\.id))
        let frame = video ? camera.snapshot() : nil
        sendingTask = Task { if !(await chat.send(text, images: frame.map { [$0] } ?? [])) { waiting = false; notice = chat.error ?? "Message was not sent." } }
    }
    private func toggleCamera() {
        if video { video = false; camera.stop(); return }
        cameraBusy = true
        Task { do { try await camera.start(); if visible && phase == .active { video = true; usedVideo = true } else { camera.stop() } } catch { notice = error.localizedDescription }; cameraBusy = false }
    }
    private var liveAnswer: String {
        let value = chat.messages.filter { !previousMessages.contains($0.id) && $0["role"].string == "agent" && !ChatPresentation.isActivity($0) }.map { $0["content"].string }.joined(separator: "\n")
        return value.isEmpty ? "Thinking…" : value
    }
    private func end() {
        if let start = startedAt {
            startedAt = nil
            let entries = transcript; let target = callConversation; let wasVideo = usedVideo
            let ended = Date()
            Task { await chat.saveCall(start: start, end: ended, video: wasVideo, transcript: entries, target: target, initiator: initiator) }
        }
        chat.callActive = false
        active = false; video = false; silence?.cancel(); sendingTask?.cancel(); sendingTask = nil; speech.stop(); voice.finished = nil; voice.stop(); camera.stop(); if waiting { Task { await chat.interrupt() } }; waiting = false }
}
