import AppKit
import ImageIO

/// Diskteki yakalama dosyasıyla çalışan yardımcılar. Amaç, tam çözünürlüklü
/// görüntüyü bellekte TUTMAMAK: kart küçük bir önizleme gösterir; düzenleme ve
/// OCR gerektiğinde dosya yeniden okunur.
enum ImageFile {
    /// Kodlanmış veriden (PNG/JPEG) en uzun kenarı `maxPixel` olan küçük görüntü.
    static func thumbnail(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Dosyadan tam çözünürlüklü görüntü (düzenleme / OCR için, gerektiğinde).
    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

/// Panoya TIFF'i gerektiğinde üretir: yalnızca kodlanmış PNG/JPEG baytlarını tutar,
/// böylece pano, tam çözünürlüklü NSImage/CGImage'i canlı tutmaz.
final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        autoreleasepool {
            if let rep = NSBitmapImageRep(data: data), let tiff = rep.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
    }
}
