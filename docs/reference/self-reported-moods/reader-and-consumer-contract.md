# Reader and consumer contract, and local validation

Part of [Self-reported moods](../self-reported-moods.md). Previous page is [Store version 1](store-version-1.md).

`SidebarOrchestrationReader.Cached` owns the bounded mood cache. Its first
valid read baselines all existing sequences without displaying their claims.
Verified absence baselines an empty store. Invalid input cannot initialize it.
Only a newly observed higher sequence matching all six fields of a current
validated orchestration node becomes eligible. The reader retains high-water
marks for at most 1,024 nodes; exhaustion disables the overlay, never evicts.
Same-sequence mutation, rollback, tombstone, missing record, invalid file or
binding mismatch cannot resurrect a report. A new reader intentionally loses
eligibility, not sequencing safety.

Host disconnects, unpaired windows, and connection rebinds revoke eligibility
in the retained reader and require a new valid baseline before displaying later
reports. The reset runs after any obsolete in-flight read finishes and before
the replacement read. High-water marks and their no-eviction capacity survive
the boundary; unchanged claims and reports written while disconnected cannot
replay. Ordinary topology refreshes and visibility changes do not reset eligibility.

The session node exposes `selfReportedMood: SidebarMoodObservation.Mood?` and
`selfReportedMoodSequence: Int?`, plus optional `moodPreview` playback metadata.
The report sequence remains separate from preview-only changes.
`clear` is never exposed as a displayed mood;
the sequence remains available for withdrawal/cold-start suppression.
`Mood.selfReportLabel` provides localized authored-basis text for the later
accessibility/tooltip consumer. `snapshot.moodsUnavailable` is a bounded
cosmetic diagnostic, not observation loss. These fields are excluded from
`current.json` encoding and never change completeness, work state, attention,
acknowledgement or resource counts.

#382 owns priority/hold integration and must preserve Question, Needs permission,
Sad and Gone over a self-report. #383 owns art. This delivery proves neither
visual priority nor hosted ExtensionKit behavior. Normal explicit production
setup distributes the adapter. Existing sessions are not reloaded by this change.

## Local validation paths

The Python orchestrator and Node adapter tests accept `MAESTRO_TEST_ROOT` for
their short socket fixture directories. Use an existing, owned directory with
enough Unix socket path headroom; `TMPDIR` separately controls ordinary fixture
files. Neither setting changes controller limits or redirects production data.
The failed-Git fixture carries an unresolvable `.git` marker so a
repository-local `TMPDIR` cannot turn it into the enclosing delivery repository.
