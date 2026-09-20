import test from "node:test";
import assert from "node:assert/strict";
import { attachAdapter, bootstrap, privateFile } from "../Resources/native-messaging/adapter.mjs";
import { mkdir, writeFile, chmod, symlink, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const id = "11111111-1111-4111-8111-111111111111";
const messageId = "22222222-2222-4222-8222-222222222222";
const identity = { nodeId: id, sessionId: id, generation: 1, runId: id };
const ticket = { version: 1, identity, credential: "b".repeat(64) };

test("bootstrap private file reader rejects public mode, symlinks and oversized data", async () => {
    const root = new URL(`../.build/adapter-files-${randomUUID()}/`, import.meta.url);
    const file = new URL("binding.json", root);
    const linked = new URL("linked.json", root);
    await mkdir(root, { recursive: true, mode: 0o700 });
    try {
        await writeFile(file, '{"synthetic":true}', { mode: 0o600 });
        assert.deepEqual(await privateFile(fileURLToPath(file), 128), { synthetic: true });
        await chmod(file, 0o644);
        await assert.rejects(privateFile(fileURLToPath(file), 128));
        await chmod(file, 0o600);
        await symlink(fileURLToPath(file), linked);
        await assert.rejects(privateFile(fileURLToPath(linked), 128));
        await assert.rejects(privateFile(fileURLToPath(file), 4));
    } finally {
        await rm(root, { recursive: true });
    }
});

test("unopted and replaced sessions are inert before filesystem or SDK access", async () => {
    assert.equal(await bootstrap({}), null);
    assert.equal(await bootstrap({ CMUX_MAESTRO_NATIVE_SESSION: id, SESSION_ID: messageId }), null);
});

test("authentication failure occurs before join and tool registration", async () => {
    let joined = false;
    await assert.rejects(attachAdapter({
        ticket, transport: async () => { throw new Error("unauthorized"); },
        joinSession: async () => { joined = true; },
    }));
    assert.equal(joined, false);
});

test("supported SDK sends once, acknowledges explicitly, never scrapes events", async () => {
    const operations = [];
    const sends = [];
    let tools;
    const adapter = await attachAdapter({
        ticket,
        transport: async request => {
            operations.push(request.operation);
            if (request.operation === "poll") return { message: {
                id: messageId, receiver: identity, sender: identity, body: "bounded task",
                expiresAt: new Date(Date.now() + 60000).toISOString(),
            } };
            return { message: { id: messageId, state: "acknowledged" } };
        },
        joinSession: async config => {
            tools = config.tools;
            assert.deepEqual(Object.keys(config), ["tools"]);
            return { sessionId: id, send: async options => { sends.push(options); return "accepted-id"; } };
        },
    });
    await adapter.poll();
    assert.equal(sends.length, 1);
    assert.equal(sends[0].mode, "enqueue");
    assert.ok(sends[0].prompt.endsWith("bounded task"));
    assert.deepEqual(operations, ["register", "ready", "poll", "delivered"]);
    await tools[0].handler({ messageId });
    assert.equal(operations.at(-1), "acknowledge");
    await assert.rejects(tools[1].handler({ messageId, body: "🟢".repeat(1025) }));
    await adapter.close();
});

test("lost provider response is unknown and never blindly retried", async () => {
    let sends = 0;
    const operations = [];
    const adapter = await attachAdapter({
        ticket,
        transport: async request => {
            operations.push(request.operation);
            return { message: request.operation === "poll" && sends === 0
                ? { id: messageId, receiver: identity, sender: identity, body: "bounded",
                    expiresAt: new Date(Date.now() + 60000).toISOString() } : null };
        },
        joinSession: async () => ({
            sessionId: id, send: async () => { sends++; throw new Error("lost response"); },
        }),
    });
    await adapter.poll();
    await adapter.poll();
    assert.equal(sends, 1);
    assert.deepEqual(operations, ["register", "ready", "poll", "unknown", "poll"]);
    await adapter.close();
});

test("foreground replacement fails closed", async () => {
    const operations = [];
    await assert.rejects(attachAdapter({
        ticket,
        transport: async request => { operations.push(request.operation); return {}; },
        joinSession: async () => ({ sessionId: messageId }),
    }));
    assert.deepEqual(operations, ["register", "close"]);
});

test("expired offer does not enter the provider and invalid receiver never sends", async () => {
    for (const staleIdentity of [false, true]) {
        let sends = 0;
        const operations = [];
        const adapter = await attachAdapter({
            ticket,
            transport: async request => {
                operations.push(request.operation);
                return { message: {
                    id: messageId, receiver: staleIdentity ? { ...identity, generation: 2 } : identity,
                    sender: identity, body: "expired", expiresAt: new Date(0).toISOString(),
                } };
            },
            joinSession: async () => ({ sessionId: id, send: async () => { sends++; } }),
        });
        if (staleIdentity) await assert.rejects(adapter.poll());
        else await adapter.poll();
        assert.equal(sends, 0);
        assert.equal(operations.includes("expired"), !staleIdentity);
        await adapter.close();
    }
});
