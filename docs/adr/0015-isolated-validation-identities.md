# Isolated validation identities

Unsigned and test builds get their own bundle-ID suffix and sidebar extension point, such as `.Validation.Tests`. Setup, install, and uninstall refuse them: only the exact production bundle identity may cause side effects.

Why: LaunchServices registration of a test build can replace the production sidebar provider. There is no supported way to suppress registration.

Rejected: an unsupported registration-suppression setting.

Consequence: build metadata and checks carry the suffix logic. Never use a validation app's installer UI.
