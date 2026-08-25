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
        let exporting = ProcessInfo.processInfo.arguments.contains("--export-ui-shots")
        if !exporting {
            IslandController.shared.show()
        }
        ClipboardStore.shared.start()
        _ = RecordingDrawController.shared   // ✏️ bildirimi gözlemcisi kurulsun
        reloadHotKeys()
        observeHotkeySettings()
        if !exporting {
            PermissionManager.prepareAtLaunch()
            applyLoginItemDefault()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                UpdateChecker.checkAutomaticallyIfDue()
            }
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

    /// İlk açılışta girişte başlatma VARSAYILAN olarak açılır (kullanıcı
    /// Ayarlar'dan kapatabilir; bayrak sayesinde bir daha zorlanmaz).
    private func applyLoginItemDefault() {
        guard LoginItemService.available else { return }
        let key = "loginItemDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? LoginItemService.setEnabled(true)
    }

    /// Kayıt sürerken çıkış (⌘Q, menü, oturum kapatma, izin onarımı sonrası
    /// yeniden başlatma…) dosyayı yarım bırakırdı. Önce kaydı kapat, dosya
    /// diske yazılınca çık.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.isRecording else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.finishRecordingForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsStore.shared.clearClipboardHistoryOnQuit {
            ClipboardStore.shared.clear()
        }
    }

    // MARK: - Menü çubuğu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage.compatSymbol("camera.viewfinder", description: "SS+")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SS+"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Sol tık: aşağı açılan dosya/pano paneli. Sağ tık (veya ⌃ tık): klasik menü.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
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
        let record = SettingsStore.shared.recordHotkey
        var problems: [String] = []

        if capture == record {
            problems.append(L("Yakalama ve kayıt kısayolları aynı (%@); yalnızca biri çalışır.", capture.display))
        }

        if let char = capture.character.first {
            let ok = HotKeyManager.shared.registerForCharacter(char, modifiers: capture.carbonModifiers, id: 1) {
                MainActor.assumeIsolated {
                    AppState.shared.beginCapture(SelectionMode(rawValue: SettingsStore.shared.lastModeRaw) ?? .rect)
                }
            }
            if !ok { problems.append(L("Yakalama kısayolu (%@) sisteme kaydedilemedi.", capture.display)) }
        }
        if let char = record.character.first {
            let ok = HotKeyManager.shared.registerForCharacter(char, modifiers: record.carbonModifiers, id: 2) {
                MainActor.assumeIsolated {
                    AppState.shared.toggleRecording()
                }
            }
            if !ok { problems.append(L("Kayıt kısayolu (%@) sisteme kaydedilemedi.", record.display)) }
        }
        AppState.shared.hotkeyWarning = problems.isEmpty ? nil : problems.joined(separator: "\n")
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
        let recording = AppState.shared.isRecording

        let versionItem = NSMenuItem(title: "SS+ \(UpdateChecker.displayVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let captureItem = makeItem(L("Alan / Pencere Yakala"), #selector(captureRect(_:)), key: capture.character.lowercased(), modifiers: capture.cocoaModifiers)
        captureItem.isEnabled = !recording
        menu.addItem(captureItem)
        menu.addItem(.separator())
        for item in [
            makeItem(L("Alan Seç"), #selector(captureRect(_:)), key: ""),
            makeItem(L("Pencere Seç"), #selector(captureWindow(_:)), key: ""),
            makeItem(L("Tüm Ekranı Yakala"), #selector(captureFullScreen(_:)), key: ""),
        ] {
            item.isEnabled = !recording
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem(
            recording ? L("Kaydı Durdur") : L("Video Kaydı Başlat"),
            #selector(toggleRecording(_:)),
            key: record.character.lowercased(),
            modifiers: record.cocoaModifiers
        ))
        menu.addItem(.separator())
        menu.addItem(makeItem(L("Kayıt Klasörünü Aç"), #selector(openFolder(_:)), key: ""))
        menu.addItem(makeItem(L("Ayarlar…"), #selector(openSettings(_:)), key: ","))
        menu.addItem(makeItem(L("Güncellemeleri denetle…"), #selector(checkForUpdates(_:)), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem(L("SS+'ı Kapat"), #selector(quitApp(_:)), key: "q"))
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
    @objc private func toggleRecording(_ sender: Any?) { AppState.shared.toggleRecording() }

    @objc private func openFolder(_ sender: Any?) {
        let folder = SettingsStore.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Task { await UpdateChecker.check(userInitiated: true) }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}
