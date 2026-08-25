import Foundation

/// Arayüz dili.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case tr
    case en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Sistem dili")
        case .tr: return "Türkçe"
        case .en: return "English"
        }
    }
}

/// Basit sözlük tabanlı yerelleştirme.
///
/// Kaynak kodda metinler Türkçe yazılır ve `L("…")` ile sarılır; Türkçe metin
/// sözlük anahtarıdır. İngilizce seçiliyse tablodan karşılığı döner, yoksa
/// anahtar olduğu gibi kullanılır. Böylece Localizable.strings dosyası ve
/// yapay anahtar isimleri gerekmez.
enum Localization {
    /// Ayarlardan gelen tercih; `SettingsStore` açılışta ve her değişimde yazar.
    nonisolated(unsafe) static var preference: AppLanguage = .system

    /// Etkin dil: "Sistem" seçiliyse macOS'un tercih dili Türkçe ise Türkçe,
    /// değilse İngilizce.
    static var effective: AppLanguage {
        switch preference {
        case .tr, .en: return preference
        case .system:
            let first = Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("tr") ? .tr : .en
        }
    }

    /// Tarih biçimlendiricileri için yerel.
    static var locale: Locale {
        Locale(identifier: effective == .tr ? "tr_TR" : "en_US")
    }

    static func string(_ key: String) -> String {
        guard effective == .en else { return key }
        return english[key] ?? key
    }

    // MARK: - İngilizce tablo (anahtar: Türkçe kaynak metin)

