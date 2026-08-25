import AppKit
import Carbon.HIToolbox

/// Global kısayolları yönetir.
///
/// Donanım tuş koduna göre kayıt yapmak Türkçe Q gibi ANSI dışı düzenlerde
/// çalışmaz: "-" karakteri farklı bir fiziksel tuşta durur. Bu yüzden asıl
/// yol `registerForCharacter(_:modifiers:id:action:)`'dır — istenen KARAKTERİ
/// üreten tüm tuş kodları yürürlükteki klavye düzeninden çözülür ve her biri
/// için ayrı bir kısayol kaydedilir. Düzen değişince kayıtlar tazelenir.
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// 'SSPL'
    private static let signature = OSType(0x5353504C)
    /// Kaydı yapılan her karakter grubunun kendine ayrılmış id aralığı.
    private static let idsPerGroup: UInt32 = 100
    private static let layoutChangedNotification =
        "com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"

    /// Karakter tabanlı bir kısayol grubu (tek karakter → birden çok tuş kodu).
    private struct CharacterHotKey {
        let character: Character
        let modifiers: UInt32
        let baseID: UInt32
        let action: () -> Void
        var refs: [EventHotKeyRef] = []
        var hotKeyIDs: [UInt32] = []
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var characterHotKeys: [UInt32: CharacterHotKey] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var installed = false
    private var layoutObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Tuş koduna göre kayıt (eski API, korunuyor)

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }

    // MARK: - Karaktere göre kayıt (düzen duyarlı)

    /// Verilen karakteri üreten TÜM tuş kodlarına aynı eylemi bağlar.
    ///
    /// - Parameters:
    ///   - character: Aranan karakter (ör. "-").
    ///   - modifiers: Carbon değiştirici maskesi (`cmdKey`, `shiftKey`…).
    ///   - id: Grubun taban kimliği. Gerçek `EventHotKeyID`'ler `id * 100 + n` olur.
    ///   - action: Kısayol tetiklendiğinde çalışacak blok (ana kuyrukta çağrılır).
    /// - Returns: En az bir tuş kodu sisteme kaydedilebildiyse `true`. `false`
    ///   dönerse kısayol HİÇ çalışmayacaktır (çakışma, çözülemeyen karakter…);
    ///   çağıran bunu kullanıcıya göstermelidir.
    @discardableResult
    func registerForCharacter(
        _ character: Character,
        modifiers: UInt32,
        id: UInt32,
        action: @escaping () -> Void
    ) -> Bool {
        installHandlerIfNeeded()
        observeLayoutChangesIfNeeded()
        unregisterCharacter(id: id)

        var entry = CharacterHotKey(
            character: character,
            modifiers: modifiers,
            baseID: id,
            action: action
        )
        bind(&entry)
        characterHotKeys[id] = entry
        return !entry.refs.isEmpty
    }

    /// Yürürlükteki düzende `keyCode` tuşunun DEĞİŞTİRİCİSİZ ürettiği karakter.
    ///
    /// Kısayol kaydedicisi bunu kullanır: `charactersIgnoringModifiers` ⇧'i
    /// yok saymaz (⇧1 → "!") ve ok tuşları için özel-kullanım karakterleri
    /// döndürür; ikisi de sonradan hiçbir tuş koduna çözülemeyip sessizce
    /// çalışmayan kısayollar üretirdi.
    func baseCharacter(forKeyCode keyCode: UInt16) -> Character? {
        guard let source = currentLayoutSource(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        defer { withExtendedLifetime(source) {} }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).lowercased().first
    }

    /// Bir karakter grubunun tüm kayıtlarını kaldırır.
    func unregisterCharacter(id: UInt32) {
        guard let entry = characterHotKeys.removeValue(forKey: id) else { return }
        release(entry)
    }

    private func release(_ entry: CharacterHotKey) {
        for ref in entry.refs {
            UnregisterEventHotKey(ref)
        }
        for hotKeyID in entry.hotKeyIDs {
            handlers.removeValue(forKey: hotKeyID)
        }
    }

    private func bind(_ entry: inout CharacterHotKey) {
        let keyCodes = resolveKeyCodes(for: entry.character)
        var refs: [EventHotKeyRef] = []
        var ids: [UInt32] = []

        for (index, keyCode) in keyCodes.enumerated() where UInt32(index) < Self.idsPerGroup {
            let hotKeyID = entry.baseID &* Self.idsPerGroup &+ UInt32(index)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                entry.modifiers,
                EventHotKeyID(signature: Self.signature, id: hotKeyID),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            guard status == noErr, let ref else { continue }
            handlers[hotKeyID] = entry.action
            refs.append(ref)
            ids.append(hotKeyID)
        }

        entry.refs = refs
        entry.hotKeyIDs = ids
    }

    // MARK: - Düzen değişimi

    private func observeLayoutChangesIfNeeded() {
        guard layoutObserver == nil else { return }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.layoutChangedNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Yeni düzenin verisi yerine otursun diye minik gecikme.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.reloadCharacterHotKeys()
            }
        }
    }

    /// Klavye düzeni değişince tuş kodlarını yeniden çözüp kayıtları tazeler.
    private func reloadCharacterHotKeys() {
        for (id, entry) in characterHotKeys {
            release(entry)
            var refreshed = entry
            refreshed.refs = []
            refreshed.hotKeyIDs = []
            bind(&refreshed)
            characterHotKeys[id] = refreshed
        }
    }

    // MARK: - Tuş kodu çözümleme

    /// Yürürlükteki klavye düzeninde, değiştiricisiz basıldığında `character`
    /// üreten tüm sanal tuş kodları.
    private func resolveKeyCodes(for character: Character) -> [UInt32] {
        var found: [UInt32] = []

        if let source = currentLayoutSource(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            found = scanKeyCodes(for: character, layoutData: layoutData)
            withExtendedLifetime(source) {}
        }

        // Düzen verisi okunamadıysa ANSI konumuna düş.
        if found.isEmpty, let ansi = Self.ansiKeyCode(for: character) {
            found.append(ansi)
        }

        // Sayısal tuş takımındaki eksi de aynı işi görsün.
        if character == "-" {
            let keypadMinus = UInt32(kVK_ANSI_KeypadMinus)
            if !found.contains(keypadMinus) {
                found.append(keypadMinus)
            }
        }

        return found
    }

    private func currentLayoutSource() -> TISInputSource? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil {
            return source
        }
        // Örn. Çince/Japonca girdi kaynaklarında düzen verisi yoktur.
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    private func scanKeyCodes(for character: Character, layoutData: CFData) -> [UInt32] {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return [] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let target = String(character).lowercased()
        let keyboardType = UInt32(LMGetKbdType())

        var result: [UInt32] = []
        for keyCode in 0..<UInt16(128) {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,                                        // değiştiricisiz
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { continue }
            if String(utf16CodeUnits: characters, count: length).lowercased() == target {
                result.append(UInt32(keyCode))
            }
        }
        return result
    }

    /// Son çare: standart ANSI düzenindeki konum.
    private static func ansiKeyCode(for character: Character) -> UInt32? {
        switch character {
        case "-": return UInt32(kVK_ANSI_Minus)
        case "=": return UInt32(kVK_ANSI_Equal)
        case "[": return UInt32(kVK_ANSI_LeftBracket)
        case "]": return UInt32(kVK_ANSI_RightBracket)
        case ",": return UInt32(kVK_ANSI_Comma)
        case ".": return UInt32(kVK_ANSI_Period)
        case "/": return UInt32(kVK_ANSI_Slash)
        case ";": return UInt32(kVK_ANSI_Semicolon)
        case "'": return UInt32(kVK_ANSI_Quote)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        case "`": return UInt32(kVK_ANSI_Grave)
        default: return nil
        }
    }

    // MARK: - Carbon olay işleyicisi

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { manager.handlers[id]?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
    }
}
