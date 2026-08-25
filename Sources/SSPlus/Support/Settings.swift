import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - Kısayol modeli

/// Karakter + Carbon değiştirici maskesi olarak saklanan, kullanıcı tarafından
/// değiştirilebilir bir global kısayol.
struct HotkeySetting: Equatable {
    /// Değiştiricisiz basıldığında üretilen karakter (örn. "-", "a", "5").
    var character: String
    /// Carbon değiştirici maskesi (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var carbonModifiers: UInt32

    /// Varsayılanlar ⌃ içerir: düz ⌘– hemen her uygulamada "Uzaklaştır"
    /// kısayoludur ve global kayıt onu bütün Mac'ten çalardı.
    static let defaultCapture = HotkeySetting(character: "-", carbonModifiers: UInt32(cmdKey | controlKey))
    static let defaultRecord = HotkeySetting(character: "-", carbonModifiers: UInt32(cmdKey | controlKey | shiftKey))

    /// UserDefaults'a yazılan düz biçim: "karakter|değiştiriciler"
    var serialized: String { "\(character)|\(carbonModifiers)" }

    init(character: String, carbonModifiers: UInt32) {
        self.character = character
        self.carbonModifiers = carbonModifiers
    }

    init?(serialized: String) {
        let parts = serialized.split(separator: "|")
        guard parts.count == 2, let mods = UInt32(parts[1]), let first = parts[0].first else { return nil }
        self.character = String(first)
        self.carbonModifiers = mods
    }

