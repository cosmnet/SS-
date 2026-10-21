import AppKit
import AVFoundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case selecting(SelectionMode, SelectionStyle)
        case recording
        /// Seçim hâli mi? (Ada geçişini yaylı "pop" ile oynatmak için.)
        var isSelecting: Bool {
            if case .selecting = self { return true }
            return false
        }

    }

    @Published var phase: Phase = .idle
    @Published var recordingSeconds: Int = 0
    /// Kayıtta sistem sesi alınıyor mu; ada göstergesi yalnızca o zaman çizilir.
    @Published var recordingAudioActive = false
    /// Ses düzeyi göstergesi: 0…1 (−60…0 dBFS tepe); hızlı yükselir, yavaş iner.
    @Published var audioLevel: Float = 0
    /// Mikrofon da kaydediliyor mu (göstergede mikrofon simgesi görünür).
    @Published var recordingMicActive = false
    /// Bu kayıtta ölçülen en yüksek tepe (doğrusal); sessiz kayıt tanısı için.
    private var audioPeakThisRecording: Float = 0
    private var applyCount = 0
    /// Global kısayol kaydı başarısız olduysa Ayarlar'da gösterilen uyarı.
    @Published var hotkeyWarning: String?

    private var recorder: (any ScreenRecording)?
    private var recordingTimer: Timer?
    private var recordingStart: Date?

    private init() {}

    var isRecording: Bool { phase == .recording }

    var recordingTimeString: String {
        String(format: "%02d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }

    // MARK: - Ekran görüntüsü akışı

    /// Düzenleyici açıkken yeni bir yakalama başlatılmaz: sonuç sessizce
    /// düzenlenmeden aktarılırdı. Kullanıcı önce düzenlemeyi bitirmeli.
    private var editorBlocksCapture: Bool {
        guard AnnotationEditorController.shared.isPresenting else { return false }
        NSSound.beep()
        return true
    }

    func beginCapture(_ mode: SelectionMode) {
        guard !isRecording else { return }
        if SelectionOverlayController.shared.isActive {
            SelectionOverlayController.shared.cancel()
            return
        }
        guard !editorBlocksCapture else { return }
        // İzin yoksa seçim katmanını hiç açma: kullanıcı alanı seçtikten sonra
        // hata almasın.
        guard PermissionManager.ensureScreenCapturePermission() else { return }
        SettingsStore.shared.lastModeRaw = mode.rawValue
        SelectionOverlayController.shared.begin(mode: mode) { [weak self] result in
            guard let result else { return }
            Task { await self?.handleCapture(result) }
        }
    }

    func beginCaptureLastMode() {
        let mode = SelectionMode(rawValue: SettingsStore.shared.lastModeRaw) ?? .rect
        beginCapture(mode)
    }

    func captureFullScreen() {
        guard !isRecording else { return }
        guard !editorBlocksCapture else { return }
        guard PermissionManager.ensureScreenCapturePermission() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        Task { await handleCapture(.rect(screen.frame, screen)) }
    }

    private func handleCapture(_ result: SelectionResult) async {
        do {
            // Overlay'in kapanışının ekrana yansıması için minik gecikme
            try? await Task.sleep(nanoseconds: 60_000_000)
            switch result {
            case let .rect(rect, screen):
                let image = try await CaptureEngine.capture(globalRect: rect, screen: screen)
                route(image, near: rect, on: screen)
            case let .window(id, frame, screen):
                let image = try await CaptureEngine.captureWindow(id: id, fallbackRect: frame, screen: screen)
                route(image, near: frame, on: screen)
            }
        } catch {
            presentError(error)
        }
    }

    /// Ayara göre ya doğrudan aktarır ya da önce yerinde çizim düzenleyicisini açar.
    private func route(_ image: CGImage, near rect: CGRect, on screen: NSScreen) {
        let scale = screen.backingScaleFactor
        guard SettingsStore.shared.editAfterCapture else {
            OutputPipeline.deliverImage(image, scale: scale)
            return
        }
        AnnotationEditorController.shared.present(
            image: image,
            on: screen,
            scale: scale,
            anchor: rect
        ) { result in
            guard let result else { return }   // Vazgeçildi: hiçbir şey aktarılmaz
            OutputPipeline.deliverImage(result, scale: scale)
        }
    }

    // MARK: - Video akışı

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            beginRecordingSelection()
        }
    }

    func beginRecordingSelection() {
        guard !isRecording else { return }
        if SelectionOverlayController.shared.isActive {
            SelectionOverlayController.shared.cancel()
            return
        }
        guard !editorBlocksCapture else { return }
        guard PermissionManager.ensureScreenCapturePermission() else { return }
        SelectionOverlayController.shared.begin(mode: .rect, style: .recording) { [weak self] result in
            guard let self, let result else { return }
            if case let .rect(rect, screen) = result {
                Task { await self.startRecording(rect: rect, screen: screen) }
            }
        }
    }

    private func startRecording(rect: CGRect, screen: NSScreen) async {
        let settings = SettingsStore.shared
        let ext = settings.videoFormat.lowercased() == "mp4" ? "mp4" : "mov"
        let url = settings.saveFolder.appendingPathComponent(OutputPipeline.fileName(prefix: L("SS+ Kayıt"), ext: ext))
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)

        // Mikrofon: ses kaydı açıksa izni iste (tüm sürümler; 15+ ScreenCaptureKit,
        // öncesinde AVFoundation). Reddedilirse kayıt mikrofonsuz sürer.
        var micWanted = false
        if settings.recordAudio {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                micWanted = true
            } else {
                presentMicrophoneDenied()
            }
        }

        let recorder = RecorderFactory.make(url: url)
        recorder.onFailure = { [weak self, weak recorder] error in
            Task { @MainActor in
                guard let self, let recorder else { return }
                self.handleStreamFailure(error, recorder: recorder)
            }
        }
        recorder.onAudioLevel = { [weak self] reading in
            Task { @MainActor in self?.applyAudioLevel(reading) }
        }
        do {
            try await recorder.start(
                globalRect: rect,
                screen: screen,
                fps: settings.fps,
                captureAudio: settings.recordAudio,
                captureMicrophone: micWanted,
                showCursor: settings.showCursor
            )
            self.recorder = recorder
            recordingSeconds = 0
            recordingStart = Date()
            recordingAudioActive = recorder.capturesAudio || recorder.capturesMicrophone
            recordingMicActive = recorder.capturesMicrophone
            audioLevel = 0
            audioPeakThisRecording = 0
            applyCount = 0
            DebugLog.log("kayıt başladı: sistemSesi=\(recorder.capturesAudio) mikrofon=\(recorder.capturesMicrophone)")
            phase = .recording
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStart else { return }
                    let elapsed = Int(Date().timeIntervalSince(start))
                    if elapsed != self.recordingSeconds { self.recordingSeconds = elapsed }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer
        } catch {
            presentError(error)
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        finishRecordingUI()
        Task { await finalize(recorder, interruptedBy: nil) }
    }

    /// Uygulama kapanmadan önce çağrılır: kaydı durdurur ve dosya diske
    /// tamamen yazılana dek BEKLER. Aksi hâlde .mov dosyası oynatılamaz kalır.
    func finishRecordingForTermination() async {
        guard let recorder else { return }
        self.recorder = nil
        finishRecordingUI()
        await finalize(recorder, interruptedBy: nil)
    }

    /// Akış kendi kendine durduğunda (ekran uykusu, kilit, monitör çıkarma…)
    /// o ana kadar alınan kareler KAYBEDİLMEZ: dosya kapatılıp teslim edilir,
    /// ardından kesinti nedeni gösterilir.
    private func handleStreamFailure(_ error: Error, recorder failed: any ScreenRecording) {
        guard let current = recorder, current === failed else { return }
        recorder = nil
        finishRecordingUI()
        Task { await finalize(failed, interruptedBy: error) }
    }

    private func finalize(_ recorder: any ScreenRecording, interruptedBy: Error?) async {
        do {
            let url = try await recorder.stop()
            OutputPipeline.deliverVideo(
                url: url,
                note: interruptedBy == nil ? nil : L("Kayıt kesildi; buraya kadarki kısım kaydedildi")
            )
        } catch {
            presentError(error)
            return
        }
        if let interruptedBy {
            presentError(interruptedBy)
        }
    }

    private func finishRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStart = nil
        recordingSeconds = 0
        if recordingAudioActive, audioPeakThisRecording < 0.001 {
            NSLog("SS+ kayıt: ses açıktı ama kayıt boyunca hiç ses ölçülmedi (tepe %.5f).", audioPeakThisRecording)
        }
        if recordingAudioActive {
            DebugLog.log(String(format: "kayıt bitti: en yüksek tepe %.4f · applyAudioLevel çağrısı %d", audioPeakThisRecording, applyCount))
        }
        recordingAudioActive = false
        recordingMicActive = false
        audioLevel = 0
        phase = .idle
    }

    private func applyAudioLevel(_ reading: AudioLevelReading) {
        guard isRecording else { return }
        let value = AudioLevel.meterValue(peak: reading.peak)
        applyCount += 1
        if applyCount % 20 == 1 {
            DebugLog.log(String(format: "applyAudioLevel #%d değer %.2f gösterge %.2f", applyCount, value, audioLevel))
        }
        // Hızlı atak, yavaş bırakma: gösterge titremesin.
        audioLevel = value >= audioLevel ? value : max(value, audioLevel - 0.08)
        audioPeakThisRecording = max(audioPeakThisRecording, reading.peak)
    }

    /// Mikrofon izni reddedildiğinde bilgilendirir; kayıt mikrofonsuz sürer.
    private func presentMicrophoneDenied() {
        let alert = NSAlert()
        alert.messageText = L("SS+ mikrofona erişemiyor")
        alert.informativeText = L("Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon bölümünde SS+ anahtarını aç. Kayıt mikrofon olmadan sürecek.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Sistem Ayarları'nı Aç"))
        alert.addButton(withTitle: L("Tamam"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hata

    func presentError(_ error: Error) {
        // İzin hatası tek elden yönetilir: oturumda yalnızca bir kez, yeniden
        // başlatma seçeneğiyle birlikte gösterilir.
        if case CaptureError.permissionDenied = error {
            PermissionManager.presentPermissionAlert()
            return
        }

        let alert = NSAlert()
        alert.messageText = "SS+"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Tamam"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
