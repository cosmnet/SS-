import AppKit
import ScreenCaptureKit

/// Geliştirici tanılaması — kayıt sessiz çıkıyorsa ScreenCaptureKit'in bu Mac'te gerçekten
/// sistem sesi verip vermediğini gösterir. Uygulamanın kendi ikilisiyle çalıştığı için
/// SS+'ın Ekran Kaydı iznini kullanır; Terminal'e ayrıca izin gerekmez:
///
///     "SS+.app/Contents/MacOS/SSPlus" --audio-probe 5 [--include-self]
///
/// Kayıtla birebir aynı filtre ve akış ayarlarını kurar, N saniye boyunca her yarım saniyede
/// gelen tampon sayısı ile tepe/RMS (dBFS) yazar, sonra özetle çıkar.
/// Çıkış kodu: 0 ses alındı · 1 tamponlar geldi ama tümü sessiz · 2 hata · 3 hiç ses tamponu gelmedi.
@available(macOS 13, *)
@MainActor
enum AudioProbe {
    static func run(seconds: Double, includeSelf: Bool) async -> Int32 {
        setbuf(stdout, nil)
        do {
            let content = try await SCKContent.shareableContent()
            guard let screen = NSScreen.main,
                  let display = SCKContent.scDisplay(for: screen, in: content) else {
                print("hata: ekran bulunamadı")
                return 2
            }
            let filter = SCContentFilter(display: display, excludingWindows: SCKContent.ownWindows(in: content))
            let config = SCStreamConfiguration()
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = !includeSelf
            config.sampleRate = 48_000
            config.channelCount = 2

            let sink = AudioProbeSink()
            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            print("sistem sesi dinleniyor: \(seconds) sn · kendi süreç sesi \(includeSelf ? "dahil" : "hariç") · ekran \(display.width)×\(display.height)")
            try await stream.startCapture()
            let ticks = max(1, Int(seconds * 2))
            for _ in 0..<ticks {
                try? await Task.sleep(nanoseconds: 500_000_000)
                sink.printAndReset()
            }
            try? await stream.stopCapture()
            return sink.printSummary()
        } catch {
            print("hata: \(error)")
            return 2
        }
    }
}

@available(macOS 15, *)
@MainActor
enum RecordProbe {
    /// Gerçek `ScreenRecorder` yolunu sürer: ekranın ortasından küçük bir alanı
    /// sistem sesi + mikrofonla N saniye kaydeder ve her düzey emisyonunu yazar.
    ///     "SS+.app/Contents/MacOS/SSPlus" --record-probe 5
    static func run(seconds: Double) async -> Int32 {
        setbuf(stdout, nil)
        guard let screen = NSScreen.main else { print("hata: ekran yok"); return 2 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssplus-record-probe.mov")
        try? FileManager.default.removeItem(at: url)
        let recorder = ScreenRecorder(url: url)
        var emissions = 0
        var maxPeak: Float = 0
        recorder.onAudioLevel = { reading in
            emissions += 1
            maxPeak = max(maxPeak, reading.peak)
            print(String(format: "emit #%3d  tepe %6.1f dBFS  rms %6.1f dBFS  frames %d",
                         emissions, AudioLevel.decibels(reading.peak), AudioLevel.decibels(reading.rms), reading.frames))
        }
        do {
            let rect = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 150, width: 400, height: 300)
            try await recorder.start(globalRect: rect, screen: screen, fps: 15,
                                     captureAudio: true, captureMicrophone: true, showCursor: false)
            print("kayıt başladı (ses=\(recorder.capturesAudio) mikrofon=\(recorder.capturesMicrophone)); \(seconds) sn konuş…")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let out = try await recorder.stop()
            print("bitti: \(out.path) · emisyon \(emissions) · en yüksek tepe \(String(format: "%.1f", AudioLevel.decibels(maxPeak))) dBFS")
            return emissions == 0 ? 3 : (maxPeak > 0.001 ? 0 : 1)
        } catch {
            print("hata: \(error)")
            return 2
        }
    }
}

@available(macOS 13, *)
private final class AudioProbeSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "ssplus.audioprobe")
    // Aşağıdakiler yalnızca `queue` üzerinde okunur/yazılır.
    private var audioBuffers = 0
    private var videoFrames = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var frames = 0
    private var totalAudioBuffers = 0
    private var maxPeak: Float = 0
    private var formatLogged = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            videoFrames += 1
            return
        }
        guard type == .audio else { return }
        audioBuffers += 1
        totalAudioBuffers += 1
        if !formatLogged {
            formatLogged = true
            print("ses biçimi: \(AudioLevel.formatSummary(of: sampleBuffer))")
        }
        guard let reading = AudioLevel.measure(sampleBuffer) else { return }
        peak = max(peak, reading.peak)
        maxPeak = max(maxPeak, reading.peak)
        sumSquares += Double(reading.rms * reading.rms) * Double(reading.frames)
        frames += reading.frames
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("akış durdu: \(error)")
    }

    func printAndReset() {
        queue.sync {
            let rms = Float(sqrt(sumSquares / Double(max(1, frames))))
            print(String(
                format: "  ses tamponu %3d · video kare %2d · tepe %6.1f dBFS · rms %6.1f dBFS",
                audioBuffers, videoFrames, AudioLevel.decibels(peak), AudioLevel.decibels(rms)
            ))
            audioBuffers = 0
            videoFrames = 0
            peak = 0
            sumSquares = 0
            frames = 0
        }
    }

    /// Özeti yazar ve çıkış kodunu döndürür.
    func printSummary() -> Int32 {
        queue.sync {
            let verdict: String
            let code: Int32
            if totalAudioBuffers == 0 {
                verdict = "HİÇ SES TAMPONU GELMEDİ (izin ya da akış sorunu)"
                code = 3
            } else if maxPeak > 0.001 {
                verdict = "ses alınıyor"
                code = 0
            } else {
                verdict = "tamponlar geldi ama tümü SESSİZ"
                code = 1
            }
            print("toplam ses tamponu \(totalAudioBuffers) · en yüksek tepe \(String(format: "%.1f", AudioLevel.decibels(maxPeak))) dBFS → \(verdict)")
            return code
        }
    }
}
