import AppKit

@MainActor
enum OutputPipeline {

    static func fileName(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'saat' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(ext)"
    }

    static func deliverImage(_ cgImage: CGImage, scale: CGFloat) {
        let settings = SettingsStore.shared
        let format = settings.imageFormat

        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        guard let data = encode(rep, format: format) else {
            AppState.shared.presentError(CaptureError.encodeFailed)
            return
        }

        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let url = settings.saveFolder.appendingPathComponent(fileName(prefix: "SS+", ext: format.fileExtension))
        do {
            try data.write(to: url)
        } catch {
            AppState.shared.presentError(error)
        }

        let nsImage = NSImage(cgImage: cgImage, size: rep.size)

        if settings.copyToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }
        if settings.playSound {
            NSSound(named: "Pop")?.play()
        }
        if settings.showPreview {
            PreviewPanelController.shared.show(.image(nsImage, url, cgImage, scale))
        }
    }

    /// Düzenleyiciden dönen sonucu VAR OLAN dosyanın üstüne yazar.
    /// Önizlemeden açılan düzenleme yeni dosya üretmez, aynısını günceller.
    static func overwrite(_ cgImage: CGImage, at url: URL, scale: CGFloat) {
        let settings = SettingsStore.shared
        let format: ImageFormat = url.pathExtension.lowercased() == "jpg" ? .jpg : .png

        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        guard let data = encode(rep, format: format) else { return }
        try? data.write(to: url, options: .atomic)

        if settings.copyToClipboard {
            let nsImage = NSImage(cgImage: cgImage, size: rep.size)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }
    }

    static func deliverVideo(url: URL) {
        let settings = SettingsStore.shared
        if settings.playSound {
            NSSound(named: "Glass")?.play()
        }
        if settings.showPreview {
            PreviewPanelController.shared.show(.video(url))
        }
    }

    private static func encode(_ rep: NSBitmapImageRep, format: ImageFormat) -> Data? {
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
    }
}
