# Mood rules

Part of [Pet moods](../pet-moods.md). Next page is [Timing, preview and motion](timing-preview-and-motion.md).

First matching rule wins:

1. Pending permission → **Needs permission**.
2. Pending answer → **Question**.
3. Explicit dead liveness → **Gone**, not success or failure.
4. Observation unavailable → neutral **Idle** art with an unavailable basis.
5. Failed root or relevant internal task with an unacknowledged error → **Sad**.
6. Cancelled with `user_abort` → **Startled**. Other/unknown reasons → neutral art.
7. Quota/authorization, model trouble, or three consecutive tool failures →
   **Confused**. This never relabels a failed lifecycle as recoverable.
8. Eligible exact-generation self-report → **Proud** (`happy`), **Celebrating**,
   or **Confused**. The description includes “Self-reported: happy”, etc.
9. Active compaction → **Compacting**.
10. Working internal subagent task → **Delegating**. Managed child sessions,
    shells and skills do not count.
11. Executing tool → **Working**.
12. Open primary turn → **Thinking**.
13. Unacknowledged Turn finished older than 60 seconds → **Sleepy**; otherwise,
    positively observed clean turn → **Content**, never proof of a good outcome.
14. Otherwise → **Idle**, with an explicit observed-idle or neutral basis.
