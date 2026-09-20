import { open, lstat } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { join, parse } from "node:path";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const maximum = 65536;

export async function privateFile(path, limit) {
    let current = parse(path).root;
    for (const component of path.slice(current.length).split("/").slice(0, -1)) {
        current = join(current, component);
        const info = await lstat(current);
        if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("Unsafe bridge path.");
    }
    const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const info = await handle.stat();
        if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o077)
            || info.size <= 0 || info.size > limit) throw new Error("Unsafe bridge file.");
        const data = Buffer.alloc(limit + 1);
        const { bytesRead } = await handle.read(data, 0, data.length, 0);
        const after = await handle.stat();
        const entry = await lstat(path);
        const stamp = value => JSON.stringify([
            value.dev, value.ino, value.uid, value.mode, value.size, value.mtimeMs, value.ctimeMs,
        ]);
        if (bytesRead !== info.size || stamp(after) !== stamp(info)
            || stamp(entry) !== stamp(info)) throw new Error("Bridge file changed.");
        return JSON.parse(data.subarray(0, bytesRead).toString("utf8"));
    } finally {
        await handle.close();
    }
}

export function controllerTransport(controller) {
    return (request) => new Promise((resolve, reject) => {
        const payload = JSON.stringify(request);
        if (Buffer.byteLength(payload) > 16384) return reject(new Error("Bridge request too large."));
        // Never put credentials or message bodies in argv, diagnostics, or observer metadata.
        const child = spawn("/usr/bin/python3", [controller, "native-bridge"], {
            stdio: ["pipe", "pipe", "ignore"],
            env: { HOME: homedir(), PATH: "/usr/bin:/bin" },
        });
        let output = Buffer.alloc(0);
        let settled = false;
        const finish = (error, result) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            error ? reject(error) : resolve(result);
        };
        // Do not kill a process; close our pipes and surface uncertain delivery.
        const timer = setTimeout(() => {
            child.stdin.destroy();
            child.stdout.destroy();
            finish(new Error("Bridge operation timed out."));
        }, 5000);
        child.on("error", () => finish(new Error("Bridge controller unavailable.")));
        child.stdin.on("error", () => finish(new Error("Bridge request was not accepted.")));
        child.stdout.on("data", data => {
            if (output.length + data.length > maximum) {
                child.stdout.destroy();
                finish(new Error("Bridge response too large."));
            } else output = Buffer.concat([output, data]);
        });
        child.on("close", code => {
            if (settled) return;
            try {
                const result = JSON.parse(output.toString("utf8"));
                if (code !== 0 || result.ok !== true) throw new Error();
                finish(null, result);
            } catch {
                finish(new Error("Bridge authentication or operation failed."));
            }
        });
        child.stdin.end(payload);
    });
}

export async function bootstrap(environment = process.env) {
    const expected = environment.CMUX_MAESTRO_NATIVE_SESSION;
    if (!expected || !uuid.test(expected) || environment.SESSION_ID !== expected) return null;
    const root = join(homedir(), "Library/Application Support/CMUXMaestroPreview/Orchestration");
    const setup = await privateFile(join(root, "native-setup.json"), 4096);
    if (setup.version !== 1) throw new Error("Native setup version is unsupported.");
    const ticket = await privateFile(join(root, "control", `native-bridge-${expected}.json`), 4096);
    if (ticket.version !== 1 || ticket.identity?.sessionId !== expected
        || !uuid.test(ticket.identity?.nodeId) || !uuid.test(ticket.identity?.runId)
        || !Number.isSafeInteger(ticket.identity?.generation) || ticket.identity.generation < 1
        || !/^[a-f0-9]{64}$/.test(ticket.credential)) throw new Error("Bridge identity is invalid.");
    return { ticket, transport: controllerTransport(join(root, "bin", "cmux-maestro-orchestrator")) };
}

