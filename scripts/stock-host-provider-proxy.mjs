// One-shot hosted fault boundary. All provider operations run in the official CLI.
import fs from "node:fs";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

const [configPath, ...args] = process.argv.slice(2);
if (process.env.GITHUB_ACTIONS !== "true" || process.env.RUNNER_ENVIRONMENT !== "github-hosted") {
  throw new Error("Hosted-only provider fault fixture");
}
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
if (config.home !== "/Users/runner" || process.getuid() !== config.uid) {
  throw new Error("Wrong provider fixture owner");
}
const environment = { ...process.env };
for (const key of ["GITHUB_TOKEN", "GH_TOKEN", "COPILOT_GITHUB_TOKEN"]) delete environment[key];
const child = spawn(config.executable, ["--no-auto-login", ...args], {
  env: environment, stdio: args.includes("--headless") ? ["pipe", "pipe", "inherit"] : "inherit",
});
child.on("error", error => { console.error(error.message); process.exitCode = 98; });
let injected = false;
child.on("close", code => process.exit(injected ? 9 : (code ?? 97)));
if (args.includes("--headless")) {
  process.stdin.pipe(child.stdin);
  child.stdin.on("error", error => {
    if (error.code !== "EPIPE") { console.error(error.message); process.exitCode = 98; }
  });
  let buffer = Buffer.alloc(0);
  const hash = path => crypto.createHash("sha256").update(fs.readFileSync(path)).digest("hex");
  child.stdout.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length > 262144) throw new Error("Provider output exceeds bound");
    while (true) {
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const header = buffer.subarray(0, end).toString();
      const match = /^Content-Length: ([0-9]+)$/.exec(header);
      if (!match || end > 1024) throw new Error("Invalid provider frame");
      const length = Number(match[1]);
      if (length < 1 || length > 262144) throw new Error("Invalid provider frame length");
      const total = end + 4 + length;
      if (buffer.length < total) return;
      const frame = buffer.subarray(0, total);
      const response = JSON.parse(buffer.subarray(end + 4, total));
      buffer = buffer.subarray(total);
      if (!injected && process.env.HOME === config.home && fs.existsSync(config.arm)
          && response.id === 2 && Array.isArray(response.result?.hooks)
          && hash(config.installedExtension) === config.candidateExtensionSHA256
          && hash(config.installedAdapter) === config.candidateAdapterSHA256) {
        fs.renameSync(config.arm, config.arm + ".consumed");
        fs.writeFileSync(config.evidence, JSON.stringify({
          phase: "real hooks.discover response after app/resource publication",
          childPID: child.pid, actualResponseSHA256: crypto.createHash("sha256").update(frame).digest("hex"),
          installedExtensionSHA256: hash(config.installedExtension),
          installedAdapterSHA256: hash(config.installedAdapter),
        }, null, 2), { mode: 0o600, flag: "wx" });
        const body = Buffer.from(JSON.stringify({
          jsonrpc: "2.0", id: response.id,
          error: { code: -32099, message: "One-shot hosted late-verification fault" },
        }));
        process.stdout.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
        injected = true;
        process.stdin.unpipe(child.stdin);
        child.stdin.end();
      } else {
        process.stdout.write(frame);
      }
    }
  });
}
