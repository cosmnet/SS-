#!/bin/zsh
set -e

cd "$(dirname "$0")"

APP_NAME="SS+"
BUNDLE="dist/${APP_NAME}.app"
ICON_SRC="Resources/SSPlus.icns"

# Universal (Apple Silicon + Intel) derleme: uygulama internetten indirilip
# her Mac'te çalışacağı için iki mimariyi de içeren tek ikili üretiyoruz.
ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "▶︎ Release derleniyor (universal: arm64 + x86_64)…"
swift build -c release "${ARCH_FLAGS[@]}"

BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/SSPlus"
if [[ ! -f "$BIN" ]]; then
  echo "✗ Derlenen ikili bulunamadı: $BIN"
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "▶︎ Uygulama ikonu üretiliyor…"
  xcrun swift scripts/make_icon.swift Resources
fi

echo "▶︎ Uygulama paketi hazırlanıyor…"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "$BIN" "${BUNDLE}/Contents/MacOS/SSPlus"
chmod +x "${BUNDLE}/Contents/MacOS/SSPlus"
cp "$ICON_SRC" "${BUNDLE}/Contents/Resources/SSPlus.icns"

cat > "${BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ssplus.app</string>
    <key>CFBundleName</key>
    <string>SS+</string>
    <key>CFBundleDisplayName</key>
    <string>SS+</string>
    <key>CFBundleExecutable</key>
    <string>SSPlus</string>
    <key>CFBundleIconFile</key>
    <string>SSPlus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# macOS, gizlilik izinlerini uygulamanın KOD İMZASI kimliğine (designated
# requirement) bağlar. Geçici (ad-hoc) imzanın kararlı bir kimliği yoktur;
# bu yüzden her yeniden derlemede SS+ "başka bir uygulama" sayılır ve Ekran
# Kaydı izni geçersiz kalır. Anahtarlıkta kararlı bir kimlik varsa onu kullan.
echo "▶︎ İmzalanıyor…"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_ID="$(print -r -- "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(print -r -- "$IDENTITIES" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi

if [[ -n "$SIGN_ID" ]]; then
  echo "  Kararlı kimlik bulundu: ${SIGN_ID}"
  codesign --force --sign "$SIGN_ID" "$BUNDLE"
  echo "  ✓ Kimlik sabit olduğu için Ekran Kaydı izni yeniden derlemelerden sonra da korunur."
else
  codesign --force --sign - "$BUNDLE"
  echo "  ⚠︎ Kararlı imzalama kimliği bulunamadı; geçici (ad-hoc) imza kullanıldı."
  echo "     macOS izinleri imza kimliğine bağladığı için her yeniden derlemede"
  echo "     SS+ yeni bir uygulama sayılır ve Ekran Kaydı izni geçersiz kalır."
  echo "     Yeniden derledikten sonra: Sistem Ayarları → Gizlilik ve Güvenlik →"
  echo "     Ekran Kaydı'nda SS+ anahtarını KAPAT, tekrar AÇ ve uygulamayı yeniden başlat."
  echo "     Kalıcı çözüm: Xcode → Settings → Accounts ile ücretsiz bir"
  echo "     \"Apple Development\" sertifikası oluştur; bu betik onu kendiliğinden kullanır."
fi

echo ""
echo "✓ Hazır: ${BUNDLE}"
echo "  Çalıştırmak için:  open \"${BUNDLE}\""
echo "  İlk açılışta Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı bölümünden"
echo "  SS+ için izin ver ve uygulamayı yeniden başlat (izin ancak o zaman geçerli olur)."
