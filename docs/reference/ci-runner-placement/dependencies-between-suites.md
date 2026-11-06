# Dependencies between suites

[↑ CI runner placement](../ci-runner-placement.md) | [Portability proof →](portability-proof.md)

- `validate-native` runs only `./scripts/test.sh`. It fetches the SDK and
  builds in its own derived data. It reads no other job's output (#196).
- Every `validate-contracts` suite writes only under its own `.build`
  subdirectory or a fresh temporary directory. No job reads another job's
  workspace.
- `guide-ui-consumer-probe` fetches its own SDK copy and needs nothing else.
- `validate-portable` reads only tracked files. It writes only temporary Git
  fixtures, which the tests remove, and uploads no artifact.
- Jobs share no cache, artifact or output path. Each artifact uploads from the
  job that produces it.
- No new dependency is added.
