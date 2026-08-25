import AppKit
import Combine
import SwiftUI

// MARK: - Eski macOS sürümleri için uyumluluk katmanı
//
// Dağıtım hedefi macOS 10.15. macOS 11/12/14'te eklenen SwiftUI ve AppKit
// arabirimleri burada `#available` ile sarılır; eski sürümlerde makul bir
// yedek gösterilir. Uygulama kodu yalnızca buradaki yardımcıları kullanır.

/// SF Symbol (macOS 11+); daha eski sürümlerde Unicode yedeği.
struct SymbolImage: View {
    let name: String
    var body: some View {
        if #available(macOS 11, *) {
            Image(systemName: name)
        } else {
            Text(Self.fallback(for: name))
        }
    }

    /// Simge adı → eski sürümlerde gösterilecek karakter.
    static func fallback(for name: String) -> String {
        let table: [String: String] = [
            "camera.viewfinder": "⌖", "rectangle.dashed": "▭", "macwindow": "▣", "display": "🖥",
            "record.circle": "●", "gearshape": "⚙", "gearshape.fill": "⚙", "stop.fill": "■",
            "pencil.tip.crop.circle": "✎", "pencil.tip": "✎", "highlighter": "▮", "arrow.up.right": "↗",
            "line.diagonal": "╱", "rectangle": "▭", "circle": "○", "textformat": "T",
            "arrow.uturn.backward": "↶", "arrow.uturn.forward": "↷", "checkmark": "✓",
            "doc.on.doc": "⧉", "text.viewfinder": "⌶", "folder": "▤", "folder.fill": "▤", "trash": "✕",
            "xmark": "✕", "link": "⛓", "arrow.up.right.square": "↗", "film.fill": "▶", "film": "▶",
            "photo": "▧", "photo.on.rectangle.angled": "▧", "text.quote": "❝", "text.alignleft": "≡",
            "tray": "▽", "arrow.clockwise": "↻", "power": "⏻", "keyboard": "⌨", "cursorarrow.rays": "➤",
            "command": "⌘", "star.fill": "★", "star": "☆", "crown": "♛", "sparkles": "✦",
            "speedometer": "◔", "speaker.wave.2.fill": "🔊", "scroll": "≣", "icloud.and.arrow.up": "☁",
            "person.crop.circle": "◉", "person.crop.circle.fill.badge.checkmark": "◉",
            "checkmark.seal.fill": "✓", "exclamationmark.triangle.fill": "⚠", "externaldrive": "▬",
            "doc.on.clipboard": "📋", "rectangle.topthird.inset.filled": "▬", "globe": "◍",
            "wrench.and.screwdriver": "🔧", "paintpalette": "🎨", "film.stack": "▶",
        ]
        return table[name] ?? "•"
    }
}

/// `Label(title, systemImage:)` (macOS 11+) yerine.
struct CompatLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 5) {
            SymbolImage(name: systemImage)
            Text(title)
        }
    }
}

/// `ProgressView` (macOS 11+) yerine küçük dönen simge.
struct CompatSpinner: View {
    var body: some View {
        if #available(macOS 11, *) {
            ProgressView().controlSize(.small)
        } else {
            Text("…")
        }
    }
}

/// Çentiğin altına inen gövde: üst köşeler düz, alt köşeler yuvarlak
/// (`UnevenRoundedRectangle` macOS 14+ olduğu için elle çizilir).
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Cam (material) zemin: macOS 12+ gerçek material, öncesinde yarı saydam koyu renk.
struct MaterialFill<S: Shape>: View {
    let shape: S
    var body: some View {
        if #available(macOS 12, *) {
            shape.fill(.ultraThinMaterial)
        } else {
            shape.fill(Color(white: 0.12, opacity: 0.88))
        }
    }
}

/// macOS 12+ `.regularMaterial`; öncesinde koyu yarı saydam.
struct RegularMaterialFill<S: Shape>: View {
    let shape: S
    var body: some View {
        if #available(macOS 12, *) {
            shape.fill(.regularMaterial)
        } else {
            shape.fill(Color(white: 0.16, opacity: 0.94))
        }
    }
}

extension View {
    /// `.help()` macOS 11+.
    @ViewBuilder
    func compatHelp(_ text: String) -> some View {
        if #available(macOS 11, *) {
            self.help(text)
        } else {
            self
        }
    }

    /// `.animation(_:value:)` macOS 12+; öncesinde örtük animasyon.
    @ViewBuilder
    func compatAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        if #available(macOS 12, *) {
            self.animation(animation, value: value)
        } else {
            self.animation(animation)
        }
    }

    /// `.tracking()` macOS 11+.
    @ViewBuilder
    func compatTracking(_ value: CGFloat) -> some View {
        if #available(macOS 11, *) {
            self
        } else {
            self
        }
    }
}

extension Text {
    /// `Text.tracking` macOS 11+; eski sürümde metin olduğu gibi kalır.
    func compatTracking(_ value: CGFloat) -> Text {
        if #available(macOS 11, *) {
            return self.tracking(value)
        }
        return self
    }
}

extension Color {
    /// `Color.accentColor` macOS 11+; öncesinde sistem vurgu rengi NSColor'dan alınır.
    static var compatAccent: Color {
        if #available(macOS 11, *) { return Color.accentColor }
        return Color.from(NSColor.controlAccentColor)
    }

    /// `Color(nsColor:)` macOS 12+; eski sürümlerde sRGB bileşenlerinden kurulur.
    static func from(_ nsColor: NSColor) -> Color {
        if #available(macOS 12, *) {
            return Color(nsColor: nsColor)
        }
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return Color(.sRGB, red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), opacity: Double(c.alphaComponent))
    }
}

// MARK: - URLSession async (Foundation'ın async API'leri macOS 12+)

extension URLSession {
    func compatData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(macOS 12, *) {
            return try await data(for: request)
        }
        return try await withCheckedThrowingContinuation { cont in
            let task = dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), response ?? URLResponse()))
            }
            task.resume()
        }
    }

    func compatUpload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        if #available(macOS 12, *) {
            return try await upload(for: request, fromFile: fileURL)
        }
        return try await withCheckedThrowingContinuation { cont in
            let task = uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), response ?? URLResponse()))
            }
            task.resume()
        }
    }
}

// MARK: - Sistem simgesi (menü çubuğu)

extension NSImage {
    /// `NSImage(systemSymbolName:)` macOS 11+; eski sürümlerde vizör simgesi elle çizilir.
    static func compatSymbol(_ name: String, description: String) -> NSImage? {
        if #available(macOS 11, *) {
            return NSImage(systemSymbolName: name, accessibilityDescription: description)
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            let arm: CGFloat = 4
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            for (corner, dx, dy) in [
                (CGPoint(x: r.minX, y: r.minY), CGFloat(1), CGFloat(1)),
                (CGPoint(x: r.maxX, y: r.minY), CGFloat(-1), CGFloat(1)),
                (CGPoint(x: r.maxX, y: r.maxY), CGFloat(-1), CGFloat(-1)),
                (CGPoint(x: r.minX, y: r.maxY), CGFloat(1), CGFloat(-1)),
            ] {
                path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                path.line(to: corner)
                path.line(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            }
            NSColor.black.setStroke()
            path.stroke()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 2.5, y: r.midY - 2.5, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
