#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/setup-tests"
FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr"
mkdir -p "$OUTPUT"
export LLVM_PROFILE_FILE="$OUTPUT/default-%p.profraw"

xcrun swiftc -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures \
    -default-isolation MainActor \
    -parse-as-library -emit-module -emit-library -enable-testing -module-name CMUXMaestroPreview \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotPaths.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityVerifier.swift" \
    "$ROOT/CMUXMaestroCopilotHook/CopilotHookRecorder.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CopilotSetup.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/WorkerLaunchSettings.swift" \
    -emit-module-path "$OUTPUT/CMUXMaestroPreview.swiftmodule" \
    -Xlinker -install_name -Xlinker "$OUTPUT/libCMUXMaestroPreview.dylib" \
    -o "$OUTPUT/libCMUXMaestroPreview.dylib"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures \
    -parse-as-library \
    -I "$OUTPUT" -L "$OUTPUT" -lCMUXMaestroPreview -F "$FRAMEWORKS" \
    -external-plugin-path "$TOOLCHAIN/lib/swift/host/plugins/testing#$TOOLCHAIN/bin/swift-plugin-server" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "$ROOT/CMUXMaestroPreviewTests/CopilotHookTests.swift" \
    "$ROOT/CMUXMaestroPreviewTests/CopilotSetupTests.swift" \
    "$ROOT/CMUXMaestroPreviewTests/SidebarAppKitTestScope.swift" \
    "$ROOT/CMUXMaestroPreviewTests/WorkerLaunchSettingsTests.swift" \
    "$ROOT/scripts/CopilotSetupTestMain.swift" -o "$OUTPUT/setup-tests"
"$OUTPUT/setup-tests"
