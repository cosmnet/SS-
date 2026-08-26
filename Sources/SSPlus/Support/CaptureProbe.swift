import AppKit
import ScreenCaptureKit

/// Geliştirici tanılaması: ekran görüntüsü motorlarının bıraktığı belleği ölçer.
///   "SS+.app/Contents/MacOS/SSPlus" --capture-probe [sck|cg|both]
/// Her yakalamadan sonra IOSurface ayak izini yazar. Ekran Kaydı izni gerekir.
@MainActor
enum CaptureProbe {
    static func run(_ which: String) async -> Int32 {
        setbuf(stdout, nil)
        guard let screen = NSScreen.main else { print("ekran yok"); return 2 }
        let rect = screen.frame
        print("başlangıç: \(footprintMB()) MB footprint · IOSurface \(ioSurfaceMB()) MB")

        func report(_ tag: String) {
            print("\(tag): footprint \(footprintMB()) MB · IOSurface \(ioSurfaceMB()) MB")
        }

        let scale = screen.backingScaleFactor
        let rounds = which.hasSuffix("8") ? 8 : 3
        for i in 1...rounds {
            do {
                let img: CGImage
                if which == "cg" {
                    img = try LegacyCapture.capture(globalRect: rect, screen: screen)
                } else if #available(macOS 14, *) {
                    img = try await SCKScreenshot.capture(globalRect: rect, screen: screen)
                } else {
                    img = try LegacyCapture.capture(globalRect: rect, screen: screen)
                }
                print("  yakalandı \(img.width)x\(img.height)")
                if which.hasPrefix("deliver") || which == "both" {
                    autoreleasepool { OutputPipeline.deliverImage(img, scale: scale) }
                    report("deliver #\(i)")
                } else {
                    report("ham yakalama #\(i)")
                }
            } catch {
                print("  yakalama hatası: \(error)")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if which == "flow" {
            // Kullanıcı akışının aynısı: tam ekran seçim katmanı açılır, kapanır,
            // ardından yakalama teslim edilir. Katmanın pencere arka deposu
            // (çift tamponlu, ekran boyutunda) serbest kalıyor mu?
            SelectionOverlayController.shared.begin(mode: .rect) { _ in }
            try? await Task.sleep(nanoseconds: 600_000_000)
            SelectionOverlayController.shared.cancel()
            try? await Task.sleep(nanoseconds: 400_000_000)
            report("katman açıldı+kapandı")
            if let img = try? await CaptureEngine.capture(globalRect: rect, screen: screen) {
                OutputPipeline.deliverImage(img, scale: scale)
            }
            report("deliver sonrası")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            report("2 sn sonra")
        }

        // Kısa bekleme: gecikmeli serbest bırakma varsa görülsün.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        report("1.5 sn sonra")
        if which.hasPrefix("deliver") || which == "flow" {
            NSPasteboard.general.clearContents()
            try? await Task.sleep(nanoseconds: 500_000_000)
            report("pano temizlendikten sonra")
        }
        if which.hasSuffix("8") {
            print("heap incelemesi için 25 sn bekleniyor (pid \(ProcessInfo.processInfo.processIdentifier))…")
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            report("bekleme sonu")
        }
        return 0
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) / (1024 * 1024) : -1
    }

    /// vmmap çıktısından IOSurface toplamını okur (kaba ama yeterli).
    private static func ioSurfaceMB() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        task.arguments = ["-summary", "\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        try? task.run(); task.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in out.split(separator: "\n") where line.contains("IOSurface") && !line.contains("IOAccelerator") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count > 1 { return String(cols[1]) }
        }
        return "?"
    }
}
