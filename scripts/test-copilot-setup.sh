#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--compile-only" && "${1:-}" != "--guide-only" ) ]]; then
    echo "Usage: test-copilot-setup.sh [--compile-only|--guide-only]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/setup-tests"
FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr"
mkdir -p "$OUTPUT"
export LLVM_PROFILE_FILE="$OUTPUT/default-%p.profraw"

TEST_SOURCES=(
    "$ROOT/CMUXMaestroPreviewTests/CLIIntegrationGuideTests.swift"
)
if [[ "${1:-}" == "--guide-only" ]]; then
    TEST_SOURCES+=("$ROOT/scripts/CLIIntegrationGuideTestMain.swift")
else
    TEST_SOURCES+=(
        "$ROOT/CMUXMaestroPreviewTests/CopilotHookTests.swift"
        "$ROOT/CMUXMaestroPreviewTests/CopilotSetupTests.swift"
        "$ROOT/CMUXMaestroPreviewTests/CopilotSetupObservationTests.swift"
        "$ROOT/CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift"
        "$ROOT/CMUXMaestroPreviewTests/MetadataProcessTestWatchdog.swift"
        "$ROOT/CMUXMaestroPreviewTests/MaestroAppLifecycleTests.swift"
        "$ROOT/CMUXMaestroPreviewTests/SidebarAppKitTestScope.swift"
        "$ROOT/CMUXMaestroPreviewTests/WorkerLaunchSettingsTests.swift"
        "$ROOT/scripts/CopilotSetupTestMain.swift"
    )
fi
if [[ "${1:-}" == "--compile-only" ]]; then
    TEST_SOURCES+=(
        "$ROOT/CMUXMaestroPreviewTests/CLIIntegrationGuideRenderingTests.swift"
        "$ROOT/CMUXMaestroPreviewTests/GuideAcceptanceEvidence.swift"
    )
fi
xcrun swiftc -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures \
    -default-isolation MainActor \
    -parse-as-library -emit-module -emit-library -enable-testing -module-name CMUXMaestroPreview \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotPaths.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityVerifier.swift" \
    "$ROOT/CMUXMaestroCopilotHook/CopilotHookRecorder.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CopilotSetup.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CopilotSetupObservation.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CopilotSetupMetadata.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CopilotObserverRegistration.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/MaestroAppLifecycle.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/WorkerLaunchSettings.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CLIIntegrationGuide.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CLIIntegrationSettingsView.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CLIIntegrationGuideReader.swift" \
    "$ROOT/CMUXMaestroPreview/Integration/CLIIntegrationGuideModel.swift" \
    -emit-module-path "$OUTPUT/CMUXMaestroPreview.swiftmodule" \
    -Xlinker -install_name -Xlinker "$OUTPUT/libCMUXMaestroPreview.dylib" \
    -o "$OUTPUT/libCMUXMaestroPreview.dylib"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures \
    -parse-as-library \
    -I "$OUTPUT" -L "$OUTPUT" -lCMUXMaestroPreview -F "$FRAMEWORKS" \
    -external-plugin-path "$TOOLCHAIN/lib/swift/host/plugins/testing#$TOOLCHAIN/bin/swift-plugin-server" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "${TEST_SOURCES[@]}" -o "$OUTPUT/setup-tests"
if [[ "${1:-}" != "--guide-only" ]]; then
    xcrun swiftc -g -parse-as-library \
        -I "$OUTPUT" -L "$OUTPUT" -lCMUXMaestroPreview \
        "$ROOT/CMUXMaestroPreviewTests/MetadataProcessTestWatchdog.swift" \
        "$ROOT/scripts/MetadataWatchdogProbe.swift" -o "$OUTPUT/metadata-watchdog-probe"
fi
if [[ "${1:-}" == "--compile-only" ]]; then
    exit 0
fi
if [[ "${1:-}" != "--guide-only" ]]; then
    python3 "$ROOT/scripts/test-metadata-watchdog.py" \
        --probe "$OUTPUT/metadata-watchdog-probe" --results-root "$OUTPUT/metadata-watchdog"
fi
"$OUTPUT/setup-tests"
