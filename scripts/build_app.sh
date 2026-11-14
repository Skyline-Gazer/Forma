#!/bin/sh
# Assemble Forma.app from the SwiftPM product and sign it ad-hoc.
#
# Batch 1 scope: this produces a bundle that can be launched and inspected on a
# developer machine. It is NOT a release artifact:
#   - ad-hoc signature ("-"), no Developer ID, no notarization, no stapling;
#   - no App Store packaging;
#   - the icon is optional; without FormaApp/Resources/AppIcon.icns the bundle
#     keeps the generic icon.
#
# Every step is verified, so a silently broken bundle fails the CI job instead of
# producing something that only looks packaged.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT/build"}
APP="$OUTPUT_DIR/Forma.app"
IDENTITY=${CODESIGN_IDENTITY:--}

echo "== environment"
xcodebuild -version
swift --version

echo "== build"
swift build --package-path "$ROOT/FormaApp" -c "$CONFIGURATION" --product Forma \
    --only-use-versions-from-resolved-file
BIN=$(swift build --package-path "$ROOT/FormaApp" -c "$CONFIGURATION" --show-bin-path)

echo "== assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Forma" "$APP/Contents/MacOS/Forma"
# The SwiftPM build directory is not the bundle: resources the app expects at
# runtime must be copied explicitly.
if [ -d "$BIN/Forma_FormaApp.bundle" ]; then
    cp -R "$BIN/Forma_FormaApp.bundle" "$APP/Contents/Resources/"
fi
cp "$ROOT/FormaApp/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/FormaApp/Resources/AppIcon.icns" ]; then
    cp "$ROOT/FormaApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "note: no AppIcon.icns; the bundle will use the generic application icon"
fi

echo "== verify bundle layout"
plutil -lint "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/Forma"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
MINIMUM=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
echo "bundle id: $BUNDLE_ID (minimum macOS $MINIMUM)"
test "$BUNDLE_ID" = "io.github.skyline-gazer.forma"

echo "== sign"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/FormaApp/Forma.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "== report"
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n '1,12p'
echo "== done: $APP"
