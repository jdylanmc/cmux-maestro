# Hover components and detail labels

Part of [sidebar presentation](../sidebar-presentation.md). Previous page is [Hover previews and copy](hover-previews.md). Next page is [Footer and session previews](footer.md).

`SidebarHoverRegion` and `SidebarHoverCard` accept presentation data, independent
of sessions, navigation, preferences, and the bottom details. Passive panels
cannot become key/main windows. Only an explicit Preview action enables keyboard
interaction. Closing that preview restores its original responder when appropriate.
Right-click a row, use its transient overflow, or press **Shift-F10** on its title
for the same native grouped menu. Opening it is passive. **Preview details** is
also passive. **Open details** keeps the existing explicit mark-read behavior.
Overflow occupies a stable 24-point slot with a 2-point gap. Revealing it
never changes the title's width or truncation. Hidden controls are not keyboard stops.
Managed inspection requests retain the captured node, run, generation, session,
workspace and surface. A changed subject shows **Details no longer available**
without inspecting or marking the replacement read.
Icon-direct right-click still opens the compact icon picker, not the row menu.
Menu icon requests keep their exact identity. A replacement target shows
**Icon target changed**, never applies the old request to a new session.
Preview Close/Copy controls have an explicit native Tab order, independent of
system-wide keyboard-navigation preferences.
Hosted keyboard regression uses the production sidebar's automatically
constructed row key loop, including any intervening native controls. It requires
an unlocked graphical login so its
test-created windows can exchange key focus. It does not substitute
simulated key ownership when WindowServer denies focus.
AppKit rendering/interaction cases and the validation-host no-window assertion
share a test-only asynchronous gate across suites, held through fixture cleanup.
Other tests stay parallel. Motion captures fix and assert the logical viewport
before comparing exact native pixels. Static controls keep a zero-change requirement.
Activity-only children offer **Open parent chat**, never an independent surface.
**Choose pet…** opens the pet picker for an exact agent session. Unsupported pet
(activity-only children, status-only sessions), tag, backlog, placement and exit
actions show disabled reasons.
Menus add no capability or lifecycle authority.
Previewing never changes the **Active window** footer. Footer follows only the
current window's selected workspace and uniquely focused native surface.
Disconnected, redacted, missing or ambiguous focus clears the previous subject.
Ordinary terminals and browsers show native context without agent fields or a pet.
An agent on a terminal requires one fresh, live, exact observed session. Managed
labels and Git context also require current, uniquely bound managed
evidence. Positively ended observations do not compete with a replacement live
session. Unknown or ambiguous owners still prevent a unique current identity.
Reused surfaces, stale membership and matching titles never establish
ownership. Existing observation expiry updates the footer without a new timer.
