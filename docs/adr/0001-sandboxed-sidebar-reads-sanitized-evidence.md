# Sandboxed sidebar reads sanitized evidence; control lives outside

The sidebar runs in the App Sandbox. It reads only bounded, sanitized files from exact granted prefixes and acts only through typed CMUX host navigation. Launch, close, messaging, Git probes, and install run in the unsandboxed app or helpers.

Why: the sidebar is the biggest attack surface and the easiest to mislead. A sandbox with read-only grants cannot leak transcripts, credentials, or paths, and cannot run a daemon, socket client, or terminal control.

Rejected: a daemon, loopback server, XPC service, or raw CMUX socket client in the sidebar.

Consequence: every new capability needs a helper outside the sandbox plus a sanitized file. No grant widens for convenience. A sandbox probe passing does not prove the host loaded the UI.

Amended by [ADR 0020](0020-sidebar-writes-beats-store-outside-its-container.md): outside its own container, the sidebar's only writable grant is the Beats store.
