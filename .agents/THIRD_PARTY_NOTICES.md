# Project skill dependency notices

The dependency skill files under `skills/` are checked-in development guidance
and tooling, not application resources. `../skills-lock.json` records each
skill's source, source path, and content hash. Preserve upstream notices when
refreshing these copies.

These notices cover the dependency material below. They do not select a
project-wide license for CMUX Maestro or replace file-specific terms.

| Source | Applicable upstream notices |
| --- | --- |
| [jdylanmc/agent-skills](https://github.com/jdylanmc/agent-skills) | MIT; [upstream license](licenses/jdylanmc-agent-skills.LICENSE). Preserve additional notices and licenses bundled with individual skills, including `skills/setup/`. |
| [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) | GPL-3.0-or-later except where an accompanying notice states otherwise; [upstream license](licenses/cmux.LICENSE) and [third-party notices](licenses/cmux.THIRD_PARTY_LICENSES.md). |
| [fayazara/macos-app-skills](https://github.com/fayazara/macos-app-skills) | The upstream [README license section](https://github.com/fayazara/macos-app-skills#license) declares MIT. No separate upstream LICENSE file was provided at retrieval; the [MIT terms](licenses/fayazara-macos-app-skills.MIT) are retained here with that attribution. |
| [avdlee/swiftui-agent-skill](https://github.com/avdlee/swiftui-agent-skill) | MIT; [upstream license](licenses/avdlee-swiftui-agent-skill.LICENSE). |
| [arjitj2/swiftui-design-principles](https://github.com/arjitj2/swiftui-design-principles) | Preserve the [bundled license](skills/swiftui-design-principles/LICENSE). |
| [wholiver/swiftui-design-skill](https://github.com/wholiver/swiftui-design-skill) | Preserve the [bundled license](skills/swiftui-design-skill/LICENSE). |

The repository-owned `macos-build`, `cmux-maestro-orchestrate`, and
`maestro-icon` skills are separate from these dependency copies.