export async function attachAdapter({ ticket, transport, joinSession, registration = randomUUID() }) {
    if (ticket.version !== 1 || !uuid.test(registration)) throw new Error("Unsupported adapter version.");
    const request = (operation, fields = {}) => transport({
        version: 1, operation, identity: ticket.identity, credential: ticket.credential,
        registration, ...fields,
    });
    // Ownership, opt-in, scoped credential, generation and lifetime are verified BEFORE SDK join.
    const deadline = Date.now() + 5000;
    while (true) {
        const registrationResult = await request("register");
        if (registrationResult.status !== "starting") break;
        if (Date.now() >= deadline) throw new Error("Provider identity binding did not finish.");
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    let closed = false;
    let polling = false;
    let timer;
    const tool = (name, operation, description, reply = false) => ({
        name, description,
        parameters: {
            type: "object", properties: {
                messageId: { type: "string", format: "uuid" },
                ...(reply ? { body: { type: "string", minLength: 1, maxLength: 4096 } } : {}),
            },
            required: reply ? ["messageId", "body"] : ["messageId"], additionalProperties: false,
        },
        handler: async args => {
            if (closed || !args || !uuid.test(args.messageId)
                || Object.keys(args).some(key => !["messageId", ...(reply ? ["body"] : [])].includes(key))
                || (reply && (typeof args.body !== "string" || !args.body.length
                    || Buffer.byteLength(args.body) > 4096))) throw new Error("Invalid explicit message response.");
            const result = await request(operation, args);
            return { textResultForLlm: JSON.stringify({ messageId: result.message.id, state: result.message.state }),
                resultType: "success" };
        },
    });
    let session;
    try {
        session = await joinSession({ tools: [
            tool("maestro_acknowledge", "acknowledge", "Explicitly acknowledge receipt of one Maestro message. Not task completion."),
            tool("maestro_reply", "reply", "Send one explicit bounded reply to the owning coordinator. State task outcome in the body.", true),
        ] });
        if (session.sessionId !== ticket.identity.sessionId) throw new Error("Joined session identity changed.");
        await request("ready");
    } catch (error) {
        closed = true;
        await request("close");
        throw error;
    }
    const poll = async () => {
        if (closed || polling) return;
        polling = true;
        try {
            const { message } = await request("poll");
            if (!message) return;
            if (!uuid.test(message.id) || typeof message.body !== "string"
                || !message.body.length || Buffer.byteLength(message.body) > 4096
                || !Number.isFinite(Date.parse(message.expiresAt))) throw new Error("Invalid bounded message.");
            if (JSON.stringify(message.receiver) !== JSON.stringify(ticket.identity)) {
                // Compare fields rather than relying on source text or terminal provenance.
                for (const key of ["nodeId", "sessionId", "generation", "runId"]) {
                    if (message.receiver?.[key] !== ticket.identity[key]) throw new Error("Stale delivery identity.");
                }
            }
            if (Date.now() >= Date.parse(message.expiresAt)) {
                await request("expired", { messageId: message.id });
                return;
            }
            const prompt = `[Maestro message ${message.id}; explicit acknowledgement/reply available]\n${message.body}`;
            let sendTimer;
            try {
                const providerMessageId = await Promise.race([
                    session.send({
                        prompt, mode: "enqueue",
                        source: message.sender.sessionId
                            ? `agent-${message.sender.sessionId}`
                            : `agent-maestro-controller-${message.sender.nodeId}`,
                    }),
                    new Promise((_, reject) => {
                        sendTimer = setTimeout(() => reject(new Error("Provider acceptance is uncertain.")), 15000);
                    }),
                ]);
                await request("delivered", { messageId: message.id, providerMessageId });
            } catch {
                // Never retry session.send: its acceptance may have happened before the connection failed.
                await request("unknown", { messageId: message.id });
            } finally {
                clearTimeout(sendTimer);
            }
        } finally {
            polling = false;
        }
    };
    return {
        poll,
        start(onFailure) {
            const tick = async () => {
                try {
                    await poll();
                    if (!closed) timer = setTimeout(tick, 1000);
                } catch {
                    closed = true; // Fail closed; do not log message contents or credentials.
                    process.stderr.write("Maestro native bridge disconnected; delivery may be uncertain. No send was retried.\n");
                    onFailure?.();
                }
            };
            void tick();
        },
        async close() {
            closed = true;
            clearTimeout(timer);
            await request("close");
        },
    };
}
