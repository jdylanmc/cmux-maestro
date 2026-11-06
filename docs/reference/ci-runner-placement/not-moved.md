# Not moved

[↑ CI runner placement](../ci-runner-placement.md) | [← Portability proof](portability-proof.md) | [Effect →](effect.md)

| Command | Why it stays on macOS |
| --- | --- |
| `python3 scripts/test-build-metadata.py` | Runs `/usr/bin/plutil` to read the Xcode project. |
| `python3 scripts/test-pet-kit.py`, `test-beats.py`, `test-joe-role-appearance.py` | These load or run `scripts/cmux-maestro-orchestrator.py`, which hard-codes tool paths, including the macOS-only `/usr/bin/sips`. `test-beats.py` also changes `TZ` through the system time zone database. Portability is not proven. |
| `python3 scripts/test-delivery-proof.py`, `node --test scripts/test-delivery-proof.mjs` | Process, socket and terminal-launch behaviour, not proven on Linux. Moving them would save about 10 seconds of macOS time per run. |
| `python3 scripts/test-local-preview.py` | Compiles Swift fixtures. |
| `python3 scripts/test-cmux-maestro-orchestrator.py` | Process-group and controller behaviour, not proven on Linux. |
| Shell reducer, SDK fetch, hooks, sandbox, unsigned build, setup, `test.sh`, guide probe | Native builds, AppKit, sandbox or hosted UI. |

- Moving more of these would not reduce macOS jobs: `validate-contracts` would
  still run on macOS for every change that reaches it.
- Only whole-suite moves that empty a macOS job for a class of changes free
  capacity. Documentation is that class.
