# Launch: native-child permissions

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Workspace capacity](launch-workspace-capacity.md) | [Launch: model selection →](launch-model-selection.md)

Prospective native-child permission regressions exercise explicit recorded
parent mode/allow/deny inheritance, deny-only additions, explicit list/false
narrowing, coordinator-only broad requests and contradictory-intent refusal.
Finite narrowing under recorded YOLO does not need redundant explicit parent allow strings: empty and redundant lists produce the same default-mode child, one
reservation/lease/launch and retained denies. Default-mode parent escalation
and wildcard grants still refuse, and matching deny strings remove allows.
Store normalization keeps negative provenance when filling a missing
interactive tool policy, and a missing mode remains missing. Neither becomes
verified parent policy. Exclusive reservation rechecks the recorded snapshot
before adding a child or lease. Legacy bounded normalization and explicit
worker YOLO refusals are unchanged. These checks establish recorded/requested
policy only. They do not inspect human-modified live permissions, prove atomic
provider-policy comparison, or guarantee actual manual startup when provider
defaults/environment request allow-all; that runtime acceptance gap stays
explicit.
