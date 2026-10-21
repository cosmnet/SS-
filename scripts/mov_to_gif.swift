// Ekran kaydını (mov/mp4) animasyonlu GIF'e çevirir. Harici araç gerekmez:
// AVFoundation kareleri okur, ImageIO GIF'i yazar.
//
//   xcrun swift scripts/mov_to_gif.swift <girdi> [çıktı.gif] [--fps 12] [--width 720]
//                                        [--start 0] [--duration 0]   (0 = sonuna kadar)
//
// X/Twitter GIF sınırı 15 MB. Dosya büyük çıkarsa önce --width, sonra --fps düşür.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var input = ""
    var output = ""
    var fps = 12.0
    var width = 720.0
    var start = 0.0
    var duration = 0.0
}

func parse() -> Options {
    var o = Options()
    var rest: [String] = []
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let a = args[i]
        func value() -> Double {
            i += 1
            return i < args.count ? (Double(args[i]) ?? 0) : 0
        }
        switch a {
        case "--fps": o.fps = value()
        case "--width": o.width = value()
        case "--start": o.start = value()
        case "--duration": o.duration = value()
        default: rest.append(a)
        }
        i += 1
    }
    guard let input = rest.first else {
        FileHandle.standardError.write(Data("Kullanım: mov_to_gif.swift <girdi> [çıktı.gif] [--fps 12] [--width 720] [--start 0] [--duration 0]\n".utf8))
        exit(2)
    }
    o.input = input
    o.output = rest.count > 1 ? rest[1] : (input as NSString).deletingPathExtension + ".gif"
    return o
}

let opts = parse()
let url = URL(fileURLWithPath: opts.input)
guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write(Data("✗ Girdi yok: \(url.path)\n".utf8))
    exit(1)
}

let asset = AVURLAsset(url: url)
let total = CMTimeGetSeconds(asset.duration)
let start = max(0, opts.start)
let span = opts.duration > 0 ? min(opts.duration, total - start) : total - start
guard span > 0 else {
    FileHandle.standardError.write(Data("✗ Seçilen aralık boş (video \(String(format: "%.1f", total)) sn).\n".utf8))
    exit(1)
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
// Kareler istenen zamanlardan sapmasın; GIF'te sapma takılma gibi görünür.
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: opts.width, height: 0)

let frameCount = max(1, Int(span * opts.fps))
let times: [NSValue] = (0..<frameCount).map {
    NSValue(time: CMTime(seconds: start + Double($0) / opts.fps, preferredTimescale: 600))
}

let out = URL(fileURLWithPath: opts.output)
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    FileHandle.standardError.write(Data("✗ GIF oluşturulamadı: \(out.path)\n".utf8))
    exit(1)
}
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

let frameProps = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / opts.fps]
] as CFDictionary

// Her zaman için bir geri çağırma gelir (başarılı ya da değil); bittiğini
// yazılan kare sayısıyla değil, gelen geri çağırma sayısıyla anlarız —
// yoksa tek bir hatalı kare betiği asar.
var written = 0
var completed = 0
let lock = NSLock()
let group = DispatchGroup()
group.enter()
generator.generateCGImagesAsynchronously(forTimes: times) { _, image, _, result, error in
    lock.lock()
    if result == .succeeded, let image {
        CGImageDestinationAddImage(dest, image, frameProps)
        written += 1
        if written % 10 == 0 || written == frameCount {
            FileHandle.standardError.write(Data("\r  kare \(written)/\(frameCount)".utf8))
        }
    } else if let error {
        FileHandle.standardError.write(Data("\n  ⚠︎ kare atlandı: \(error.localizedDescription)\n".utf8))
    }
    completed += 1
    let done = completed == frameCount
    lock.unlock()
    if done { group.leave() }
}
group.wait()

guard written > 0, CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("\n✗ Hiç kare yazılamadı.\n".utf8))
    exit(1)
}

// ImageIO başlığı GIF87a yazıyor; döngü bloğu (NETSCAPE2.0) 89a uzantısıdır.
// Katı çözücüler tek tur oynatmasın diye başlığı düzeltiyoruz.
if let handle = try? FileHandle(forUpdating: out) {
    handle.seek(toFileOffset: 0)
    handle.write(Data("GIF89a".utf8))
    try? handle.close()
}

let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
let mb = Double(size ?? 0) / 1_048_576
print("\n✓ \(out.path)")
print(String(format: "  %d kare · %.0f fps · %.0f px genişlik · %.1f MB", written, opts.fps, opts.width, mb))
if mb > 15 {
    print("  ⚠︎ X sınırı 15 MB. --width 560 ya da --fps 10 dene.")
}
