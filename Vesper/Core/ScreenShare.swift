import ReplayKit
import AVKit
import CoreMedia
import CoreVideo
import UIKit
import SwiftUI
#if !targetEnvironment(macCatalyst)
import AppIntents
#endif

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
                guard self.generation == request else { if error == nil { RPScreenRecorder.shared().stopCapture { _ in } }; return }
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

#if !targetEnvironment(macCatalyst)
struct VesperLookNowIntent: AppIntent {
    static var title: LocalizedStringResource = "看这一幕"
    static var description = IntentDescription("分享屏幕时，请 Ash 现在看一眼画面")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard BroadcastAccess.isSharing() else {
            throw NSError(domain: "VesperScreenShare", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先在 Vesper 开始分享屏幕。"])
        }
        try BroadcastAccess.requestLookNow()
        return .result()
    }
}

struct VesperScreenShareShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: VesperLookNowIntent(),
                    phrases: ["让 \(.applicationName) 看这一幕", "在 \(.applicationName) 看这一幕"],
                    shortTitle: "看这一幕", systemImageName: "eye")
    }
}

enum ScreenShareCardStyle: String, CaseIterable {
    case pearl, midnight
    var title: String { self == .pearl ? "雾白" : "深蓝" }
    var background: UIColor {
        self == .pearl
            ? UIColor(red: 0.91, green: 0.94, blue: 0.97, alpha: 1)
            : UIColor(red: 0.12, green: 0.17, blue: 0.23, alpha: 1)
    }
}

/// The broadcast extension owns capture and replies. This card only presents
/// its shared status; it never starts a second screen recorder or model turn.
@MainActor final class ScreenSharePiP: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    static let shared = ScreenSharePiP()
    @Published private(set) var active = false
    @Published private(set) var style = ScreenShareCardStyle(rawValue: UserDefaults.standard.string(forKey: "screenShareCardStyle") ?? "") ?? .pearl
    @Published var error: String?

    private weak var sourceView: ScreenSharePiPCard?
    private var floatingCard: ScreenSharePiPCard?
    private var videoView: ScreenSharePiPVideoView?
    private var controller: AVPictureInPictureController?
    private var polling: Timer?
    private var name = "Ash"
    private var avatar: UIImage?

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ view: ScreenSharePiPCard) {
        sourceView = view
        view.apply(style: style)
        refresh()
        guard controller == nil, Self.supported else { return }
        let floating = ScreenSharePiPCard()
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = CGSize(width: 360, height: 150)
        content.view.backgroundColor = style.background
        floating.frame = content.view.bounds
        floating.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let video = ScreenSharePiPVideoView(frame: content.view.bounds)
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.addSubview(video)
        content.view.addSubview(floating)
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: view, contentViewController: content)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        floatingCard = floating
        floating.apply(style: style)
        videoView = video
        controller = pip
        refresh()
    }

    func detach(_ view: ScreenSharePiPCard) {
        guard sourceView === view else { return }
        stop()
        sourceView = nil
        floatingCard = nil
        videoView = nil
        controller = nil
    }

    func setIdentity(name: String, avatar: UIImage?) {
        self.name = name
        self.avatar = avatar
        refresh()
    }

    func setStyle(_ selected: ScreenShareCardStyle) {
        style = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "screenShareCardStyle")
        sourceView?.apply(style: selected)
        floatingCard?.apply(style: selected)
        refresh()
    }

    func start() {
        guard Self.supported else { error = "这台 iPhone 暂不支持画中画。"; return }
        guard let controller, sourceView?.window != nil else {
            error = "小窗还没准备好，请稍候再试。"; return
        }
        guard BroadcastAccess.isSharing() else {
            error = "先点录屏按钮，选择 Vesper 开始分享屏幕。"; return
        }
        error = nil
        refresh()
        controller.startPictureInPicture()
    }

    func stop() {
        polling?.invalidate(); polling = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        active = false
    }

    private func refresh() {
        let observation = BroadcastAccess.observation()
        let status = observation["status"] as? String ?? ""
        if active && (status == "Screen sharing ended" || status == "Screen sharing paused") {
            stop(); return
        }
        let replyAt = observation["replyAt"] as? Double ?? 0
        let recentReply = Date().timeIntervalSince1970 - replyAt < 120
            ? String((observation["reply"] as? String ?? "").prefix(90)) : ""
        let subtitle = BroadcastAccess.isSharing()
            ? (status.hasPrefix("Screen connection failed") ? "正在分享 · 连接重试" : "正在看你的屏幕")
            : "等待屏幕分享"
        sourceView?.update(name: name, status: subtitle, reply: recentReply, avatar: avatar)
        floatingCard?.update(name: name, status: subtitle, reply: recentReply, avatar: avatar)
        if let floatingCard { videoView?.display(card: floatingCard) }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        active = true; error = nil; refresh()
        polling?.invalidate()
        polling = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        active = false
        self.error = "小窗未能打开：" + error.localizedDescription
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        polling?.invalidate(); polling = nil; active = false
    }
}

