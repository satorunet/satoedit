#!/bin/bash
# release ビルドして build/さとるエディタ.app を作る
#   ./scripts/bundle.sh          … この Mac 用 (速い)
#   ./scripts/bundle.sh --universal … Apple Silicon (arm64) と Intel (x86_64) 両対応
#   ./scripts/bundle.sh --dmg       … 両対応でビルドして配布用の DMG も作る
#   ./scripts/bundle.sh --dev       … 開発中の確かめ用: デバッグビルド・時刻印なしの署名で、すぐ起動できるアプリだけ作る (配布しない)
set -euo pipefail
cd "$(dirname "$0")/.."

# 版: 上げるときはここを変える (自動アップデートは CFBundleVersion で新旧を比べるので、版と同じにする)
VERSION="${VERSION:-1.0.2}"
BUILD_NUMBER="$VERSION"
BUNDLE_ID="${BUNDLE_ID:-net.satoru.satoruEditor}"

UNIVERSAL=0
DMG=0
DEV=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --dmg) UNIVERSAL=1; DMG=1 ;;
        --dev) DEV=1 ;;
        *) echo "知らないオプション: $arg" >&2; exit 1 ;;
    esac
done

if [ "$DEV" = 1 ]; then
    swift build
    BIN=".build/debug/Hinoki"
elif [ "$UNIVERSAL" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/Hinoki"
else
    swift build -c release
    BIN=".build/release/Hinoki"
fi
BINDIR="$(dirname "$BIN")"

APP="build/さとるエディタ.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/satoruEditor"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 設定で選べる色ちがいのアイコン
cp -R Resources/Icons "$APP/Contents/Resources/Icons"
# 自動アップデート (Sparkle) の部品を同梱する
mkdir -p "$APP/Contents/Frameworks"
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>satoruEditor</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>さとるエディタ</string>
    <key>CFBundleDisplayName</key><string>さとるエディタ</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/satorunet/satoedit/main/mac/appcast.xml</string>
    <key>SUPublicEDKey</key><string>1dnduvVlAY0o/ykPaaGkwkiXlEiNICxasqTmTupPzDo=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>NSHumanReadableCopyright</key><string>© 2026 satoru.net. MIT License.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleLocalizations</key><array><string>ja</string><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>声で文字を入力するために、マイクを使います。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>話した言葉を文字にするために、音声認識を使います。</string>
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

# 署名: キーチェーンに「Developer ID Application」の証明書があれば、それで署名する (なければ ad-hoc)
#   SIGN_ID="Developer ID Application: 名前 (チームID)" で指定もできる
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$SIGN_ID" ]; then
    # 公証には hardened runtime と時刻印が要る
    # マイク (音声入力) は hardened runtime では許可の印 (entitlements) が要る
    # (開発中は時刻印を付けない。ネットに問い合わせない分すぐ終わる。署名の名前は同じなのでキーチェーンの許可はそのまま使える)
    if [ "$DEV" = 1 ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
    # Sparkle の中身は内側から順に署名する (Sparkle の説明どおり)
    SP="$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime $TS -s "$SIGN_ID" "$SP/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime $TS -s "$SIGN_ID" --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime $TS -s "$SIGN_ID" "$SP/Versions/B/Autoupdate"
    codesign --force --options runtime $TS -s "$SIGN_ID" "$SP/Versions/B/Updater.app"
    codesign --force --options runtime $TS -s "$SIGN_ID" "$SP"
    codesign --force --options runtime $TS --entitlements scripts/entitlements.plist -s "$SIGN_ID" "$APP"
    codesign --verify --strict --verbose=1 "$APP"
    echo "signed: $SIGN_ID"
else
    codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
    echo "signed: ad-hoc (Developer ID の証明書がないため)"
fi
echo "built: $(pwd)/$APP"
lipo -archs "$APP/Contents/MacOS/satoruEditor" | sed 's/^/arch: /'

if [ "$DMG" = 1 ]; then
    # 開くと「アプリ → アプリケーション」の矢印の絵が出る、よくある形の DMG を作る
    STAGE="build/dmg"
    VOL="さとるエディタ ${VERSION}"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/.background"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    # 背景 (1 倍と 2 倍をまとめた tiff。Retina でもくっきり出る)
    BG="build/dmg-bg"
    mkdir -p "$BG"
    swift scripts/make_dmg_bg.swift "$BG/bg.png" 1 >/dev/null
    swift scripts/make_dmg_bg.swift "$BG/bg@2x.png" 2 >/dev/null
    tiffutil -cathidpicheck "$BG/bg.png" "$BG/bg@2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null 2>&1
    rm -rf "$BG"

    OUT="build/satoruEditor-${VERSION}-mac.dmg"
    RW="build/dmg-rw.dmg"
    rm -f "$OUT" "$RW"
    # 同じ名前の巻が開いていたら閉じる
    [ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
    hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
    rm -rf "$STAGE"
    DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')
    sleep 2
    # Finder に窓の大きさ・背景・アイコンの位置を覚えさせる (.DS_Store に残る)
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:bg.tiff"
        set position of item "さとるエディタ.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    sync
    rm -rf "/Volumes/$VOL/.fseventsd" 2>/dev/null || true
    hdiutil detach "$DEV" >/dev/null
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
    rm -f "$RW"
    if [ -n "$SIGN_ID" ]; then
        codesign --force --timestamp -s "$SIGN_ID" "$OUT"
        # 公証: 先に一度だけ
        #   xcrun notarytool store-credentials satoru-notary --apple-id <Apple ID> --team-id <チームID>
        # で、App 用パスワードをキーチェーンに保存しておく (NOTARY_PROFILE で名前を変えられる)
        PROFILE="${NOTARY_PROFILE:-satoru-notary}"
        if [ "${SKIP_NOTARY:-0}" = 1 ]; then
            echo "公証はとばしました (SKIP_NOTARY=1)"
        elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
            xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
            xcrun stapler staple "$OUT"
            spctl -a -t open --context context:primary-signature -v "$OUT" && echo "notarized: OK"
        else
            echo "公証はとばしました (notarytool の保存済み資格情報 '$PROFILE' がない)"
        fi
    fi
    echo "dmg: $(pwd)/$OUT"
fi
