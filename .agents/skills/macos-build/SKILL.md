---
name: macos-build
description: >
  Build and validate CMUX Maestro using its checked-in scripts. Use this skill whenever the user
  asks to build, compile, test, register, or check whether the macOS app and ExtensionKit sidebar
  compile successfully. Also use it after implementation changes when repository validation is
  required.
---

# Build CMUX Maestro

Use CMUX Maestro's checked-in scripts as the authority. Do not replace them with
ad hoc `xcodebuild` commands: the scripts select full Xcode, fetch the pinned
CMUX ExtensionKit Software Development Kit (SDK), isolate derived data, and
apply the repository's signing policy.

Run commands from the repository root.

## Unsigned Build

```bash
./scripts/build-unsigned.sh
```

This is the smallest compile check. It builds the `CMUXMaestroPreview` scheme
without code signing and writes derived data beneath `.build/unsigned`.

## Tests

```bash
./scripts/test.sh
```

Run this after code or test changes. It builds and executes the focused Swift
test target with derived data beneath `.build/tests`.

## Explicit Alpha Installation

```bash
./scripts/build-register.sh
```

Run only with explicit, current installation authority. It performs an ad hoc
signed build and invokes the coordinated stable-app/Copilot installer, including
official provider plugin operations. It is not a validation-only registration
probe and must not run incidentally after code changes.

## Validation Selection

- Compile-only request: run `./scripts/build-unsigned.sh`.
- Implementation change: run `./scripts/build-unsigned.sh` and
  `./scripts/test.sh`.
- Extension registration, manifest, signing, or host-discovery change: validate
  through the authorized test venue; run `./scripts/build-register.sh` only
  with a separate installation grant.
- Continuous Integration (CI) request: execute the authoritative commands from
  `.github/workflows/ci.yml`; do not substitute a local partial check.

Honor caller restrictions on GUI/native-host testing. Focused non-UI checks
include `python3 scripts/test-local-preview.py` and
`./scripts/test-copilot-setup.sh`; they do not waive hosted CI or prove stock-host
loaded behavior.

Do not run the build and test scripts concurrently. Both may fetch or inspect
the same pinned SDK state, and sequential output is easier to attribute.

## Failure Handling

- Preserve complete command output when a script fails.
- Diagnose the first actionable compiler, linker, test, signing, or
  registration error.
- Fix the root cause without weakening tests, signing constraints, sandboxing,
  or extension manifest requirements.
- Re-run the failed script, then any later required validation scripts.
- Do not manually install or replace the CMUX SDK; `scripts/fetch-sdk.sh` owns
  the pinned checkout and concurrency controls.

## Repository Cleanliness

After validation, inspect:

```bash
git status --short
```

Never commit `.build/`, `DerivedData/`, `vendor/CmuxExtensionKit/`, SDK fetch
state, or Xcode user data.
