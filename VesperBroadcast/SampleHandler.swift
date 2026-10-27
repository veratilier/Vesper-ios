import ReplayKit
import UIKit

final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var enabled = false
    private var sending = false
    private var lastFrame = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var lastPreferencesRead = Date.distantPast
    private var captureInterval: TimeInterval = 10
    private var seenLookRequest = 0
    private var work: Task<Void, Never>?
    private var client: BroadcastClient?
    private var configuration: BroadcastAccess.Configuration?
    private var generation = UUID()
    private let context = CIContext(options: [.cacheIntermediates: false])
    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        guard let credentials = BroadcastAccess.credentials() else {
            finishBroadcastWithError(NSError(domain: "Vesper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open Movie Room and prepare screen sharing first."])); return
        }
        configuration = credentials
        BroadcastAccess.resetObservation()
        client = BroadcastClient(configuration: credentials)
        lock.lock()
        enabled = true; lastFrame = .distantPast; lastHeartbeat = Date()
        captureInterval = BroadcastAccess.captureInterval()
        seenLookRequest = BroadcastAccess.lookRequest()
        lock.unlock()
        status("Sharing screen", sharing: true)
    }
    override func broadcastPaused() { stopSending(); status("Screen sharing paused", sharing: false) }
    override func broadcastResumed() {
        guard let configuration else { return }
        lock.lock(); client = BroadcastClient(configuration: configuration)
        enabled = true; lastFrame = .distantPast; lastHeartbeat = Date()
        seenLookRequest = BroadcastAccess.lookRequest(); lock.unlock()
        status("Sharing screen", sharing: true)
    }
    override func broadcastFinished() { stopSending(); status("Screen sharing ended", sharing: false) }
    private func stopSending() {
        lock.lock(); enabled = false; generation = UUID(); sending = false; let task = work; work = nil; let closingClient = client; lock.unlock()
        task?.cancel(); if let closingClient { Task { await closingClient.close() } }
    }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let now = Date()
        if now.timeIntervalSince(lastHeartbeat) >= 3 {
            lastHeartbeat = now
            BroadcastAccess.heartbeat()
        }
        var lookRequest = seenLookRequest
        if now.timeIntervalSince(lastPreferencesRead) >= 1 {
            lastPreferencesRead = now
            let preferences = BroadcastAccess.preferences()
            let requestedInterval = preferences["captureInterval"] as? Double ?? 10
            captureInterval = [5.0, 10.0, 20.0, 30.0].contains(requestedInterval) ? requestedInterval : 10
            lookRequest = preferences["lookRequest"] as? Int ?? 0
        }
        let forced = lookRequest > seenLookRequest
        guard !sending, forced || now.timeIntervalSince(lastFrame) >= captureInterval else { lock.unlock(); return }
        if forced { seenLookRequest = lookRequest }
        sending = true; lastFrame = now
        let frameGeneration = generation; let frameClient = client; lock.unlock()
        let data: Data? = autoreleasepool {
            guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            var image = CIImage(cvPixelBuffer: pixel)
            if let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                image = image.oriented(forExifOrientation: number.int32Value)
            }
            let scale = min(1, 900 / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
        }
        guard let data, let frameClient else { finishedFrame(frameGeneration); return }
        lock.lock()
        guard enabled, generation == frameGeneration else { lock.unlock(); return }
        work = Task { [weak self] in
            do {
                let reply = try await frameClient.observe(data, forced: forced)
                try Task.checkCancellation()
                self?.frameStatus("Frame received", reply: reply, generation: frameGeneration)
            } catch {
                if !Task.isCancelled { self?.frameStatus("Screen connection failed. Reopen Movie Room to check.", generation: frameGeneration) }
            }
            self?.finishedFrame(frameGeneration)
        }
        lock.unlock()
    }
    private func finishedFrame(_ captured: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard generation == captured else { return }
        sending = false; work = nil
    }
    private func frameStatus(_ text: String, reply: String? = nil, generation captured: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, generation == captured else { return }
        status(text, reply: reply)
    }
    private func status(_ text: String, reply: String? = nil, sharing: Bool? = nil) {
        BroadcastAccess.updateObservation(status: text, reply: reply, sharing: sharing)
    }
}

private actor BroadcastClient {
    private let configuration: BroadcastAccess.Configuration
    private let sessionID = UUID().uuidString
    private let transport: URLSession
    private var started = false
    private var ended = false
    init(configuration: BroadcastAccess.Configuration) {
        self.configuration = configuration
        let session = URLSessionConfiguration.ephemeral
        session.timeoutIntervalForRequest = 20
        session.timeoutIntervalForResource = 25
        session.urlCache = nil
        transport = URLSession(configuration: session)
    }
    func close() async {
        ended = true
        _ = try? await request("/companion/watch", body: ["action": "stop", "sessionId": sessionID])
        transport.invalidateAndCancel()
    }
    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let base = URL(string: configuration.historyURL), base.scheme == "https", base.host != nil,
              let url = URL(string: configuration.historyURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw NSError(domain: "VesperBroadcast", code: 3)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "VesperBroadcast", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    func observe(_ image: Data, forced: Bool) async throws -> String {
        guard !ended else { throw CancellationError() }
        if !started {
            _ = try await request("/companion/watch", body: ["action": "start", "sessionId": sessionID,
                "conversationId": configuration.conversationID, "instructions": configuration.instructions,
                "name": configuration.name, "userName": configuration.userName, "model": configuration.model])
            started = true
        }
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        let frameID = UUID().uuidString
        var result = try await request("/companion/watch", body: ["action": "frame", "sessionId": sessionID,
            "requestId": frameID, "image": image.base64EncodedString(), "force": forced])
        while !ended {
            try Task.checkCancellation()
            switch result["status"] as? String {
            case "completed": return result["reply"] as? String ?? ""
            case "quiet": return ""
            case "cancelled": throw CancellationError()
            case "failed": throw NSError(domain: "VesperBroadcast", code: 6)
            default: break
            }
            try await Task.sleep(for: .seconds(2))
            result = try await request("/companion/watch/\(sessionID)/\(frameID)")
        }
        throw CancellationError()
    }
}
