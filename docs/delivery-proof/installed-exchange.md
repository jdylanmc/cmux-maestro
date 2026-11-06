# Parent-reported installed exchange and skill-name correction

Part of the [native delivery proof](../delivery-proof.md). Previous page is [Bounded live checks and cleanup](live-checks.md). Next page is [Installed implementation: checkpoint and validation](installed-validation.md).

The parent installed revision `93d6968` through the normal updater and the human
successfully used **Enable Copilot Integration**. Three fresh managed participants
launched with explicitly approved `--yolo` in ordinary working directories, not
proof fixtures. A called `maestro_peers` and found B and C with generation-bearing
addresses. The installed A -> B -> A exchange produced `installed-violet-54-1` at
`2026-09-22T00:13:46.727Z`. CMUX's **Default sidebar** was selected, demonstrating
that this exchange did not require the Maestro sidebar to be selected. This does
not establish the separate sidebar-hidden condition or repeat draft/background
acceptance on the installed build.

The same run exposed a skill-discovery failure: the skill tool call
`{"skill":"maestro"}` failed with **`Skill not found: maestro`**, although the parent
reported plugin `cmux-maestro-native` v1.1.0 and its installed `skills/maestro`
directory. The plugin layout follows the documented legacy `skills/` default;
this is not evidence that the package needs an explicit `skills` field.

Copilot **1.0.87-0** shipped `app.js` constructs plugin skill commands as
`pluginName:skillName` (functions `DUe` at line 1514 and `n0n` at line 1800);
skill listing/recognition uses `skillsInvocationName` at line 3122.
The [public plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference#component-path-fields)
confirms the default directory convention. The initial interpretation incorrectly
conflated qualified slash-command names with skill-tool identifiers. A received
the parent's qualified-name diagnostic but correctly ignored it as outside its
authorized peer task. A separate fresh participant explicitly authorized to test
`{"skill":"cmux-maestro-native:maestro"}` then failed with
**`Skill not found: cmux-maestro-native:maestro`** at
`2026-09-22T00:19:41.795Z`.

Bounded read-only discovery using the exact worker executable and CLI **1.0.87-0**
later listed the installed messaging skill as `name: maestro`,
`source: plugin`, `enabled: true`. The native loader identifies its plugin as
`cmux-maestro-native`, while `skillsInvocationName` returns the bare skill name.
At that stage, the plugin used slash command `/cmux-maestro-native:maestro`
and skill-tool argument `{"skill":"maestro"}`. That distinction did not fix live
discovery. The [final distribution decision](guide-distribution.md)
supersedes plugin messaging-guide installation and invocation with global
`/maestro`. Lifecycle/icon slash references remain qualified.

**The cause of the initial missing-inventory observation remains unresolved.** The failing
session's startup model-visible inventory did not contain the messaging skill,
whereas later read-only discovery did. The permitted comparison found no
installer/runtime root or registered-plugin discrepancy; it did not establish
the cause of that startup/current-inventory difference. Neither the namespace
correction nor plugin discovery proved live skill execution. Subsequent bare
plugin and explicit-plugin-directory live failures led to the observed successful
global installation in
[guide distribution](guide-distribution.md). No private registry contents, account/model data,
credentials or full debug transcripts are included in these findings.
