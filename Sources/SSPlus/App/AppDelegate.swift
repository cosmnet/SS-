import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    /// main.swift üst düzey kodu izole değil; oradan örneklenebilmesi için.
    override nonisolated init() {
        super.init()
    }

    // MARK: - Yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = AppState.shared
        setupStatusItem()
        if !ProcessInfo.processInfo.arguments.contains("--export-ui-shots") {
            IslandController.shared.show()
        }
        ClipboardStore.shared.start()
        _ = RecordingDrawController.shared   // ✏️ bildirimi gözlemcisi kurulsun
        reloadHotKeys()
        observeHotkeySettings()
        let exporting = ProcessInfo.processInfo.arguments.contains("--export-ui-shots")
        if !exporting {
            PermissionManager.prepareAtLaunch()
        }

        if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "--export-ui-shots"),
           ProcessInfo.processInfo.arguments.indices.contains(idx + 1) {
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[idx + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                UIShotExport.run(to: dir)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menü çubuğu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SS+")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SS+"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Sol tık: aşağı açılan dosya/pano paneli. Sağ tık: klasik menü.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            StatusPanelController.shared.close()
            let menu = buildMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
        } else {
            StatusPanelController.shared.toggle(relativeTo: sender)
        }
    }

    // MARK: - Kısayollar

    private func registerHotKeys() {
        let capture = SettingsStore.shared.captureHotkey
        if let char = capture.character.first {
            HotKeyManager.shared.registerForCharacter(char, modifiers: capture.carbonModifiers, id: 1) {
                MainActor.assumeIsolated {
                    AppState.shared.beginCapture(SelectionMode(rawValue: SettingsStore.shared.lastModeRaw) ?? .rect)
                }
            }
        }
        let record = SettingsStore.shared.recordHotkey
        if let char = record.character.first {
            HotKeyManager.shared.registerForCharacter(char, modifiers: record.carbonModifiers, id: 2) {
                MainActor.assumeIsolated {
                    AppState.shared.beginRecordingSelection()
                }
            }
        }
    }

    /// Ayarlardan kısayol değişince sıcak yeniden kayıt.
    func reloadHotKeys() {
        HotKeyManager.shared.unregisterCharacter(id: 1)
        HotKeyManager.shared.unregisterCharacter(id: 2)
        registerHotKeys()
    }

    private func observeHotkeySettings() {
        SettingsStore.shared.$captureHotkeyRaw
            .combineLatest(SettingsStore.shared.$recordHotkeyRaw)
            .dropFirst()   // açılışta zaten kayıtlı
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reloadHotKeys()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menü (sağ tık)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let capture = SettingsStore.shared.captureHotkey
        let record = SettingsStore.shared.recordHotkey

        let captureItem = makeItem("Alan / Pencere Yakala", #selector(captureRect(_:)), key: capture.character.lowercased(), modifiers: capture.cocoaModifiers)
        menu.addItem(captureItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Alan Seç", #selector(captureRect(_:)), key: "r"))
        menu.addItem(makeItem("Pencere Seç", #selector(captureWindow(_:)), key: "w"))
        menu.addItem(makeItem("Tüm Ekranı Yakala", #selector(captureFullScreen(_:)), key: "f"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Video Kaydı Başlat", #selector(toggleRecording(_:)), key: record.character.lowercased(), modifiers: record.cocoaModifiers))
        menu.addItem(.separator())
        menu.addItem(makeItem("Kayıt Klasörünü Aç", #selector(openFolder(_:)), key: "o"))
        menu.addItem(makeItem("Ayarlar…", #selector(openSettings(_:)), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("SS+'ı Kapat", #selector(quitApp(_:)), key: "q"))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: - İşlemler

    @objc private func captureRect(_ sender: Any?) { AppState.shared.beginCapture(.rect) }
    @objc private func captureWindow(_ sender: Any?) { AppState.shared.beginCapture(.window) }
    @objc private func captureFullScreen(_ sender: Any?) { AppState.shared.captureFullScreen() }
    @objc private func toggleRecording(_ sender: Any?) { AppState.shared.beginRecordingSelection() }

    @objc private func openFolder(_ sender: Any?) {
        let folder = SettingsStore.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}
