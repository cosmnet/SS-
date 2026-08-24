#!/usr/bin/env swift
//
// SS+ uygulama ikonunu üretir.
//
//   xcrun swift scripts/make_icon.swift [çıktı-dizini]
//
// Markayı (siyah yuvarlatılmış kare zemin + pembe→mor vizör ayraçları + "+"
// rozeti) doğrudan CoreGraphics ile çizer, gerekli tüm boyutlarda PNG üretir ve
// `iconutil` ile tek bir `SSPlus.icns` dosyasına dönüştürür. Çizim geometrisi
// Sources/SSPlus/UI/Logo.swift ile birebir aynıdır.
//
// Çıktı: <çıktı-dizini>/SSPlus.icns   (varsayılan: ./Resources)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Renkler

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

private let strokeColors = [rgb(1.00, 0.36, 0.62), rgb(0.62, 0.34, 0.98)] as CFArray
private let badgeColors = [rgb(1.00, 0.42, 0.68), rgb(0.58, 0.31, 0.96)] as CFArray
private let plateColors = [rgb(0.11, 0.11, 0.13), rgb(0.02, 0.02, 0.03)] as CFArray

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func gradient(_ colors: CFArray) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1])!
}

// MARK: - Yollar

/// Dört köşe ayracından oluşan vizör çerçevesi (üst-sol orijinli uzayda).
private func viewfinderPath(in rect: CGRect, radius: CGFloat, arm: CGFloat) -> CGPath {
    let side = min(rect.width, rect.height)
    let r = min(radius, side * 0.4)
    // Kenarın ortasında belirgin bir boşluk kalsın; aksi hâlde ayraçlar birleşip
    // kapalı bir dikdörtgene dönüşür.
    let a = max(0.5, min(arm, side * 0.425 - r))

    let path = CGMutablePath()

    // Sol üst
    path.move(to: CGPoint(x: rect.minX, y: rect.minY + r + a))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + r + a, y: rect.minY), radius: r)
    path.addLine(to: CGPoint(x: rect.minX + r + a, y: rect.minY))

    // Sağ üst
    path.move(to: CGPoint(x: rect.maxX - r - a, y: rect.minY))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r + a), radius: r)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + a))

    // Sağ alt
    path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - a))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - r - a, y: rect.maxY), radius: r)
    path.addLine(to: CGPoint(x: rect.maxX - r - a, y: rect.maxY))

    // Sol alt
    path.move(to: CGPoint(x: rect.minX + r + a, y: rect.maxY))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r - a), radius: r)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - a))

    return path
}

/// Rozetin içindeki yuvarlatılmış "+" işareti.
private func plusPath(in badge: CGRect) -> CGPath {
    let armLength = badge.width * 0.50
    let thickness = max(1, badge.width * 0.17)
    let radius = thickness / 2
    let path = CGMutablePath()
    path.addRoundedRect(
        in: CGRect(x: badge.midX - armLength / 2, y: badge.midY - thickness / 2,
                   width: armLength, height: thickness),
        cornerWidth: radius, cornerHeight: radius
    )
    path.addRoundedRect(
        in: CGRect(x: badge.midX - thickness / 2, y: badge.midY - armLength / 2,
                   width: thickness, height: armLength),
        cornerWidth: radius, cornerHeight: radius
    )
    return path
}

// MARK: - Çizim

private func drawMark(in ctx: CGContext, origin: CGPoint, side: CGFloat, showsBadge: Bool) {
    let line = max(1.2, side * 0.105)
    let badgeDiameter = showsBadge ? side * 0.44 : 0
    let frameSide = side * (showsBadge ? 0.84 : 1.0)

    let markRect = CGRect(
        x: origin.x + line / 2,
        y: origin.y + line / 2,
        width: max(1, frameSide - line),
        height: max(1, frameSide - line)
    )
    let radius = markRect.width * 0.26
    let arm = markRect.width * 0.10
    let badgeRect = CGRect(
        x: origin.x + side - badgeDiameter,
        y: origin.y + side - badgeDiameter,
        width: badgeDiameter,
        height: badgeDiameter
    )

    // 1) Köşe ayraçları — rozetin çevresi ters kırpma ile boşaltılır.
    ctx.saveGState()
    if showsBadge {
        let cutout = badgeRect.insetBy(dx: -line * 0.85, dy: -line * 0.85)
        ctx.addRect(ctx.boundingBoxOfClipPath)
        ctx.addEllipse(in: cutout)
        ctx.clip(using: .evenOdd)
    }
    ctx.addPath(viewfinderPath(in: markRect, radius: radius, arm: arm))
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(strokeColors),
        start: CGPoint(x: markRect.minX, y: markRect.minY),
        end: CGPoint(x: markRect.maxX, y: markRect.maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    guard showsBadge, badgeDiameter > 3 else { return }

    // 2) "+" rozeti
    ctx.saveGState()
    ctx.addEllipse(in: badgeRect)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(badgeColors),
        start: CGPoint(x: badgeRect.minX, y: badgeRect.minY),
        end: CGPoint(x: badgeRect.maxX, y: badgeRect.maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(plusPath(in: badgeRect))
    ctx.fillPath()
}

private func renderIcon(pixels: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Üst-sol orijinli uzaya geç: Logo.swift'teki geometri birebir kullanılabilsin.
    let size = CGFloat(pixels)
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    // Zemin: macOS ikon ızgarasına oturan yuvarlatılmış kare.
    let inset = (size * 0.098).rounded()
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = plate.width * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(plateColors),
        start: CGPoint(x: plate.midX, y: plate.minY),
        end: CGPoint(x: plate.midX, y: plate.maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Mark: küçük boyutlarda rozet okunmaz hâle geldiği için düşürülür ve
    // çerçeve büyütülür.
    let showsBadge = pixels >= 64
    let markSide = (plate.width * (showsBadge ? 0.60 : 0.68)).rounded()
    let markOrigin = CGPoint(
        x: (plate.midX - markSide / 2).rounded(),
        y: (plate.midY - markSide / 2).rounded()
    )
    drawMark(in: ctx, origin: markOrigin, side: markSide, showsBadge: showsBadge)

    return ctx.makeImage()
}

private func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Ana akış

let fm = FileManager.default
let outputDir = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources",
    isDirectory: true
)
try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

let iconset = fm.temporaryDirectory.appendingPathComponent("SSPlus-\(UUID().uuidString).iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

/// Piksel ölçüsü → o ölçüyle yazılacak iconset dosya adları.
let names: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]

for pixels in names.keys.sorted() {
    guard let image = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("✗ \(pixels)px çizilemedi\n".utf8))
        exit(1)
    }
    for name in names[pixels]! {
        guard writePNG(image, to: iconset.appendingPathComponent(name)) else {
            FileHandle.standardError.write(Data("✗ \(name) yazılamadı\n".utf8))
            exit(1)
        }
    }
}

let icns = outputDir.appendingPathComponent("SSPlus.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("✗ iconutil başarısız (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}

let bytes = (try? fm.attributesOfItem(atPath: icns.path)[.size] as? Int) ?? 0
print("✓ İkon üretildi: \(icns.path) (\(bytes) bayt)")
