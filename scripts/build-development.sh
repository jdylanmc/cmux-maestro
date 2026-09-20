#!/bin/bash
set -euo pipefail

# Explicit local opt-in. No account access, profile downloads, install or pluginkit.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${CMUX_DEVELOPMENT_TEAM:?Set a local Apple Developer Team ID}"
: "${CMUX_DEVELOPMENT_IDENTITY:?Set a local Apple Development signing identity}"
: "${CMUX_NATIVE_APP_PROFILE:?Set the installed app development profile name or UUID}"
: "${CMUX_NATIVE_EXTENSION_PROFILE:?Set the installed extension development profile name or UUID}"
[[ "$CMUX_DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "Invalid Team ID format." >&2; exit 1; }
[[ "$CMUX_DEVELOPMENT_IDENTITY" == "Apple Development:"* ]] || {
    echo "This optional path requires an Apple Development identity." >&2; exit 1;
}
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
DERIVED_DATA="$ROOT/.build/development"
APP="$DERIVED_DATA/Build/Products/Debug/CMUX Maestro Preview.app"
SETTINGS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$CMUX_DEVELOPMENT_IDENTITY"
    "DEVELOPMENT_TEAM=$CMUX_DEVELOPMENT_TEAM"
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
    "CMUX_NATIVE_APP_ENTITLEMENTS=$ROOT/scripts/native-development.entitlements"
    "CMUX_NATIVE_APP_PROFILE=$CMUX_NATIVE_APP_PROFILE"
    "CMUX_NATIVE_EXTENSION_PROFILE=$CMUX_NATIVE_EXTENSION_PROFILE"
    CMUX_BUNDLE_ID_SUFFIX= CMUX_DISPLAY_NAME_SUFFIX=
    CMUX_SIDEBAR_EXTENSION_POINT_ID=com.cmuxterm.app.cmux.sidebar
)
"$ROOT/scripts/fetch-sdk.sh"
mkdir -p "$DERIVED_DATA"
xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -alltargets \
    -configuration Debug -showBuildSettings -json "${SETTINGS[@]}" \
    > "$DERIVED_DATA/namespace-settings.json"
python3 "$ROOT/scripts/verify-build-metadata.py" --mode development \
    --settings "$DERIVED_DATA/namespace-settings.json" \
    --source-entitlements "$ROOT/CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements"
xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -scheme CMUXMaestroPreview \
    -configuration Debug -derivedDataPath "$DERIVED_DATA" "${SETTINGS[@]}" build
python3 "$ROOT/scripts/verify-build-metadata.py" --mode development --app "$APP"
echo "Development build verified; not installed or explicitly registered. Runtime readiness and human signing still require local validation."
