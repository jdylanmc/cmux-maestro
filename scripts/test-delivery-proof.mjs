// Contract tests with mocked Copilot sessions. These do not prove native UI behavior.
import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import net from "node:net";
import { EventEmitter, once } from "node:events";
import { execFileSync, spawn } from "node:child_process";
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

async function managedFixture(t, owners = [0, 0, 0, 1]) {
  const root = await fs.mkdtemp(path.join(base, "m61-"));
  const workspaces = new Map(owners.map((owner) => [owner, randomUUID()]));
  const bindings = owners.map((owner, index) => ({
    peer: index.toString(16).padStart(16, "0"), nodeId: randomUUID(), name: `Participant ${index}`,
    workspaceId: workspaces.get(owner),
    sessionId: randomUUID(), generation: 1, capability: (index % 16).toString(16).repeat(64),
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
  return { root, bindings, tools, sends, events, launch, environment, adapters };
}

const managedAddress = (binding) => ({ ...addr(binding), generation: binding.generation });

test("workspace peers and replies survive another workspace's 128 route/socket pairs", async (t) => {
  const f = await managedFixture(t, [...Array(128).fill(0), 1, 1]);
  for (const binding of f.bindings.slice(0, 128)) {
    const server = net.createServer((socket) => socket.destroy());
    server.listen(path.join(f.root, `${binding.peer}.sock`));
    await once(server, "listening");
    await fs.chmod(path.join(f.root, `${binding.peer}.sock`), 0o600);
    f.adapters.push({ close: () => new Promise((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve())) });
  }
  await f.launch(128);
  await f.launch(129);
  assert.equal((await fs.readdir(f.root)).length, 260);
  const response = await f.tools[128].maestro_peers({});
  assert.equal(typeof response, "string", "valid local peers must not fail from foreign workspace routes");
  const peers = JSON.parse(response);
  assert.deepEqual(peers, [{
    name: f.bindings[129].name, nodeId: f.bindings[129].nodeId,
    ...managedAddress(f.bindings[129]),
  }]);
  assert.equal(JSON.stringify(peers).includes(f.bindings[0].sessionId), false);
  for (const [sender, recipient] of [[128, 129], [129, 128]]) {
    const incoming = event(f.events, "send");
    assert.match(await f.tools[sender].maestro_send({
      destination: managedAddress(f.bindings[recipient]), body: "Only the local workspace",
    }), /unconfirmed/);
    await incoming;
    const envelope = JSON.parse(f.sends.at(-1).prompt.split("\n").slice(1).join("\n"));
    assert.deepEqual(envelope.sender, managedAddress(f.bindings[sender]));
    assert.deepEqual(envelope.destination, managedAddress(f.bindings[recipient]));
    assert.equal(f.sends.at(-1).index, recipient);
  }
  assert.equal(f.sends.length, 2);
  assert.equal((await f.tools[128].maestro_send({
    destination: managedAddress(f.bindings[0]), body: "No cross-workspace route",
  })).resultType, "failure");
  assert.equal(f.sends.length, 2);
});

test("managed route scan keeps separate workspace and host safety bounds", async (t) => {
  const local = await managedFixture(t, Array(129).fill(0));
  await local.launch(0);
  assert.equal((await local.tools[0].maestro_peers({})).resultType, "failure");
  const host = await managedFixture(t, Array.from({ length: 1025 }, (_, i) => Math.floor(i / 128)));
  await host.launch(0);
  assert.equal((await host.tools[0].maestro_peers({})).resultType, "failure");
  await fs.unlink(path.join(host.root, `${host.bindings[1024].peer}.json`));
  const response = await host.tools[0].maestro_peers({});
  assert.equal(typeof response, "string", "exact 1024-host bound must allow 128 local participants");
  const peers = JSON.parse(response);
  assert.equal(peers.length, 127);
  assert.ok(peers.every((peer) => peer.workspaceId === host.bindings[0].workspaceId));
  for (let index = (await fs.readdir(host.root)).length; index < 2049; index++) {
    await fs.writeFile(path.join(host.root, `unused-${index}`), "", { mode: 0o600 });
  }
  assert.equal((await host.tools[0].maestro_peers({})).resultType, "failure");
});

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
export async function joinSession(config) {
  if (process.env.FIXTURE_READINESS) {
    writeFileSync(process.env.FIXTURE_STAGE, JSON.stringify({
      options: Object.keys(config), tools: config.tools.map(tool => tool.name),
    }));
  }
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

test("actual native loader offers only readiness in an ordinary CMUX session", async (t) => {
  const f = await loaderFixture(t);
  const ordinary = f.launch({
    CMUX_MAESTRO_MESSAGE_ROOT: "", CMUX_MAESTRO_MESSAGE_PEER: "",
    CMUX_MAESTRO_WORKER_ID: "", CMUX_MAESTRO_GENERATION: "",
    CMUX_MAESTRO_EXECUTION_MODE: "", CMUX_MAESTRO_DIRECT_LAUNCH: "",
    CMUX_MAESTRO_LAUNCH_PID: "", CMUX_MAESTRO_ORCHESTRATOR: "",
    FIXTURE_READINESS: "1",
  });
  assert.deepEqual(await f.exited(ordinary), [0, null]);
  assert.ok(await f.exists(ordinary.stage), "Ordinary own-session extension must join for diagnostics");
  assert.deepEqual(JSON.parse(await fs.readFile(ordinary.stage, "utf8")), {
    options: ["tools"], tools: ["maestro_readiness"],
  });
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

test("native identity observes only its own current model when explicitly requested", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let tools;
  let modelQueries = 0;
  let login = "verified-parent";
  let snapshot = {
    modelId: "gpt-6.1-sol", contextTier: "long_context", reasoningEffort: "medium",
    planBaseModelId: "not-the-current-model", privateMetadata: "not-for-transmission",
  };
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async options => {
      tools = options.tools;
      return { sessionId: own.sessionId, rpc: {
        gitHubAuth: { getStatus: async () => ({
          isAuthenticated: true, host: "https://github.com", login,
        }) },
        model: { getCurrent: async () => { modelQueries++; return snapshot; } },
      } };
    },
  });
  t.after(() => adapter.close());
  const tool = tools.find(item => item.name === "maestro_identity");
  const invocation = { sessionId: own.sessionId };
  for (const args of [{}, { includeModel: false }]) {
    const result = await tool.handler(args, invocation);
    assert.equal(typeof result, "string");
    assert.deepEqual(JSON.parse(result), {
      nodeId: own.nodeId, ...managedAddress(own),
      account: { login, host: "https://github.com" },
    });
    assert.equal(modelQueries, 0);
  }
  assert.equal(tool.parameters.properties.includeModel.type, "boolean");
  const before = Date.now();
  const result = JSON.parse(await tool.handler({ includeModel: true }, invocation));
  const { observedAt, ...observation } = result.modelObservation;
  assert.deepEqual(observation, {
    status: "observed", source: "session-model-current",
    model: "gpt-6.1-sol", contextTier: "long_context", reasoningEffort: "medium",
  });
  assert.ok(Date.parse(observedAt) >= before && Date.parse(observedAt) <= Date.now());
  assert.equal(result.sessionId, own.sessionId);
  assert.equal(modelQueries, 1);
  assert.equal(JSON.stringify(result).includes("not-for-transmission"), false);
  assert.equal(JSON.stringify(result).includes("not-the-current-model"), false);
  assert.equal(JSON.stringify(result).includes(own.capability), false);

  snapshot = { modelId: "provider/custom", reasoningEffort: "ultra" };
  const next = JSON.parse(await tool.handler({ includeModel: true }, invocation)).modelObservation;
  assert.equal(next.model, "provider/custom");
  assert.equal(next.reasoningEffort, "ultra");
  assert.equal("contextTier" in next, false, "missing observations are not configured defaults");
  for (const args of [{ includeModel: "true" }, { includeModel: null },
    { includeModel: true, modelId: "forged" }]) {
    assert.equal((await tool.handler(args, invocation)).resultType, "failure");
  }
  assert.equal((await tool.handler({ includeModel: true },
    { sessionId: f.bindings[1].sessionId })).resultType, "failure");
  assert.equal(modelQueries, 2);
});

test("native identity reports model observation limits without inventing configured evidence", async (t) => {
  for (const [name, getter, reason] of [
    ["absent", undefined, "model-api-unavailable"],
    ["unsupported", async () => { throw Object.assign(new Error("private"), { code: -32601 }); },
      "model-api-unavailable"],
    ["failed", async () => { throw new Error("PRIVATE_MODEL_ERROR"); }, "model-api-failed"],
    ["unreported", async () => ({ reasoningEffort: "medium" }), "model-not-reported"],
    ["null", async () => null, "model-response-invalid"],
    ["unsafe-model", async () => ({ modelId: "bad\nmodel" }), "model-response-invalid"],
    ["unsafe-effort", async () => ({ modelId: "safe", reasoningEffort: [] }), "model-response-invalid"],
    ["unknown-tier", async () => ({ modelId: "safe", contextTier: "invented" }), "model-response-invalid"],
  ]) {
    await t.test(name, async t => {
      const f = await managedFixture(t);
      const own = f.bindings[0];
      let tools;
      const adapter = await start({
        root: f.root, peer: own.peer, managed: true, expected: own,
        joinSession: async options => {
          tools = options.tools;
          return { sessionId: own.sessionId, rpc: {
            gitHubAuth: { getStatus: async () => ({
              isAuthenticated: true, host: "https://github.com", login: "verified-parent",
            }) }, model: { getCurrent: getter },
          } };
        },
      });
      t.after(() => adapter.close());
      const response = await tools.find(item => item.name === "maestro_identity")
        .handler({ includeModel: true }, { sessionId: own.sessionId });
      assert.equal(typeof response, "string", "optional model failure must preserve verified identity");
      const result = JSON.parse(response);
      assert.deepEqual(result.modelObservation, { status: "unavailable", reason });
      assert.equal(result.account.login, "verified-parent");
      assert.equal(JSON.stringify(result).includes("PRIVATE_MODEL_ERROR"), false);
    });
  }
});

test("native identity refuses account drift across its optional model observation", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let tools;
  let login = "before";
  let modelQueries = 0;
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async options => {
      tools = options.tools;
      return { sessionId: own.sessionId, rpc: {
        gitHubAuth: { getStatus: async () => ({
          isAuthenticated: true, host: "https://github.com", login,
        }) },
        model: { getCurrent: async () => {
          modelQueries++;
          login = "after";
          return { modelId: "safe" };
        } },
      } };
    },
  });
  t.after(() => adapter.close());
  const result = await tools.find(item => item.name === "maestro_identity")
    .handler({ includeModel: true }, { sessionId: own.sessionId });
  assert.equal(result.resultType, "failure");
  assert.equal("modelObservation" in result, false);
  assert.equal(modelQueries, 1);
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

test("native spawn carries optional caller launch preferences without changing omission or account identity", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  const requests = [];
  let modelQueries = 0;
  let tools;
  const receipt = { ok: true, launchAccepted: true, startup: "pending" };
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async options => {
      tools = options.tools;
      return {
        sessionId: own.sessionId,
        rpc: { gitHubAuth: { getStatus: async () => ({
          isAuthenticated: true, host: "https://github.com", login: "verified-parent",
        }) }, model: { list: async () => {
          modelQueries++;
          return { list: [{
            id: "gpt-6.1-sol", name: "Fixture selected model",
            capabilities: { supports: { reasoningEffort: true }, limits: {} },
            supportedContextTiers: ["default", "long_context"],
            supportedReasoningEfforts: ["medium", "high"], defaultReasoningEffort: "medium",
            metadata: { privateFixture: "not-for-transmission" },
          }], quotaSnapshots: { fixture: "not-for-transmission" } };
        } } },
      };
    },
    launch: async request => { requests.push(request); return receipt; },
  });
  t.after(() => adapter.close());
  const spawn = tools.find(tool => tool.name === "maestro_spawn").handler;
  const assignment = { name: "Child", cwd: "/synthetic", task: "Bounded task" };
  const invocation = { sessionId: own.sessionId };
  assert.deepEqual(JSON.parse(await spawn(assignment, invocation)), receipt);
  assert.deepEqual(requests[0].assignment, assignment);
  assert.equal(modelQueries, 0);
  assert.equal("launchCapabilities" in requests[0], false);
  const selected = {
    ...assignment, model: "gpt-6.1-sol", contextTier: "long_context", reasoningEffort: "medium",
  };
  const result = await spawn(selected, invocation);
  assert.equal(typeof result, "string", "supported optional inputs must reach the controller");
  assert.deepEqual(JSON.parse(result), receipt);
  assert.deepEqual(requests[1].assignment, selected);
  assert.equal(requests[1].identity.login, "verified-parent");
  assert.equal(modelQueries, 1);
  assert.deepEqual(requests[1].launchCapabilities, {
    version: 1, sessionId: own.sessionId,
    account: { login: "verified-parent", host: "https://github.com" },
    source: "session-model-list",
    models: [{
      id: "gpt-6.1-sol", contextTiers: ["default", "long_context"],
      reasoningEfforts: ["medium", "high"], defaultReasoningEffort: "medium",
    }],
  });
  assert.equal(JSON.stringify(requests[1]).includes("not-for-transmission"), false);
  assert.equal(result.includes(own.capability), false);
  assert.equal((await spawn({ ...selected, login: "injected" }, invocation)).resultType, "failure");
  assert.equal(requests.length, 2);
});

