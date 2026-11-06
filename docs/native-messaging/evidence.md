# Evidence, corrected assumptions, and remaining gap

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Owned-descendant close: stock host behavior and admission limits](close-host-behavior.md)

Initial SDK inspection used npm Copilot **1.0.83**, while live sessions reported
**1.0.87-0**. Source declarations justified an experiment, not a compatibility
or draft-safety guarantee. The native proof showed agent-authored A -> B -> A,
and the human explicitly confirmed an unsent draft remained exact and editable.
Separate harness-origin injection showed app-background response. It was not an
agent-authored send or a sidebar-hidden test.

Installed revision `93d6968`, the normal updater and human-enabled integration
then supported three fresh ordinary-working-directory participants: A
discovered B and C with generations, and A -> B -> A returned
`installed-violet-54-1`. CMUX's **Default sidebar** was selected. This
disproves a dependency on selecting the Maestro sidebar, not all visibility
conditions, and does not show reliable delivery. Mocked transport/setup tests
and packaging checks do not prove native UI behavior.

Plugin-based guide discovery failed live. Bare-name lookup failed in
interactive sessions even though later read-only discovery listed the skill,
qualified lookup also failed, and explicit `--plugin-dir` did not fix it. No
exact upstream cause is claimed, and neither workaround remains in the
launcher.

At `2026-09-22T12:03:56.533Z`, the user reported a successful global
local-source installation with `npx skills` **1.5.26** to
`~/.agents/skills/maestro`, followed by successful Copilot global discovery.
Global `npx skills` is now the only guide distribution: `/maestro` or
`{"skill":"maestro"}`. This is observed discovery, not a guarantee across CLI
versions or proof of every live messaging condition. The GitHub-source command
in Settings needs the skill merged to `main`;
[local-source acceptance instructions](../reference/cli-guide-and-uninstall.md#cli-integration-install-the-global-guide)
cover development without movable refs or automatic installation.

Setup writes only `{version, routes, extension}` for messaging and ignores an
old `pluginDirectory` field. Only explicit setup removes the obsolete messaging
guide from the installer's own plugin, preserving unrelated and global skills.
No live files changed for this correction. Installed Settings UI acceptance and
any consentful refresh are separate from the observed global discovery
success.
