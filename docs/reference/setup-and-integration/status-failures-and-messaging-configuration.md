# Status, failures and messaging configuration

[↑ Setup and Copilot integration](../setup-and-integration.md) | [← Legacy migration and disable preservation](legacy-migration-and-disable-preservation.md)

**Status retains disable detail.** Completed registration records bounded
opaque provider keys tied to its exact generation and tested provider version.
Check Registration remains file-only. It distinguishes all/some configured
observer disables using that receipt. Reports unresolved applicability for
unknown keys or stale/missing provenance. Never guesses that unrelated key
disables observer. Never starts metadata subprocess. Incomplete transaction or
conflicting/missing plugin state takes precedence over ordinary disabled status.
Verified setup with preserved all/subset disables = successful CLI completion
(stdout, exit 0), with explicit disable message. Actual failures remain
nonzero. Malformed command arguments keep usage exit 2.

Failures identify last completed phase, not blanket installation success.
Interrupted transaction may retain disabled owned file while old
plugin remains installed, or leave hookless plugin awaiting publication.
Retry revalidates provenance and content. Retained disabled stage stays
disabled conservatively. Foreign edits require manual review, not automatic
rollback. Existing sessions keep cached hooks. Any provider reload,
restart or resume is human-owned. See
[compatibility limits](../../behavioral-parity/observer-registration.md).

Messaging launch configuration and stored nodes keep three-field
`{version, routes, extension}` contract. Obsolete `pluginDirectory` setup
field is ignored for compatibility. Never validated or passed to Copilot.
Managed launches keep `--experimental`, pins, denies, coordinator-only explicit
YOLO and terminal I/O. They do not require guide or pass `--plugin-dir`.
