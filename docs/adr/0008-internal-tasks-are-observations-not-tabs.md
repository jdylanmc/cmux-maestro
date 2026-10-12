# Internal tasks are observations, not tabs

Provider sub-agents appear as compact rows under their exact owning session. Real terminal-backed child agents keep their native tab identity. Unmatched observations never attach to the current managed chat, and duplicates never count as extra agents. Finished tasks hide until the workspace eye is on; failed tasks stay until dismissed.

Why: one session can run dozens of sub-agents. Tabs would inflate agent counts and invent ownership.

Rejected: a tab per task, attaching orphans to the nearest chat.

Consequence: tasks need their own ancestry, counting, and retention rules.
