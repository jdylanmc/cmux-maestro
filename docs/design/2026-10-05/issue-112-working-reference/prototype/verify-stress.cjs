const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

(async () => {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const checks = [], errors = [], requests = [], layouts = [], findings = [];
  const baseURL = process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/";
  const artifacts = process.env.PROTOTYPE_ARTIFACT_DIR || __dirname;
  const check = (name, condition) => { assert.ok(condition, name); checks.push(name); };
  const finding = (surface, scenario, measurements) => findings.push({ surface, scenario, ...measurements });
  try {
    const page = await browser.newPage({ viewport: { width: 1512, height: 1080 }, reducedMotion: "reduce" });
    page.on("pageerror", error => errors.push(error.message));
    page.on("request", request => requests.push(request.url()));
    await page.goto(baseURL);
    await page.locator("#reset-demo").click();
    check("Stress workspace is present but collapsed by default", await page.locator('[data-workspace="stress"]').count() === 1 && await page.locator('[data-workspace-collapse="stress"]').getAttribute("aria-expanded") === "false");
    check("Normal initial selection remains unchanged", await page.locator("#pinned-details").getAttribute("data-active") === "implementer");
    const fixture = await page.evaluate(() => {
      const agents = surfaces.filter(item => item.workspace === "stress" && item.kind === "agent");
      const tasks = observedChildren.filter(item => internalTaskOwner(item).workspace === "stress");
      return {
        agents: agents.length, tasks: tasks.length,
        tabs: surfaces.filter(item => item.workspace === "stress").length,
        directChats: agents.filter(item => item.parent === "stress-root").length,
        directTasks: tasks.filter(item => item.parent === "stress-root").length,
        chatDepth: agents.filter(item => item.id.startsWith("stress-depth-")).length,
        taskDepth: tasks.filter(item => item.id.startsWith("stress-task-depth-")).length,
        shortestAgentName: Math.min(...agents.map(item => item.name.length)),
        shortestHistory: Math.min(...agents.map(item => item.task.length)),
        longestUnbrokenToken: stressToken.length
      };
    });
    assert.deepEqual({ agents: fixture.agents, tasks: fixture.tasks, tabs: fixture.tabs }, { agents: 61, tasks: 172, tabs: 65 });
    check("Fixture has dozens of both kinds of child work", fixture.directChats === 48 && fixture.directTasks === 96);
    check("Fixture retains twelve levels of each kind of ancestry", fixture.chatDepth === 12 && fixture.taskDepth === 12);
    check("Names, histories and identifiers genuinely exceed normal content sizes", fixture.shortestAgentName >= 400 && fixture.shortestHistory >= 4000 && fixture.longestUnbrokenToken >= 400);
    await page.evaluate(() => {
      state.workspaceOrder = ["scratch", "design"];
      delete state.workspaceCollapsed.stress;
      state.icons.implementer = { mode: "custom", glyph: "leaf", color: "#79d7cc" };
      state.tags.implementer = ["preserve-this"];
      state.taskDismissals[taskOutcomeKey(observedChildren.find(item => item.id === "task-review"))] = true;
      const record = { id: "directory-00000000-0000-4000-8000-000000000001", directory: "/demo/kept-workspace" };
      state.createdDirectories.push(record);
      state.workspaceOrder.push(record.id);
      state.workspaceCollapsed[record.id] = true;
      state.utilityTabs.beats = { workspace: record.id, pane: 2 };
      save();
    });
    await page.reload();
    check("Previous two-workspace preferences migrate without losing custom data", await page.evaluate(() =>
      state.workspaceOrder.join(",") === "scratch,design,directory-00000000-0000-4000-8000-000000000001,stress" &&
      state.workspaceCollapsed.stress && state.icons.implementer.glyph === "leaf" &&
      state.tags.implementer[0] === "preserve-this" && Object.keys(state.taskDismissals).length === 1 &&
      state.utilityTabs.beats.workspace === state.createdDirectories[0].id
    ));
    await page.reload();
    check("Migration persists once without duplicating Stress testing", await page.evaluate(() => state.workspaceOrder.filter(id => id === "stress").length === 1 && startupNotice === ""));
    await page.locator("#reset-demo").click();
    await page.locator("#stress-button").click();
    check("Stress shortcut opens the fixture and its review controls", await page.locator("#pinned-details").getAttribute("data-active") === "stress-root" && await page.locator("#stress-controls").isVisible());
    const identity = await page.evaluate(() => JSON.stringify({
      surfaces: surfaces.map(({ id, workspace, parent, worktree }) => ({ id, workspace, parent, worktree })),
      tasks: observedChildren.map(({ id, parent }) => ({ id, parent }))
    }));
    await page.evaluate(() => { state.workspaceCollapsed.design = true; state.workspaceCollapsed.scratch = true; render(); });

    for (const width of [280, 350, 460]) {
      for (const grouping of ["worktrees", "subagents", "workspace"]) {
        const result = await page.evaluate(({ width, grouping }) => {
          const start = performance.now();
          state.grouping = grouping;
          document.documentElement.style.setProperty("--sidebar-width", `${width}px`);
          render();
          const sidebar = document.querySelector("#sidebar");
          const root = document.querySelector('[data-workspace="stress"]');
          const clippedNames = [...root.querySelectorAll(".task-name")].filter(element => element.clientWidth < 40);
          const overflowing = [...root.querySelectorAll(".workspace-title, .group-heading, .row-main, .task-line")].filter(element => element.scrollWidth > element.clientWidth + 1);
          const statusHidden = [...root.querySelectorAll(".task-status")].filter(element => {
            const box = element.getBoundingClientRect(), parent = sidebar.getBoundingClientRect();
            return box.left < parent.left || box.right > parent.right;
          });
          const ambiguousNames = [...root.querySelectorAll(".row-name")].filter(element => element.textContent.startsWith("Review the complete sidebar:") && element.scrollWidth > element.clientWidth);
          return {
            width, grouping, renderAndLayoutMs: Math.round((performance.now() - start) * 10) / 10,
            sidebarWidth: sidebar.clientWidth, sidebarContentWidth: sidebar.scrollWidth,
            overflowing: overflowing.slice(0, 6).map(element => ({ class: element.className, width: element.clientWidth, contentWidth: element.scrollWidth })),
            tooNarrowTaskNames: clippedNames.length, minimumTaskNameWidth: Math.min(...[...root.querySelectorAll(".task-name")].map(element => element.clientWidth)),
            statusesOutsideSidebar: statusHidden.length, ambiguousClippedChatNames: ambiguousNames.length,
            renderedTabs: root.querySelectorAll("[data-native-surface]").length
          };
        }, { width, grouping });
        layouts.push(result);
        if (result.sidebarContentWidth > result.sidebarWidth + 1) finding("Sidebar horizontal overflow", `${grouping} at ${width}px`, { contentWidth: result.sidebarContentWidth, availableWidth: result.sidebarWidth, examples: result.overflowing });
        if (result.overflowing.length) finding("Row or worktree-header content exceeds its container", `${grouping} at ${width}px`, { examples: result.overflowing });
        if (result.tooNarrowTaskNames) finding("Deep task names lose usable width", `${grouping} at ${width}px`, { count: result.tooNarrowTaskNames, minimumWidth: result.minimumTaskNameWidth });
        if (result.statusesOutsideSidebar) finding("State marks fall outside sidebar", `${grouping} at ${width}px`, { count: result.statusesOutsideSidebar });
        if (result.ambiguousClippedChatNames > 1) finding("Repeated opening text makes truncated chat names ambiguous", `${grouping} at ${width}px`, { count: result.ambiguousClippedChatNames });
        if (result.renderAndLayoutMs > 200) finding("Slow synchronous rendering", `${grouping} at ${width}px`, { renderAndLayoutMs: result.renderAndLayoutMs, advisoryThresholdMs: 200 });
        if (grouping === "workspace") check(`Native workspace retains all 65 real tabs at ${width}px`, result.renderedTabs === 65);
        if (width === 280) {
          await page.mouse.move(1450, 30);
          await page.locator("#workspaces").evaluate(element => { element.scrollTop = 0; element.scrollLeft = 0; });
          await page.locator("#sidebar").screenshot({ path: path.join(artifacts, `stress-${grouping}-280.png`) });
        }
      }
    }
    check("Stress navigation does not alter ownership or ancestry", await page.evaluate(() => JSON.stringify({
      surfaces: surfaces.map(({ id, workspace, parent, worktree }) => ({ id, workspace, parent, worktree })),
      tasks: observedChildren.map(({ id, parent }) => ({ id, parent }))
    })) === identity);
    await page.locator('[data-grouping="subagents"]').click();
    const beforeEye = await page.locator('[data-workspace="stress"] [data-observed]').count();
    await page.locator('[data-toggle-finished="stress"]').click();
    check("Idle reveal increases visible internal tasks without deleting data", await page.locator('[data-workspace="stress"] [data-observed]').count() > beforeEye && await page.evaluate(() => observedChildren.filter(item => internalTaskOwner(item).workspace === "stress").length) === 172);
    await page.locator('[data-ancestry="stress-root"]').click();
    check("Wide family collapses without changing active selection", await page.locator('[data-row="stress-agent-1"]').count() === 0 && await page.locator("#pinned-details").getAttribute("data-active") === "stress-root");
    await page.locator('[data-ancestry="stress-root"]').click();
    const lastTask = page.locator('[data-observed="stress-task-depth-12"]');
    await lastTask.scrollIntoViewIfNeeded();
    check("Deepest internal task remains reachable through scrolling", await lastTask.isVisible());
    const preview = async id => {
      const row = page.locator(`[data-row="${id}"]`);
      await row.scrollIntoViewIfNeeded();
      await page.mouse.move(1450, 30);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await page.locator("#global-grouping button").first().focus();
      await row.locator(".row-main").focus();
      await page.locator("#hover-card").waitFor({ state: "visible" });
    };
    await preview("stress-agent-8");
    check("Paragraph-length agent can be keyboard-previewed without selection", await page.locator("#hover-card").isVisible() && await page.locator("#pinned-details").getAttribute("data-active") === "stress-root");
    const measure = async (selector, name) => {
      const result = await page.locator(selector).evaluate(element => ({
        width: element.clientWidth, contentWidth: element.scrollWidth, height: element.clientHeight, contentHeight: element.scrollHeight
      }));
      if (result.contentWidth > result.width + 1) finding(`${name}: horizontal overflow`, "paragraphs and unbroken identifiers", result);
      if (result.contentHeight > result.height * 3) finding(`${name}: content spans many viewport heights`, "paragraph histories and long names", { ...result, viewportHeights: Math.round(result.contentHeight / result.height * 10) / 10 });
      return result;
    };
    const hover = await measure("#hover-card", "Hover preview");
    await page.screenshot({ path: path.join(artifacts, "stress-hover.png") });
    await page.keyboard.press("Escape");
    check("Escape dismisses oversized preview without losing keyboard origin", !await page.locator("#hover-card").isVisible() && await page.evaluate(() => document.activeElement.dataset.focus === "stress-agent-8"));
    await page.locator('[data-row="stress-agent-8"] .row-main').click();
    const pinned = await measure("#pinned-details", "Pinned details");
    check("Pinned history retains the complete synthetic raw value", (await page.locator('#pinned-details [data-field="child-history"] [data-copy-value]').getAttribute("data-copy-value")).length >= 4000);
    await page.locator('[data-row="stress-agent-8"] [data-menu]').click();
    const menu = await measure("#context-menu", "Row action menu");
    await page.keyboard.press("End");
    check("Long-name row menu still allows keyboard access to its final action", await page.evaluate(() => document.activeElement.textContent === "Cancel"));
    await page.keyboard.press("Escape");
    await page.locator("#stress-long-name").check();
    check("Long workspace name fixture is rendered in the actual sidebar header", (await page.locator('[data-workspace="stress"] .workspace-select').textContent()).length >= 800);
    const workspaceName = page.locator('[data-workspace="stress"] .workspace-select');
    await page.mouse.move(1450, 30);
    await workspaceName.scrollIntoViewIfNeeded();
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const workspaceNameBox = await workspaceName.boundingBox();
    await page.mouse.move(workspaceNameBox.x + Math.min(20, workspaceNameBox.width / 2), workspaceNameBox.y + workspaceNameBox.height / 2);
    await page.locator("#hover-card").waitFor({ state: "visible" });
    const workspaceHover = await measure("#hover-card", "Workspace preview");
    const header = await page.locator('[data-workspace="stress"] .workspace-title').evaluate(element => {
      const name = element.querySelector(".workspace-select"), actions = element.querySelector(".workspace-actions");
      const nameBox = name.getBoundingClientRect(), actionBox = actions.getBoundingClientRect(), box = element.getBoundingClientRect();
      return { nameWidth: name.clientWidth, nameScrollLeft: name.scrollLeft, actionWidth: actions.clientWidth, actionOutsideHeader: actionBox.right > box.right + 1, overlapping: nameBox.right > actionBox.left + 1 };
    });
    if (header.nameScrollLeft || header.nameWidth < 40 || header.actionOutsideHeader || header.overlapping) finding("Long workspace header loses label or action clarity", "paragraph workspace name after preview", header);
    await page.keyboard.press("Escape");
    await page.locator("#stress-history").click();
    check("History has many real fixture outcomes, not a special preview shortcut", await page.locator('[data-history-entry^="stress-"]').count() >= 9);
    const history = await measure("#history-dialog", "Completed activity history");
    await page.screenshot({ path: path.join(artifacts, "stress-history.png") });
    await page.keyboard.press("Escape");
    await page.locator("#stress-long-name").uncheck();
    await page.locator('[data-row="stress-browser-1"] .row-main').click();
    const browserPinned = await measure("#pinned-details", "Browser pinned details");
    await preview("stress-browser-1");
    const browserHover = await measure("#hover-card", "Browser hover preview");
    await page.screenshot({ path: path.join(artifacts, "stress-browser.png") });
    await page.keyboard.press("Escape");
    await page.locator('[data-row="stress-terminal-3"] .row-main').click();
    const terminalPinned = await measure("#pinned-details", "Terminal pinned details");
    await preview("stress-terminal-3");
    const terminalHover = await measure("#hover-card", "Terminal hover preview");
    await page.keyboard.press("Escape");
    check("Long browser and terminal rows remain actual selectable surfaces", await page.locator("#pinned-details").getAttribute("data-active") === "stress-terminal-3");
    await page.locator("#beats-button").click();
    await page.reload();
    check("Utility view placement in Stress testing survives reload", await page.evaluate(() => state.utilityTabs.beats.workspace === "stress" && state.active === "tool-beats"));
    await page.locator('#native-layout [data-close-tool="beats"]').click();
    await page.locator("#reset-demo").click();
    check("Reset preserves the complete stress fixture and returns to the readable demo", await page.evaluate(() => surfaces.filter(item => item.workspace === "stress").length === 65 && state.workspaceCollapsed.stress && !state.stressLongName && state.active === "implementer"));
    check("No runtime errors under the stress fixture", errors.length === 0);
    check("Stress fixture never contacts external services", requests.every(url => url.startsWith(baseURL)));
    const report = { checkedAt: new Date().toISOString(), fixture, checks, layouts, panels: { hover, pinned, menu, workspaceHover, history, browserPinned, browserHover, terminalPinned, terminalHover }, header, findings, errors };
    fs.writeFileSync(path.join(artifacts, "stress-report.json"), JSON.stringify(report, null, 2));
    console.log(`PASS: ${checks.length} stress-fixture and interaction checks. DIAGNOSTIC: ${findings.length} overload findings; see stress-report.json.`);
    console.log(JSON.stringify({ fixture, findings }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
