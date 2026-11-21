#!/bin/bash
# シミュレータ用にビルドする。使い方: scripts/build_sim.sh ["iPhone 11"]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-iPhone 11}"
python3 scripts/gen_xcodeproj.py
xcodebuild -project SatoruEditor.xcodeproj -scheme SatoruEditor -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning: |BUILD (SUCCEEDED|FAILED)" | grep -v XcodeJapanese || true
test -d build/DerivedData/Build/Products/Debug-iphonesimulator/SatoruEditor.app
echo "app: $(pwd)/build/DerivedData/Build/Products/Debug-iphonesimulator/SatoruEditor.app"
