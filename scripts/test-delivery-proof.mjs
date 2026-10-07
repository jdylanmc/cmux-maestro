// Contract tests with mocked Copilot sessions. These do not prove native UI behavior.
import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import net from "node:net";
import { EventEmitter, once } from "node:events";
import { spawn } from "node:child_process";
import { pathToFileURL, fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { start, startManaged, validateSend } from "./delivery-proof/adapter.mjs";

const base = await fs.realpath("/tmp");

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(base, "m61-"));
  const workspaceId = randomUUID();
  const bindings = Object.fromEntries(["a", "b"].map((peer, i) => [peer, {
    peer, workspaceId, sessionId: randomUUID(), capability: `${i + 1}`.repeat(64),
  }]));
  for (const [peer, binding] of Object.entries(bindings)) {
    await fs.writeFile(path.join(root, `${peer}.json`), JSON.stringify(binding), { mode: 0o600 });
  }
  const tools = {};
  const sends = { a: [], b: [] };
  const events = new EventEmitter();
  const adapters = [];
  t.after(async () => {
    for (const adapter of adapters) await adapter.close();
    await fs.rm(root, { recursive: true });
  });
  async function launch(peer, overrideId) {
    const adapter = await start({
      root, peer,
      diagnostic: () => events.emit("drop"),
      joinSession: async (config) => {
        assert.deepEqual(Object.keys(config), ["tools"]);
        tools[peer] = Object.fromEntries(config.tools.map((tool) => [tool.name,
          (args, invocation = { sessionId: bindings[peer].sessionId }) => tool.handler(args, invocation)]));
        return {
          sessionId: overrideId ?? bindings[peer].sessionId,
          send: async (options) => {
            sends[peer].push(options);
            events.emit("send", peer);
            return "ignored-native-message-id";
          },
        };
      },
    });
    adapters.push(adapter);
  }
  return { root, bindings, tools, sends, events, launch, adapters };
}

const addr = (binding) => ({ workspaceId: binding.workspaceId, sessionId: binding.sessionId });
const event = (emitter, name) => once(emitter, name, { signal: AbortSignal.timeout(2000) });

async function rawSend(root, peer, wire) {
  await new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(root, `${peer}.sock`));
    let returned = 0;
    socket.on("data", (chunk) => { returned += chunk.length; });
    socket.on("error", reject);
    socket.on("connect", () => socket.end(JSON.stringify(wire)));
    socket.on("end", () => {
      assert.equal(returned, 0, "receiver must not implement an acknowledgement protocol");
      resolve();
    });
  });
}

test("mocked native sessions: same-workspace peer send and ordinary reply", async (t) => {
  const f = await fixture(t);
  await f.launch("a");
  await f.launch("b");
  const peers = JSON.parse(await f.tools.a.maestro_proof_peers({}));
  assert.deepEqual(peers, [{ peer: "b", ...addr(f.bindings.b) }]);
  assert.equal(JSON.stringify(peers).includes("capability"), false);
  const incoming = event(f.events, "send");
  const result = await f.tools.a.maestro_proof_send({ destination: addr(f.bindings.b), body: "Hello B" });
  assert.match(result, /unconfirmed/);
  await incoming;
  assert.equal(f.sends.b.length, 1);
  assert.equal(f.sends.b[0].mode, "enqueue");
  const envelope = JSON.parse(f.sends.b[0].prompt.split("\n").slice(1).join("\n"));
  assert.deepEqual(envelope, {
    destination: addr(f.bindings.b), sender: addr(f.bindings.a), body: "Hello B",
  });
  assert.equal(f.sends.b[0].prompt.includes(f.bindings.a.capability), false);
  const reply = event(f.events, "send");
  await f.tools.b.maestro_proof_send({ destination: envelope.sender, body: "Hello A" });
  await reply;
  assert.equal(f.sends.a.length, 1);
  assert.equal(f.sends.a[0].mode, "enqueue");
});

test("strict send shape refuses forged sender, malformed UUIDs, controls and oversized bodies", () => {
  const destination = { workspaceId: randomUUID(), sessionId: randomUUID() };
  validateSend({ destination, body: "normal\nmessage" });
  for (const value of [
    { destination, body: "x", sender: destination },
    { destination, body: "x", capability: "forged" },
    { destination: { ...destination, sessionId: "../b" }, body: "x" },
    { destination, body: "é".repeat(2049) },
    { destination, body: " \n " },
    { destination, body: "\u001b[I" },
    { destination, body: "x", extra: true },
  ]) assert.throws(() => validateSend(value));
});

test("no peer control privilege, cross-workspace route, self-send, unknown peer or fallback", async (t) => {
  const f = await fixture(t);
  await f.launch("a");
  for (const destination of [
    addr(f.bindings.a),
    { workspaceId: randomUUID(), sessionId: f.bindings.b.sessionId },
    { workspaceId: f.bindings.a.workspaceId, sessionId: randomUUID() },
  ]) {
    assert.equal((await f.tools.a.maestro_proof_send({ destination, body: "x" })).resultType, "failure");
  }
  assert.equal((await f.tools.a.maestro_proof_send({
    destination: addr(f.bindings.b), body: "recipient not listening",
  })).resultType, "failure");
  assert.equal((await f.tools.a.maestro_proof_peers({}, {
    sessionId: f.bindings.b.sessionId,
  })).resultType, "failure");
  assert.equal((await f.tools.a.maestro_proof_send({
    destination: addr(f.bindings.b), body: "wrong tool caller",
  }, { sessionId: f.bindings.b.sessionId })).resultType, "failure");
  assert.deepEqual(f.sends, { a: [], b: [] });
});

