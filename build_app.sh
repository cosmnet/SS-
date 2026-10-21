#!/bin/zsh
set -e

cd "$(dirname "$0")"

APP_NAME="SS+"
BUNDLE="dist/${APP_NAME}.app"
ICON_SRC="Resources/SSPlus.icns"

# Sürüm kaynağı, öncelik sırasıyla:
#   1) VERSION ortam değişkeni (make_release.sh böyle geçirir)
#   2) HEAD'den erişilen son "vX.Y.Z" git etiketi ("v" öneki atılır)
#   3) site/version.json "version" alanı (etiketsiz kopya / tarball)
#   4) 1.0.0
# Eskiden elle çalıştırmada hep 1.0.0 yazılıyordu; yerel derleme bu yüzden
# sitedeki sürümü "yeni sürüm" diye bildiriyordu. Derleme numarası git commit
# sayısından türer; aynı sürümün yeniden derlemelerini ayırt eder.
if [[ -n "${VERSION:-}" ]]; then
  VERSION_SOURCE="VERSION ortam değişkeni"
else
  TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -n "$TAG" ]]; then
    VERSION="${TAG#v}"
    VERSION_SOURCE="git etiketi ${TAG}"
    AHEAD="$(git rev-list --count "${TAG}..HEAD" 2>/dev/null || echo 0)"
    if [[ "$AHEAD" != "0" ]]; then VERSION_SOURCE+=" (+${AHEAD} commit)"; fi
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then VERSION_SOURCE+=" · kaydedilmemiş değişiklikler var"; fi
  else
    VERSION="$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' site/version.json 2>/dev/null | head -1)"
    if [[ -n "$VERSION" ]]; then
      VERSION_SOURCE="site/version.json"
    else
      VERSION="1.0.0"
      VERSION_SOURCE="varsayılan"
    fi
  fi
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "⚠︎ Sürüm '${VERSION}' x.y.z biçiminde değil; CFBundleShortVersionString yine de bu olacak."
fi
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Universal (Apple Silicon + Intel) derleme, Xcode gerekmeden: her dilim kendi
# hedef üçlüsüyle derlenir ve lipo ile birleştirilir.
#   x86_64 → macOS 10.15 Catalina ve üzeri (Intel Mac'ler)
#   arm64  → macOS 11 ve üzeri (Apple Silicon'un ilk sürümü)
# Swift eşzamanlılık çalışma zamanı 10.15–11'de sistemde bulunmadığından
# libswift_Concurrency.dylib pakete (Contents/Frameworks) eklenir; ikili
# @executable_path/../Frameworks rpath'ini taşır (Package.swift).
# Asgari macOS sürümü Package.swift'teki platforms değerinden gelir ve
# derlemeden sonra ikiliden okunur (aşağıda MIN_OS). Xcode 27 ve sonrası
# 12.0'ın altını zaten derlemiyor.
MIN_INTEL="12.0"

# Yerelleştirme tablosunda aynı anahtar iki kez yazılırsa swiftc yalnızca UYARIR,
# ama Swift çalışma zamanı sözlük ilk okunduğunda çöker ("Dictionary literal
# contains duplicate keys"). 1.6.6 bu yüzden İngilizce arayüzde ilk L() çağrısında
# çöktü. Derlemeden önce yakala: anahtarlar satır başında `"…":` biçimindedir.
LOC_FILE="Sources/SSPlus/Support/Localization.swift"
LOC_DUPS="$(awk '
  /^[[:space:]]*"([^"\\]|\\.)*"[[:space:]]*:/ {
    match($0, /"([^"\\]|\\.)*"/)
    key = substr($0, RSTART, RLENGTH)
    if (++seen[key] == 2) print key
  }' "$LOC_FILE")"
if [[ -n "$LOC_DUPS" ]]; then
  echo "✗ ${LOC_FILE}: yinelenen anahtar(lar) — çalışma zamanında çökme sebebi:" >&2
  print -r -- "$LOC_DUPS" | sed 's/^/    /' >&2
  exit 1
fi

