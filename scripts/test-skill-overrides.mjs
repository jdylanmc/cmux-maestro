import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { checkOverrides, skillFolderHash } from "./check-skill-overrides.mjs";

const script = join(dirname(fileURLToPath(import.meta.url)), "check-skill-overrides.mjs");

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "maestro-skill-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  async function write(path, contents) {
    await mkdir(dirname(join(root, path)), { recursive: true });
    await writeFile(join(root, path), contents);
  }
  const skill = join(root, ".agents/skills/example");
  await write(".agents/skills/example/SKILL.md", "# Skill\n[State](../../../docs/state.md#pr-states)\n");
  await write("docs/state.md", "# Policy\n\n## PR states\n\n## Ready\n\n## Ready\n");
  await write(".agents/skill-overrides.json", JSON.stringify({
    skills: ["example"], links: ["docs/state.md#pr-states"],
  }));
  await write("skills-lock.json", JSON.stringify({
    version: 1, skills: { example: { computedHash: await skillFolderHash(skill) } },
  }));
  await mkdir(join(root, "scripts"));
  await copyFile(script, join(root, "scripts/check-skill-overrides.mjs"));
  execFileSync("git", ["init", "--quiet", root]);
  function track() { execFileSync("git", ["-C", root, "add", "."]); }
  track();
  return { root, skill, write, track };
}

test("canonical digest uses path order and raw bytes, excluding dependency internals", async (t) => {
  const f = await fixture(t);
  await f.write(".agents/skills/example/SKILL.md", "# Skill\n");
  await f.write(".agents/skills/example/guide.md", "# Guide\n");
  await f.write(".agents/skills/example/node_modules/ignored", "not skill content");
  await f.write(".agents/skills/example/.git/ignored", "not skill content");
  assert.equal(await skillFolderHash(f.skill),
    "a7d03e437c3f2d958354ad355688d3b9609ed37110b4b99b49d06882efccc19a");
});

test("checks manifest anchors and inbound multiline links, including duplicate headings", async (t) => {
  const f = await fixture(t);
  await f.write("README.md", "[Review\nstate](docs/state.md#ready-1)\n");
  f.track();
  assert.deepEqual(await checkOverrides(f.root), { skills: 1, links: 3 });
});

test("CI command succeeds, then exits nonzero after an unlocked skill edit", async (t) => {
  const f = await fixture(t);
  const command = join(f.root, "scripts/check-skill-overrides.mjs");
  const initial = spawnSync(process.execPath, [command], { encoding: "utf8" });
  assert.equal(initial.status, 0, initial.stderr);
  assert.match(initial.stdout, /Verified 1 local skill hashes and 2 policy links/);
  await f.write(".agents/skills/example/SKILL.md", "# Changed without lock update\n");
  const result = spawnSync(process.execPath, [command], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Skill hash drift: example/);
});

test("CI command rejects a renamed policy heading without a skill-content change", async (t) => {
  const f = await fixture(t);
  await f.write("docs/state.md", "# Policy\n\n## Renamed\n");
  const result = spawnSync(process.execPath, [join(f.root, "scripts/check-skill-overrides.mjs")],
    { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Missing policy anchor: docs\/state.md#pr-states/);
});

test("rejects a broken incoming anchor even when the declared anchor still exists", async (t) => {
  const f = await fixture(t);
  await f.write("README.md", "[State](docs/state.md#obsolete)\n");
  f.track();
  await assert.rejects(checkOverrides(f.root), /Missing policy anchor: README.md/);
});

test("rejects the full declared fragment instead of accepting its valid prefix", async (t) => {
  const f = await fixture(t);
  await f.write(".agents/skill-overrides.json", JSON.stringify({
    skills: ["example"], links: ["docs/state.md#pr-states#missing"],
  }));
  await assert.rejects(checkOverrides(f.root), /Missing policy anchor: docs\/state.md#pr-states#missing/);
});

test("rejects the full incoming fragment instead of accepting its valid prefix", async (t) => {
  const f = await fixture(t);
  await f.write("README.md", "[State](docs/state.md#pr-states#missing)\n");
  f.track();
  await assert.rejects(checkOverrides(f.root), /Missing policy anchor: README.md/);
});

test("deleted policy document fails rather than silently reducing coverage", async (t) => {
  const f = await fixture(t);
  await rm(join(f.root, "docs/state.md"));
  await assert.rejects(checkOverrides(f.root), /ENOENT/);
});

test("unrelated upstream drift and unrelated links stay outside the declared override scope", async (t) => {
  const f = await fixture(t);
  const lock = JSON.parse(await readFile(join(f.root, "skills-lock.json"), "utf8"));
  lock.skills.unrelated = { computedHash: "upstream metadata, not a local override" };
  await f.write("skills-lock.json", JSON.stringify(lock));
  await f.write("README.md", "[External](https://example.com/missing)\n[Unrelated](absent.md)\n");
  f.track();
  assert.deepEqual(await checkOverrides(f.root), { skills: 1, links: 2 });
});

test("missing override lock entry cannot pass", async (t) => {
  const f = await fixture(t);
  await f.write("skills-lock.json", '{"version":1,"skills":{}}');
  await assert.rejects(checkOverrides(f.root), /Unknown local skill: example/);
});

test("empty override registry cannot claim successful coverage", async (t) => {
  const f = await fixture(t);
  await f.write(".agents/skill-overrides.json", '{"skills":[],"links":[]}');
  await assert.rejects(checkOverrides(f.root), /nonempty skills and links/);
});

test("skill symlink is rejected rather than hashed as if absent", async (t) => {
  const f = await fixture(t);
  await symlink(join(f.root, "docs/state.md"), join(f.skill, "linked.md"));
  await assert.rejects(checkOverrides(f.root), /Unsupported skill symlink/);
});
