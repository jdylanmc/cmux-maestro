# Deep-outline fixture readiness

Part of [behavioral parity and proof](../behavioral-parity.md).

Focus-layout fixtures own **available content width**, not AppKit's preferred
scroller style. A test-host-only modifier applies `scrollIndicators(.never)`
to the unchanged production sidebar/tree and reserves a constant trailing
gutter derived from the public `NSScrollView.contentSize` API, separately for
overlay and legacy budgets. No gutter size is hard-coded and no content width
is frozen: resizing the owned window still changes the viewport and title.
These are **overlay/legacy-equivalent available-width inputs**, not native
indicator appearance or identical row-geometry claims.

The stronger policy is intentional:
[`.hidden` can still show macOS indicators when a mouse is connected](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/hidden).
[`.never` overrides that policy](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/never).
Before immutable baseline capture, preparation requires absent native scrollers,
no native width gutter, a visible deep title, document/clip width agreement and
matching geometry samples. It does not claim native quiescence or pin style:
[AppKit can later update style and retile](https://developer.apple.com/documentation/appkit/nsscroller/preferredscrollerstyle).
Cold-start evidence observed that update on both fixed-budget fixtures without
changing their title/viewport frames, alongside an unmodified native control
whose width changed. A one-time explicit style assignment alone failed that
stress. The matching hosted width delta still does not establish its trigger.

`deepOutlineFixedViewportSurvivesNativeStyleChanges` compares each budget's
available viewport against a separate, real-native production render, then
requires exact title/viewport equality through both native style-transition
directions. Focus and no-focus tests run both budgets; focus retains both
densities and appearances, the 124-point minimum, height/depth caps and 20 ms
effect interval. The real-window-width negative control also runs both budgets,
requires the full 26-point viewport loss and still rejects changed title frames.

`nativeEightLevelOutlineRetainsMinimumTitleWidthAt280` separately protects the
actual native depth-eight title at a 280-point host: at least 124 points wide,
at most 70 points high, in both densities, light/dark appearances and both
native scroller styles. It verifies the requested style and visible native
geometry before each static measurement, without the fixed-input inset or a
subsequent timed equality check. This absolute guard is necessary because the
equivalent-width fixture's inset changes indentation and gives its legacy
title two extra points. That fixture alone cannot protect the native minimum.
Style assignment is not treated as a pin against later AppKit updates.

`deepOutlineLateNativeStyleChangeInvalidatesSampledBaseline` exercises both
overlay-to-legacy and legacy-to-overlay transitions through the public setter,
in run-owned offscreen fixtures without focus. It requires opposite viewport
width directions, equal title/viewport width deltas and an unchanged title
height. The original exact frame comparison rejects both changes. This control
and all ordinary full production renders remain outside the fixed-input modifier.
Neither layer restores geometry after baseline. Global preferences, production
layout and AppKit test gates remain unchanged. Fixed-input focus coverage and
actual native composition/transition coverage are separate layers; neither
substitutes for the other.
