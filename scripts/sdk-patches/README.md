# Pinned SDK patches

`scripts/fetch-sdk.sh` applies every `*.patch` here, in name order, to the
pinned `CmuxExtensionKit` with `patch -p1 -F 0` (no fuzz) before installing it.
A patch that no longer applies exactly fails the fetch. The stamp
`vendor/CmuxExtensionKit/.cmux-commit` records the pinned commit and the
SHA-256 of the concatenated patches, so editing a patch refetches the SDK.

| Patch | Why | Decision |
| --- | --- | --- |
| `0001-per-window-sidebar-scenes.patch` | One transport per accepted connection and a per-scene `CmuxSidebarScene` in the SwiftUI environment, so each CMUX window's sidebar binds only to its own connection. | ADR 0023 |

To change a patch, edit a freshly fetched `vendor/CmuxExtensionKit`, then
regenerate the patch against a pristine extract of the same commit with
`diff -ruN a b` from the `Sources/` parents. Strip timestamps; use
`/dev/null` for new files. Never commit `vendor/`.

Drop a patch when the pinned commit contains an equivalent upstream change.
