#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/shell-reducer-tests"
mkdir -p "$OUTPUT"

xcrun swiftc -swift-version 5 -strict-concurrency=complete \
    -default-isolation MainActor -parse-as-library \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotModels.swift" \
    "$ROOT/CMUXMaestroPreview/Domain/AgentSignals.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotEventReducer.swift" \
    "$ROOT/scripts/CopilotShellReducerTests.swift" \
    -o "$OUTPUT/shell-reducer-tests"

"$OUTPUT/shell-reducer-tests"
