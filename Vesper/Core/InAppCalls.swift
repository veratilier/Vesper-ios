import AVFoundation
import Combine

@MainActor final class InAppCalls: ObservableObject {
    static let shared = InAppCalls()
    @Published private(set) var id: UUID?
    @Published private(set) var audioReady = false
    @Published private(set) var muted = false
    @Published var error: String?
    private var interruption: AnyCancellable?
    init() {
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.end() }
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
        } catch { self.error = error.localizedDescription; throw error }
    }
    func mute(_ value: Bool) { muted = value }
    func end() {
        guard id != nil else { return }
        id = nil; audioReady = false; muted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
