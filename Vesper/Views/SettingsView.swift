import SwiftUI
import PhotosUI
import Photos
import ImageIO
import UserNotifications
import AuthenticationServices
import CryptoKit
import Security
import EventKit
import HealthKit
import AVFoundation
import Speech
#if os(iOS) && !targetEnvironment(macCatalyst)
import MapKit
import CoreBluetooth
import CoreMotion
import Intents
import MusicKit
#endif

// Settings use the same glass surface as the rest of the app.
private struct SettingsGlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var interactive = false
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .vesperGlass(in: RoundedRectangle(cornerRadius: 25), interactive: interactive)
    }
}

struct SettingsView: View {
    var body: some View {
        Page(title: "Settings") {
            settingsSection("PERSONALIZE") {
                NavigationLink { AppearanceSettingsView() } label: { settingsRow("Appearance", icon: "paintpalette") }
                #if os(iOS) && !targetEnvironment(macCatalyst)
                separator
                NavigationLink { PictureWidgetSettingsView() } label: { settingsRow("Picture Widget", icon: "photo.on.rectangle") }
                separator
                NavigationLink { CompanionIslandSettingsView() } label: { settingsRow("Dynamic Island", icon: "sparkles.rectangle.stack") }
                #endif
                separator
                NavigationLink { VoiceSettingsView() } label: { settingsRow("Voice", icon: "waveform") }
            }
            settingsSection("ASH & ACTIVITY") {
                #if os(iOS) && !targetEnvironment(macCatalyst)
                NavigationLink { ArrivalSettingsView() } label: { settingsRow("Arrival", icon: "mappin.and.ellipse") }
                separator
                #endif
                NavigationLink { BarkSettingsView() } label: { settingsRow("Bark notifications", icon: "bell.badge") }
            }
            settingsSection("DEVICE & DATA") {
                NavigationLink { DevicePermissionsView() } label: { settingsRow("Permissions", icon: "hand.raised") }
                separator
                NavigationLink { DataSettingsView() } label: { settingsRow("Data", icon: "archivebox") }
            }
        }.buttonStyle(.plain).background { Background() }.transparentNavigationTop()
    }
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .tracking(0.8).foregroundStyle(VesperTheme.muted)
                .padding(.leading, 8).accessibilityAddTraits(.isHeader)
            SettingsGlassCard(padding: 0, interactive: true) {
                VStack(spacing: 0) { content() }
            }
        }
    }
    private var separator: some View { Divider().padding(.leading, 62).padding(.trailing, 16) }
    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 30, height: 32)
            Text(title).font(.system(size: 17, weight: .medium))
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(VesperTheme.muted)
        }.padding(.horizontal, 16).padding(.vertical, 14).frame(minHeight: 60)
            .contentShape(Rectangle())
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
private struct CompanionIslandSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var companion = CompanionLiveActivity.shared
    @AppStorage(CompanionLeadingStyle.key, store: UserDefaults(suiteName: CompanionLeadingStyle.appGroup))
    private var leadingStyle = CompanionLeadingStyle.pixelSnake.rawValue

    var body: some View {
        Page(title: "Dynamic Island") {
            SettingsGlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Island companion", isOn: Binding(
                        get: { companion.isActive },
                        set: { enabled in
                            if enabled {
                                companion.start(avatar: store.document("profile")["agentAvatar"].string,
                                                baseURL: store.baseURL, name: store.agentDisplayName,
                                                backend: store.activeBackend)
                            } else {
                                Task { await companion.end() }
                            }
                        }
                    ))
                    .font(.system(size: 17, weight: .semibold))
                    .tint(VesperTheme.ink)
                    .disabled(companion.working)
                    Text("Keep Ash in the Dynamic Island and on the Lock Screen.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                    if let error = companion.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            Text("LEFT ICON")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8).foregroundStyle(VesperTheme.muted)
                .padding(.horizontal, 5)
            SettingsGlassCard(padding: 0) {
                VStack(spacing: 0) {
                    choice(.pixelSnake, title: "像素小蛇", detail: "敲一下时会轻轻动一下") {
                        CompanionPixelSnake(size: 42)
                            .frame(width: 48, height: 48)
                            .background(.black, in: Circle())
                    }
                    Divider().padding(.leading, 76)
                    choice(.avatar, title: "Ash 头像", detail: "使用当前聊天头像") {
                        CallPortrait().frame(width: 42, height: 42)
                            .frame(width: 48, height: 48)
                    }
                }
            }
            Text("实时活动只会在状态变化时播放短暂过渡，小蛇不会持续循环运动。")
                .font(.footnote).foregroundStyle(VesperTheme.muted)
                .padding(.horizontal, 5)
        }
        .buttonStyle(.plain)
        .background { Background() }
        .transparentNavigationTop()
        .onChange(of: leadingStyle) { _, _ in CompanionLiveActivity.shared.refreshAppearance() }
        .onAppear { companion.refresh() }
    }

    private func choice<Icon: View>(_ style: CompanionLeadingStyle, title: String,
                                    detail: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button { leadingStyle = style.rawValue } label: {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .medium))
                    Text(detail).font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Spacer(minLength: 8)
                if leadingStyle == style.rawValue {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(VesperTheme.ink)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(leadingStyle == style.rawValue ? .isSelected : [])
    }
}
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
struct PictureWidgetSettingsView: View {
    @State private var selection: [PhotosPickerItem] = []
    @State private var photos: [WidgetPictureItem] = []
    @State private var saving = false
    @State private var error: String?
    @State private var renamingID: String?
    @State private var name = ""

    var body: some View {
        PermissionPage(title: "Picture Widget") {
            SettingsGlassCard {
                HStack(spacing: 14) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 24))
                        .frame(width: 46, height: 46)
                        .background(VesperTheme.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your widget photos").font(.system(size: 17, weight: .semibold))
                        Text("Saved on this iPhone").font(.subheadline).foregroundStyle(VesperTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Text("\(photos.count)").font(.subheadline.weight(.semibold))
                        .foregroundStyle(VesperTheme.muted)
                }
            }

            PhotosPicker(selection: $selection, matching: .images) {
                Label("Add photos", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(PermissionActionStyle())
            .disabled(saving)
            if saving { ProgressView("Saving photos…") }

            if photos.isEmpty {
                SettingsGlassCard {
                    Text("Add a photo to use it in a Home Screen widget.")
                        .foregroundStyle(VesperTheme.muted)
                }
            } else {
                Text("SAVED PHOTOS").font(.system(size: 12, weight: .semibold))
                    .tracking(0.8).foregroundStyle(VesperTheme.muted)
                    .padding(.leading, 8)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(photos) { photo in photoCard(photo) }
                }
            }

            SettingsGlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use on your Home Screen").font(.system(size: 16, weight: .semibold))
                    Text("Long press a Vesper picture widget → Edit Widget → Picture: Saved photo → choose a name. Pick Dark or Photo under Style.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
            }
        }
        .onAppear {
            do { try WidgetPictureStore.migrateLegacyPicture() }
            catch { self.error = error.localizedDescription }
            photos = WidgetPictureStore.items()
        }
        .onChange(of: selection) { _, selected in
            guard !selected.isEmpty else { return }
            saving = true
            Task {
                defer { saving = false; selection = [] }
                for item in selected {
                    do {
                        guard let raw = try await item.loadTransferable(type: Data.self),
                              let source = CGImageSourceCreateWithData(raw as CFData,
                                  [kCGImageSourceShouldCache: false] as CFDictionary),
                              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: 1200,
                                  kCGImageSourceShouldCacheImmediately: true
                              ] as CFDictionary),
                              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.78) else {
                            throw NSError(domain: "Vesper.WidgetPicture", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Could not read a selected photo."])
                        }
                        _ = try WidgetPictureStore.add(jpeg)
                    } catch { self.error = error.localizedDescription }
                }
                photos = WidgetPictureStore.items()
                WidgetSync.pictureChanged()
            }
        }
        .alert("Rename photo", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renamingID, !trimmed.isEmpty {
                    do {
                        try WidgetPictureStore.rename(id, to: String(trimmed.prefix(50)))
                        photos = WidgetPictureStore.items()
                    } catch { self.error = error.localizedDescription }
                }
                renamingID = nil
            }
            Button("Cancel", role: .cancel) { renamingID = nil }
        } message: {
            Text("This name appears in the widget's Saved Photo list.")
        }
        .alert("Picture Widget", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func photoCard(_ photo: WidgetPictureItem) -> some View {
        SettingsGlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if let data = WidgetPictureStore.image(for: photo.id),
                       let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").resizable().scaledToFit()
                            .padding(32).foregroundStyle(VesperTheme.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 15))
                HStack(spacing: 4) {
                    Text(photo.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Rename", systemImage: "pencil") {
                            renamingID = photo.id
                            name = photo.name
                        }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            do {
                                try WidgetPictureStore.remove(photo.id)
                                photos = WidgetPictureStore.items()
                                WidgetSync.pictureChanged()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Edit \(photo.name)")
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(VesperTheme.ink)
    }
}
#endif
// Shared permission layout keeps the navigation title, cards and actions consistent.
struct PermissionPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @AppStorage("vesperPalette") private var palette = "blue"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .font(.system(size: 15)).padding(20).padding(.bottom, 90)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(VesperTheme.ink)
            .background { Background() }.transparentNavigationTop()
    }
}
struct PermissionPanel<Content: View>: View {
    var compact = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 15 : 20)
            .vesperMaterial(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(VesperTheme.palette == .black ? Color.white.opacity(0.16) : Color.white.opacity(0.7), lineWidth: 1))
    }
}
struct PermissionActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(VesperTheme.palette == .black ? Color.black : .white)
            .padding(.horizontal, 18).frame(minHeight: 44)
            .background(VesperTheme.ink, in: Capsule()).opacity(configuration.isPressed ? 0.7 : 1)
    }
}
enum PermissionLabels {
    static func calendar(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: return "Allowed"
        case .writeOnly: return "Write only"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        default: return "Check Settings"
        }
    }
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
struct DevicePermissionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var weather = WeatherController.shared
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ObservedObject private var arrival = NativeArrivalMonitor.shared
    @ObservedObject private var bluetooth = NativeBluetoothAccess.shared
    @State private var focusStatus = INFocusStatusCenter.default.authorizationStatus
    @State private var motionStatus = CMMotionActivityManager.authorizationStatus()
    @State private var musicStatus = MusicAuthorization.currentStatus
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    #endif
    @State private var notifications = "Checking…"
    @State private var calendar = "Checking…"
    @State private var reminders = "Checking…"
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    #endif
    var body: some View {
        PermissionPage(title: "Permissions") {
            Text("Choose what Vesper can access on this device.").font(.subheadline).foregroundStyle(VesperTheme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                card("Location", icon: "location.fill", status: weather.authorized ? "Allowed" : "Not allowed", detail: "Read your current location in chat and show local weather.") { WeatherPermissionsView() }
                #if os(iOS) && !targetEnvironment(macCatalyst)
                card("Places", icon: "mappin.and.ellipse", status: arrival.authorization == .authorizedAlways ? "Background on" : "Needs Always", detail: "Save multiple places and let Ash greet you when you arrive nearby.") { ArrivalSettingsView() }
                card("Photos", icon: "photo", status: PhotoAccessInfoView.label(photoStatus), detail: "Let Ash browse photos on this iPhone with your authorization.") { PhotoAccessInfoView() }
                #endif
                card("Health", icon: "heart.fill", status: HKHealthStore.isHealthDataAvailable() ? "Manage access" : "Unavailable", detail: "Choose which health summaries \(store.agentDisplayName) may read.") { HealthView() }
                card("Calendar", icon: "calendar", status: calendar, detail: "Read upcoming events and add plans from chat.") { SystemPlannerView(reminderOnly: false) }
                card("Reminders", icon: "checklist", status: reminders, detail: "Let \(store.agentDisplayName) add tasks to Apple Reminders.") { SystemPlannerView(reminderOnly: true) }
                card("Notifications", icon: "bell.fill", status: notifications, detail: "Receive date and synced letter reminders.") { NotificationSettingsView() }
            }
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Text("Calls & voice").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                card("Microphone", icon: "mic.fill", status: SimplePermissionView.captureLabel(microphoneStatus), detail: "Voice messages and calls.") { SimplePermissionView(kind: .microphone) }
                card("Speech Recognition", icon: "waveform", status: SimplePermissionView.speechLabel(speechStatus), detail: "Speech to text during calls.") { SimplePermissionView(kind: .speech) }
                card("Camera", icon: "camera.fill", status: SimplePermissionView.captureLabel(cameraStatus), detail: "Photos and call camera.") { SimplePermissionView(kind: .camera) }
            }
            #endif
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Text("More device context").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                card("Bluetooth", icon: "antenna.radiowaves.left.and.right", status: SimplePermissionView.bluetoothLabel(bluetooth.authorization), detail: "Nearby accessories when you ask.") { SimplePermissionView(kind: .bluetooth) }
                card("Focus", icon: "moon.fill", status: SimplePermissionView.focusLabel(focusStatus), detail: "Whether notifications are silenced.") { SimplePermissionView(kind: .focus) }
                card("Motion & Fitness", icon: "figure.walk", status: SimplePermissionView.motionLabel(motionStatus), detail: "Recent movement when you ask.") { SimplePermissionView(kind: .motion) }
                card("Apple Music", icon: "music.note", status: SimplePermissionView.musicLabel(musicStatus), detail: "Your library and playback.") { SimplePermissionView(kind: .music) }
            }
            Text("Nearby Bluetooth and motion reads work only while this iPhone is connected. Vesper's own Now Playing state does not need a separate iOS permission.")
                .font(.caption).foregroundStyle(VesperTheme.muted)
            #endif
        }.onAppear {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            refreshSimplePermissions()
            #endif
        }.task(id: phase) {
            guard phase == .active else { return }
            calendar = PermissionLabels.calendar(.event); reminders = PermissionLabels.calendar(.reminder)
            #if os(iOS) && !targetEnvironment(macCatalyst)
            refreshSimplePermissions()
            #endif
            let value = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            switch value {
            case .authorized: notifications = "Allowed"
            case .provisional, .ephemeral: notifications = "Limited"
            case .denied: notifications = "Off"
            default: notifications = "Not requested"
            }
        }
    }
    private func card<Destination: View>(_ title: String, icon: String, status: String, detail: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            PermissionPanel(compact: true) {
                HStack(alignment: .top) {
                    Image(systemName: icon).font(.system(size: 19))
                    Spacer(minLength: 4)
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(VesperTheme.muted).multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(VesperTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VesperTheme.palette == .black ? Color.black : .white)
                    .padding(.horizontal, 16).frame(height: 34).background(VesperTheme.ink, in: Capsule())
            }.frame(minHeight: typeSize.isAccessibilitySize ? 220 : 190)
        }.buttonStyle(.plain)
    }
    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func refreshSimplePermissions() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        focusStatus = INFocusStatusCenter.default.authorizationStatus
        motionStatus = CMMotionActivityManager.authorizationStatus()
        musicStatus = MusicAuthorization.currentStatus
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }
    #endif
}
#if os(iOS) && !targetEnvironment(macCatalyst)
private struct SimplePermissionView: View {
    enum Kind: Hashable {
        case microphone, speech, camera, bluetooth, focus, motion, music
        var canCheck: Bool { self == .bluetooth || self == .focus || self == .motion }
    }
    let kind: Kind
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var bluetooth = NativeBluetoothAccess.shared
    @State private var capture = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var focus = INFocusStatusCenter.default.authorizationStatus
    @State private var motion = CMMotionActivityManager.authorizationStatus()
    @State private var music = MusicAuthorization.currentStatus
    @State private var busy = false
    @State private var checking = false
    @State private var detail = ""
    @State private var checkResult = ""

