import AppKit

/// Temiz kurulum için kaldırma yardımcısı.
///
/// macOS, gizlilik izinlerini (Ekran Kaydı vb.) paket kimliğine bağlı TCC
/// kayıtlarında tutar; uygulamayı çöpe atmak bu kayıtları silmez. Buradaki
/// "izinleri sıfırla" `tccutil reset All <bundle id>` çalıştırır: Sistem
/// Ayarları'ndaki SS+ satırları kaybolur ve bir sonraki açılışta izin
/// sıfırdan istenir. "Tamamen kaldır" buna ek olarak ayarları, Google
/// oturumunu, pano arşivini siler ve uygulamayı Çöp'e taşır.
@MainActor
enum Uninstaller {

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.ssplus.app" }

    /// Ayarlar'daki düğme bunu çağırır.
    static func present() {
        let alert = NSAlert()
        alert.messageText = L("SS+ kaldırılsın mı?")
        alert.informativeText = L("""
        İzinleri sıfırla: Sistem Ayarları → Gizlilik ve Güvenlik'teki SS+ kayıtları \
        (Ekran Kaydı vb.) silinir ve uygulama kapanır; bir sonraki açılışta izin yeniden istenir. \
        Ayarların ve dosyaların korunur.

        Tamamen kaldır: Buna ek olarak tüm ayarlar, Google oturumu ve pano arşivi silinir, \
        uygulama Çöp'e taşınır. Kaydettiğin ekran görüntüleri ve videolar silinmez.
        """)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("İzinleri sıfırla ve çık"))
        alert.addButton(withTitle: L("Tamamen kaldır"))
        alert.addButton(withTitle: L("Vazgeç"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetPermissions()
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            removeEverything()
            NSApp.terminate(nil)
        default:
            break
        }
    }

    /// TCC kayıtlarını siler (kullanıcı düzeyi servisler için yönetici şifresi gerekmez).
    static func resetPermissions() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", bundleID]
        try? task.run()
        task.waitUntilExit()
    }

    /// İzinler + ayarlar + Google oturumu + pano arşivi + uygulama paketi.
    static func removeEverything() {
        resetPermissions()

        // Google belirteçleri (Anahtar Zinciri) ve Drive klasör kimliği
        GoogleAuth.shared.forgetLocally()

        // Pano arşivi (~/Library/Application Support/SSPlus)
        ClipboardStore.shared.clear()
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("SSPlus", isDirectory: true))
        }

        // Tüm ayarlar
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        // Uygulama paketi → Çöp (paketlenmemiş `swift run` çalışmasında dokunma)
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        }
    }
}
