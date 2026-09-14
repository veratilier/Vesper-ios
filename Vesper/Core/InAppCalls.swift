import AVFoundation
import Combine

@MainActor final class InAppCalls: ObservableObject {
    static let shared = InAppCalls()
    @Published private(set) var id: UUID?
    @Published private(set) var audioReady = false
    @Published private(set) var muted = false
    @Published private(set) var speakerEnabled = false
    @Published private(set) var outputName = ""
    @Published var error: String?
    private var interruption: AnyCancellable?
    private var routeChange: AnyCancellable?
    init() {
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.end() }
            }
        routeChange = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshOutput() }
            }
    }
    func start() async throws {
        guard id == nil else { return }
        error = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
            id = UUID(); muted = false; audioReady = true
            refreshOutput()
        } catch { self.error = error.localizedDescription; throw error }
    }
    func mute(_ value: Bool) { muted = value }
    func setSpeaker(_ enabled: Bool) {
        guard audioReady else { return }
        error = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // Remove defaultToSpeaker so switching off can restore the receiver/headset.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch { self.error = "Could not change audio output: " + error.localizedDescription }
        refreshOutput()
    }
    private func refreshOutput() {
        guard id != nil else { speakerEnabled = false; outputName = ""; return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        speakerEnabled = outputs.contains { $0.portType == .builtInSpeaker }
        outputName = outputs.map { $0.portName }.joined(separator: ", ")
    }
    func end() {
        guard id != nil else { return }
        id = nil; audioReady = false; muted = false
        speakerEnabled = false; outputName = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