test("wire rejects invented identity/capability and never returns an application response", async (t) => {
  const f = await fixture(t);
  await f.launch("b");
  for (const change of [
    { capability: "0".repeat(64) },
    { sender: { ...addr(f.bindings.a), sessionId: randomUUID() } },
    { destination: addr(f.bindings.a) },
    { extra: true },
  ]) {
    const dropped = event(f.events, "drop");
    await rawSend(f.root, "b", {
      sender: addr(f.bindings.a), destination: addr(f.bindings.b),
      capability: f.bindings.a.capability, body: "must not arrive", ...change,
    });
    await dropped;
  }
  assert.deepEqual(f.sends.b, []);
});

test("wrong joined session, unsafe files, symlinks and occupied endpoints fail closed", async (t) => {
  const f = await fixture(t);
  await assert.rejects(f.launch("a", randomUUID()));
  const binding = path.join(f.root, "a.json");
  await fs.chmod(binding, 0o644);
  await assert.rejects(f.launch("a"));
  await fs.chmod(binding, 0o600);
  await fs.rename(binding, path.join(f.root, "saved.json"));
  await fs.symlink(path.join(f.root, "saved.json"), binding);
  await assert.rejects(f.launch("a"));
  await fs.unlink(binding);
  await fs.rename(path.join(f.root, "saved.json"), binding);
  await f.launch("a");
  await assert.rejects(f.launch("a"));
});

test("native send rejection is diagnosed once, not retried or converted to a receipt", async (t) => {
  const f = await fixture(t);
  let attempts = 0;
  const nativeError = new EventEmitter();
  const adapter = await start({
    root: f.root, peer: "b",
    diagnostic: () => nativeError.emit("drop"),
    joinSession: async () => ({
      sessionId: f.bindings.b.sessionId,
      send: async () => { attempts++; throw new Error("synthetic provider error"); },
    }),
  });
  f.adapters.push(adapter);
  const dropped = event(nativeError, "drop");
  await rawSend(f.root, "b", {
    sender: addr(f.bindings.a), destination: addr(f.bindings.b),
    capability: f.bindings.a.capability, body: "only one attempt",
  });
  await dropped;
  assert.equal(attempts, 1);
});

test("malformed and fragmented wire input never uses terminal or readiness APIs", async (t) => {
  const f = await fixture(t);
  await f.launch("b");
  const dropped = event(f.events, "drop");
  await new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(f.root, "b.sock"));
    socket.on("error", reject);
    socket.on("connect", () => socket.end("{not JSON"));
    socket.on("end", resolve);
  });
  await dropped;
  assert.equal(f.sends.b.length, 0);
  const incoming = event(f.events, "send");
  const wire = JSON.stringify({
    sender: addr(f.bindings.a), destination: addr(f.bindings.b),
    capability: f.bindings.a.capability, body: "native enqueue only",
  });
  await new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(f.root, "b.sock"));
    socket.on("error", reject);
    socket.on("connect", () => {
      socket.write(wire.slice(0, 20));
      socket.end(wire.slice(20));
    });
    socket.on("end", resolve);
  });
  await incoming;
  assert.equal(f.sends.b.length, 1);
  assert.equal(f.sends.b[0].mode, "enqueue");
});

async function managedFixture(t) {
  const root = await fs.mkdtemp(path.join(base, "m61-"));
  const workspaceId = randomUUID();
  const bindings = [0, 1, 2, 3].map((index) => ({
    peer: String(index).repeat(16), nodeId: randomUUID(), name: `Participant ${index}`,
    workspaceId: index === 3 ? randomUUID() : workspaceId,
    sessionId: randomUUID(), generation: 1, capability: String(index).repeat(64),
  }));
  for (const binding of bindings) {
    await fs.writeFile(path.join(root, `${binding.peer}.json`), JSON.stringify(binding), { mode: 0o600 });
  }
  const tools = [], sends = [], adapters = [];
  const events = new EventEmitter();
  t.after(async () => {
    for (const adapter of adapters) await adapter.close();
    await fs.rm(root, { recursive: true });
  });
  function environment(index) {
    const own = bindings[index];
    return {
      CMUX_MAESTRO_MESSAGE_ROOT: root, CMUX_MAESTRO_MESSAGE_PEER: own.peer,
      CMUX_MAESTRO_WORKER_ID: own.nodeId, CMUX_MAESTRO_EXECUTION_MODE: "interactive",
      CMUX_WORKSPACE_ID: own.workspaceId, SESSION_ID: own.sessionId, CMUX_MAESTRO_GENERATION: "1",
    };
  }
  async function launch(index, overrides = {}) {
    const adapter = await startManaged({
      environment: { ...environment(index), ...overrides },
      diagnostic: () => events.emit("drop"),
      joinSession: async (options) => {
        assert.deepEqual(Object.keys(options), ["tools"]);
        tools[index] = Object.fromEntries(options.tools.map((tool) =>
          [tool.name, (args, invocation = { sessionId: bindings[index].sessionId }) => tool.handler(args, invocation)]));
        return {
          sessionId: bindings[index].sessionId,
          send: async (value) => { sends.push({ index, ...value }); events.emit("send"); },
        };
      },
    });
    adapters.push(adapter);
  }
  return { root, bindings, tools, sends, events, launch, environment };
}

