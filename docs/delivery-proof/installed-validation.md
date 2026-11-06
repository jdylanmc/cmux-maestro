# Installed implementation: checkpoint and validation

Part of the [native delivery proof](../delivery-proof.md). Previous page is [Parent-reported installed exchange and skill-name correction](installed-exchange.md). Next page is [Installed adapter wiring](installed-adapter.md).

**Implementation checkpoint:** runtime/setup/resource wiring and their targeted
contracts are implemented. The user-confirmed intent is stored unchanged at
`skills/maestro/intent.md`; the simple repo-native `SKILL.md` beside it teaches
discovery/send/reply and cross-references the existing lifecycle skill, without
an atomic-skill framework or tool-permission frontmatter grants. The source folder
is discoverable by `npx skills`, not an app resource or a runtime prerequisite.
The parent still owns final complete CI, independent review and installed live
validation. Targeted build and test evidence is recorded below.

Final distribution-correction validation:

- **M2 launcher:** three-field setup/node compatibility, ignored obsolete
  `pluginDirectory`, no `--plugin-dir`, and launches without any guide/plugin
  source. This correction leaves lifecycle R1-R5 code unchanged.
- **M3 Settings/setup/resources:** default production and validation Settings
  scenes share the native tabs; the actual copy handler emits the exact
  interactive global command. Isolated setup covers absent guide resources,
  precise obsolete-copy removal, repeated setup, preserved unrelated files,
  symlink refusal and unchanged runtime installation/uninstallation.
- **M4 tests/CI:** isolated Settings/setup/hook suite **35 passed**, integrated
  Settings/setup suites **20 passed**, launcher/proof/skill suite **55 passed**,
  orchestration **45 passed**, adapter **10 passed**, metadata **15 passed**,
  local-preview **60 passed**.
  The existing CI setup step now also compiles and runs Settings tests.
  Unsigned build and namespace validation passed; the built app contains no
  messaging guide. These are targeted checks, not a final full-CI claim.
- **M5 guide/findings:** global `/maestro`, separate runtime consent, prior live
  failures and user-reported global success, and the pre-merge local-source
  command are documented. `intent.md` remains byte-identical with SHA-256
  `8dd1495be16e27a92b43a038ab7b728b4d6fedcbae1e53f41aac11452fe54d42`.

This author performed no production setup, global install/refresh, provider
launch, live binding read or live endpoint mutation. Installed Settings UI
acceptance and independent review remain parent-owned; the GitHub-source command
cannot install this unpublished guide until merge.

Historical targeted validation before the final distribution correction (the
old packaged guide below is no longer shipped):

- `./scripts/build-unsigned.sh`: **BUILD SUCCEEDED**, and both namespace checks passed.
  The built app identifier is
  `com.jdylanmc.CMUXMaestroPreview.Validation.Unsigned`, not production.
- Exact byte comparisons passed for packaged `adapter.mjs`, `extension.mjs`,
  `maestro/SKILL.md`, `maestro/intent.md`, and lifecycle `SKILL.md`.
  Confirmed intent SHA-256 remains
  `8dd1495be16e27a92b43a038ab7b728b4d6fedcbae1e53f41aac11452fe54d42`,
  matching the parent's storage-gate receipt.
- `./scripts/test-copilot-setup.sh`: **30 tests passed**. Installation uses
  synthetic private paths and the real new skill/adapter resources; no provider
  process, production setup, or live endpoint is involved.
- Existing CI-registered suites passed: **45 orchestration, 20 Python
  launcher/proof/skill, 10 Node adapter, 15 metadata, 60 local-preview tests**.
  `git diff --check` passed. These are targeted results, not a claim that the
  parent's final full CI/review or live installed-product checks are complete.
