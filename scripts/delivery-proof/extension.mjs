import { joinSession } from "@github/copilot-sdk/extension";
import { sessionEndGate, startBeats, startBornManaged, startManaged, startReadiness } from "./adapter.mjs";

const shutdown = new AbortController();
const diagnosticCodes = new Set([
  "EADDRINUSE", "EACCES", "EPERM", "ENOENT", "ENOTDIR", "ELOOP",
  "ETIMEDOUT", "ECONNREFUSED", "ECONNRESET", "ABORT_ERR",
]);
let listener;
let beats;
let stopping = false;
// Owned-process passes run only while this session is managed (ADR 0027). A missing or broken
// module costs only process observation, never messaging, Beats or enrollment.
const processes = await import("./processes.mjs").then(module => module.createProcessObserver(), () => null);
const join = config => joinSession(processes ? processes.hooks(config) : config);
const managedListener = value => { listener = value; processes?.start(); };

function fail(context, error) {
  const code = diagnosticCodes.has(error?.code) ? error.code : "INITIALIZATION_FAILED";
  console.error(`Maestro messaging ${context} (${code}); no fallback or retry.`);
  process.exit(1);
}

async function stop() {
  if (stopping) return;
  stopping = true;
  processes?.stop();
  // /exit sends SIGTERM just before SessionEnd; give that record (and its binding clear) two seconds.
  await sessionEndGate.drain(2000);
  shutdown.abort();
  try {
    // Let a Beats sync in flight record what it created; never wait more than two seconds.
    await Promise.race([beats?.close(), new Promise((resolve) => setTimeout(resolve, 2000))]);
    await listener?.close();
    process.exit(0);
  } catch (error) {
    fail("shutdown failed", error);
  }
}
process.on("SIGTERM", stop);
// A hangup means the terminal or a signal ended the session, never the user (see adapter).
process.on("SIGHUP", () => { sessionEndGate.hungUp = true; stop(); });

startManaged({
  joinSession: join, signal: shutdown.signal, onListener: managedListener,
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
      joinSession: join, signal: shutdown.signal, onListener: managedListener, onJoined: beatsFor,
    });
    session = born === null ? await startReadiness({ joinSession: join, signal: shutdown.signal }) : born.session;
  }
  beatsFor(session);
}).catch(error => {
  if (!stopping) fail("unavailable for this session", error);
});
