#!/bin/zsh
# Builds Isle.app into ./build.
#   scripts/build.sh [--install] [--run]
# --install copies it to /Applications (needed for Launch at Login), --run launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Isle
ARCH=$(uname -m)
swift build -c release --arch "$ARCH" --product "$NAME" 2>&1 | grep -vE "^\[|Compiling|Write swift-version" || true
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/$NAME"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Sign with your own development identity if you have one, so macOS remembers permissions
# across rebuilds; otherwise sign ad-hoc. Override with: CODESIGN_IDENTITY="..." scripts/build.sh
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP" >/dev/null
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

for arg in "$@"; do
  case $arg in
    --install)
      pkill -x "$NAME" 2>/dev/null || true
      rm -rf "/Applications/$NAME.app" && cp -R "$APP" /Applications/
      APP="/Applications/$NAME.app"; echo "Installed to $APP" ;;
    --run)
      pkill -x "$NAME" 2>/dev/null || true; sleep 0.3
      open "$APP" ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done
