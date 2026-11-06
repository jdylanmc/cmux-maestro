# Agent interface and cosmetic preview

[↑ Self-reported moods](../self-reported-moods.md) | [Refusals →](refusals.md)

Native `maestro_mood({ "mood": "happy" })`; supported values are `happy`,
`celebrating`, `confused`, and `clear`. The installed adapter privately binds
the exact invoking session and generation. It accepts no target, text, sequence,
timestamp, or appearance argument. The equivalent controller interface is:

```sh
cmux-maestro-orchestrator mood --self --session-id "<current-session-uuid>" --mood happy
```

The command requires an existing exact managed binding, live provider ancestry,
sole session custody, and the appearance helper's side-effect-free native
`prove`. It checks again inside the existing control lock; no state enrollment,
event read, focus change, terminal input, process control or permission grant.
Lock contention refuses immediately. No queue or automatic retry.

Native/CLI success returns `ok`, `sessionId`, `mood`, `sequence` and `changed`.
It means the claim was stored or already current, never task completion or
display confirmation. Refusals use bounded reason codes; capacity, malformed
store, stale identity and rate limiting preserve the previous file.

## Explicit cosmetic preview

Only when the human requests a preview, call
`maestro_mood({ "mood": "preview" })` once. The equivalent CLI uses
`mood --self --session-id "<current-session-uuid>" --mood preview`.
This previews the existing expressions in order: Idle, Thinking, Working,
Delegating, Question, Needs permission, Confused, Content, Startled, Sad,
Compacting, Sleepy, Gone, Proud, Celebrating. Each slot is five seconds;
the request expires after 75 seconds. Late observations skip elapsed slots,
not replay or extend them. A reader must already have a valid baseline.

`maestro_mood({ "mood": "cancel-preview" })` (CLI `--mood cancel-preview`)
cancels only this exact session's preview and restores ordinary mood resolution,
including an eligible prior self-report. `clear` also cancels the preview and
withdraws the self-report. An ordinary report ends the preview. No other session,
custom duration, mood list, scheduler, heartbeat or repeated write is supported.
Starting an already-active preview is a no-op; explicit cancellation does not
refill the three-second allowance. Acceptance confirms storage, not display.

The pet shows a small corner play glyph that covers no face of the built-in
pets and adds no separate accessibility element. Its accessibility label and tooltip state
**Cosmetic preview; not session state** and its real current mood.
Question, permission, real failure and process death preempt immediately.
Urgent facts, lost observations or changed identity halt
that preview request in every pet view, including hover cards opened later,
rather than resuming it when those facts disappear.
An urgent fact that starts and ends while the sidebar is hidden is not
observed, so the rest of the 75-second window may play when it is shown again.
Cold reader starts, disconnects, mismatches and invalid data suppress playback.
Preview never writes or fabricates lifecycle, attention, history, custody,
acknowledgement or capacity. The existing single cosmetic display deadline
handles the slots and expiry. The controller performs one atomic write.
