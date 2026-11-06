# Lazy preference observation (#169)

Part of [behavioral parity and proof](../behavioral-parity.md).

Layout remains read-only until an explicit action. Its file presenter watches
the nearest existing container when the target is absent. Changes to that
presenter's own item invalidate the target through the existing refresh path,
including directory-content and attribute notifications. Unrelated subitem
events remain filtered; no polling, eager directory creation or new writer is
added. Each accepted notification schedules one existing byte-bounded coordinated
read. Equal values do not publish a new store value.

`SidebarLayoutTests.lazyPresenterOwnItemChangesRefreshWithoutCreatingTarget`
uses the actual presenter through `NSFilePresenter`, with an absent nested
target and unrelated-event controls.
`presenterOwnItemChangesRetainCoordinatedReadAndNoticeSemantics` checks repeated
unchanged reads, file-byte preservation and explicit malformed-file notices.
The original two-process lazy-layout convergence test and its ten-second
deadline, observation, layout/history/attention assertions remain unchanged.
These deterministic callback regressions establish the documented invalidation
path, not the exclusive cause of the prior hosted convergence failure or
installed-runtime acceptance.