const managedAddress = (binding) => ({ ...addr(binding), generation: binding.generation });

async function loaderFixture(t) {
  const root = await fs.mkdtemp(path.join(base, "m61-loader-"));
  const surfaceId = randomUUID();
  const binding = {
    peer: "1111111111111111", nodeId: randomUUID(), name: "Synthetic lifecycle",
    workspaceId: randomUUID(), sessionId: randomUUID(), generation: 1, capability: "c".repeat(64),
  };
  const endpoint = path.join(root, `${binding.peer}.sock`);
  const route = path.join(root, `${binding.peer}.json`);
  const children = [];
  async function exists(file) {
    try { return await fs.lstat(file); }
    catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }
  async function waitFor(predicate) {
    const deadline = Date.now() + 4000;
    while (!await predicate()) {
      assert.ok(Date.now() < deadline, "Synthetic lifecycle condition exceeded test watchdog");
      await delay(10);
    }
  }
  async function exited(item) {
    const timeout = new AbortController();
    try {
      return await Promise.race([
        item.done,
        delay(4000, null, { signal: timeout.signal }).then(() => {
          throw new Error("Owned synthetic extension did not terminate within test watchdog");
        }),
      ]);
    } finally { timeout.abort(); }
  }
  async function stop(item, signal = "SIGTERM") {
    item.child.kill(signal);
    return exited(item);
  }
  t.after(async () => {
    const failures = [];
    try {
      for (const item of children) {
        if (item.child.exitCode === null && item.child.signalCode === null) {
          try { await stop(item); }
          catch (error) { item.child.kill("SIGKILL"); await item.done; failures.push(error); }
        }
        if (item.observing && await exists(item.stage)) {
          const pid = Number(await fs.readFile(item.stage, "utf8"));
          if (!await exists(item.stage + ".stopped")) {
            try { process.kill(pid, "SIGTERM"); }
            catch (error) { if (error.code !== "ESRCH") failures.push(error); }
          }
        }
      }
    } finally { await fs.rm(root, { recursive: true }); }
    if (failures.length) throw new AggregateError(failures, "Synthetic extension cleanup failed");
  });
  await fs.writeFile(route, JSON.stringify(binding), { mode: 0o600 });
  await fs.writeFile(path.join(root, "sdk.mjs"), `
import { writeFileSync } from "node:fs";
export async function joinSession() {
  if (process.env.FIXTURE_FAIL_JOIN) {
    throw Object.assign(new Error(process.env.FIXTURE_PRIVATE_TEXT), { code: process.env.FIXTURE_PRIVATE_TEXT });
  }
  if (process.env.FIXTURE_HOLD_STAGE === "join") {
    writeFileSync(process.env.FIXTURE_STAGE, "join");
    process.stdin.resume();
    await new Promise(() => {});
  }
  return { sessionId: process.env.SESSION_ID };
}
`, { mode: 0o600 });
  await fs.writeFile(path.join(root, "resolve.mjs"), `
export function resolve(specifier, context, next) {
  if (specifier === "@github/copilot-sdk/extension")
    return { url: new URL("./sdk.mjs", import.meta.url).href, shortCircuit: true };
  return next(specifier, context);
}
`, { mode: 0o600 });
  await fs.writeFile(path.join(root, "preload.mjs"), `
import { register, syncBuiltinESMExports } from "node:module";
import { promises as fs, writeFileSync, appendFileSync } from "node:fs";
import net from "node:net";
import childProcess from "node:child_process";
register(new URL("./resolve.mjs", import.meta.url));
if (process.env.FIXTURE_HOLD_STAGE === "observe") {
  const execFile = childProcess.execFile;
  childProcess.execFile = (...args) => {
    const child = execFile(...args);
    child.stdin.end = data => child.stdin.write(data);
    return child;
  };
  syncBuiltinESMExports();
}
const chmod = fs.chmod;
fs.chmod = async (...args) => {
  if (process.env.FIXTURE_HOLD_STAGE === "chmod") {
    writeFileSync(process.env.FIXTURE_STAGE, "chmod");
    await new Promise(() => {});
  }
  if (process.env.FIXTURE_FAIL_CHMOD) throw Object.assign(new Error("private fixture path"), { code: "EACCES" });
  return chmod(...args);
};
const emit = net.Server.prototype.emit;
net.Server.prototype.emit = function(event, ...args) {
  if (event === "error") appendFileSync(process.env.FIXTURE_ERRORS, String(args[0]?.code) + "\\n", { mode: 0o600 });
  return Reflect.apply(emit, this, [event, ...args]);
};
`, { mode: 0o600 });
  await fs.writeFile(path.join(root, "controller"), `#!/usr/bin/env node
const { writeFileSync } = require("node:fs");
process.stdin.resume();
if (process.env.FIXTURE_HOLD_STAGE === "observe") {
  process.stdin.once("data", () => {
    process.on("SIGTERM", () => {
      writeFileSync(process.env.FIXTURE_STAGE + ".stopped", "stopped");
      process.exit(0);
    });
    writeFileSync(process.env.FIXTURE_STAGE, String(process.pid));
  });
}
process.stdin.on("end", () => process.stdout.write(JSON.stringify({ ok: true, observed: true })));
`, { mode: 0o700 });
  function launch(overrides = {}) {
    const stage = path.join(root, `stage-${children.length}`);
    const errors = path.join(root, `errors-${children.length}`);
    const child = spawn(process.execPath, [
      "--import", pathToFileURL(path.join(root, "preload.mjs")).href,
      fileURLToPath(new URL("./delivery-proof/extension.mjs", import.meta.url)),
    ], {
      env: {
        PATH: process.env.PATH,
        SESSION_ID: binding.sessionId, CMUX_WORKSPACE_ID: binding.workspaceId, CMUX_SURFACE_ID: surfaceId,
        CMUX_MAESTRO_MESSAGE_ROOT: root, CMUX_MAESTRO_MESSAGE_PEER: binding.peer,
        CMUX_MAESTRO_WORKER_ID: binding.nodeId, CMUX_MAESTRO_GENERATION: "1",
        CMUX_MAESTRO_EXECUTION_MODE: "interactive", CMUX_MAESTRO_DIRECT_LAUNCH: "1",
        CMUX_MAESTRO_LAUNCH_PID: String(process.pid), CMUX_MAESTRO_ORCHESTRATOR: path.join(root, "controller"),
        FIXTURE_STAGE: stage, FIXTURE_ERRORS: errors, ...overrides,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const item = { child, done: once(child, "exit"), stage, errors, stderr: "",
      observing: overrides.FIXTURE_HOLD_STAGE === "observe" };
    child.stderr.setEncoding("utf8").on("data", chunk => { item.stderr += chunk; });
    child.stdout.resume();
    children.push(item);
    return item;
  }
  const listening = () => waitFor(async () => {
    const info = await exists(endpoint);
    return info?.isSocket() && (info.mode & 0o777) === 0o600;
  });
  return { root, binding, endpoint, route, exists, waitFor, exited, stop, launch, listening };
}

test("actual native loader closes its listener on SIGTERM and the same binding reloads", async (t) => {
  const f = await loaderFixture(t);
  const bindingBefore = await fs.readFile(f.route);
  const first = f.launch();
  await f.listening();
  const connection = net.createConnection(f.endpoint);
  t.after(() => connection.destroy());
  await once(connection, "connect");
  const disconnected = once(connection, "close");
  assert.deepEqual(await f.stop(first), [0, null]);
  await disconnected;
  assert.equal(await f.exists(f.endpoint), null);
  assert.deepEqual(await fs.readFile(f.route), bindingBefore);
  const replacement = f.launch();
  await f.listening();
  assert.deepEqual(await f.stop(replacement), [0, null]);
  assert.equal(await f.exists(f.endpoint), null);
  assert.deepEqual(await fs.readFile(f.route), bindingBefore);
});

for (const stage of ["join", "observe", "chmod"]) {
  test(`actual native loader handles SIGTERM during ${stage} initialization`, async (t) => {
    const f = await loaderFixture(t);
    const first = f.launch({ FIXTURE_HOLD_STAGE: stage });
    await f.waitFor(() => f.exists(first.stage));
    assert.equal(Boolean(await f.exists(f.endpoint)), stage === "chmod");
    assert.deepEqual(await f.stop(first), [0, null]);
    if (stage === "observe") await f.waitFor(() => f.exists(first.stage + ".stopped"));
    assert.equal(await f.exists(f.endpoint), null);
    const replacement = f.launch();
    await f.listening();
    assert.deepEqual(await f.stop(replacement), [0, null]);
    assert.equal(await f.exists(f.endpoint), null);
  });
}

test("actual native loader cleans its owned listener after initialization failure", async (t) => {
  const f = await loaderFixture(t);
  const failed = f.launch({ FIXTURE_FAIL_CHMOD: "1" });
  assert.deepEqual(await f.exited(failed), [1, null]);
  assert.match(failed.stderr, /\(EACCES\)/);
  assert.equal(await f.exists(f.endpoint), null);
  const replacement = f.launch();
  await f.listening();
  assert.deepEqual(await f.stop(replacement), [0, null]);
});

for (const killed of [false, true]) {
  test(`actual native loader refuses ${killed ? "unproven stale" : "occupied live"} sockets without unlinking`, async (t) => {
    const f = await loaderFixture(t);
    const first = f.launch();
    await f.listening();
    const original = await fs.lstat(f.endpoint);
    if (killed) assert.deepEqual(await f.stop(first, "SIGKILL"), [null, "SIGKILL"]);
    const replacement = f.launch();
    assert.deepEqual(await f.exited(replacement), [1, null]);
    assert.match(await fs.readFile(replacement.errors, "utf8"), /EADDRINUSE/);
    assert.match(replacement.stderr, /\(EADDRINUSE\)/);
    assert.equal(replacement.stderr.includes(f.binding.capability), false);
    assert.equal(replacement.stderr.includes(f.root), false);
    const retained = await fs.lstat(f.endpoint);
    assert.equal(retained.dev, original.dev);
    assert.equal(retained.ino, original.ino);
    if (!killed) assert.deepEqual(await f.stop(first), [0, null]);
  });
}

test("actual native loader diagnostics never print raw exception text or private values", async (t) => {
  const f = await loaderFixture(t);
  const privateText = `PRIVATE_TASK_AND_CAPABILITY_${f.binding.capability}`;
  const failed = f.launch({ FIXTURE_FAIL_JOIN: "1", FIXTURE_PRIVATE_TEXT: privateText });
  assert.deepEqual(await f.exited(failed), [1, null]);
  assert.match(failed.stderr, /\(INITIALIZATION_FAILED\)/);
  assert.ok(failed.stderr.length < 200);
  assert.equal(failed.stderr.includes(privateText), false);
  assert.equal(failed.stderr.includes(f.binding.capability), false);
  assert.equal(await f.exists(f.endpoint), null);
});

test("installed mode discovers arbitrary same-workspace participants and peer replies", async (t) => {
  const f = await managedFixture(t);
  for (const index of [0, 1, 2, 3]) await f.launch(index);
  const peers = JSON.parse(await f.tools[0].maestro_peers({}));
  assert.deepEqual(peers.map((p) => p.sessionId).sort(), [f.bindings[1].sessionId, f.bindings[2].sessionId].sort());
  assert.equal(JSON.stringify(peers).includes("capability"), false);
  assert.equal(JSON.stringify(peers).includes(f.root), false);
  for (const index of [1, 2]) {
    const incoming = event(f.events, "send");
    assert.match(await f.tools[0].maestro_send({
      destination: managedAddress(f.bindings[index]), body: `hello ${index}`,
    }), /unconfirmed/);
    await incoming;
    const envelope = JSON.parse(f.sends.at(-1).prompt.split("\n").slice(1).join("\n"));
    assert.deepEqual(envelope.sender, managedAddress(f.bindings[0]));
    assert.equal(f.sends.at(-1).mode, "enqueue");
    const reply = event(f.events, "send");
    await f.tools[index].maestro_send({ destination: envelope.sender, body: "reply" });
    await reply;
    assert.equal(f.sends.at(-1).index, 0);
  }
  assert.equal((await f.tools[0].maestro_send({
    destination: managedAddress(f.bindings[3]), body: "different workspace",
  })).resultType, "failure");
  assert.deepEqual(Object.keys(f.tools[0]),
    ["maestro_peers", "maestro_send", "maestro_identity", "maestro_close", "maestro_spawn"]);
});

test("installed loader is inert outside managed sessions and refuses mismatched bindings before join", async (t) => {
  let joined = false;
  assert.equal(await startManaged({ environment: {}, joinSession: () => { joined = true; } }), null);
  assert.equal(joined, false);
  const f = await managedFixture(t);
  for (const overrides of [
    { SESSION_ID: randomUUID() }, { CMUX_WORKSPACE_ID: randomUUID() },
    { CMUX_MAESTRO_GENERATION: "2" }, { CMUX_MAESTRO_WORKER_ID: randomUUID() },
  ]) {
    await assert.rejects(startManaged({
      environment: { ...f.environment(0), ...overrides },
      joinSession: () => { joined = true; },
    }));
    assert.equal(joined, false);
  }
});

test("direct loader uses precreated bindings and observes only its joined CLI session once", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const surfaceId = randomUUID();
  const order = [];
  const environment = {
    ...f.environment(0), CMUX_MAESTRO_DIRECT_LAUNCH: "1",
    CMUX_MAESTRO_LAUNCH_PID: "12345", CMUX_SURFACE_ID: surfaceId,
    CMUX_MAESTRO_ORCHESTRATOR: "/synthetic/controller",
  };
  const adapter = await startManaged({
    environment,
    joinSession: async options => {
      order.push("join");
      assert.deepEqual(options.tools.map(tool => tool.name),
        ["maestro_peers", "maestro_send", "maestro_identity", "maestro_close", "maestro_spawn"]);
      return { sessionId: own.sessionId };
    },
    observe: async (request, controller) => {
      order.push("observe");
      assert.equal(controller, environment.CMUX_MAESTRO_ORCHESTRATOR);
      assert.deepEqual(request, {
        nodeId: own.nodeId, workspaceId: own.workspaceId, sessionId: own.sessionId,
        generation: 1, surfaceId, pid: 12345,
      });
      assert.equal(JSON.stringify(request).includes("capability"), false);
      return { ok: true, observed: true };
    },
  });
  t.after(() => adapter.close());
  assert.deepEqual(order, ["join", "observe"]);
});

test("direct observation failure is explicit and never retried or adopted", async (t) => {
  const f = await managedFixture(t);
  let observations = 0;
  const environment = {
    ...f.environment(0), CMUX_MAESTRO_DIRECT_LAUNCH: "1",
    CMUX_MAESTRO_LAUNCH_PID: "12345", CMUX_SURFACE_ID: randomUUID(),
  };
  await assert.rejects(startManaged({
    environment, joinSession: async () => ({ sessionId: f.bindings[0].sessionId }),
    observe: async () => { observations++; throw new Error("ownership changed"); },
  }), /ownership changed/);
  assert.equal(observations, 1);
  await assert.rejects(startManaged({
    environment, joinSession: async () => ({ sessionId: randomUUID() }),
    observe: async () => { observations++; },
  }));
  assert.equal(observations, 1);
  await assert.rejects(fs.stat(path.join(f.root, `${f.bindings[0].peer}.sock`)), { code: "ENOENT" });
});

test("native launch reads the invoking session account on each request, not task-supplied identity", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let tools;
  let login = "parent-a";
  const requests = [];
  const receipt = {
    ok: true, workerId: "synthetic-worker", launchAccepted: true, startup: "pending",
    initialTask: "configured", supervisorStarted: false, providerStarted: false,
    providerRunning: null, messaging: "configured", messagingAvailability: "unknown",
    workObservation: "unavailable",
  };
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async options => {
      tools = options.tools;
      return {
        sessionId: own.sessionId,
        rpc: { gitHubAuth: { getStatus: async () => ({
          isAuthenticated: true, host: "https://github.com", login,
        }) } },
      };
    },
    launch: async request => {
      requests.push(request);
      return receipt;
    },
  });
  t.after(() => adapter.close());
  const spawn = tools.find(tool => tool.name === "maestro_spawn").handler;
  const identity = tools.find(tool => tool.name === "maestro_identity").handler;
  const assignment = { name: "Child", cwd: "/synthetic", task: "Bounded task" };
  const invocation = { sessionId: own.sessionId };
  for (const next of ["parent-a", "parent-b"]) {
    login = next;
    const observed = JSON.parse(await identity({}, invocation));
    assert.equal(observed.account.login, next);
    assert.equal(observed.sessionId, own.sessionId);
    assert.equal(JSON.stringify(observed).includes(own.capability), false);
    const result = await spawn(assignment, invocation);
    assert.deepEqual(JSON.parse(result), receipt);
    assert.equal(requests.at(-1).identity.login, next);
    assert.equal(result.includes(own.capability), false);
    assert.equal(result.includes(next), false);
  }
  assert.equal((await spawn({ ...assignment, login: "injected" }, invocation)).resultType, "failure");
  assert.equal((await spawn(assignment, { sessionId: f.bindings[1].sessionId })).resultType, "failure");
  login = undefined;
  assert.equal((await identity({}, invocation)).resultType, "failure");
  assert.equal((await spawn(assignment, invocation)).resultType, "failure");
  assert.equal(requests.length, 2);
});

