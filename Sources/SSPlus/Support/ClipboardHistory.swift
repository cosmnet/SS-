import AppKit
import Combine

// MARK: - Girdi

/// Pano geçmişindeki tek bir kopyalama. Görüntüler tam çözünürlükte diske,
/// küçük önizlemeleri belleğe alınır; metinler doğrudan manifestte saklanır.
struct ClipboardEntry: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    let date: Date
    /// kind == .text: metnin kendisi (uzunluğu sınırlanır)
    var text: String?
    /// kind == .image: kayıt klasöründeki PNG dosyasının adı
    var imageFile: String?
}

// MARK: - Depo

/// Sistem panosunu izler ve son kopyalamaları arşivler.
///
/// Şifre yöneticileri gibi gizli içerik üreten uygulamalar panoyu
/// `org.nspasteboard.ConcealedType` ile işaretler; bunlar arşive ALINMAZ.
/// SS+'ın kendi kopyaladığı ekran görüntüleri de arşive düşer — bu bilinçli
/// bir tercih: ada ve menü paneli son yakalamalara buradan erişir.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var entries: [ClipboardEntry] = []

    /// Arayüzde gösterilen küçük önizlemeler (bellekte).
    private var thumbnails: [UUID: NSImage] = [:]

    private var lastChangeCount: Int
    private var timer: Timer?
    private var started = false

    static let maxEntries = 10
    private static let maxTextLength = 5000
    private static let thumbnailEdge: CGFloat = 192

    /// ~/Library/Application Support/SSPlus/Clipboard
    private let storeDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SSPlus/Clipboard", isDirectory: true)
    }()

    private var manifestURL: URL {
        storeDirectory.appendingPathComponent("manifest.json")
    }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        load()
    }

    /// AppDelegate açılışta bir kez çağırır; pano izleme başlar.
    func start() {
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: İzleme

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Gizli (şifre yöneticisi vb.) içerik arşivlenmez
        if let types = pasteboard.types,
           types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let rep = image.representations.first,
           rep.size.width >= 16, rep.size.height >= 16 {
            add(image: image)
            return
        }

        if let raw = pasteboard.string(forType: .string) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                add(text: String(text.prefix(Self.maxTextLength)))
            }
        }
    }

    private func add(text: String) {
        // Aynı içerik varsa en üste taşı (kopya üretme)
        entries.removeAll { $0.kind == .text && $0.text == text }
        entries.insert(ClipboardEntry(id: UUID(), kind: .text, date: Date(), text: text, imageFile: nil), at: 0)
        trim()
        save()
    }

    private func add(image: NSImage) {
        guard let full = image.pngData(), !full.isEmpty else { return }
        // Aynı görüntü arka arkaya iki kez düşmesin
        if let first = entries.first, first.kind == .image,
           let file = first.imageFile,
           let existing = try? Data(contentsOf: storeDirectory.appendingPathComponent(file)),
           existing == full { return }

        let fileName = UUID().uuidString + ".png"
        let url = storeDirectory.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        guard let _ = try? full.write(to: url) else { return }

        let entry = ClipboardEntry(id: UUID(), kind: .image, date: Date(), text: nil, imageFile: fileName)
        thumbnails[entry.id] = image.downscaled(to: Self.thumbnailEdge)
        entries.insert(entry, at: 0)
        trim()
        save()
    }

    private func trim() {
        guard entries.count > Self.maxEntries else { return }
        let removed = entries[Self.maxEntries...]
        entries = Array(entries.prefix(Self.maxEntries))
        for entry in removed {
            thumbnails.removeValue(forKey: entry.id)
            if let file = entry.imageFile {
                try? FileManager.default.removeItem(at: storeDirectory.appendingPathComponent(file))
            }
        }
    }

    // MARK: Erişim

    /// Listelerde gösterilen küçük görüntü.
    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard entry.kind == .image, let file = entry.imageFile else { return nil }
        if let cached = thumbnails[entry.id] { return cached }
        guard let full = NSImage(contentsOf: storeDirectory.appendingPathComponent(file)) else { return nil }
        let thumb = full.downscaled(to: Self.thumbnailEdge)
        thumbnails[entry.id] = thumb
        return thumb
    }

    /// Öğeyi panoya geri yazar.
    func recopy(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case .text:
            pasteboard.setString(entry.text ?? "", forType: .string)
        case .image:
            guard let file = entry.imageFile,
                  let image = NSImage(contentsOf: storeDirectory.appendingPathComponent(file)) else { return }
            pasteboard.writeObjects([image])
        }
    }

    /// Pazarlama ekran görüntüsü için bellekte örnek pano. Manifest'e yazılmaz.
    func installExportFixtures() {
        func swatch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSImage {
            let img = NSImage(size: NSSize(width: 192, height: 128))
            img.lockFocus()
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: img.size)).fill()
            img.unlockFocus()
            return img
        }
        let a = UUID(), b = UUID(), c = UUID()
        thumbnails[a] = swatch(1, 0.36, 0.62)
        thumbnails[b] = swatch(0.62, 0.34, 0.98)
        thumbnails[c] = swatch(0.12, 0.14, 0.22)
        entries = [
            ClipboardEntry(id: a, kind: .image, date: Date(), text: nil, imageFile: "export-a.png"),
            ClipboardEntry(id: UUID(), kind: .text, date: Date().addingTimeInterval(-40), text: "⌘– ile yakala, yerinde çiz, kaybol.", imageFile: nil),
            ClipboardEntry(id: b, kind: .image, date: Date().addingTimeInterval(-80), text: nil, imageFile: "export-b.png"),
            ClipboardEntry(id: UUID(), kind: .text, date: Date().addingTimeInterval(-120), text: "Son 10 kopya adada ve menü panelinde.", imageFile: nil),
            ClipboardEntry(id: c, kind: .image, date: Date().addingTimeInterval(-180), text: nil, imageFile: "export-c.png"),
            ClipboardEntry(id: UUID(), kind: .text, date: Date().addingTimeInterval(-240), text: "https://ssplus.app", imageFile: nil),
        ]
    }

    func clear() {
        for entry in entries where entry.kind == .image {
            if let file = entry.imageFile {
                try? FileManager.default.removeItem(at: storeDirectory.appendingPathComponent(file))
            }
        }
        entries.removeAll()
        thumbnails.removeAll()
        save()
    }

    // MARK: Kalıcılık

    private func save() {
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
        // Diskte kalmayan görüntüleri at
        entries = stored.filter { entry in
            guard entry.kind == .image else { return true }
            guard let file = entry.imageFile else { return false }
            return FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent(file).path)
        }
        entries = Array(entries.prefix(Self.maxEntries))
    }
}

// MARK: - NSImage yardımcıları

extension NSImage {
    /// En uzun kenarı `edge` olacak şekilde küçültülmüş kopya.
    func downscaled(to edge: CGFloat) -> NSImage {
        let size = size
        guard size.width > 0, size.height > 0 else { return self }
        let scale = min(edge / size.width, edge / size.height)
        guard scale < 1 else { return self }
        let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1)
        scaled.unlockFocus()
        return scaled
    }

    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
