# SS+

macOS için hafif, hızlı ve tamamen yerel çalışan bir ekran yakalama uygulaması.
Menü çubuğunda yaşar, ekranın üst ortasında **island** (dinamik ada) arayüzüyle açılır ve
yakaladığın her şeyi sağ alt köşede küçük bir önizleme kartı olarak sunar.

Swift + SwiftUI + ScreenCaptureKit ile yazılmıştır. Harici bağımlılık yoktur.

---

## Özellikler

- **Island arayüzü** — Çentikte duran, üzerine 1.2 sn bekleyince açılan kompakt araç çubuğu.
  Yalnızca kayıt ve seçimde zorunlu görünür; ayarlardan tamamen kapatılabilir.
- **⌃⌘ –  ile anında yakalama** — Son kullandığın modu hatırlar (kısayol Ayarlar'dan değiştirilebilir).
  - **Alan** (dikdörtgen sürükleme, ⇧ ile kare)
  - **Pencere** — üzerine geldiğin pencereyi vurgular, tıklayınca yakalar
  - **Tüm ekran** — seçim sırasında `↩` ya da menüden
- **Video kaydı** — ScreenCaptureKit + AVAssetWriter ile alan bazlı `.mov` kaydı (H.264).
- **Önizleme kartı** — Yakaladıktan sonra sağ altta belirir; kopyalayabilir, Finder'da
  gösterebilir, silebilir, hatta doğrudan **başka bir uygulamaya sürükleyip bırakabilirsin**.
  Ayarlardaki süre (varsayılan 5 sn) sonunda kendiliğinden kapanır; üzerine gelirsen beklemeye alır.
- **Ayarlar** — Kaydetme klasörü, PNG/JPEG formatı, panoya kopyalama, imleç, önizleme;
  video için kap (MOV/MP4), kodek, bit hızı ve sistem sesi.
- **Pano geçmişi (isteğe bağlı)** — Açıksa son 10 kopyalama adada ve menü panelinde listelenir.
  Varsayılan olarak **kapalıdır**; açıldığında kopyalananlar
  `~/Library/Application Support/SSPlus/Clipboard` altına yazılır. Şifre yöneticilerinin gizli
  işaretlediği içerik hiçbir zaman kaydedilmez; "Çıkışta geçmişi sil" seçeneği vardır.
- **Pro (demo)**
  - **Metin Kopyala (OCR)** — Görüntüdeki yazıyı Vision ile tanıyıp panoya alır
  - **60 FPS** video kaydı
  - **Sistem sesi** kaydı
  - **HEVC** kodeği ve özel bit hızı

> Pro özellikleri **Ayarlar → Pro → Etkinleştirme kodu** alanına geçerli bir kod
> girilerek açılır. Kod doğrulaması tamamen yereldir; hiçbir veri dışarı gönderilmez.

---

## İndir ve kur

En güncel sürümü [Releases](../../releases/latest) sayfasından `SS+-<sürüm>.dmg`
olarak indirebilirsin (Apple Silicon + Intel, universal).

1. DMG'yi aç, **SS+** simgesini **Applications** klasörüne sürükle.
2. **İlk açılış (bir kereye mahsus):** Uygulama Apple tarafından noterlenmediği için
   macOS ilk açılışta "doğrulanamadı" uyarısı verir.
   - Applications klasöründen SS+ uygulamasını bir kez aç (uyarıyı kapat).
   - **Sistem Ayarları → Gizlilik ve Güvenlik**'e gir, aşağı in.
   - "SS+ engellendi" satırındaki **Yine de Aç** düğmesine bas ve onayla.

   Dilersen tek satırla da olur:

   ```sh
   xattr -dr com.apple.quarantine /Applications/SS+.app
   ```
3. **Ekran Kaydı iznini** ver (aşağıdaki bölüm), sonra uygulamayı kapatıp yeniden aç.

---

## Kaynaktan derleme

Xcode Command Line Tools (veya Xcode) kurulu olmalıdır.

```sh
./build_app.sh
open "dist/SS+.app"
```

`build_app.sh` şunları yapar: release derlemesi alır, `dist/SS+.app` paketini oluşturur,
`Info.plist` dosyasını yazar ve paketi ad-hoc olarak imzalar.

Sadece geliştirme derlemesi için:

```sh
swift build
```

Dağıtıma hazır DMG üretmek için:

```sh
./make_release.sh 1.0.0
```

---

## İlk çalıştırma — Ekran Kaydı izni

SS+ ekranı okuyabilmek için macOS'un **Ekran Kaydı** iznine ihtiyaç duyar.
İlk açılışta sistem izin ister; vermezsen yakalama çalışmaz.

**Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı** bölümünden **SS+** için izni açın.

İzni verdikten sonra uygulamayı kapatıp tekrar açın:

```sh
killall SSPlus 2>/dev/null; open "dist/SS+.app"
```

Uygulama menü çubuğunda kamera vizörü (`camera.viewfinder`) simgesiyle görünür — Dock'ta ikon oluşmaz
(`LSUIElement`).

---

## Kısayollar

| Kısayol | İşlev |
| --- | --- |
| `⌃⌘ –` | Yakalama aracını aç (son kullanılan mod) |
| `⌃⇧⌘ –` | Video kaydını başlat / durdur |
| `R` / `A` | Seçim sırasında **alan** moduna geç |
| `W` / `P` | Seçim sırasında **pencere** moduna geç |
| `⇧` | Seçim sırasında kare oranına kilitle |
| `↩` | Seçim sırasında tüm ekranı yakala |
| `Esc` | Seçimi iptal et |
| `1`–`7` | Düzenleyicide araç seç |
| `⌘Z` / `⇧⌘Z` / `⌫` | Düzenleyicide geri al / yinele / son öğeyi geri al |
| `↩` / `Esc` / `⌘.` | Düzenleyicide kaydet / çizimsiz aktar / vazgeç |
| `⌘ ,` | Ayarları aç |
| `⌘ Q` | Çıkış |

---

## Proje yapısı

```
Sources/SSPlus/
├── main.swift                  # Giriş noktası (.accessory politikası)
├── App/AppDelegate.swift       # Menü çubuğu, global kısayollar, açılış, kayıt sürerken güvenli çıkış
├── Core/
│   ├── AppState.swift          # Uygulama durumu ve yakalama/kayıt akışı
│   └── OutputPipeline.swift    # Dosyaya yazma, pano, ses, önizleme
├── Capture/
│   ├── CaptureEngine.swift     # ScreenCaptureKit ekran görüntüsü
│   ├── ScreenRecorder.swift    # SCStream + AVAssetWriter video kaydı
│   └── SelectionOverlay.swift  # Tam ekran seçim katmanı
├── UI/
│   ├── Island.swift            # Dinamik ada + pano şeridi
│   ├── NotchMetrics.swift      # Çentik ölçümü (NSScreen'den dinamik)
│   ├── NotchAlignmentTest.swift# Çentik hizalama test katmanı
│   ├── Logo.swift              # Vektör marka
│   ├── PreviewPanel.swift      # Yakalama sonrası önizleme kartı
│   ├── StatusPanel.swift       # Menü çubuğu dosya/pano paneli
│   ├── AnnotationEditor.swift  # Yerinde çizim düzenleyici
│   ├── RecordingDrawOverlay.swift # Kayıt sırasında ekrana çizim
│   └── SettingsWindow.swift    # Ayarlar (kısayol kayıtçısı dahil)
└── Support/
    ├── Settings.swift          # UserDefaults destekli ayarlar
    ├── ClipboardHistory.swift  # Pano geçmişi (isteğe bağlı, son 10)
    ├── Notifications.swift     # Uygulama içi bildirim adları
    ├── UIShotExport.swift      # Pazarlama görselleri (--export-ui-shots)
    ├── StrokeSmoothing.swift   # Fırça sabitleyici + Catmull-Rom
    ├── Permissions.swift       # Ekran kaydı izni + onarım
    ├── Pro.swift               # Pro bayrağı + OCR servisi
    └── HotKeyManager.swift     # Carbon global kısayollar
```

---

## Gereksinimler

- macOS 14 (Sonoma) veya üzeri
- Swift 5.9+ araç zinciri
