#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/preference-coordination"
mkdir -p "$OUTPUT"

xcrun swiftc -swift-version 5 -strict-concurrency=complete \
    -default-isolation MainActor -parse-as-library -enable-bare-slash-regex \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotModels.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotWorktree.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotPaths.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotEventReducer.swift" \
    "$ROOT/CMUXMaestroPreview/Domain/AgentSignals.swift" \
    "$ROOT/CMUXMaestroPreview/Domain/AgentSessionSnapshot.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotSnapshotAdapter.swift" \
    "$ROOT/CMUXMaestroSidebar/Hierarchy/HierarchySnapshot.swift" \
    "$ROOT/CMUXMaestroSidebar/Copilot/SidebarCopilotHistory.swift" \
    "$ROOT/CMUXMaestroSidebar/Copilot/SidebarCopilotTree.swift" \
    "$ROOT/CMUXMaestroSidebar/Copilot/SidebarCopilotProjectionCache.swift" \
    "$ROOT/CMUXMaestroSidebar/Copilot/SidebarSessionProjectionCache.swift" \
    "$ROOT/CMUXMaestroSidebar/Copilot/SidebarWorktreeGroups.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarPreferenceStore.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarPreferences.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarIconPreferences.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarOrder.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarTags.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarBeatsModel.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift" \
    "$ROOT/CMUXMaestroSidebar/UI/SidebarIconModels.swift" \
    "$ROOT/CMUXMaestroSidebar/State/SidebarLayout.swift" \
    "$ROOT/CMUXMaestroPreviewTests/PreferenceAttentionFixture.swift" \
    "$ROOT/scripts/PreferenceCoordinationTestClient.swift" \
    -o "$OUTPUT/preference-test-client"
