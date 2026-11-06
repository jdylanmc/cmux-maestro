# Remove only the owned local preview

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Recovery commands and diagnostics](recovery-commands.md)

First, in the stable containing app, explicitly choose **Uninstall Native
Plugin…** and confirm the official CLI action. Restart/resume sessions that
still cache its hooks when convenient, then close the containing app and
deselect the preview sidebar. Only after those hooks no longer need its
helper, explicitly remove the installed preview:

```sh
python3 scripts/local-preview.py uninstall --cached-hooks-retired
```

This deregisters and removes only the receipt-owned stable app and backups.
The option is an operator assertion, not a scan of private CLI state. `recover` resumes an
interrupted removal. Ownership metadata and the lock
remain for safe future installs. Observation records, history/attention
preferences, containers, native plugin settings and source builds are retained.
No purge option exists. Neither removal nor update touches `maestro-cmux`,
legacy settings, hooks, sidebars, other apps or CMUX configuration.

Tests: [`test-local-preview.py`](../../../scripts/test-local-preview.py). [Install test inventory and limits](../../evidence/reference.md#remove-only-the-owned-local-preview).