struct ScreenSharePiPSource: UIViewRepresentable {
    let manager: ScreenSharePiP
    func makeUIView(context: Context) -> ScreenSharePiPCard {
        let view = ScreenSharePiPCard()
        manager.attach(view)
        return view
    }
    func updateUIView(_ uiView: ScreenSharePiPCard, context: Context) { manager.attach(uiView) }
    static func dismantleUIView(_ uiView: ScreenSharePiPCard, coordinator: ()) {
        ScreenSharePiP.shared.detach(uiView)
    }
}

/// Render the companion card as real video frames. AVKit keeps the video-call
/// source current while its Picture in Picture window is outside the app.
@MainActor private final class ScreenSharePiPVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    func display(card: ScreenSharePiPCard) {
        let size = card.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        card.setNeedsLayout()
        card.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { context in
            card.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else { return }
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, cgImage.width, cgImage.height,
                                  kCVPixelFormatType_32BGRA, attributes, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel),
                                      width: cgImage.width, height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(cgImage.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixel,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: 2, preferredTimescale: 600),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: pixel,
                                                       formatDescription: format,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }
}

final class ScreenSharePiPCard: UIView {
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let replyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ScreenShareCardStyle.pearl.background
        layer.cornerRadius = 20
        clipsToBounds = true
        layer.borderWidth = 1
        avatarView.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        avatarView.tintColor = .white
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 24
        nameLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        nameLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        replyLabel.font = .systemFont(ofSize: 16)
        replyLabel.textColor = .white
        replyLabel.numberOfLines = 2
        let labels = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        labels.axis = .vertical; labels.spacing = 3
        let heading = UIStackView(arrangedSubviews: [avatarView, labels])
        heading.alignment = .center; heading.spacing = 12
        let column = UIStackView(arrangedSubviews: [heading, replyLabel])
        column.axis = .vertical; column.spacing = 13
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalToConstant: 48),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
        apply(style: .pearl)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(style: ScreenShareCardStyle) {
        let light = style == .pearl
        backgroundColor = style.background
        layer.borderColor = light ? UIColor.white.withAlphaComponent(0.9).cgColor
                                  : UIColor.white.withAlphaComponent(0.24).cgColor
        let ink = light ? UIColor(red: 0.12, green: 0.19, blue: 0.25, alpha: 1) : .white
        nameLabel.textColor = ink
        replyLabel.textColor = ink
        statusLabel.textColor = ink.withAlphaComponent(0.62)
        avatarView.backgroundColor = ink.withAlphaComponent(0.12)
        avatarView.tintColor = ink
    }

    func update(name: String, status: String, reply: String, avatar: UIImage?) {
        nameLabel.text = name
        statusLabel.text = status
        replyLabel.text = reply.isEmpty ? "有新发现会在这里告诉你" : "“\(reply)”"
        avatarView.image = avatar ?? UIImage(systemName: "person.fill")
    }
}
#endif
