#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

"$ROOT/scripts/fetch-sdk.sh"

xcodebuild \
    -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
    -scheme CMUXMaestroPreview \
    -configuration Debug \
    -derivedDataPath "$ROOT/.build/unsigned" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
