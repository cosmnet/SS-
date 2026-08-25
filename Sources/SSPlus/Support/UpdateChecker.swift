import AppKit

/// Sürüm denetimi: sitedeki `version.json` ile paketin sürümünü karşılaştırır.
///
/// - Elle denetim: her durumda sonuç gösterilir ("Güncelsin!" ya da yeni sürüm).
/// - Otomatik denetim: günde en çok bir kez, yalnızca yeni sürüm varsa uyarır;
///   ağ hataları sessizce yutulur.
@MainActor
enum UpdateChecker {
    struct Info: Decodable {
        let version: String
        let build: Int?
        let download: String
        let notes: String?
    }

    /// Paketten okunan sürüm; paketlenmemiş (`swift run`) çalışmada nil.
    static var bundleVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Karşılaştırma için: paketlenmemişse "0" (her yayın daha yeni sayılır).
    static var currentVersion: String { bundleVersion ?? "0" }

    static var currentBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "1.5.0 (19)" gibi görüntü metni; paketlenmemişse "dev".
    static var displayVersion: String {
        guard let version = bundleVersion else { return "dev" }
        if let build = currentBuild, !build.isEmpty { return "\(version) (\(build))" }
        return version
    }

    static func checkAutomaticallyIfDue() {
        // swift run: pakette sürüm yok; her açılışta "yeni sürüm" diye uyarma.
        guard bundleVersion != nil else { return }
        let settings = SettingsStore.shared
        guard settings.checkUpdatesAutomatically else { return }
        guard Date().timeIntervalSince(settings.lastUpdateCheck) > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    static func check(userInitiated: Bool) async {
        do {
            var request = URLRequest(url: SiteLinks.versionJSON)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.compatData(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
            let info = try JSONDecoder().decode(Info.self, from: data)
            SettingsStore.shared.lastUpdateCheck = Date()
            if isNewer(info.version, than: currentVersion) {
                presentAvailable(info)
            } else if userInitiated {
                presentUpToDate()
            }
        } catch {
            if userInitiated { presentError(error) }
        }
    }

    /// Bileşen bileşen sayısal karşılaştırma (bkz. VersionCompare): "1.10.0" > "1.9.0",
    /// "1.5" == "1.5.0", "1.5.1-beta" → 1.5.1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        VersionCompare.isNewer(candidate, than: current)
    }

    // MARK: Diyaloglar

    private static func presentAvailable(_ info: Info) {
        let alert = NSAlert()
        alert.messageText = L("Yeni sürüm hazır: SS+ %@", info.version)
        alert.informativeText = L("Şu anki sürüm %@. İndirip DMG'yi Applications klasörüne sürükleyerek güncelleyebilirsin.", displayVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("İndir"))
        alert.addButton(withTitle: L("Sürüm geçmişi"))
        alert.addButton(withTitle: L("Daha sonra"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: info.download) ?? SiteLinks.releases)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(info.notes.flatMap(URL.init) ?? SiteLinks.changelog)
        default:
            break
        }
    }

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = L("Güncelsin!")
        alert.informativeText = L("SS+ %@ şu anda en yeni sürüm.", displayVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Tamam"))
        alert.addButton(withTitle: L("Sürüm geçmişi"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(SiteLinks.changelog)
        }
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Güncelleme denetlenemedi")
        alert.informativeText = L("Sunucuya ulaşılamadı: %@", error.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Tamam"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
