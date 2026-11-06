# Effect

[↑ CI runner placement](../ci-runner-placement.md) | [← Not moved](not-moved.md)

Documentation-only pull requests (`docs/**`, `README.md`, `CHANGELOG.md`, `CONTEXT.md` or `AGENTS.md`, other than the merge policy) run no macOS job; `validate-portable` runs on Linux. Merge-policy changes still run `validate-contracts`, because `scripts/test-build-metadata.py` reads the policy. The measured before/after effect is archived. [Archived evidence](../../evidence/ci.md#effect).
