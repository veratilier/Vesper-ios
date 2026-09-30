import ReplayKit
import UIKit
import SwiftUI

private final class ScreenFrames {
    private let lock = NSLock()
    private var image: Data?
    private var capturedAt = Date.distantPast
    private let context = CIContext()
    func receive(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(capturedAt) >= 2,
              let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        let source = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, 1000 / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(resized, from: resized.extent) else { return }
        image = UIImage(cgImage: cg).jpegData(compressionQuality: 0.65); capturedAt = Date()
    }
    func snapshot() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(capturedAt) < 5 ? image : nil
    }
    func clear() { lock.lock(); image = nil; capturedAt = .distantPast; lock.unlock() }
}

@MainActor final class ScreenShare: NSObject, ObservableObject, RPScreenRecorderDelegate {
    @Published private(set) var active = false
    @Published private(set) var starting = false
    @Published var error: String?
    private let frames = ScreenFrames()
    private var generation = UUID()
    func start() {
        guard !active, !starting else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { error = "Screen sharing is unavailable on this device."; return }
        error = nil; starting = true; generation = UUID(); let request = generation
        recorder.delegate = self; recorder.isMicrophoneEnabled = false
        let frames = frames
        recorder.startCapture(handler: { buffer, type, error in
            if error == nil && type == .video { frames.receive(buffer) }
        }, completionHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard self.generation == request else { if error == nil { recorder.stopCapture { _ in } }; return }
                self.starting = false; self.active = error == nil; self.error = error?.localizedDescription
            }
        })
    }
    func snapshot() -> Data? { active ? frames.snapshot() : nil }
    func stop() {
        generation = UUID(); active = false; starting = false; frames.clear()
        if RPScreenRecorder.shared().isRecording { RPScreenRecorder.shared().stopCapture { _ in } }
    }
    nonisolated func screenRecorder(_ screenRecorder: RPScreenRecorder, didStopRecordingWith previewViewController: RPPreviewViewController?, error: Error?) {
        let detail = error?.localizedDescription
        Task { @MainActor in self.stop(); self.error = detail }
    }
}
