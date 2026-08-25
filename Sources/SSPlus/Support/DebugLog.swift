import Foundation

/// Dosyaya yazan hafif tanılama günlüğü. Bazı kurulumlarda unified log NSLog
/// çıktısını göstermediği için sorun avında dosya tek güvenilir kanaldır.
/// Açmak için: `defaults write com.ssplus.app debugLog -bool true`
/// Dosya: ~/Library/Application Support/SSPlus/debug.log
enum DebugLog {
    nonisolated(unsafe) private static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
    private static let queue = DispatchQueue(label: "ssplus.debuglog")
    nonisolated(unsafe) private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSPlus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()
    nonisolated(unsafe) private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ line: String) {
        guard enabled else { return }
        queue.async {
            let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
