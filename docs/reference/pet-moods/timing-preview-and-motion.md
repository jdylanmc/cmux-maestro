# Timing, preview and motion

Part of [Pet moods](../pet-moods.md). Previous page is [Mood rules](mood-rules.md).

`SidebarPetMood` owns the three tuning constants: `minimumMoodHold` (3 seconds),
`sleepyAfter` (60 seconds), and `confusedToolFailureThreshold` (3).

Each visible pet owns a cancellable display deadline through
`SidebarPetMoodDisplay`. A shown expression holds for the minimum duration, then
snaps to the *current* candidate without requiring another event. Ended
intermediate moods are skipped. Same-mood observations do not rearm the hold.
Question, Needs permission, Sad and Gone preempt immediately. Exact placement,
session, managed node/run/generation or bound-process changes reset the hold.
Disappearance cancels the deadline. Nothing is persisted.

Sleepy uses the existing unacknowledged Turn finished timestamp, not process idle
time. Acknowledgement removes that candidate. The ordinary art hold still applies.
It does not expire or acknowledge an outcome. One deadline handles hold
catch-up, Sleepy and explicit cosmetic preview slots/expiry, with an injectable
clock for deterministic tests.

A human-requested `maestro_mood({"mood":"preview"})` temporarily shows all fifteen
expressions at five seconds each, without altering the ordinary resolver.
The real current mood remains available in the description. Every preview pet
shows a small play glyph in the art's physical top-left corner, without
changing the pet frame; the glyph is hidden from accessibility, and the pet's
label and help carry the localized cosmetic basis. Urgent facts, observation
loss and identity changes immediately halt that request in every pet view
showing the session, including views created later.
An urgent fact that starts and ends while the sidebar is hidden is not
observed, so the rest of the 75-second window may play when it is shown again.
`cancel-preview` and the 75-second expiry snap to ordinary resolution without
the three-second art hold. The request's fixed timeline never restarts on
duplicate observations or late view creation.

Reduce Motion displays frame zero of the same selected mood and obeys the same
precedence and hold. Held art is described separately from the current mood/basis.
Footer status and attention badges never wait for the art. Hover previews remain
passive. Sheet selection uses the existing mood playback API, including each
legacy fallback's own loop length. Bundled art updates are separate (#383);
legacy fallback rows need not be visually distinct.

See [self-reported moods](../self-reported-moods.md) for identity validation,
cold-start suppression and malformed-store safeguards, and
[pets and icons](../pets-and-icons.md) for the atlas contract.
