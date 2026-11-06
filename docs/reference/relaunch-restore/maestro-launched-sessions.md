# Maestro-launched sessions

Part of [relaunch restore](../relaunch-restore.md). Previous page is [After a born-managed resume](after-a-born-managed-resume.md). Next page is [Resume command checks](resume-command-checks.md).

Children from `maestro_spawn`, and coordinators from `launch-coordinator`, do not use CMUX's own restore. The owner approved the binding for `launch-coordinator` roots too: they carry recorded flags like children. Their launch sets `CMUX_COPILOT_HOOKS_DISABLED=1`, so CMUX's hooks never record them. CMUX's restore drops launch flags, which could drop deny rules or the parent link.

Instead, each launch attaches a resume binding to its exact surface:

```text
cmux surface resume set --workspace <workspace> --surface <surface> --cwd <dir> \
  --kind agent --checkpoint <session> -- <controller> resume <session>
```

Only launches with Maestro messaging get a binding (delivery-proof fixture launches do not). If the session already ended with `/exit` before the binding landed, Maestro clears it at once. Archiving a run clears its launches' bindings and removes every generation's launch script. A resumed `launch-coordinator` root keeps its launch receipt's token for the owner commands `status`, `focus`, and `archive` only; each resumed provider gets its own token, and every other command needs it. The binding holds identifiers only. It holds no token, prompt, or temporary path. `<controller>` is the installed `~/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator`. It runs through its own `#!/usr/bin/env python3`, so the binding and its approved prefix survive Python and app upgrades. The session ID is the only varying argument, so one approval of `<controller> resume` covers every launch. The launch receipt reports `resumeBinding: "set"` or `"unavailable"`.

When the session ends by `/exit` (a Copilot `SessionEnd` with no `SIGHUP` before it; see [Born-managed roots](born-managed-roots.md)), Maestro's native extension records the end for that generation and clears that surface's binding with `cmux surface resume clear`, like CMUX does for its own records. It sends only identifiers and reads nothing from the hook input. If the clear fails, the binding stays, but the resume still refuses a user-ended generation. A quit, hangup, or signal is not trusted as an exit. The extension is Maestro's own SessionEnd observer: `CMUX_COPILOT_HOOKS_DISABLED` silences only CMUX's hooks, never Maestro's extension or its identity hook. The resume refuses when the Maestro integration that carries this observer is not installed. An exit during the session's first moments is held until its provider is observed, then recorded. A quit or crash records no end, so the session resumes at the next relaunch.
