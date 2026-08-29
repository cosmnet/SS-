import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// SS+'ın ihtiyaç duyduğu bütün izinleri TEK ekranda toplayan pencere.
///
/// Eskiden izinler tek tek, farklı anlarda ve sistem diliyle soruluyordu:
/// açılışta ekran kaydı için bir sistem penceresi, çok sonra mikrofon için
/// bir başkası. Kullanıcı ne istendiğini ve neden istendiğini göremediği için
/// bu akış ürkütücüydü.
///
/// Buradaki yaklaşım:
///  • Hepsi bir listede, her biri **neden** gerektiğiyle birlikte.
///  • Zorunlu / isteğe bağlı ayrımı açıkça yazılır; hiçbiri dayatılmaz.
///  • Durum canlı güncellenir: kullanıcı Sistem Ayarları'nda anahtarı açınca
///    satır beklemeden yeşile döner.
///  • Kapatmak serbesttir ("Şimdilik geç"); uygulama izinsiz de açılır,
///    yalnızca ilgili özellik çalışmaz.
enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return L("Ekran Kaydı")
        case .microphone:      return L("Mikrofon")
        }
    }

    var icon: String {
        switch self {
        case .screenRecording:
            // ".badge.record" çeşidi SF Symbols 4 (macOS 13+); 11–12'de boş çiziliyordu.
            if #available(macOS 13, *) { return "rectangle.dashed.badge.record" }
            return "rectangle.dashed"
        case .microphone:      return "mic.fill"
        }
    }

    /// Bu izin olmadan uygulamanın temel işi yapılamıyor mu?
    var isRequired: Bool {
        switch self {
        case .screenRecording: return true
        case .microphone:      return false
        }
    }

    /// Kullanıcıya "neden" cevabı. Teknik değil, somut olmalı.
    var reason: String {
        switch self {
        case .screenRecording:
            return L("Ekran görüntüsü ve video alabilmek için. macOS, ekranı okuyan her uygulamadan bunu ayrıca ister.")
        case .microphone:
            return L("Yalnızca video kaydında \"Mikrofonu kaydet\" seçeneğini açarsan kullanılır. Kapalıyken mikrofona hiç dokunulmaz.")
        }
    }

    var status: PermissionState {
        switch self {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .needed
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .granted
            case .notDetermined: return .needed
            default:             return .blocked
            }
        }
    }

    /// Satırdaki düğmeye basıldığında yapılacak iş.
    ///
    /// "Belirsiz" durumdayken sistem penceresini tetiklemek doğru davranıştır;
    /// kullanıcı daha önce reddettiyse macOS bir daha sormaz, o yüzden doğrudan
    /// Sistem Ayarları'nın ilgili bölümü açılır.
    @MainActor
    func request() {
        switch self {
        case .screenRecording:
            if status == .granted { return }
            // Çağrı ayrı bir süreçte pencere çizer ve hemen döner.
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = CGRequestScreenCaptureAccess()
                if !granted {
                    DispatchQueue.main.async { PermissionManager.openScreenRecordingSettings() }
                }
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            case .authorized:
                break
            default:
                PermissionManager.openMicrophoneSettings()
            }
        }
    }
}

enum PermissionState {
    /// Verilmiş.
    case granted
    /// Henüz istenmemiş ya da verilmemiş — sistem penceresi hâlâ gösterilebilir.
    case needed
    /// Kullanıcı daha önce reddetmiş; yalnızca Sistem Ayarları'ndan açılabilir.
    case blocked

    var isGranted: Bool { self == .granted }
}

// MARK: - Pencere

@MainActor
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionsWindowController()

    private var window: NSWindow?

    /// Açılışta yalnızca gerçekten gerekliyse gösterilir.
    ///
    /// Ölçüt: zorunlu izinlerden biri eksik. Her açılışta değil — kullanıcı bir
    /// kez "şimdilik geç" derse, izin yine eksik olsa bile pencere kendiliğinden
    /// açılmaz; yakalama denendiğinde açılır. Amaç, uygulamayı her başlatışta
    /// aynı ekranla karşılaşmamak.
    func showIfNeededAtLaunch() {
        let key = "permissionsIntroShown"
        let alreadyShown = UserDefaults.standard.bool(forKey: key)
        let allRequiredGranted = PermissionKind.allCases
            .filter(\.isRequired)
            .allSatisfy { $0.status.isGranted }
        guard !allRequiredGranted, !alreadyShown else { return }
        show()
        // Bayrak pencere gerçekten gösterildikten SONRA yazılır: show() sırasında
        // çökülürse (1.6.6'daki yinelenen yerelleştirme anahtarı gibi) tek seferlik
        // tanıtım boşa yanmasın.
        UserDefaults.standard.set(true, forKey: key)
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Kök görünüme sabit genişlik verilir: fittingSize, SwiftUI'nin "ideal"
        // boyutunu genişlik sınırı OLMADAN ölçer (metinler tek satıra açılır,
        // ~855 pt) ve boy olduğundan kısa çıkar; başlık ile Bitti/Geç düğmeleri
        // pencerenin dışında kalıyordu. Sabit genişlikte metinler sarılır,
        // boy doğru ölçülür.
        let width: CGFloat = 520
        let hosting = NSHostingController(rootView: PermissionsView().frame(width: width))

        // Boy içeriğe göre: izin verilmişken satırlar kısadır, eksikken
        // yeniden başlatma uyarısı da eklenir. Sabit boy, ilk durumda
        // pencerenin yarısını boş bırakıyordu. Ölçüm pencere kurulmadan
        // ÖNCE yapılır (aşağıdaki sizingOptions notuna bakınız).
        hosting.view.setFrameSize(NSSize(width: width, height: 1))
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize.height
        let height = min(max(fitted, 300), 640)

        // macOS 13+: NSHostingController, SwiftUI'nin "ideal" boyutunu pencereye
        // intrinsic/min/maks kısıtı olarak uygular; bu pencere açıldıktan saniyeler
        // sonra binlerce punto boya büyüyor, Bitti/Geç düğmeleri ekranın dışında
        // kalıyordu (macOS 26'da ölçüldü: 520×6872). Ölçüm bittikten sonra izleme
        // kapatılır; boy aşağıda elle sabitlenir.
        if #available(macOS 13, *) {
            hosting.sizingOptions = []
        }

        let window = NSWindow(contentViewController: hosting)
        window.title = L("SS+ İzinleri")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Esc ile kapansın: kullanıcı bir izin penceresinde sıkıştığını
        // hissetmemeli. `.closable` yalnızca ⌘W ve düğmeyi verir.
        // Yerel gözlemci sürecin TÜM pencerelerinin tuşlarını görür; yalnızca bu
        // pencere hedefse yut, Ayarlar ya da seçim katmanındaki Esc'e karışma.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, event.window === self.window else { return event }   // 53 = Esc
            self.close()
            return nil
        }
    }

    /// Esc tuşu gözlemcisi; pencere kapanınca kaldırılır.
    private var escapeMonitor: Any?

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        window = nil
    }
}