test("native preference API absence forwards unavailable evidence and preserves visible fallback warning", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let tools;
  let request;
  const receipt = {
    ok: true, launchAccepted: true,
    warnings: ["Capability verification unavailable; configured defaults retained."],
  };
  const adapter = await start({
    root: f.root, peer: own.peer, managed: true, expected: own,
    joinSession: async options => {
      tools = options.tools;
      return { sessionId: own.sessionId, rpc: { gitHubAuth: { getStatus: async () => ({
        isAuthenticated: true, host: "https://github.com", login: "verified-parent",
      }) } } };
    },
    launch: async value => { request = value; return receipt; },
  });
  t.after(() => adapter.close());
  const result = await tools.find(tool => tool.name === "maestro_spawn").handler({
    name: "Child", cwd: "/synthetic", task: "Bounded", model: "gpt-6.1-sol",
  }, { sessionId: own.sessionId });
  assert.equal(typeof result, "string");
  assert.deepEqual(JSON.parse(result), receipt);
  assert.deepEqual(request.launchCapabilities, {
    version: 1, sessionId: own.sessionId,
    account: { login: "verified-parent", host: "https://github.com" },
    source: "unavailable", models: [],
  });
});

test("native model metadata errors and account drift refuse without a launch or fallback", async (t) => {
  for (const scenario of ["malformed", "duplicate", "account-drift", "forged-evidence"]) {
    await t.test(scenario, async (t) => {
      const f = await managedFixture(t);
      const own = f.bindings[0];
      let tools;
      let reads = 0;
      let queries = 0;
      let launches = 0;
      const model = {
        id: "gpt-6.1-sol", name: "Fixture",
        capabilities: { supports: { reasoningEffort: true }, limits: {} },
        supportedContextTiers: ["default"], supportedReasoningEfforts: ["medium"],
        defaultReasoningEffort: "medium",
      };
      const adapter = await start({
        root: f.root, peer: own.peer, managed: true, expected: own,
        joinSession: async options => {
          tools = options.tools;
          return { sessionId: own.sessionId, rpc: {
            gitHubAuth: { getStatus: async () => ({
              isAuthenticated: true, host: "https://github.com",
              login: scenario === "account-drift" && ++reads > 1 ? "changed-parent" : "verified-parent",
            }) },
            model: { list: async () => {
              queries++;
              return scenario === "malformed" ? { list: "invalid" } :
                { list: scenario === "duplicate" ? [model, model] : [model] };
            } },
          } };
        },
        launch: async () => { launches++; return { ok: true }; },
      });
      t.after(() => adapter.close());
      const selected = { name: "Child", cwd: "/synthetic", task: "Bounded", model: "gpt-6.1-sol" };
      if (scenario === "forged-evidence") selected.launchCapabilities = { source: "session-model-list" };
      const result = await tools.find(tool => tool.name === "maestro_spawn").handler(
        selected, { sessionId: own.sessionId },
      );
      assert.equal(result.resultType, "failure");
      assert.equal(launches, 0);
      assert.equal(queries, scenario === "forged-evidence" ? 0 : 1);
    });
  }
});