    static func captureLabel(_ value: AVAuthorizationStatus) -> String {
        switch value {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }
    static func speechLabel(_ value: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch value {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }
    static func bluetoothLabel(_ value: CBManagerAuthorization) -> String {
        switch value {
        case .allowedAlways: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }
    static func focusLabel(_ value: INFocusStatusAuthorizationStatus) -> String {
        switch value {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }
    static func motionLabel(_ value: CMAuthorizationStatus) -> String {
        switch value {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }
    static func musicLabel(_ value: MusicAuthorization.Status) -> String {
        switch value {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }

    private var title: String {
        switch kind {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .camera: return "Camera"
        case .bluetooth: return "Bluetooth"
        case .focus: return "Focus"
        case .motion: return "Motion & Fitness"
        case .music: return "Apple Music"
        }
    }
    private var status: String {
        switch kind {
        case .microphone, .camera: return Self.captureLabel(capture)
        case .speech: return Self.speechLabel(speech)
        case .bluetooth: return Self.bluetoothLabel(bluetooth.authorization)
        case .focus: return Self.focusLabel(focus)
        case .motion: return Self.motionLabel(motion)
        case .music: return Self.musicLabel(music)
        }
    }
    private var explanation: String {
        switch kind {
        case .microphone: return "Used when you speak in a call or record a voice message."
        case .speech: return "Converts your speech into text during calls and voice messages."
        case .camera: return "Used when you take a photo or share camera frames in a call."
        case .bluetooth: return "Ash can briefly check nearby Bluetooth accessory names when you ask."
        case .focus: return "Ash can check whether Focus is silencing notifications, but not which mode is active."
        case .motion: return "Ash can check recent movement when you ask; this does not reveal your location."
        case .music: return "Vesper uses this for your Apple Music library and playback."
        }
    }
    var body: some View {
        PermissionPage(title: title) {
            PermissionPanel {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Text(explanation).foregroundStyle(VesperTheme.muted)
                Button(busy ? "Requesting…" : "Allow access") { Task { await request() } }
                    .buttonStyle(PermissionActionStyle()).disabled(busy)
                if status != "Not requested" {
                    Button("Open iPhone Settings") { PermissionLabels.openSettings() }
                        .buttonStyle(PermissionActionStyle())
                }
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(VesperTheme.muted) }
            }
            if kind.canCheck && status == "Allowed" {
                PermissionPanel(compact: true) {
                    Button(checking ? "Checking…" : "Check now") { Task { await check() } }
                        .buttonStyle(PermissionActionStyle()).disabled(checking)
                    if !checkResult.isEmpty {
                        Text(checkResult).font(.subheadline).foregroundStyle(VesperTheme.muted)
                    }
                }
            }
            if kind == .bluetooth {
                Text("A nearby BLE scan does not show every device or prove a connection. Call audio uses the iPhone's audio route.")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }
        }.task(id: phase) { if phase == .active { refresh() } }
    }
    private func refresh() {
        capture = AVCaptureDevice.authorizationStatus(for: kind == .camera ? .video : .audio)
        speech = SFSpeechRecognizer.authorizationStatus()
        focus = INFocusStatusCenter.default.authorizationStatus
        motion = CMMotionActivityManager.authorizationStatus()
        music = MusicAuthorization.currentStatus
    }
    private func request() async {
        guard !busy else { return }
        if status == "Allowed" { detail = "Already allowed."; return }
        if status == "Off" { detail = "Access is off. Change it in iPhone Settings."; PermissionLabels.openSettings(); return }
        if status == "Restricted" { detail = "Access is restricted on this iPhone."; return }
        busy = true; detail = ""
        switch kind {
        case .microphone: _ = await AVAudioApplication.requestRecordPermission()
        case .speech:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .bluetooth: bluetooth.request()
        case .focus: _ = await INFocusStatusCenter.default.requestAuthorization()
        case .motion: _ = try? await NativeContextAccess.motion()
        case .music: _ = await MusicAuthorization.request()
        }
        refresh(); busy = false
    }
    private func check() async {
        guard !checking else { return }
        checking = true
        do {
            switch kind {
            case .bluetooth:
                let names = try await bluetooth.scan()["nearbyNames"].array.map(\.string).filter { !$0.isEmpty }
                checkResult = names.isEmpty ? "No named accessories found nearby." : "Nearby: " + names.prefix(3).joined(separator: ", ")
            case .focus:
                let focused = try NativeContextAccess.focus()["focused"]
                checkResult = focused == .null ? "Focus status unavailable." : focused.bool ? "Focus is on." : "Focus is off."
            case .motion:
                let activity = try await NativeContextAccess.motion()["activity"].string
                checkResult = activity == "unknown" ? "No recent movement signal." : "Recent activity: " + activity + "."
            default: break
            }
        } catch { checkResult = error.localizedDescription }
        checking = false
    }
}

private struct PhotoAccessInfoView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var requesting = false

    static func label(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Full Access"
        case .limited: return "Selected only"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not requested"
        }
    }
    var body: some View {
        PermissionPage(title: "Photos") {
            PermissionPanel {
                HStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 27))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("iPhone Photos").font(.headline)
                        Text(Self.label(status)).font(.subheadline).foregroundStyle(VesperTheme.muted)
                    }
                    Spacer()
                }
                Text("Ash can browse and view your system photo library while Vesper is connected. Photos he opens are included in the chat's tool results. Your originals stay in Photos.")
                    .foregroundStyle(VesperTheme.muted)
                if status == .notDetermined {
                    Button(requesting ? "Requesting…" : "Allow Full Access") {
                        requesting = true
                        Task {
                            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            requesting = false
                        }
                    }.buttonStyle(PermissionActionStyle()).disabled(requesting)
                } else if status != .authorized {
                    Button("Open iPhone Settings") { PermissionLabels.openSettings() }
                        .buttonStyle(PermissionActionStyle())
                    if status == .limited {
                        Text("Choose Full Access in iPhone Settings to let Ash browse beyond the photos you selected.")
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }
            }
            PermissionPanel(compact: true) {
                Text("Original photos stay on this iPhone. New previews are no longer synced to the server. Ash can view photos in a connected chat, but not during autonomous wakes. Earlier synced previews remain on your private server.")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
            }
        }.task(id: phase) { if phase == .active { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) } }
    }
}
struct ArrivalSettingsView: View {
    @ObservedObject private var monitor = NativeArrivalMonitor.shared
    @State private var showingEditor = false
    @State private var deletingID: String?
    @State private var editingID: String?
    @State private var name = ""
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var locationLabel = "Choose a location"
    @State private var radius = 300.0
    @State private var searching = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        PermissionPage(title: "Arrival") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your places").font(.system(size: 27, weight: .bold))
                    Text("Ash can greet you when you arrive.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                Spacer(minLength: 8)
                Button { startAdding() } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                }.buttonStyle(PermissionActionStyle())
                    .accessibilityIdentifier("arrival-add-place")
                    .disabled(monitor.places.count >= 10)
            }
            if monitor.authorization != .authorizedAlways {
                PermissionPanel(compact: true) {
                    Label("Allow background location", systemImage: "location.circle").font(.headline)
                    Text("iOS needs Always Location to notice arrivals while Vesper is closed or your phone is locked.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                    HStack(spacing: 14) {
                        Button("Allow Always") { monitor.requestAlwaysAccess() }.buttonStyle(PermissionActionStyle())
                        Button("Settings") { PermissionLabels.openSettings() }.font(.subheadline)
                    }
                }
            }
            if monitor.places.isEmpty {
                PermissionPanel {
                    Image(systemName: "mappin.slash.circle").font(.system(size: 32)).foregroundStyle(VesperTheme.muted)
                    Text("No places yet").font(.headline)
                    Text("Add home, school, or anywhere you want Ash to recognize. You can search an address or use your current location.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                    Button("Add a place") { startAdding() }.buttonStyle(PermissionActionStyle())
                }
            } else {
                if let overlap = overlappingArrivalPlaces {
                    PermissionPanel(compact: true) {
                        Label(overlap.distance < 30 ? "These places share one location" : "Arrival areas overlap",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text(overlap.distance < 30
                             ? "\(overlap.first.name) and \(overlap.second.name) are saved at the same point. iPhone cannot tell which one you reached."
                             : "\(overlap.first.name) and \(overlap.second.name) overlap. Crossing between them may not count as a new arrival.")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted)
                        HStack(spacing: 16) {
                            Button("Edit \(overlap.first.name)") { edit(overlap.first) }
                            Button("Edit \(overlap.second.name)") { edit(overlap.second) }
                        }.font(.subheadline.weight(.semibold))
                    }
                }
                ForEach(monitor.places) { place in
                    PermissionPanel(compact: true) {
                        HStack(spacing: 12) {
                            Image(systemName: place.enabled ? "mappin.circle.fill" : "mappin.circle")
                                .font(.system(size: 27)).frame(width: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name).font(.system(size: 17, weight: .semibold))
                                Text("Arrival area · \(Int(place.radius)) m")
                                    .font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                            Spacer(minLength: 4)
                            Toggle(place.name, isOn: Binding(
                                get: { monitor.places.first(where: { $0.id == place.id })?.enabled ?? false },
                                set: { monitor.setEnabled($0, for: place.id) }
                            )).labelsHidden().accessibilityLabel("Monitor \(place.name)")
                        }
                        HStack {
                            Button("Edit") { edit(place) }.font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Delete", role: .destructive) { deletingID = place.id }
                                .font(.subheadline)
                        }
                    }
                }
            }
            if !monitor.status.isEmpty {
                Text(monitor.status).font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Text("Arrival is approximate and may be delayed by iOS. Coordinates stay on this iPhone; Ash receives the place name after an arrival. Repeat greetings are limited.")
                .font(.caption).foregroundStyle(VesperTheme.muted)
        }
        .onAppear { monitor.resume() }
        .sheet(isPresented: $showingEditor) { editor }
        .confirmationDialog("Delete this place?", isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }
        )) {
            Button("Delete Place", role: .destructive) {
                if let deletingID { monitor.deletePlace(deletingID) }
                deletingID = nil
            }
        }
    }
    private var overlappingArrivalPlaces: (first: SavedArrivalPlace, second: SavedArrivalPlace, distance: Double)? {
        let places = monitor.places.filter(\.enabled)
        guard places.count > 1 else { return nil }
        for first in 0..<(places.count - 1) {
            for second in (first + 1)..<places.count {
                let a = CLLocation(latitude: places[first].latitude, longitude: places[first].longitude)
                let b = CLLocation(latitude: places[second].latitude, longitude: places[second].longitude)
                let distance = a.distance(from: b)
                if distance < places[first].radius + places[second].radius {
                    return (places[first], places[second], distance)
                }
            }
        }
        return nil
    }
    private var editor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PermissionPanel {
                        Text("Name").font(.headline)
                        TextField("Home, school, café…", text: $name)
                            .textFieldStyle(.roundedBorder).textInputAutocapitalization(.words)
                            .accessibilityIdentifier("arrival-place-name")
                    }
                    PermissionPanel {
                        Text("Location").font(.headline)
                        Label(locationLabel, systemImage: coordinate == nil ? "mappin.slash" : "mappin.circle.fill")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted)
                        Button {
                            Task { await markCurrentLocation() }
                        } label: {
                            Label(working ? "Locating…" : "Use Current Location", systemImage: "location.fill")
                        }.buttonStyle(PermissionActionStyle()).disabled(working)
                        HStack {
                            TextField("Search an address or place", text: $query)
                                .textFieldStyle(.roundedBorder).submitLabel(.search)
                                .onSubmit { Task { await searchPlaces() } }
                            Button { Task { await searchPlaces() } } label: {
                                Image(systemName: "magnifyingglass").frame(width: 38, height: 38)
                            }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityLabel("Search places")
                        }
                        if searching { ProgressView("Searching…") }
                        ForEach(results.indices, id: \.self) { index in
                            let item = results[index]
                            Button {
                                coordinate = item.placemark.coordinate
                                locationLabel = item.name ?? item.placemark.title ?? "Selected place"
                                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    name = item.name ?? ""
                                }
                                results = []
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? "Place").fontWeight(.medium)
                                    if let address = item.placemark.title {
                                        Text(address).font(.caption).foregroundStyle(VesperTheme.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }.buttonStyle(.plain)
                            if index < results.count - 1 { Divider() }
                        }
                    }
                    PermissionPanel {
                        HStack {
                            Text("Arrival area").font(.headline)
                            Spacer()
                            Text("\(Int(radius)) m").foregroundStyle(VesperTheme.muted)
                        }
                        Slider(value: $radius, in: 200...800, step: 100)
                        Text("A wider area is more reliable when GPS is imprecise.")
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.red) }
                }.padding(20)
            }
            .background { Background() }
            .navigationTitle(editingID == nil ? "Add Place" : "Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { savePlace() }
                        .fontWeight(.semibold)
                        .disabled(coordinate == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("arrival-save-place")
                }
            }
        }
    }
    private func startAdding() {
        clearForm(); showingEditor = true
    }
    private func edit(_ place: SavedArrivalPlace) {
        editingID = place.id; name = place.name
        coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        locationLabel = place.name; radius = place.radius; query = ""; results = []; message = nil
        showingEditor = true
    }
    private func clearForm() {
        editingID = nil; name = ""; coordinate = nil; locationLabel = "Choose a location"
        radius = 300; query = ""; results = []; message = nil
    }
    private func markCurrentLocation() async {
        working = true; defer { working = false }
        do {
            let locator = NativeChatLocation()
            let fix = try await locator.read()
            guard fix["precisePermission"].bool else { throw ServiceError(message: "Enable Precise Location before saving a place.") }
            coordinate = CLLocationCoordinate2D(latitude: fix["latitude"].number, longitude: fix["longitude"].number)
            locationLabel = "Current location · ±\(Int(fix["horizontalAccuracyMeters"].number)) m"
            message = nil
        } catch { message = error.localizedDescription }
    }
    private func searchPlaces() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true; defer { searching = false }
        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.resultTypes = [.pointOfInterest, .address]
            results = Array(try await MKLocalSearch(request: request).start().mapItems.prefix(8))
            message = results.isEmpty ? "No matching places found." : nil
        } catch { message = error.localizedDescription }
    }
    private func savePlace() {
        guard let coordinate else { return }
        do {
            try monitor.savePlace(id: editingID, name: name, coordinate: coordinate, radius: radius)
            showingEditor = false
            clearForm()
        } catch { message = error.localizedDescription }
    }
}
#endif
/// Shared by Studio and first-run pairing; existing server addresses stay intact.
struct DeviceTokenEditor: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @State private var credential = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("VPS device token", text: $credential)
                .foregroundStyle(VesperTheme.ink).textContentType(.password)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("device-token-field")
            Button {
                let connection = BackendConnection(baseURL: store.baseURL, historyURL: store.historyURL, socketURL: store.socketURL)
                let token = credential
                saving = true
                Task {
                    if await store.saveConnection(connection: connection, credential: token,
                                                  canSave: { chat.canSwitchBackend }) {
                        chat.configure(store)
                    }
                    saving = false
                }
            } label: {
                HStack { if saving { ProgressView() }; Text(saving ? "Saving…" : "Save token") }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving || store.loading || !chat.canSwitchBackend || credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("save-backend-connection")
            if !chat.canSwitchBackend { Text("Finish the current reply or call before changing the token.").font(.caption) }
            Text(store.connected ? "Connected" : store.token.isEmpty ? "Not configured" : "Saved")
                .font(.caption).foregroundStyle(VesperTheme.muted)
            if let error = store.connectionError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear {
            do { credential = try CredentialStore.load(account: VesperBackend.vps.credentialAccount) }
            catch { credential = ""; store.connectionError = error.localizedDescription }
        }
    }
}
/// Keep every Heartbeat navigation level on the same wallpaper. The navigation
/// surface follows the appearance choice: native clear glass or classic blur.
private struct WakePageAppearance: ViewModifier {
    @AppStorage("glassStyle") private var glassStyle = VesperGlassStyle.liquid.rawValue
    @AppStorage("glassTransparency") private var classicTransparency = 0.0