test("native launch refuses unsupported account APIs without creating a terminal", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let tools;
  let launches = 0;
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async options => { tools = options.tools; return { sessionId: own.sessionId }; },
    launch: async () => { launches++; },
  });
  t.after(() => adapter.close());
  const result = await tools.find(tool => tool.name === "maestro_spawn").handler(
    { name: "Child", cwd: "/synthetic", task: "No fallback" }, { sessionId: own.sessionId },
  );
  assert.equal(result.resultType, "failure");
  assert.equal(launches, 0);
});

test("installed routes refuse stale generations, lost participation and wrong invocation", async (t) => {
  const f = await managedFixture(t);
  await f.launch(0);
  await f.launch(1);
  for (const destination of [
    { ...managedAddress(f.bindings[1]), generation: 2 }, addr(f.bindings[1]),
    managedAddress(f.bindings[0]),
  ]) assert.equal((await f.tools[0].maestro_send({ destination, body: "stale" })).resultType, "failure");
  assert.equal((await f.tools[0].maestro_peers({}, { sessionId: f.bindings[1].sessionId })).resultType, "failure");
  const dropped = event(f.events, "drop");
  await rawSend(f.root, f.bindings[1].peer, {
    sender: managedAddress(f.bindings[0]), destination: { ...managedAddress(f.bindings[1]), generation: 2 },
    capability: f.bindings[0].capability, body: "stale",
  });
  await dropped;
  await fs.unlink(path.join(f.root, `${f.bindings[0].peer}.json`));
  assert.equal((await f.tools[0].maestro_peers({})).resultType, "failure");
  assert.equal((await f.tools[0].maestro_send({
    destination: managedAddress(f.bindings[1]), body: "removed",
  })).resultType, "failure");
  assert.equal(f.sends.length, 0);
});

