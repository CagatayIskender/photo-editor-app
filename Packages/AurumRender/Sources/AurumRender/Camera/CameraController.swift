import AVFoundation
import CoreImage
import SwiftUI
import AurumCore

/// The in-app camera: a live preview with the chosen look applied, photo
/// capture at full resolution with the same look, and video recording with
/// the look burned in.
///
/// Frames arrive on a capture queue, are graded with `FilterGraph` and
/// published as CGImages at preview size. Recording writes the graded frames
/// through `AVAssetWriter`, so what you see is what is recorded.
@MainActor
public final class CameraController: NSObject, ObservableObject {
    public enum Position { case back, front }
    public enum State: Equatable { case idle, running, recording, denied, failed(String) }

    @Published public private(set) var preview: CGImage?
    @Published public private(set) var state: State = .idle
    @Published public private(set) var position: Position = .back
    @Published public private(set) var recordingSeconds: Double = 0
    /// The look applied live. Changing it takes effect on the next frame.
    @Published public var document: EditDocument

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "aurum.camera")
    private let processor: FrameProcessor
    private var photoContinuation: CheckedContinuation<CIImage, Error>?

    public init(catalog: LookCatalog) {
        self.document = EditDocument(source: SourceAsset(localIdentifier: "camera", pixelSize: PixelSize(width: 1080, height: 1920)))
        self.processor = FrameProcessor(graph: FilterGraph(catalog: catalog))
        super.init()
        processor.onPreview = { [weak self] image in
            Task { @MainActor in self?.preview = image }
        }
        processor.onRecordingTime = { [weak self] seconds in
            Task { @MainActor in self?.recordingSeconds = seconds }
        }
    }

    // MARK: Session

    public func start() async {
        let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
        guard videoAllowed else { state = .denied; return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        processor.setDocument(document)
        let session = self.session
        let configured: Bool = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.configure(position: .back))
                session.startRunning()
            }
        }
        state = configured ? .running : .failed("The camera couldn't start.")
    }

    public func stop() {
        let session = self.session
        queue.async { session.stopRunning() }
        state = .idle
    }

    public func flip() {
        let next: Position = position == .back ? .front : .back
        position = next
        queue.async { _ = self.configure(position: next) }
    }

    public func documentDidChange() {
        processor.setDocument(document)
    }

    nonisolated private func configure(position: Position) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        for input in session.inputs { session.removeInput(input) }

        let devicePosition: AVCaptureDevice.Position = position == .back ? .back : .front
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: devicePosition),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return false }
        session.addInput(input)
        if let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(processor, queue: queue)
            session.addOutput(videoOutput)
        }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(processor, queue: queue)
            session.addOutput(audioOutput)
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = position == .front }
        }
        processor.isMirrored = position == .front
        return true
    }

    // MARK: Photo

    /// Captures a full-resolution photo and returns it with the look applied.
    public func capturePhoto() async throws -> CIImage {
        let raw: CIImage = try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        return processor.graded(raw, document: document)
    }

    // MARK: Video

    public func startRecording(to url: URL) {
        processor.startRecording(to: url)
        state = .recording
    }

    /// Finishes the movie file and returns its URL.
    public func stopRecording() async -> URL? {
        let url = await processor.stopRecording()
        state = .running
        recordingSeconds = 0
        return url
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<CIImage, Error>
        if let data = photo.fileDataRepresentation(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            result = .success(image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)))
        } else {
            result = .failure(error ?? NSError(domain: "AurumCamera", code: 1))
        }
        Task { @MainActor in
            self.photoContinuation?.resume(with: result)
            self.photoContinuation = nil
        }
    }
}

/// Grades camera frames off the main thread and feeds the recorder.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var graph: FilterGraph
    private var document: EditDocument?
    private let context = CIContext(options: [.cacheIntermediates: false])
    var isMirrored = false
    var onPreview: ((CGImage) -> Void)?
    var onRecordingTime: ((Double) -> Void)?

    // Recording state, touched only on the capture queue except where locked.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var pendingURL: URL?
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    /// Longest side of preview frames.
    static let previewSize: CGFloat = 1280

    init(graph: FilterGraph) {
        self.graph = graph
    }

    func setDocument(_ document: EditDocument) {
        lock.lock(); self.document = document; lock.unlock()
    }

    func graded(_ image: CIImage, document: EditDocument) -> CIImage {
        var doc = document
        doc.crop = .identity
        return graph.apply(doc, to: image)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); let doc = document; lock.unlock()
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let output = doc.map { graded(frame, document: $0) } ?? frame
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        appendVideo(output, at: time, size: frame.extent.size)

        let scale = min(1, Self.previewSize / max(output.extent.width, output.extent.height))
        let small = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = context.createCGImage(small, from: small.extent) { onPreview?(cg) }
    }

    // MARK: Recording

    func startRecording(to url: URL) {
        lock.lock(); pendingURL = url; lock.unlock()
    }

    func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let writer, let videoInput else {
                pendingURL = nil
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            stopContinuation = continuation
            self.writer = nil
            lock.unlock()
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            let url = writer.outputURL
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let c = self.stopContinuation
                self.stopContinuation = nil
                self.videoInput = nil
                self.audioInput = nil
                self.adaptor = nil
                self.startTime = nil
                self.lock.unlock()
                c?.resume(returning: writer.status == .completed ? url : nil)
            }
        }
    }

    private func appendVideo(_ image: CIImage, at time: CMTime, size: CGSize) {
        lock.lock()
        if writer == nil, let url = pendingURL {
            pendingURL = nil
            setUpWriter(url: url, size: size, at: time)
        }
        let input = videoInput, adaptor = self.adaptor, start = startTime
        lock.unlock()
        guard let input, let adaptor, let start, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        context.render(image, to: buffer)
        adaptor.append(buffer, withPresentationTime: time)
        onRecordingTime?(CMTimeSubtract(time, start).seconds)
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock(); let input = audioInput, started = startTime != nil; lock.unlock()
        guard started, let input, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    /// Called with the lock held.
    private func setUpWriter(url: URL, size: CGSize, at time: CMTime) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ])
        audio.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height
        ])
        if writer.canAdd(video) { writer.add(video) }
        if writer.canAdd(audio) { writer.add(audio) }
        writer.startWriting()
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.adaptor = adaptor
        self.startTime = time
    }
}
