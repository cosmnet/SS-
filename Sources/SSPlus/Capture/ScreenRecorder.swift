import AppKit
import AVFoundation
import ScreenCaptureKit

/// Kayıt motorlarının ortak arayüzü.
protocol ScreenRecording: AnyObject {
    var url: URL { get }
    var onFailure: ((Error) -> Void)? { get set }
    @MainActor func start(globalRect: CGRect, screen: NSScreen, fps: Int, captureAudio: Bool, showCursor: Bool) async throws
    func stop() async throws -> URL
}

enum RecorderFactory {
    /// macOS 12.3+: ScreenCaptureKit; daha eski: AVCaptureScreenInput.
    @MainActor
    static func make(url: URL) -> any ScreenRecording {
        if #available(macOS 12.3, *) {
            return ScreenRecorder(url: url)
        }
        return LegacyScreenRecorder(url: url)
    }
}

// MARK: - ScreenCaptureKit (macOS 12.3+)

@available(macOS 12.3, *)
final class ScreenRecorder: NSObject, ScreenRecording, SCStreamOutput, SCStreamDelegate {
    /// Ayarlardaki kaba göre uzantı düzeltilebildiği için değişken; stop() bunu döndürür.
    private(set) var url: URL
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
    /// Aşağıdaki dört alan YALNIZCA `sampleQueue` üzerinden okunur/yazılır.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let sampleQueue = DispatchQueue(label: "ssplus.recorder.samples")

    init(url: URL) {
        self.url = url
    }

    @MainActor
    func start(globalRect: CGRect, screen: NSScreen, fps: Int, captureAudio: Bool, showCursor: Bool) async throws {
        let content = try await SCKContent.shareableContent()
        guard let display = SCKContent.scDisplay(for: screen, in: content) else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: SCKContent.ownWindows(in: content))

        let scale = screen.backingScaleFactor
        var pixelWidth = Int(globalRect.width * scale)
        var pixelHeight = Int(globalRect.height * scale)
        pixelWidth -= pixelWidth % 2
        pixelHeight -= pixelHeight % 2

        let safeFPS = max(1, min(fps, 120))
        // Sistem sesi ScreenCaptureKit'te macOS 13 ile geldi.
        var audioEnabled = false
        if #available(macOS 13, *) { audioEnabled = captureAudio }

        let config = SCStreamConfiguration()
        config.sourceRect = CaptureEngine.localTopLeftRect(globalRect, on: screen)
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursor
        config.queueDepth = 6
        if #available(macOS 13, *) { config.capturesAudio = audioEnabled }

        let settings = SettingsStore.shared
        let isPro = ProManager.shared.isPro
        let fileType: AVFileType = settings.videoFormat.lowercased() == "mp4" ? .mp4 : .mov
        let codec: AVVideoCodecType = (settings.videoCodec.lowercased() == "hevc" && isPro) ? .hevc : .h264
        let autoBitrate = min(40_000_000, max(2_000_000, Int(Double(pixelWidth * pixelHeight * safeFPS) * 0.07)))
        let chosenMbps = settings.videoBitrateMbps
        let bitrate = (chosenMbps > 0 && isPro) ? chosenMbps * 1_000_000 : autoBitrate

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: safeFPS,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioEnabled {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.encodeFailed
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if #available(macOS 13, *), audioEnabled {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        sampleQueue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.sessionStarted = false
        }
        self.stream = stream

        // Çizim penceresi akış başladıktan SONRA oluşur; filtreden muaf kalıp videoya girer.
        RecordingDrawController.shared.arm()
    }

    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        let (writer, started): (AVAssetWriter?, Bool) = sampleQueue.sync {
            let w = self.writer
            let s = self.sessionStarted
            if s {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            return (w, s)
        }

        guard let writer else { return url }

        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.noFrames
        }

        if writer.status == .writing {
            await writer.finishWriting()
        }
        if writer.status == .failed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CaptureError.encodeFailed
        }
        return url
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
            return
        }
        if #available(macOS 13, *), type == .audio {
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }
}

// MARK: - AVCaptureScreenInput (macOS 10.15 – 12.2)

/// ScreenCaptureKit öncesi Mac'ler için kayıt: AVCaptureSession + ekran girişi +
/// film dosyası çıkışı. Sistem sesi bu yolda yoktur; kap her zaman QuickTime (.mov).
final class LegacyScreenRecorder: NSObject, ScreenRecording, AVCaptureFileOutputRecordingDelegate {
    private(set) var url: URL
    var onFailure: ((Error) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(url: URL) {
        self.url = url.pathExtension.lowercased() == "mov" ? url : url.deletingPathExtension().appendingPathExtension("mov")
    }

    @MainActor
    func start(globalRect: CGRect, screen: NSScreen, fps: Int, captureAudio: Bool, showCursor: Bool) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        guard let input = AVCaptureScreenInput(displayID: CaptureEngine.displayID(for: screen)) else {
            throw CaptureError.noDisplay
        }
        input.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 60))))
        input.capturesCursor = showCursor
        input.capturesMouseClicks = false
        // Kırpma: ekranın kendi koordinatı (alt-sol orijin, punto)
        input.cropRect = CGRect(
            x: globalRect.minX - screen.frame.minX,
            y: globalRect.minY - screen.frame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
        input.scaleFactor = screen.backingScaleFactor

        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CaptureError.noDisplay }
        session.addInput(input)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw CaptureError.encodeFailed }
        session.addOutput(output)
        session.commitConfiguration()
        if let connection = output.connection(with: .video) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
        }

        session.startRunning()
        try? FileManager.default.removeItem(at: url)
        output.startRecording(to: url, recordingDelegate: self)
        RecordingDrawController.shared.arm()
    }

    func stop() async throws -> URL {
        guard output.isRecording else {
            session.stopRunning()
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.noFrames
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); stopContinuation = cont; lock.unlock()
            output.stopRecording()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        session.stopRunning()
        lock.lock(); let cont = stopContinuation; stopContinuation = nil; lock.unlock()
        if let error {
            // AVFoundation, başarıyla biten kayıtlarda da "durduruldu" hatası verebilir.
            let finishedOK = ((error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !finishedOK {
                if let cont {
                    cont.resume(throwing: error)
                } else {
                    DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
                }
                return
            }
        }
        cont?.resume(returning: outputFileURL)
    }
}
