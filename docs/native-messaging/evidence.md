# Evidence, corrected assumptions, and remaining gap

Part of [native messaging: architecture and research findings](../native-messaging-architecture.md). Previous page is [Owned-descendant close: stock host behavior and admission limits](close-host-behavior.md).

Initial SDK inspection used npm Copilot **1.0.83**, while live sessions reported
**1.0.87-0**. Source declarations justified an experiment, not a compatibility or
draft-safety guarantee. The native proof demonstrated agent-authored A -> B -> A.
The human explicitly confirmed an unsent draft remained exact and editable.
Separate harness-origin injection demonstrated app-background response; it was
not an agent-authored send and not a sidebar-hidden test.

Installed revision `93d6968`, normal updater and human-enabled integration then
supported three fresh ordinary-working-directory participants: A discovered B
and C with generations, and A -> B -> A returned `installed-violet-54-1`.
CMUX's **Default sidebar** was selected. This disproves a dependency on the Maestro
sidebar being selected, not all visibility conditions or reliable delivery.
Mocked transport/setup tests and packaging checks do not prove native UI behavior.

Plugin-based guide discovery failed live: bare-name lookup failed in interactive
sessions despite later read-only discovery listing the skill; qualified lookup
also failed. Explicit `--plugin-dir` did not fix the live failure. No exact
upstream cause is claimed, and neither workaround remains in the launcher.

At `2026-09-22T12:03:56.533Z`, the user reported successful global local-source
installation with `npx skills` **1.5.26** to `~/.agents/skills/maestro`, followed
by successful Copilot global discovery. Global `npx skills` is now the only guide
distribution: `/maestro` or `{"skill":"maestro"}`. This is observed discovery,
not a guarantee across CLI versions or proof of every live messaging condition.
The GitHub-source command in Settings requires the skill to merge to `main`;
[local-source acceptance instructions](../reference/cli-guide-and-uninstall.md#cli-integration-install-the-global-guide)
cover development without movable refs or automatic installation.

Setup writes only `{version, routes, extension}` for messaging. The old
`pluginDirectory` field is ignored if encountered. On explicit setup only,
the obsolete messaging guide in the installer's own plugin is removed, preserving
unrelated and global skills. No live files were changed for this correction.
Installed Settings UI acceptance and any consentful refresh remain separate from
the already observed global discovery success.
