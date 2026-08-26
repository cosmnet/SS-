import AppKit
import AVFoundation
import ScreenCaptureKit

/// Kayıt motorlarının ortak arayüzü.
protocol ScreenRecording: AnyObject {
    var url: URL { get }
    var onFailure: ((Error) -> Void)? { get set }
    /// `start` sonrası: sistem sesi gerçekten alınıyor mu (macOS 13+ ve ayar açık).
    var capturesAudio: Bool { get }
    /// `start` sonrası: mikrofon gerçekten kaydediliyor mu (ayar açık, izin verilmiş, cihaz var).
    var capturesMicrophone: Bool { get }
    /// Ses düzeyi (tepe/RMS), ~20 Hz; arka plan kuyruğundan çağrılır.
    var onAudioLevel: ((AudioLevelReading) -> Void)? { get set }
    @MainActor func start(globalRect: CGRect, screen: NSScreen, fps: Int, captureAudio: Bool, captureMicrophone: Bool, showCursor: Bool) async throws
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
final class ScreenRecorder: NSObject, ScreenRecording, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Ayarlardaki kaba göre uzantı düzeltilebildiği için değişken; stop() bunu döndürür.
    private(set) var url: URL
    var onFailure: ((Error) -> Void)?
    private(set) var capturesAudio = false
    private(set) var capturesMicrophone = false
    var onAudioLevel: ((AudioLevelReading) -> Void)?

    private var stream: SCStream?
    /// macOS 15 öncesinde mikrofon ScreenCaptureKit'ten değil, ayrı bir AVCaptureSession'dan gelir.
    private var micSession: AVCaptureSession?
    /// Aşağıdaki alanlar YALNIZCA `sampleQueue` üzerinden okunur/yazılır.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var levelPeak: Float = 0
    private var levelSumSquares: Double = 0
    private var levelFrames = 0
    private var levelLastEmit: CFAbsoluteTime = 0
    private var systemFormatLogged = false
    private var micFormatLogged = false
    private var emitCount = 0
    private var measureFailures = 0
    private let sampleQueue = DispatchQueue(label: "ssplus.recorder.samples")
    /// Gösterge güncelleme aralığı (sn).
    private static let levelInterval: CFAbsoluteTime = 0.05

    init(url: URL) {
        self.url = url
    }

    @MainActor
    func start(globalRect: CGRect, screen: NSScreen, fps: Int, captureAudio: Bool, captureMicrophone: Bool, showCursor: Bool) async throws {
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
        capturesAudio = audioEnabled
        // Mikrofon: macOS 15+ ScreenCaptureKit'in kendi mikrofon çıkışı; daha eski
        // sürümlerde AVFoundation (AVCaptureSession + AVCaptureAudioDataOutput) aynı
        // `sampleQueue` üzerinden tampon verir ve aynı ses parçasına yazılır.
        var micEnabled = false
        var micViaSCK = false
        if captureMicrophone {
            if #available(macOS 15, *) {
                micEnabled = true
                micViaSCK = true
            } else if let session = makeMicrophoneSession() {
                micSession = session
                micEnabled = true
            }
        }
        capturesMicrophone = micEnabled

        let config = SCStreamConfiguration()
        config.sourceRect = CaptureEngine.localTopLeftRect(globalRect, on: screen)
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursor
        config.queueDepth = 3   // her kuyruk karesi tam boyutlu bir yüzeydir; 3 yeterli
        if #available(macOS 13, *) { config.capturesAudio = audioEnabled }
        if #available(macOS 15, *), micViaSCK {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

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

        var micInput: AVAssetWriterInput?
        if micEnabled {
            // Mikrofon ayrı bir ses parçası (track) olarak yazılır; konuşma için tek kanal yeter.
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micInput = input
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
            if #available(macOS 15, *), micViaSCK {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await stream.startCapture()
        } catch {
            micSession = nil
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        sampleQueue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.micInput = micInput
            self.sessionStarted = false
            self.levelPeak = 0
            self.levelSumSquares = 0
            self.levelFrames = 0
            self.levelLastEmit = 0
            self.systemFormatLogged = false
            self.micFormatLogged = false
            self.emitCount = 0
            self.measureFailures = 0
        }
        self.stream = stream
        micSession?.startRunning()

