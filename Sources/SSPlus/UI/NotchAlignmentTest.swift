import AppKit

/// "Çentik Hizalama Testi" — uygulamanın çentiği NEREDE sandığını 5 saniyeliğine
/// ekrana çizer.
///
/// Hizalama hâlâ kaymışsa kullanıcının ekran görüntüsü alıp gönderebilmesi için
/// vardır: dikdörtgen gerçek çentiğin üstüne birebir oturmuyorsa, kaymanın yönü
/// ve miktarı fotoğraftan okunabilir. Pencere tıklamaları geçirir ve süre
/// dolunca kendini kapatır.
@MainActor
enum NotchAlignmentTest {

    private static var window: NSWindow?
    private static var dismissWorkItem: DispatchWorkItem?

    static let duration: TimeInterval = 5

    static func run() {
        dismiss()

        guard let screen = NotchMetrics.hostScreen() else { return }
        let metrics = NotchMetrics.metrics(for: screen)

        let panel = AlignmentWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        // Ekran görüntüsü alınabilmeli: `sharingType` kısıtlanmaz.

        let view = AlignmentView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.metrics = metrics
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        window = panel

        let work = DispatchWorkItem { MainActor.assumeIsolated { dismiss() } }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Ekranın tam çerçevesine oturması için sıkıştırmayı devre dışı bırakır.
private final class AlignmentWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Ölçülen çentik dikdörtgenini ve sayıları çizen katman.
///
/// Görünüm ekranın TAMAMINI kapladığı için pencere-içi koordinat = global
/// koordinat − ekran orijini; başka bir dönüşüm yoktur, dolayısıyla çizim
/// hatası ihtimali kalmaz.
private final class AlignmentView: NSView {
    var metrics: NotchMetrics = .fallback

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let origin = metrics.screenFrame.origin
        let local = CGRect(
            x: metrics.notchRect.minX - origin.x,
            y: metrics.notchRect.minY - origin.y,
            width: metrics.notchRect.width,
            height: metrics.notchRect.height
        )

        if metrics.hasNotch {
            drawNotchOutline(local, in: ctx)
            drawGuides(local, in: ctx)
        }

        drawLegend(below: local, in: ctx)
    }

    private func drawNotchOutline(_ rect: CGRect, in ctx: CGContext) {
        // İçini boya: gerçek çentiğin üstündeyse hiç görünmez, kaymışsa taşan
        // kısım menü çubuğunun üzerinde renkli bir dilim olarak belirir.
        ctx.setFillColor(NSColor.systemPink.withAlphaComponent(0.35).cgColor)
        ctx.fill(rect)

        // Tam sınır: 1.5 punto, kenarın ortasında.
        ctx.setStrokeColor(NSColor.systemPink.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)

        // Köşe nişanları
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        let tick: CGFloat = 14
        for corner in [
            (CGPoint(x: rect.minX, y: rect.minY), CGFloat(1), CGFloat(1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGFloat(-1), CGFloat(1)),
        ] {
            let (p, dx, dy) = corner
            ctx.move(to: CGPoint(x: p.x + dx * tick, y: p.y))
            ctx.addLine(to: p)
            ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * tick))
        }
        ctx.strokePath()
    }

    private func drawGuides(_ rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [6, 5])

        // Çentiğin alt kenarı boyunca yatay kılavuz: gerçek çentiğin bittiği
        // yerle çakışmalı.
        ctx.move(to: CGPoint(x: 0, y: rect.minY))
        ctx.addLine(to: CGPoint(x: bounds.width, y: rect.minY))

        // Sol ve sağ kenar boyunca dikey kılavuzlar
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY - 90))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 90))

        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawLegend(below rect: CGRect, in ctx: CGContext) {
        let title = "SS+ · Çentik Hizalama Testi"
        let body = metrics.debugSummary
        let hint = metrics.hasNotch
            ? "Pembe dikdörtgen çentiğin ÜSTÜNE birebir oturmalı. Taşma varsa bu ekranın fotoğrafını gönder."
            : "Bu ekranda çentik bulunamadı; ada menü çubuğunun altına yerleşir."

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]

        let text = NSMutableAttributedString(string: title + "\n", attributes: titleAttrs)
        text.append(NSAttributedString(string: "\n" + body + "\n\n", attributes: bodyAttrs))
        text.append(NSAttributedString(string: hint, attributes: hintAttrs))

        let maxWidth: CGFloat = 620
        let textSize = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size

        let padding: CGFloat = 18
        let boxWidth = min(maxWidth, textSize.width.rounded(.up)) + padding * 2
        let boxHeight = textSize.height.rounded(.up) + padding * 2
        let anchorY = metrics.hasNotch ? rect.minY : bounds.maxY - metrics.menuBarHeight
        let box = CGRect(
            x: ((bounds.width - boxWidth) / 2).rounded(),
            y: (anchorY - 34 - boxHeight).rounded(),
            width: boxWidth,
            height: boxHeight
        )

        let rounded = CGPath(roundedRect: box, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        ctx.addPath(rounded)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(rounded)
        ctx.strokePath()

        text.draw(with: box.insetBy(dx: padding, dy: padding),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
