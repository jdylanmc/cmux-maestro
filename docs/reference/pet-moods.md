# Pet moods

The pet uses the exact session's sanitized presentation inputs, not its status
icon or terminal text. Missing facts stay unknown. A mood changes only art and
its accessibility description/tooltip; status, attention, acknowledgement,
history and lifecycle remain independent.

First matching rule wins:

1. Pending permission → **Needs permission**.
2. Pending answer → **Question**.
3. Explicit dead liveness → **Gone**, not success or failure.
4. Observation unavailable → neutral **Idle** art with an unavailable basis.
5. Failed root or relevant internal task with an unacknowledged error → **Sad**.
6. Cancelled with `user_abort` → **Startled**; other/unknown reasons → neutral art.
7. Quota/authorization, model trouble, or three consecutive tool failures →
   **Confused**. This never relabels a failed lifecycle as recoverable.
8. Eligible exact-generation self-report → **Proud** (`happy`), **Celebrating**,
   or **Confused**. The description includes “Self-reported: happy”, etc.
9. Active compaction → **Compacting**.
10. Working internal subagent task → **Delegating**. Managed child sessions,
    shells and skills do not count.
11. Executing tool → **Working**.
12. Open primary turn → **Thinking**.
13. Unacknowledged Turn finished at least 60 seconds old → **Sleepy**; otherwise,
    positively observed clean turn → **Content**, never proof of a good outcome.
14. Otherwise → **Idle**, with an explicit observed-idle or neutral basis.

`SidebarPetMood` owns the three tuning constants: `minimumMoodHold` (3 seconds),
`sleepyAfter` (60 seconds), and `confusedToolFailureThreshold` (3).

Each visible pet owns a cancellable display deadline through
`SidebarPetMoodDisplay`. A shown expression holds for the minimum duration, then
snaps to the *current* candidate without requiring another event. Ended
intermediate moods are skipped. Same-mood observations do not rearm the hold.
Question, Needs permission, Sad and Gone preempt immediately. Exact placement,
session, managed node/run/generation or bound-process changes reset the hold.
Disappearance cancels the deadline; nothing is persisted.

Sleepy uses the existing unacknowledged Turn finished timestamp, not process idle
time. Acknowledgement removes that candidate; the ordinary art hold still applies.
It does not expire or acknowledge an outcome. One deadline handles both hold
catch-up and Sleepy, with an injectable clock for deterministic tests.

Reduce Motion displays frame zero of the same selected mood and obeys the same
precedence and hold. Held art is described separately from the current mood/basis.
Footer status and attention badges never wait for the art. Hover previews remain
passive. Sheet selection uses the existing mood playback API, including each
legacy fallback's own loop length. Bundled art updates are separate (#383);
legacy fallback rows need not be visually distinct.

See [self-reported moods](self-reported-moods.md) for identity validation,
cold-start suppression and malformed-store safeguards, and
[pets and icons](pets-and-icons.md) for the atlas contract.
