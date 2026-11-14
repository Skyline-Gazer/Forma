#!/bin/sh
# Verify one assembled Forma.app: structure, required resources, and a strict
# code-signature check. Usable on a directory produced by build_app.sh or on a
# bundle restored from a CI artifact.
#
# It does not launch the app; `smoke_app.sh` does that.
set -eu

APP=${1:-}
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "usage: verify_app_bundle.sh <Forma.app>" >&2
    exit 2
fi

REQUIRED_RESOURCES="
project-archive.v1.json
vendor-library.v1.json
forma-governance-cases.v1.json
forma-eligibility.v1.json
manifest-1.0.schema.json
proposal-1.0.schema.json
"

echo "== $APP"
test -f "$APP/Contents/Info.plist" || { echo "error: Info.plist missing" >&2; exit 1; }
plutil -lint "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/Forma" || { echo "error: executable missing" >&2; exit 1; }

BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
test "$BUNDLE_ID" = "io.github.skyline-gazer.forma" || { echo "error: unexpected bundle id $BUNDLE_ID" >&2; exit 1; }

RESOURCE_BUNDLE="$APP/Contents/Resources/Forma_FormaCore.bundle"
test -d "$RESOURCE_BUNDLE" || { echo "error: Forma_FormaCore.bundle missing from Contents/Resources" >&2; exit 1; }
for resource in $REQUIRED_RESOURCES; do
    find "$RESOURCE_BUNDLE" -name "$resource" -print -quit | grep -q . \
        || { echo "error: required resource missing: $resource" >&2; exit 1; }
done

if [ -d "$APP/Forma_FormaCore.bundle" ]; then
    echo "error: resource bundle at the .app root would break codesign --strict" >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n '1,12p'
echo "== verified: $APP"
