import AVFoundation
import Combine
#if os(iOS) && !targetEnvironment(macCatalyst)
import CallKit
#endif

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
            #if os(iOS) && !targetEnvironment(macCatalyst)
            let answeredWithCallKit = SystemIncomingCall.shared.hasAnsweredCall
            if !answeredWithCallKit { try session.setActive(true) }
            id = UUID(); muted = false; audioReady = !answeredWithCallKit || SystemIncomingCall.shared.audioActivated
            #else
            try session.setActive(true)
            id = UUID(); muted = false; audioReady = true
            #endif
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
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let answeredWithCallKit = SystemIncomingCall.shared.hasAnsweredCall
        #endif
        id = nil; audioReady = false; muted = false
        speakerEnabled = false; outputName = ""
        CallLiveActivity.shared.end()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if !answeredWithCallKit {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #else
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    #if os(iOS) && !targetEnvironment(macCatalyst)
    func callKitDidActivate() {
        if id != nil { audioReady = true; refreshOutput() }
    }
    func callKitDidDeactivate() {
        if id != nil { end() }
    }
    #endif
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Presents an already received in-app invitation using the iPhone call screen.
/// The invitation still depends on the existing foreground chat connection.
@MainActor final class SystemIncomingCall: NSObject, ObservableObject, @preconcurrency CXProviderDelegate {
    static let shared = SystemIncomingCall()
    static let answeredNotification = Notification.Name("VesperSystemCallAnswered")
    @Published private(set) var fallbackBackend: VesperBackend?
    private let provider: CXProvider
    private var callID: UUID?
    private var pendingBackend: VesperBackend?
    private(set) var hasAnsweredCall = false
    private(set) var audioActivated = false

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func present(backend: VesperBackend, name: String) {
        guard callID == nil else { return }
        let id = UUID()
        callID = id
        pendingBackend = backend
        fallbackBackend = nil
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self, self.callID == id else { return }
                if let error {
                    let failure = error as NSError
                    NSLog("Vesper CallKit incoming call rejected: %@ (%ld): %@",
                          failure.domain, failure.code, failure.localizedDescription)
                    self.callID = nil
                    self.pendingBackend = nil
                    self.fallbackBackend = backend
                }
            }
        }
    }

    func dismissPending(for backend: VesperBackend) {
        if fallbackBackend == backend { fallbackBackend = nil }
        guard pendingBackend == backend, let id = callID else { return }
        pendingBackend = nil
        callID = nil
        provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
    }

    func endFromApp() {
        guard hasAnsweredCall, let id = callID else { return }
        callID = nil
        pendingBackend = nil
        hasAnsweredCall = false
        audioActivated = false
        provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
    }

    func providerDidReset(_ provider: CXProvider) {
        let wasAnswered = hasAnsweredCall
        let backend = pendingBackend
        callID = nil
        pendingBackend = nil
        hasAnsweredCall = false
        audioActivated = false
        fallbackBackend = nil
        if let backend { NotificationCenter.default.post(name: .init("VesperSystemCallDeclined"), object: backend) }
        if wasAnswered {
            InAppCalls.shared.end()
            NativeCallPresentation.shared.close()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard action.callUUID == callID, let backend = pendingBackend else {
            action.fail(); return
        }
        pendingBackend = nil
        hasAnsweredCall = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat,
                                                            options: [.allowBluetoothHFP, .defaultToSpeaker])
            action.fulfill()
            NotificationCenter.default.post(name: Self.answeredNotification, object: backend)
        } catch {
            hasAnsweredCall = false
            callID = nil
            fallbackBackend = backend
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == callID else { action.fulfill(); return }
        let backend = pendingBackend
        let wasAnswered = hasAnsweredCall
        callID = nil
        pendingBackend = nil
        hasAnsweredCall = false
        audioActivated = false
        fallbackBackend = nil
        if let backend { NotificationCenter.default.post(name: .init("VesperSystemCallDeclined"), object: backend) }
        if wasAnswered {
            InAppCalls.shared.end()
            NativeCallPresentation.shared.close()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActivated = true
        InAppCalls.shared.callKitDidActivate()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActivated = false
        InAppCalls.shared.callKitDidDeactivate()
    }
}
#endif
