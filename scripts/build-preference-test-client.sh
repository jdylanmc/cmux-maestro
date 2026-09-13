#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/preference-coordination"
mkdir -p "$OUTPUT"

xcrun swiftc -swift-version 5 -strict-concurrency=complete \
    -default-isolation MainActor -parse-as-library \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotModels.swift" \
    "$ROOT/CMUXMaestroSidebar/Copilot/SidebarCopilotHistory.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarPreferenceStore.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarPreferences.swift" \
    "$ROOT/scripts/PreferenceCoordinationTestClient.swift" \
    -o "$OUTPUT/preference-test-client"