    @ViewBuilder func body(content: Content) -> some View {
        if glassStyle == VesperGlassStyle.classic.rawValue {
            content.background { Background() }
                .toolbarBackground(.ultraThinMaterial.opacity(1 - GlassAppearance.transparency(classicTransparency)), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content.background { Background() }.transparentNavigationTop()
        }
    }
}

private extension View {
    func wakePageAppearance() -> some View { modifier(WakePageAppearance()) }

    /// Preserve scroll insets for the controls, without cutting off the glass
    /// cards as they pass behind the header and floating bottom navigation.
    @ViewBuilder func wakeScrollAppearance() -> some View {
        if #available(iOS 26.0, *) {
            scrollClipDisabled().scrollEdgeEffectHidden(true, for: .vertical)
        } else {
            scrollClipDisabled()
        }
    }

    func wakeListRow() -> some View {
        listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    func wakeSubpageAppearance(_ title: String) -> some View {
        modifier(WakeSubpageAppearance(title: title, trailing: EmptyView()))
    }

    func wakeSubpageAppearance<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(WakeSubpageAppearance(title: title, trailing: trailing()))
    }
}

private struct WakeGlassSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold))
                .padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
            SettingsGlassCard(padding: 0, interactive: true) {
                VStack(spacing: 0) { content }
            }
        }
    }
}

private extension View {
    func wakeGlassRow() -> some View {
        padding(.horizontal, 18).padding(.vertical, 14).frame(minHeight: 55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Inset the floating header without putting the scroll view in a shorter
/// VStack, which clips glass cards at the header's lower edge.
private struct WakeSubpageAppearance<Trailing: View>: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let trailing: Trailing

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .wakeScrollAppearance()
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geometry.safeAreaInsets.top + 44)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 30)
                        Color.black
                    }
                    .ignoresSafeArea(.container, edges: .vertical)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    ZStack {
                        Text(title).font(.headline).lineLimit(1)
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .vesperMaterial(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back")
                            Spacer()
                            trailing.frame(width: 44, height: 44)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 58)
                    .frame(maxWidth: .infinity)
                }
        }
        .foregroundStyle(VesperTheme.ink)
        .background { Background() }
        .toolbar(.hidden, for: .navigationBar)
        .transparentNavigationTop()
    }
}

