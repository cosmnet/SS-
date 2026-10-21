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

# İmza + notarizasyon kimliği (DMG'den önce uygulamanın kendisi için de gerekli)
#
# Gatekeeper, indirilen (karantinalı) bir uygulamayı ancak Developer ID ile
# imzalı VE Apple tarafından noterlenmişse uyarısız açar. Apple Development ya
# da kendinden imzalı sertifikalar yetmez.
#
# Notarizasyon için bir kerelik kimlik kaydı gerekir (şifre burada saklanmaz,
# Anahtar Zinciri'ne gider):
#   xcrun notarytool store-credentials ssplus-notary \
#     --apple-id <apple-id> --team-id <TEAM_ID> --password <uygulamaya-özel-şifre>
# Uygulamaya özel şifre: https://appleid.apple.com → Oturum Açma ve Güvenlik.
NOTARY_PROFILE="${NOTARY_PROFILE:-ssplus-notary}"
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
HAVE_NOTARY=0
if [[ -z "$SIGN_ID" ]]; then
  echo "  ⚠︎ Developer ID Application sertifikası bulunamadı; paket imzalanmayacak"
  echo "     ve noterlenmeyecek. Bu paketi indiren herkes \"uygulama açılamadı\""
  echo "     uyarısı alır. Sertifika: Xcode → Settings → Accounts → hesabını seç →"
  echo "     Manage Certificates → + → Developer ID Application."
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  HAVE_NOTARY=1
else
  echo "  ⚠︎ Notarizasyon profili '${NOTARY_PROFILE}' kayıtlı değil; paket imzalanır"
  echo "     ama noterlenmez. Tek seferlik kayıt için:"
  echo "       xcrun notarytool store-credentials ${NOTARY_PROFILE} \\"
  echo "         --apple-id <apple-id> --team-id <TEAM_ID> --password <uygulamaya-özel-şifre>"
fi

# Verilen dosyayı Apple'a gönderir ve bileti üzerine işler.
notarize() {
  local item="$1" label="$2"
  echo "▶︎ ${label} notere gönderiliyor (birkaç dakika sürebilir)…"
  if xcrun notarytool submit "$item" --keychain-profile "$NOTARY_PROFILE" --wait; then
    xcrun stapler staple "$3"
    echo "  ✓ ${label} noterlendi ve bilet işlendi."
  else
    echo "  ✗ ${label} notarizasyonu başarısız. Ayrıntı için:" >&2
    echo "     xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}" >&2
    exit 1
  fi
}

# 1) Universal release derlemesi + imza (sürüm Info.plist'e de yazılır)
VERSION="$VERSION" ./build_app.sh

# 2) Uygulamanın kendisini noterle ve bileti .app'e işle.
#    DMG'yi noterlemek de yeter ama bilet yalnızca DMG'de kalır; kullanıcı
#    uygulamayı Applications'a kopyaladıktan sonra çevrimdışıysa Gatekeeper
#    bileti bulamaz. .app'e işlenen bilet bu durumu da kapatır.
if (( HAVE_NOTARY )); then
  APP_ZIP="dist/.app-notarize.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP" "Uygulama" "$APP"
  rm -f "$APP_ZIP"
fi

# 3) DMG içeriği
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/OKU-BENI.txt" <<'TXT'
SS+ — Kurulum
=============

1) SS+ simgesini soldaki "Applications" klasörüne sürükle. Hepsi bu:
   uygulama Apple tarafından noterlendiği için ek bir güvenlik adımı yok.

2) İZİN  (uygulamanın çalışması için şart)
   SS+ ilk yakalamada macOS'un Ekran Kaydı iznini ister; "Sistem Ayarları'nı
   Aç" deyip SS+ anahtarını aç. İzni verdikten sonra SS+ uygulamasını KAPAT ve
   yeniden AÇ; macOS izni ancak yeniden başlatınca uygular.
   (Ses kaydını kullanacaksan mikrofon izni de ilk kullanımda sorulur.)

3) KULLANIM
   SS+ menü çubuğunda çalışır, Dock'ta görünmez. Menü çubuğundaki simgeye tıkla.

4) HER ŞEY AÇIK
   Metin tanıma (OCR), 60 fps kayıt, HEVC, özel bit hızı ve ses kaydı dahil
   tüm özellikler ücretsiz; kod, abonelik ya da hesap yok.

5) KISAYOLLAR
   ⌃⌘–  yakalama aracı  ·  ⌃⇧⌘–  video kaydı başlat / durdur
   (Ayarlar → Kısayollar'dan değiştirilebilir.)
TXT

# 4) DMG oluştur
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

# 5) DMG imzası + notarizasyonu (indirilen dosyanın kendisi de doğrulanır)
if [[ -n "$SIGN_ID" ]]; then
  echo "▶︎ DMG imzalanıyor: ${SIGN_ID}"
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if (( HAVE_NOTARY )); then
    notarize "$DMG" "DMG" "$DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/     /'
  fi
fi

echo ""
echo "✓ Hazır: ${DMG}  ($(du -h "$DMG" | cut -f1))"
echo "  GitHub → Releases → Draft a new release ekranına bu dosyayı sürükle."
