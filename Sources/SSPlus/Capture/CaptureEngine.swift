import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case noWindow
    case permissionDenied
    case encodeFailed
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noDisplay: return L("Ekran bulunamadı.")
        case .noWindow: return L("Pencere bulunamadı.")
        case .permissionDenied: return L("Ekran kaydı izni gerekiyor. Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı bölümünden SS+ için izin verin.")
        case .encodeFailed: return L("Görüntü kodlanamadı.")
        case .noFrames: return L("Kayıt sırasında hiç kare alınamadı; dosya oluşturulmadı.")
        }
    }
}

/// SS+'ın kendi pencerelerinden yakalamaya DAHİL edilecek olanlar (ör. Ayarlar).
/// Geçici arayüz pencereleri (seçim katmanı, ada, önizleme kartı, menü paneli,
/// çizim katmanı) `sharingType = .none` ile zaten hiçbir yakalamaya girmez;
/// buradaki liste yalnızca "normal" pencerelerimizi görünür kılar.
enum CaptureVisibility {
    static var capturableOwnWindowIDs: Set<CGWindowID> = []
}

/// Ekran görüntüsü motoru — sürüme göre yönlendirir.
///
/// • macOS 14+: ScreenCaptureKit `SCScreenshotManager` (imleç, en iyi çözünürlük).
/// • Daha eski (10.15–13): CoreGraphics `CGWindowListCreateImage`. SS+'ın kendi
///   pencereleri `sharingType = .none` olduğundan her iki yolda da görüntüye girmez.
enum CaptureEngine {

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Global Cocoa (alt-sol orijin) koordinatındaki dikdörtgeni,
    /// ekranın kendi üst-sol orijinli koordinat uzayına çevirir.
    static func localTopLeftRect(_ globalRect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: globalRect.minX - screen.frame.minX,
            y: screen.frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    @MainActor
    static func capture(globalRect: CGRect, screen: NSScreen) async throws -> CGImage {
        let raw: CGImage
        if #available(macOS 14, *) {
            raw = try await SCKScreenshot.capture(globalRect: globalRect, screen: screen)
        } else {
            raw = try LegacyCapture.capture(globalRect: globalRect, screen: screen)
        }
        // IOSurface destekli orijinal burada bırakılır; kopya sıradan bellek.
        return autoreleasepool { ImageFile.mallocBackedCopy(raw) }
    }

    @MainActor
    static func captureWindow(id: CGWindowID, fallbackRect: CGRect, screen: NSScreen) async throws -> CGImage {
        let raw: CGImage
        if #available(macOS 14, *) {
            raw = try await SCKScreenshot.captureWindow(id: id, fallbackRect: fallbackRect, screen: screen)
        } else {
            raw = try LegacyCapture.captureWindow(id: id, fallbackRect: fallbackRect, screen: screen)
        }
        return autoreleasepool { ImageFile.mallocBackedCopy(raw) }
    }

    @MainActor
    static func captureDisplay(screen: NSScreen) async throws -> CGImage {
        try await capture(globalRect: screen.frame, screen: screen)
    }
}

// MARK: - ScreenCaptureKit ortak parçalar (macOS 12.3+)

@available(macOS 12.3, *)
enum SCKContent {
    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw mapped(error)
        }
    }

    static func scDisplay(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        let id = CaptureEngine.displayID(for: screen)
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    /// Filtreden çıkarılacak kendi pencerelerimiz: Ayarlar gibi yakalanabilir
    /// olarak kaydedilenler hariç.
    @MainActor
    static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let capturable = CaptureVisibility.capturableOwnWindowIDs
        return content.windows.filter {
            $0.owningApplication?.processID == pid && !capturable.contains($0.windowID)
        }
    }

    /// ScreenCaptureKit hatasını anlamlı bir SS+ hatasına çevirir: yalnızca
    /// gerçek izin sorunları (ön kontrol olumsuz ya da -3801) izin hatası sayılır.
    static func mapped(_ error: Error) -> Error {
        if !CGPreflightScreenCaptureAccess() { return CaptureError.permissionDenied }
        if (error as NSError).code == -3801 { return CaptureError.permissionDenied }
        return error
    }
}

// MARK: - ScreenCaptureKit ekran görüntüsü (macOS 14+)

@available(macOS 14, *)
enum SCKScreenshot {
    @MainActor
    static func capture(globalRect: CGRect, screen: NSScreen) async throws -> CGImage {
        let content = try await SCKContent.shareableContent()
        guard let display = SCKContent.scDisplay(for: screen, in: content) else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: SCKContent.ownWindows(in: content))
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = CaptureEngine.localTopLeftRect(globalRect, on: screen)
        config.width = Int(globalRect.width * scale)
        config.height = Int(globalRect.height * scale)
        config.showsCursor = SettingsStore.shared.showCursor
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    static func captureWindow(id: CGWindowID, fallbackRect: CGRect, screen: NSScreen) async throws -> CGImage {
        let content = try await SCKContent.shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            // Pencere kaybolduysa çerçevesini ekrandan kırp
            return try await capture(globalRect: fallbackRect, screen: screen)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - CoreGraphics yolu (macOS 10.15 – 13)

enum LegacyCapture {
    /// Cocoa global (alt-sol orijin) → CoreGraphics global (birincil ekranın üst-sol köşesi).
    static func cgRect(fromCocoa rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func capture(globalRect: CGRect, screen: NSScreen) throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        guard let image = CGWindowListCreateImage(
            cgRect(fromCocoa: globalRect),
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else { throw CaptureError.noDisplay }
        return image
    }

    static func captureWindow(id: CGWindowID, fallbackRect: CGRect, screen: NSScreen) throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]),
           image.width > 1, image.height > 1 {
            return image
        }
        return try capture(globalRect: fallbackRect, screen: screen)
    }
}
