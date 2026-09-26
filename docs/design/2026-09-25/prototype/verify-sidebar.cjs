const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

(async () => {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const checks = [], errors = [], widths = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1512, height: 1050 } });
    page.on("pageerror", error => errors.push(error.message));
    const check = (name, condition) => { assert.ok(condition, name); checks.push(name); };
    const state = () => page.evaluate(() => JSON.parse(localStorage.getItem("maestro-cosmetic-lab-v2")));
    const model = () => page.evaluate(() => ({
      identities: surfaces.map(({ id, workspace, worktree, parent }) => ({ id, workspace, worktree, parent })),
      active: state.active, panes: state.panes, icons: state.icons, pets: state.pets, beats: state.beats
    }));
    const drag = async (source, target, after = false) => {
      await target.scrollIntoViewIfNeeded();
      const box = await target.boundingBox();
      await source.dragTo(target, { targetPosition: { x: Math.min(40, box.width / 2), y: after ? box.height - 3 : 3 } });
    };
    const workspaceOrder = () => page.locator("#workspaces > .workspace").evaluateAll(elements => elements.map(element => element.dataset.workspace));
    const treeOrder = () => page.locator("#workspace-content-design > .worktree").evaluateAll(elements => elements.map(element => element.dataset.worktreeId));
    await page.goto(process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/");
    await page.locator("#reset-demo").click();
    const initial = await model();
    await page.locator('[data-workspace-collapse="design"]').click();
    await drag(page.locator('[data-workspace="scratch"] > .workspace-title'), page.locator('[data-workspace="design"] > .workspace-title'));
    assert.deepEqual(await workspaceOrder(), ["scratch", "design"]);
    check("Whole workspaces reorder with their collapsed content intact", (await state()).workspaceCollapsed.design && (await state()).workspaceCollapsed.scratch);
    assert.deepEqual(await model(), initial);
    await page.reload();
    assert.deepEqual(await workspaceOrder(), ["scratch", "design"]);
    check("Workspace order persists across reload", true);

    await page.locator("#reset-demo").click();
    await drag(page.locator('[data-worktree-id="tree-002"] > .group-heading'), page.locator('[data-worktree-id="tree-001"] > .group-heading'));
    assert.deepEqual(await treeOrder(), ["tree-002", "tree-001"]);
    check("Worktree groups move as a unit without changing child membership", await page.locator('[data-worktree-id="tree-002"] [data-row]').count() === 3);
    const before = await model();
    await drag(page.locator('[data-row="reviewer"]'), page.locator('[data-row="implementer"]'));
    assert.deepEqual(await page.locator('[data-worktree-id="tree-002"] .group-rows > [data-row]').evaluateAll(elements => elements.map(element => element.dataset.row)), ["reviewer", "implementer", "accessibility"]);
    check("Individual agents reorder within their worktree", true);
    assert.deepEqual(await model(), before);
    await page.locator('[data-expand="design:main"]').first().click();
    const ordersBeforeRejectedDrop = (await state()).sidebarOrders;
    await drag(page.locator('[data-row="reviewer"]'), page.locator('[data-row="coordinator"]'));
    assert.deepEqual((await state()).sidebarOrders, ordersBeforeRejectedDrop);
    assert.deepEqual(await model(), before);
    check("Cross-worktree drop is rejected without changing identity or layout", true);
    await page.locator('[data-row="accessibility"] .row-main').focus();
    await page.keyboard.press("Alt+ArrowUp");
    check("Keyboard reordering moves only the focused sibling", (await state()).sidebarOrders["members:design:sidebar"].join(",") === "reviewer,accessibility,implementer");
    check("Keyboard reordering preserves focus", await page.evaluate(() => document.activeElement.dataset.focus === "accessibility"));
    await page.reload();
    check("Worktree and child orders both survive reload", (await treeOrder())[0] === "tree-002" && (await state()).sidebarOrders["members:design:sidebar"].join(",") === "reviewer,accessibility,implementer");

    await page.locator("#reset-demo").click();
    await page.locator('[data-grouping="subagents"]').click();
    const familyBefore = await model();
    await drag(page.locator('[data-row="reviewer"]'), page.locator('[data-row="coordinator"]'));
    check("Agent trees reorder with their entire subtree", await page.locator("#workspace-content-design > .ancestor").first().locator(':scope > .ancestor-row [data-row="reviewer"]').count() === 1 && await page.locator('.ancestor:has(> .ancestor-row [data-row="reviewer"]) > .tree-children [data-row]').count() === 2);
    assert.deepEqual(await model(), familyBefore);
    await drag(page.locator('[data-row="accessibility"]'), page.locator('[data-row="writer"]'));
    check("Child trees reorder among their own siblings", (await state()).sidebarOrders["family:design:reviewer"].join(",") === "accessibility,writer");
    const beforeReparent = (await state()).sidebarOrders;
    await drag(page.locator('[data-row="implementer"]'), page.locator('[data-row="writer"]'));
    assert.deepEqual((await state()).sidebarOrders, beforeReparent);
    assert.deepEqual(await model(), familyBefore);
    check("Dragging an agent into another family cannot reparent it", true);

    await page.locator("#reset-demo").click();
    await page.locator('[data-grouping="workspace"]').click();
    await drag(page.locator('[data-pane-collapse="design:2"]'), page.locator('[data-pane-collapse="design:1"]'));
    assert.deepEqual(await page.locator("#workspace-content-design > [data-native-pane]").evaluateAll(elements => elements.map(element => element.dataset.nativePane)), ["design:2", "design:1"]);
    assert.deepEqual(await page.locator("#native-layout > .pane").evaluateAll(elements => elements.map(element => element.dataset.pane)), ["2", "1"]);
    check("Pane groups carry their surface contents and preserve pane identities", await page.locator('[data-native-pane="design:2"] [data-row="implementer"]').count() === 1);
    await drag(page.locator('[data-row="azure"]'), page.locator('[data-row="github"]'));
    const tabOrder = (await state()).tabOrder["design:2"];
    check("Browser rows reorder within their pane and update the native tab strip", tabOrder.indexOf("azure") < tabOrder.indexOf("github") && await page.locator('[data-pane="2"] [data-drag]').evaluateAll(elements => elements.findIndex(element => element.dataset.drag === "azure") < elements.findIndex(element => element.dataset.drag === "github")));
    const paneOrders = JSON.stringify((await state()).tabOrder);
    await drag(page.locator('[data-row="azure"]'), page.locator('[data-row="shell"]'));
    check("Sidebar surface drops cannot cross panes", JSON.stringify((await state()).tabOrder) === paneOrders && !(await state()).panes.azure);
    await page.locator("#beats-button").click();
    await page.locator("#taskboard-button").click();
    await drag(page.locator('#workspaces [data-row="tool-taskboard"]'), page.locator('#workspaces [data-row="tool-beats"]'));
    check("Utility tabs participate in the same sibling ordering", (await state()).tabOrder["design:2"].indexOf("tool-taskboard") < (await state()).tabOrder["design:2"].indexOf("tool-beats"));

    await page.locator("#open-directory-button").click();
    await page.locator("#directory-path").fill("relative/path");
    await page.locator("#directory-form [type=submit]").click();
    check("Directory mock rejects ambiguous relative paths visibly", (await page.locator("#directory-error").textContent()).includes("absolute path") && (await state()).workspaceOrder.length === 2);
    await page.locator("#directory-path").fill("~/Projects/Design <notes>");
    await page.locator("#directory-form [type=submit]").click();
    const created = (await state()).createdDirectories[0];
    check("Folder-plus creates a synthetic workspace and terminal", (await state()).workspaceOrder.length === 3 && (await state()).active === `${created.id}-terminal` && (await page.locator(`[data-workspace="${created.id}"] .workspace-select`).textContent()) === "Design <notes>" && await page.locator(".workspace-select notes").count() === 0);
    await page.reload();
    check("Created demo workspace survives reload", (await state()).workspaceOrder.length === 3 && await page.locator(`[data-workspace="${created.id}"]`).count() === 1);
    await page.locator(`[data-workspace="${created.id}"] .workspace-select`).focus();
    await page.keyboard.press("Alt+ArrowUp");
    check("Workspace reorder preserves unrelated siblings with three workspaces", (await state()).workspaceOrder.join(",") === `design,${created.id},scratch`);
    await page.locator("#beats-button").click();
    await page.locator('#native-layout [data-tool-move="beats"]').click();
    await page.locator("#tool-move-workspace").selectOption(created.id);
    await page.locator("#tool-move-form [type=submit]").click();
    await page.reload();
    check("Utility tab placement supports newly created demo workspaces", (await state()).utilityTabs.beats.workspace === created.id && await page.locator("#beats-panel").isVisible());
    await page.locator("#reset-demo").click();
    check("Reset removes only generated demo workspaces", (await state()).workspaceOrder.length === 2 && (await state()).createdDirectories.length === 0);

    check("Compact agent rows omit state words and the info button", !/\bWorking\b|\bNeeds input\b/.test(await page.locator(".agent-row .row-meta").allTextContents().then(items => items.join(" "))) && await page.locator("[data-info]").count() === 0);
    check("Working spinner remains labelled for assistive technology", await page.locator('[data-row="implementer"] .state-dot').getAttribute("aria-label") === "Working");
    check("Working state animates while needs-input stays static", await page.locator('[data-row="implementer"] .state-dot').evaluate(element => getComputedStyle(element).animationName) === "working-spin" && await page.locator('[data-row="reviewer"] .state-dot').evaluate(element => getComputedStyle(element).animationName) === "none");
    await page.emulateMedia({ reducedMotion: "reduce" });
    check("Reduced motion suppresses the spinner animation", await page.locator('[data-row="implementer"] .state-dot').evaluate(element => getComputedStyle(element).animationName) === "none");
    await page.locator('[data-grouping="subagents"]').click();
    await page.evaluate(() => {
      const template = surfaces.find(item => item.id === "implementer");
      for (let depth = 1; depth <= 8; depth++) surfaces.push({ ...template, id: `depth-${depth}`, name: "Nested delivery reviewer", parent: depth === 1 ? "coordinator" : `depth-${depth - 1}`, task: `Nested agent depth ${depth}` });
      render();
    });
    for (const width of [280, 350]) {
      await page.locator("#sidebar-width").fill(String(width));
      const name = page.locator('[data-row="depth-8"] .row-name');
      await name.scrollIntoViewIfNeeded();
      const box = await page.locator('[data-row="depth-8"] .row-title').boundingBox();
      widths.push({ sidebar: width, label: box.width });
      check(`Eight-level agent retains useful text width at ${width}px`, box.width >= (width === 280 ? 160 : 230));
      check(`Inline tags do not truncate the nested name at ${width}px`, await name.evaluate(element => element.scrollWidth <= element.clientWidth));
      check(`Deep nesting does not overflow the ${width}px sidebar`, await page.locator("#sidebar").evaluate(element => element.scrollWidth <= element.clientWidth));
    }
    await page.screenshot({ path: path.join(__dirname, "review-deep-sidebar.png") });
    check("No runtime errors", errors.length === 0);
    fs.writeFileSync(path.join(__dirname, "verification-sidebar.json"), JSON.stringify({ checkedAt: new Date().toISOString(), checks, widths, errors }, null, 2));
    console.log(`PASS: ${checks.length} sidebar checks. Label widths: ${JSON.stringify(widths)}`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