struct WakeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let onOpenSidebar: (() -> Void)?
    init(onOpenSidebar: (() -> Void)? = nil) { self.onOpenSidebar = onOpenSidebar }
    @State private var runtime: JSONValue = .null
    @State private var enabled = false
    @State private var backgroundVoiceOn = false
    @State private var intervalMinutes = 0
    @State private var allowedTools: Set<String> = []
    @State private var allowedMessages: Set<String> = []
    @State private var busy = false
    @State private var status = ""
    private var supported: Bool { runtime["permissionVersion"].number >= 1 }
    private var recovery: JSONValue { runtime["recovery"] }
    private var intervalOptions: [Int] {
        // Keep any previously saved custom duration selectable when opening the page.
        Array(Set([0, 30, 45, 60, 90, 120, 180, 240, 360, 720, 1440, intervalMinutes])).sorted()
    }
    private func intervalLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "Ash decides" }
        if minutes % 60 == 0 { return "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")" }
        return "\(minutes) minutes"
    }
    private var nextWakeAt: Date? {
        guard case .number(let timestamp) = runtime["nextAt"], timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    private var hasUnsavedChanges: Bool {
        guard runtime != .null else { return false }
        return enabled != runtime["config"]["enabled"].bool ||
            intervalMinutes != Int(runtime["config"]["intervalMinutes"].number) ||
            allowedTools != Set(runtime["permissions"]["tools"].array.map { $0.string }) ||
            allowedMessages != Set(runtime["permissions"]["messages"].array.map { $0.string })
    }
    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            VStack(spacing: 0) {
                WallpaperInlineHeader("Heartbeat") {
                    Button {
                        if let onOpenSidebar { onOpenSidebar() } else { dismiss() }
                    } label: {
                        Image(systemName: onOpenSidebar == nil ? "chevron.left" : "line.3.horizontal")
                            .frame(width: 44, height: 44)
                            .vesperMaterial(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(onOpenSidebar == nil ? "Back" : "Open chat sidebar")
                } trailing: {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                            .vesperMaterial(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy).accessibilityLabel("Refresh wake service")
                }
                wakeContent
            }
            .background { Background() }
            .toolbar(.hidden, for: .navigationBar)
            #else
            wakeContent
                .navigationTitle("Heartbeat").navigationBarTitleDisplayMode(.inline).wakePageAppearance()
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(busy).accessibilityLabel("Refresh wake service")
                } }
            #endif
        }
        .safeAreaInset(edge: .bottom) { if hasUnsavedChanges { saveBar } }
        .task {
            if runtime == .null { await load() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !busy else { continue }
                // Refresh scheduler data without overwriting unsaved permission switches.
                if let value = try? await store.api.request("/wake", history: true), !busy { runtime = value }
            }
        }.refreshable { await load() }
    }
    private var wakeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                if runtime != .null {
                    WakeGlassSection(title: "Status") { nextWakeRow.wakeGlassRow() }
                }
                WakeGlassSection(title: "Wake rhythm") {
                    Toggle("Automatic wake-up", isOn: $enabled)
                        .disabled(!supported || busy).wakeGlassRow()
                    Divider().padding(.horizontal, 18)
                    HStack {
                        Text("Frequency")
                        Spacer(minLength: 8)
                        Picker("Frequency", selection: $intervalMinutes) {
                            ForEach(intervalOptions, id: \.self) { minutes in
                                Text(intervalLabel(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).disabled(!supported || busy)
                        .accessibilityIdentifier("wake-interval")
                    }.wakeGlassRow()
                    Divider().padding(.horizontal, 18)
                    Text(intervalMinutes == 0
                         ? "Ash chooses when to wake. Quiet hours still apply."
                         : "This controls check-ins, not how often Ash sends a message.")
                        .font(.caption).foregroundStyle(VesperTheme.muted).wakeGlassRow()
                    Divider().padding(.horizontal, 18)
                    NavigationLink { WakeSleepView() } label: { wakeLinkLabel("Sleep time") }
                        .wakeGlassRow()
                }
                WakeGlassSection(title: "During a wake") {
                    Toggle("Background voice messages", isOn: Binding(
                        get: { backgroundVoiceOn },
                        set: { value in
                            backgroundVoiceOn = value
                            Task { await setBackgroundVoice(enabled: value) }
                        }
                    )).disabled(!supported || busy).wakeGlassRow()
                    Divider().padding(.horizontal, 18)
                    NavigationLink { permissionsPage } label: { wakeLinkLabel("Permissions") }
                        .disabled(!supported).wakeGlassRow()
                    Divider().padding(.horizontal, 18)
                    NavigationLink { WakePromptView() } label: { wakeLinkLabel("Wake prompt") }
                        .disabled(!supported).wakeGlassRow()
                }
                WakeGlassSection(title: "History") {
                    NavigationLink { WakeWorkflowView() } label: { wakeLinkLabel("Workflow") }
                        .wakeGlassRow()
                }
                if !supported {
                    SettingsGlassCard { Text("Refresh the service to check permission support. If unavailable, update the VPS wake service.").font(.caption) }
                }
                if !status.isEmpty {
                    SettingsGlassCard { Text(status).font(.caption).textSelection(.enabled) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 28)
        }
        .buttonStyle(.plain)
    }
    private func wakeLinkLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VesperTheme.muted)
        }
    }
    private var saveBar: some View {
        WakeSaveButton(title: busy ? "Saving…" : "Save changes", disabled: !supported || busy) {
            Task { await save() }
        }
    }
    private var nextWakeRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            HStack(alignment: .center, spacing: 12) {
                Text("Next wake")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if !runtime["config"]["enabled"].bool {
                        Text("Paused")
                    } else if recovery["paused"].bool {
                        Text(recovery["reason"].string == "quota" ? "Waiting for account quota" :
                             recovery["reason"].string == "authentication" ? "Login required" : "Paused after repeated failures")
                        if recovery["failureCount"].number > 0 {
                            Text("\(Int(recovery["failureCount"].number)) consecutive failures").font(.caption)
                        }
                        if recovery["retryAt"].number > 0 {
                            Text("Check again: " + Date(timeIntervalSince1970: recovery["retryAt"].number).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                        }
                    } else if let nextWakeAt {
                        if nextWakeAt > timeline.date {
                            Text(nextWakeAt, style: .relative)
                        } else {
                            Text("Waiting for scheduler")
                        }
                        Text(nextWakeAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    } else {
                        Text("No wake scheduled")
                    }
                }.foregroundStyle(VesperTheme.muted)
            }.accessibilityElement(children: .combine)
        }
    }
    private var permissionsPage: some View {
        List {
            NavigationLink {
                permissionPage(messages: true)
            } label: {
                HStack { Text("Message types"); Spacer(); Text("\(allowedMessages.count) enabled").foregroundStyle(VesperTheme.muted) }
            }.wakeListRow()
            NavigationLink {
                permissionPage(messages: false)
            } label: {
                HStack { Text("Allowed tools"); Spacer(); Text("\(allowedTools.count) enabled").foregroundStyle(VesperTheme.muted) }
            }.wakeListRow()
        }.disabled(busy).scrollContentBackground(.hidden)
            .navigationTitle("Permissions").navigationBarTitleDisplayMode(.inline)
            .wakeSubpageAppearance("Permissions")
            .safeAreaInset(edge: .bottom) { if hasUnsavedChanges { saveBar } }
    }
    private func permissionPage(messages: Bool) -> some View {
        List {
            Section {
                ForEach(runtime[messages ? "messageOptions" : "toolOptions"].array.map { $0.string }, id: \.self) { name in
                    Toggle(name.replacingOccurrences(of: "_", with: " ").capitalized, isOn: permission(name, messages: messages))
                }
            } footer: {
                Text(messages ? "Choose the kinds of messages \(store.agentDisplayName) may send." : "External MCP access stays read-only. Tool access does not authorize purchases, deletion or account changes.")
            }.wakeListRow()
        }.disabled(busy).scrollContentBackground(.hidden)
            .navigationTitle(messages ? "Message types" : "Allowed tools").navigationBarTitleDisplayMode(.inline)
            .wakeSubpageAppearance(messages ? "Message types" : "Allowed tools")
            .safeAreaInset(edge: .bottom) { if hasUnsavedChanges { saveBar } }
    }
    private func permission(_ name: String, messages: Bool) -> Binding<Bool> {
        Binding(get: { (messages ? allowedMessages : allowedTools).contains(name) }, set: { value in
            if messages { if value { allowedMessages.insert(name) } else { allowedMessages.remove(name) } }
            else { if value { allowedTools.insert(name) } else { allowedTools.remove(name) } }
        })
    }
    private func apply(_ value: JSONValue) {
        runtime = value; enabled = value["config"]["enabled"].bool
        backgroundVoiceOn = value["backgroundVoice"]["enabled"].bool
        intervalMinutes = Int(value["config"]["intervalMinutes"].number)
        allowedTools = Set(value["permissions"]["tools"].array.map { $0.string })
        allowedMessages = Set(value["permissions"]["messages"].array.map { $0.string })
    }
    private func setBackgroundVoice(enabled: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            var body: JSONValue = .object(["action": .string("backgroundVoice"), "enabled": .bool(enabled)])
            if enabled {
                let connection = VoiceConfiguration.normalized(VoiceConfiguration.connection(store))
                guard !connection["apiKey"].string.isEmpty, !connection["voiceId"].string.isEmpty else {
                    throw ServiceError(message: "Set up \(store.agentDisplayName)’s voice in Settings → Voice first.")
                }
                body["connection"] = connection
            }
            let result = try await store.api.request("/wake", method: "POST", body: body, history: true)
            guard result["backgroundVoice"]["enabled"].bool == enabled else {
                throw ServiceError(message: "The VPS did not confirm the background voice setting.")
            }
            runtime["backgroundVoice"] = result["backgroundVoice"]
            backgroundVoiceOn = enabled
            status = enabled ? "Background voice is ready on VPS." : "Background voice is off; its server copy was removed."
        } catch {
            backgroundVoiceOn = runtime["backgroundVoice"]["enabled"].bool
            status = error.localizedDescription
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { apply(try await store.api.request("/wake", history: true)); status = "" }
        catch { status = error.localizedDescription }
    }
    private func save() async {
        guard supported, !busy else { return }; busy = true; defer { busy = false }
        let interval: JSONValue = intervalMinutes == 0 ? .null : .number(Double(intervalMinutes))
        let permissions: JSONValue = .object(["tools": .array(allowedTools.sorted().map { .string($0) }), "messages": .array(allowedMessages.sorted().map { .string($0) })])
        let body: JSONValue = .object(["action": .string("configure"), "enabled": .bool(enabled), "intervalMinutes": interval, "permissions": permissions])
        do {
            let result = try await store.api.request("/wake", method: "POST", body: body, history: true)
            guard result["permissionVersion"].number >= 1, result["permissions"] == permissions,
                  result["config"]["enabled"].bool == enabled,
                  result["config"]["intervalMinutes"] == interval else {
                throw ServiceError(message: "The server did not confirm these wake settings.")
            }
            apply(result); status = "Saved. Wake interval and permissions are now active on the server."
        } catch { status = error.localizedDescription }
    }
}
struct WakeSleepView: View {
    @EnvironmentObject private var store: AppStore
    @State private var enabled = true
    @State private var dreamEnabled = true
    @State private var start = Self.date("00:00")
    @State private var end = Self.date("07:00")
    @State private var busy = false
    @State private var supported = false
    @State private var status = ""
    private static let zone = TimeZone(identifier: "Asia/Shanghai")!
    private static func date(_ value: String) -> Date {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: parts.first ?? 0, minute: parts.last ?? 0))!
    }
    private static func time(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
    var body: some View {
        Form {
            if busy { ProgressView("Loading sleep settings…").wakeListRow() }
            Section {
                Toggle("Sleep time", isOn: $enabled)
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute)
                Toggle("Save a dream after sleep", isOn: $dreamEnabled)
            } footer: {
                Text("Beijing time. Automatic activity and notifications stay silent during sleep. After sleep, one dream is saved to Collection → Dreams. Dreams are imagination, not factual memories.")
            }.disabled(!supported || busy).wakeListRow()
            if !status.isEmpty { Section { Text(status).font(.caption).textSelection(.enabled) }.wakeListRow() }
        }.scrollContentBackground(.hidden).environment(\.timeZone, Self.zone)
            .navigationTitle("Sleep time").navigationBarTitleDisplayMode(.inline)
            .wakeSubpageAppearance("Sleep time") {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .vesperMaterial(.ultraThinMaterial, in: Circle())
                    .buttonStyle(.plain)
                    .disabled(busy).accessibilityLabel("Reload sleep settings")
            }
            .safeAreaInset(edge: .bottom) {
                WakeSaveButton(title: busy ? "Saving…" : "Save sleep time", disabled: !supported || busy) { Task { await save() } }
            }.task { await load() }.refreshable { await load() }
    }
    private func load() async {
        guard !busy else { return }
        busy = true; status = ""; defer { busy = false }
        do {
            let value = try await store.api.request("/wake", history: true)
            supported = value["sleepVersion"].number >= 1
            guard supported else {
                status = "This history service does not support sleep settings yet. Update it, then tap Reload."
                return
            }
            let setting = value["config"]["sleep"]
            enabled = setting["enabled"].bool; dreamEnabled = setting["dreamEnabled"].bool
            start = Self.date(setting["start"].string); end = Self.date(setting["end"].string)
        } catch {
            if !Task.isCancelled { status = error.localizedDescription + " Tap Reload to try again." }
        }
    }
    private func save() async {
        guard !busy, supported else { return }
        guard Self.time(start) != Self.time(end) else { status = "Choose different start and end times."; return }
        busy = true; defer { busy = false }
        let setting: JSONValue = .object(["enabled": .bool(enabled), "dreamEnabled": .bool(dreamEnabled),
            "start": .string(Self.time(start)), "end": .string(Self.time(end)), "timeZone": .string(Self.zone.identifier)])
        do {
            // Preserve the latest main switch/interval, including changes from another device.
            let latest = try await store.api.request("/wake", history: true)
            let body: JSONValue = .object(["action": .string("configure"), "enabled": latest["config"]["enabled"],
                "intervalMinutes": latest["config"]["intervalMinutes"], "sleep": setting])
            let saved = try await store.api.request("/wake", method: "POST", body: body, history: true)
            let reread = try await store.api.request("/wake", history: true)
            guard saved["config"]["sleep"] == setting, reread["config"]["sleep"] == setting else {
                throw ServiceError(message: "The service did not retain the sleep settings.")
            }
            status = "Saved and verified. Applies to the existing VPS scheduler."
        } catch { status = error.localizedDescription }
    }
}

