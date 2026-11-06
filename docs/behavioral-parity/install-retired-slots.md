# Alpha installation: retired slots and native publication

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Coordinated alpha installation](alpha-installation.md) | [Alpha installation: integration checkpoint →](install-integration-checkpoint.md)

A changed install stages and verifies the new bridge before reclaiming the old
retired slot. A `reclaiming` transaction journals exact digest/node-based
cleanup while owned registrations are withdrawn and owned processes idle.
Failure restores the working app/integration and required previous backup; the
verified new candidate can stay retired to finish old-app relaunch and
checkpoint release. Partially copied candidates keep the original unverified
staging cleanup rules. On success, old previous becomes retired only after
bridge work finishes. The durable `committed` boundary separates
release/retention cleanup from reversible failures.

Native publication uses exact app/extension state. A correct registration is
verified without a second forced registration, and an absent pair can be published.
Verified transaction-owned app-present/extension-absent publication reuses the
per-component registration primitive to add only the missing extension, with
source/identity preflight and fresh pair/readback checks. A now-complete pair
is left alone, and a changed unsupported pair refuses. Extension-present/app-absent
never authorizes a forced app registration while a native view may be hosted.
Outside the transaction, partial ambiguity refuses. Staging cleanup keeps its
transaction until the restored registration verifies. None of this is an
atomic macOS service acknowledgment.

Restoration confirms the retained candidate's registration is absent before
publishing the old app. No retirement mutation follows final publication. Tests
cover repeated failure bounds, old apps without bridge capability, original
running/hidden state, interrupted optional deletion, release and receipt
writes, alias/tamper/missing slots, first-install absence and explicit
uninstall. They do not establish asynchronous service drain or that stock CMUX
saw an identity disappear.

Ordinary install runs an exact production-ID/public-point sibling preflight
before staging or provider effects and revalidates before native withdrawal.
Only receipt-owned paths and an explicitly authorized, verified
current-checkout development source may be retired. External eligible paths
and unknown/debugger elections fail with a concrete error, without adoption.
Ignored or superseded records, other points/identifiers and unrelated provider
hooks remain unchanged. The historical sibling-recovery proposal still needs
separate production consent.
