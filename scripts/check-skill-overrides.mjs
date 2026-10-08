#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { lstat, readFile, readdir, realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

// Match the skills CLI: sorted relative paths followed by raw file bytes.
export async function skillFolderHash(root) {
  const files = [];
  async function collect(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`Unsupported skill symlink: ${path}`);
      if (entry.isDirectory() && ![".git", "node_modules"].includes(entry.name)) {
        await collect(path);
      } else if (entry.isFile()) {
        files.push({ path: relative(root, path).split(sep).join("/"), bytes: await readFile(path) });
      }
    }
  }
  await collect(root);
  files.sort((a, b) => a.path.localeCompare(b.path));
  const hash = createHash("sha256");
  for (const file of files) hash.update(file.path).update(file.bytes);
  return hash.digest("hex");
}

function headings(markdown) {
  const anchors = new Set();
  for (const match of markdown.matchAll(/^#{1,6} +(.+)$/gm)) {
    const base = match[1].trim().toLowerCase()
      .replace(/[^\p{L}\p{N}_\s-]/gu, "").replace(/\s/g, "-");
    let anchor = base;
    for (let suffix = 1; anchors.has(anchor); suffix++) anchor = `${base}-${suffix}`;
    anchors.add(anchor);
  }
  return anchors;
}

function splitFragment(link) {
  const index = link.indexOf("#");
  return index < 0 ? [link, ""] : [link.slice(0, index), link.slice(index + 1)];
}

export async function checkOverrides(root) {
  root = await realpath(root);
  const config = JSON.parse(await readFile(join(root, ".agents/skill-overrides.json"), "utf8"));
  const lock = JSON.parse(await readFile(join(root, "skills-lock.json"), "utf8"));
  if (!Array.isArray(config.skills) || !config.skills.length ||
      !Array.isArray(config.links) || !config.links.length) {
    throw new Error("Local skill overrides need nonempty skills and links lists");
  }
  async function inside(path) {
    const actual = await realpath(path);
    const rel = relative(root, actual);
    if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new Error(`Path outside repository: ${path}`);
    }
    return actual;
  }
  for (const id of config.skills) {
    if (typeof id !== "string" || !/^[a-z][a-z0-9-]*$/.test(id) || !lock.skills[id]) {
      throw new Error(`Unknown local skill: ${id}`);
    }
    const hash = await skillFolderHash(await inside(join(root, ".agents/skills", id)));
    if (hash !== lock.skills[id].computedHash) {
      throw new Error(`Skill hash drift: ${id}; review the local override, then update its lock hash`);
    }
  }

  const targets = new Set();
  const contents = new Map();
  async function checkLink(path, anchor, label) {
    await inside(path);
    if (!contents.has(path)) contents.set(path, await readFile(path, "utf8"));
    if (anchor && !headings(contents.get(path)).has(decodeURIComponent(anchor))) {
      throw new Error(`Missing policy anchor: ${label}`);
    }
  }
  for (const link of config.links) {
    if (typeof link !== "string") throw new Error("Policy link must be a string");
    const [path, anchor] = splitFragment(link);
    const target = resolve(root, path);
    await checkLink(target, anchor, link);
    targets.add(target);
  }
  const files = execFileSync("git", ["-C", root, "ls-files", "-z", "--", "*.md"], {
    encoding: "utf8",
  }).split("\0").filter(Boolean);
  let checkedLinks = config.links.length;
  for (const file of files) {
    const source = join(root, file);
    if ((await lstat(source)).isSymbolicLink()) continue;
    const markdown = await readFile(source, "utf8");
    for (const match of markdown.matchAll(/\[[^\]]*\]\(([^)\s]+)\)/g)) {
      const link = match[1];
      if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(link)) continue;
      const [path, anchor] = splitFragment(link);
      const target = path ? resolve(dirname(source), decodeURIComponent(path)) : source;
      if (!targets.has(target)) continue;
      await checkLink(target, anchor, `${file}: ${link}`);
      checkedLinks++;
    }
  }
  return { skills: config.skills.length, links: checkedLinks };
}

if (process.argv[1] && await realpath(process.argv[1]) === await realpath(fileURLToPath(import.meta.url))) {
  try {
    const result = await checkOverrides(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
    console.log(`Verified ${result.skills} local skill hashes and ${result.links} policy links`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