    static let english: [String: String] = [
        // Genel
        "Tamam": "OK",
        "Vazgeç": "Cancel",
        "Ayarlar": "Settings",
        "Ayarlar…": "Settings…",
        "SS+ Ayarları": "SS+ Settings",
        "Sistem dili": "System language",
        "Dil": "Language",
        "Kapat": "Close",
        "Sil": "Delete",
        "Kopyala": "Copy",
        "Göster": "Reveal",
        "Düzenle": "Edit",
        "Temizle": "Clear",
        "Çıkış": "Quit",
        "saat": "at",
        "SS+ Kayıt": "SS+ Recording",

        // Menü
        "Alan / Pencere Yakala": "Capture Area / Window",
        "Alan Seç": "Select Area",
        "Pencere Seç": "Select Window",
        "Tüm Ekranı Yakala": "Capture Entire Screen",
        "Video Kaydı Başlat": "Start Video Recording",
        "Kaydı Durdur": "Stop Recording",
        "Kayıt Klasörünü Aç": "Open Save Folder",
        "SS+'ı Kapat": "Quit SS+",

        // Hatalar
        "Ekran bulunamadı.": "No display found.",
        "Pencere bulunamadı.": "Window not found.",
        "Ekran kaydı izni gerekiyor. Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı bölümünden SS+ için izin verin.":
            "Screen Recording permission is required. Enable SS+ under System Settings → Privacy & Security → Screen Recording.",
        "Görüntü kodlanamadı.": "The image could not be encoded.",
        "Kayıt sırasında hiç kare alınamadı; dosya oluşturulmadı.": "No frames were captured; no file was created.",
        "Kayıt kesildi; buraya kadarki kısım kaydedildi": "Recording interrupted; the part captured so far was saved",
        "Yakalama ve kayıt kısayolları aynı (%@); yalnızca biri çalışır.": "Capture and record shortcuts are identical (%@); only one will work.",
        "Yakalama kısayolu (%@) sisteme kaydedilemedi.": "The capture shortcut (%@) could not be registered.",
        "Kayıt kısayolu (%@) sisteme kaydedilemedi.": "The record shortcut (%@) could not be registered.",

        // İzin
        "SS+ için ekran kaydı izni gerekiyor": "SS+ needs Screen Recording permission",
        "İzni Onar ve Yeniden Başlat": "Repair Permission and Relaunch",
        "Sistem Ayarları'nı Aç": "Open System Settings",
        """
        Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı listesinde SS+ \
        anahtarını AÇIK duruma getir, sonra uygulamayı TAMAMEN kapatıp yeniden aç. \
        macOS, verilen izni ancak uygulama yeniden başlatıldığında tanır.

        Anahtar açık görünmesine rağmen çalışmıyorsa kayıt bozuk demektir \
        (yeniden derleme sonrası imza değişimi buna yol açar). \
        "İzni Onar ve Yeniden Başlat" eski kaydı silip uygulamayı yeniden \
        başlatır; macOS bu kez temiz bir izin penceresi gösterir.
        """:
        """
        Turn ON the SS+ switch under System Settings → Privacy & Security → Screen Recording, \
        then quit SS+ completely and open it again. macOS only applies the permission after a relaunch.

        If the switch is on but capture still fails, the permission record is stale \
        (a changed code signature after rebuilding causes this). "Repair Permission and Relaunch" \
        removes the old record and relaunches; macOS will then show a fresh permission prompt.
        """,

        // Seçim
        "Sürükleyerek alan seç  ·  ⇧ kare": "Drag to select an area  ·  ⇧ square",
        "Yakalanacak pencereye tıkla": "Click the window to capture",
        "Kayıt alanı seç": "Select recording area",
        "↩ tüm ekran": "↩ entire screen",
        "Esc iptal": "Esc cancel",
        "Alan": "Area",
        "Pencere": "Window",
        "Ekran": "Screen",
        "Kayıt": "Record",

        // Ada
        "Kayıt sırasında çiz": "Draw while recording",
        "Durdur": "Stop",
        "Kaydı durdur": "Stop recording",
        "PANO": "CLIPBOARD",
        "Pano geçmişini temizle": "Clear clipboard history",
        "Kopyaladıkların burada birikir": "Things you copy collect here",
        "Pano geçmişi kapalı · Ayarlar → Genel'den aç": "Clipboard history is off · enable in Settings → General",
        "Metni panoya geri kopyala": "Copy text back to clipboard",
        "Görseli panoya geri kopyala": "Copy image back to clipboard",

        // Önizleme
        "Kopyalandı": "Copied",
        "Metin panoya kopyalandı": "Text copied to clipboard",
        "Metin bulunamadı": "No text found",
        "OCR yalnızca Pro'da — Ayarlar'dan aç": "OCR is Pro only — unlock in Settings",
        "Videoyu aç": "Open video",
        "Video kaydedildi": "Video saved",
        "Finder'da göster": "Reveal in Finder",

        // Düzenleyici
        "Kalem": "Pen",
        "Fosforlu": "Highlighter",
        "Ok": "Arrow",
        "Çizgi": "Line",
        "Dikdörtgen": "Rectangle",
        "Elips": "Ellipse",
        "Metin": "Text",
        "Beyaz": "White",
        "Siyah": "Black",
        "Kırmızı": "Red",
        "Turuncu": "Orange",
        "Sarı": "Yellow",
        "Yeşil": "Green",
        "Mavi": "Blue",
        "Mor": "Purple",
        "Geri Al (⌘Z)": "Undo (⌘Z)",
        "Yinele (⇧⌘Z)": "Redo (⇧⌘Z)",
        "Kalınlık": "Thickness",
        "Bitti": "Done",
        "Çizimleri uygula ve aktar (Enter)": "Apply drawings and save (Enter)",
        "Düz Aktar": "Save Plain",
        "Çizimsiz orijinali aktar (Esc)": "Save the original without drawings (Esc)",
        "Hiçbir şey kaydetme (⌘.)": "Save nothing (⌘.)",

        // Kayıt üstü çizim
        "İnce": "Thin",
        "Orta": "Medium",
        "Kalın": "Thick",
        "%@ kalınlık": "%@ stroke",
        "Yaz ve ↩": "Type, then ↩",
        "Tüm çizimleri sil": "Erase all drawings",
        "Çizim katmanını kapat (Esc)": "Close the drawing layer (Esc)",
        "Metin — tıkla, yaz, ↩ ile bırak": "Text — click, type, ↩ to place",

        // Menü paneli
        "Dosyalar": "Files",
        "Görseller": "Images",
        "Metinler": "Texts",
        "Henüz kayıt yok": "Nothing saved yet",
        "Pano görseli": "Clipboard image",
        "Panoya geri kopyala": "Copy back to clipboard",
        "Pano görsel geçmişi boş": "No clipboard images yet",
        "Pano metin geçmişi boş": "No clipboard texts yet",
        "Pano geçmişi kapalı · Ayarlar → Genel": "Clipboard history is off · Settings → General",
        "Listeyi yenile": "Refresh list",

        // Ayarlar — sekmeler
        "Genel": "General",
        "Kayıt & Çıktı": "Recording & Output",
        "Kısayollar": "Shortcuts",

        // Ayarlar — Genel
        "Yakalama": "Capture",
        "Yakalama sonrası düzenleyiciyi aç": "Open the editor after capturing",
        "Çekilen görüntü, bulunduğu yerin üstünde açılan çizim düzenleyicisine düşer.": "The captured image opens in a drawing editor right where it was taken.",
        "Önizleme kartını göster": "Show preview card",
        "Kaybolma süresi": "Dismiss after",
        "%d sn": "%d s",
        "Kopyalama sesi çal": "Play capture sound",
        "Pano geçmişi": "Clipboard history",
        "Pano geçmişini tut": "Keep clipboard history",
        "Açıkken kopyaladığın son 10 metin ve görsel adada ve menü panelinde listelenir. Bunlar diske yazılır: ~/Library/Application Support/SSPlus/Clipboard. Şifre yöneticilerinin gizli işaretlediği içerik hiçbir zaman kaydedilmez.":
            "When on, the last 10 texts and images you copy are listed in the island and the menu panel. They are written to disk at ~/Library/Application Support/SSPlus/Clipboard. Content that password managers mark as concealed is never stored.",
        "Çıkışta geçmişi sil": "Clear history on quit",
        "Geçmişi şimdi temizle": "Clear history now",
        "Ada (Island)": "Island",
        "Ada'yı (Island) boşta göster": "Show the island when idle",
        "Kapatılırsa ada yalnızca kayıt ve seçim sırasında görünür; çentik tamamen sessiz kalır.": "When off, the island appears only while recording or selecting; the notch stays completely quiet.",
        "Arayüz dili değişikliği anında uygulanır.": "Language changes apply immediately.",

        // Ayarlar — Kayıt & Çıktı
        "Konum": "Location",
        "Değiştir…": "Change…",
        "Görüntüleri panoya da kopyala": "Also copy images to the clipboard",
        "Görüntü": "Image",
        "Görüntü formatı": "Image format",
        "İmleci ekran görüntüsüne ve videoya dahil et": "Include the cursor in screenshots and video",
        "Akıllı pencere sezme": "Smart window detection",
        "Alan modunda fare pencere üstündeyken tıklamak o pencereyi yakalar.": "In area mode, clicking while hovering a window captures that window.",
        "Video": "Video",
        "Kare hızı": "Frame rate",
        "Kap": "Container",
        "Kodek": "Codec",
        "Bit hızı": "Bit rate",
        "Otomatik": "Automatic",
        "Sistem sesini kaydet": "Record system audio",
        "Pro olmadan kayıt 30 fps, H.264 ve otomatik bit hızıyla yapılır.": "Without Pro, recordings use 30 fps, H.264 and automatic bit rate.",
        "60 fps yalnızca Pro'da": "60 fps is Pro only",

        // Ayarlar — Kısayollar
        "Genel kısayollar": "Global shortcuts",
        "Yakalama aracı": "Capture tool",
        "Video kaydı başlat / durdur": "Start / stop video recording",
        "Varsayılanlara dön": "Restore defaults",
        "Sıfırla": "Reset",
        "Kısayola bas…": "Press shortcut…",
        "Esc: vazgeç": "Esc: cancel",
        "Değiştirmek için tıkla ve yeni kısayola bas": "Click, then press the new shortcut",
        "Bu tuş kısayol olamaz; harf, rakam ya da noktalama seç.": "That key can't be a shortcut; choose a letter, digit or punctuation.",
        "En az bir değiştirici (⌘ ⌥ ⌃ ⇧) gerekli.": "At least one modifier (⌘ ⌥ ⌃ ⇧) is required.",
        "Bu kısayol diğer eylemde kullanılıyor.": "This shortcut is already used by the other action.",
        "Seçim ekranı": "Selection screen",
        "Alan modu": "Area mode",
        "Pencere modu": "Window mode",
        "Kare oranına kilitle": "Lock to square",
        "Tüm ekranı yakala": "Capture entire screen",
        "Çizim düzenleyici": "Drawing editor",
        "Araç seç": "Select tool",
        "Geri al · yinele": "Undo · redo",
        "Son öğeyi geri al": "Undo last item",
        "Bitti · kaydet": "Done · save",
        "Çizimsiz aktar": "Save without drawings",

        // Google Drive
        "Bu derlemede Google istemci kimliği yok (Resources/GoogleOAuth.plist). Kurulum için README'ye bak.":
            "This build has no Google client ID (Resources/GoogleOAuth.plist). See the README for setup.",
        "Kendi Google hesabınla oturum açarsın; belirteçler yalnızca bu Mac'in Anahtar Zinciri'nde tutulur, SS+ geliştiricisinin Drive'ına erişimi olmaz.":
            "You sign in with your own Google account; tokens are kept only in this Mac's Keychain, and the SS+ developer has no access to your Drive.",
        "Google ile oturum aç": "Sign in with Google",
        "Tarayıcıda Google onayı bekleniyor…": "Waiting for Google consent in the browser…",
        "Çıkış yap": "Sign out",
        "Ekran görüntülerini Drive'a yükle": "Upload screenshots to Drive",
        "Klasör": "Folder",
        "Drive'da aç": "Open in Drive",
        "Klasör Drive'ının kökünde oluşturulur; sonra Drive'da istediğin yere taşıyabilir ya da adını değiştirebilirsin — yüklemeler onu izlemeye devam eder.":
            "The folder is created at the root of your Drive; you can then move or rename it anywhere in Drive — uploads keep following it.",
        "Bağlantıyla herkese açık paylaş": "Share with anyone who has the link",
        "Linki panoya kopyala": "Copy the link to the clipboard",
        "Drive'a yükleniyor…": "Uploading to Drive…",
        "Drive linki kopyalandı": "Drive link copied",
        "Drive'a yüklendi": "Uploaded to Drive",
        "Drive yüklemesi başarısız": "Drive upload failed",
        "Drive linkini kopyala": "Copy Drive link",
        "Google Drive'da aç": "Open in Google Drive",
        "Bağlantı alınamadı": "No link returned",
        "Google Drive için istemci kimliği ayarlanmamış.": "No Google client ID is configured for Drive.",
        "Oturum açma iptal edildi.": "Sign-in was cancelled.",
        "Güvenlik doğrulaması başarısız (state).": "Security check failed (state mismatch).",
        "Yerel geri dönüş sunucusu başlatılamadı.": "The local callback server could not be started.",
        "Google belirteci alınamadı: %@": "Could not obtain a Google token: %@",
        "Google oturumu yok; Ayarlar'dan oturum aç.": "Not signed in to Google; sign in from Settings.",
        "Google oturumu süresi doldu; Ayarlar'dan yeniden oturum aç.": "Your Google session expired; sign in again from Settings.",
        "Google Drive hatası (%d): %@": "Google Drive error (%d): %@",
        "Google Drive beklenmeyen bir yanıt verdi.": "Google Drive returned an unexpected response.",
        "Tamam, SS+'a dönebilirsin.": "All set — you can return to SS+.",

        // Ayarlar — Pro
        "Abonelik": "Subscription",
        "SS+ Pro aktif": "SS+ Pro is active",
        "Tüm özellikler açık": "All features unlocked",
        "Tüm özelliklerin kilidini aç": "Unlock all features",
        "Kaldır": "Remove",
        "Kod ile etkinleştirildi": "Activated with a code",
        "Etkinleştirme kodu": "Activation code",
        "Kodu gir": "Enter code",
        "Etkinleştir": "Activate",
        "Bu kod geçerli değil.": "This code is not valid.",
        "Metin Kopyala (OCR)": "Copy Text (OCR)",
        "Ekran görüntüsündeki yazıyı tek tıkla panoya al": "Grab the text in a screenshot with one click",
        "60 FPS Video": "60 FPS Video",
        "Akıcı, yüksek kare hızında ekran kaydı": "Smooth, high-frame-rate screen recording",
        "Sistem Sesi": "System Audio",
        "Video kaydına sistem sesini dahil et": "Include system audio in recordings",
        "HEVC ve özel bit hızı": "HEVC and custom bit rate",
        "Daha küçük dosya, daha yüksek kalite": "Smaller files, higher quality",
        "Kaydırmalı Yakalama": "Scrolling Capture",
        "Uzun sayfaları tek görüntüde birleştir (yakında)": "Stitch long pages into one image (coming soon)",
        "Anında Paylaşım Linki": "Instant Share Link",
        "Yakaladığını buluta yükle, linki paylaş (yakında)": "Upload a capture and share the link (coming soon)",
    ]
}

/// Kısa yardımcı: Türkçe kaynak metni etkin dile çevirir.
func L(_ key: String) -> String {
    Localization.string(key)
}

/// Biçimli sürüm: `L("%@ kalınlık", name)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.string(key), arguments: args)
}
