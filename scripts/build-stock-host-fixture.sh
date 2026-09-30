#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted &&
   "$HOME" == /Users/runner && "$ROOT" == "${GITHUB_WORKSPACE:-}" ]] || {
    echo "Hosted fixture build only; no local publication." >&2
    exit 2
}
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
DERIVED_DATA="$ROOT/.build/adhoc"
APP="$DERIVED_DATA/Build/Products/Debug/CMUX Maestro Preview.app"

# The production build portion of build-register.sh, without its combined install.
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
xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -alltargets \
    -configuration Debug -showBuildSettings -json "${SETTINGS[@]}" \
    > "$DERIVED_DATA/namespace-settings.json"
python3 "$ROOT/scripts/verify-build-metadata.py" --mode production \
    --settings "$DERIVED_DATA/namespace-settings.json" \
    --source-entitlements "$ROOT/CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements"
xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -scheme CMUXMaestroPreview \
    -configuration Debug -derivedDataPath "$DERIVED_DATA" "${SETTINGS[@]}" build
python3 "$ROOT/scripts/verify-build-metadata.py" --mode production --app "$APP"
echo "Verified signed production fixture built; no explicit install or registration performed."
