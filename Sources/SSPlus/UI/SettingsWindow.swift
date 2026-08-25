import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Pencere denetleyicisi

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("SS+ Ayarları")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.sharingType = .none   // kayıt sırasında açılırsa videoya girmesin
        window.delegate = WindowKeeper.shared
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

/// Ayarlar penceresi kapatılınca menü çubuğu moduna dön.
final class WindowKeeper: NSObject, NSWindowDelegate {
    static let shared = WindowKeeper()

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Ana görünüm

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Genel"
        case output = "Kayıt & Çıktı"
        case shortcuts = "Kısayollar"
        case pro = "Pro"

        var id: String { rawValue }
    }

    @State private var selectedTab: Tab

    init(tab: Tab = .general) {
        _selectedTab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Üstte yerel sekmeler
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(L(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general: GeneralTab()
                    case .output: OutputTab()
                    case .shortcuts: ShortcutsTab()
                    case .pro: ProTab()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Ortak parçalar

/// Başlık kutunun DIŞINDA (ikon + ad), içerik açık gri yuvarlatılmış panelde.
private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

/// Pro'ya özel bir denetimin yanına konan küçük rozet.
private struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.linearGradient(
                colors: [.pink, .purple],
                startPoint: .leading,
                endPoint: .trailing
            )))
            .foregroundStyle(.white)
    }
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

private func fieldLabel(_ text: String) -> some View {
    Text(text + ":")
        .font(.system(size: 13))
}

private func rowDivider() -> some View {
    Divider().opacity(0.6)
}

private var appVersion: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    return build.map { "\(short) (\($0))" } ?? short
}

// MARK: - Girişte başlat

/// `SMAppService` ile oturum açılışında başlatma. Paketlenmemiş (`swift run`)
/// çalışmada kayıt başarısız olur; anahtar o zaman devre dışı görünür.
@MainActor
private final class LoginItem: ObservableObject {
    static let shared = LoginItem()
    @Published var enabled: Bool
    @Published var error: String?

    private init() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Genel

struct GeneralTab: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var login = LoginItem.shared

