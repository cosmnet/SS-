import AppKit

@MainActor
enum OutputPipeline {

    static func fileName(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")   // yerel rakam sistemlerinden bağımsız
        formatter.dateFormat = "yyyy-MM-dd '\(L("saat"))' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(ext)"
    }

    /// Aynı saniyede ikinci yakalama öncekinin üstüne yazmasın: " 2", " 3"… eklenir.
    private static func uniqueURL(in folder: URL, prefix: String, ext: String) -> URL {
        let base = folder.appendingPathComponent(fileName(prefix: prefix, ext: ext))
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
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
        let url = uniqueURL(in: settings.saveFolder, prefix: "SS+", ext: format.fileExtension)
        do {
            try data.write(to: url)
        } catch {
            // Dosya yoksa önizleme kartı, ses ve pano da olmasın: kart var
            // olmayan bir dosyaya "Göster / Sil" sunardı.
            AppState.shared.presentError(error)
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: rep.size)

        if settings.copyToClipboard {
            copyToPasteboard(nsImage, encoded: data, fileExtension: format.fileExtension)
        }
        if settings.playSound {
            NSSound(named: "Pop")?.play()
        }
        if settings.showPreview {
            PreviewPanelController.shared.show(.image(nsImage, url, cgImage, scale))
        }
        // Kart gösterildikten SONRA: yükleme durumu karta işlenir.
        DriveUploadCoordinator.shared.upload(imageData: data, mimeType: format.mimeType, localURL: url)
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
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppState.shared.presentError(error)
            return
        }

        if settings.copyToClipboard {
            let nsImage = NSImage(cgImage: cgImage, size: rep.size)
            copyToPasteboard(nsImage, encoded: data, fileExtension: format.fileExtension)
        }
        // Drive'daki dosya da güncellenir (aynı kimlik, aynı bağlantı).
        DriveUploadCoordinator.shared.upload(imageData: data, mimeType: format.mimeType, localURL: url)
    }

    static func deliverVideo(url: URL, note: String? = nil) {
        let settings = SettingsStore.shared
        if settings.playSound {
            NSSound(named: "Glass")?.play()
        }
        if settings.showPreview {
            PreviewPanelController.shared.show(.video(url), note: note)
        }
    }

    /// Görüntüyü panoya yazar ve pano geçmişine ZATEN kodlanmış veriyi verir;
    /// böylece geçmiş, SS+'ın kendi yakalamasını ana iş parçacığında yeniden
    /// PNG'ye çevirmek zorunda kalmaz.
    private static func copyToPasteboard(_ image: NSImage, encoded data: Data, fileExtension: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        ClipboardStore.shared.noteOwnCapture(
            encoded: data,
            fileExtension: fileExtension,
            pasteboardChangeCount: pasteboard.changeCount
        )
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
