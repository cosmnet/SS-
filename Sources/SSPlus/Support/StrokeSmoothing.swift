import AppKit

/// Fareyle çizimde girdi titreşimini yumuşatan sabitleyici.
///
/// Ham nokta ile son yumuşatılmış nokta arasında üstel yaklaşım uygulanır
/// (`smoothing` küçüldükçe hat daha sakin ama biraz daha gecikmeli olur) ve
/// `minStep`'ten yakın noktalar elenerek kalem titremesi giderilir.
final class StrokeStabilizer {
    /// 0'a yakın = çok yumuşak / tembel fırça, 1 = ham girdi.
    var smoothing: CGFloat = 0.45
    /// Bu kadar puntodan kısa hareketler yok sayılır.
    var minStep: CGFloat = 1.0

    private var smoothed: CGPoint?

    func reset(with point: CGPoint) {
        smoothed = point
    }

    /// Sürükleme sırasında her ham nokta için çağrılır.
    /// Eklenmesi gereken yeni yumuşatılmış noktayı döndürür; gerek yoksa nil.
    func add(_ raw: CGPoint) -> CGPoint? {
        guard let last = smoothed else {
            smoothed = raw
            return raw
        }
        let next = CGPoint(
            x: last.x + (raw.x - last.x) * smoothing,
            y: last.y + (raw.y - last.y) * smoothing
        )
        guard hypot(next.x - last.x, next.y - last.y) >= minStep else { return nil }
        smoothed = next
        return next
    }
}

enum StrokePath {
    /// Noktalardan Catmull-Rom → kübik Bézier dönüşümüyle akıcı bir yol kurar.
    ///
    /// Orta-nokta kuadratik yönteme göre köşe kırılmaları daha azdır ve
    /// titreşimli fare girdisinde belirgin şekilde daha akıcı görünür.
    static func smooth(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for p in points.dropFirst() { path.line(to: p) }
            return path
        }

        let count = points.count
        for i in 0..<(count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }
}
