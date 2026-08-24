import AppKit
import CoreGraphics

/// Ekran kaydı (TCC) izninin tek elden yönetimi.
///
/// Amaç, "sürekli aynı ayar penceresi çıkıyor" şikâyetini kökünden bitirmek:
///
///  • Sistem izin penceresi (`CGRequestScreenCaptureAccess`) **kurulum başına en
///    fazla bir kez** tetiklenir. macOS zaten ikinci kez sormaz; bayrak, TCC
///    sıfırlansa bile uygulamanın ısrar etmemesini garantiler.
///  • Kendi Türkçe uyarımız **oturum başına en fazla bir kez** görünür — eskiden
///    her başarısız yakalama denemesinde yeniden açılıyordu.
///  • İzin verildikten sonra `CGPreflightScreenCaptureAccess()` çalışan süreç
///    için `false` dönmeye devam eder; bu yüzden uyarıda yeniden başlatma
///    seçeneği sunulur. Yeniden başlatma ASLA kendiliğinden yapılmaz (sonsuz
///    döngü riski), yalnızca kullanıcı düğmeye basarsa.
@MainActor
enum PermissionManager {

    /// Uyarı bu oturumda gösterildi mi? (Süreç yeniden başlayınca sıfırlanır.)
    private static var alertShownThisSession = false
    /// Uyarı şu anda ekranda mı? İç içe modal açılmasını engeller.
    private static var alertOnScreen = false

    // MARK: - Sorgu

    /// Ekran kaydı izni bu süreç için geçerli mi?
    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Açılış

    /// Uygulama açılışında bir kez çağrılır.
    ///
    /// İzin varsa hiçbir şey yapmaz. Yoksa sistem penceresini tetikler.
    /// `CGRequestScreenCaptureAccess` yalnızca TCC kaydı "belirsiz" durumdayken
    /// pencere gösterir; reddedilmiş/verilmiş durumda sessizce döner. Eski
    /// sürümdeki "kurulum başına bir kez" bayrağı, TCC sıfırlandıktan sonra
    /// sistemin bir daha SORMAMASI gibi bir kilitlenmeye yol açıyordu — bu
    /// yüzden izin yoksa her açılışta istenir. Pencere ayrı bir süreç
    /// tarafından çizilir ve çağrı anında geri döner; ana iş parçacığı
    /// bloke edilmez.
    static func prepareAtLaunch() {
        guard !hasScreenCapturePermission else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Kapı

    /// Yakalama/kayıt başlamadan önce çağrılır.
    ///
    /// İzin varsa `true` döner. Yoksa oturumun İLK denemesinde açıklayıcı uyarıyı
    /// gösterir, sonraki denemelerde yalnızca kısa bir uyarı sesi verir.
    @discardableResult
    static func ensureScreenCapturePermission() -> Bool {
        if hasScreenCapturePermission {
            // İzin (yeniden başlatma sonrası) geldiyse uyarı hakkını geri ver.
            alertShownThisSession = false
            return true
        }
        presentPermissionAlert()
        return false
    }

    /// Ekran kaydı izni uyarısı. Oturumda yalnızca bir kez açılır.
    static func presentPermissionAlert() {
        guard !alertOnScreen else { return }
        guard !alertShownThisSession else {
            NSSound.beep()
            return
        }
        alertShownThisSession = true
        alertOnScreen = true
        defer { alertOnScreen = false }

        let alert = NSAlert()
        alert.messageText = "SS+ için ekran kaydı izni gerekiyor"
        alert.informativeText = """
        Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı listesinde SS+ \
        anahtarını AÇIK duruma getir, sonra uygulamayı TAMAMEN kapatıp yeniden aç. \
        macOS, verilen izni ancak uygulama yeniden başlatıldığında tanır.

        Anahtar açık görünmesine rağmen çalışmıyorsa kayıt bozuk demektir \
        (yeniden derleme sonrası imza değişimi buna yol açar). \
        "İzni Onar ve Yeniden Başlat" eski kaydı silip uygulamayı yeniden \
        başlatır; macOS bu kez temiz bir izin penceresi gösterir.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "İzni Onar ve Yeniden Başlat")
        alert.addButton(withTitle: "Sistem Ayarları'nı Aç")
        alert.addButton(withTitle: "Vazgeç")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetPermissionRecordAndRelaunch()
        case .alertSecondButtonReturn:
            openScreenRecordingSettings()
        default:
            break
        }
    }

    // MARK: - Onarım

    /// Bozuk TCC kaydını silip uygulamayı yeniden başlatır.
    ///
    /// Yeniden derlenen (veya imza kimliği değişen) uygulamalar için Sistem
    /// Ayarları'ndaki eski anahtar "açık" görünse bile geçersizdir ve kullanıcı
    /// hiçbir şekilde izin veremez hâle gelir. `tccutil reset` kaydı siler;
    /// sonraki açılışta sistem izin penceresi yeniden belirir.
    static func resetPermissionRecordAndRelaunch() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ssplus.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        try? task.run()
        task.waitUntilExit()
        relaunch()
    }

    // MARK: - Eylemler

    /// Sistem Ayarları'nı doğrudan Ekran Kaydı bölümünde açar.
    ///
    /// macOS 26'da bölümün yeni kimliği `com.apple.settings.PrivacySecurity.extension`;
    /// eski `com.apple.preference.security` adresi hâlâ çalıştığı için yedek olarak
    /// denenir.
    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    /// Uygulamayı kapatıp yeniden açar.
    ///
    /// Yeni örnek, eski süreç TAMAMEN kapandıktan sonra başlatılır: `open -n`
    /// hâlâ çalışan bir örnek varken yalnızca onu öne getirebilir ve yeniden
    /// başlatma gerçekleşmez. Bekleme işi kabuğa devredilir, böylece biz
    /// çıktıktan sonra da sürer.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        let launchCommand: String
        if bundleURL.pathExtension == "app" {
            launchCommand = "/usr/bin/open -n \(shellQuoted(bundleURL.path))"
        } else if let executable = Bundle.main.executablePath {
            // Paketlenmemiş çalıştırma (swift run): ikiliyi doğrudan başlat.
            launchCommand = "\(shellQuoted(executable)) &"
        } else {
            NSApp.terminate(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; \(launchCommand)",
        ]
        try? task.run()

        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
