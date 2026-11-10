#!/bin/zsh
# Builds "Ditoo Status.app" with the Swift toolchain from Xcode or the Command Line Tools.
set -e
cd "$(dirname "$0")"
APP="build/Ditoo Status.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -parse-as-library Sources/*.swift \
  -o "$APP/Contents/MacOS/DitooStatus-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos14 -parse-as-library Sources/*.swift \
  -o "$APP/Contents/MacOS/DitooStatus-x86_64"
lipo -create "$APP/Contents/MacOS/DitooStatus-"* -output "$APP/Contents/MacOS/DitooStatus"
rm "$APP/Contents/MacOS/DitooStatus-"*
# A stable signing identity keeps macOS's Bluetooth permission across rebuilds; ad-hoc ("-")
# makes every build a new app to macOS. Set SIGN_ID, or the first "Apple Development" identity is used.
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "built $PWD/$APP (signed: ${SIGN_ID:--})"
if [[ "$1" == "--install" ]]; then
  # Replace the copy in ~/Applications and restart it.
  DEST="$HOME/Applications/Ditoo Status.app"
  osascript -e 'quit app "Ditoo Status"' 2>/dev/null || true
  for i in {1..20}; do pgrep -x DitooStatus >/dev/null || break; sleep 0.5; done
  mkdir -p "$HOME/Applications" && rm -rf "$DEST" && cp -R "$APP" "$DEST"
  open "$DEST" && echo "installed $DEST"
fi
