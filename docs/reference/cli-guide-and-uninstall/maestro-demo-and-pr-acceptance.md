# Maestro demo guide and PR acceptance

[↑ CLI guide, enable, and uninstall](../cli-guide-and-uninstall.md) | [Re-check, installed guide status and acceptance evidence →](re-check-and-installed-guide-status.md)

**`/maestro-demo`** is an optional, human-requested live demonstration: two visible
interactive workers by default, three on request, distinct icons/colors, their
own tags and original locally drawn pets, and one native-message encore each.
It uses the installed lifecycle and pet skills; it does not install them or add
permissions. Closing is a separate human choice. Its presenter notes describe
sidebar features without driving the UI or restarting CMUX.
Preflight selects an exact launch folder trusted in the child's configuration;
an explicit parent `--config-dir` is not assumed to propagate. Workers reuse it
read-only, with separate temporary artwork/result directories. If trust cannot
be established, the presenter must trust one chosen folder before the demo.
YOLO does not suppress Copilot's configuration-trust prompt.
Initial worker reports target the exact spawning demo parent, not a nested
launch wrapper's root coordinator. Replies use the real envelope sender.
The Settings status and `maestro-guide.sha256` remain **`/maestro`-only**; they
do not attest to the demo guide's contents or session discovery.

## Development and PR acceptance

**Development / PR acceptance before merge:** repository command in
[CLI Integration](../cli-guide-and-uninstall.md#cli-integration-install-the-global-guide) cannot
install the unpublished skill from `main`. From this checkout's root, human
may run the same installer against local source instead:

```sh
npx skills add . --skill maestro maestro-demo --agent github-copilot --global --copy
```

Settings embeds no branch refs, automatic refresh, or release machinery.
That is an observed location. Do not assume
all global skills live under `.copilot`. Bare plugin loading and explicit
`--plugin-dir` both failed live. No upstream root cause is claimed. See the
[public findings](../../delivery-proof/guide-distribution.md).
Refresh of user's existing global copy remains a separate consentful action.

[Dated discovery evidence](../../evidence/reference.md#maestro-demo-guide-and-pr-acceptance).
