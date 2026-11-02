import AVFoundation
import CoreImage
import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// The AURUM camera: a live preview wearing the chosen look, a strip of
/// looks to swap while framing, and one shutter: tap for a photo, hold to
/// record. A photo opens in the Studio still wearing its look (so it can be
/// changed); a video opens in the video editor.
struct CameraView: View {
    @ObservedObject var app: AppModel
    @StateObject private var camera: CameraController
    @State private var selectedLookID: String?
    @State private var showsGrid = false
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var isBusy = false
    @State private var isPressing = false
    @State private var holdTask: Task<Void, Never>?
    @State private var startedRecordingFromHold = false
    @State private var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel) {
        self.app = app
        _camera = StateObject(wrappedValue: CameraController(catalog: app.catalog))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.state {
            case .denied:
                deniedState
            case .failed(let reason):
                failedState(reason)
            default:
                VStack(spacing: 0) {
                    topBar
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    lookStrip
                    controls
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task { await camera.start() }
        .onDisappear {
            holdTask?.cancel()
            camera.stop()
        }
    }

    private var isRecording: Bool { camera.state == .recording }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Spacing.xs) {
            IconButton(.close, label: String(localized: "Close")) { app.closeFlow() }
                .disabled(isRecording || isBusy)
                .accessibilityIdentifier("camera.close")
            Spacer()
            if isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(verbatim: VideoEditorView.timecode(camera.recordingSeconds))
                        .aurumText(.caption)
                        .monospacedDigit()
                }
                .padding(.horizontal, Spacing.s)
                .frame(height: 28)
                .background(Capsule().fill(.black.opacity(0.5)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Recording, \(VideoEditorView.timecode(camera.recordingSeconds))"))
            } else {
                Button { cycleTimer() } label: {
                    Text(timerSeconds == 0 ? String(localized: "Timer off") : String(localized: "\(timerSeconds) s"))
                        .aurumText(.label, color: timerSeconds == 0 ? AurumColor.textSecondary : AurumColor.accent)
                        .frame(minWidth: Size.touch, minHeight: Size.touch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Self-timer")
                .accessibilityValue(timerSeconds == 0 ? String(localized: "Off") : String(localized: "\(timerSeconds) seconds"))
                Button { showsGrid.toggle(); Haptics.detent() } label: {
                    Text("Grid")
                        .aurumText(.label, color: showsGrid ? AurumColor.accent : AurumColor.textSecondary)
                        .frame(minWidth: Size.touch, minHeight: Size.touch)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showsGrid ? .isSelected : [])
            }
            Spacer()
            IconButton(.flip, label: String(localized: "Switch camera"), isEnabled: !isRecording && !isBusy) {
                camera.flip()
                Haptics.detent()
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 52)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            if let image = camera.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    .overlay { if showsGrid { CameraGrid().allowsHitTesting(false) } }
                    .accessibilityLabel(previewLabel)
                    .accessibilityAddTraits(.isImage)
            } else {
                ProgressView().tint(AurumColor.accent)
            }
            if let countdown {
                Text(verbatim: "\(countdown)")
                    .font(AurumTextStyle.display.font.weight(.light))
                    .scaleEffect(2.4)
                    .foregroundColor(AurumColor.textPrimary)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                    .id(countdown)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.4).combined(with: .opacity))
                    .accessibilityLabel(String(localized: "Taking photo in \(countdown)"))
            }
            if let message {
                NoticeBanner(text: message) { self.message = nil }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, Spacing.s)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: countdown)
    }

    private var previewLabel: String {
        if let id = selectedLookID, let look = app.catalog.look(id: id) {
            return String(localized: "Camera preview, with the \(look.name) look")
        }
        return String(localized: "Camera preview")
    }

    // MARK: Looks

    private var lookStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Spacing.s) {
                Button { selectLook(nil) } label: {
                    LookThumbnail(name: String(localized: "Original"), image: nil, swatch: [AurumColor.surfaceRaised, AurumColor.surface], isSelected: selectedLookID == nil, isPremium: false)
                }
                .buttonStyle(.plain)
                ForEach(app.catalog.looks) { look in
                    Button { selectLook(look.id) } label: {
                        LookThumbnail(
                            name: look.name,
                            image: nil,
                            swatch: look.swatch.map(Color.init(hex:)),
                            isSelected: selectedLookID == look.id,
                            isPremium: look.tier == .member
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, 4)
        }
        .frame(height: 112)
        .disabled(isBusy)
    }

    private func selectLook(_ id: String?) {
        selectedLookID = id
        var doc = EditDocument(source: camera.document.source)
        if let id { doc.applyLook(id) }
        camera.document = doc
        camera.documentDidChange()
        Haptics.apply()
        if let id {
            app.deps.analytics.track(.lookApplied(lookID: id, premium: app.catalog.look(id: id)?.tier == .member))
        }
    }

    // MARK: Shutter

    private var controls: some View {
        HStack {
            Spacer()
            shutter
            Spacer()
        }
        .overlay(alignment: .center) {
            Text(isRecording ? String(localized: "Release to stop") : String(localized: "Tap for photo · hold for video"))
                .aurumText(.label, color: AurumColor.textTertiary)
                .offset(y: 54)
                .accessibilityHidden(true)
        }
        .frame(height: 124)
        .padding(.bottom, Spacing.s)
    }

    private var shutter: some View {
        ZStack {
            Circle()
                .stroke(AurumColor.textPrimary.opacity(0.9), lineWidth: 3)
                .frame(width: 78, height: 78)
            RoundedRectangle(cornerRadius: isRecording ? 8 : 31)
                .fill(isRecording ? Color.red : AurumColor.textPrimary)
                .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                .scaleEffect(isPressing && !isRecording ? 0.92 : 1)
            if isBusy {
                ProgressView().tint(AurumColor.onAccent)
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: isRecording)
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: isPressing)
        .frame(width: 88, height: 88)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressBegan() }
                .onEnded { _ in pressEnded() }
        )
        .allowsHitTesting(!isBusy && countdown == nil && camera.state != .idle)
        .accessibilityElement()
        .accessibilityLabel(isRecording ? String(localized: "Stop recording") : String(localized: "Shutter"))
        .accessibilityHint("Tap to take a photo. Touch and hold to record a video.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await shutterTapped() } }
        .accessibilityAction(named: isRecording ? String(localized: "Stop recording") : String(localized: "Record video")) {
            Task {
                if isRecording { await finishRecording() } else { startRecording() }
            }
        }
        .accessibilityIdentifier("camera.shutter")
    }

    private func pressBegan() {
        guard !isPressing else { return }
        isPressing = true
        startedRecordingFromHold = false
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, isPressing, !isRecording else { return }
            startedRecordingFromHold = true
            startRecording()
        }
    }

    private func pressEnded() {
        isPressing = false
        holdTask?.cancel()
        holdTask = nil
        if startedRecordingFromHold || isRecording {
            startedRecordingFromHold = false
            Task { await finishRecording() }
        } else {
            Task { await shutterTapped() }
        }
    }

    private func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
        Haptics.detent()
    }

    private func shutterTapped() async {
        guard !isBusy, countdown == nil else { return }
        if timerSeconds > 0 {
            for n in stride(from: timerSeconds, through: 1, by: -1) {
                countdown = n
                Haptics.detent()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = nil
        }
        await takePhoto()
    }

    // MARK: Capture

    /// Captures the original (the look is kept as an edit, not burned in),
    /// adds it to Photos, and opens it in the Studio wearing the same look.
    private func takePhoto() async {
        isBusy = true
        defer { isBusy = false }
        let live = camera.document
        // `capturePhoto` grades with `document`; a neutral one returns the original.
        camera.document = EditDocument(source: live.source)
        let captured: CIImage
        do {
            captured = try await camera.capturePhoto()
            camera.document = live
        } catch {
            camera.document = live
            message = String(localized: "The photo couldn't be taken. Please try again.")
            return
        }
        Haptics.success()
        guard let data = Self.jpegData(captured) else {
            message = String(localized: "The photo couldn't be taken. Please try again.")
            return
        }
        do {
            try await app.deps.photos.save(data, fileExtension: "jpg")
        } catch {
            message = String(localized: "AURUM needs permission to add photos. You can allow it in Settings.")
            return
        }
        guard let item = await app.deps.photos.recentPhotos(limit: 1).first else {
            message = String(localized: "Saved to Photos")
            return
        }
        camera.stop()
        app.openCapturedPhoto(item, lookID: selectedLookID)
    }

    static func jpegData(_ image: CIImage) -> Data? {
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return CIContext().jpegRepresentation(of: image, colorSpace: space, options: [:])
    }

    private func startRecording() {
        guard !isRecording else { return }
        camera.startRecording(to: Self.recordingURL())
        Haptics.apply()
        app.deps.analytics.track(.toolOpened(tool: "camera.record"))
    }

    /// Stops recording, adds the video to Photos and opens it in the video editor.
    private func finishRecording() async {
        guard isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        let size = camera.preview.map { PixelSize(width: $0.width, height: $0.height) } ?? PixelSize(width: 1080, height: 1920)
        guard let url = await camera.stopRecording() else {
            message = String(localized: "The video couldn't be saved. Please try again.")
            return
        }
        Haptics.success()
        let length = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        var source = SourceAsset(localIdentifier: LibraryMediaSource.identifier(for: url), pixelSize: size)
        var duration = length
        do {
            try await app.deps.photos.saveVideo(at: url)
            if let saved = await app.deps.photos.recentVideos(limit: 1).first {
                source = SourceAsset(localIdentifier: saved.id, pixelSize: saved.pixelSize)
                duration = saved.duration > 0 ? saved.duration : length
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            // Not in Photos: the editor works from the file AURUM recorded.
        }
        guard duration > 0 else {
            message = String(localized: "The video couldn't be saved. Please try again.")
            return
        }
        camera.stop()
        var project = VideoProject(aspect: size.aspectRatio > 1 ? .landscape : .story)
        project.append(Clip(kind: .video, source: source, sourceDuration: duration))
        app.openVideo(project, source: "camera")
    }

    /// Documents/Captures, so a clip kept outside Photos survives a relaunch.
    static func recordingURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AURUM-\(UUID().uuidString.prefix(8)).mov")
    }

    // MARK: Denied and failed

    private var deniedState: some View {
        VStack(spacing: Spacing.m) {
            IconView(.camera, size: 40).foregroundColor(AurumColor.accent)
            Text("Camera access is off").aurumText(.title)
            Text("To shoot with a look applied, allow AURUM to use the camera in Settings. Your photos stay on your iPhone.")
                .aurumText(.body, color: AurumColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(GoldButtonStyle(compact: true))
            Button("Not now") { app.closeFlow() }
                .buttonStyle(TextActionButtonStyle())
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AurumColor.background.ignoresSafeArea())
    }

    private func failedState(_ reason: String) -> some View {
        VStack(spacing: Spacing.m) {
            Text("The camera couldn't start.").aurumText(.headline)
            Text(Localized.dynamic(reason)).aurumText(.caption, color: AurumColor.textTertiary)
            Button("Close") { app.closeFlow() }
                .buttonStyle(GoldButtonStyle(compact: true))
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AurumColor.background.ignoresSafeArea())
    }
}

/// Rule-of-thirds lines over the preview.
struct CameraGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(AurumColor.textPrimary.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
