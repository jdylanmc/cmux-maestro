const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "./prototype/node_modules/playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

(async () => {
  const root = __dirname, url = process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/";
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const images = [], errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1512, height: 1080 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(url);
    async function reset() {
      await page.locator("#reset-demo").click();
      await page.mouse.move(1400, 50);
      await page.evaluate(() => { clearTimeout(noticeTimer); document.querySelector("#notice").classList.remove("visible"); });
      await page.locator("#workspaces").evaluate(element => { element.scrollTop = 0; });
      await page.locator(".stage").evaluate(element => { element.scrollTop = 0; });
    }
    async function save(name, caption, selectors = null) {
      await page.evaluate(() => document.querySelector("#notice").classList.remove("visible"));
      const options = { path: path.join(root, "images", `${name}.png`) };
      if (selectors) {
        const boxes = await Promise.all(selectors.map(selector => page.locator(selector).boundingBox()));
        assert.ok(boxes.every(Boolean), `All screenshot subjects must exist: ${name}`);
        const x = Math.max(0, Math.min(...boxes.map(box => box.x)) - 6);
        const y = Math.max(0, Math.min(...boxes.map(box => box.y)) - 6);
        const right = Math.min(1512, Math.max(...boxes.map(box => box.x + box.width)) + 6);
        const bottom = Math.min(1080, Math.max(...boxes.map(box => box.y + box.height)) + 6);
        options.clip = { x, y, width: right - x, height: bottom - y };
      }
      await page.screenshot(options);
      images.push({ file: `images/${name}.png`, caption, sha256: crypto.createHash("sha256").update(fs.readFileSync(options.path)).digest("hex") });
    }
    await reset();
    await save("overview", "Default approved design: compact sidebar and native-layout review stage.");
    await save("worktrees", "Worktrees: compact groups, title-inline tags and icon-only agent status.", ["#sidebar"]);
    await save("header", "Header order: directory, Beats, Taskboard, History, Settings, Fermata.", [".sidebar-heading", "#global-grouping"]);
    await page.locator('[data-grouping="subagents"]').click();
    await save("subagents", "Sub-agents: verified ancestry, reduced indentation and compact tags.", ["#sidebar"]);
    await page.locator('[data-grouping="workspace"]').click();
    await save("workspace", "Workspace: real hierarchy concepts, pane-local surfaces and no explanatory clutter.", ["#sidebar"]);
    await reset();
    await page.locator('[data-hover-workspace="design"]').hover();
    await page.locator("#hover-card").waitFor({ state: "visible" });
    await save("workspace-hover", "Workspace-name-only hover; eye, backlog, menu and collapse controls do not trigger it.", ["#sidebar", "#hover-card"]);
    await page.mouse.move(1400, 50);
    await page.locator('[data-row="accessibility"] .row-main').hover();
    await page.waitForFunction(() => document.querySelector("#hover-card .hover-title")?.textContent.includes("Accessibility review"));
    await save("agent-hover", "Hovered agent details and its pet stay separate from the pinned active agent. Values are synthetic.", ["#sidebar", "#hover-card"]);
    await reset();
    await page.locator('#pinned-details [data-tags="implementer"]').click();
    await page.locator("#tag-input").fill("design-review, frontend");
    await page.locator("#tag-form [type=submit]").click();
    await save("tags-inline", "Shared slug colors; tags are unchanged in size, inline with agent names, aligned right.", ["#sidebar"]);
    await page.locator('#pinned-details [data-tag-color="frontend"]').click();
    await save("tag-colors", "Human swatch overrides apply everywhere; automatic colors derive from the slug.", ["#sidebar", "#tag-color-dialog"]);
    await page.keyboard.press("Escape");
    await page.locator('#pinned-details [data-tags="implementer"]').click();
    await save("tag-editor", "Human tag assignment and tag colors preserve agent-owned tag attribution.", ["#tags-dialog"]);
    await page.keyboard.press("Escape");
    await page.locator('[data-pet="implementer"]').click();
    await save("pet-picker", "Independent per-agent pet choice, reset and visibility; original placeholder artwork.", ["#sidebar", "#picker"]);
    await page.keyboard.press("Escape");
    await page.locator('[data-row="github"] [data-icon]').click();
    await save("browser-icon", "Browser appearance picker with explicit website-favicon mode; no favicon fetching is demonstrated.", ["#sidebar", "#picker"]);
    await page.keyboard.press("Escape");
    await page.locator("#history-button").click();
    await save("history", "History preserves completed activity and open-chat versus explicit exit semantics.", ["#history-dialog"]);
    await page.keyboard.press("Escape");
    await reset();
    await page.locator('[data-toggle-finished="design"]').click();
    await save("workspace-history-eye", "Workspace-specific finished visibility: first eye enabled, second unaffected.", ["#sidebar"]);
    await page.locator('[data-row="implementer"] [data-menu]').click();
    await save("agent-menu", "Agent overflow keeps focus, appearance, tags and lifecycle actions separate.", ["#sidebar", "#context-menu"]);
    await page.keyboard.press("Escape");
    await page.locator('[data-workspace-menu="design"]').click();
    await save("workspace-menu", "Workspace menu and adjacent per-workspace eye/backlog affordances.", ["#sidebar", "#context-menu"]);
    await page.keyboard.press("Escape");
    await page.locator('#pinned-details [data-dismiss="implementer"]').click();
    await save("exit-confirm", "Working-agent exit requires explicit confirmation; simulated only.", ["#dismiss-dialog"]);
    await page.keyboard.press("Escape");
    await page.locator('[data-drag="reviewer"] [data-focus]').click();
    await page.locator('#pinned-details [data-dismiss="reviewer"]').click();
    await save("exit-scope", "Parent-only versus exact descendant scope; no live lifecycle action.", ["#dismiss-scope-dialog"]);
    await page.keyboard.press("Escape");
    await page.locator("#maestro-settings-button").click();
    await page.locator("#install-scenario").selectOption("unreadable");
    await save("settings", "Header gear opens Maestro settings; guide status is a simulated scenario.", ["#settings-dialog"]);
    await page.keyboard.press("Escape");
    await reset();
    await page.locator("#beats-button").click();
    await save("beats", "Beats content tab: exact agent, cron, prompt and per-Beat queued state.");
    await page.locator("[data-cron-builder]").click();
    await save("cron-builder", "Inline wand opens friendly controls that fill a single cron expression.", ["#cron-dialog"]);
    await page.keyboard.press("Escape");
    await page.locator(".beat-simulator summary").click();
    await page.locator('[data-beat-tick="beat-review"]').click();
    await page.locator('[data-beat-tick="beat-review"]').click();
    await page.locator(".beat-diagnostic-status").scrollIntoViewIfNeeded();
    await save("beat-diagnostics", "Two extra triggers leave only one pending occurrence; scheduling controls are explicit simulation.", [".beat-diagnostic-status", ".beat-diagnostics", ".beat-simulator"]);
    await page.locator("#taskboard-button").click();
    await page.locator("#taskboard").scrollIntoViewIfNeeded();
    await save("taskboard", "Taskboard is a reusable content tab, not a sidebar grouping mode.");
    await page.locator('#native-layout [data-tool-move="taskboard"]').click();
    await save("utility-move", "Move a utility view to a pane/workspace without changing agents or Beats.", ["#tool-move-dialog"]);
    await page.keyboard.press("Escape");
    await reset();
    await page.locator("#open-directory-button").click();
    await page.locator("#directory-path").fill("~/Projects/new-project");
    await save("open-directory", "Directory-plus entry point; example-path simulation stands in for a native directory chooser.", ["#directory-dialog"]);
    await page.keyboard.press("Escape");
    await page.locator("#fermata-button").click();
    await save("fermata", "Final header icon: musical fermata, Keep Mac Awake on/off; local demo state only.", [".sidebar-heading"]);
    await reset();
    const source = await page.locator('[data-row="accessibility"]').boundingBox();
    const target = await page.locator('[data-row="implementer"]').boundingBox();
    await page.mouse.move(source.x + 65, source.y + 12);
    await page.mouse.down();
    await page.mouse.move(target.x + 65, target.y + 3, { steps: 20 });
    await page.waitForFunction(() => document.querySelector("[data-drop-edge]"));
    await save("sidebar-reorder", "Real prototype drag gesture: insertion line among sibling rows; no reparenting.", ["#sidebar"]);
    await page.mouse.up();
    await reset();
    await page.locator('[data-grouping="subagents"]').click();
    await page.evaluate(() => {
      const template = surfaces.find(item => item.id === "implementer");
      for (let depth = 1; depth <= 8; depth++) surfaces.push({ ...template, id: `capture-depth-${depth}`, name: "Nested delivery reviewer", parent: depth === 1 ? "coordinator" : `capture-depth-${depth - 1}`, task: `Synthetic depth-${depth} layout case` });
      render();
    });
    await page.locator("#sidebar-width").fill("280");
    await page.locator('[data-row="capture-depth-8"]').scrollIntoViewIfNeeded();
    await save("deep-nesting", "Explicit test-only eight-level fixture at 280px; not part of the default demo.", ["#sidebar"]);
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(root, "evidence", "capture.json"), JSON.stringify({
      capturedAt: new Date().toISOString(), browser: await browser.version(), viewport: { width: 1512, height: 1080 }, scale: 2,
      motion: "reduce", synthetic: true, noNativeIntegration: true, images, errors
    }, null, 2) + "\n");
    console.log(`Captured ${images.length} target images without runtime errors.`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