// MARK: - Görünüm

struct PermissionsView: View {
    /// Sistem Ayarları'nda yapılan değişikliği yakalamak için düzenli yoklama.
    /// TCC değişimi için bildirim yayını yoktur; ucuz bir sorgu olduğu için
    /// saniyede bir okumak sorun değildir.
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Ekran kaydı izni bu süreç için geçerli değilse yeniden başlatma uyarısı
    /// gösterilir.
    ///
    /// `CGPreflightScreenCaptureAccess()` çalışan süreç için, kullanıcı Sistem
    /// Ayarları'nda anahtarı açtıktan SONRA bile `false` dönmeye devam eder —
    /// yani "izin yeni verildi" durumunu süreç içinden ayırt etmenin bir yolu
    /// yoktur. Bu yüzden izin eksik göründüğü sürece yeniden başlatma yolu
    /// açık tutulur: kullanıcı izni verdiyse tek eksik zaten budur.
    private var needsRestart: Bool {
        !PermissionKind.screenRecording.status.isGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 10) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, tick: tick)
                }
            }
            .padding(.horizontal, 22)

            if needsRestart {
                restartNotice
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
            }

            Spacer(minLength: 14)

            footer
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onReceive(timer) { _ in tick &+= 1 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                SSPlusLogoView(size: 26)
                Text(L("SS+ birkaç izin istiyor"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            Text(L("Hepsi bu ekranda — tek tek karşına çıkmayacak. SS+ hiçbir veriyi dışarı göndermez; her izin yalnızca onu kullandığın özellik için gerekir ve istediğin zaman geri alabilirsin."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var restartNotice: some View {
        HStack(spacing: 10) {
            SymbolImage(name: "arrow.clockwise.circle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("İzni verdikten sonra yeniden başlat"))
                    .font(.system(size: 12, weight: .semibold))
                Text(L("macOS ekran kaydı iznini ancak uygulama yeniden başlatıldığında tanır. Anahtarı açtıysan tek eksik bu."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L("Yeniden Başlat")) { PermissionManager.relaunch() }
                .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    /// `keyboardShortcut` macOS 11 ister; 10.15'te düğme kısayolsuz kalır.
    @ViewBuilder
    private var doneButton: some View {
        if #available(macOS 11, *) {
            Button(L("Bitti")) { PermissionsWindowController.shared.close() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button(L("Bitti")) { PermissionsWindowController.shared.close() }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L("Gizlilik politikası")) { NSWorkspace.shared.open(SiteLinks.privacy) }
                .buttonStyle(.link)
                .font(.system(size: 11))
            // Anahtar "açık" göründüğü hâlde izin çalışmıyorsa (yeniden derleme
            // sonrası imza değişimi) tek çözüm TCC kaydını silmektir.
            Button(L("İzin çalışmıyor mu?")) { PermissionManager.presentRepairAlert() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .compatHelp(L("Sistem Ayarları'nda anahtar açık görünmesine rağmen yakalama çalışmıyorsa eski izin kaydını siler."))
            Spacer()
            Button(L("Şimdilik geç")) { PermissionsWindowController.shared.close() }
            doneButton
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .padding(.top, 6)
    }
}

/// Tek izin satırı: simge, ad, gerekçe, durum rozeti ve eylem düğmesi.
private struct PermissionRow: View {
    let kind: PermissionKind
    /// Yalnızca görünümü tazelemek için; değeri kullanılmaz.
    let tick: Int

    private var state: PermissionState { kind.status }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolImage(name: kind.icon)
                .font(.system(size: 16))
                .foregroundColor(state.isGranted ? .green : .accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((state.isGranted ? Color.green : Color.accentColor).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                    badge
                }
                Text(kind.reason)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            action
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    @ViewBuilder
    private var badge: some View {
        let (text, color): (String, Color) = kind.isRequired
            ? (L("Gerekli"), .orange)
            : (L("İsteğe bağlı"), .secondary)
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundColor(color)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .granted:
            HStack(spacing: 4) {
                SymbolImage(name: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(L("Verildi"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        case .needed:
            Button(L("İzin ver")) { kind.request() }
                .controlSize(.small)
        case .blocked:
            Button(L("Ayarlarda aç")) { kind.request() }
                .controlSize(.small)
        }
    }
}
