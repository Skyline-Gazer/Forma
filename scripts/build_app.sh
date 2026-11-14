#!/bin/sh
# Assemble Forma.app from the SwiftPM product, ad-hoc sign it, and verify that the
# result is both signable and launchable in structure.
#
# This produces a development bundle, not a release artifact: ad-hoc signature,
# no Developer ID, no notarization, no stapling, no App Store packaging.
#
# Two rules learned from the Batch 2A field run:
#
#   1. The resource bundle must live in `Contents/Resources`. SwiftPM's generated
#      `Bundle.module` accessor looks in the `.app` root, which `codesign
#      --strict` refuses ("unsealed contents present in the bundle root"), so the
#      app resolves its bundle itself (`FormaResourceBundle`).
#   2. A bundle that "packages" without starting is not packaged. The script
#      asserts the required resources are present; `scripts/smoke_app.sh` proves
#      the result starts.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT/build"}
APP="$OUTPUT_DIR/Forma.app"
IDENTITY=${CODESIGN_IDENTITY:--}

# Files every installation must be able to open. A missing one means the app
# would fail at launch or silently lose a capability, so the build stops.
REQUIRED_RESOURCES="
project-archive.v1.json
vendor-library.v1.json
forma-governance-cases.v1.json
forma-eligibility.v1.json
manifest-1.0.schema.json
proposal-1.0.schema.json
"

echo "== environment"
xcodebuild -version
swift --version

echo "== build"
swift build --package-path "$ROOT/FormaApp" -c "$CONFIGURATION" --product Forma \
    --only-use-versions-from-resolved-file
BIN=$(swift build --package-path "$ROOT/FormaApp" -c "$CONFIGURATION" --show-bin-path)
echo "bin: $BIN"

CORE_BUNDLE="$BIN/Forma_FormaCore.bundle"
if [ ! -d "$CORE_BUNDLE" ]; then
    echo "error: $CORE_BUNDLE is missing; the app cannot load its profiles, schemas or policy" >&2
    exit 1
fi

echo "== assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Forma" "$APP/Contents/MacOS/Forma"

# Copy every resource bundle the build produced. FormaCore's is required; a
# dependency's is copied when present so a future dependency does not silently
# lose its resources either.
for bundle in "$BIN"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
    echo "copied $(basename "$bundle")"
done

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

RESOURCE_BUNDLE="$APP/Contents/Resources/Forma_FormaCore.bundle"
test -d "$RESOURCE_BUNDLE" || { echo "error: resource bundle missing from Contents/Resources" >&2; exit 1; }
# SwiftPM's bundle layout differs between toolchains (a shallow bundle with the
# files at its root, or a macOS bundle with Contents/Resources). Check by file
# name rather than by assuming one layout, and print what was found so the next
# layout change is diagnosable from the log.
echo "resource layout:"
find "$RESOURCE_BUNDLE" -maxdepth 3 | sed -n '1,20p' | sed 's/^/  /'
for resource in $REQUIRED_RESOURCES; do
    if ! find "$RESOURCE_BUNDLE" -name "$resource" -print -quit | grep -q .; then
        echo "error: required resource missing: $resource" >&2
        exit 1
    fi
done
echo "resources: required set present"

# The app must not contain a resource bundle at the bundle root: `codesign
# --strict` rejects it, and the root is not a sealed location.
if [ -d "$APP/Forma_FormaCore.bundle" ]; then
    echo "error: Forma_FormaCore.bundle is at the .app root; move it to Contents/Resources" >&2
    exit 1
fi

echo "== sign"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/FormaApp/Forma.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "== report"
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n '1,12p'
echo "== done: $APP"
