# Alpha installation: retired slots and native publication

Part of [behavioral parity and proof](../behavioral-parity.md). Previous page is [coordinated alpha installation](alpha-installation.md). Next page is [Alpha installation: integration checkpoint](install-integration-checkpoint.md).

For a changed install, the new bridge is staged and verified before the old
retired slot is reclaimed. A `reclaiming` transaction journals exact
digest/node-based cleanup while owned registrations are withdrawn and owned
processes are idle. Failure restores the working app/integration and required
previous backup; the new verified candidate can remain retired to complete old
app relaunch and checkpoint release. Partially copied candidates retain the
original unverified staging cleanup rules. At success, old previous becomes
retired only after bridge work finishes. The durable `committed` boundary
distinguishes release/retention cleanup from reversible failures.

Native publication uses exact app/extension state: already-correct registration
is verified without a second forced registration, and an absent pair can be
published.
Verified transaction-owned app-present/extension-absent publication reuses the
per-component registration primitive to add only the missing extension, with
source/identity preflight and fresh pair/readback checks. A now-complete pair is
left alone. A changed unsupported pair refuses. Extension-present/app-absent
never authorizes a forced app registration while a native view may be hosted.
Outside the transaction, partial ambiguity still refuses. Staging cleanup keeps
its transaction until the restored registration verifies. These checks are not
an atomic macOS service acknowledgment. Restoration establishes the retained candidate's
registration absence before publishing the old app. No retirement mutation
follows final publication. Tests cover repeated failure bounds, old apps lacking
bridge capability, original running/hidden state, interrupted optional deletion,
release and receipt writes, alias/tamper/missing slots, first-install absence and
explicit uninstall. These fixtures do not establish asynchronous service drain
or that stock CMUX observed an identity disappearance.

Exact production-ID/public-point sibling preflight precedes staging/provider
effects on ordinary install and revalidates before native withdrawal. Only
receipt-owned paths and an explicitly authorized, verified current-checkout
development source may be retired. External eligible paths and unknown/debugger
elections produce a concrete error without adoption; ignored/superseded records,
other points/identifiers and unrelated provider hooks remain unchanged. The
historical sibling-recovery proposal still needs separate production consent.
