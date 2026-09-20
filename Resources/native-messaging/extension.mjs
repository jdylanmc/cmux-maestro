import { bootstrap, attachAdapter } from "./adapter.mjs";

try {
    const binding = await bootstrap();
    if (binding) {
        const { joinSession } = await import("@github/copilot-sdk/extension");
        const adapter = await attachAdapter({ ...binding, joinSession });
        adapter.start(() => process.exit(1));
        process.once("SIGTERM", () => {
            void adapter.close().then(() => process.exit(0), () => process.exit(1));
        });
    }
} catch {
    // No SDK join for an unverified session. Never emit private bridge data.
    process.stderr.write("Maestro native messaging unavailable; no automatic adoption or retry.\n");
    process.exit(1);
}
