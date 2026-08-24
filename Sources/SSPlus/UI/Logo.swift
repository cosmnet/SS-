import SwiftUI

/// SS+ vektör markası.
///
/// Tamamen `Path`/`Canvas` ile çizilir — SF Symbol kullanılmaz. Yuvarlatılmış
/// vizör çerçevesinin dört köşe ayracı pembe→mor degrade konturla çizilir,
/// sağ alt köşeye dolu "+" rozeti oturur. Rozetin çevresi konturdan temiz
/// biçimde ayrılsın diye ayraç katmanına ters kırpma uygulanır; böylece mark
/// zeminden bağımsız olarak 14pt'de de 28pt'de de net görünür.
struct SSPlusLogoView: View {
    /// Markın kare kenar uzunluğu (punto).
    var size: CGFloat = 16
    /// Sağ alttaki "+" rozeti çizilsin mi.
    var showsBadge: Bool = true

    private static let strokeGradient = Gradient(colors: [
        Color(red: 1.00, green: 0.36, blue: 0.62),   // pembe
        Color(red: 0.62, green: 0.34, blue: 0.98),   // mor
    ])

    private static let badgeGradient = Gradient(colors: [
        Color(red: 1.00, green: 0.42, blue: 0.68),
        Color(red: 0.58, green: 0.31, blue: 0.96),
    ])

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            guard side > 2 else { return }

            let line = max(1.2, side * 0.105)
            let badgeDiameter = showsBadge ? side * 0.44 : 0
            let frameSide = side * (showsBadge ? 0.84 : 1.0)

            let markRect = CGRect(
                x: line / 2,
                y: line / 2,
                width: max(1, frameSide - line),
                height: max(1, frameSide - line)
            )
            // Yarıçap + kol, kenarın yarısından belirgin biçimde kısa olmalı;
            // aksi hâlde ayraçlar birleşip kapalı bir dikdörtgene dönüşür.
            let radius = markRect.width * 0.26
            let arm = markRect.width * 0.10

            let badgeRect = CGRect(
                x: side - badgeDiameter,
                y: side - badgeDiameter,
                width: badgeDiameter,
                height: badgeDiameter
            )

            // 1) Köşe ayraçları — rozetin çevresi ters kırpma ile boşaltılır.
            var brackets = context
            if showsBadge {
                let cutout = badgeRect.insetBy(dx: -line * 0.85, dy: -line * 0.85)
                brackets.clip(to: Path(ellipseIn: cutout), options: .inverse)
            }
            brackets.stroke(
                Self.viewfinderPath(in: markRect, radius: radius, arm: arm),
                with: .linearGradient(
                    Self.strokeGradient,
                    startPoint: CGPoint(x: markRect.minX, y: markRect.minY),
                    endPoint: CGPoint(x: markRect.maxX, y: markRect.maxY)
                ),
                style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            )

            // 2) "+" rozeti
            guard showsBadge, badgeDiameter > 3 else { return }
            context.fill(
                Path(ellipseIn: badgeRect),
                with: .linearGradient(
                    Self.badgeGradient,
                    startPoint: CGPoint(x: badgeRect.minX, y: badgeRect.minY),
                    endPoint: CGPoint(x: badgeRect.maxX, y: badgeRect.maxY)
                )
            )
            context.fill(Self.plusPath(in: badgeRect), with: .color(.white))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Yollar

    /// Dört köşe ayracından oluşan vizör çerçevesi.
    private static func viewfinderPath(in rect: CGRect, radius: CGFloat, arm: CGFloat) -> Path {
        let side = min(rect.width, rect.height)
        let r = min(radius, side * 0.4)
        // Kenarın ortasında en az %15'lik bir boşluk kalsın.
        let a = max(0.5, min(arm, side * 0.425 - r))

        var path = Path()

        // Sol üst
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r + a))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + r + a, y: rect.minY),
            radius: r
        )
        path.addLine(to: CGPoint(x: rect.minX + r + a, y: rect.minY))

        // Sağ üst
        path.move(to: CGPoint(x: rect.maxX - r - a, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r + a),
            radius: r
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + a))

        // Sağ alt
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - a))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - r - a, y: rect.maxY),
            radius: r
        )
        path.addLine(to: CGPoint(x: rect.maxX - r - a, y: rect.maxY))

        // Sol alt
        path.move(to: CGPoint(x: rect.minX + r + a, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r - a),
            radius: r
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - a))

        return path
    }

    /// Rozetin içindeki yuvarlatılmış "+" işareti.
    private static func plusPath(in badge: CGRect) -> Path {
        let cx = badge.midX
        let cy = badge.midY
        let armLength = badge.width * 0.50
        let thickness = max(1.0, badge.width * 0.17)
        let corner = CGSize(width: thickness / 2, height: thickness / 2)

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: cx - armLength / 2, y: cy - thickness / 2, width: armLength, height: thickness),
            cornerSize: corner
        )
        path.addRoundedRect(
            in: CGRect(x: cx - thickness / 2, y: cy - armLength / 2, width: thickness, height: armLength),
            cornerSize: corner
        )
        return path
    }
}
