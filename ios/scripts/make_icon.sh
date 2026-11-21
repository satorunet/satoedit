#!/bin/bash
# iPhone / iPad のアイコンを作る: Mac 版と同じ絵 (mac/scripts/make_icon.swift、藍の罫線の原稿用紙) を、
# 角まで塗った背景 (iOS のアイコンは透明にできない) に載せて、必要な大きさを全部書き出す。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET=SatoruEditor/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET"
swift ../mac/scripts/make_icon.swift "$TMP/icon.png" 0 2B4C9B >/dev/null
cat > "$TMP/flatten.swift" <<'SW'
import AppKit
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 0, y: 0, width: S, height: S)
NSGradient(starting: NSColor(srgbRed: 0.86, green: 0.89, blue: 0.95, alpha: 1), ending: NSColor(srgbRed: 0.70, green: 0.76, blue: 0.88, alpha: 1))!.draw(in: r, angle: -90)
// 少し大きく (iOS は角を丸く切るので、紙を真ん中に寄せる)
src.draw(in: r.insetBy(dx: -40, dy: -40), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SW
swift "$TMP/flatten.swift" "$TMP/icon.png" "$TMP/flat.png"
# 透明の層を落とす (App Store はアイコンに透明があると受け付けない): いったん JPEG にして PNG に戻す
sips -s format jpeg -s formatOptions 100 "$TMP/flat.png" --out "$TMP/flat.jpg" >/dev/null
sips -s format png "$TMP/flat.jpg" --out "$SET/icon-1024.png" >/dev/null
rm -f "$SET"/icon-[0-9]*.png.tmp
python3 - "$SET" <<'PY'
import json, subprocess, sys, os
d = sys.argv[1]
spec = [("iphone", 20, [2, 3]), ("iphone", 29, [2, 3]), ("iphone", 40, [2, 3]), ("iphone", 60, [2, 3]),
        ("ipad", 20, [1, 2]), ("ipad", 29, [1, 2]), ("ipad", 40, [1, 2]), ("ipad", 76, [1, 2]), ("ipad", 83.5, [2])]
images = []
for idiom, pt, scales in spec:
    for s in scales:
        px = int(pt * s)
        name = f"icon-{px}.png"
        if name != "icon-1024.png":
            subprocess.check_call(["sips", "-z", str(px), str(px), os.path.join(d, "icon-1024.png"), "--out", os.path.join(d, name)], stdout=subprocess.DEVNULL)
        sz = f"{pt:g}x{pt:g}"
        images.append({"idiom": idiom, "size": sz, "scale": f"{s}x", "filename": name})
images.append({"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": "icon-1024.png"})
json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)
PY
mkdir -p SatoruEditor/Assets.xcassets/LaunchBackground.colorset
cat > SatoruEditor/Assets.xcassets/Contents.json <<'J'
{ "info" : { "version" : 1, "author" : "xcode" } }
J
cat > SatoruEditor/Assets.xcassets/LaunchBackground.colorset/Contents.json <<'J'
{ "colors" : [ { "idiom" : "universal", "color" : { "color-space" : "srgb", "components" : { "red" : "1.000", "green" : "0.992", "blue" : "0.970", "alpha" : "1.000" } } } ],
  "info" : { "version" : 1, "author" : "xcode" } }
J
ls "$SET"