        // Çizim penceresi akış başladıktan SONRA oluşur; filtreden muaf kalıp videoya girer.
        RecordingDrawController.shared.arm()
    }

    /// macOS 15 öncesi için mikrofon oturumu: varsayılan giriş cihazı → tek kanal 48 kHz
    /// float LPCM tamponlar `sampleQueue` üzerinde `captureOutput(_:didOutput:from:)`'a gelir.
    /// Cihaz yoksa ya da izin verilmemişse nil (mikrofonsuz devam edilir).
    private func makeMicrophoneSession() -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate (macOS < 15 mikrofonu)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        meter(sampleBuffer, isMic: true)
        startSessionIfNeeded(with: sampleBuffer)
        guard sessionStarted, let micInput, micInput.isReadyForMoreMediaData else { return }
        micInput.append(sampleBuffer)
    }

    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        micSession?.stopRunning()
        micSession = nil

        let (writer, started): (AVAssetWriter?, Bool) = sampleQueue.sync {
            let w = self.writer
            let s = self.sessionStarted
            if s {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.micInput = nil
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
            startSessionIfNeeded(with: sampleBuffer)
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
            return
        }
        if #available(macOS 13, *), type == .audio {
            meter(sampleBuffer, isMic: false)
            startSessionIfNeeded(with: sampleBuffer)
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            return
        }
        if #available(macOS 15, *), type == .microphone {
            meter(sampleBuffer, isMic: true)
            startSessionIfNeeded(with: sampleBuffer)
            guard sessionStarted, let micInput, micInput.isReadyForMoreMediaData else { return }
            micInput.append(sampleBuffer)
        }
    }

    /// Yazma oturumunu İLK gelen örnekle başlatır — video ya da ses, hangisi önce gelirse.
    /// Ekran içeriği hiç değişmezse ScreenCaptureKit video karesi göndermeyebilir;
    /// oturum sese de yaslandığı için böyle kayıtlar "hiç kare yakalanamadı" diye
    /// ÇÖPE GİTMEZ: ses (+ varsa seyrek kareler) dosyaya yazılır.
    private func startSessionIfNeeded(with sampleBuffer: CMSampleBuffer) {
        guard !sessionStarted, let writer else { return }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sessionStarted = true
        DebugLog.log("yazma oturumu başladı")
    }

    /// Ses tamponunun düzeyini ölçer, `levelInterval` aralığıyla birleştirip `onAudioLevel`'e
    /// iletir (`sampleQueue` üzerinde). Her türün ilk tamponunun biçimi bir kez günlüğe yazılır.
    private func meter(_ sampleBuffer: CMSampleBuffer, isMic: Bool) {
        guard let reading = AudioLevel.measure(sampleBuffer) else {
            measureFailures += 1
            if measureFailures <= 3 {
                DebugLog.log("ölçüm nil (mic=\(isMic)) — \(AudioLevel.formatSummary(of: sampleBuffer))")
            }
            return
        }
        if isMic ? !micFormatLogged : !systemFormatLogged {
            if isMic { micFormatLogged = true } else { systemFormatLogged = true }
            let summary = AudioLevel.formatSummary(of: sampleBuffer)
            NSLog("SS+ kayıt sesi (mic=%d): %@", isMic ? 1 : 0, summary)
            DebugLog.log("ilk ses tamponu (mic=\(isMic)): \(summary)")
        }
        levelPeak = max(levelPeak, reading.peak)
        levelSumSquares += Double(reading.rms * reading.rms) * Double(reading.frames)
        levelFrames += reading.frames
        let now = CFAbsoluteTimeGetCurrent()
        guard now - levelLastEmit >= Self.levelInterval else { return }
        let aggregate = AudioLevelReading(
            peak: levelPeak,
            rms: Float(sqrt(levelSumSquares / Double(max(1, levelFrames)))),
            frames: levelFrames
        )
        levelPeak = 0
        levelSumSquares = 0
        levelFrames = 0
        levelLastEmit = now
        emitCount += 1
        if emitCount % 20 == 1 {
            DebugLog.log(String(format: "emit #%d tepe %.4f rms %.4f cb=%@", emitCount, aggregate.peak, aggregate.rms, onAudioLevel == nil ? "YOK" : "var"))
        }
        onAudioLevel?(aggregate)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }
}

// MARK: - AVCaptureScreenInput (macOS 10.15 – 12.2)

/// ScreenCaptureKit öncesi Mac'ler için kayıt: AVCaptureSession + ekran girişi (+ mikrofon
/// girişi) + film dosyası çıkışı. Sistem sesi bu yolda yoktur (macOS'ta API'si yok);
/// mikrofon AVFoundation ile kaydedilir. Kap her zaman QuickTime (.mov).
final class LegacyScreenRecorder: NSObject, ScreenRecording, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var url: URL
    var onFailure: ((Error) -> Void)?
    /// Bu yolda sistem sesi yoktur.
    let capturesAudio = false
    private(set) var capturesMicrophone = false
    var onAudioLevel: ((AudioLevelReading) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let meterOutput = AVCaptureAudioDataOutput()
    private let meterQueue = DispatchQueue(label: "ssplus.legacy.meter")
    private var meterLastEmit: CFAbsoluteTime = 0
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(url: URL) {
        self.url = url.pathExtension.lowercased() == "mov" ? url : url.deletingPathExtension().appendingPathExtension("mov")
    }

    @MainActor
    func start(globalRect: CGRect, screen: NSScreen, fps: Int, captureAudio: Bool, captureMicrophone: Bool, showCursor: Bool) async throws {
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
        // Mikrofon: film çıkışı ses parçasını kendiliğinden yazar; ayrı bir veri
        // çıkışı yalnızca düzey göstergesi için tamponları ölçer.
        if captureMicrophone,
           let device = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            capturesMicrophone = true
            if session.canAddOutput(meterOutput) {
                meterOutput.setSampleBufferDelegate(self, queue: meterQueue)
                session.addOutput(meterOutput)
            }
        }
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

    /// Mikrofon düzeyi (~20 Hz), yalnızca gösterge için.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - meterLastEmit >= 0.05, let reading = AudioLevel.measure(sampleBuffer) else { return }
        meterLastEmit = now
        onAudioLevel?(reading)
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