# Universal derleme TEK komutla yapılır. Eskiden iki ayrı `--triple` derlemesi
# `.build/<üçlü>/release/` altına yazıyordu; yeni SwiftPM ürünü
# `.build/out/Products/Release/` altına koyuyor. O yüzden çıktının yeri
# `--show-bin-path` ile sorulur: sabit yola güvenilirse eski bir ikili sessizce
# paketlenir (1.7.0 hazırlığında tam bunu yaşadık: Ağustos'tan kalma ikili
# imzalanıp noterlendi).
echo "▶︎ Release derleniyor (universal: arm64 + x86_64)…"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
BIN="${BIN_DIR}/SSPlus"
[[ -f "$BIN" ]] || { echo "✗ Derlenen ikili bulunamadı: $BIN" >&2; exit 1; }

# Güvenlik ağı: ikili en yeni kaynaktan eskiyse paketleme.
NEWEST_SRC="$(find Sources -name "*.swift" -newer "$BIN" -print -quit 2>/dev/null || true)"
if [[ -n "$NEWEST_SRC" ]]; then
  echo "✗ İkili kaynaktan eski görünüyor (ör. ${NEWEST_SRC}); derleme gerçekten çalıştı mı?" >&2
  exit 1
fi

BUILT_ARCHS="$(lipo -archs "$BIN")"
for want in arm64 x86_64; do
  [[ "$BUILT_ARCHS" == *"$want"* ]] || { echo "✗ ${want} dilimi yok (bulunan: ${BUILT_ARCHS})" >&2; exit 1; }
done
# Asgari sürüm ikiliden okunur; Info.plist ile ikili asla çelişmesin.
MIN_OS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
MIN_OS="${MIN_OS:-$MIN_INTEL}"
echo "  Mimariler: ${BUILT_ARCHS} · asgari macOS: ${MIN_OS}"

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

# Google Drive: geliştiricinin OAuth istemci kimliği (git'e girmez).
if [[ -f "Resources/GoogleOAuth.plist" ]]; then
  cp "Resources/GoogleOAuth.plist" "${BUNDLE}/Contents/Resources/GoogleOAuth.plist"
  echo "  Google OAuth istemcisi pakete eklendi."
else
  echo "  ⚠︎ Resources/GoogleOAuth.plist yok; Google Drive yüklemesi bu derlemede kapalı olacak."
  echo "     (Resources/GoogleOAuth.example.plist dosyasını kopyalayıp doldur.)"
fi

echo "  Sürüm ${VERSION} (${BUILD}) — kaynak: ${VERSION_SOURCE}"
cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>tr</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SS+ uses the microphone only when you enable "Record microphone" for video recordings.</string>
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
# Xcode/Apple hesabı olmayan makineler için yerel, kendinden imzalı kimlik
# (Anahtar Zinciri'nde "SS+ Local Signing"). Kararlıdır: yeniden derlemeler
# arasında Ekran Kaydı izni korunur. Gatekeeper açısından ad-hoc ile aynıdır.
if [[ -z "$SIGN_ID" ]] && print -r -- "$IDENTITIES" | grep -q '"SS+ Local Signing"'; then
  SIGN_ID="SS+ Local Signing"
fi

ENTITLEMENTS="Resources/SSPlus.entitlements"

# İç içe kod (Frameworks/*.dylib) dıştan içe doğru ayrı ayrı imzalanır.
# `--deep` Apple tarafından önerilmiyor ve notarizasyonda sorun çıkarabiliyor.
sign_bundle() {
  local id="$1"; shift
  local extra=("$@")
  for lib in "${BUNDLE}"/Contents/Frameworks/*.dylib(N); do
    codesign --force --sign "$id" "${extra[@]}" "$lib"
  done
  codesign --force --sign "$id" "${extra[@]}" "$BUNDLE"
}

if [[ -n "$SIGN_ID" ]]; then
  echo "  Kararlı kimlik bulundu: ${SIGN_ID}"
  if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then
    # Dağıtım imzası: notarizasyon Hardened Runtime + güvenli zaman damgası ister.
    echo "  Hardened Runtime + zaman damgası uygulanıyor (notarizasyona hazır)."
    sign_bundle "$SIGN_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS"
  else
    # Yerel geliştirme imzası: zaman damgası için ağa çıkma, runtime'ı zorlama.
    sign_bundle "$SIGN_ID" --timestamp=none
  fi
  echo "  ✓ Kimlik sabit olduğu için Ekran Kaydı izni yeniden derlemelerden sonra da korunur."
else
  sign_bundle - --timestamp=none
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