test("native close supplies private invoking identity and one explicit target without account or observation calls", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const target = { workerId: f.bindings[1].nodeId, ...managedAddress(f.bindings[1]), surfaceId: randomUUID() };
  const result = { ok: true, ...target, closeAccepted: true, removal: "unconfirmed" };
  const requests = [];
  let close;
  const controller = new AbortController();
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: { ...own, controller: "/synthetic/controller" },
    signal: controller.signal,
    joinSession: async ({ tools }) => {
      close = tools.find(tool => tool.name === "maestro_close");
      return { sessionId: own.sessionId };
    },
    closeChild: async (...args) => { requests.push(args); return result; },
  });
  t.after(() => adapter.close());
  assert.deepEqual(close.parameters.required, ["target"]);
  assert.equal(close.parameters.additionalProperties, false);
  const output = await close.handler({ target }, { sessionId: own.sessionId });
  assert.deepEqual(JSON.parse(output), result);
  assert.equal(output.includes(own.capability), false);
  assert.deepEqual(requests, [[{
    identity: { nodeId: own.nodeId, ...managedAddress(own), capability: own.capability }, target,
  }, "/synthetic/controller", controller.signal]]);
  assert.deepEqual(f.sends, []);
});

test("native close forwards explicit subtree scope once and preserves complete per-target outcomes", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const target = { workerId: f.bindings[1].nodeId, ...managedAddress(f.bindings[1]), surfaceId: randomUUID() };
  const descendant = { workerId: randomUUID(), workspaceId: own.workspaceId,
    surfaceId: randomUUID(), sessionId: randomUUID(), generation: 3 };
  const result = { ok: true, scope: "subtree", results: [
    { ...descendant, outcome: "unknown", attempted: true, removal: "unconfirmed", reason: "host-failure" },
    { ...target, outcome: "accepted", attempted: true, closeAccepted: true,
      removal: "unconfirmed", reason: "accepted" },
  ] };
  const requests = [];
  const controller = new AbortController();
  let close;
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: { ...own, controller: "/synthetic/controller" },
    signal: controller.signal,
    joinSession: async ({ tools }) => {
      close = tools.find(tool => tool.name === "maestro_close");
      return { sessionId: own.sessionId };
    },
    closeChild: async (...args) => { requests.push(args); return result; },
  });
  t.after(() => adapter.close());

  const output = await close.handler({ target, scope: "subtree" }, { sessionId: own.sessionId });

  assert.deepEqual(requests, [[{
    identity: { nodeId: own.nodeId, ...managedAddress(own), capability: own.capability },
    target, scope: "subtree",
  }, "/synthetic/controller", controller.signal]]);
  assert.deepEqual(JSON.parse(output), result);
  assert.deepEqual(close.parameters.properties.scope.enum, ["target-only", "subtree"]);
  assert.deepEqual(close.parameters.required, ["target"]);
  assert.equal(output.includes(own.capability), false);
  assert.deepEqual(f.sends, []);
});

