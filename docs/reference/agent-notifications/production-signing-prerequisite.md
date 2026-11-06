# Production signing prerequisite

[↑ Agent notifications](../agent-notifications.md) | [← Rate limit and clicks](rate-limit-and-clicks.md)

The containing app must carry
`com.apple.developer.usernotifications.communication = true` in its effective
signature and a matching, unexpired production profile authorizing that
capability. Its Info.plist declares `INSendMessageIntent` in `NSUserActivityTypes`.
The app checks the effective entitlement before authorizing or donating; without
it notifications return `notification-unavailable`, never an ordinary fallback.

Publication requires `build-register.sh --provisioning-profile /absolute/profile`.
It verifies the profile and one usable existing matching identity, signs all
embedded native code consistently, and embeds the profile only in the containing
app before coordinated installation. New ad-hoc publication refuses; historical
receipt-owned ad-hoc rollback remains supported. See the
[signing prerequisites](../install-update-recovery.md). No Developer Portal or
certificate mutation is automated. Never use the isolated synthetic test profile
or replace production bundles manually. The sidebar needs no communication
entitlement or additional grant.

CMUX's optional **Forward notifications to my iPhone** applies to CMUX-owned
notifications, not these direct Maestro OS notifications. This implementation
adds no phone service, forwarding, credentials or network delivery.