struct AgentInstructionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var document: SharedAgentInstructions?
    @State private var loadedClient: APIClient?
    @State private var draft = ""
    @State private var busy = false
    @State private var status = ""
    @State private var confirmDiscard = false
    @State private var reloadAfterDiscard = false

    private var edited: Bool { document != nil && draft != document?.content }
    private var valid: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 24000
            && !draft.contains("<vesper_shared_agent_instructions>")
            && !draft.contains("</vesper_shared_agent_instructions>")
    }
    private func matches(_ client: APIClient) -> Bool {
        store.activeBackend == .vps && store.api.historyURL == client.historyURL
            && store.api.baseURL == client.baseURL && store.api.token == client.token
    }
    var body: some View {
        List {
            Section {
                Text("Ash 的共同指令：身份、相处方式和连续性要求。聊天、通话和后台活动共用 VPS 上的这一份文件。")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
            }
            if document != nil {
                Section {
                    TextEditor(text: $draft)
                        .font(.system(size: 15)).scrollContentBackground(.hidden)
                        .frame(minHeight: 420).disabled(busy)
                        .accessibilityLabel("AGENTS.md editor")
                    Text("\(draft.utf8.count) / 24,000 bytes")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                } header: { Text("AGENTS.md") } footer: {
                    Text("保存后从下一次回复或后台活动开始使用。当前正在进行的回复不变；联系人、项目和场景的补充指令仍会一起使用。")
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.subheadline).textSelection(.enabled) }
            }
            Section {
                Button(busy ? "Please wait…" : "Reload") {
                    if edited { reloadAfterDiscard = true; confirmDiscard = true }
                    else { Task { await load() } }
                }.disabled(busy || store.activeBackend != .vps)
            }
        }
        .scrollContentBackground(.hidden).background { Background() }
        .foregroundStyle(VesperTheme.ink)
        .navigationTitle("Agent Instructions").navigationBarTitleDisplayMode(.inline)
        .transparentNavigationTop().navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if edited { reloadAfterDiscard = false; confirmDiscard = true } else { dismiss() } } label: {
                    Label("Back", systemImage: "chevron.left")
                }.disabled(busy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            WakeSaveButton(title: busy ? "Please wait…" : "Save", disabled: busy || !edited || !valid || loadedClient.map { !matches($0) } != false) {
                Task { await save() }
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(reloadAfterDiscard ? "Discard & reload" : "Discard & leave", role: .destructive) {
                if reloadAfterDiscard { Task { await load() } } else { dismiss() }
            }
            Button("Keep editing", role: .cancel) {}
        }
        .task { if document == nil { await load() } }
    }
    private func load() async {
        guard !busy else { return }
        guard store.activeBackend == .vps else {
            status = "请先连接 VPS，再编辑共同指令。"; return
        }
        busy = true; defer { busy = false }
        let client = store.api
        do {
            let value = try SharedAgentInstructions(await client.request("/agent-instructions", history: true))
            guard matches(client) else { status = "连接已切换，请重新加载。"; return }
            document = value; loadedClient = client; draft = value.content; status = ""
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard !busy, valid, let document, let client = loadedClient, matches(client) else { return }
        busy = true; defer { busy = false }
        do {
            let value = try SharedAgentInstructions(await client.request("/agent-instructions", method: "POST", body: .object([
                "content": .string(draft), "revision": .string(document.revision)
            ]), history: true))
            guard matches(client) else { status = "已保存到原 VPS；连接已切换，请重新加载。"; return }
            self.document = value; draft = value.content
            status = "已保存到 VPS，下一次回复或后台活动开始使用。"
        } catch let error as ServiceError where error.statusCode == 409 {
            status = "文件已在别处更新，你的草稿仍保留在这里。请先复制要保留的文字，再点 Reload 读取最新版本。"
        } catch { status = "保存未确认，草稿已保留。\n" + error.localizedDescription }
    }
}

struct WakePromptView: View {
    @EnvironmentObject private var store: AppStore
    @State private var runtime: JSONValue = .null
    @State private var prompt = ""
    @State private var currentRules = ""
    @State private var limit = 8000
    @State private var supported = false
    @State private var busy = false
    @State private var status = ""
    var body: some View {
        List {
            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Additional wake instructions")
                Text("\(prompt.count) / \(limit) characters")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
                DisclosureGroup("共同运行规则") {
                    Text(currentRules).font(.subheadline).textSelection(.enabled)
                }
            } header: {
                Text("我的提示")
            } footer: {
                Text("在这里填写你的补充要求，保存后会加到共同运行规则中。清空并保存即可移除补充要求；唤醒间隔和权限仍在对应页面设置。")
            }.wakeListRow()
            if runtime != .null { selfPromptSection }
            if !status.isEmpty { Section { Text(status).font(.caption).textSelection(.enabled) }.wakeListRow() }
        }.scrollContentBackground(.hidden)
            .navigationTitle("Wake prompt").navigationBarTitleDisplayMode(.inline)
            .wakeSubpageAppearance("Wake prompt")
            .safeAreaInset(edge: .bottom) {
                WakeSaveButton(title: busy ? "Saving…" : "Save prompt", disabled: !supported || busy || prompt.count > limit) {
                    Task { await save() }
                }
            }
            .task {
                await load()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard !busy else { continue }
                    // Keep Rowan's saved prompt fresh without replacing the user's unsaved edits.
                    if let value = try? await store.api.request("/wake", history: true), !busy {
                        runtime = value
                        currentRules = value["defaultPrompt"].string
                    }
                }
            }
    }
    private var selfPromptSection: some View {
        Section {
            if runtime["selfPrompt"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(runtime["planningVersion"].number >= 1 ? "他还没有保存自写提示。" : "当前服务尚未提供自写提示。")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
            } else {
                Text(runtime["selfPrompt"].string)
                    .font(.subheadline).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("wake-self-prompt-text")
                if case .number(let timestamp) = runtime["selfPromptUpdatedAt"], timestamp.isFinite, timestamp > 0 {
                    Text("更新于 " + Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                }
            }
        } header: {
            Text("\(store.agentDisplayName) 的提示")
        } footer: {
            Text("由 \(store.agentDisplayName) 自己保存，每轮醒来时作为参考。")
        }.wakeListRow()
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let value = try await store.api.request("/wake", history: true)
            runtime = value
            supported = value["promptMode"].string == "append"
            currentRules = value["defaultPrompt"].string
            limit = max(1, Int(value["promptMaxLength"].number))
            prompt = value["promptAddendum"].string
            status = supported ? "" : "Update the VPS wake service to edit the prompt."
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard supported, !busy, prompt.count <= limit else { return }
        busy = true; defer { busy = false }
        let requested = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await store.api.request("/wake", method: "POST", body: .object(["action": .string("prompt"), "prompt": .string(requested)]), history: true)
            guard result["promptMode"].string == "append", result["promptAddendum"].string == requested else {
                throw ServiceError(message: "The VPS did not confirm the prompt change.")
            }
            currentRules = result["defaultPrompt"].string
            runtime = result
            prompt = requested
            status = "Saved on the VPS. The next wake will use these instructions."
        } catch { status = error.localizedDescription }
    }
}
private struct WakeSaveButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VesperTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 56)
                .vesperMaterial(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}
enum WakeWorkflowPresentation {
    static func status(_ value: String) -> String {
        ["running": "进行中", "queued": "等待开始", "saved": "发送中", "success": "完成", "completed": "完成", "partial_failure": "部分未完成", "push_failed": "推送未送达", "failure": "失败", "failed": "失败", "interrupted": "已中止", "cancelled": "已取消", "silent": "保持安静", "skipped": "已跳过", "request_accepted": "请求已受理", "unknown": "尚未确认", "pending": "等待处理"][value] ?? value
    }
    static func time(_ value: Double) -> String {
        value > 0 ? Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened) : ""
    }
    static func symbol(_ value: String) -> String {
        switch value {
        case "success", "completed", "done": "checkmark.circle.fill"
        case "failure", "failed", "partial_failure", "push_failed": "xmark.circle.fill"
        case "running", "saved": "arrow.triangle.2.circlepath.circle.fill"
        case "queued", "pending", "started", "unknown": "clock.fill"
        case "silent", "skipped": "moon.circle.fill"
        default: "minus.circle.fill"
        }
    }
    static func color(_ value: String) -> Color {
        switch value {
        case "success", "completed", "done": .green
        case "failure", "failed", "partial_failure", "push_failed": .red
        case "running", "saved": .blue
        case "queued", "pending", "started", "unknown": .orange
        default: VesperTheme.muted
        }
    }
    static func duration(_ start: Double, _ end: Double) -> String {
        guard start > 0, end >= start else { return "" }
        let seconds = Int(end - start)
        return seconds >= 3600 ? "\(seconds / 3600)h \((seconds % 3600) / 60)m"
            : seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
    static func trigger(_ source: String) -> String {
        ["automation": "定时唤醒", "manual": "手动触发", "verification": "运行检查", "letter-reminder": "拆信提醒", "morning-dream": "晨间梦" ][source] ?? "自动运行"
    }
}

struct WakeWorkflowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    @State private var jobs: [JSONValue] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var error = ""
    @State private var filter = "全部"
    private var visibleJobs: [JSONValue] {
        jobs.filter { job in
            let result = job["outcome"].string.isEmpty ? job["status"].string : job["outcome"].string
            switch filter {
            case "进行中": return ["running", "queued", "saved"].contains(result)
            case "失败": return ["failure", "failed", "partial_failure", "interrupted"].contains(result)
            case "安静": return ["silent", "skipped"].contains(job["status"].string)
            default: return true
            }
        }
    }
    var body: some View {
        Page(title: "Workflow", subtitle: "\(store.agentDisplayName) 的运行记录", showsTitle: false) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(["全部", "进行中", "失败", "安静"], id: \.self) { option in
                        Button { filter = option } label: {
                            Text(option).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 15).padding(.vertical, 8)
                                .background(filter == option ? VesperTheme.ink.opacity(0.13) : VesperTheme.ink.opacity(0.05), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("运行记录 · 已加载 \(jobs.count) 次")
                .font(.caption.weight(.medium)).foregroundStyle(VesperTheme.muted)
            if jobs.isEmpty && !loading && error.isEmpty { EmptyCard(title: "暂时没有记录", message: "下一次醒来后，真实活动和静默原因会留在这里。") }
            if visibleJobs.isEmpty && !jobs.isEmpty && !loading { Text("当前筛选没有记录").font(.subheadline).foregroundStyle(VesperTheme.muted) }
            ForEach(visibleJobs) { job in
                NavigationLink { WakeRunDetail(job: job) } label: {
                    GlassCard { HStack(alignment: .top, spacing: 13) {
                        let outcome = job["outcome"].string.isEmpty ? job["status"].string : job["outcome"].string
                        Image(systemName: WakeWorkflowPresentation.symbol(outcome))
                            .font(.title3).foregroundStyle(WakeWorkflowPresentation.color(outcome)).frame(width: 25)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(job["title"].string.isEmpty ? "自唤醒" : job["title"].string)
                                    .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VesperTheme.muted)
                            }
                            Text(job["summary"].string).font(.subheadline).lineLimit(2)
                            HStack(spacing: 7) {
                                Text(WakeWorkflowPresentation.trigger(job["source"].string))
                                Text("·")
                                Text(WakeWorkflowPresentation.time(job["created"].number))
                                let duration = WakeWorkflowPresentation.duration(job["started"].number, job["finished"].number)
                                if !duration.isEmpty { Text("·"); Text(duration) }
                            }.font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                    } }
                }.buttonStyle(.plain)
            }
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption); Button("重试") { Task { await load(reset: true) } } }
            if nextOffset != nil { Button("更早的记录") { Task { await load(reset: false) } }.disabled(loading) }
        }.wakeSubpageAppearance("Workflow")
        .task { await load(reset: true) }.refreshable { await load(reset: true) }
        .onChange(of: phase) { _, value in if value == .active { Task { await load(reset: true) } } }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let value = try await store.api.request("/wake?view=workflow&limit=20&offset=\(reset ? 0 : nextOffset ?? 0)", history: true)
            var seen = Set<String>()
            jobs = ((reset ? [] : jobs) + value["jobs"].array).filter { seen.insert($0.id).inserted }
            if case .number(let number) = value["nextOffset"] { nextOffset = Int(number) } else { nextOffset = nil }
            error = ""
        } catch { self.error = error.localizedDescription }
    }
}

