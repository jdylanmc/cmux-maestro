# Lazy preference observation (#169)

[↑ Behavioral parity and proof](../behavioral-parity.md)

Layout stays read-only until an explicit action. When the target is absent, its
file presenter watches the nearest existing container. Changes to the
presenter's own item, including directory-content and attribute notifications,
invalidate the target through the existing refresh path. Unrelated subitem
events stay filtered; no polling, eager directory creation or new writer is
added. Each accepted notification schedules one byte-bounded coordinated read,
and equal values publish no new store value.

`SidebarLayoutTests.lazyPresenterOwnItemChangesRefreshWithoutCreatingTarget`
drives the actual presenter through `NSFilePresenter`, with an absent nested
target and unrelated-event controls.
`presenterOwnItemChangesRetainCoordinatedReadAndNoticeSemantics` checks
repeated unchanged reads, file-byte preservation and explicit malformed-file
notices. The original two-process lazy-layout convergence test keeps its
ten-second deadline and observation, layout, history and attention assertions.
These deterministic callback regressions establish the documented invalidation
path, not the exclusive cause of the earlier hosted convergence failure or
installed-runtime acceptance.
