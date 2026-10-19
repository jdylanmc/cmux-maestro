// When to ask the controller for an owned-process pass (#75, #78, ADR 0026). One pass covers
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
// process, a detached one, or an incomplete or missing entry.
export function sessionNeedsWatching(projection, sessionId) {
  const nodes = (Array.isArray(projection?.nodes) ? projection.nodes : [])
    .filter(node => node?.copilotSessionId === sessionId);
  if (nodes.length === 0) return true;
  return nodes.some(node => node.state === "scan-incomplete" || (Array.isArray(node.processes) &&
    node.processes.some(item => item?.state === "escaped" ||
      (item?.state === "owned-current" && item?.group === "separate"))));
}

export function createProcessObserver({ run = runProcessObserve, intervalMs = SCAN_INTERVAL_MS,
  debounceMs = SCAN_DEBOUNCE_MS, now = Date.now, timers = globalThis, sessionId = process.env.SESSION_ID,
  projection = publishedProjection(), stat = file => fs.stat(file), read = file => fs.readFile(file, "utf8") } = {}) {
  let active = false;
  let timer;
  let inFlight = null;
  let last = -Infinity;
  let watched = { mtimeMs: NaN, needed: true };
  const needed = async info => {
    if (info.mtimeMs !== watched.mtimeMs) {
      let value = true;
      try {
        if (info.size <= MAX_PROJECTION) value = sessionNeedsWatching(JSON.parse(await read(projection)), sessionId);
      } catch {}
      watched = { mtimeMs: info.mtimeMs, needed: value };
    }
    return watched.needed;
  };
  const trigger = (periodic = false) => {
    if (!active || inFlight || now() - last < debounceMs) return inFlight ?? undefined;
    last = now();
    inFlight = (async () => {
      const info = await stat(projection).catch(() => null);
      // Another session's pass just covered every managed node, this one included.
      if (info && now() - info.mtimeMs < SHARED_FRESH_MS) return;
      if (periodic && info && !await needed(info)) return;
      await run();
    })().catch(() => {}).finally(() => { inFlight = null; });
    return inFlight;
  };
  const stop = () => {
    active = false;
    timers.clearInterval(timer);
    timer = undefined;
  };
  return {
    get active() { return active; },
    // Only once this session is managed: one pass now, then checks every interval until it ends.
    start() {
      if (active) return;
      active = true;
      trigger();
      timer = timers.setInterval(() => trigger(true), intervalMs);
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