struct WakeRunDetail: View {
    let job: JSONValue
    @EnvironmentObject private var store: AppStore
    @State private var updated: JSONValue = .null
    private var record: JSONValue { updated == .null ? job : updated }
    private var outcome: String { record["outcome"].string.isEmpty ? record["status"].string : record["outcome"].string }
    var body: some View {
        Page(title: "Workflow", subtitle: record["title"].string, showsTitle: false) {
            GlassCard { VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: WakeWorkflowPresentation.symbol(outcome))
                        .font(.title2).foregroundStyle(WakeWorkflowPresentation.color(outcome))
                    Text(WakeWorkflowPresentation.status(outcome)).font(.headline)
                    Spacer()
                    Text("#" + String(record.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(VesperTheme.muted)
                }
                Text(record["title"].string.isEmpty ? "自唤醒" : record["title"].string)
                    .font(.title3.weight(.semibold))
                Text(record["summary"].string).font(.subheadline).textSelection(.enabled)
                HStack(spacing: 7) {
                    Text(WakeWorkflowPresentation.trigger(record["source"].string))
                    Text("·")
                    Text(WakeWorkflowPresentation.time(record["created"].number))
                    let duration = WakeWorkflowPresentation.duration(record["started"].number, record["finished"].number)
                    if !duration.isEmpty { Text("·"); Text(duration) }
                }.font(.caption).foregroundStyle(VesperTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            Text("运行流程").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            GlassCard { VStack(alignment: .leading, spacing: 0) {
                WakeWorkflowNode(title: "开始", detail: WakeWorkflowPresentation.trigger(record["source"].string),
                                 status: "completed", last: false)
                ForEach(Array(record["calls"].array.enumerated()), id: \.offset) { index, call in
                    WakeWorkflowNode(title: call["action"].string.isEmpty ? call["name"].string : call["action"].string,
                                     detail: call["result"].string, status: call["completion"].string,
                                     last: false, time: call["started"].number,
                                     duration: WakeWorkflowPresentation.duration(call["started"].number, call["finished"].number),
                                     name: call["name"].string, references: call["references"].array)
                }
                WakeWorkflowNode(title: ["failure", "failed", "partial_failure"].contains(outcome) ? "结束 · 未完成" : record["notification"].string.isEmpty ? "结束 · 保持安静" : "结束 · 已发送消息",
                                 detail: record["notification"].string.isEmpty ? record["silentReason"].string : record["notification"].string,
                                 status: outcome, last: true, time: record["finished"].number)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            DisclosureGroup("Token usage") {
                if record["tokenUsage"] != .null {
                    ChatTokenUsageDetails(value: record["tokenUsage"], title: "Wake usage")
                } else {
                    Text("\(Int(record["tokens"].number).formatted()) tokens · Cache unavailable").font(.caption)
                }
                Text(record.id).font(.caption2).foregroundStyle(VesperTheme.muted).textSelection(.enabled)
            }
        }.wakeSubpageAppearance("Workflow").task {
            var components = URLComponents()
            components.path = "/wake"
            components.queryItems = [URLQueryItem(name: "view", value: "workflow"), URLQueryItem(name: "id", value: job.id)]
            guard let path = components.string else { return }
            repeat {
                if let value = try? await store.api.request(path, history: true) { updated = value["job"] }
                guard ["running", "queued", "saved"].contains(record["status"].string) else { return }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

private struct WakeWorkflowNode: View {
    let title: String
    let detail: String
    let status: String
    let last: Bool
    var time: Double = 0
    var duration: String = ""
    var name: String = ""
    var references: [JSONValue] = []
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Image(systemName: WakeWorkflowPresentation.symbol(status))
                    .font(.system(size: 18)).foregroundStyle(WakeWorkflowPresentation.color(status))
                    .frame(width: 23, height: 23)
                if !last { Rectangle().fill(VesperTheme.muted.opacity(0.35)).frame(width: 1, height: 56) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text(title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(WakeWorkflowPresentation.status(status)).font(.caption).foregroundStyle(WakeWorkflowPresentation.color(status))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(VesperTheme.muted)
                    }
                }.buttonStyle(.plain)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(expanded ? nil : 2).textSelection(.enabled) }
                if expanded {
                    if time > 0 { Text(WakeWorkflowPresentation.time(time) + (duration.isEmpty ? "" : " · " + duration)).font(.caption2).foregroundStyle(VesperTheme.muted) }
                    if !name.isEmpty { Text(name).font(.caption2.monospaced()).foregroundStyle(VesperTheme.muted).textSelection(.enabled) }
                    ForEach(references) { reference in
                        if reference["kind"].string == "bookmarks" { NavigationLink("查看书签") { BookmarksView() } }
                    }
                }
            }.padding(.bottom, last ? 0 : 15)
        }
    }
}

struct AgentSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("nativeInstructions") private var instructions: String?
    var body: some View {
        Page(title: "Agent", showsTitle: false) {
            GlassCard { VStack(alignment: .leading, spacing: 12) { FormField(label: "\(store.agentDisplayName) instructions", text: Binding(get: { store.resolvedAgentInstructions(instructions) }, set: { instructions = $0 }), multiline: true); Text("Saved on this device for \(store.agentDisplayName) conversations, including existing ones. Edit your chat preferences with the document button on Chat.").font(.caption).foregroundStyle(VesperTheme.muted) } }
            EmptyCard(title: "Models", message: "Choose an available model from the model picker inside a connected chat.")
        }
    }
}
struct DataSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var exportURL: URL?
    @State private var status = ""
    @State private var resolving: String?
    var body: some View {
        Page(title: "Data", subtitle: "Saved on this device, synced across your Vesper devices.", showsTitle: false) {
            SettingsGlassCard { VStack(alignment: .leading, spacing: 12) {
                Label("Local storage", systemImage: "internaldrive").font(.headline)
                Text(store.hasLocalData ? "Your saved documents are ready to open without waiting for the cloud." : "Connect once to download your documents onto this device.").font(.subheadline)
                if store.syncing { ProgressView("Syncing changes…") }
                Text(store.pendingDocuments.isEmpty ? "No pending changes" : "\(store.pendingDocuments.count) document(s) saved locally, waiting to sync")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
                if let date = store.lastSyncedAt { Text("Last sync: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(VesperTheme.muted) }
                if let error = store.syncError { Text(error).font(.caption) }
                ForEach(store.conflictingDocuments.sorted(), id: \.self) { key in
                    Button("Resolve changes in \(key.capitalized)") { resolving = key }
                }
                Button("Sync now") { Task { await store.refresh(); await store.syncPendingDocuments() } }
                    .disabled(store.loading || store.syncing || store.token.isEmpty)
                Text("New AI replies and files that have not been downloaded still need a connection.").font(.caption).foregroundStyle(VesperTheme.muted)
            }}
            SettingsGlassCard { VStack(alignment: .leading, spacing: 16) {
                Text("Device credentials are stored in the iOS Keychain. This app does not copy web browser credentials automatically.").font(.subheadline)
                Button("Prepare document export") {
                    do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vesper-documents.json"); try JSONEncoder.pretty.encode(JSONValue.object(store.documents)).write(to: url, options: [.atomic, .completeFileProtection]); exportURL = url }
                    catch { status = error.localizedDescription }
                }.disabled(!store.canEnter)
                if let exportURL { ShareLink("Share export", item: exportURL) }
                Text("Export includes this device’s documents and pending edits. Chat history, media files and server memory are not included.").font(.caption).foregroundStyle(VesperTheme.muted)
                if !status.isEmpty { Text(status).font(.caption) }
            }}
        }.background { Background() }.transparentNavigationTop()
        .confirmationDialog("Choose which changes to keep in \(resolving?.capitalized ?? "this document")", isPresented: Binding(get: { resolving != nil }, set: { if !$0 { resolving = nil } })) {
            if let key = resolving {
                Button("Keep this device’s edits") { Task { await store.resolvePendingDocument(key, keepLocal: true) }; resolving = nil }
                Button("Use cloud version", role: .destructive) { Task { await store.resolvePendingDocument(key, keepLocal: false) }; resolving = nil }
            }
        }
    }
}

enum VoiceConfiguration {
    static func normalized(_ original: JSONValue) -> JSONValue {
        var value = original
        guard var url = URLComponents(string: original["baseUrl"].string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else { return value }
        let isMini = original["provider"].string.lowercased().contains("minimax") || (url.host ?? "").contains("minimax")
        if isMini && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("t2a_v2") {
            let group = original["groupId"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty, !(url.queryItems ?? []).contains(where: { $0.name == "GroupId" }) { url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "GroupId", value: group)] }
            value["endpoint"] = .string(url.string ?? "")
            url.path = ""; url.query = nil; url.fragment = nil
            value["baseUrl"] = .string(url.string ?? original["baseUrl"].string)
        }
        return value
    }
    static func failure(_ data: Data, response: URLResponse, connection: JSONValue) -> String {
        let payload = try? JSONDecoder().decode(JSONValue.self, from: data)
        var detail = payload?["error"].string ?? ""
        if detail.isEmpty { detail = "Voice service request failed" }
        let key = connection["apiKey"].string
        if !key.isEmpty { detail = detail.replacingOccurrences(of: key, with: "[redacted]") }
        return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): " + String(detail.prefix(350))
    }
    @MainActor static func connection(_ store: AppStore) -> JSONValue {
        let saved = CredentialStore.read(account: "call-voice-configuration")
        if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(saved.utf8)) { return value }
        return store.document("connections")["Agent 声音"]
    }
}
struct VoiceSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var preview = CallVoice()
    @State private var provider = "ElevenLabs"
    @State private var baseURL = "https://api.elevenlabs.io"
    @State private var apiKey = ""
    @State private var voiceID = ""
    @State private var model = "eleven_multilingual_v2"
    @State private var groupID = ""
    @State private var speed = 1.0
    @State private var status = ""
    private var configuration: JSONValue { .object(["provider": .string(provider), "baseUrl": .string(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), "apiKey": .string(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)), "voiceId": .string(voiceID.trimmingCharacters(in: .whitespacesAndNewlines)), "model": .string(model), "groupId": .string(groupID), "speed": .string(String(speed))]) }
    var body: some View {
        Page(title: "Voice", subtitle: "\(store.agentDisplayName)’s voice in audio and video calls.", showsTitle: false) {
            SettingsGlassCard { VStack(alignment: .leading, spacing: 16) {
                Picker("Provider", selection: Binding(get: { provider }, set: { value in provider = value; baseURL = value == "ElevenLabs" ? "https://api.elevenlabs.io" : "https://api.minimax.chat"; model = value == "ElevenLabs" ? "eleven_multilingual_v2" : "speech-2.6-hd"; voiceID = ""; apiKey = ""; groupID = "" })) { Text("ElevenLabs").tag("ElevenLabs"); Text("MiniMax").tag("MiniMax") }
                FormField(label: "API address", text: $baseURL)
                Text("API key").font(.caption)
                SecureField("API key", text: $apiKey).foregroundStyle(VesperTheme.ink).padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 12))
                FormField(label: "Voice ID", text: $voiceID)
                FormField(label: "Model", text: $model)
                if provider == "MiniMax" { FormField(label: "Group ID (optional)", text: $groupID) }
                HStack { Text("Speed"); Slider(value: $speed, in: 0.7...1.2, step: 0.05); Text(String(format: "%.2f×", speed)).font(.caption) }
                Button("Save voice") { save() }.buttonStyle(.bordered)
                Button(preview.speaking ? "Stop preview" : "Preview voice") { if preview.speaking { preview.stop() } else if validate() { Task { await preview.play("宝贝，我在这里。", store: store, connectionOverride: configuration) } } }.buttonStyle(.bordered)
                Text("Saved in this device’s Keychain and used for call replies. Preview uses your provider’s credits.").font(.caption).foregroundStyle(VesperTheme.muted)
                if !status.isEmpty { Text(status).font(.caption) }
                if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled() }
        }.background { Background() }.transparentNavigationTop().onAppear {
            let saved = VoiceConfiguration.connection(store)
            if !saved["provider"].string.isEmpty { provider = saved["provider"].string }
            if !saved["baseUrl"].string.isEmpty { baseURL = saved["baseUrl"].string }
            apiKey = saved["apiKey"].string; voiceID = saved["voiceId"].string; groupID = saved["groupId"].string
            if !saved["model"].string.isEmpty { model = saved["model"].string }
            speed = min(1.2, max(0.7, Double(saved["speed"].string) ?? 1))
        }.onDisappear { preview.stop() }
    }
    private func validate() -> Bool {
        do { _ = try APIClient.validatedURL(baseURL, path: "") } catch { status = error.localizedDescription; return false }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter an API key and Voice ID."; return false }
        status = ""; return true
    }
    private func save() {
        guard validate() else { return }
        do {
            let selected = VoiceConfiguration.normalized(configuration)
            let data = try JSONEncoder().encode(selected)
            try CredentialStore.save(String(decoding: data, as: UTF8.self), account: "call-voice-configuration")
            status = "Saved. New call replies use this voice."
            if store.activeBackend == .vps {
                Task {
                    do {
                        let wake = try await store.api.request("/wake", history: true)
                        guard wake["backgroundVoice"]["enabled"].bool else { return }
                        let updated = try await store.api.request("/wake", method: "POST", body: .object([
                            "action": .string("backgroundVoice"), "enabled": .bool(true), "connection": selected
                        ]), history: true)
                        guard updated["backgroundVoice"]["enabled"].bool else {
                            throw ServiceError(message: "VPS did not confirm the new background voice.")
                        }
                        status = "Saved for calls and background voice messages."
                    } catch { status = "Voice saved on this device. Background voice update failed: " + error.localizedDescription }
                }
            }
        }
        catch { status = error.localizedDescription }
    }
}

