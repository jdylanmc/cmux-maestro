# Atomic app replacement

Update and rollback exchange the new app with the live destination through `renamex_np(RENAME_SWAP)`. First install uses an exclusive rename. Filesystems without it fail closed. At most one verified previous app and one inactive retired app stay after completion.

Why: a non-atomic replace leaves a window with no app, which breaks a running host.

Rejected: copy-then-delete fallback, a non-atomic path on unsupported filesystems.

Consequence: install only works on filesystems that support the swap.
