#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/adhoc"
APP="$DERIVED_DATA/Build/Products/Debug/CMUX Maestro Preview.app"
APPEX="$APP/Contents/Extensions/CMUX Maestro Preview Extension.appex"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

"$ROOT/scripts/fetch-sdk.sh"
mkdir -p "$DERIVED_DATA"
SETTINGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    ENABLE_CODE_COVERAGE=NO
    DEVELOPMENT_TEAM=
    CMUX_BUNDLE_ID_SUFFIX=
    CMUX_DISPLAY_NAME_SUFFIX=
    CMUX_SIDEBAR_EXTENSION_POINT_ID=com.cmuxterm.app.cmux.sidebar
)

# Xcode's application build can itself register with LaunchServices. Validate
# the resolved production namespace before entering this explicit publication path.
xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -alltargets \
    -configuration Debug -showBuildSettings -json "${SETTINGS[@]}" \
    > "$DERIVED_DATA/namespace-settings.json"
python3 "$ROOT/scripts/verify-build-metadata.py" --mode production \
    --settings "$DERIVED_DATA/namespace-settings.json" \
    --source-entitlements "$ROOT/CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements"

xcodebuild \
    -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
    -scheme CMUXMaestroPreview \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    "${SETTINGS[@]}" \
    build

if [[ ! -d "$APPEX" ]]; then
    echo "Expected extension was not built: $APPEX" >&2
    exit 1
fi

python3 "$ROOT/scripts/verify-build-metadata.py" --mode production --app "$APP"
pluginkit -a "$APPEX"
python3 "$ROOT/scripts/verify-build-metadata.py" --mode production --registration "$APPEX"