struct ToolsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [JSONValue] = []
    @State private var status = ""
    @State private var query = ""
    @State private var editing: JSONValue?
    private var filteredItems: [JSONValue] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return items }
        return items.filter { item in
            item["name"].string.localizedCaseInsensitiveContains(search)
                || item["url"].string.localizedCaseInsensitiveContains(search)
                || item["tools"].array.contains {
                    $0["name"].string.localizedCaseInsensitiveContains(search)
                        || $0["description"].string.localizedCaseInsensitiveContains(search)
                }
        }
    }
    var body: some View {
        Page(title: "MCP", subtitle: "Connected services and the tools \(store.agentDisplayName) can use.", showsTitle: false) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connections").font(.title3.weight(.semibold))
                    Text("\(items.count) added").font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Spacer()
                NavigationLink { VesperConnectorView() } label: {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(VesperTheme.ink)
                        .frame(width: 44, height: 44)
                        .vesperGlass(in: Circle(), interactive: true)
                }.buttonStyle(.plain).accessibilityLabel("Connect \(store.agentDisplayName) to Vesper")
                Button {
                    editing = .object(["id": .string(UUID().uuidString), "enabled": .bool(true), "authMode": .string("none")])
                } label: { Label("Add", systemImage: "plus").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.bordered).accessibilityLabel("Add MCP server")
            }
            if !items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
                    TextField("Search connections or tools", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.padding(.horizontal, 15).frame(minHeight: 46)
                    .vesperGlass(in: RoundedRectangle(cornerRadius: 16))
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
            ForEach(filteredItems) { item in
                McpConnectionCard(item: item) { editing = item }
            }
            if items.isEmpty { Text("Add an MCP server to see its tools here.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
            else if filteredItems.isEmpty { Text("No matching connections or tools.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
        }.background { Background() }.transparentNavigationTop()
            .task { await load() }.refreshable { await load() }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { item in McpEditor(item: item, existing: items.contains { $0.id == item.id }) }
    }
    private func load() async {
        do { let result = try await store.api.request("/api/mcp/connections"); items = result["connections"].array; status = "" }
        catch { status = error.localizedDescription }
    }
}

private struct McpConnectionCard: View {
    let item: JSONValue
    let edit: () -> Void
    @State private var showsTools = false
    private var tools: [JSONValue] { item["tools"].array }
    private var host: String { URLComponents(string: item["url"].string)?.host ?? item["url"].string }
    private var connectionStatus: String {
        if !item["enabled"].bool { return "Off" }
        if item["authMode"].string != "none" && !item["authorized"].bool { return "Needs access" }
        return "Connected"
    }
    var body: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 45, height: 45)
                        .vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item["name"].string).font(.headline).lineLimit(2)
                        Text(host).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button(action: edit) { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                        .buttonStyle(.plain).accessibilityLabel("Edit \(item["name"].string) connection")
                }
                HStack(spacing: 8) {
                    Circle().fill(item["enabled"].bool ? VesperTheme.ink : VesperTheme.muted)
                        .frame(width: 6, height: 6)
                    Text(connectionStatus)
                    Text("·")
                    Text("\(tools.count) tools")
                    Spacer()
                    Text(item["authMode"].string.uppercased()).font(.caption2.weight(.medium))
                }.font(.caption).foregroundStyle(VesperTheme.muted)
                Divider()
                Button { withAnimation(.easeInOut(duration: 0.18)) { showsTools.toggle() } } label: {
                    HStack {
                        Text("Tools").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: showsTools ? "chevron.up" : "chevron.down").font(.caption)
                    }.frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(showsTools ? "Expanded" : "Collapsed")
                if showsTools {
                    if tools.isEmpty {
                        Text("No tools found. Open settings to test this connection again.")
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                                if index > 0 { Divider().padding(.vertical, 12) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tool["name"].string)
                                        .font(.system(size: 13, weight: .semibold))
                                        .textSelection(.enabled)
                                    if !tool["description"].string.isEmpty {
                                        Text(tool["description"].string).font(.caption)
                                            .foregroundStyle(VesperTheme.muted).fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct McpEditor: View {
    let item: JSONValue
    let existing: Bool
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var auth = "none"
    @State private var token = ""
    @State private var enabled = true
    @State private var busy = false
    @State private var status = ""
    @State private var deleting = false
    @StateObject private var oauth = McpOAuthSession()
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("HTTPS MCP URL", text: $url).keyboardType(.URL)
                Toggle("Enabled", isOn: $enabled)
                Picker("Authentication", selection: $auth) { Text("None").tag("none"); Text("Bearer token").tag("bearer"); Text("OAuth").tag("oauth") }
                if auth == "bearer" { SecureField(existing ? "Token (blank keeps saved token)" : "Access token", text: $token) }
                if auth == "oauth" {
                    Text("Connect to open the service’s authorization page. After approval, Vesper will test and save the connection automatically.").font(.caption)
                    Button("Connect & authorize") { Task { await save(authorize: true) } }.disabled(busy)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
                if existing { Section { Button("Remove server", role: .destructive) { deleting = true }.disabled(busy) } }
            }.disabled(busy).textInputAutocapitalization(.never).autocorrectionDisabled().scrollContentBackground(.hidden).background { Background() }
                .navigationTitle(existing ? "Edit MCP" : "Add MCP").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "Connecting…" : (auth == "oauth" && !item["authorized"].bool ? "Connect & authorize" : "Save & test")) { Task { await save() } }.disabled(busy) }
                }
                .confirmationDialog("Remove this MCP connection?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { Task { await remove() } }
                }
        }.onAppear { name = item["name"].string; url = item["url"].string; auth = item["authMode"].string; enabled = item["enabled"].bool }
            .interactiveDismissDisabled(busy)
    }
    @MainActor private func save(authorize: Bool = false) async {
        guard !busy else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter a name."; return }
        do { _ = try APIClient.validatedURL(url, path: "") } catch { status = error.localizedDescription; return }
        if existing, url.trimmingCharacters(in: .whitespacesAndNewlines) != item["url"].string, auth == "bearer", token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { status = "Enter credentials for the new URL before saving."; return }
        busy = true; status = ""; defer { busy = false }
        if auth == "oauth", authorize || !item["authorized"].bool || item["authMode"].string != "oauth" || url.trimmingCharacters(in: .whitespacesAndNewlines) != item["url"].string {
            do { token = try await oauth.authorize(api: store.api, resource: url.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { status = error.localizedDescription; return }
        }
        var body: JSONValue = .object(["id": .string(item.id), "name": .string(name), "url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines)), "enabled": .bool(enabled), "authMode": .string(auth)])
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["token"] = .string(token.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if auth == "none" { body["clearToken"] = .bool(true) }
        do { let result = try await store.api.request("/api/mcp/connections", method: "PUT", body: body); guard result["connection"].id == item.id else { throw ServiceError(message: "The server did not confirm this connection.") }; dismiss() }
        catch { status = error.localizedDescription }
    }
    private func remove() async {
        busy = true; defer { busy = false }
        guard let id = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        do { _ = try await store.api.request("/api/mcp/connections?id=\(id)", method: "DELETE"); dismiss() }
        catch { status = error.localizedDescription }
    }
}


@MainActor
private final class McpOAuthSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // authorize() requires a live window and retains it for this session.
        // Do not construct a detached window that cannot present authentication.
        guard let anchor else { preconditionFailure("OAuth presentation requested outside an active session") }
        return anchor
    }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ServiceError(message: "Could not start a secure authorization session.")
        }
        return base64URL(Data(bytes))
    }
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func authorize(api: APIClient, resource: String) async throws -> String {
        let redirect = try APIClient.validatedURL(api.baseURL, path: "/mcp/oauth/callback?native=1").absoluteString
        let metadata = try await api.request("/api/mcp/oauth/discover", method: "POST", body: .object([
            "url": .string(resource), "redirectUri": .string(redirect)
        ]))
        guard !metadata["clientId"].string.isEmpty else {
            throw ServiceError(message: "This service requires a registered OAuth client ID. Automatic registration is unavailable.")
        }
        let verifier = try randomValue()
        let state = try randomValue()
        guard var authorization = URLComponents(string: metadata["authorizationUrl"].string),
              authorization.scheme == "https", authorization.host != nil,
              authorization.user == nil, authorization.password == nil else {
            throw ServiceError(message: "The service returned an invalid authorization address.")
        }
        let values = ["response_type": "code", "client_id": metadata["clientId"].string,
                      "redirect_uri": redirect, "state": state, "code_challenge_method": "S256",
                      "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
                      "scope": metadata["scopes"].string, "resource": metadata["resource"].string]
        authorization.queryItems = (authorization.queryItems ?? []).filter { values[$0.name] == nil }
            + values.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let address = authorization.url else { throw ServiceError(message: "Invalid authorization address.") }
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.first { $0.isKeyWindow }
        guard anchor != nil else { throw ServiceError(message: "Open Vesper before connecting this service.") }
        defer { session = nil; anchor = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let browser = ASWebAuthenticationSession(url: address, callbackURLScheme: "vesper") { url, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: ServiceError(message: "Authorization cancelled. Your entries are still here."))
                    } else { continuation.resume(throwing: error) }
                } else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: ServiceError(message: "Authorization returned no result.")) }
            }
            browser.presentationContextProvider = self
            self.session = browser
            if !browser.start() { continuation.resume(throwing: ServiceError(message: "Could not open the authorization window.")) }
        }
        guard callback.scheme == "vesper", callback.host == "oauth", callback.path == "/callback",
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw ServiceError(message: "Unexpected authorization callback.")
        }
        let query = parts.queryItems ?? []
        func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
        guard query.filter({ $0.name == "state" }).count == 1, value("state") == state else {
            throw ServiceError(message: "Authorization session did not match. Please reconnect.")
        }
        let oauthError = value("error")
        if !oauthError.isEmpty {
            let description = value("error_description")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = description.isEmpty
                ? oauthError.replacingOccurrences(of: "_", with: " ")
                : description
            throw ServiceError(message: "Authorization failed: \(reason.prefix(240))")
        }
        guard query.filter({ $0.name == "code" }).count == 1, !value("code").isEmpty else {
            throw ServiceError(message: "The service returned no authorization code.")
        }
        let result = try await api.request("/api/mcp/oauth", method: "POST", body: .object([
            "tokenUrl": metadata["tokenUrl"], "clientId": metadata["clientId"], "clientSecret": metadata["clientSecret"],
            "code": .string(value("code")), "verifier": .string(verifier), "redirectUri": .string(redirect), "resource": metadata["resource"]
        ]))
        guard !result["accessToken"].string.isEmpty else { throw ServiceError(message: "Authorization returned no access token.") }
        return result["accessToken"].string
    }
}

