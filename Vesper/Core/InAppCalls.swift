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
        VesperCallControlBridge.handle = { [weak self] control in
            guard let self, self.id != nil else {
                throw NSError(domain: "Vesper.Call", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The call is no longer active."])
            }
            switch control {
            case "speaker":
                self.setSpeaker(!self.speakerEnabled)
                if let error = self.error {
                    throw NSError(domain: "Vesper.Call", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: error])
                }
            case "mute": self.mute(!self.muted)
            case "end": self.end()
            default: throw NSError(domain: "Vesper.Call", code: 2)
            }
        }
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
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            id = UUID(); muted = false; audioReady = true
            refreshOutput()
        } catch { self.error = error.localizedDescription; throw error }
    }
    func mute(_ value: Bool) { muted = value; syncActivityControls() }
    func setSpeaker(_ enabled: Bool) {
        guard audioReady else { return }
        error = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // Remove defaultToSpeaker so switching off can restore the receiver/headset.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch { self.error = "Could not change audio output: " + error.localizedDescription }
        refreshOutput()
        syncActivityControls()
    }
    private func refreshOutput() {
        guard id != nil else { speakerEnabled = false; outputName = ""; return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        speakerEnabled = outputs.contains { $0.portType == .builtInSpeaker }
        outputName = outputs.map { $0.portName }.joined(separator: ", ")
    }
    private func syncActivityControls() {
        CallLiveActivity.shared.updateControls(muted: muted, speakerEnabled: speakerEnabled)
    }
    func end() {
        guard id != nil else { return }
        id = nil; audioReady = false; muted = false
        speakerEnabled = false; outputName = ""
        CallLiveActivity.shared.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