test("native close rejects public peer addresses, forged authority, broad targets and wrong invocations before ingress", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const target = { workerId: f.bindings[1].nodeId, ...managedAddress(f.bindings[1]), surfaceId: randomUUID() };
  let close, attempts = 0;
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async ({ tools }) => {
      close = tools.find(tool => tool.name === "maestro_close").handler;
      return { sessionId: own.sessionId };
    },
    closeChild: async () => { attempts++; throw new Error("must not reach ingress"); },
  });
  t.after(() => adapter.close());
  for (const args of [
    {}, { target: managedAddress(f.bindings[1]) }, { target: [target] },
    { target, identity: own }, { target, subtree: true },
    { target: { ...target, capability: own.capability } },
    { target: { ...target, generation: 0 } }, { target: { ...target, generation: 1.5 } },
    { target: { ...target, surfaceId: "../other" } },
    { target: { ...target, workspaceId: randomUUID() } },
    { target: { ...target, workerId: own.nodeId } },
    { target: { ...target, sessionId: own.sessionId } },
  ]) {
    assert.equal((await close(args, { sessionId: own.sessionId })).resultType, "failure");
  }
  assert.equal((await close({ target }, { sessionId: f.bindings[1].sessionId })).resultType, "failure");
  const route = path.join(f.root, `${own.peer}.json`);
  await fs.writeFile(route, JSON.stringify({ ...own, generation: 2 }));
  assert.equal((await close({ target }, { sessionId: own.sessionId })).resultType, "failure");
  await fs.writeFile(route, `{"capability":"${own.capability}", broken}`);
  const corrupt = await close({ target }, { sessionId: own.sessionId });
  assert.equal(corrupt.resultType, "failure");
  assert.equal(corrupt.textResultForLlm.includes(own.capability), false);
  await fs.unlink(route);
  assert.equal((await close({ target }, { sessionId: own.sessionId })).resultType, "failure");
  assert.equal(attempts, 0);
});

