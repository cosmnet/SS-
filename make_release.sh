#!/bin/zsh
# SS+ — GitHub Releases'e yüklenecek dağıtım paketini üretir.
#   Kullanım:  ./make_release.sh [sürüm]      örn: ./make_release.sh 1.0.0
# Çıktı:       dist/SS+-<sürüm>.dmg  (sürükle-bırak kurulum ekranlı, universal)
set -e
cd "$(dirname "$0")"

APP_NAME="SS+"
APP="dist/${APP_NAME}.app"
VERSION="${1:-1.0.0}"
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

SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --sign "$SIGN_ID" "$DMG"
fi

echo ""
echo "✓ Hazır: ${DMG}  ($(du -h "$DMG" | cut -f1))"
echo "  GitHub → Releases → Draft a new release ekranına bu dosyayı sürükle."
