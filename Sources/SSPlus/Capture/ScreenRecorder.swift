import AppKit
import AVFoundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Ayarlardaki kaba göre uzantı düzeltilebildiği için değişken; stop() bunu döndürür.
    private(set) var url: URL
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
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
        let content = try await CaptureEngine.shareableContent()
        guard let display = CaptureEngine.scDisplay(for: screen, in: content) else {
            throw CaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let exclude = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: exclude)

        let scale = screen.backingScaleFactor
        var pixelWidth = Int(globalRect.width * scale)
        var pixelHeight = Int(globalRect.height * scale)
        pixelWidth -= pixelWidth % 2
        pixelHeight -= pixelHeight % 2

        let config = SCStreamConfiguration()
        config.sourceRect = CaptureEngine.localTopLeftRect(globalRect, on: screen)
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursor
        config.queueDepth = 6
        config.capturesAudio = captureAudio

        // MARK: Ayarlardan gelen kap / kodek / bit hızı
        let settings = SettingsStore.shared
        let isPro = ProManager.shared.isPro

        let wantsMP4 = settings.videoFormat.lowercased() == "mp4"
        let fileType: AVFileType = wantsMP4 ? .mp4 : .mov
        let wantedExtension = wantsMP4 ? "mp4" : "mov"
        if url.pathExtension.lowercased() != wantedExtension {
            let corrected = url.deletingPathExtension().appendingPathExtension(wantedExtension)
            try? FileManager.default.removeItem(at: corrected)
            url = corrected
        }

        // HEVC yalnızca Pro'da; değilse H.264'e düş
        let codec: AVVideoCodecType =
            (settings.videoCodec.lowercased() == "hevc" && isPro) ? .hevc : .h264

        // Bit hızı: 0 = otomatik formül, diğerleri yalnızca Pro'da geçerli
        let autoBitrate = max(2_000_000, pixelWidth * pixelHeight * 6)
        let chosenMbps = settings.videoBitrateMbps
        let bitrate = (chosenMbps > 0 && isPro) ? chosenMbps * 1_000_000 : autoBitrate

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        if captureAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            writer.add(audioInput)
            self.audioInput = audioInput
        }

        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.encodeFailed
        }
        self.writer = writer
        self.videoInput = videoInput

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()
        self.stream = stream

        // Kayıt sırasında ekrana çizim katmanını hazırla (singleton'a dokunmak
        // bildirim + faz gözlemcilerini kaydeder). Çizim penceresi akış
        // başladıktan SONRA oluştuğu için içerik filtresinden muaf kalır ve
        // videoya dahil olur.
        RecordingDrawController.shared.arm()
    }

    func stop() async -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }
        return url
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else { return }
            if !sessionStarted {
                writer?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        case .audio:
            guard sessionStarted, audioInput?.isReadyForMoreMediaData == true else { return }
            audioInput?.append(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }
}