    /// NSEvent değiştiricilerini Carbon maskesine çevirir.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    /// Menülerde görüntüleme için Cocoa değiştirici maskesi.
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// "⇧⌘–" benzeri görüntü metni.
    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + character.uppercased()
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg
    var id: String { rawValue }
    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpg: return "JPEG"
        }
    }
    var fileExtension: String { rawValue }
    var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpg: return "image/jpeg"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    @Published var imageFormat: ImageFormat {
        didSet { d.set(imageFormat.rawValue, forKey: "imageFormat") }
    }
    @Published var saveFolderPath: String {
        didSet { d.set(saveFolderPath, forKey: "saveFolderPath") }
    }
    @Published var copyToClipboard: Bool {
        didSet { d.set(copyToClipboard, forKey: "copyToClipboard") }
    }
    @Published var showCursor: Bool {
        didSet { d.set(showCursor, forKey: "showCursor") }
    }
    @Published var playSound: Bool {
        didSet { d.set(playSound, forKey: "playSound") }
    }
    @Published var showPreview: Bool {
        didSet { d.set(showPreview, forKey: "showPreview") }
    }
    @Published var fps: Int {
        didSet { d.set(fps, forKey: "fps") }
    }
    @Published var recordAudio: Bool {
        didSet { d.set(recordAudio, forKey: "recordAudio") }
    }
    @Published var lastModeRaw: String {
        didSet { d.set(lastModeRaw, forKey: "lastModeRaw") }
    }
    /// "mov" | "mp4"
    @Published var videoFormat: String {
        didSet { d.set(videoFormat, forKey: "videoFormat") }
    }
    /// "h264" | "hevc"
    @Published var videoCodec: String {
        didSet { d.set(videoCodec, forKey: "videoCodec") }
    }
    /// 0 = otomatik
    @Published var videoBitrateMbps: Int {
        didSet { d.set(videoBitrateMbps, forKey: "videoBitrateMbps") }
    }
    /// Alan modunda pencere üzerine gelince otomatik pencere yakalama
    @Published var smartWindowDetect: Bool {
        didSet { d.set(smartWindowDetect, forKey: "smartWindowDetect") }
    }
    /// Yakaladıktan sonra yerinde düzenleyiciyi aç
    @Published var editAfterCapture: Bool {
        didSet { d.set(editAfterCapture, forKey: "editAfterCapture") }
    }
    /// Önizleme kartının ekranda kalma süresi (sn)
    @Published var previewSeconds: Double {
        didSet { d.set(previewSeconds, forKey: "previewSeconds") }
    }
    /// Boştayken çentikteki ada gösterilsin mi (kayıt sırasında daima gösterilir)
    @Published var islandEnabled: Bool {
        didSet { d.set(islandEnabled, forKey: "islandEnabled") }
    }
    /// Pano geçmişi tutulsun mu. Kopyalanan HER şey diske yazıldığı için
    /// varsayılan KAPALI; kullanıcı bilerek açar.
    @Published var clipboardHistoryEnabled: Bool {
        didSet { d.set(clipboardHistoryEnabled, forKey: "clipboardHistoryEnabled") }
    }
    /// Uygulama kapanırken pano geçmişini diskten sil
    @Published var clearClipboardHistoryOnQuit: Bool {
        didSet { d.set(clearClipboardHistoryOnQuit, forKey: "clearClipboardHistoryOnQuit") }
    }
    // MARK: Google Drive

    /// Ekran görüntülerini Drive'a yükle
    @Published var driveUploadEnabled: Bool {
        didSet { d.set(driveUploadEnabled, forKey: "driveUploadEnabled") }
    }
    /// Yüklenen dosyayı "bağlantıya sahip herkes" ile paylaş
    @Published var driveShareAnyone: Bool {
        didSet { d.set(driveShareAnyone, forKey: "driveShareAnyone") }
    }
    /// Video kayıtlarını da Drive'a yükle (büyük dosyalar; varsayılan KAPALI)
    @Published var driveUploadVideos: Bool {
        didSet { d.set(driveUploadVideos, forKey: "driveUploadVideos") }
    }
    /// Paylaşım bağlantısını panoya kopyala
    @Published var driveCopyLink: Bool {
        didSet { d.set(driveCopyLink, forKey: "driveCopyLink") }
    }
    /// Drive'da oluşturulacak klasörün adı
    @Published var driveFolderName: String {
        didSet { d.set(driveFolderName, forKey: "driveFolderName") }
    }
    /// Oluşturulan klasörün Drive kimliği (kullanıcı taşısa da geçerli kalır)
    @Published var driveFolderID: String {
        didSet { d.set(driveFolderID, forKey: "driveFolderID") }
    }

    /// Günde bir kez yeni sürüm denetle
    @Published var checkUpdatesAutomatically: Bool {
        didSet { d.set(checkUpdatesAutomatically, forKey: "checkUpdatesAutomatically") }
    }
    /// Son otomatik denetim zamanı
    @Published var lastUpdateCheck: Date {
        didSet { d.set(lastUpdateCheck.timeIntervalSince1970, forKey: "lastUpdateCheck") }
    }

    /// Arayüz dili: "system" | "tr" | "en"
    @Published var languageRaw: String {
        didSet {
            d.set(languageRaw, forKey: "language")
            Localization.preference = AppLanguage(rawValue: languageRaw) ?? .system
        }
    }
    /// Yakalama kısayolu (serileştirilmiş)
    @Published var captureHotkeyRaw: String {
        didSet { d.set(captureHotkeyRaw, forKey: "captureHotkeyRaw") }
    }
    /// Video kaydı kısayolu (serileştirilmiş)
    @Published var recordHotkeyRaw: String {
        didSet { d.set(recordHotkeyRaw, forKey: "recordHotkeyRaw") }
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .system }
        set { languageRaw = newValue.rawValue }
    }
    var captureHotkey: HotkeySetting {
        get { HotkeySetting(serialized: captureHotkeyRaw) ?? .defaultCapture }
        set { captureHotkeyRaw = newValue.serialized }
    }
    var recordHotkey: HotkeySetting {
        get { HotkeySetting(serialized: recordHotkeyRaw) ?? .defaultRecord }
        set { recordHotkeyRaw = newValue.serialized }
    }

    var saveFolder: URL {
        URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private init() {
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "png") ?? .png
        saveFolderPath = d.string(forKey: "saveFolderPath") ?? "~/Desktop"
        copyToClipboard = d.object(forKey: "copyToClipboard") as? Bool ?? true
        showCursor = d.object(forKey: "showCursor") as? Bool ?? false
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        showPreview = d.object(forKey: "showPreview") as? Bool ?? true
        fps = d.object(forKey: "fps") as? Int ?? 30
        recordAudio = d.object(forKey: "recordAudio") as? Bool ?? false
        lastModeRaw = d.string(forKey: "lastModeRaw") ?? "rect"
        videoFormat = d.string(forKey: "videoFormat") ?? "mov"
        videoCodec = d.string(forKey: "videoCodec") ?? "h264"
        videoBitrateMbps = d.object(forKey: "videoBitrateMbps") as? Int ?? 0
        smartWindowDetect = d.object(forKey: "smartWindowDetect") as? Bool ?? true
        editAfterCapture = d.object(forKey: "editAfterCapture") as? Bool ?? false
        previewSeconds = d.object(forKey: "previewSeconds") as? Double ?? 5
        islandEnabled = d.object(forKey: "islandEnabled") as? Bool ?? true
        clipboardHistoryEnabled = d.object(forKey: "clipboardHistoryEnabled") as? Bool ?? false
        clearClipboardHistoryOnQuit = d.object(forKey: "clearClipboardHistoryOnQuit") as? Bool ?? false
        driveUploadEnabled = d.object(forKey: "driveUploadEnabled") as? Bool ?? false
        driveShareAnyone = d.object(forKey: "driveShareAnyone") as? Bool ?? true
        driveUploadVideos = d.object(forKey: "driveUploadVideos") as? Bool ?? false
        driveCopyLink = d.object(forKey: "driveCopyLink") as? Bool ?? true
        driveFolderName = d.string(forKey: "driveFolderName") ?? "SS+"
        driveFolderID = d.string(forKey: "driveFolderID") ?? ""
        checkUpdatesAutomatically = d.object(forKey: "checkUpdatesAutomatically") as? Bool ?? true
        lastUpdateCheck = Date(timeIntervalSince1970: d.double(forKey: "lastUpdateCheck"))
        let storedLanguage = d.string(forKey: "language") ?? "system"
        languageRaw = storedLanguage
        Localization.preference = AppLanguage(rawValue: storedLanguage) ?? .system
        captureHotkeyRaw = d.string(forKey: "captureHotkeyRaw") ?? HotkeySetting.defaultCapture.serialized
        recordHotkeyRaw = d.string(forKey: "recordHotkeyRaw") ?? HotkeySetting.defaultRecord.serialized
    }
}
