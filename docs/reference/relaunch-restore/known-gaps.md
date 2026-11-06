# Known gaps

[↑ Relaunch restore](../relaunch-restore.md) | [← Sidebar rows](sidebar-rows.md) | [Live checks →](live-checks.md)

- If you also installed CMUX's Copilot hooks yourself (in `config.json` or another hook file), both sets run and CMUX receives each event twice. Remove your copy and keep Maestro's file, which setup maintains.
- CMUX's Copilot restore keeps `--name` and adds `--resume`. Copilot 1.0.98 refuses that pair. A session started with `--name` does not come back through CMUX's restore. Rename the session inside Copilot instead.
- Sessions launched through wrappers such as Agency are not covered.
- Launches made before this change have no binding and do not resume.
- A session started before the Maestro integration was installed enrolls only at its next extension join (`/clear`, `/resume`, or an extension reload you run). Maestro never triggers one.
- After `/clear` or an in-session `/resume`, the new session takes over the tab only when the previous session's end was recorded; otherwise it stays unmanaged with `provider-already-enrolled`. If the previous root still has live children, it releases the tab and keeps them: no row shows that run, its children appear as their own observed sessions, and the new root cannot close them. A later `/resume` of the released session in another tab refuses with `surface-mismatch`.
- Before its first prompt, a new or resumed session reports `awaiting-first-prompt` and its Maestro tools refuse.
- If a second tab resumes a session that is already managed, the first tab loses Maestro authority as soon as the second holds the session lock (`session-custody-lost`), and the second is refused. Neither is managed until one of them joins again (extension reload, `/resume`, or a relaunch) as the only holder.
- An unmanaged restored session can show the CMUX surface title (for example `Terminal`) until Maestro's observer hook binds it.
