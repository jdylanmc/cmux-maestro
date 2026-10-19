// When to ask the controller for an owned-process pass (#75, #78, ADR 0026). One pass covers
// every managed session and throttles itself; this decides only when this session asks.
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";

export const SCAN_INTERVAL_MS = 10_000;
export const SCAN_DEBOUNCE_MS = 2_000;
const SCAN_TIMEOUT_MS = 20_000;

const installedController = () => path.join(os.homedir(),
  "Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator");

// Output is never read: the pass publishes its own projection, and a failure waits for the next.
export function runProcessObserve(controller = process.env.CMUX_MAESTRO_ORCHESTRATOR || installedController()) {
  return new Promise(resolve => {
    const child = spawn(controller, ["process-observe"], { stdio: "ignore", timeout: SCAN_TIMEOUT_MS });
    child.once("error", resolve);
    child.once("exit", resolve);
  });
}

export function createProcessObserver({ run = runProcessObserve, intervalMs = SCAN_INTERVAL_MS,
  debounceMs = SCAN_DEBOUNCE_MS, now = Date.now, timers = globalThis } = {}) {
  let active = false;
  let timer;
  let inFlight = null;
  let last = -Infinity;
  const trigger = () => {
    if (!active || inFlight || now() - last < debounceMs) return inFlight ?? undefined;
    last = now();
    inFlight = Promise.resolve().then(() => run()).catch(() => {}).finally(() => { inFlight = null; });
    return inFlight;
  };
  const stop = () => {
    active = false;
    timers.clearInterval(timer);
    timer = undefined;
  };
  return {
    get active() { return active; },
    // Only once this session is managed: one pass now, then one per interval until it ends.
    start() {
      if (active) return;
      active = true;
      trigger();
      timer = timers.setInterval(trigger, intervalMs);
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
