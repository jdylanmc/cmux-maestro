# Obsolete guide cleanup, disable and uninstall

[↑ CLI guide, enable, and uninstall](../cli-guide-and-uninstall.md) | [← Guide UI consumer probe](guide-ui-consumer-probe.md)

On next explicit **Enable Copilot Integration**, setup removes only its old
`Copilot/plugin/skills/maestro/SKILL.md` copy, if present, using owner-checked,
non-symlink traversal. It preserves other skills and files, including lifecycle,
icon and global guides. It never sweeps global paths or cached/live sessions.

## Disable or uninstall

Use **Remove Copilot Integration…**, then explicitly confirm. After ownership
and metadata checks, this disables and removes only the recognized dedicated
file, runs `copilot --no-auto-update plugin uninstall cmux-maestro-native`
when installed, verifies removal, then removes Maestro's native loader entry
point and launch configuration. It removes the owned CMUX Copilot hooks
(`cmux-maestro-cmux-hooks.json`) only when its bytes are a manifest Maestro
shipped, and puts it back if a later removal fails. A file Maestro did not write
stays, and uninstall names it.
Foreign or modified observer files are refused.
Global settings and disable keys are not removed. Do not touch live route bindings,
sockets and in-memory adapters. Close those sessions normally.
Restart/resume existing CLI
sessions to unload their cached hooks. Disable this sidebar in CMUX separately
if desired. Uninstall does not select or remove any other provider.
It also leaves the separately installed global guide untouched.

For individual future CLI launches, `MAESTRO_NATIVE_DISABLED=1` suppresses identity hooks.
`CMUX_COPILOT_HOOKS_DISABLED=1` silences only CMUX's own hooks; Maestro launches set it so CMUX's
restore never claims them (ADR 0024), and Maestro keeps observing them. This integration does not
change or use the legacy `MAESTRO_DISABLED` flag.