test("native model projection keeps valid provider-native defaults from poisoning known selection", async (t) => {
  for (const providerDefault of [undefined, "ultra", "max"]) {
    await t.test(providerDefault ?? "no-default", async (t) => {
      const f = await managedFixture(t);
      const own = f.bindings[0];
      let tools;
      const requests = [];
      const custom = {
        id: "provider/custom", name: "Fixture custom provider",
        capabilities: { supports: { reasoningEffort: true }, limits: {} },
        supportedContextTiers: ["default"], supportedReasoningEfforts: ["ultra"],
      };
      if (providerDefault !== undefined) custom.defaultReasoningEffort = providerDefault;
      const adapter = await start({
        root: f.root, peer: own.peer, managed: true, expected: own,
        joinSession: async options => {
          tools = options.tools;
          return { sessionId: own.sessionId, rpc: {
            gitHubAuth: { getStatus: async () => ({
              isAuthenticated: true, host: "https://github.com", login: "verified-parent",
            }) },
            model: { list: async () => ({ list: [{
              id: "gpt-6.1-sol", name: "Fixture known model",
              capabilities: { supports: { reasoningEffort: true }, limits: {} },
              supportedContextTiers: ["default", "long_context"],
              supportedReasoningEfforts: ["medium"], defaultReasoningEffort: "medium",
            }, custom] }) },
          } };
        },
        launch: async request => { requests.push(request); return { ok: true, launchAccepted: true }; },
      });
      t.after(() => adapter.close());
      const result = await tools.find(tool => tool.name === "maestro_spawn").handler({
        name: "Known selected", cwd: "/synthetic", task: "Bounded", model: "gpt-6.1-sol",
        contextTier: "long_context", reasoningEffort: "medium",
      }, { sessionId: own.sessionId });
      if (providerDefault === "max") {
        assert.equal(result.resultType, "failure");
        assert.equal(requests.length, 0);
      } else {
        assert.equal(typeof result, "string");
        assert.equal(JSON.parse(result).launchAccepted, true);
        assert.equal(requests.length, 1);
        assert.deepEqual(requests[0].launchCapabilities.models[1], {
          id: "provider/custom", contextTiers: ["default"], reasoningEfforts: [],
        });
        assert.equal(JSON.stringify(requests[0]).includes("ultra"), false);
      }
    });
  }
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

test("native close rejects unrepresentable captured generations before effects through the actual adapter roundtrip", async (t) => {
  for (const generation of ["9007199254740991", "9007199254740992", "9007199254740993", "1" + "0".repeat(400)]) {
    await t.test(`captured generation ${generation.length === 16 ? generation : "10**400"}`, async (t) => {
      const packet = JSON.parse(execFileSync("python3", ["-B", "-c", `
import io,json,runpy,sys
from contextlib import redirect_stdout,redirect_stderr
module=runpy.run_path(sys.argv[1])
fixture=module["NativeCloseTests"]()
fixture.setUp()
try:
    fixture.state["nodes"].pop(fixture.grandchild["id"])
    child=fixture.add_close_descendant(fixture.child,12347)
    child["generation"]=int(sys.argv[2])
    fixture.persist()
    fixture.cmux.workspace_surfaces.return_value.add(child["surfaceId"])
    fixture.cmux.run.side_effect=lambda *args,**kwargs:json.loads(args[2])
    before={str(p):p.read_bytes() for p in fixture.home.rglob("*") if p.is_file()}
    stdout,stderr=io.StringIO(),io.StringIO()
    with redirect_stdout(stdout),redirect_stderr(stderr):
        code=fixture.invoke({"identity":fixture.identity,"target":fixture.target,"scope":"subtree"},cli=True)
    after={str(p):p.read_bytes() for p in fixture.home.rglob("*") if p.is_file()}
    print(json.dumps({"code":code,"stdout":stdout.getvalue(),"stderr":stderr.getvalue(),
        "target":fixture.target,"effects":fixture.cmux.run.call_count,"unchanged":before==after}))
finally:
    fixture.doCleanups()
`, fileURLToPath(new URL("./test-delivery-proof.py", import.meta.url)), generation], {
        encoding: "utf8", timeout: 15_000, maxBuffer: 1_048_576,
      }));
      const f = await managedFixture(t);
      const own = { ...f.bindings[0], workspaceId: packet.target.workspaceId };
      await fs.writeFile(path.join(f.root, `${own.peer}.json`), JSON.stringify(own), { mode: 0o600 });
      const packetFile = path.join(f.root, "controller-packet.json");
      const executable = path.join(f.root, "generation-controller.mjs");
      await fs.writeFile(packetFile, JSON.stringify(packet), { mode: 0o600 });
      await fs.writeFile(executable, `#!${process.execPath}
import { readFileSync } from "node:fs";
const request=JSON.parse(readFileSync(0,"utf8"));
if(process.argv.slice(2).join()!=="native-close" || request.scope!=="subtree") process.exit(4);
const packet=JSON.parse(readFileSync(${JSON.stringify(packetFile)},"utf8"));
process.stdout.write(packet.stdout);
process.stderr.write(packet.stderr);
process.exitCode=packet.code;
`, { mode: 0o700 });
      let close;
      const adapter = await start({
        root: f.root, peer: own.peer, managed: true, expected: { ...own, controller: executable },
        joinSession: async ({ tools }) => {
          close = tools.find(tool => tool.name === "maestro_close").handler;
          return { sessionId: own.sessionId };
        },
      });
      t.after(() => adapter.close());

      const output = await close({ target: packet.target, scope: "subtree" }, { sessionId: own.sessionId });

      if (generation === "9007199254740991") {
        assert.equal(packet.effects, 2);
        assert.equal(packet.unchanged, true);
        assert.equal(packet.code, 0);
        const receipt = JSON.parse(output);
        assert.equal(receipt.results.length, 2);
        assert.equal(String(receipt.results[0].generation), generation);
        assert.deepEqual(receipt.results.map(item => item.outcome), ["accepted", "accepted"]);
        assert.ok(receipt.results.every(item => item.attempted && item.removal === "unconfirmed"));
        return;
      }
      assert.equal(packet.effects, 0,
        `exact numeric identities must be representable before any host effect; actual adapter reply: ${
          typeof output === "string" ? output : JSON.stringify(output)}`);
      assert.equal(packet.unchanged, true);
      assert.equal(packet.code, 2);
      assert.equal(packet.stdout, "");
      assert.equal(output.resultType, "failure");
      assert.match(output.textResultForLlm, /No fallback or retry.*removal is unconfirmed/);
      assert.ok(Buffer.byteLength(output.textResultForLlm) <= 65_536);
      assert.equal(output.textResultForLlm.includes("closeAccepted"), false);
      assert.deepEqual(f.sends, []);
    });
  }
});
