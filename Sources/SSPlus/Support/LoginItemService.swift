import AppKit
import ServiceManagement

/// Girişte başlatma: macOS 13+ `SMAppService`; daha eski sürümlerde
/// ~/Library/LaunchAgents altında bir başlatma ajanı.
enum LoginItemService {
    private static let label = "com.ssplus.app.launch"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Yalnızca paketlenmiş uygulamada anlamlı (`swift run` değil).
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ on: Bool) throws {
        if #available(macOS 13, *) {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return
        }
        if on {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundleURL.path],
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: agentURL, options: .atomic)
            run("/bin/launchctl", ["load", "-w", agentURL.path])
        } else {
            run("/bin/launchctl", ["unload", "-w", agentURL.path])
            try? FileManager.default.removeItem(at: agentURL)
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }
}
