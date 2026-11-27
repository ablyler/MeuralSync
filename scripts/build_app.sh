#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="MeuralSync"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/ablyler/MeuralSync/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

echo "Building $APP_NAME $APP_VERSION ($BUILD_NUMBER) [release]..."
cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp "$BUILD_DIR/MeuralSyncApp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy SwiftPM resource bundles (contains parks/*.png and attractions.json)
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    fi
done

# Embed Sparkle.framework if built by SwiftPM
SPARKLE_FW="$BUILD_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

SPARKLE_PLIST_ENTRIES=""
if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
    SPARKLE_PLIST_ENTRIES=$(cat <<PLIST
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
PLIST
)
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MeuralSync</string>
    <key>CFBundleIdentifier</key>
    <string>com.ablyler.MeuralSync</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MeuralSync</string>
    <key>CFBundleDisplayName</key>
    <string>MeuralSync</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>MeuralSync exports curated photos from your Photos library to upload to your Meural digital frames.</string>
${SPARKLE_PLIST_ENTRIES}
</dict>
</plist>
EOF

# Sign inside-out (avoids deprecated --deep).
# For persistent Keychain & Photos permissions across updates, set SIGN_IDENTITY to a stable certificate.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--options runtime)
fi

if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_V="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    for xpc in "$SPARKLE_V/XPCServices"/*.xpc; do
        [ -d "$xpc" ] && codesign "${SIGN_ARGS[@]}" "$xpc"
    done
    [ -f "$SPARKLE_V/Autoupdate" ] && codesign "${SIGN_ARGS[@]}" "$SPARKLE_V/Autoupdate"
    [ -d "$SPARKLE_V/Updater.app" ] && codesign "${SIGN_ARGS[@]}" "$SPARKLE_V/Updater.app"
    codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

for bundle in "$APP_BUNDLE/Contents/Resources"/*.bundle; do
    if [ -d "$bundle" ]; then
        codesign "${SIGN_ARGS[@]}" "$bundle"
    fi
done

codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "To install: cp -R \"$APP_BUNDLE\" /Applications/"
