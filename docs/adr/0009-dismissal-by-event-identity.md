# Dismissal by event identity

A dismissed outcome is keyed by session UUID, child ID, and the accepted terminal-event UUID. Fresh lifecycle identities reopen work. Labels, paths, source text, and wall-clock timestamps never key a dismissal. Finished and failed outcomes have no retention clock.

Why: names repeat, clocks lie, sessions move and reload. Event identity survives all three.

Rejected: matching by label or path, time-based expiry of outcomes.

Consequence: dismissal needs tombstones and identity tracking. History presentation limits stay separate from ingestion limits.
