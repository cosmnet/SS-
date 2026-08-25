import AppKit
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
        window.setContentSize(NSSize(width: 520, height: 560))
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
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .output: return "folder"
            case .shortcuts: return "keyboard"
            case .pro: return "star.fill"
            }
        }
    }

    @State private var selectedTab: Tab

    init(tab: Tab = .general) {
        _selectedTab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sekme çubuğu
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        Label(L(tab.rawValue), systemImage: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            )
                            .foregroundStyle(selectedTab == tab ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch selectedTab {
                case .general: GeneralTab()
                case .output: OutputTab()
                case .shortcuts: ShortcutsTab()
                case .pro: ProTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Ortak parçalar

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

private func groupLabel(_ title: String, _ icon: String) -> some View {
    Label(title, systemImage: icon)
        .font(.system(size: 12, weight: .semibold))
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

// MARK: - Genel

struct GeneralTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(L("Yakalama sonrası düzenleyiciyi aç"), isOn: $settings.editAfterCapture)
                            .toggleStyle(.switch)
                        caption(L("Çekilen görüntü, bulunduğu yerin üstünde açılan çizim düzenleyicisine düşer."))
                        Divider()
                        Toggle(L("Önizleme kartını göster"), isOn: $settings.showPreview)
                            .toggleStyle(.switch)
                        if settings.showPreview {
                            HStack {
                                caption(L("Kaybolma süresi"))
                                Slider(value: $settings.previewSeconds, in: 2...15, step: 1)
                                    .controlSize(.small)
                                Text(L("%d sn", Int(settings.previewSeconds)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                        Divider()
                        Toggle(L("Kopyalama sesi çal"), isOn: $settings.playSound)
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Yakalama"), "camera.viewfinder")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(L("Pano geçmişini tut"), isOn: $settings.clipboardHistoryEnabled)
                            .toggleStyle(.switch)
                        caption(L("Açıkken kopyaladığın son 10 metin ve görsel adada ve menü panelinde listelenir. Bunlar diske yazılır: ~/Library/Application Support/SSPlus/Clipboard. Şifre yöneticilerinin gizli işaretlediği içerik hiçbir zaman kaydedilmez."))
                        if settings.clipboardHistoryEnabled {
                            Toggle(L("Çıkışta geçmişi sil"), isOn: $settings.clearClipboardHistoryOnQuit)
                                .toggleStyle(.switch)
                            HStack {
                                Spacer()
                                Button(L("Geçmişi şimdi temizle")) {
                                    ClipboardStore.shared.clear()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Pano geçmişi"), "doc.on.clipboard")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(L("Ada'yı (Island) boşta göster"), isOn: $settings.islandEnabled)
                            .toggleStyle(.switch)
                        caption(L("Kapatılırsa ada yalnızca kayıt ve seçim sırasında görünür; çentik tamamen sessiz kalır."))
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Ada (Island)"), "rectangle.topthird.inset.filled")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $settings.language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.title).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        caption(L("Arayüz dili değişikliği anında uygulanır."))
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Dil"), "globe")
                }
            }
            .padding(16)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
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
                        Toggle(L("Görüntüleri panoya da kopyala"), isOn: $settings.copyToClipboard)
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Konum"), "externaldrive")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(L("Görüntü formatı"), selection: $settings.imageFormat) {
                            ForEach(ImageFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle(L("İmleci ekran görüntüsüne ve videoya dahil et"), isOn: $settings.showCursor)
                            .toggleStyle(.switch)

                        Toggle(L("Akıllı pencere sezme"), isOn: $settings.smartWindowDetect)
                            .toggleStyle(.switch)
                        caption(L("Alan modunda fare pencere üstündeyken tıklamak o pencereyi yakalar."))
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Görüntü"), "sparkles")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            caption(L("Kare hızı"))
                            Spacer()
                            FrameRateButton(fps: 30)
                            FrameRateButton(fps: 60)
                            if !pro.isPro { ProBadge() }
                        }

                        HStack {
                            caption(L("Kap"))
                            Spacer()
                            Picker("", selection: $settings.videoFormat) {
                                Text("MOV").tag("mov")
                                Text("MP4").tag("mp4")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 130)
                        }

                        HStack {
                            caption(L("Kodek"))
                            Spacer()
                            Picker("", selection: $settings.videoCodec) {
                                Text("H.264").tag("h264")
                                Text("HEVC").tag("hevc")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 130)
                            .disabled(!pro.isPro)
                            if !pro.isPro { ProBadge() }
                        }

                        HStack {
                            caption(L("Bit hızı"))
                            Spacer()
                            Picker("", selection: $settings.videoBitrateMbps) {
                                Text(L("Otomatik")).tag(0)
                                Text("8 Mb/s").tag(8)
                                Text("16 Mb/s").tag(16)
                                Text("32 Mb/s").tag(32)
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .disabled(!pro.isPro)
                            if !pro.isPro { ProBadge() }
                        }

                        HStack {
                            Toggle(L("Sistem sesini kaydet"), isOn: $settings.recordAudio)
                                .toggleStyle(.switch)
                                .disabled(!pro.isPro)
                            if !pro.isPro { ProBadge() }
                        }
                        if !pro.isPro {
                            caption(L("Pro olmadan kayıt 30 fps, H.264 ve otomatik bit hızıyla yapılır."))
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Video"), "record.circle")
                }

                GroupBox {
                    driveSection
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel("Google Drive", "icloud.and.arrow.up")
                }
            }
            .padding(16)
        }
    }

    // MARK: Google Drive

    @ViewBuilder
    private var driveSection: some View {
        if !auth.isConfigured {
            caption(L("Bu derlemede Google istemci kimliği yok (Resources/GoogleOAuth.plist). Kurulum için README'ye bak."))
        } else if !auth.isSignedIn {
            VStack(alignment: .leading, spacing: 10) {
                caption(L("Kendi Google hesabınla oturum açarsın; belirteçler yalnızca bu Mac'in Anahtar Zinciri'nde tutulur, SS+ geliştiricisinin Drive'ına erişimi olmaz."))
                HStack {
                    Button(L("Google ile oturum aç")) { signInToGoogle() }
                        .disabled(auth.isSigningIn)
                    if auth.isSigningIn {
                        ProgressView().controlSize(.small)
                        caption(L("Tarayıcıda Google onayı bekleniyor…"))
                    }
                }
                if let driveError {
                    Label(driveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.crop.circle.fill.badge.checkmark")
                        .foregroundStyle(.green)
                    Text(auth.accountEmail ?? "")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(L("Çıkış yap")) {
                        Task { await auth.signOut() }
                    }
                    .controlSize(.small)
                }

                Toggle(L("Ekran görüntülerini Drive'a yükle"), isOn: $settings.driveUploadEnabled)
                    .toggleStyle(.switch)

                HStack {
                    caption(L("Klasör"))
                    TextField("SS+", text: $settings.driveFolderName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 180)
                        .onSubmit { renameDriveFolder() }
                    Button(L("Drive'da aç")) { openDriveFolder() }
                        .controlSize(.small)
                        .disabled(driveBusy)
                }
                caption(L("Klasör Drive'ının kökünde oluşturulur; sonra Drive'da istediğin yere taşıyabilir ya da adını değiştirebilirsin — yüklemeler onu izlemeye devam eder."))

                Toggle(L("Bağlantıyla herkese açık paylaş"), isOn: $settings.driveShareAnyone)
                    .toggleStyle(.switch)
                Toggle(L("Linki panoya kopyala"), isOn: $settings.driveCopyLink)
                    .toggleStyle(.switch)
                    .disabled(!settings.driveShareAnyone)

                if let driveError {
                    Label(driveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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

// MARK: - Kısayollar

struct ShortcutsTab: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var app = AppState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(spacing: 0) {
                        ShortcutRecorderRow(
                            title: L("Yakalama aracı"),
                            icon: "camera.viewfinder",
                            tint: .purple,
                            hotkey: captureBinding,
                            conflictsWith: settings.recordHotkey
                        )
                        Divider().padding(.leading, 44)
                        ShortcutRecorderRow(
                            title: L("Video kaydı başlat / durdur"),
                            icon: "record.circle",
                            tint: .red,
                            hotkey: recordBinding,
                            conflictsWith: settings.captureHotkey
                        )
                        Divider().padding(.leading, 44)
                        HStack {
                            caption(L("Varsayılanlara dön"))
                            Spacer()
                            Button(L("Sıfırla")) {
                                settings.captureHotkey = .defaultCapture
                                settings.recordHotkey = .defaultRecord
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        if let warning = app.hotkeyWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    groupLabel(L("Genel kısayollar"), "command")
                }

                GroupBox {
                    ShortcutRow(
                        rows: [
                            ("R", L("Alan modu")),
                            ("W", L("Pencere modu")),
                            ("⇧", L("Kare oranına kilitle")),
                            ("↩", L("Tüm ekranı yakala")),
                            ("Esc", L("Vazgeç")),
                        ]
                    )
                    .padding(.vertical, 4)
                } label: {
                    groupLabel(L("Seçim ekranı"), "cursorarrow.rays")
                }

                GroupBox {
                    ShortcutRow(
                        rows: [
                            ("1–7", L("Araç seç")),
                            ("⌘Z · ⇧⌘Z", L("Geri al · yinele")),
                            ("⌫", L("Son öğeyi geri al")),
                            ("↩", L("Bitti · kaydet")),
                            ("Esc", L("Çizimsiz aktar")),
                            ("⌘.", L("Vazgeç")),
                        ]
                    )
                    .padding(.vertical, 4)
                } label: {
                    groupLabel(L("Çizim düzenleyici"), "pencil.tip.crop.circle")
                }
            }
            .padding(16)
        }
    }

    private var captureBinding: Binding<HotkeySetting> {
        Binding(
            get: { settings.captureHotkey },
            set: { settings.captureHotkey = $0 }
        )
    }

    private var recordBinding: Binding<HotkeySetting> {
        Binding(
            get: { settings.recordHotkey },
            set: { settings.recordHotkey = $0 }
        )
    }
}

/// Kare hızı seçim düğmesi (tip çıkarımını hafifletmek için ayrı view).
/// 60 fps Pro'ya özeldir: seçilebilir gibi görünüp sessizce 30'a düşmesin.
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

/// Değiştirilebilir kısayol satırı: "Kaydet"e basılır, istenen tuş kombinasyonuna
/// basılır ve kısayol anında yeniden kaydedilir.
struct ShortcutRecorderRow: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var hotkey: HotkeySetting
    /// Diğer global kısayol: aynısı seçilirse reddedilir (ikisi birden kaydedilemez).
    var conflictsWith: HotkeySetting?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalidFlash = false
    @State private var reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint == .red ? .red : .primary)
                Spacer()
                recordButton
            }
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onDisappear { stopRecording() }
    }

    private var recordButton: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? L("Kısayola bas…") : hotkey.display)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(minWidth: 72)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(
                                    recording ? Color.accentColor : (invalidFlash ? Color.red : Color.white.opacity(0.15)),
                                    lineWidth: recording ? 1.5 : 0.5
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .help(recording ? L("Esc: vazgeç") : L("Değiştirmek için tıkla ve yeni kısayola bas"))
    }

    private func startRecording() {
        stopRecording()
        recording = true
        reason = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc: vazgeç
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            // Karakteri DÜZENDEN, değiştiricisiz çöz: ⇧1 → "1", ok tuşları → nil.
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
        if (0xE000...0xF8FF).contains(scalar.value) { return false }   // ok / işlev tuşları
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

// MARK: - Kısayol satırı (salt okunur)

struct ShortcutRow: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.1)
                        .font(.system(size: 13))
                    Spacer()
                    Text(row.0)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if index < rows.count - 1 {
                    Divider().padding(.leading, 44)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: pro.isPro ? "star.fill" : "star")
                                .foregroundStyle(pro.isPro ? .yellow : .secondary)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pro.isPro ? L("SS+ Pro aktif") : "SS+ Pro")
                                    .font(.headline)
                                Text(pro.isPro ? L("Tüm özellikler açık") : L("Tüm özelliklerin kilidini aç"))
                                    .font(.caption)
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
                        Divider()
                        codeSection
                        Divider()
                        // Tek kaynak: ProManager.features (README ve OKU-BENI de buna uyar)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(ProManager.features.enumerated()), id: \.offset) { _, feature in
                                featureRow(feature.icon, feature.title, feature.detail)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    groupLabel(L("Abonelik"), "crown")
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var codeSection: some View {
        if pro.isPro {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                Text(L("Kod ile etkinleştirildi"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let code = pro.redeemedCode {
                    Text(code.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.green.opacity(0.15))
                        )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                caption(L("Etkinleştirme kodu"))
                HStack(spacing: 8) {
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
                }
                if codeError {
                    Label(L("Bu kod geçerli değil."), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
