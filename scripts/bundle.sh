#!/bin/bash
# release ビルドして build/さとるエディタ.app を作る
#   ./scripts/bundle.sh          … この Mac 用 (速い)
#   ./scripts/bundle.sh --universal … Apple Silicon (arm64) と Intel (x86_64) 両対応
#   ./scripts/bundle.sh --dmg       … 両対応でビルドして配布用の DMG も作る
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
BUILD_NUMBER="1"
BUNDLE_ID="${BUNDLE_ID:-local.satomaru.editor}"

UNIVERSAL=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --dmg) UNIVERSAL=1; DMG=1 ;;
        *) echo "知らないオプション: $arg" >&2; exit 1 ;;
    esac
done

if [ "$UNIVERSAL" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/Hinoki"
else
    swift build -c release
    BIN=".build/release/Hinoki"
fi

APP="build/さとるエディタ.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hinoki"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 設定で選べる色ちがいのアイコン
cp -R Resources/Icons "$APP/Contents/Resources/Icons"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Hinoki</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>さとるエディタ</string>
    <key>CFBundleDisplayName</key><string>さとるエディタ</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 さとるエディタ. MIT License.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>さとるエディタで開く</string></dict>
            <key>NSMessage</key><string>openFilesService</string>
            <key>NSPortName</key><string>さとるエディタ</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.data</string><string>public.text</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>さとるエディタで grep</string></dict>
            <key>NSMessage</key><string>grepFolderService</string>
            <key>NSPortName</key><string>さとるエディタ</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>テキスト</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.text</string>
                <string>public.plain-text</string>
                <string>public.source-code</string>
                <string>public.data</string>
            </array>
            <key>NSDocumentClass</key><string>Hinoki.Document</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
lipo -archs "$APP/Contents/MacOS/Hinoki" | sed 's/^/arch: /'

if [ "$DMG" = 1 ]; then
    STAGE="build/dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp README.md "$STAGE/はじめにお読みください.txt" 2>/dev/null || true
    OUT="build/SatoruEditor-${VERSION}.dmg"
    rm -f "$OUT"
    hdiutil create -volname "さとるエディタ ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
    rm -rf "$STAGE"
    echo "dmg: $(pwd)/$OUT"
fi
