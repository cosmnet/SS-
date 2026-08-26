import AppKit
import SwiftUI

// MARK: - Model

enum PreviewItem {
    /// Küçük önizleme (tam çözünürlük bellekte tutulmaz), kayıtlı dosya, ölçek.
    /// Düzenleme ve OCR dosyayı gerektiğinde yeniden okur.
    case image(NSImage, URL, CGFloat)
    case video(URL)
}

@MainActor
final class PreviewModel: ObservableObject {
    @Published var item: PreviewItem?
    /// Anlık geri bildirim ("Kopyalandı" gibi)
    @Published var status: String?
    /// Google Drive yükleme durumu (yalnızca görüntü kartı)
    @Published var upload: DriveUploadState?

    var currentURL: URL? {
        switch item {
        case let .image(_, url, _)?: return url
        case let .video(url)?: return url
        case nil: return nil
        }
    }
}

// MARK: - Denetleyici

/// Sağ alttaki çerçevesiz önizleme kartı.
///
/// • Çerçeve/panel kromu yok: yalnızca görüntü, saç teli kontur ve yumuşak gölge.
/// • Görüntüye tıklanınca düzenleyici EKRANIN ORTASINDA açılır; Kaydet
///   aynı dosyanın üzerine yazar (yeni dosya üretmez).
/// • Herhangi bir yere tıklanınca kapanır — sabit bekleme yok.
/// • Fare üstündeyken altta işlem çipleri belirir (Düzenle, Kopyala, OCR, Göster, Sil).
@MainActor
final class PreviewPanelController {
    static let shared = PreviewPanelController()

    let model = PreviewModel()

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var statusTimer: Timer?
    /// Kartın DIŞINDAKİ tıklamaları yakalayan izleyiciler (kendi penceremiz dahil her yer)
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    /// Kapanış animasyonu bittiğinde yakalamayı serbest bırakmak için: bu arada
    /// yeni bir kart gösterildiyse (token değişir) eski kapanış onu silmez.
    private var closeToken = UUID()

    private init() {}

    // MARK: - Göster

    /// - note: Karttaki durum satırı (örn. "Kayıt kesildi…"); nil ise varsayılan metin.
    func show(_ item: PreviewItem, note: String? = nil) {
        close()
        closeToken = UUID()   // önceki kapanışın tamamlanma bloğu artık geçersiz
        model.item = item
        model.status = note
        model.upload = nil

        let size = contentSize(for: item)
        let margin: CGFloat = 16

        // Fare hangi ekrandaysa orada, sağ altta belir
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.minY + margin
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // gölgeyi SwiftUI çiziyor; çift gölge olmasın
        panel.level = .statusBar
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: PreviewCardView(model: model, controller: self))
        panel.contentView = hosting

        // Başlangıç: hafif küçük + saydam
        let finalFrame = panel.frame
        panel.setFrame(finalFrame.insetBy(dx: 12, dy: 12), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        installClickMonitors()
        scheduleDismiss()
    }

    // MARK: - Boyut

