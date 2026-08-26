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

    /// ScreenCaptureKit'in döndürdüğü görüntü IOSurface destekli olur ve o yüzeyler
    /// (çift tamponlu, ekran boyutunda) görüntüye tutunan HERHANGİ bir şey yüzünden
    /// süreçte kalabilir. Yakalamayı sıradan belleğe kopyalayıp orijinali hemen
    /// bırakırsak yüzeyler sisteme geri döner; kopya bizim akışımızla birlikte
    /// serbest kalır (ölçüldü).
    static func mallocBackedCopy(_ image: CGImage) -> CGImage {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Dosyadan tam çözünürlüklü görüntü (düzenleme / OCR için, gerektiğinde).
    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