test("native close surfaces one refusal or lost reply without retry or resource-completion claims", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let close, attempts = 0;
  let failure = new Error("stock last-surface refusal");
  const controller = new AbortController();
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own, signal: controller.signal,
    joinSession: async ({ tools }) => {
      close = tools.find(tool => tool.name === "maestro_close").handler;
      return { sessionId: own.sessionId };
    },
    closeChild: async () => { attempts++; throw failure; },
  });
  t.after(() => adapter.close());
  const args = { target: {
    workerId: f.bindings[1].nodeId, ...managedAddress(f.bindings[1]), surfaceId: randomUUID(),
  } };
  for (const message of ["stock last-surface refusal", "lost reply", "timeout", "cancelled"]) {
    failure = new Error(message);
    const before = attempts;
    const result = await close(args, { sessionId: own.sessionId });
    assert.equal(result.resultType, "failure");
    assert.ok(result.textResultForLlm.includes(message));
    assert.match(result.textResultForLlm, /No fallback or retry.*removal is unconfirmed/);
    assert.equal(attempts, before + 1);
  }
  controller.abort();
  assert.equal((await close(args, { sessionId: own.sessionId })).resultType, "failure");
  assert.equal(attempts, 4, "already cancelled invocation never reaches the controller");
});

test("native close controller transport passes stdin once and reports refusal, lost reply and in-flight cancellation", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const executable = path.join(f.root, "controller.mjs");
  const modeFile = path.join(f.root, "mode");
  const callsFile = path.join(f.root, "calls");
  await fs.writeFile(executable, `#!${process.execPath}
import { readFileSync, appendFileSync } from "node:fs";
if (process.argv.slice(2).join() !== "native-close") process.exit(3);
const request = JSON.parse(readFileSync(0, "utf8"));
if (Object.keys(request).sort().join() !== "identity,target") process.exit(4);
const mode = readFileSync(${JSON.stringify(modeFile)}, "utf8");
appendFileSync(${JSON.stringify(callsFile)}, mode + "\\n");
if (mode === "accepted") console.log(JSON.stringify({
  ok: true, ...request.target, closeAccepted: true, removal: "unconfirmed",
}));
if (mode === "refused") {
  console.error(JSON.stringify({ ok: false, error: "stock lastSurface refusal" }));
  process.exitCode = 2;
}
if (mode === "lost") { console.error("unstructured local failure"); process.exitCode = 2; }
if (mode === "invalid") console.log('{"private":"must-not-escape", broken}');
if (mode === "cancel") setTimeout(() => process.exit(5), 4000);
`, { mode: 0o700 });
  const abort = new AbortController();
  let close;
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true,
    expected: { ...own, controller: executable }, signal: abort.signal,
    joinSession: async ({ tools }) => {
      close = tools.find(tool => tool.name === "maestro_close").handler;
      return { sessionId: own.sessionId };
    },
  });
  t.after(() => adapter.close());
  const target = { workerId: f.bindings[1].nodeId, ...managedAddress(f.bindings[1]), surfaceId: randomUUID() };
  for (const mode of ["accepted", "refused", "lost", "invalid", "cancel"]) {
    await fs.writeFile(modeFile, mode);
    const pending = close({ target }, { sessionId: own.sessionId });
    if (mode === "cancel") {
      const deadline = Date.now() + 2000;
      while (!(await fs.readFile(callsFile, "utf8")).endsWith("cancel\n")) {
        assert.ok(Date.now() < deadline, "synthetic controller did not receive request");
        await delay(10);
      }
      abort.abort();
    }
    const result = await pending;
    if (mode === "accepted") assert.deepEqual(JSON.parse(result), {
      ok: true, ...target, closeAccepted: true, removal: "unconfirmed",
    });
    else {
      assert.equal(result.resultType, "failure");
      assert.match(result.textResultForLlm, mode === "refused" ? /lastSurface/ : /uncertain/);
      assert.match(result.textResultForLlm, /No fallback or retry/);
      assert.equal(result.textResultForLlm.includes("unstructured local failure"), false);
      assert.equal(result.textResultForLlm.includes("must-not-escape"), false);
    }
  }
  assert.equal(await fs.readFile(callsFile, "utf8"), "accepted\nrefused\nlost\ninvalid\ncancel\n");
});