    private func contentSize(for item: PreviewItem) -> CGSize {
        switch item {
        case let .image(nsImage, _, _):
            let maxW: CGFloat = 340
            let maxH: CGFloat = 280
            let imageSize = nsImage.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return CGSize(width: 240, height: 180)
            }
            let scale = min(maxW / imageSize.width, maxH / imageSize.height)
            return CGSize(
                width: floor(imageSize.width * scale),
                height: floor(imageSize.height * scale)
            )
        case .video:
            return CGSize(width: 300, height: 64)
        }
    }

    // MARK: - Zamanlayıcılar

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        let seconds = SettingsStore.shared.previewSeconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func pauseDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    func resumeDismiss() {
        scheduleDismiss()
    }

    // MARK: - Kapatma (her yere tıkla)

    private func installClickMonitors() {
        removeClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Uygulama DIŞINDAKİ her tıklama kartı kapatır
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        // Uygulama İÇİNDEKİ tıklamalar: kartın kendisine değilse kapat
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.close()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeClickMonitors()
        guard let panel else { return }
        self.panel = nil
        let frame = panel.frame
        let token = UUID()
        closeToken = token
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame.insetBy(dx: 8, dy: 8), display: true)
        }, completionHandler: { [weak self] in
            // Tamamlanma bloğu ana iş parçacığında çağrılır.
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
                // Tam çözünürlüklü yakalama (Retina'da onlarca MB) kart kapanınca
                // bellekte kalmasın; yeni kart gösterildiyse dokunma.
                guard let self, self.closeToken == token, self.panel == nil else { return }
                self.model.item = nil
                self.model.upload = nil
                self.model.status = nil
            }
        })
    }

    // MARK: - Drive yükleme durumu

    /// Yalnızca kart hâlâ o dosyayı gösteriyorsa uygulanır; yükleme sürerken
    /// kart kendiliğinden kapanmaz.
    func setUploadState(_ state: DriveUploadState, for url: URL) {
        guard model.currentURL == url else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            model.upload = state
        }
        switch state {
        case .uploading:
            pauseDismiss()
        case .done, .failed:
            resumeDismiss()
        }
    }

    func copyDriveLink() {
        guard case let .done(link)? = model.upload else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.absoluteString, forType: .string)
        ClipboardStore.shared.markOwnChange(pasteboard.changeCount)
        flash(L("Drive linki kopyalandı"))
    }

    func openDriveLink() {
        guard case let .done(link)? = model.upload else { return }
        NSWorkspace.shared.open(link)
    }

    // MARK: - İşlemler

    /// Görüntüye tıkla → düzenleyici ekranın ortasında açılır; kaydedince
    /// AYNI DOSYANIN üstüne yazılır.
    func editCurrentImage() {
        guard case let .image(_, url, scale)? = model.item,
              let cgImage = ImageFile.loadCGImage(url) else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        close()
        guard let screen else { return }
        AnnotationEditorController.shared.present(
            image: cgImage,
            on: screen,
            scale: scale,
            anchor: nil   // ekranın ortası
        ) { result in
            guard let result else { return }
            OutputPipeline.overwrite(result, at: url, scale: scale)
        }
    }

    func copy() {
        guard case let .image(_, url, _)? = model.item,
              let data = try? Data(contentsOf: url) else { return }
        let changeCount = OutputPipeline.writeImageToPasteboard(data, fileExtension: url.pathExtension)
        ClipboardStore.shared.markOwnChange(changeCount)   // yeniden kopyalama geçmişe düşmesin
        flash(L("Kopyalandı"))
    }

    func runOCR() {
        guard case let .image(_, url, _)? = model.item,
              let cgImage = ImageFile.loadCGImage(url) else { return }
        pauseDismiss()
        Task {
            let text = try? await OCRService.recognizeText(in: cgImage)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.flash(L("Metin panoya kopyalandı"))
            } else {
                self.flash(L("Metin bulunamadı"))
            }
        }
    }

    func openCurrent() {
        guard let item = model.item else { return }
        switch item {
        case let .image(_, url, _), let .video(url):
            NSWorkspace.shared.open(url)
        }
        close()
    }

    func revealCurrent() {
        guard let item = model.item else { return }
        switch item {
        case let .image(_, url, _), let .video(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        close()
    }

    func deleteCurrent() {
        guard let item = model.item else { return }
        switch item {
        case let .image(_, url, _), let .video(url):
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        close()
    }

    /// Kısa durum yazısı gösterir; ardından kapanma sayacı yeniden başlar.
    func flash(_ text: String) {
        statusTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.15)) {
            model.status = text
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.model.status = nil
                }
                self.resumeDismiss()
            }
        }
    }
}

// MARK: - SwiftUI kart

struct PreviewCardView: View {
    @ObservedObject var model: PreviewModel
    weak var controller: PreviewPanelController?
    /// Pazarlama dışa aktarımında hover çiplerini açık tutar.
    var forceHover = false

