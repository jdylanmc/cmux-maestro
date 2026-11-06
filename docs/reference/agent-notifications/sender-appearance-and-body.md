# Sender appearance and body

[↑ Agent notifications](../agent-notifications.md) | [Priority, permission and mute →](priority-permission-and-mute.md)

Communication notifications show the sender's selected sidebar glyph/color at
the leading edge, with the system-owned small app-icon badge. The app badge is
not manually composited; its light/dark behavior follows OS icon style and the
separately supplied application artwork. No pet or right-hand attachment.
Human per-session icon overrides and reset-to-default precede the agent's
authored choice. Glyphs use the existing pinned Nerd Font catalog and exact
appearance record. Custom colors share the sidebar's sRGB parser/contrast outline.
Unreadable preferences or unavailable glyphs refuse, rather than changing the
human's selected identity.

The system-visible sender title is the localized **Maestro agent**. No session
filename, inferred role or work-state subtitle is supplied. Public content title
and subtitle remain empty. Communication metadata supplies the sender title.
Account and conversation handles still contain the exact verified session UUID.

The body is shortened to 140 characters including an ellipsis. Control and
format characters are stripped. Input is bounded before decoding/processing.
The native/controller boundary conservatively counts Unicode code points;
Swift presentation counts grapheme clusters. Secrets must not be supplied:
Maestro retains no message text, but macOS stores delivered notification content
and Siri receives incoming communication donations containing the authored
message, selected avatar and app-specific sender/conversation identity. No
Contacts lookup/write, phone/email association or outgoing interaction is added.
Siri may use donations for suggestions. A completed donation may persist even
if a later identity check or notification submission fails; no automatic retry
or broad cleanup is performed.
