#!/bin/bash
set -euo pipefail

APP_NAME="RuSwitcher"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Единый источник версии — version.json в корне репозитория.
VERSION=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$SCRIPT_DIR/version.json")
BUILD=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("build","1"))' "$SCRIPT_DIR/version.json")

# Keychain profile used for Apple notarization. Override with NOTARIZE_PROFILE=<name>.
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-notarytool-studio}"
DEVELOPER_SIGN_ID="${DEVELOPER_SIGN_ID:-Developer ID Application: Rashid Nasibulin (9GEWCZ59HK)}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.ruswitcher.app}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-9GEWCZ59HK}"

# create_dmg.sh is a public-release command by default. LOCAL_DMG=1 creates a
# clearly labelled local-only image and never mutates public release metadata.
LOCAL_DMG="${LOCAL_DMG:-0}"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "WARNING: SKIP_NOTARIZE=1 is treated as LOCAL_DMG=1."
    LOCAL_DMG=1
fi
if [ "$LOCAL_DMG" = "1" ]; then
    DMG_NAME="${APP_NAME}-${VERSION}-local.dmg"
else
    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
fi

VOL_NAME="${APP_NAME}"
BACKGROUND="$SCRIPT_DIR/dmg_background.png"
APP_PATH="$SCRIPT_DIR/${APP_NAME}.app"
DMG_PATH="$SCRIPT_DIR/$DMG_NAME"
mkdir -p "$SCRIPT_DIR/.build"
WORK_DIR="$(mktemp -d "$SCRIPT_DIR/.build/RuSwitcher-dmg.XXXXXX")"
DMG_TEMP="$WORK_DIR/${APP_NAME}-temp.dmg"
DMG_BUILD_PATH="$WORK_DIR/$DMG_NAME"
APP_ZIP="$WORK_DIR/${APP_NAME}-app.zip"
MOUNT_DIR=""
PUBLICATION_PID=""

cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}

handle_signal() {
    local exit_code="$1"
    trap - INT TERM
    if [ -n "$PUBLICATION_PID" ]; then
        kill -TERM "$PUBLICATION_PID" >/dev/null 2>&1 || true
        wait "$PUBLICATION_PID" >/dev/null 2>&1 || true
        PUBLICATION_PID=""
    fi
    exit "$exit_code"
}

verify_final_dmg_payload() {
    local verify_mount="$WORK_DIR/verified-payload"
    local payload_app="$verify_mount/${APP_NAME}.app"
    local payload_version payload_build payload_identifier payload_package_type
    local signature_details signature_identifier signature_team

    echo "→ Verifying compressed DMG structure..."
    hdiutil verify "$DMG_BUILD_PATH"
    mkdir -p "$verify_mount"
    echo "→ Re-mounting final DMG read-only for payload verification..."
    MOUNT_DIR="$verify_mount"
    hdiutil attach -readonly -nobrowse -noverify \
        -mountpoint "$verify_mount" "$DMG_BUILD_PATH" >/dev/null

    if [ ! -d "$payload_app" ] || [ -L "$payload_app" ]; then
        echo "ERROR: final DMG does not contain a regular ${APP_NAME}.app payload."
        return 1
    fi
    payload_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$payload_app/Contents/Info.plist")
    payload_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$payload_app/Contents/Info.plist")
    payload_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$payload_app/Contents/Info.plist")
    payload_package_type=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$payload_app/Contents/Info.plist")
    if [ "$payload_version" != "$VERSION" ] || [ "$payload_build" != "$BUILD" ]; then
        echo "ERROR: final DMG payload is $payload_version+$payload_build, expected $VERSION+$BUILD."
        return 1
    fi
    if [ "$payload_identifier" != "$EXPECTED_BUNDLE_ID" ] || [ "$payload_package_type" != "APPL" ]; then
        echo "ERROR: final DMG payload metadata is invalid ($payload_identifier, $payload_package_type)."
        return 1
    fi

    echo "→ Verifying final payload code signature..."
    codesign --verify --deep --strict --verbose=2 "$payload_app"
    signature_details=$(codesign -dv --verbose=4 "$payload_app" 2>&1)
    signature_identifier=$(awk -F= '/^Identifier=/{print substr($0, index($0, "=") + 1); exit}' <<<"$signature_details")
    if [ "$signature_identifier" != "$EXPECTED_BUNDLE_ID" ]; then
        echo "ERROR: signed payload identifier is '$signature_identifier', expected '$EXPECTED_BUNDLE_ID'."
        return 1
    fi

    if [ "$LOCAL_DMG" != "1" ]; then
        signature_team=$(awk -F= '/^TeamIdentifier=/{print substr($0, index($0, "=") + 1); exit}' <<<"$signature_details")
        if [ "$signature_team" != "$EXPECTED_TEAM_ID" ]; then
            echo "ERROR: final payload Team ID is '$signature_team', expected '$EXPECTED_TEAM_ID'."
            return 1
        fi
        echo "→ Validating final payload notarization and Gatekeeper assessment..."
        xcrun stapler validate "$payload_app"
        spctl --assess --type execute --verbose=4 "$payload_app"
    fi

    hdiutil detach "$MOUNT_DIR" -quiet
    MOUNT_DIR=""
    echo "→ Final DMG payload verified: $payload_identifier $payload_version+$payload_build"
}