private struct VesperConnectorView: View {
    @EnvironmentObject private var store: AppStore
    @State private var token = CredentialStore.read(account: "vesper-mcp-owner")
    @State private var status = ""
    @State private var statusIsError = false
    @State private var showsToken = false
    @State private var urlCopied = false
    @State private var busy = false
    @State private var confirming = false
    private let endpoint = "https://mcp.vesper.r-vera.com/mcp"
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Page(title: "Vesper MCP", subtitle: "Let \(store.agentDisplayName) access your Vesper through a connector.", showsTitle: false) {
            SettingsGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").font(.system(size: 17, weight: .semibold))
                        Text("Connection URL").font(.headline)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = endpoint
                            urlCopied = true
                        } label: { Label(urlCopied ? "Copied" : "Copy", systemImage: urlCopied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Text(endpoint)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 13))
                    Text("Add this URL to ChatGPT or another MCP client.")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                }
            }
            SettingsGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Access token", systemImage: "key.horizontal").font(.headline)
                    HStack(spacing: 4) {
                        Group {
                            if showsToken { TextField("Bearer token", text: $token) }
                            else { SecureField("Bearer token", text: $token) }
                        }.textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 14))
                        Button { showsToken.toggle() } label: {
                            Image(systemName: showsToken ? "eye.slash" : "eye").frame(width: 34, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel(showsToken ? "Hide token" : "Show token")
                        Button {
                            UIPasteboard.general.string = trimmedToken
                            status = "Token copied"
                            statusIsError = false
                        } label: {
                            Image(systemName: "doc.on.doc").frame(width: 34, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Copy token").disabled(trimmedToken.isEmpty)
                    }.padding(.leading, 12).padding(.trailing, 4)
                        .vesperGlass(in: RoundedRectangle(cornerRadius: 13))
                    Text("This is separate from your device pairing token. Set a new token on Vesper before testing it.")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                    Button { confirming = true } label: {
                        Text("Set token on Vesper").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(VesperTheme.palette == .black ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(VesperTheme.ink, in: Capsule())
                    }.buttonStyle(.plain).disabled(busy || trimmedToken.isEmpty)
                    Button { Task { await test() } } label: {
                        Text("Test connection").font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(busy || trimmedToken.isEmpty)
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    if !status.isEmpty {
                        Label(status, systemImage: statusIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.footnote).foregroundStyle(statusIsError ? Color.red : VesperTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.background { Background() }.transparentNavigationTop()
            .onChange(of: token) { _, _ in status = ""; statusIsError = false }
            .confirmationDialog("Replace Vesper’s MCP access token? Existing connectors using the old token will need updating.", isPresented: $confirming, titleVisibility: .visible) {
            Button("Set token") { Task { await setup() } }
        }
    }
    private func test() async {
        busy = true; defer { busy = false }
        do {
            let result = try await store.api.request("/api/mcp", method: "POST", body: .object(["url": .string(endpoint), "token": .string(trimmedToken)]))
            try CredentialStore.save(trimmedToken, account: "vesper-mcp-owner")
            status = "Connected · \(Int(result["toolCount"].number)) tools"
            statusIsError = false
        } catch { status = error.localizedDescription; statusIsError = true }
    }
    private func setup() async {
        let value = trimmedToken
        guard (16...256).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { status = "Use 16–256 letters, numbers, underscores or hyphens."; statusIsError = true; return }
        busy = true
        do { _ = try await store.api.request("/api/mcp/owner-token", method: "POST", body: .object(["token": .string(value)])); try CredentialStore.save(value, account: "vesper-mcp-owner"); status = "Token saved. Test the connection next."; statusIsError = false }
        catch { status = error.localizedDescription; statusIsError = true }
        busy = false
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("vesperNotifyLetters") private var notifyLetters = true
    @State private var notifyQuotes = true
    @State private var quoteLoaded = false
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var loaded = false
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        PermissionPage(title: "Notifications") {
            PermissionPanel {
                HStack {
                    Label("Notification access", systemImage: "bell.fill").font(.headline)
                    Spacer()
                    Text(accessStatus).font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Text("Choose which Vesper updates can notify this device.").foregroundStyle(VesperTheme.muted)
                if loaded && authorization == .notDetermined {
                    Button { Task { await requestPermission() } } label: {
                        Text(busy ? "Requesting…" : "Allow notifications")
                    }.buttonStyle(PermissionActionStyle()).disabled(busy)
                } else if loaded {
                    Button("Open system settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }.buttonStyle(PermissionActionStyle())
                }
                DisclosureGroup("About this access") {
                    Text("每日句子通过已连接的 Bark 或网页推送；新打开的信使用设备通知。日期提醒可在每个日期里单独设置。")
                        .font(.footnote).foregroundStyle(VesperTheme.muted).padding(.top, 8)
                }.font(.subheadline)
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            PermissionPanel {
                Text("What to notify").font(.headline)
                Toggle("每日句子", isOn: Binding(get: { notifyQuotes }, set: { value in
                    notifyQuotes = value
                    Task { await saveQuotePreference(value) }
                })).disabled(!quoteLoaded || busy)
                Toggle("新打开的信", isOn: $notifyLetters)
                Text("日期提醒可以在每个日期里单独设置；聊天回复可在 Bark 通知里设置。")
                    .font(.footnote).foregroundStyle(VesperTheme.muted)
            }
        }.task(id: scenePhase) { if scenePhase == .active { await refreshPermission() } }
            .task(id: store.baseURL + "\n" + store.token) { await loadQuotePreference() }
    }
    private var accessStatus: String {
        guard loaded else { return "Checking…" }
        switch authorization {
        case .authorized: return "Allowed"
        case .provisional, .ephemeral: return "Limited"
        case .denied: return "Off"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
    @MainActor private func refreshPermission() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        loaded = true
    }
    @MainActor private func requestPermission() async {
        guard !busy else { return }
        busy = true; error = ""
        defer { busy = false }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { self.error = error.localizedDescription }
        await refreshPermission()
    }
    @MainActor private func loadQuotePreference() async {
        guard !store.token.isEmpty else { return }
        do {
            let result = try await store.api.request("/api/daily-quotes")
            notifyQuotes = result["preferences"]["notify"].bool
            quoteLoaded = true
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func saveQuotePreference(_ value: Bool) async {
        busy = true; defer { busy = false }
        do {
            let result = try await store.api.request("/api/daily-quotes", method: "POST", body: .object([
                "action": .string("preferences"), "notify": .bool(value)]))
            guard result["preferences"]["notify"].bool == value else { throw ServiceError(message: "通知偏好未保存。") }
            await DailyQuoteNotifications.refresh(api: store.api)
            error = ""
        } catch { notifyQuotes = !value; self.error = error.localizedDescription }
    }
}

struct ChatAvatarSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var photo: PhotosPickerItem?
    @State private var picker = false
    @State private var selectedRole = "agent"
    @State private var saving = false
    @State private var saveError: String?
    @State private var editingName = false
    @State private var editingRole = "agent"
    @State private var name = ""
    var body: some View {
        Page(title: "Avatars", showsTitle: false) {
            SettingsGlassCard {
                VStack(spacing: 18) {
                    avatarRow("agent", fallback: store.agentDisplayName)
                    Divider()
                    avatarRow("user", fallback: "Vera")

                }
            }
            if saving { ProgressView("Saving…").frame(maxWidth: .infinity) }
        }.background { Background() }.transparentNavigationTop()
            .photosPicker(isPresented: $picker, selection: $photo, matching: .images)
            .onChange(of: photo) { _, selected in
                guard let selected else { return }
                let role = selectedRole
                saving = true
                Task {
                    defer { saving = false; photo = nil }
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self) else { throw ServiceError(message: "Could not read this photo.") }
                        let jpeg = try await ChatImageProcessing.prepareAvatar(data)
                        let saved = await store.mutate("profile", verifySavedValue: true) { current in
                            var profile = current
                            profile[role + "Avatar"] = .string("data:image/jpeg;base64," + jpeg.base64EncodedString())
                            return profile
                        }
                        if !saved { saveError = store.error ?? "Could not save this avatar."; store.error = nil }
                    } catch { saveError = error.localizedDescription }
                }
            }
            .alert("Edit name", isPresented: $editingName) {
                TextField("Name", text: $name)
                Button("Save") {
                    let updated = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
                    let role = editingRole
                    saving = true
                    Task {
                        defer { saving = false }
                        let saved = await store.mutate("profile", verifySavedValue: true) { current in
                            var profile = current; profile[role + "Name"] = .string(updated); return profile
                        }
                        if !saved { saveError = store.error ?? "The contact name could not be saved."; store.error = nil }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Updates this name throughout Vesper.")
            }
            .alert("Contact", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
    }
    private func avatarRow(_ role: String, fallback: String) -> some View {
        let profile = store.document("profile")
        let name = profile[role + "Name"].string.isEmpty ? fallback : profile[role + "Name"].string
        return HStack(spacing: 14) {
            Button { selectedRole = role; picker = true } label: {
                ChatProfileAvatar(source: profile[role + "Avatar"].string, name: name, role: role, baseURL: store.baseURL).equatable()
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Change " + name + "’s avatar")
                .accessibilityIdentifier("change-" + role + "-avatar")
            Button {
                editingRole = role; self.name = name; editingName = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 17, weight: .medium)).lineLimit(1)
                        Text("Edit name").font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(VesperTheme.muted)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Edit " + name + "’s name")
                .accessibilityIdentifier("edit-" + role + "-name")
        }.foregroundStyle(VesperTheme.ink).disabled(saving)
    }
}


struct BarkSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.chatWorkspace) private var workspace
    @State private var enabled = false
    @State private var address = ""
    @State private var showAddress = false
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var confirmation = ""
    private var connection: AppStore { workspace?.runtime(.vps).store ?? store }
    var body: some View {
        Page(title: "Bark", showsTitle: false) {
            SettingsGlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Reply notifications", isOn: $enabled)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Push address").font(.caption).foregroundStyle(VesperTheme.muted)
                        HStack(spacing: 8) {
                            Group {
                                if showAddress { TextField("https://api.day.app/your-device-key", text: $address) }
                                else { SecureField("https://api.day.app/your-device-key", text: $address) }
                            }.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .font(.system(size: 14)).accessibilityLabel("Bark push address")
                            Button { showAddress.toggle() } label: {
                                Image(systemName: showAddress ? "eye.slash" : "eye").frame(width: 36, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(showAddress ? "Hide address" : "Show address")
                        }.padding(.leading, 12).padding(.trailing, 4)
                            .vesperGlass(in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text("VPS 聊天、拍一拍和自唤醒：整轮回复完成后只提醒一次。正在看对应聊天时保持安静；通知使用当前名字和头像。")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                    Text("这个地址保存在 VPS 上，手机和平板共用；在任一设备保存都会改变同一个推送目标。")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                    VStack(spacing: 10) {
                        Button { Task { await save(test: false) } } label: {
                            Text("Save").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(VesperTheme.palette == .black ? Color.black : Color.white)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(VesperTheme.ink, in: Capsule()).contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("bark-save")
                        Button { Task { await save(test: true) } } label: {
                            Label("Send test notification", systemImage: "bell")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(VesperTheme.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .vesperGlass(in: Capsule(), interactive: true).contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("bark-test")
                            .disabled(!enabled || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !confirmation.isEmpty { Text(confirmation).font(.caption).foregroundStyle(VesperTheme.muted) }
                }
            }.disabled(loading || saving || connection.token.isEmpty)
            if loading || saving { ProgressView().frame(maxWidth: .infinity) }
            if connection.token.isEmpty { Text("请先连接 VPS。").foregroundStyle(VesperTheme.muted) }
        }.background { Background() }.transparentNavigationTop()
            .task {
                defer { loading = false }
                guard !connection.token.isEmpty else { return }
                do {
                    let value = try await connection.api.request("/notifications/bark", history: true)
                    enabled = value["enabled"].bool; address = value["address"].string
                    NotificationCenter.default.post(name: .init("BarkConfigurationChanged"), object: nil)
                } catch { self.error = error.localizedDescription }
            }
            .alert("Bark", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func save(test: Bool) async {
        guard !saving else { return }
        saving = true; confirmation = ""
        defer { saving = false }
        do {
            let api = connection.api
            let value = try await api.request("/notifications/bark", method: "POST", body: .object([
                "enabled": .bool(enabled), "address": .string(address.trimmingCharacters(in: .whitespacesAndNewlines))]), history: true)
            guard value["enabled"].bool == enabled else { throw ServiceError(message: "Bark settings were not confirmed.") }
            address = value["address"].string
            NotificationCenter.default.post(name: .init("BarkConfigurationChanged"), object: nil)
            if test {
                let result = try await api.request("/notifications/bark", method: "POST", body: .object(["action": .string("test")]), history: true)
                guard result["ok"].bool else { throw ServiceError(message: "Bark delivery could not be confirmed.") }
                confirmation = "测试通知已发送。"
            } else { confirmation = "已保存。" }
        } catch { self.error = error.localizedDescription }
    }
}
