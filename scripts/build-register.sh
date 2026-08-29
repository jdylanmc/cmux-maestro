#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/adhoc"
APP="$DERIVED_DATA/Build/Products/Debug/CMUX Maestro Preview.app"
APPEX="$APP/Contents/Extensions/CMUX Maestro Preview Extension.appex"
EXTENSION_ID="com.jdylanmc.CMUXMaestroPreview.Extension"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

"$ROOT/scripts/fetch-sdk.sh"

xcodebuild \
    -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
    -scheme CMUXMaestroPreview \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    build

if [[ ! -d "$APPEX" ]]; then
    echo "Expected extension was not built: $APPEX" >&2
    exit 1
fi

pluginkit -a "$APPEX"

if ! pluginkit -mAvvv -i "$EXTENSION_ID"; then
    echo "pluginkit did not discover $EXTENSION_ID" >&2
    exit 1
fi
