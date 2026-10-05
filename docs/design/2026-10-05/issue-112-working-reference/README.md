# Issue #112 working HTML reference

This runnable copy is derived from the frozen September 29 reference ZIP
(`sidebar-refinement-target-20260929.zip`, SHA-256
`4b54c765a550f3081fc88ccd57a6cbfa701d83bb59ee8e868ec122f3b5d8093a`).
The archived ZIP, its manifest, review gallery, capture hashes, and approval
remain unchanged. This copy only corrects the demonstrated S53-S55 reference
transitions; it is not a new visual approval or proof of native behavior.

Run `python3 prototype/serve.py` from this directory, then from `prototype/`:

```sh
npm ci
npm run test:copy
npm run test:issue-112
npm run test:stress
```

The copy suite retains the archived raw-value, reveal, clipboard-isolation,
error/retry, keyboard, and viewport assertions. `verify-issue-112.cjs` adds
subject-scroll, delayed pointer dismissal, and preview-origin dialog return
checks tied to S53-S55. All browser clipboard writes use an in-page stub; the
reference remains synthetic and performs no host/session operation.

Only the copy, stress, and issue-specific runners are duplicated into this
working folder. The other September 29 verification scripts remain unchanged
inside the frozen ZIP.
