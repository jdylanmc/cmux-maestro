// Re-check scripts/test-fixtures/beats-cron-cases.json `copilotNextRuns` against an installed Copilot
// runtime, so the recorded oracle can be refreshed when Copilot's scheduler changes. Not run in CI.
//
//   node scripts/check-copilot-cron-oracle.mjs <path to Copilot's runtime.node> [cron ...]
//
// With crons, prints their recorded next runs as JSON cases to add to the fixture.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

const [runtimePath, ...extra] = process.argv.slice(2);
if (!runtimePath) {
  console.error("Usage: node scripts/check-copilot-cron-oracle.mjs <runtime.node> [cron ...]");
  process.exit(2);
}
const runtime = createRequire(import.meta.url)(runtimePath);
const fixture = JSON.parse(readFileSync(new URL("./test-fixtures/beats-cron-cases.json", import.meta.url)));
const { timeZone, from, cases } = fixture.copilotNextRuns;
const local = (ms) => {
  const part = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date(ms)).map(({ type, value }) => [type, value]));
  return `${part.year}-${part.month}-${part.day} ${part.hour}:${part.minute}`;
};
// `from` is local wall time in `timeZone`; find its instant by scanning the surrounding day.
const [day, clock] = from.split(" ");
let start = Date.parse(`${day}T${clock}:00Z`) - 14 * 3600_000;
while (local(start) !== from) start += 60_000;
const record = (cron, count) => {
  const next = [];
  for (let at = start; next.length < count;) {
    const run = Number(runtime.scheduleNextCronRun(cron, timeZone, at));
    if (!Number.isFinite(run)) throw new Error(`Copilot rejects ${cron}`);
    next.push(local(run));
    at = run + 1;
  }
  return next;
};
if (extra.length) {
  console.log(JSON.stringify(extra.map((cron) => ({ cron, next: record(cron, 8) })), null, 1));
} else {
  const drift = cases.filter(({ cron, next }) => JSON.stringify(record(cron, next.length)) !== JSON.stringify(next));
  for (const { cron } of drift) console.error(`Drift: ${cron}`);
  console.log(drift.length ? `${drift.length} of ${cases.length} cases drifted.` : `All ${cases.length} cases match.`);
  process.exit(drift.length ? 1 : 0);
}
