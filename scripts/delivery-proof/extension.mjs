import { joinSession } from "@github/copilot-sdk/extension";
import { startManaged } from "./adapter.mjs";

const shutdown = new AbortController();
const diagnosticCodes = new Set([
  "EADDRINUSE", "EACCES", "EPERM", "ENOENT", "ENOTDIR", "ELOOP",
  "ETIMEDOUT", "ECONNREFUSED", "ECONNRESET", "ABORT_ERR",
]);
let listener;
let stopping = false;

function fail(context, error) {
  const code = diagnosticCodes.has(error?.code) ? error.code : "INITIALIZATION_FAILED";
  console.error(`Maestro messaging ${context} (${code}); no fallback or retry.`);
  process.exit(1);
}

process.on("SIGTERM", async () => {
  if (stopping) return;
  stopping = true;
  shutdown.abort();
  try {
    await listener?.close();
    process.exit(0);
  } catch (error) {
    fail("shutdown failed", error);
  }
});

startManaged({
  joinSession, signal: shutdown.signal, onListener: value => { listener = value; },
}).catch(error => {
  if (!stopping) fail("unavailable for this session", error);
});
