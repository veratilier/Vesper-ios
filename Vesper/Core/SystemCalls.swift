import CallKit
import AVFoundation
import Combine

@MainActor final class SystemCalls: NSObject, ObservableObject, CXProviderDelegate {
    static let shared = SystemCalls()
    @Published private(set) var id: UUID?
    @Published private(set) var audioReady = false
    @Published private(set) var muted = false
    @Published var error: String?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var outgoing = false
    override init() {
        let config = CXProviderConfiguration(localizedName: "Vesper")
        config.maximumCallGroups = 1; config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]; config.supportsVideo = false
        provider = CXProvider(configuration: config)
        super.init(); provider.setDelegate(self, queue: .main)
    }
    func incoming() async throws {
        guard id == nil else { throw ServiceError(message: "A call is already in progress.") }
        let callID = UUID(); id = callID; error = nil; outgoing = false
        let update = CXCallUpdate(); update.remoteHandle = CXHandle(type: .generic, value: "Rowan")
        update.localizedCallerName = "Rowan"; update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false
        do { try await provider.reportNewIncomingCall(with: callID, update: update) }
        catch { id = nil; throw error }
    }
    func start() async throws {
        guard id == nil else { throw ServiceError(message: "A call is already in progress.") }
        let callID = UUID(); id = callID; error = nil; outgoing = true
        do { try await controller.request(CXTransaction(action: CXStartCallAction(call: callID, handle: CXHandle(type: .generic, value: "Rowan")))) }
        catch { id = nil; throw error }
    }
    func end() {
        guard let id else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { error in
            if error != nil { Task { @MainActor in self.provider.reportCall(with: id, endedAt: Date(), reason: .failed); self.reset() } }
        }
    }
    func mute(_ value: Bool) {
        guard let id else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: value))) { error in
            if let error { Task { @MainActor in self.error = error.localizedDescription } }
        }
    }
    private func configureAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
    }
    private func reset() { id = nil; audioReady = false; muted = false }
    func providerDidReset(_ provider: CXProvider) { reset() }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        do { try configureAudio(); provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date()); action.fulfill() }
        catch { self.error = error.localizedDescription; action.fail(); reset() }
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        do { try configureAudio(); action.fulfill(); NotificationCenter.default.post(name: .init("VesperSystemCallAnswered"), object: nil) }
        catch { self.error = error.localizedDescription; action.fail(); provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed); reset() }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { action.fulfill(); reset() }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { muted = action.isMuted; action.fulfill() }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioReady = true
        if outgoing, let id { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if let id { provider.reportCall(with: id, endedAt: Date(), reason: .failed) }
        error = "The system call action timed out."; reset()
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { audioReady = false }
}
