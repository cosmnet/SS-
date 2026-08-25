import AppKit
import AVFoundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Ayarlardaki kaba göre uzantı düzeltilebildiği için değişken; stop() bunu döndürür.
    private(set) var url: URL
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
    /// Aşağıdaki dört alan YALNIZCA `sampleQueue` üzerinden okunur/yazılır.
    /// `stop()` de onlara ancak `sampleQueue.sync` içinden dokunur; böylece
    /// geç gelen bir kare, kapatılmış bir girişe eklenmeye çalışmaz.
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

        let safeFPS = max(1, min(fps, 120))
        let config = SCStreamConfiguration()
        config.sourceRect = CaptureEngine.localTopLeftRect(globalRect, on: screen)
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursor
        config.queueDepth = 6
        config.capturesAudio = captureAudio

        // MARK: Ayarlardan gelen kap / kodek / bit hızı
        let settings = SettingsStore.shared
        let isPro = ProManager.shared.isPro

        let fileType: AVFileType = settings.videoFormat.lowercased() == "mp4" ? .mp4 : .mov

        // HEVC yalnızca Pro'da; değilse H.264'e düş
        let codec: AVVideoCodecType =
            (settings.videoCodec.lowercased() == "hevc" && isPro) ? .hevc : .h264

        // Bit hızı: 0 = otomatik formül, diğerleri yalnızca Pro'da geçerli.
        // Ekran içeriği çok iyi sıkışır; kare hızıyla ölçekle ve üstten sınırla.
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
        if captureAudio {
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

        // Yazıcı açıldıktan sonra akış kurulamazsa diske boş bir dosya
        // bırakma: yazımı iptal et, dosyayı sil, hatayı yukarı ilet.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if captureAudio {
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

        // Kayıt sırasında ekrana çizim katmanını hazırla (singleton'a dokunmak
        // bildirim + faz gözlemcilerini kaydeder). Çizim penceresi akış
        // başladıktan SONRA oluştuğu için içerik filtresinden muaf kalır ve
        // videoya dahil olur.
        RecordingDrawController.shared.arm()
    }

    /// Akışı durdurur ve dosyayı kapatır.
    ///
    /// - Hiç kare gelmediyse dosya silinir ve `CaptureError.noFrames` fırlatılır.
    /// - Yazıcı hata verdiyse dosya silinir ve yazıcının hatası fırlatılır.
    /// Böylece çağıran taraf asla oynatılamayan bir dosyayı "kaydedildi" diye sunmaz.
    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Örnek kuyruğuyla senkron: bundan sonra hiçbir kare eklenemez.
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

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
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
        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
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
