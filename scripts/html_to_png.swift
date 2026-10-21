// Yerel bir HTML dosyasını istenen boyutta PNG'ye çevirir (WKWebView anlık
// görüntüsü). Pazarlama görsellerini tasarımı HTML/CSS'te tutarak üretmek için.
//
//   xcrun swift scripts/html_to_png.swift <girdi.html> <çıktı.png> [genişlik] [yükseklik] [ölçek]
//
// Ölçek 2 → retina (çıktı 2× piksel). Varsayılan 1600×900, ölçek 2.

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("Kullanım: html_to_png.swift <girdi.html> <çıktı.png> [genişlik] [yükseklik] [ölçek]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3]) ?? 1600 : 1600
let height = args.count > 4 ? Double(args[4]) ?? 900 : 900
let scale = args.count > 5 ? Double(args[5]) ?? 2 : 2

final class Snapper: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let output: URL
    let scale: Double
    init(size: CGSize, output: URL, scale: Double) {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        self.output = output
        self.scale = scale
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Yazı tipleri ve geçişler otursun diye kısa bir soluk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.snap() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("✗ Sayfa yüklenemedi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    private func snap() {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: web.frame.size)
        config.snapshotWidth = NSNumber(value: web.frame.width * scale)
        web.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("✗ Anlık görüntü alınamadı: \(error?.localizedDescription ?? "bilinmiyor")\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: self.output)
                let px = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
                let kb = png.count / 1024
                print("✓ \(self.output.path)  (\(px) px · \(kb) KB)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("✗ Yazılamadı: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let snapper = Snapper(size: CGSize(width: width, height: height), output: output, scale: scale)
// Yerel dosyalara (görseller) erişebilmesi için üst klasör okuma izniyle yükle.
snapper.web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
app.run()
