#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RuSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
# Universal-сборка кладёт продукт сюда (а не в .build/release)
BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
VERSION_JSON="$PROJECT_DIR/version.json"

# version.json — единый источник правды. Значения в Info.plist в репо
# игнорируются: скрипт штампует CFBundleShortVersionString и CFBundleVersion
# в копию Info.plist внутри собранного бандла.
SHORT_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON'))['version'])")
BUILD_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('build','1'))")
DEV_TAG=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('dev',''))")

if [ -z "$SHORT_VERSION" ]; then
    echo "ERROR: could not read version from $VERSION_JSON"
    exit 1
fi

echo "=== Building $APP_NAME v$SHORT_VERSION (build $BUILD_VERSION) ==="

# 1. Собираем release — universal (arm64 + x86_64), чтобы работало и на Intel-маках
echo "→ swift build -c release --arch arm64 --arch x86_64 (universal)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64

# 2. Создаём .app bundle
echo "→ Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Копируем бинарник
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 3a. Самопроверка: бинарь обязан быть universal (arm64 + x86_64), иначе Intel-маки не запустят
ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
    echo "ERROR: бинарь не universal (получено: $ARCHS)"; exit 1
fi
echo "→ Universal OK: $ARCHS"

# 4. Копируем Info.plist и штампуем версию из version.json
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist"
# Dev-метка (буква) для непубликуемых сборок — пусто для релиза. Показывается в About/меню.
/usr/libexec/PlistBuddy -c "Set :RSDevTag $DEV_TAG" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :RSDevTag string $DEV_TAG" "$APP_BUNDLE/Contents/Info.plist"
echo "→ Stamped Info.plist: CFBundleShortVersionString=$SHORT_VERSION$DEV_TAG CFBundleVersion=$BUILD_VERSION"

# 5. Копируем иконку
cp "$PROJECT_DIR/RuSwitcher.icns" "$APP_BUNDLE/Contents/Resources/RuSwitcher.icns"

# 5a. Модель полностью локальная. В готовом macOS bundle кладём её в
# Contents/Resources; Bundle.module остаётся SwiftPM fallback для тестов.
CORE_RESOURCE_BUNDLE="$BUILD_DIR/RuSwitcher_RuSwitcherCore.bundle"
if [ ! -d "$CORE_RESOURCE_BUNDLE" ]; then
    echo "ERROR: RuSwitcherCore resource bundle not found: $CORE_RESOURCE_BUNDLE"
    exit 1
fi
MODEL_RESOURCE="$CORE_RESOURCE_BUNDLE/Contents/Resources/language-model-v1.bin"
if [ ! -f "$MODEL_RESOURCE" ]; then
    echo "ERROR: language model not found: $MODEL_RESOURCE"
    exit 1
fi
cp "$MODEL_RESOURCE" "$APP_BUNDLE/Contents/Resources/language-model-v1.bin"
V4_MODEL_RESOURCE="$CORE_RESOURCE_BUNDLE/Contents/Resources/LayoutRerankerV4.mlmodelc"
V4_MANIFEST_RESOURCE="$CORE_RESOURCE_BUNDLE/Contents/Resources/layout-model-v4.json"
if [ ! -d "$V4_MODEL_RESOURCE" ] || [ ! -f "$V4_MANIFEST_RESOURCE" ]; then
    echo "ERROR: V4 model resources not found in SwiftPM bundle"
    exit 1
fi
cp -R "$V4_MODEL_RESOURCE" "$APP_BUNDLE/Contents/Resources/LayoutRerankerV4.mlmodelc"
cp "$V4_MANIFEST_RESOURCE" "$APP_BUNDLE/Contents/Resources/layout-model-v4.json"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/scripts/data/SCOWL_COPYRIGHT.txt" "$APP_BUNDLE/Contents/Resources/SCOWL_COPYRIGHT.txt"
echo "→ Bundled V3/V4 local models and third-party notices"

# 6. Создаём PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 7. Подписываем стабильной identity. Developer ID сохраняет разрешения между
#    публичными обновлениями; локальный сертификат сохраняет их между нашими
#    локальными сборками после одного повторного разрешения в macOS.
DEV_SIGN_ID="Developer ID Application: Rashid Nasibulin (9GEWCZ59HK)"
LOCAL_SIGN_ID="RuSwitcher Local Code Signing"
SIGN_ID="${SIGN_ID:-}"
SIGN_KIND="explicit identity"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)

if [ -z "$SIGN_ID" ]; then
    if echo "$IDENTITIES" | grep -Fq "\"$DEV_SIGN_ID\""; then
        SIGN_ID="$DEV_SIGN_ID"
        SIGN_KIND="Developer ID"
    elif echo "$IDENTITIES" | grep -Fq "\"$LOCAL_SIGN_ID\""; then
        SIGN_ID="$LOCAL_SIGN_ID"
        SIGN_KIND="local reusable certificate"
    else
        echo "ERROR: no signing identity found."
        echo "Install either:"
        echo "  - $DEV_SIGN_ID"
        echo "  - $LOCAL_SIGN_ID"
        exit 1
    fi
fi

echo "→ Code signing with $SIGN_KIND: $SIGN_ID"
codesign --force --deep --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$PROJECT_DIR/RuSwitcher.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_BUNDLE"
echo "Signed with: $SIGN_ID"
echo ""
echo "To install:"
echo "  cp -R $APP_BUNDLE /Applications/"