run_publication_transaction() {
    /usr/bin/python3 "$SCRIPT_DIR/scripts/publish_release.py" "$@" &
    PUBLICATION_PID=$!
    local status=0
    wait "$PUBLICATION_PID" || status=$?
    PUBLICATION_PID=""
    return "$status"
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

echo "=== Creating styled DMG ==="

# A public artifact must be signed and notarizable. Check this before spending
# time rebuilding or mutating any release files.
if [ "$LOCAL_DMG" != "1" ]; then
    IDENTITIES=$(security find-identity -v -p codesigning)
    if ! grep -Fq "\"$DEVELOPER_SIGN_ID\"" <<<"$IDENTITIES"; then
        echo "ERROR: public release requires '$DEVELOPER_SIGN_ID'."
        echo "       Use LOCAL_DMG=1 for a local-only image."
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" >/dev/null 2>&1; then
        echo "ERROR: notarytool profile '$NOTARIZE_PROFILE' is missing or unusable."
        echo "       Public release aborted before build. Use LOCAL_DMG=1 locally."
        exit 1
    fi
fi

# 0. ВСЕГДА пересобираем приложение из исходников. Без этого шага DMG берёт имя
#    из version.json, а payload — из случайно лежащего рядом RuSwitcher.app.
#    Именно так в релиз 2.1.0 попал бандл 2.0.3: имя было 2.1.0, а внутри 2.0.3.
echo "→ Rebuilding app from source (build_app.sh)..."
if [ "$LOCAL_DMG" = "1" ]; then
    "$SCRIPT_DIR/build_app.sh"
else
    SIGN_ID="$DEVELOPER_SIGN_ID" "$SCRIPT_DIR/build_app.sh"
fi

# 0a. Жёсткая проверка: версия в собранном бандле обязана совпадать с version.json,
#     иначе отказываемся паковать DMG.
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUNDLE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [ "$BUNDLE_VERSION" != "$VERSION" ] || [ "$BUNDLE_BUILD" != "$BUILD" ]; then
    echo "ERROR: bundle is $BUNDLE_VERSION (build $BUNDLE_BUILD) but version.json is $VERSION (build $BUILD)."
    echo "       Refusing to ship a version-mismatched DMG."
    exit 1
fi
echo "→ Verified bundle $BUNDLE_VERSION (build $BUNDLE_BUILD) matches version.json"

# 0b. Нотаризуем и стейплим САМО приложение ДО упаковки — чтобы тикет был внутри .app.
#     Без этого вытащенный из DMG бандл не имеет своего тикета и при первом запуске
#     зависит от ОНЛАЙН-проверки Gatekeeper (после переноса/в офлайне → «не могу запустить»).
#     Со стейплом на бандле приложение запускается чисто офлайн, без xattr.
if [ "$LOCAL_DMG" != "1" ]; then
    echo "→ Notarizing the app bundle..."
    ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
    echo "→ Stapling the app bundle..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

# Size the writable image from the built payload. HFS+ metadata, Finder state,
# signatures and copy-on-disk variance get 33% plus an 8 MiB floor of overhead.
APP_SIZE_KB=$(du -sk "$APP_PATH" | awk '{print $1}')
BACKGROUND_SIZE_KB=$(du -sk "$BACKGROUND" | awk '{print $1}')
PAYLOAD_SIZE_KB=$((APP_SIZE_KB + BACKGROUND_SIZE_KB + 64))
OVERHEAD_SIZE_KB=$((PAYLOAD_SIZE_KB / 3 + 8192))
DMG_SIZE_KB=$((PAYLOAD_SIZE_KB + OVERHEAD_SIZE_KB))
DMG_SIZE_KB=$((((DMG_SIZE_KB + 4095) / 4096) * 4096))
echo "→ Writable image size: $((DMG_SIZE_KB / 1024)) MiB (app: $((APP_SIZE_KB / 1024)) MiB)"

# 0c. Не отключаем чужие тома автоматически. Коллизия имени должна остановить
#     release, а не потенциально размонтировать открытый пользователем образ.
if [ -e "/Volumes/${VOL_NAME}" ]; then
    echo "ERROR: /Volumes/${VOL_NAME} is already mounted. Detach it and retry."
    exit 1
fi

# 1. Create temporary writable DMG
echo "→ Creating temp DMG..."
hdiutil create -volname "$VOL_NAME" -fs HFS+ \
    -size "${DMG_SIZE_KB}k" -layout NONE "$DMG_TEMP"

# 2. Mount it
echo "→ Mounting..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
echo "   Mounted at: $MOUNT_DIR"
# Защита: если имя всё же разъехалось (том «RuSwitcher 1») — оформление уйдёт мимо. Прерываемся.
if [ "$MOUNT_DIR" != "/Volumes/${VOL_NAME}" ]; then
    echo "ERROR: temp DMG mounted at '$MOUNT_DIR', expected '/Volumes/${VOL_NAME}'."
    echo "       Stale volume collision — refusing to build an unstyled DMG."
    exit 1
fi

# 3. Copy app and create Applications symlink
echo "→ Copying app..."
cp -R "$APP_PATH" "$MOUNT_DIR/"
ln -sf /Applications "$MOUNT_DIR/Applications"

# 4. Create .background directory and copy background image
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND" "$MOUNT_DIR/.background/background.png"

# 5. Apply Finder settings via AppleScript
echo "→ Configuring Finder view..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.png"

        -- Position: app icon on left, Applications on right
        set position of item "$APP_NAME.app" of container window to {170, 210}
        set position of item "Applications" of container window to {490, 210}

        close
        open

        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# 6. Set volume icon
if [ -f "$SCRIPT_DIR/${APP_NAME}.icns" ]; then
    cp "$SCRIPT_DIR/${APP_NAME}.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

# 7. Finalize permissions
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

# 7a. Проверяем, что Finder реально записал оформление. .DS_Store хранит фон и позиции
#     иконок; если его нет — DMG откроется голым. Лучше упасть, чем отдать кривой образ.
if [ ! -f "$MOUNT_DIR/.DS_Store" ]; then
    echo "ERROR: .DS_Store not written to $MOUNT_DIR — DMG styling did NOT apply."
    echo "       Refusing to ship an unstyled DMG."
    exit 1
fi
echo "→ Styling OK (.DS_Store present)"

# 8. Unmount
echo "→ Unmounting..."
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

# 9. Convert to compressed read-only DMG
echo "→ Compressing..."
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_BUILD_PATH"

# 9a. Подписываем САМ .dmg Developer ID. Без этого образ нотаризуется и стейплится, но
#     `spctl -t install` даёт "no usable signature" — у скачанного образа нет подписи
#     контейнера, и на части Mac это приводит к недоверию к вынутому из него .app.
if [ "$LOCAL_DMG" != "1" ]; then
    echo "→ Code signing the DMG (Developer ID + secure timestamp)..."
    codesign --force --timestamp --sign "$DEVELOPER_SIGN_ID" "$DMG_BUILD_PATH"
    codesign --verify --verbose=2 "$DMG_BUILD_PATH"
fi

# 10. Notarize with Apple (required for Gatekeeper to accept the DMG on end-user Macs).
# Signed-but-unnotarized DMGs trigger "Apple could not verify [app] is free of malware".
if [ "$LOCAL_DMG" = "1" ]; then
    echo "→ LOCAL_DMG=1 — local-only image; no notarization or public metadata update"
else
    echo "→ Submitting to Apple notary service (profile: $NOTARIZE_PROFILE)..."
    xcrun notarytool submit "$DMG_BUILD_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_BUILD_PATH"
    xcrun stapler validate "$DMG_BUILD_PATH"
    # Контрольная проверка: образ должен приниматься как установочный носитель.
    echo "→ Verifying DMG passes Gatekeeper (install assessment)..."
    spctl -a -vvv -t install "$DMG_BUILD_PATH"
fi

# Copying, permission finalization and compression can invalidate or alter the
# app after its initial notarization. Verify the exact payload users will mount
# before publishing either the DMG or its hash.
verify_final_dmg_payload

# 11. Записываем sha256 обратно в version.json и cask — хэш механически привязан
#     к реально собранному DMG, а не копируется руками (раньше это расходилось).
DMG_SHA=$(shasum -a 256 "$DMG_BUILD_PATH" | awk '{print $1}')

if [ "$LOCAL_DMG" != "1" ]; then
    echo "→ Publishing DMG and release metadata transactionally..."
    if ! run_publication_transaction \
        --candidate-dmg "$DMG_BUILD_PATH" \
        --destination-dmg "$DMG_PATH" \
        --version-json "$SCRIPT_DIR/version.json" \
        --cask "$SCRIPT_DIR/ruswitcher.rb" \
        --version "$VERSION" \
        --build "$BUILD" \
        --sha256 "$DMG_SHA"; then
        echo "ERROR: release publication failed; previous DMG and metadata were restored."
        exit 1
    fi
else
    # A local image has no paired public metadata. os.rename/mv is atomic on
    # this volume and the candidate has already passed final payload checks.
    mv -f "$DMG_BUILD_PATH" "$DMG_PATH"
fi

echo ""
echo "=== Done! ==="
echo "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "SHA256: $DMG_SHA"
if [ "$LOCAL_DMG" = "1" ]; then
    echo "→ LOCAL-ONLY: version.json and ruswitcher.rb were not changed."
else
    echo "→ Public release metadata updated with this hash."
fi