test("native close subtree transport preserves complete output and treats overflow or cancellation as uncertain", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const target = { workerId: f.bindings[1].nodeId, ...managedAddress(f.bindings[1]), surfaceId: randomUUID() };
  const results = Array.from({ length: 127 }, (_, index) => ({
    ...(index === 126 ? target : {
      workerId: randomUUID(), workspaceId: own.workspaceId, surfaceId: randomUUID(),
      sessionId: randomUUID(), generation: 1,
    }),
    outcome: index === 0 ? "unknown" : "not-attempted", attempted: index === 0,
    reason: index === 0 ? "confirmation_required" : "budget-exhausted", removal: "unconfirmed",
  }));
  const complete = { ok: true, scope: "subtree", results };
  assert.ok(Buffer.byteLength(JSON.stringify(complete)) < 65_536);
  const executable = path.join(f.root, "subtree-controller.mjs");
  const modeFile = path.join(f.root, "subtree-mode");
  const callsFile = path.join(f.root, "subtree-calls");
  await fs.writeFile(callsFile, "");
  await fs.writeFile(executable, `#!${process.execPath}
import { readFileSync, appendFileSync } from "node:fs";
if (process.argv.slice(2).join() !== "native-close") process.exit(3);
const request = JSON.parse(readFileSync(0, "utf8"));
if (Object.keys(request).sort().join() !== "identity,scope,target" || request.scope !== "subtree") process.exit(4);
const mode = readFileSync(${JSON.stringify(modeFile)}, "utf8");
appendFileSync(${JSON.stringify(callsFile)}, mode + "\\n");
if (mode === "complete") console.log(${JSON.stringify(JSON.stringify(complete))});
if (mode === "overflow") console.log(JSON.stringify({ ok: true, scope: "subtree", results: [], private: "x".repeat(70_000) }));
if (mode === "cancel") setTimeout(() => process.exit(5), 4000);
`, { mode: 0o700 });
  const abort = new AbortController();
  let close;
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true,
    expected: { ...own, controller: executable }, signal: abort.signal,
    joinSession: async ({ tools }) => {
      close = tools.find(tool => tool.name === "maestro_close").handler;
      return { sessionId: own.sessionId };
    },
  });
  t.after(() => adapter.close());
  for (const mode of ["complete", "overflow", "cancel"]) {
    await fs.writeFile(modeFile, mode);
    const pending = close({ target, scope: "subtree" }, { sessionId: own.sessionId });
    if (mode === "cancel") {
      const deadline = Date.now() + 2000;
      while (!(await fs.readFile(callsFile, "utf8")).endsWith("cancel\n")) {
        assert.ok(Date.now() < deadline, "synthetic subtree controller did not receive request");
        await delay(10);
      }
      abort.abort();
    }
    const output = await pending;
    if (mode === "complete") {
      assert.deepEqual(JSON.parse(output), complete);
      assert.ok(Buffer.byteLength(output) <= 65_536);
    } else {
      assert.equal(output.resultType, "failure");
      assert.match(output.textResultForLlm, /uncertain/);
      assert.match(output.textResultForLlm, /No fallback or retry.*removal is unconfirmed/);
      assert.equal(output.textResultForLlm.includes("private"), false);
      assert.equal(output.textResultForLlm.includes("xxxx"), false);
      assert.equal(output.textResultForLlm.includes("closeAccepted"), false);
    }
  }
  assert.equal(await fs.readFile(callsFile, "utf8"), "complete\noverflow\ncancel\n");
  assert.equal((await close({ target, scope: "subtree" }, { sessionId: own.sessionId })).resultType, "failure");
  assert.equal(await fs.readFile(callsFile, "utf8"), "complete\noverflow\ncancel\n");
  assert.deepEqual(f.sends, []);
});
