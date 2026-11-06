# CLI guide, enable, and uninstall

Global /maestro guide, guide acceptance evidence, enable and uninstall rules. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

### CLI Integration: install the global guide

Maestro's native **Settings > CLI Integration** tab explains the guide. It
provides read-only guide-content status, **Re-check**, selectable command text
and **Copy install command**. Each global location reports separately: missing,
unreadable, different, or **Matches this build**. Match compares file's exact
bytes with a SHA-256 reference generated from this build's canonical
`skills/maestro/SKILL.md`. Build does not bundle the global guide itself.
Missing or invalid build reference is an explicit comparison error, not a
local-guide verdict. Different content may be newer or customized, not outdated.
Run this command in your own terminal to install or update:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro maestro-demo --agent github-copilot --global --copy
```

Review the installer's interactive confirmation. Command deliberately omits
`--yes`. Settings only reads guide content and copies text. It does not execute `npx`, open a terminal,
install a skill, or change global configuration. This is the **one canonical
guide distribution**, from `skills/maestro/{SKILL.md,intent.md}` and
`skills/maestro-demo/SKILL.md`. Invoke global
**`/maestro`**, or use the skill tool with `{"skill":"maestro"}`. No extra
skill-activation grants required. Guide never secretly installs runtime;
native messaging works without it. Runtime stays the separate **Enable Copilot
Integration** action, including the existing lifecycle and icon plugin skills.

#### Maestro demo guide

See [Maestro demo guide and PR acceptance](cli-guide-and-uninstall/maestro-demo-and-pr-acceptance.md).

#### Development and PR acceptance

See [development and PR acceptance](cli-guide-and-uninstall/maestro-demo-and-pr-acceptance.md#development-and-pr-acceptance).

#### Re-check and installed guide status

See [re-check, installed guide status and acceptance evidence](cli-guide-and-uninstall/re-check-and-installed-guide-status.md).

#### Guide acceptance evidence

See [guide acceptance evidence](cli-guide-and-uninstall/re-check-and-installed-guide-status.md#guide-acceptance-evidence).

#### Acceptance composition and runner

See [acceptance composition and runner](cli-guide-and-uninstall/acceptance-composition-and-runner.md).

#### Fresh acceptance provenance

See [fresh acceptance provenance](cli-guide-and-uninstall/fresh-acceptance-provenance.md).

#### Guide UI consumer probe

See [guide UI consumer probe](cli-guide-and-uninstall/guide-ui-consumer-probe.md).

#### Obsolete guide cleanup

See [obsolete guide cleanup, disable and uninstall](cli-guide-and-uninstall/obsolete-guide-cleanup.md).

### Disable or uninstall

See [disable or uninstall](cli-guide-and-uninstall/obsolete-guide-cleanup.md#disable-or-uninstall).
