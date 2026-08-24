import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case noWindow
    case permissionDenied
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Ekran bulunamadı."
        case .noWindow: return "Pencere bulunamadı."
        case .permissionDenied: return "Ekran kaydı izni gerekiyor. Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı bölümünden SS+ için izin verin."
        case .encodeFailed: return "Görüntü kodlanamadı."
        }
    }
}

enum CaptureEngine {

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func scDisplay(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        let id = displayID(for: screen)
        return content.displays.first { $0.displayID == id } ?? content.displays.first
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

    private static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }

    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw mapped(error)
        }
    }

    /// ScreenCaptureKit hatasını anlamlı bir SS+ hatasına çevirir.
    ///
    /// Eskiden buradaki HER hata "izin gerekiyor" sayılıyordu; ilgisiz bir
    /// aksaklıkta bile izin uyarısı açıldığı için ayar penceresi durmadan
    /// karşımıza çıkıyordu. Artık yalnızca gerçek izin sorunları öyle işaretlenir:
    /// sistem ön kontrolü olumsuzsa ya da ScreenCaptureKit açıkça
    /// `SCStreamErrorUserDeclined` (-3801) döndüyse.
    private static func mapped(_ error: Error) -> Error {
        if !CGPreflightScreenCaptureAccess() { return CaptureError.permissionDenied }
        if (error as NSError).code == -3801 { return CaptureError.permissionDenied }
        return error
    }

    // MARK: - Ekran görüntüleri

    @MainActor
    static func capture(globalRect: CGRect, screen: NSScreen) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = scDisplay(for: screen, in: content) else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows(in: content))
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = localTopLeftRect(globalRect, on: screen)
        config.width = Int(globalRect.width * scale)
        config.height = Int(globalRect.height * scale)
        config.showsCursor = SettingsStore.shared.showCursor
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    static func captureWindow(id: CGWindowID, fallbackRect: CGRect, screen: NSScreen) async throws -> CGImage {
        let content = try await shareableContent()
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

    @MainActor
    static func captureDisplay(screen: NSScreen) async throws -> CGImage {
        try await capture(globalRect: screen.frame, screen: screen)
    }
}
