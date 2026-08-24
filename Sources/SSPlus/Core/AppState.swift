import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case selecting(SelectionMode, SelectionStyle)
        case recording

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording): return true
            case let (.selecting(m1, _), .selecting(m2, _)): return m1 == m2
            default: return false
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var recordingSeconds: Int = 0

    private var recorder: ScreenRecorder?
    private var recordingTimer: Timer?

    private init() {}

    var isRecording: Bool { phase == .recording }

    var recordingTimeString: String {
        String(format: "%02d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }

    // MARK: - Ekran görüntüsü akışı

    func beginCapture(_ mode: SelectionMode) {
        guard !isRecording else { return }
        if SelectionOverlayController.shared.isActive {
            SelectionOverlayController.shared.cancel()
            return
        }
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
        let pro = ProManager.shared.isPro
        let ext = settings.videoFormat.lowercased() == "mp4" ? "mp4" : "mov"
        let url = settings.saveFolder.appendingPathComponent(OutputPipeline.fileName(prefix: "SS+ Kayıt", ext: ext))
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)

        let recorder = ScreenRecorder(url: url)
        recorder.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.finishRecordingUI()
                self?.presentError(error)
            }
        }
        do {
            try await recorder.start(
                globalRect: rect,
                screen: screen,
                fps: pro ? settings.fps : min(settings.fps, 30),
                captureAudio: pro && settings.recordAudio,
                showCursor: settings.showCursor
            )
            self.recorder = recorder
            recordingSeconds = 0
            phase = .recording
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.recordingSeconds += 1 }
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
        Task {
            let url = await recorder.stop()
            OutputPipeline.deliverVideo(url: url)
        }
    }

    private func finishRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingSeconds = 0
        phase = .idle
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
        alert.addButton(withTitle: "Tamam")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
