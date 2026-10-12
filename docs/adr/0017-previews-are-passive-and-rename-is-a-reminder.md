# Previews are passive; rename is a reminder

A preview card never focuses, marks read, navigates, copies, or changes the Active window footer. Anything with a side effect is an explicit control. The CMUX extension SDK has no rename, command-palette, or keystroke action, so the workspace menu offers "Rename… (⇧⌘R)": it selects the workspace and shows a reminder of CMUX's own shortcut.

Why: hover must be safe. And Maestro cannot drive CMUX beyond the typed host actions the SDK exposes.

Rejected: synthetic keystrokes, a fake in-sidebar rename that diverges from CMUX.

Consequence: rename stays a two-step user action until CMUX adds an SDK action.
