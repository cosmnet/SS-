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
        let pointSize = NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )

        // Bitmap kopyası yalnızca kodlama süresince yaşasın (Retina'da onlarca MB);
        // otomatik serbest bırakma havuzu AppKit geçicilerini hemen boşaltır.
        let encoded: Data? = autoreleasepool {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = pointSize
            return encode(rep, format: format)
        }
        guard let data = encoded else {
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

        // Kart için küçük önizleme; tam çözünürlüklü görüntü fonksiyon bitince serbest kalır.
        let thumbCG = ImageFile.thumbnail(from: data, maxPixel: 720) ?? cgImage
        let preview = NSImage(cgImage: thumbCG, size: pointSize)

        if settings.copyToClipboard {
            let changeCount = writeImageToPasteboard(data, fileExtension: format.fileExtension)
            ClipboardStore.shared.noteOwnCapture(encoded: data, fileExtension: format.fileExtension, pasteboardChangeCount: changeCount)
        }
        if settings.playSound {
            NSSound(named: "Pop")?.play()
        }
        if settings.showPreview {
            PreviewPanelController.shared.show(.image(preview, url, scale))
        }
        // Kart gösterildikten SONRA: yükleme durumu karta işlenir. Yükleme kapalıysa
        // `data` burada son kez kullanılır ve fonksiyon bitince serbest kalır.
        DriveUploadCoordinator.shared.upload(imageData: data, mimeType: format.mimeType, localURL: url)
    }

    /// Düzenleyiciden dönen sonucu VAR OLAN dosyanın üstüne yazar.
    /// Önizlemeden açılan düzenleme yeni dosya üretmez, aynısını günceller.
    static func overwrite(_ cgImage: CGImage, at url: URL, scale: CGFloat) {
        let settings = SettingsStore.shared
        let format: ImageFormat = url.pathExtension.lowercased() == "jpg" ? .jpg : .png

        let pointSize = NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        let encoded: Data? = autoreleasepool {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = pointSize
            return encode(rep, format: format)
        }
        guard let data = encoded else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppState.shared.presentError(error)
            return
        }

        if settings.copyToClipboard {
            let changeCount = writeImageToPasteboard(data, fileExtension: format.fileExtension)
            ClipboardStore.shared.noteOwnCapture(encoded: data, fileExtension: format.fileExtension, pasteboardChangeCount: changeCount)
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
        DriveUploadCoordinator.shared.uploadVideo(localURL: url)
    }

    /// Görüntüyü panoya BAYT olarak yazar (PNG ya da JPEG) ve TIFF'i isteyen
    /// uygulamalar için gerektiğinde üretilen bir sağlayıcı ekler. Panoya NSImage
    /// nesnesi verilmez: o nesne tam çözünürlüklü yakalamayı bir sonraki
    /// kopyalamaya dek bellekte tutuyordu. Döndürülen değer pano sayacıdır.
    @discardableResult
    static func writeImageToPasteboard(_ data: Data, fileExtension: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let isJPEG = ["jpg", "jpeg"].contains(fileExtension.lowercased())
        item.setData(data, forType: isJPEG ? NSPasteboard.PasteboardType("public.jpeg") : .png)
        item.setDataProvider(LazyTIFFProvider(data: data), forTypes: [.tiff])
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
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
