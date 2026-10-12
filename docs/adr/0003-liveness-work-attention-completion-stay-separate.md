# Liveness, work, attention, and completion stay separate

Process liveness, work state, attention, and completion are four independent facts. Maestro never infers success, progress, hang, or completion from process presence, idle time, file timestamps, terminal output, launch acceptance, or history expiry. Turn finished means one matching `assistant.turn_end`, nothing more.

Why: each signal lies on its own. A live process can be stuck, an exited process can have succeeded, a quiet session can be thinking.

Rejected: stall detection, exit-code success, "quiet means done".

Consequence: the UI shows more unknown and partial states, and says so.