    var body: some View {
        SettingsSection(title: L("Genel"), icon: "gearshape") {
            HStack(spacing: 16) {
                Toggle(L("Girişte başlat"), isOn: Binding(
                    get: { login.enabled },
                    set: { login.set($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!login.available)
                Spacer()
                fieldLabel(L("Dil"))
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            if let error = login.error {
                caption(error)
            }
        }

        SettingsSection(title: L("Yakalama"), icon: "camera.viewfinder") {
            HStack(spacing: 16) {
                Toggle(L("Yakalama sonrası düzenleyiciyi aç"), isOn: $settings.editAfterCapture)
                    .toggleStyle(.checkbox)
                Spacer()
                Toggle(L("Kopyalama sesi çal"), isOn: $settings.playSound)
                    .toggleStyle(.checkbox)
            }
            rowDivider()
            HStack(spacing: 10) {
                Toggle(L("Önizleme kartını göster"), isOn: $settings.showPreview)
                    .toggleStyle(.checkbox)
                Picker("", selection: $settings.previewSeconds) {
                    ForEach([2.0, 3.0, 5.0, 8.0, 10.0, 15.0], id: \.self) { s in
                        Text(L("%d sn", Int(s))).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .disabled(!settings.showPreview)
                Spacer()
                Toggle(L("Ada'yı (Island) boşta göster"), isOn: $settings.islandEnabled)
                    .toggleStyle(.checkbox)
            }
        }

        SettingsSection(title: L("Pano geçmişi"), icon: "doc.on.clipboard") {
            HStack(spacing: 16) {
                Toggle(L("Pano geçmişini tut"), isOn: $settings.clipboardHistoryEnabled)
                    .toggleStyle(.checkbox)
                Toggle(L("Çıkışta geçmişi sil"), isOn: $settings.clearClipboardHistoryOnQuit)
                    .toggleStyle(.checkbox)
                    .disabled(!settings.clipboardHistoryEnabled)
                Spacer()
                Button(L("Geçmişi şimdi temizle")) { ClipboardStore.shared.clear() }
                    .controlSize(.small)
                    .disabled(!settings.clipboardHistoryEnabled)
            }
            caption(L("Açıkken kopyaladığın son 10 metin ve görsel adada ve menü panelinde listelenir. Bunlar diske yazılır: ~/Library/Application Support/SSPlus/Clipboard. Şifre yöneticilerinin gizli işaretlediği içerik hiçbir zaman kaydedilmez."))
        }

        SettingsSection(title: L("Hakkında"), icon: "person.crop.circle") {
            HStack(alignment: .center, spacing: 22) {
                VStack(spacing: 6) {
                    SSPlusLogoView(size: 72)
                    Text("SS+")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(appVersion)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 120)
                VStack(alignment: .leading, spacing: 10) {
                    caption(L("macOS için hafif ekran yakalama: ada arayüzü, yerinde düzenleme, video kaydı ve isteğe bağlı Google Drive paylaşımı."))
                    HStack(spacing: 8) {
                        Button(L("Kaynak kodu (GitHub)")) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/cosmnet/SS-")!)
                        }
                        Button(L("Kaldır / İzinleri sıfırla…")) { Uninstaller.present() }
                    }
                    .controlSize(.small)
                    caption(L("İzin sorunlarında ya da temiz kurulum için: macOS'taki SS+ izin kayıtlarını (Ekran Kaydı vb.) siler. İstersen ayarları ve Google oturumunu da kaldırıp uygulamayı Çöp'e taşır."))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Kayıt & Çıktı

struct OutputTab: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var auth = GoogleAuth.shared
    @State private var driveError: String?
    @State private var driveBusy = false

    var body: some View {
        SettingsSection(title: L("Konum"), icon: "externaldrive") {
            HStack(spacing: 8) {
                fieldLabel(L("Klasör"))
                TextField("", text: $settings.saveFolderPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button(L("Değiştir…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.saveFolderPath = url.path
                    }
                }
                .controlSize(.small)
            }
        }

        SettingsSection(title: L("Görüntü"), icon: "photo") {
            HStack(spacing: 16) {
                fieldLabel(L("Format"))
                Picker("", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                Toggle(L("Görüntüleri panoya da kopyala"), isOn: $settings.copyToClipboard)
                    .toggleStyle(.checkbox)
            }
            rowDivider()
            HStack(spacing: 16) {
                Toggle(L("İmleci dahil et"), isOn: $settings.showCursor)
                    .toggleStyle(.checkbox)
                Toggle(L("Akıllı pencere sezme"), isOn: $settings.smartWindowDetect)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            caption(L("Alan modunda fare pencere üstündeyken tıklamak o pencereyi yakalar."))
        }

        SettingsSection(title: L("Video"), icon: "record.circle") {
            HStack(spacing: 14) {
                fieldLabel(L("Kare hızı"))
                FrameRateButton(fps: 30)
                FrameRateButton(fps: 60)
                if !pro.isPro { ProBadge() }
                Spacer()
                fieldLabel(L("Kap"))
                Picker("", selection: $settings.videoFormat) {
                    Text("MOV").tag("mov")
                    Text("MP4").tag("mp4")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            rowDivider()
            HStack(spacing: 14) {
                fieldLabel(L("Kodek"))
                Picker("", selection: $settings.videoCodec) {
                    Text("H.264").tag("h264")
                    Text("HEVC").tag("hevc")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .disabled(!pro.isPro)
                fieldLabel(L("Bit hızı"))
                Picker("", selection: $settings.videoBitrateMbps) {
                    Text(L("Otomatik")).tag(0)
                    Text("8 Mb/s").tag(8)
                    Text("16 Mb/s").tag(16)
                    Text("32 Mb/s").tag(32)
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(!pro.isPro)
                Spacer()
                Toggle(L("Sistem sesini kaydet"), isOn: $settings.recordAudio)
                    .toggleStyle(.checkbox)
                    .disabled(!pro.isPro)
                if !pro.isPro { ProBadge() }
            }
            if !pro.isPro {
                caption(L("Pro olmadan kayıt 30 fps, H.264 ve otomatik bit hızıyla yapılır."))
            }
        }

        SettingsSection(title: "Google Drive", icon: "icloud.and.arrow.up") {
            driveSection
        }
    }

    // MARK: Google Drive

    @ViewBuilder
    private var driveSection: some View {
        if !auth.isConfigured {
            caption(L("Bu derlemede Google istemci kimliği yok (Resources/GoogleOAuth.plist). Kurulum için README'ye bak."))
        } else if !auth.isSignedIn {
            HStack(spacing: 10) {
                Button(L("Google ile oturum aç")) { signInToGoogle() }
                    .disabled(auth.isSigningIn)
                if auth.isSigningIn {
                    ProgressView().controlSize(.small)
                    caption(L("Tarayıcıda Google onayı bekleniyor…"))
                }
                Spacer()
            }
            caption(L("Kendi Google hesabınla oturum açarsın; belirteçler yalnızca bu Mac'in Anahtar Zinciri'nde tutulur, SS+ geliştiricisinin Drive'ına erişimi olmaz."))
            if let driveError {
                Label(driveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill.badge.checkmark")
                    .foregroundStyle(.green)
                Text(auth.accountEmail ?? "")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(L("Çıkış yap")) { Task { await auth.signOut() } }
                    .controlSize(.small)
            }
            rowDivider()
            HStack(spacing: 16) {
                Toggle(L("Ekran görüntülerini Drive'a yükle"), isOn: $settings.driveUploadEnabled)
                    .toggleStyle(.checkbox)
                Toggle(L("Video kayıtlarını da yükle"), isOn: $settings.driveUploadVideos)
                    .toggleStyle(.checkbox)
                    .disabled(!settings.driveUploadEnabled)
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle(L("Bağlantıyla herkese açık paylaş"), isOn: $settings.driveShareAnyone)
                    .toggleStyle(.checkbox)
                Toggle(L("Linki panoya kopyala"), isOn: $settings.driveCopyLink)
                    .toggleStyle(.checkbox)
                    .disabled(!settings.driveShareAnyone)
                Spacer()
            }
            rowDivider()
            HStack(spacing: 8) {
                fieldLabel(L("Klasör"))
                TextField("SS+", text: $settings.driveFolderName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 200)
                    .onSubmit { renameDriveFolder() }
                Button(L("Drive'da aç")) { openDriveFolder() }
                    .controlSize(.small)
                    .disabled(driveBusy)
                Spacer()
            }
            caption(L("Klasör Drive'ının kökünde oluşturulur; sonra Drive'da istediğin yere taşıyabilir ya da adını değiştirebilirsin — yüklemeler onu izlemeye devam eder."))
            if let driveError {
                Label(driveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func signInToGoogle() {
        driveError = nil
        Task {
            do {
                try await auth.signIn()
                settings.driveUploadEnabled = true
                try await DriveUploadCoordinator.shared.ensureFolder()
            } catch GoogleAuthError.cancelled {
                // sessiz
            } catch {
                driveError = error.localizedDescription
            }
        }
    }

    private func renameDriveFolder() {
        driveError = nil
        Task {
            do { try await DriveUploadCoordinator.shared.renameFolder() } catch { driveError = error.localizedDescription }
        }
    }

    private func openDriveFolder() {
        driveError = nil
        driveBusy = true
        Task {
            defer { driveBusy = false }
            do {
                try await DriveUploadCoordinator.shared.ensureFolder()
                if let url = DriveUploadCoordinator.shared.folderURL { NSWorkspace.shared.open(url) }
            } catch {
                driveError = error.localizedDescription
            }
        }
    }
}

/// Kare hızı seçim düğmesi. 60 fps Pro'ya özeldir: seçilebilir gibi görünüp
/// sessizce 30'a düşmesin.
private struct FrameRateButton: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var pro = ProManager.shared
    let fps: Int

    private var locked: Bool { fps > 30 && !pro.isPro }

    var body: some View {
        let selected = settings.fps == fps && !locked
        Button("\(fps) fps") {
            settings.fps = fps
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .tint(selected ? Color.accentColor : Color.gray.opacity(0.3))
        .disabled(locked)
        .help(locked ? L("60 fps yalnızca Pro'da") : "")
    }
}

// MARK: - Kısayollar

struct ShortcutsTab: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        SettingsSection(title: L("Genel kısayollar"), icon: "keyboard") {
            HStack(spacing: 12) {
                fieldLabel(L("Yakalama aracı"))
                ShortcutRecorderButton(hotkey: captureBinding, conflictsWith: settings.recordHotkey)
                fieldLabel(L("Video kaydı başlat / durdur"))
                ShortcutRecorderButton(hotkey: recordBinding, conflictsWith: settings.captureHotkey)
                Spacer()
                Button(L("Sıfırla")) {
                    settings.captureHotkey = .defaultCapture
                    settings.recordHotkey = .defaultRecord
                }
                .controlSize(.small)
            }
            if let warning = app.hotkeyWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }

        HStack(alignment: .top, spacing: 16) {
            SettingsSection(title: L("Seçim ekranı"), icon: "cursorarrow.rays") {
                ShortcutList(rows: [
                    ("R / A", L("Alan modu")),
                    ("W / P", L("Pencere modu")),
                    ("⇧", L("Kare oranına kilitle")),
                    ("↩", L("Tüm ekranı yakala")),
                    ("Esc", L("Vazgeç")),
                ])
            }
            SettingsSection(title: L("Çizim düzenleyici"), icon: "pencil.tip.crop.circle") {
                ShortcutList(rows: [
                    ("1–7", L("Araç seç")),
                    ("⌘Z · ⇧⌘Z", L("Geri al · yinele")),
                    ("⌫", L("Son öğeyi geri al")),
                    ("↩", L("Bitti · kaydet")),
                    ("Esc", L("Çizimsiz aktar")),
                    ("⌘.", L("Vazgeç")),
                ])
            }
        }
    }

    private var captureBinding: Binding<HotkeySetting> {
        Binding(get: { settings.captureHotkey }, set: { settings.captureHotkey = $0 })
    }

    private var recordBinding: Binding<HotkeySetting> {
        Binding(get: { settings.recordHotkey }, set: { settings.recordHotkey = $0 })
    }
}

/// Kısayol kaydedici: tıklanır, yeni kombinasyona basılır, anında kaydedilir.
struct ShortcutRecorderButton: View {
    @Binding var hotkey: HotkeySetting
    /// Diğer global kısayol: aynısı seçilirse reddedilir (ikisi birden kaydedilemez).
    var conflictsWith: HotkeySetting?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalidFlash = false
    @State private var reason: String?

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? L("Kısayola bas…") : hotkey.display)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
                .frame(minWidth: 84)
        }
        .controlSize(.small)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(recording ? Color.accentColor : (invalidFlash ? Color.red : Color.clear), lineWidth: 1.5)
        )
        .help(reason ?? (recording ? L("Esc: vazgeç") : L("Değiştirmek için tıkla ve yeni kısayola bas")))
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        recording = true
        reason = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let char = HotKeyManager.shared.baseCharacter(forKeyCode: event.keyCode),
                  Self.isBindable(char) else {
                flashInvalid(L("Bu tuş kısayol olamaz; harf, rakam ya da noktalama seç."))
                return nil
            }
            let carbonMods = HotkeySetting.carbonModifiers(from: event.modifierFlags)
            guard carbonMods != 0 else {
                flashInvalid(L("En az bir değiştirici (⌘ ⌥ ⌃ ⇧) gerekli."))
                return nil
            }
            let candidate = HotkeySetting(character: String(char), carbonModifiers: carbonMods)
            if let other = conflictsWith, other == candidate {
                flashInvalid(L("Bu kısayol diğer eylemde kullanılıyor."))
                return nil
            }
            hotkey = candidate
            stopRecording()
            return nil
        }
    }

    /// Yazdırılabilir, özel-kullanım olmayan tek karakterler bağlanabilir.
    private static func isBindable(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
        if (0xE000...0xF8FF).contains(scalar.value) { return false }
        if scalar.properties.generalCategory == .control || char.isWhitespace { return false }
        return char.isLetter || char.isNumber || char.isPunctuation || char.isSymbol
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }

    private func flashInvalid(_ why: String) {
        reason = why
        withAnimation(.easeInOut(duration: 0.12).repeatCount(2, autoreverses: true)) {
            invalidFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            invalidFlash = false
        }
        NSSound.beep()
    }
}

/// Salt okunur kısayol listesi (tuş sağda, rozet biçiminde).
private struct ShortcutList: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.1).font(.system(size: 12))
                    Spacer()
                    Text(row.0)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                }
            }
        }
    }
}

// MARK: - Pro

struct ProTab: View {
    @ObservedObject private var pro = ProManager.shared
    @State private var codeInput: String = ""
    @State private var codeError: Bool = false
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        SettingsSection(title: L("Abonelik"), icon: "crown") {
            HStack(spacing: 12) {
                Image(systemName: pro.isPro ? "star.fill" : "star")
                    .foregroundStyle(pro.isPro ? .yellow : .secondary)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pro.isPro ? L("SS+ Pro aktif") : "SS+ Pro")
                        .font(.headline)
                    Text(pro.isPro ? L("Tüm özellikler açık") : L("Tüm özelliklerin kilidini aç"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if pro.isPro {
                    Button(L("Kaldır")) {
                        pro.clearCode()
                        codeInput = ""
                        codeError = false
                    }
                    .controlSize(.small)
                }
            }
            rowDivider()
            codeSection
        }

        SettingsSection(title: L("Pro özellikleri"), icon: "sparkles") {
            ForEach(Array(ProManager.features.enumerated()), id: \.offset) { _, feature in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(feature.title).font(.system(size: 12, weight: .semibold))
                    Text("— " + feature.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var codeSection: some View {
        if pro.isPro {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                caption(L("Kod ile etkinleştirildi"))
                if let code = pro.redeemedCode {
                    Text(code.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.15)))
                }
            }
        } else {
            HStack(spacing: 8) {
                fieldLabel(L("Etkinleştirme kodu"))
                TextField(L("Kodu gir"), text: $codeInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 180)
                    .focused($codeFieldFocused)
                    .onSubmit(submitCode)
                    .onChange(of: codeInput) { _, _ in codeError = false }
                Button(L("Etkinleştir"), action: submitCode)
                    .controlSize(.small)
                    .disabled(codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            if codeError {
                Label(L("Bu kod geçerli değil."), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func submitCode() {
        if pro.redeem(codeInput) {
            codeError = false
            codeInput = ""
            codeFieldFocused = false
        } else {
            codeError = true
        }
    }
}
