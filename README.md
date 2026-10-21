# SS+

macOS için hafif ve hızlı bir ekran yakalama uygulaması. Tamamen ücretsiz; sunucu yok, hesap yok, hiçbir veri dışarı gönderilmez.
Menü çubuğunda yaşar, istersen ekranın üst ortasındaki **island** (dinamik ada) arayüzüyle açılır ve
yakaladığın her şeyi sağ alt köşede küçük bir önizleme kartı olarak sunar.

Swift + SwiftUI + ScreenCaptureKit ile yazılmıştır. Harici bağımlılık yoktur.

---

## Özellikler

- **Island arayüzü** — Çentikte (çentiksiz Mac'lerde menü çubuğunun altında) duran, üzerine 1.2 sn
  bekleyince açılan kompakt araç çubuğu. Varsayılan olarak boşta **gizlidir**; **Ayarlar → Genel →
  Yakalama → "Ada'yı (Island) boşta göster"** ile açılır. Kayıt ve seçim sırasında her zaman görünür.
- **⌃⌘ –  ile anında yakalama** — Son kullandığın modu hatırlar (kısayol Ayarlar'dan değiştirilebilir).
  - **Alan** (dikdörtgen sürükleme, ⇧ ile kare)
  - **Pencere** — üzerine geldiğin pencereyi vurgular, tıklayınca yakalar
  - **Tüm ekran** — seçim sırasında `↩` ya da menüden
- **Video kaydı** — ScreenCaptureKit + AVAssetWriter ile alan bazlı `.mov` kaydı (H.264).
- **Ses kaydı** — Tek ayar: **"Sesi kaydet (sistem + mikrofon)"**, varsayılan açık.
  Sistem sesi (macOS 13+) ve mikrofon (tüm sürümler: macOS 15+ ScreenCaptureKit, öncesinde
  AVFoundation) aynı dosyaya **iki ayrı ses parçası** olarak
  yazılır; kayıt sırasında adada canlı ses düzeyi göstergesi görünür (mikrofon için ilk
  kullanımda izin sorulur).
- **Önizleme kartı** — Yakaladıktan sonra sağ altta belirir; kopyalayabilir, Finder'da
  gösterebilir, silebilir, hatta doğrudan **başka bir uygulamaya sürükleyip bırakabilirsin**.
  Ayarlardaki süre (varsayılan 5 sn) sonunda kendiliğinden kapanır; üzerine gelirsen beklemeye alır.
- **Ayarlar** — Kaydetme klasörü, PNG/JPEG formatı, panoya kopyalama, imleç, önizleme;
  video için kap (MOV/MP4), kodek, bit hızı ve sistem sesi.
- **Pano geçmişi (isteğe bağlı)** — Açıksa son 10 kopyalama adada ve menü panelinde listelenir.
  Varsayılan olarak **kapalıdır**; açıldığında kopyalananlar
  `~/Library/Application Support/SSPlus/Clipboard` altına yazılır. Şifre yöneticilerinin gizli
  işaretlediği içerik hiçbir zaman kaydedilmez; "Çıkışta geçmişi sil" seçeneği vardır.
- **Metin Kopyala (OCR)** — Görüntüdeki yazıyı Vision ile tanıyıp panoya alır
- **60 FPS** video kaydı, **HEVC** kodeği ve özel bit hızı

> Uygulamanın tamamı ücretsizdir: etkinleştirme kodu, abonelik ya da hesap yok.
> SS+, Cafer Karakaya ve Cem Özkaynak tarafından hazırlanmıştır.

---

## Web sitesi

<https://ssplusapp.vercel.app> — özellikler, [sürüm geçmişi](https://ssplusapp.vercel.app/changelog),
[gizlilik politikası](https://ssplusapp.vercel.app/privacy) ve [kullanım koşulları](https://ssplusapp.vercel.app/terms).
Uygulama günde bir kez `version.json` dosyasını okuyarak yeni sürüm olup olmadığını denetler
(Ayarlar → Genel → Hakkında'dan kapatılabilir ya da elle denetlenebilir). Site kaynağı `site/`
klasöründedir. Yayımlama: Vercel, depo içinden yapılan deploy'lara git yazar bilgisini ekler ve
yazar Vercel takımında doğrulanmış değilse deploy'u BLOCKED bırakır; bu yüzden klasörü depo dışına
kopyalayıp oradan yayımla:

```sh
rsync -a --exclude .vercel --exclude .env.local site/ /tmp/ssplus-site/ && cd /tmp/ssplus-site \
  && npx vercel link --yes --project ssplus && npx vercel deploy --prod --yes
```

DMG dosyaları siteye konmaz (Vercel disk imajı içeren deploy'ları engeller); indirme bağlantıları
GitHub Releases'e gider.

---

## İndir ve kur

En güncel sürümü <https://ssplusapp.vercel.app> adresinden `SSPlus-<sürüm>.dmg` olarak
indirebilirsin (universal: macOS 12 Monterey ve üzeri, Intel + Apple Silicon).

1. DMG'yi aç, **SS+** simgesini **Applications** klasörüne sürükle. Paket Developer ID ile
   imzalı ve Apple tarafından noterlenmiştir; "doğrulanamadı" uyarısı çıkmaz.
2. SS+ ilk yakalamada **Ekran Kaydı** iznini ister (aşağıdaki bölüm); izni verdikten sonra
   uygulamayı kapatıp yeniden aç.

## Kaynaktan derleme

Xcode Command Line Tools (veya Xcode) kurulu olmalıdır.

```sh
./build_app.sh
open "dist/SS+.app"
```

`build_app.sh` şunları yapar: release derlemesi alır, `dist/SS+.app` paketini oluşturur,
`Info.plist` dosyasını yazar ve paketi ad-hoc olarak imzalar. Sürüm numarasını sırayla `VERSION`
ortam değişkeninden, HEAD'den erişilen son `vX.Y.Z` git etiketinden ya da `site/version.json`
dosyasından alır (derleme numarası commit sayısıdır); böylece yerel derleme sitedeki sürümü
"yeni sürüm" diye bildirmez.

Sadece geliştirme derlemesi için:

```sh
swift build
```

Sistem sesi tanılaması — kayıt sessiz çıkıyorsa ScreenCaptureKit'in bu Mac'te gerçekten ses verip
vermediğini gösterir (uygulamanın kendi Ekran Kaydı izniyle çalışır; bir ses çalarken dene):

```sh
"dist/SS+.app/Contents/MacOS/SSPlus" --audio-probe 5   # 5 sn dinler, yarım saniyede bir tepe/RMS yazar
```

Dağıtıma hazır DMG üretmek için:

```sh
./make_release.sh 1.5.0   # sürüm zorunlu; yayımlamadan önce: git tag v1.5.0
```

---

## Google Drive kurulumu (geliştirici, isteğe bağlı)

> **Yayımlanan paketlerde Drive yoktur.** `Resources/GoogleOAuth.plist` olmadan
> derlenen paketlerde Ayarlar'daki Google Drive bölümü hiç görünmez; GitHub
> Releases'teki DMG'ler bu durumda. Aşağısı yalnızca kendi derlemende Drive'ı
> açmak istersen geçerlidir.

Drive yüklemesi Google'ın OAuth istemcisi ister. Bu yalnızca uygulamanın *kimliğidir*: her
kullanıcı kendi hesabıyla oturum açar, belirteçler kendi Mac'inin Anahtar Zinciri'nde kalır ve
geliştiricinin kimsenin Drive'ına erişimi olmaz. Kapsam en dar olanıdır (`drive.file`: yalnızca
SS+'ın oluşturduğu dosya ve klasörler); Google doğrulaması gerektirmez.

1. <https://console.cloud.google.com> → yeni proje (örn. "SS+").
2. **APIs & Services → Library** → **Google Drive API** → Enable.
3. **OAuth consent screen** → External → uygulama adı "SS+", destek e-postası;
   **Scopes** → `https://www.googleapis.com/auth/drive.file` ekle;
   **Audience** → Testing (kendi hesabını test kullanıcısı olarak ekle) ya da Publish.
4. **Credentials → Create credentials → OAuth client ID → Desktop app** → Client ID ve Client
   secret'ı kopyala.
5. `Resources/GoogleOAuth.example.plist` dosyasını `Resources/GoogleOAuth.plist` olarak kopyala
   ve iki değeri yaz. Dosya `.gitignore`'dadır; `build_app.sh` onu pakete ekler.
   (`swift run` için: `SSPLUS_GOOGLE_CLIENT_ID` / `SSPLUS_GOOGLE_CLIENT_SECRET` ortam değişkenleri.)

Kullanıcı tarafı: **Ayarlar → Genel → Google Drive → Google ile oturum aç**. Tarayıcıda
onay verilir, SS+ Drive kökünde "SS+" klasörünü oluşturur. Yeniden kurulum ya da yeniden oturum
açmada var olan klasör bulunup kullanılır (yeni kopya açılmaz); daha önce açılmış boş bir kopya
varsa Drive'dan silebilirsin. Sonraki her ekran görüntüsü oraya
yüklenir; "Bağlantıyla herkese açık paylaş" açıksa link panoya kopyalanır ve önizleme kartında
"Drive linkini kopyala / Google Drive'da aç" düğmeleri belirir.

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
    ├── Localization.swift      # Türkçe/İngilizce sözlük (L("…"))
    ├── GoogleAuth.swift        # Google OAuth (PKCE + loopback), Anahtar Zinciri
    ├── GoogleDrive.swift       # Drive v3 istemcisi + yükleme koordinatörü
    ├── StrokeSmoothing.swift   # Fırça sabitleyici + Catmull-Rom
    ├── Permissions.swift       # Ekran kaydı izni + onarım
    ├── OCR.swift               # Vision ile metin tanıma
    ├── UpdateChecker.swift     # Siteden version.json ile sürüm denetimi
    ├── VersionCompare.swift    # Sürüm dizgilerini bileşen bileşen sayısal karşılaştırma
    ├── AudioLevel.swift        # PCM tampon tepe/RMS ölçümü (kayıt göstergesi)
    ├── AudioProbe.swift        # --audio-probe: sistem sesi tanılaması
    └── HotKeyManager.swift     # Carbon global kısayollar
```

---

## Gereksinimler

- **macOS 12 Monterey veya üzeri** (Intel + Apple Silicon) — DMG universal'dır.
  Xcode 27 ve sonrası 12.0'ın altını derlemiyor; daha eski hedefler için eski bir araç
  zinciriyle `MIN_INTEL=10.15 MIN_ARM=11.0 ./build_app.sh`.
- Sürüme göre özellikler: çentik adası (macOS 12+), sistem sesi kaydı (13+), ekran görüntüsünde imleç
  ve ScreenCaptureKit motoru (14+). Daha eski sürümlerde CoreGraphics ve AVFoundation yolu kullanılır.
- Derleme için Swift 5.9+ araç zinciri (Command Line Tools yeterli; universal derleme `--triple` ile yapılır).
