import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// Menü çubuğu panelinin listeleri.
@MainActor
final class StatusPanelModel: ObservableObject {
    enum Tab: Int, CaseIterable {
        case files
        case clipboardImages
        case clipboardTexts

        var title: String {
            switch self {
            case .files: return "Dosyalar"
            case .clipboardImages: return "Görseller"
            case .clipboardTexts: return "Metinler"
            }
        }
    }

    @Published var tab: Tab = .files
    @Published var files: [URL] = []
    /// Kopyalama onayı için kısa süreli işaret
    @Published var copiedID: UUID?

    /// Kayıt klasöründeki SS+ dosyalarını yeni→eski tarar.
    func refreshFiles() {
        let folder = SettingsStore.shared.saveFolder
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            return
        }
        files = urls
            .filter { $0.lastPathComponent.hasPrefix("SS+") }
            .sorted {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            }
            .prefix(10)
            .map { $0 }
    }

    func confirmCopy(_ id: UUID) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.copiedID == id else { return }
                self?.copiedID = nil
            }
        }
    }
}

// MARK: - Denetleyici

/// Menü çubuğu simgesine SOL TIKLA açılan panel: hızlı eylemler ve
/// son dosyalar / pano geçmişi listeleri. Sağ tık klasik menüyü açar.
@MainActor
final class StatusPanelController {
    static let shared = StatusPanelController()

    let model = StatusPanelModel()

    private var panel: NSPanel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    var isOpen: Bool { panel != nil }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel != nil {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        close()
        model.refreshFiles()

        let size = CGSize(width: 300, height: 392)
        let buttonRect = button.window?.frame ?? .zero
        let origin = CGPoint(
            x: max(buttonRect.minX - size.width + buttonRect.width, 8),
            y: buttonRect.minY - size.height - 6
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        panel.contentView = NSHostingView(rootView: StatusPanelView(model: model, controller: self))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        installClickMonitors()
    }

    func close() {
        removeClickMonitors()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: Dış tıklama

    private func installClickMonitors() {
        removeClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            // Durum çubuğu düğmesine tekrar tıklama toggle tarafından yönetilir;
            // panele yapılan tıklamalar kapanmamalı.
            if let window = event.window,
               window !== self.panel,
               !String(describing: type(of: window)).contains("StatusBar") {
                self.close()
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Başka uygulamaya geçince kapan (global tık zaten yakalar)
            }
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
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }
}

/// Durum çubuğu düğmesinin penceresi NSStatusBarWindow türevidir.
/// (Tür kontrolü panel dışı tıklamayı ayırt etmek için yeterlidir.)

// MARK: - SwiftUI

struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel
    weak var controller: StatusPanelController?

    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            quickActions
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().opacity(0.25)

            tabPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            tabContent
                .frame(maxHeight: .infinity)

            Divider().opacity(0.25)

            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        )
    }

    // MARK: Hızlı eylemler

    private var quickActions: some View {
        HStack(spacing: 6) {
            quickAction(icon: "rectangle.dashed", title: "Alan", shortcut: settings.captureHotkey.display) {
                AppState.shared.beginCapture(.rect)
            }
            quickAction(icon: "macwindow", title: "Pencere") {
                AppState.shared.beginCapture(.window)
            }
            quickAction(icon: "display", title: "Ekran") {
                AppState.shared.captureFullScreen()
            }
            quickAction(icon: "record.circle", title: "Kayıt", tint: .red, shortcut: settings.recordHotkey.display) {
                AppState.shared.beginRecordingSelection()
            }
        }
    }

    private func quickAction(icon: String, title: String, tint: Color = .primary, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            controller?.close()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 16)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(shortcut.map { "\(title) — \($0)" } ?? title)
    }

    // MARK: Sekmeler

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(StatusPanelModel.Tab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { model.tab = tab }
                    if tab == .files { model.refreshFiles() }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(model.tab == tab ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(model.tab == tab ? Color.accentColor.opacity(0.85) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.16)))
    }

    // MARK: İçerik

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .files:
            filesList
        case .clipboardImages:
            clipboardImagesList
        case .clipboardTexts:
            clipboardTextsList
        }
    }

    private var filesList: some View {
        Group {
            if model.files.isEmpty {
                emptyState(icon: "tray", text: "Henüz kayıt yok")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.files, id: \.self) { url in
                            fileRow(url)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 9) {
            FileThumbnailView(url: url)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(relativeDate(of: url))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Finder'da göster")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(url)
        }
    }

    private var clipboardImagesList: some View {
        let images = clipboard.entries.filter { $0.kind == .image }
        return Group {
            if images.isEmpty {
                emptyState(icon: "photo.on.rectangle.angled", text: settings.clipboardHistoryEnabled ? "Pano görsel geçmişi boş" : "Pano geçmişi kapalı · Ayarlar → Genel")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(images) { entry in
                            clipboardImageRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func clipboardImageRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 9) {
            Group {
                if let thumb = clipboard.thumbnail(for: entry) {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 30)
                        .clipped()
                        .cornerRadius(5)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 30)
                }
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text("Pano görseli")
                    .font(.system(size: 11.5, weight: .medium))
                Text(RelativeDateTimeFormatter.localized.tr.string(for: entry.date) ?? "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.copiedID == entry.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            clipboard.recopy(entry)
            model.confirmCopy(entry.id)
        }
        .help("Panoya geri kopyala")
    }

    private var clipboardTextsList: some View {
        let texts = clipboard.entries.filter { $0.kind == .text }
        return Group {
            if texts.isEmpty {
                emptyState(icon: "text.quote", text: settings.clipboardHistoryEnabled ? "Pano metin geçmişi boş" : "Pano geçmişi kapalı · Ayarlar → Genel")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(texts) { entry in
                            clipboardTextRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func clipboardTextRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(entry.text ?? "")
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(RelativeDateTimeFormatter.localized.tr.string(for: entry.date) ?? "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if model.copiedID == entry.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            clipboard.recopy(entry)
            model.confirmCopy(entry.id)
        }
        .help("Panoya geri kopyala")
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Alt bar

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton(icon: "gearshape", label: "Ayarlar") {
                SettingsWindowController.shared.show()
            }
            footerButton(icon: "arrow.clockwise", label: "Listeyi yenile") {
                model.refreshFiles()
            }
            Spacer()
            footerButton(icon: "power", label: "Çıkış") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            controller?.close()
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: Yardımcılar

    private func relativeDate(of url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return RelativeDateTimeFormatter.localized.tr.string(for: date) ?? ""
    }
}

// MARK: - Küçük görsel önizleme

/// Dosyalar sekmesindeki satır simgesi: görüntüler gerçek küçük önizleme,
/// videolar film simgesi gösterir.
struct FileThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 30)
                    .clipped()
                    .cornerRadius(5)
            } else {
                Image(systemName: url.pathExtension.lowercased() == "mov" ? "film" : "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 30)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(5)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard url.pathExtension.lowercased() != "mov" else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url) else { return }
            let thumb = image.downscaled(to: 96)
            DispatchQueue.main.async { self.thumbnail = thumb }
        }
    }
}

// MARK: - Göreli tarih

private extension RelativeDateTimeFormatter {
    static var localized: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "tr_TR")
        return formatter
    }

    /// `formatter.string(for:)` macOS 12+'da mevcut; burada yalnızca tür
    /// yardımı olarak durur (yerelleştirme davranışı için).
    var tr: RelativeDateTimeFormatter { self }
}
