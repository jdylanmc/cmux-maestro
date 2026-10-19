// When to ask the controller for an owned-process pass (#75, #78, ADR 0027). One pass covers
// every managed session and throttles itself; this decides only when this session asks, and
// checks the shared projection first so idle sessions never start the controller.
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

export const SCAN_INTERVAL_MS = 10_000;
export const SCAN_DEBOUNCE_MS = 2_000;
// The controller's own minimum interval between passes.
export const SHARED_FRESH_MS = 2_000;
const SCAN_TIMEOUT_MS = 20_000;
const MAX_PROJECTION = 1_048_576;

const support = path.join(os.homedir(), "Library/Application Support/CMUXMaestroPreview/Orchestration");
const installedController = () => path.join(support, "bin/cmux-maestro-orchestrator");
export const publishedProjection = () => path.join(support, "observer/processes.json");

// Output is never read: the pass publishes its own projection, and a failure waits for the next.
export function runProcessObserve(controller = process.env.CMUX_MAESTRO_ORCHESTRATOR || installedController()) {
  return new Promise(resolve => {
    const child = spawn(controller, ["process-observe"], { stdio: "ignore", timeout: SCAN_TIMEOUT_MS });
    child.once("error", resolve);
    child.once("exit", resolve);
  });
}

// Periodic passes only matter while this session has its own work to watch: a non-helper owned
// process, a retained detached or exited one (so it expires), or an incomplete or missing entry.
export function sessionNeedsWatching(projection, sessionId) {
  const nodes = (Array.isArray(projection?.nodes) ? projection.nodes : [])
    .filter(node => node?.copilotSessionId === sessionId);
  if (nodes.length === 0) return true;
  return nodes.some(node => node.state === "scan-incomplete" || (Array.isArray(node.processes) &&
    node.processes.some(item => item?.state === "escaped" || item?.state === "exited" ||
      (item?.state === "owned-current" && item?.group === "separate"))));
}

const MAX_PENDING_RUNS = 3;

export function createProcessObserver({ run = runProcessObserve, intervalMs = SCAN_INTERVAL_MS,
  debounceMs = SCAN_DEBOUNCE_MS, now = Date.now, timers = globalThis, sessionId = process.env.SESSION_ID,
  projection = publishedProjection(), stat = file => fs.stat(file), read = file => fs.readFile(file, "utf8") } = {}) {
  let active = false;
  let timer;
  let retry;
  let inFlight = null;
  let last = -Infinity;
  // The earliest event no pass has covered yet: a pass covers it only if it began after it.
  let pendingSince = null;
  let pendingRuns = 0;
  let cached = { mtimeMs: NaN, observedAt: -Infinity, needed: true };
  const load = async () => {
    const info = await stat(projection).catch(() => null);
    if (!info) return { mtimeMs: NaN, observedAt: -Infinity, needed: true };
    if (info.mtimeMs !== cached.mtimeMs) {
      let observedAt = -Infinity;
      let needed = true;
      try {
        if (info.size <= MAX_PROJECTION) {
          const value = JSON.parse(await read(projection));
          const parsed = Date.parse(value?.observedAt);
          if (Number.isFinite(parsed)) observedAt = parsed;
          needed = sessionNeedsWatching(value, sessionId);
        }
      } catch {}
      cached = { mtimeMs: info.mtimeMs, observedAt, needed };
    }
    return cached;
  };
  const later = ms => {
    if (retry !== undefined || !active) return;
    retry = timers.setTimeout(() => { retry = undefined; attempt(false); }, Math.max(0, ms));
    retry?.unref?.();
  };
  const settle = state => {
    if (pendingSince !== null && state.observedAt >= pendingSince) {
      pendingSince = null;
      pendingRuns = 0;
    }
  };
  const attempt = periodic => {
    if (!active) return undefined;
    if (inFlight) return inFlight;  // its finally retries anything still pending
    if (now() - last < debounceMs) {
      if (pendingSince !== null) later(last + debounceMs - now());
      return undefined;
    }
    inFlight = (async () => {
      const state = await load();
      settle(state);
      if (pendingSince === null) {
        // Nothing pending; a periodic check runs only for its own work, and never right after
        // another session's pass, which covered every managed node.
        if (!periodic || !state.needed || now() - state.mtimeMs < SHARED_FRESH_MS) return;
      } else if (now() - state.observedAt < SHARED_FRESH_MS) {
        // The controller would refuse a pass this soon; ask once it accepts one.
        later(state.observedAt + SHARED_FRESH_MS - now());
        return;
      }
      last = now();
      await run();
      if (pendingSince !== null) {
        settle(await load());
        // Give up on an event after a few passes that never published, rather than spin.
        if (pendingSince !== null && ++pendingRuns >= MAX_PENDING_RUNS) {
          pendingSince = null;
          pendingRuns = 0;
        }
      }
    })().catch(() => {}).finally(() => {
      inFlight = null;
      if (pendingSince !== null) later(debounceMs);
    });
    return inFlight;
  };
  // Every hook event (and becoming managed) must be covered by a pass that starts after it.
  const trigger = () => {
    if (!active) return undefined;
    pendingSince ??= now();
    return attempt(false);
  };
  const stop = () => {
    active = false;
    timers.clearInterval(timer);
    timers.clearTimeout(retry);
    timer = undefined;
    retry = undefined;
    pendingSince = null;
  };
  return {
    get active() { return active; },
    // Only once this session is managed: one pass now, then checks every interval until it ends.
    start() {
      if (active) return;
      active = true;
      trigger();
      timer = timers.setInterval(() => attempt(true), intervalMs);
      timer?.unref?.();
    },
    stop,
    trigger,
    // Tool use and agent stops ask for a pass; existing handlers run unchanged with their results.
    hooks(config) {
      const hooks = { ...config?.hooks };
      for (const name of ["onPostToolUse", "onAgentStop"]) {
        const original = hooks[name];
        hooks[name] = async (...args) => { trigger(); return original?.(...args); };
      }
      const end = hooks.onSessionEnd;
      hooks.onSessionEnd = async (...args) => { stop(); return end?.(...args); };
      return { ...config, hooks };
    },
  };
}
