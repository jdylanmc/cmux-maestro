# Recorded launch policy, deny wins

Child launches use the parent's recorded policy: mode, bounded allow rules, deny rules. Denies win, descendants never widen inherited permissions, explicit worker YOLO refuses, and coordinator YOLO needs explicit human approval. The record is history, not proof of live permissions.

Why: the Copilot SDK offers no atomic, verified view of live permissions. Pretending to inherit them would be a guess.

Rejected: a live permission snapshot, mutating permissions after launch, granting shell or wildcard rules from tool visibility or prompt text.

Consequence: `/permissions` or `COPILOT_ALLOW_ALL` can make a record stale. Flags are policy, not an OS sandbox.
