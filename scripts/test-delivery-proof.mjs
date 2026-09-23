// Contract tests with mocked Copilot sessions. These do not prove native UI behavior.
import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import net from "node:net";
import { EventEmitter, once } from "node:events";
import { start, startManaged, validateSend } from "./delivery-proof/adapter.mjs";

const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const base = path.join(repo, ".build", "dp");

async function fixture(t) {
  await fs.mkdir(base, { recursive: true, mode: 0o700 });
  const root = path.join(base, randomUUID().slice(0, 8));
  await fs.mkdir(root, { mode: 0o700 });
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
  const root = path.join(repo, ".build", randomUUID().slice(0, 5));
  await fs.mkdir(root, { mode: 0o700 });
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
  assert.deepEqual(Object.keys(f.tools[0]), ["maestro_peers", "maestro_send", "maestro_identity", "maestro_spawn"]);
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

test("native launch reads the invoking session account on each request, not task-supplied identity", async (t) => {
  const f = await managedFixture(t);
  const own = f.bindings[0];
  let tools;
  let login = "parent-a";
  const requests = [];
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
      return { ok: true, workerId: "synthetic-worker", supervisorStarted: true };
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
    assert.equal(JSON.parse(result).ok, true);
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
