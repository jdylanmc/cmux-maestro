# Surface directory comes from the CMUX report only

Path labels show the directory CMUX reports for the exact surface, written with `~` for the user's home, with lexical normalization only. No filesystem probe, no symlink resolution, no `effectivePanelDirectory` fallback, no borrowing from a replacement session. A report has no age; Maestro never invents one.

Why: provenance. A path from another source reads as fact when it is a guess.

Rejected: agent-process CWD, last-tool directory, filesystem resolution.

Consequence: missing or denied paths stay explicit. Git worktree labels are separate evidence, never a directory fallback.
