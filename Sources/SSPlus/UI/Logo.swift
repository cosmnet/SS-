import SwiftUI

/// SS+ vektör markası — yalnızca `Path` ile çizilir (macOS 10.15 uyumlu).
///
/// Yuvarlatılmış vizör çerçevesinin dört köşe ayracı pembe→mor degrade konturla
/// çizilir, sağ alt köşeye dolu "+" rozeti oturur. Ayraç katmanı rozetin
/// çevresinde maske ile boşaltılır; böylece mark her zeminde net görünür.
struct SSPlusLogoView: View {
    var size: CGFloat = 16
    var showsBadge: Bool = true

    private static let strokeGradient = Gradient(colors: [
        Color(red: 1.00, green: 0.36, blue: 0.62),
        Color(red: 0.62, green: 0.34, blue: 0.98),
    ])
    private static let badgeGradient = Gradient(colors: [
        Color(red: 1.00, green: 0.42, blue: 0.68),
        Color(red: 0.58, green: 0.31, blue: 0.96),
    ])

    var body: some View {
        let side = size
        let line = max(1.2, side * 0.105)
        let badgeDiameter = showsBadge ? side * 0.44 : 0
        let frameSide = side * (showsBadge ? 0.84 : 1.0)
        let markRect = CGRect(x: line / 2, y: line / 2, width: max(1, frameSide - line), height: max(1, frameSide - line))
        let radius = markRect.width * 0.26
        let arm = markRect.width * 0.10
        let badgeRect = CGRect(x: side - badgeDiameter, y: side - badgeDiameter, width: badgeDiameter, height: badgeDiameter)
        let cutout = badgeRect.insetBy(dx: -line * 0.85, dy: -line * 0.85)

        return ZStack(alignment: .topLeading) {
            Self.viewfinderPath(in: markRect, radius: radius, arm: arm)
                .stroke(
                    LinearGradient(gradient: Self.strokeGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
                )
                .mask(
                    ZStack {
                        Rectangle().fill(Color.black)
                        if showsBadge {
                            Path(ellipseIn: cutout).fill(Color.black).blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                )
            if showsBadge, badgeDiameter > 3 {
                Path(ellipseIn: badgeRect)
                    .fill(LinearGradient(gradient: Self.badgeGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                Self.plusPath(in: badgeRect).fill(Color.white)
            }
        }
        .frame(width: size, height: size)
    }

    private static func viewfinderPath(in rect: CGRect, radius: CGFloat, arm: CGFloat) -> Path {
        let side = min(rect.width, rect.height)
        let r = min(radius, side * 0.4)
        let a = max(0.5, min(arm, side * 0.425 - r))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r + a))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r + a, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r + a, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - r - a, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r + a), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + a))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - a))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r - a, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - r - a, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + r + a, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r - a), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - a))
        return path
    }

    private static func plusPath(in badge: CGRect) -> Path {
        let cx = badge.midX, cy = badge.midY
        let armLength = badge.width * 0.50
        let thickness = max(1.0, badge.width * 0.17)
        let corner = CGSize(width: thickness / 2, height: thickness / 2)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: cx - armLength / 2, y: cy - thickness / 2, width: armLength, height: thickness), cornerSize: corner)
        path.addRoundedRect(in: CGRect(x: cx - thickness / 2, y: cy - armLength / 2, width: thickness, height: armLength), cornerSize: corner)
        return path
    }
}
