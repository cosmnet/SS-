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
        window.title = "SS+ Ayarları"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()
        window.isReleasedWhenClosed = false
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
                        Label(tab.rawValue, systemImage: tab.icon)
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

// MARK: - Genel

struct GeneralTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Yakalama sonrası düzenleyiciyi aç", isOn: $settings.editAfterCapture)
                            .toggleStyle(.switch)
                        Text("Çekilen görüntü, bulunduğu yerin üstünde açılan çizim düzenleyicisine düşer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        Toggle("Önizleme kartını göster", isOn: $settings.showPreview)
                            .toggleStyle(.switch)
                        if settings.showPreview {
                            HStack {
                                Text("Kaybolma süresi")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $settings.previewSeconds, in: 2...15, step: 1)
                                    .controlSize(.small)
                                Text("\(Int(settings.previewSeconds)) sn")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                        Divider()
                        Toggle("Kopyalama sesi çal", isOn: $settings.playSound)
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Yakalama", systemImage: "camera.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Ada'yı (Island) boşta göster", isOn: $settings.islandEnabled)
                            .toggleStyle(.switch)
                        Text("Kapatılırsa ada yalnızca kayıt ve seçim sırasında görünür; çentik tamamen sessiz kalır.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Ada (Island)", systemImage: "rectangle.topthird.inset.filled")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Kayıt & Çıktı

struct OutputTab: View {
    @ObservedObject private var settings = SettingsStore.shared

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
                            Button("Değiştir…") {
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
                        Toggle("Görüntüleri panoya da kopyala", isOn: $settings.copyToClipboard)
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Konum", systemImage: "externaldrive")
                        .font(.system(size: 12, weight: .semibold))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Görüntü formatı", selection: $settings.imageFormat) {
                            ForEach(ImageFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("Video kare hızı")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            FrameRateButton(fps: 30)
                            FrameRateButton(fps: 60)
                        }

                        Toggle("Akıllı pencere sezme", isOn: $settings.smartWindowDetect)
                            .toggleStyle(.switch)
                        Text("Alan modunda fare pencere üstündeyken tıklamak o pencereyi yakalar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Kalite", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Kısayollar

struct ShortcutsTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(spacing: 0) {
                        ShortcutRecorderRow(
                            title: "Yakalama aracı",
                            icon: "camera.viewfinder",
                            tint: .purple,
                            hotkey: captureBinding
                        )
                        Divider().padding(.leading, 44)
                        ShortcutRecorderRow(
                            title: "Video kaydı",
                            icon: "record.circle",
                            tint: .red,
                            hotkey: recordBinding
                        )
                        Divider().padding(.leading, 44)
                        HStack {
                            Text("Varsayılanlara dön")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Sıfırla") {
                                settings.captureHotkey = .defaultCapture
                                settings.recordHotkey = .defaultRecord
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Genel kısayollar", systemImage: "command")
                        .font(.system(size: 12, weight: .semibold))
                }

                GroupBox {
                    ShortcutRow(
                        rows: [
                            ("R", "Alan modu"),
                            ("W", "Pencere modu"),
                            ("⇧", "Kare oranına kilitle"),
                            ("↩", "Tüm ekranı yakala"),
                            ("Esc", "Vazgeç"),
                        ]
                    )
                    .padding(.vertical, 4)
                } label: {
                    Label("Seçim ekranı", systemImage: "cursorarrow.rays")
                        .font(.system(size: 12, weight: .semibold))
                }

                GroupBox {
                    ShortcutRow(
                        rows: [
                            ("1–7", "Araç seç"),
                            ("↩", "Bitti · kaydet"),
                            ("Esc", "Vazgeç"),
                            ("⌫", "Son öğeyi sil"),
                        ]
                    )
                    .padding(.vertical, 4)
                } label: {
                    Label("Çizim düzenleyici", systemImage: "pencil.tip.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
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
private struct FrameRateButton: View {
    @ObservedObject private var settings = SettingsStore.shared
    let fps: Int

    var body: some View {
        let selected = settings.fps == fps
        Button("\(fps) fps") {
            settings.fps = fps
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .tint(selected ? Color.accentColor : Color.gray.opacity(0.3))
    }
}

/// Değiştirilebilir kısayol satırı: "Kaydet"e basılır, istenen tuş kombinasyonuna
/// basılır ve kısayol anında yeniden kaydedilir.
struct ShortcutRecorderRow: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var hotkey: HotkeySetting

    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalidFlash = false

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint == .red ? .red : .primary)
            Spacer()
            recordButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onDisappear { stopRecording() }
    }

    private var recordButton: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? "Kısayola bas…" : hotkey.display)
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
        .help(recording ? "Esc: vazgeç" : "Değiştirmek için tıkla ve yeni kısayola bas")
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc: vazgeç
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let characters = event.charactersIgnoringModifiers, let first = characters.first else {
                flashInvalid()
                return nil
            }
            let carbonMods = HotkeySetting.carbonModifiers(from: event.modifierFlags)
            guard carbonMods != 0 else {
                // Değiştiricisiz kısayol global olarak anlamsız
                flashInvalid()
                return nil
            }
            hotkey = HotkeySetting(character: String(first).lowercased(), carbonModifiers: carbonMods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }

    private func flashInvalid() {
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
                                Text(pro.isPro ? "SS+ Pro aktif" : "SS+ Pro")
                                    .font(.headline)
                                Text(pro.isPro ? "Tüm özellikler açık" : "Tüm özelliklerin kilidini aç")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pro.isPro {
                                Button("Kaldır") {
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
                        VStack(alignment: .leading, spacing: 6) {
                            featureRow("text.viewfinder", "OCR: görüntüden metin çıkarma")
                            featureRow("paintpalette", "Ekstra vurgu renkleri ve çıkartmalar")
                            featureRow("film.stack", "Kayıtta kare üstü tarih-saat damgası")
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Abonelik", systemImage: "crown")
                        .font(.system(size: 12, weight: .semibold))
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
                Text("Kod ile etkinleştirildi")
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
                Text("Etkinleştirme kodu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Kodu gir", text: $codeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 180)
                        .focused($codeFieldFocused)
                        .onSubmit(submitCode)
                        .onChange(of: codeInput) { _, _ in codeError = false }
                    Button("Etkinleştir", action: submitCode)
                        .controlSize(.small)
                        .disabled(codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if codeError {
                    Label("Bu kod geçerli değil.", systemImage: "exclamationmark.triangle.fill")
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

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