    @State private var hovering = false

    var body: some View {
        Group {
            switch model.item {
            case let .image(nsImage, _, _)?:
                imageCard(nsImage)
            case let .video(url)?:
                videoCard(url)
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: Görüntü kartı (çerçevesiz)

    private func imageCard(_ nsImage: NSImage) -> some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5)
                        .padding(-0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .simultaneousGesture(
                    TapGesture().onEnded { controller?.editCurrentImage() }
                )
                .onDrag {
                    if case let .image(_, url, _)? = model.item {
                        return NSItemProvider(object: url as NSURL)
                    }
                    return NSItemProvider()
                }

            // Hover işlem çipleri
            if hovering {
                chipRow
                    .padding(8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Durum bildirimi ("Kopyalandı" gibi) ya da Drive yükleme durumu
            if let status = model.status ?? uploadStatusText {
                VStack {
                    Text(status)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .transition(.opacity)
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
        .onAppear {
            if forceHover { hovering = true }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) {
                hovering = inside || forceHover
            }
            if inside {
                controller?.pauseDismiss()
            } else {
                controller?.resumeDismiss()
            }
        }
    }

    /// Drive yükleme durumunun kart üstündeki metni.
    private var uploadStatusText: String? {
        switch model.upload {
        case .uploading?: return L("Drive'a yükleniyor…")
        case .done?:
            return SettingsStore.shared.driveShareAnyone && SettingsStore.shared.driveCopyLink
                ? L("Drive linki kopyalandı")
                : L("Drive'a yüklendi")
        case .failed?: return L("Drive yüklemesi başarısız")
        case nil: return nil
        }
    }

    private var chipRow: some View {
        HStack(spacing: 2) {
            chip(icon: "pencil.tip.crop.circle", label: L("Düzenle")) { controller?.editCurrentImage() }
            chip(icon: "doc.on.doc", label: L("Kopyala")) { controller?.copy() }
            if case .done? = model.upload {
                chip(icon: "link", label: L("Drive linkini kopyala")) { controller?.copyDriveLink() }
                chip(icon: "arrow.up.right.square", label: L("Google Drive'da aç")) { controller?.openDriveLink() }
            }
            if ProManager.shared.isPro {
                chip(icon: "text.viewfinder", label: "OCR") { controller?.runOCR() }
            } else {
                proChip
            }
            chip(icon: "folder", label: L("Göster")) { controller?.revealCurrent() }
            chip(icon: "trash", label: L("Sil"), tint: .red) { controller?.deleteCurrent() }
            chip(icon: "xmark", label: L("Kapat")) { controller?.close() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            MaterialFill(shape: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
    }

    private var proChip: some View {
        HStack(spacing: 3) {
            SymbolImage(name: "text.viewfinder")
            Text("PRO")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
        }
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.3))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .compatHelp(L("OCR yalnızca Pro'da — Ayarlar'dan aç"))
    }

    private func chip(icon: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolImage(name: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(tint.opacity(0.9))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatHelp(label)
    }

    // MARK: Video kartı

    private func videoCard(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Button {
                controller?.openCurrent()
            } label: {
                SymbolImage(name: "film.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [.red.opacity(0.9), .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            .buttonStyle(.plain)
            .compatHelp(L("Videoyu aç"))

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.status ?? uploadStatusText ?? L("Video kaydedildi"))
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                if case .done? = model.upload {
                    chip(icon: "link", label: L("Drive linkini kopyala")) { controller?.copyDriveLink() }
                    chip(icon: "arrow.up.right.square", label: L("Google Drive'da aç")) { controller?.openDriveLink() }
                }
                chip(icon: "folder", label: L("Finder'da göster")) { controller?.revealCurrent() }
                chip(icon: "trash", label: L("Sil"), tint: .red) { controller?.deleteCurrent() }
                chip(icon: "xmark", label: L("Kapat")) { controller?.close() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            MaterialFill(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
        )
    }
}
