import AppKit
import SwiftUI

/// Pazarlama için gerçek SwiftUI yüzeylerini PNG olarak dışa aktarır.
///
/// `SS+.app --args --export-ui-shots /path` ile bir kez çalışır, yazıp çıkar.
@MainActor
enum UIShotExport {
    static func run(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        ClipboardStore.shared.installExportFixtures()
        IslandController.shared.ui.metrics = .fallback
        IslandController.shared.ui.expanded = true
        IslandController.shared.pinned = true
        StatusPanelController.shared.model.refreshFiles()

        // Parlak yeşil: Python'da kromayı kesip gerçek UI'yi şeffaf PNG olarak alırız.
        let chroma = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

        snap(IslandView(), size: CGSize(width: 540, height: 230), name: "ui-island", in: directory, backdrop: chroma)

        AppState.shared.phase = .recording
        AppState.shared.recordingSeconds = 12
        snap(IslandView(), size: CGSize(width: 360, height: 64), name: "ui-island-recording", in: directory, backdrop: chroma)
        AppState.shared.phase = .idle
        AppState.shared.recordingSeconds = 0

        // --- Çentikli yerleşim -------------------------------------------
        // Bu makinenin GERÇEK çentik ölçüleriyle çizilir: kanatların çentiğin
        // iki yanına doğru oturduğu ve orta oyuğun boş kaldığı buradan görülür.
        let notch = NotchMetrics.primary()
        if notch.hasNotch {
            IslandController.shared.ui.metrics = notch
            let bleed = IslandLayout.topBleed

            func notchedSize(_ phase: AppState.Phase, drop: CGFloat) -> CGSize {
                let wing = IslandController.wingWidth(for: phase, metrics: notch)
                return CGSize(
                    width: notch.notchWidth + wing * 2,
                    height: notch.notchHeight + bleed + drop
                )
            }

            IslandController.shared.ui.expanded = true
            snap(IslandView(), size: notchedSize(.idle, drop: 190),
                 name: "ui-island-notch-expanded", in: directory, backdrop: chroma)

            AppState.shared.phase = .selecting(.rect, .screenshot)
            snap(IslandView(), size: notchedSize(AppState.shared.phase, drop: 0),
                 name: "ui-island-notch-selecting", in: directory, backdrop: chroma)

            AppState.shared.phase = .recording
            AppState.shared.recordingSeconds = 12
            AppState.shared.recordingAudioActive = true
            AppState.shared.audioLevel = 0.6
            snap(IslandView(), size: notchedSize(.recording, drop: 0),
                 name: "ui-island-notch-recording", in: directory, backdrop: chroma)

            AppState.shared.phase = .idle
            AppState.shared.recordingSeconds = 0
            AppState.shared.recordingAudioActive = false
            IslandController.shared.ui.metrics = .fallback
        }

        let panelModel = StatusPanelController.shared.model
        panelModel.tab = .files
        snap(StatusPanelView(model: panelModel, controller: nil), size: CGSize(width: 300, height: 392), name: "ui-status-files", in: directory, backdrop: chroma)
        panelModel.tab = .clipboardImages
        snap(StatusPanelView(model: panelModel, controller: nil), size: CGSize(width: 300, height: 392), name: "ui-status-images", in: directory, backdrop: chroma)
        panelModel.tab = .clipboardTexts
        snap(StatusPanelView(model: panelModel, controller: nil), size: CGSize(width: 300, height: 392), name: "ui-status-texts", in: directory, backdrop: chroma)

        snap(PermissionsView(), size: CGSize(width: 520, height: 440), name: "ui-permissions", in: directory, backdrop: .windowBackgroundColor)

        snap(SettingsView(tab: .general), size: CGSize(width: 520, height: 420), name: "ui-settings-general", in: directory, backdrop: .windowBackgroundColor)
        snap(SettingsView(tab: .output), size: CGSize(width: 520, height: 420), name: "ui-settings-output", in: directory, backdrop: .windowBackgroundColor)
        snap(SettingsView(tab: .shortcuts), size: CGSize(width: 520, height: 420), name: "ui-settings-shortcuts", in: directory, backdrop: .windowBackgroundColor)

        let actions = AnnotationActions(undo: {}, redo: {}, done: {}, plain: {}, cancel: {})
        snap(AnnotationToolbarView(model: AnnotationModel(), actions: actions), size: CGSize(width: 900, height: 100), name: "ui-editor-toolbar", in: directory, backdrop: chroma)

        snap(
            DrawToolbarView(model: RecordingDrawController.shared.tools, controller: RecordingDrawController.shared),
            size: CGSize(width: 560, height: 72),
            name: "ui-record-drawbar",
            in: directory,
            backdrop: chroma
        )

        let shot = stageImage() ?? sampleImage()
        let preview = PreviewModel()
        preview.item = .image(shot, directory.appendingPathComponent("preview.png"), 2)
        snap(
            PreviewCardView(model: preview, controller: nil, forceHover: true),
            size: CGSize(width: 360, height: 260),
            name: "ui-preview",
            in: directory,
            backdrop: chroma
        )

        snap(SSPlusLogoView(size: 256), size: CGSize(width: 256, height: 256), name: "ui-logo", in: directory, backdrop: chroma)

        print("UI shot export → \(directory.path)")
    }

    private static func snap<V: View>(_ view: V, size: CGSize, name: String, in directory: URL, backdrop: NSColor) {
        let root = view
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = backdrop.alphaComponent >= 1
        window.backgroundColor = backdrop
        window.hasShadow = false
        window.level = .statusBar
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)

        if backdrop.alphaComponent < 1, let cg = trimTransparent(rep) {
            let trimmed = NSBitmapImageRep(cgImage: cg)
            if let png = trimmed.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
            }
            return
        }
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private static func trimTransparent(_ rep: NSBitmapImageRep) -> CGImage? {
        guard let cg = rep.cgImage else { return nil }
        return cg
    }

    private static func stageImage() -> NSImage? {
        let url = URL(fileURLWithPath: "/Users/cosm/Desktop/SS/MARKETING/visuals/wiro/gradient-stage.png")
        return NSImage(contentsOf: url)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func sampleImage() -> NSImage {
        NSImage(cgImage: sampleCGImage(), size: NSSize(width: 320, height: 200))
    }

    private static func sampleCGImage() -> CGImage {
        let w = 640, h = 400
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0.36, blue: 0.62, alpha: 0.92))
        ctx.fillEllipse(in: CGRect(x: 80, y: 90, width: 180, height: 180))
        ctx.setFillColor(CGColor(red: 0.62, green: 0.34, blue: 0.98, alpha: 0.88))
        ctx.fillEllipse(in: CGRect(x: 280, y: 110, width: 220, height: 220))
        return ctx.makeImage()!
    }
}
