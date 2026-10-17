import { joinSession } from "@github/copilot-sdk/extension";
import { startBeats, startBornManaged, startManaged, startReadiness } from "./adapter.mjs";

const shutdown = new AbortController();
const diagnosticCodes = new Set([
  "EADDRINUSE", "EACCES", "EPERM", "ENOENT", "ENOTDIR", "ELOOP",
  "ETIMEDOUT", "ECONNREFUSED", "ECONNRESET", "ABORT_ERR",
]);
let listener;
let beats;
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
    // Let a Beats sync in flight record what it created; never wait more than two seconds.
    await Promise.race([beats?.close(), new Promise((resolve) => setTimeout(resolve, 2000))]);
    await listener?.close();
    process.exit(0);
  } catch (error) {
    fail("shutdown failed", error);
  }
});

startManaged({
  joinSession, signal: shutdown.signal, onListener: value => { listener = value; },
}).then(async managed => {
  // Beats hand recurring prompts to Copilot's own scheduler in any CMUX session; failures are
  // diagnosed inside and never stop messaging.
  const beatsFor = session => {
    if (!beats && typeof session?.rpc?.schedule?.list === "function") beats = startBeats({ session });
  };
  let session = managed?.session;
  if (managed === null) {
    // A session born in CMUX enrolls itself (ADR 0025); otherwise readiness only.
    const born = await startBornManaged({
      joinSession, signal: shutdown.signal, onListener: value => { listener = value; }, onJoined: beatsFor,
    });
    session = born === null ? await startReadiness({ joinSession, signal: shutdown.signal }) : born.session;
  }
  beatsFor(session);
}).catch(error => {
  if (!stopping) fail("unavailable for this session", error);
});
