# Refresh host focus while the sidebar is visible

Owner decision: a bounded Maestro-side workaround for a CMUX host gap. CMUX
does not push a sidebar snapshot when only tab, pane or workspace focus
changes. The focus bar and **Active window** footer stayed on the previous
surface until an unrelated change arrived.

Evidence (CMUX at the pinned commit `ae7fbce99f98c98df5ccf915e548dd080d33cfa8`;
the host view is unchanged on `main` as of 2026-11-05):

- `Sources/CMUXInstalledExtensionSidebarHostView.swift:354-357` pushes only when
  `snapshotUpdateToken` changes. `:1458` also pushes after an accepted extension
  action, so clicking a Maestro row did update focus.
- `Sources/ContentView.swift:12546-12548` (`refreshExtensionSidebarSnapshot`) is
  the only token bump. Its callers observe titles, panel sets, metadata and
  provider changes (`Sources/WorkspaceSidebarObservation.swift:209-254`,
  `:272-304`), never `focusedPanelId` or `selectedTabId`.
- A focus change re-titles a workspace only without a custom title, so a
  custom-titled workspace never pushed on a tab click.
- `isFocused` is computed when a snapshot is built
  (`Sources/ContentView.swift:12744`), so a pulled snapshot is correct.

The SDK has no focus event. It does let an extension pull its own snapshot:
`CmuxSidebarHost.refresh()` → `requestSidebarSnapshot`.

Decision:

- Each window's `SidebarWindowBinding` (ADR 0023) owns one
  `SidebarHostFocusRefresh`. It calls its own bound connection's
  `host.refresh()` every 500 ms (100 ms timer tolerance). It runs only while
  that window's sidebar view is mounted (SwiftUI `onAppear` to `onDisappear`),
  the connection is connected, and CMUX (or the extension process) is the
  active app. Otherwise it stops, with no timer. Mounted is not on screen:
  minimising or covering the window does not stop it while CMUX stays
  active. Hiding the sidebar does, because CMUX unmounts it and drops the
  connection.
- Becoming mounted, active or connected refreshes at once, unless a request is
  still unanswered. At most one request is outstanding, also across a stop and
  restart (for example switching away from CMUX and back). Any publication from
  the connection answers it. Three ticks skip an unanswered request and the
  fourth re-sends it. A lost reply blocks for about 2 s. Losing the connection
  abandons it, so reconnecting asks at once.
- A failed pull (the SDK reports `.error` for a missing payload, a host error or
  a decode failure) shows the existing degraded state and stops refreshing until
  the host publishes again: a push, an accepted action or a reconnection. It
  does not retry while degraded. Every other connection error already behaves
  this way, and retrying would ask a failing host twice a second indefinitely.
- Unpaired, waiting and disconnected states never refresh. No window refreshes
  another window's connection.
- An unchanged pull costs no re-apply. CMUX's snapshot cache keeps the
  previous sequence when content is identical
  (`CMUXInstalledExtensionSidebarHostView.swift:161-173`). The binding's existing
  `snapshot != lastSnapshot` check therefore drops the pull before any model
  update, SwiftUI invalidation, or Copilot or orchestration re-projection.
  Scope filtering runs after the cache (`:1362-1372`), so a change only to a
  field Maestro cannot read (for example pull request URLs) can still bump the
  sequence. That cost already applies to pushes, and a pull does not repeat
  it: each such change bumps the cache once. No sequence-ignoring guard was
  added, because existing behaviour and tests treat a newer sequence as a new
  delivery.
- App activation is a power gate only. It is not identity, window pairing or
  focus evidence (ADR 0002). The refresh only reads. It never moves CMUX focus,
  sends input, or touches CMUX unread counts. A refreshed snapshot follows the
  same rules as a pushed one. It acknowledges nothing by itself. A real change
  in host focus is handled as a pushed change would be, only sooner.

Why not reuse an existing tick: Copilot and orchestration polling wake on file
events with a 2-second fallback. They run only when sessions can be read, so
they are neither periodic nor fast enough.

Cost, measured on 2026-11-05 with a synthetic window of 8 workspaces,
24 surfaces and 6 Copilot sessions (5.6 KB payload). The Debug test build
(`-Onone`) gives upper bounds:

| Work per tick (median of 3 runs) | Time | Allocations |
| --- | --- | --- |
| Extension main thread: both SDK publications of an unchanged pull | 6.4 µs | 0 |
| Extension XPC queue: decoding the snapshot | 69 µs | 471 |
| Host main thread, encoding only | 59 µs | 317 |
| For comparison: applying a real focus change | 57 µs | 779 |

A temporary micro-benchmark measured these numbers. It counted main-thread
allocations through `malloc_logger`. It is not committed, because repository
tests do not read wall clocks. The committed tests check the same no-work
behaviour by counting state changes.

CMUX also builds the snapshot on its main thread. Per workspace, it walks
panels, Git branches, pull requests and directories (`ContentView.swift:12711-12749`,
`:12929-12965`). For a window this size, that is estimated at a few hundred
microseconds. At 2 Hz, that is about 1 ms of CPU per second per visible
window across both processes (about 0.1% of one core). This is well inside
the 2% idle-CPU target in
[reader lifecycle](../reference/reader-lifecycle-and-retention.md). Hidden
sidebars and an inactive CMUX cost nothing. Added focus latency averages
250 ms and is at most about 600 ms. A 1-second cadence would halve the cost
but double the visible lag for little gain.

Removal: delete `SidebarHostFocusRefresh` and its wiring when CMUX pushes a
snapshot on focus and selection changes. For example, it could bump
`snapshotUpdateToken` on `selectedTabId` and each workspace's `focusedPanelId`.
Then revert the related documentation and changelog notes.

Consequences: CMUX builds about two extra snapshots per second for each visible,
active sidebar. Live hosted behaviour still needs human checking. That covers
the activation signal in the sandboxed extension process. Tests cover the
activation rule and the mount lifecycle with injected notifications and an
offscreen hosting view, not the hosted process. A minimised window keeps
refreshing while CMUX is active, at the same small per-window cost. The
2% idle target is measured on the extension process only, so a live check
should also sample CMUX's process, which builds the snapshots.

Reference: [host focus refresh](../reference/sidebar/refresh-cost.md#host-focus-refresh).
