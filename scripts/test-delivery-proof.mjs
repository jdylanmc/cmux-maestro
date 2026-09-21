// Contract tests with mocked Copilot sessions. These do not prove native UI behavior.
import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import net from "node:net";
import { EventEmitter, once } from "node:events";
import { start, validateSend } from "./delivery-proof/adapter.mjs";

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
