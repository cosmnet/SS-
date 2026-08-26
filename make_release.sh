#!/bin/zsh
# SS+ — GitHub Releases'e yüklenecek dağıtım paketini üretir.
#   Kullanım:  ./make_release.sh <sürüm>      örn: ./make_release.sh 1.5.0   (sürüm zorunlu)
# Çıktı:       dist/SS+-<sürüm>.dmg  (sürükle-bırak kurulum ekranlı, universal)
set -e
cd "$(dirname "$0")"

APP_NAME="SS+"
APP="dist/${APP_NAME}.app"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Kullanım: ./make_release.sh <sürüm>   örn: ./make_release.sh 1.5.0" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "✗ Sürüm x.y.z biçiminde olmalı: '${VERSION}'" >&2
  exit 1
fi
# Uyarılar (hata değil): git etiketi ve site/version.json istenen sürümle uyuşmalı.
TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ "${TAG#v}" != "$VERSION" ]]; then
  echo "  ⚠︎ HEAD'deki son etiket '${TAG:-yok}' ≠ ${VERSION}; yayımlamadan önce: git tag v${VERSION}"
fi
SITE_VERSION="$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' site/version.json 2>/dev/null | head -1)"
if [[ "$SITE_VERSION" != "$VERSION" ]]; then
  echo "  ⚠︎ site/version.json '${SITE_VERSION:-yok}' diyor; sürüm denetimi için siteyi de ${VERSION} yap."
fi
VOL_NAME="SS+ ${VERSION}"
# Dosya adında "+" kullanma: GitHub Releases yüklemesi bu karakterde hata veriyor.
DMG="dist/SSPlus-${VERSION}.dmg"
STAGE="dist/.dmg-stage"

# 1) Universal release derlemesi + imza (sürüm Info.plist'e de yazılır)
VERSION="$VERSION" ./build_app.sh

# 2) DMG içeriği
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/OKU-BENI.txt" <<'TXT'
SS+ — Kurulum
=============

1) SS+ simgesini soldaki "Applications" klasörüne sürükle.

2) İLK AÇILIŞ  (bir kereye mahsus)
   SS+ Apple tarafından noterlenmiş bir geliştirici hesabıyla imzalanmadığı
   için macOS ilk açılışta "doğrulanamadı" uyarısı verir. Aşması çok kolay:

   - Applications klasöründen SS+ uygulamasını bir kez aç (uyarı çıkacak, kapat).
   - Sistem Ayarları → Gizlilik ve Güvenlik'i aç, aşağı in.
   - "SS+ engellendi" satırındaki "Yine de Aç" düğmesine bas, şifreni gir.
   - Çıkan onayda tekrar "Aç" de. Bundan sonra normal şekilde açılır.

   (Alternatif: Terminal'de tek satır
      xattr -dr com.apple.quarantine /Applications/SS+.app )

3) İZİNLER  (uygulamanın çalışması için şart)
   Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı → SS+ açık olmalı.
   İzni verdikten sonra SS+ uygulamasını KAPAT ve yeniden AÇ;
   macOS izni ancak yeniden başlatınca uygular.

4) KULLANIM
   SS+ menü çubuğunda çalışır, Dock'ta görünmez. Menü çubuğundaki simgeye tıkla.

5) PRO'YU AÇMA
   Ayarlar → Pro → "Etkinleştirme kodu" alanına sana verilen kodu yaz ve
   "Etkinleştir"e bas. Pro özellikleri (OCR ile metin kopyalama, 60 FPS video,
   sistem sesi, HEVC ve özel bit hızı) anında açılır.

6) KISAYOLLAR
   ⌃⌘–  yakalama aracı  ·  ⌃⇧⌘–  video kaydı başlat / durdur
   (Ayarlar → Kısayollar'dan değiştirilebilir.)
TXT

# 3) DMG oluştur
echo "▶︎ DMG oluşturuluyor…"
TMP_DMG="dist/.tmp.dmg"
rm -f "$TMP_DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" \
  -fs HFS+ -format UDRW -ov "$TMP_DMG" >/dev/null

MOUNT_DIR="/Volumes/${VOL_NAME}"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen >/dev/null

osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "  ⚠︎ Pencere düzeni ayarlanamadı (Finder izni yok); DMG yine de çalışır."
tell application "Finder"
  tell disk "${VOL_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 800, 570}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set position of item "${APP_NAME}.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    set position of item "OKU-BENI.txt" of container window to {300, 340}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE"

# 4) DMG imzası + notarizasyon
#
# Gatekeeper, indirilen (karantinalı) bir uygulamayı ancak Developer ID ile
# imzalı VE Apple tarafından noterlenmişse açar. Apple Development ya da
# kendinden imzalı sertifikalar yetmez — kullanıcı "uygulama açılamadı" alır.
#
# Notarizasyon için bir kerelik kimlik kaydı gerekir (şifre burada saklanmaz,
# Anahtar Zinciri'ne gider):
#   xcrun notarytool store-credentials ssplus-notary \
#     --apple-id <apple-id> --team-id <TEAM_ID> --password <uygulamaya-özel-şifre>
# Uygulamaya özel şifre: https://appleid.apple.com → Oturum Açma ve Güvenlik.
NOTARY_PROFILE="${NOTARY_PROFILE:-ssplus-notary}"

SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -z "$SIGN_ID" ]]; then
  echo ""
  echo "  ⚠︎ Developer ID Application sertifikası bulunamadı; DMG imzalanmadı ve"
  echo "     noterlenmedi. Bu paketi indiren herkes "uygulama açılamadı" uyarısı alır."
  echo "     Sertifika: Xcode → Settings → Accounts → hesabını seç → Manage"
  echo "     Certificates → + → Developer ID Application (Account Holder/Admin yetkisi şart)."
else
  echo "▶︎ DMG imzalanıyor: ${SIGN_ID}"
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo ""
    echo "  ⚠︎ Notarizasyon profili '${NOTARY_PROFILE}' kayıtlı değil; DMG imzalandı"
    echo "     ama noterlenmedi. Tek seferlik kayıt için:"
    echo "       xcrun notarytool store-credentials ${NOTARY_PROFILE} \\"
    echo "         --apple-id <apple-id> --team-id <TEAM_ID> --password <uygulamaya-özel-şifre>"
  else
    echo "▶︎ Apple'a noterlenmek üzere gönderiliyor (birkaç dakika sürebilir)…"
    if xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
      # Bileti DMG'ye işle: böylece kullanıcı çevrimdışıyken de doğrulanabilir.
      xcrun stapler staple "$DMG"
      echo "  ✓ Noterlendi ve bilet işlendi."
      spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/     /'
    else
      echo "  ✗ Notarizasyon başarısız. Ayrıntı için:"
      echo "     xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}"
      exit 1
    fi
  fi
fi

echo ""
echo "✓ Hazır: ${DMG}  ($(du -h "$DMG" | cut -f1))"
echo "  GitHub → Releases → Draft a new release ekranına bu dosyayı sürükle."
