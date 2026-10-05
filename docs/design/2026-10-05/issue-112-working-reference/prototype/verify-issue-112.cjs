const { chromium } = require("playwright");
const assert = require("node:assert/strict");

(async () => {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 1512, height: 940 }, reducedMotion: "reduce" });
  const checks = [], errors = [], requests = [];
  const baseURL = new URL(process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/").href;
  const check = (name, passed) => { assert.ok(passed, name); checks.push(name); };
  const active = () => page.locator("#pinned-details").getAttribute("data-active");
  const lifecycle = () => page.evaluate(() => JSON.stringify(state.dismissed));
  page.on("pageerror", error => errors.push(error.message));
  page.on("request", request => requests.push(request.url()));
  await page.addInitScript(() => {
    window.copyRequests = [];
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: async value => { window.copyRequests.push(value); } }
    });
  });

  try {
    await page.goto(baseURL);
    await page.locator("#reset-demo").click();
    await page.locator("#stress-button").click();
    await page.locator('[data-grouping="subagents"]').click();
    const selectionBefore = await active();
    const lifecycleBefore = await lifecycle();
    const preview = async id => {
      const row = page.locator(`[data-row="${id}"] .row-main`);
      await row.scrollIntoViewIfNeeded();
      await page.mouse.move(1450, 30);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await row.hover();
      await page.locator("#hover-card").waitFor({ state: "visible" });
    };

    await preview("stress-agent-1");
    const rawA = await page.locator('#hover-card [data-field="session-id"] .field-copy')
      .getAttribute("data-copy-value");
    await page.locator("#hover-card").evaluate(element => { element.scrollTop = element.scrollHeight; });
    const scrolledA = await page.locator("#hover-card").evaluate(element => element.scrollTop);
    check("S53 setup scrolls preview A away from its identity heading", scrolledA > 0);

    const subjectB = "stress-agent-3";
    const rowB = page.locator(`[data-row="${subjectB}"] .row-main`);
    await page.evaluate(id => showHover(id, document.querySelector(`[data-row="${id}"] .row-main`)), subjectB);
    await page.waitForFunction(id =>
      !document.querySelector("#hover-card").hidden &&
      document.querySelector("#hover-card .hover-title")?.textContent.includes(byId(id).name), subjectB);
    const rawB = await page.locator('#hover-card [data-field="session-id"] .field-copy')
      .getAttribute("data-copy-value");
    const expectedB = await page.evaluate(id => demoSessionMetadata.get(id).sessionId, subjectB);
    const headingAtTop = await page.locator("#hover-card").evaluate(card => {
      const cardBox = card.getBoundingClientRect();
      const heading = card.querySelector(".hover-title")?.getBoundingClientRect();
      return !!heading && heading.top >= cardBox.top && heading.bottom <= cardBox.bottom;
    });
    check("S53 subject B starts with its visible identity heading", headingAtTop);
    check("S53 preview B contains B's exact raw session identity", rawB === expectedB && rawB !== rawA);
    check("S53 changing preview subject leaves the selected tab and lifecycle untouched",
      await active() === selectionBefore && await lifecycle() === lifecycleBefore);

    const refreshPosition = await page.locator("#hover-card").evaluate(card => {
      const maximum = card.scrollHeight - card.clientHeight;
      card.scrollTop = Math.min(600, maximum / 2);
      return { before: card.scrollTop, maximum };
    });
    check("S53 same-subject fixture has a scrollable body", refreshPosition.maximum > 1 && refreshPosition.before > 0);
    await page.evaluate(id => showHover(id, document.querySelector(`[data-row="${id}"] .row-main`)), subjectB);
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const afterRefresh = await page.locator("#hover-card").evaluate(card => card.scrollTop);
    check("S53 same-subject refresh preserves its scroll position",
      Math.abs(afterRefresh - refreshPosition.before) <= 1);
    check("S53 same-subject refresh retains current raw subject and active selection",
      await page.locator('#hover-card [data-field="session-id"] .field-copy').getAttribute("data-copy-value") === expectedB &&
      await active() === selectionBefore && await lifecycle() === lifecycleBefore);
    await page.keyboard.press("Escape");

    await page.locator("#reset-demo").click();
    await page.locator("#stress-button").click();
    await page.evaluate(() => {
      state.grouping = "worktrees";
      state.workspaceCollapsed.stress = false;
      state.collapsed["stress:stress-wide"] = true;
      state.collapsed["stress:stress-deep"] = true;
      render();
    });
    const iconID = "stress-agent-47";
    const strip = page.locator('.strip-scroll[data-strip-key="stress:stress-wide"]');
    const iconOrigin = page.locator(`.strip-scroll[data-strip-key="stress:stress-wide"] .strip-agent[data-focus="${iconID}"]`);
    check("S55 origin is the final, visible icon in a horizontally scrolled card",
      await iconOrigin.count() === 1);
    await strip.evaluate(element => { element.scrollLeft = element.scrollWidth; });
    const iconVisible = await page.evaluate(id => {
      const icon = document.querySelector(`.strip-agent[data-focus="${id}"]`);
      const viewport = icon?.closest(".strip-scroll");
      if (!icon || !viewport) return false;
      const item = icon.getBoundingClientRect(), area = viewport.getBoundingClientRect();
      return item.left >= area.left && item.right <= area.right;
    }, iconID);
    check("S55 target icon is visible after horizontal scrolling", iconVisible);
    const colorDialog = page.locator("#tag-color-dialog");
    const focusTagColorFromIcon = async () => {
      await iconOrigin.hover();
      await page.locator("#hover-card").waitFor({ state: "visible" });
      await iconOrigin.focus();
      const trigger = page.locator("#hover-card [data-tag-color]").first();
      let keyboardReachedTrigger = false;
      for (let index = 0; index < 20; index++) {
        if (await trigger.evaluate(element => element === document.activeElement)) {
          keyboardReachedTrigger = true;
          break;
        }
        await page.keyboard.press("Tab");
      }
      check("S55 keyboard reaches a preview tag-color action from the icon origin",
        keyboardReachedTrigger && await page.evaluate(id => hoverReturnFocus?.dataset.focus === id, iconID));
      return trigger;
    };
    const colorTrigger = await focusTagColorFromIcon();
    const selectionForDialog = await active();
    const lifecycleForDialog = await lifecycle();
    const colorsBeforeCancel = await page.evaluate(() => JSON.stringify(state.tagColors));
    const clipboardBefore = await page.evaluate(() => window.copyRequests.length);
    await page.keyboard.press("Enter");
    await colorDialog.waitFor({ state: "visible" });
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => !document.querySelector("#tag-color-dialog").open);
    await page.waitForFunction(id =>
      document.activeElement === document.querySelector(`.strip-agent[data-focus="${id}"]`), iconID);
    check("S55 cancel restores the exact scrolled icon origin",
      await iconOrigin.evaluate(element => element === document.activeElement));
    check("S55 cancel preserves active tab, lifecycle, tag colors and clipboard",
      await active() === selectionForDialog && await lifecycle() === lifecycleForDialog &&
      await page.evaluate(() => JSON.stringify(state.tagColors)) === colorsBeforeCancel &&
      await page.evaluate(() => window.copyRequests.length) === clipboardBefore);

    await focusTagColorFromIcon();
    await page.keyboard.press("Enter");
    await colorDialog.waitFor({ state: "visible" });
    const changedColor = await page.locator("#tag-color-options button").first().getAttribute("data-tag-swatch");
    await page.locator("#tag-color-options button").first().click();
    check("S55 choosing a color completes only the synthetic color preference",
      await page.evaluate(({ id, color }) => state.tagColors[tagColorTarget] === color && state.active === "stress-root"
        && !state.dismissed[id], { id: iconID, color: changedColor }));
    await colorDialog.locator('[data-close="tag-color-dialog"]').click();
    await page.waitForFunction(id =>
      document.activeElement === document.querySelector(`.strip-agent[data-focus="${id}"]`), iconID);
    check("S55 completion restores the exact icon after the row rerenders",
      await iconOrigin.evaluate(element => element === document.activeElement));
    check("S55 completion preserves selection, live lifecycle and clipboard",
      await active() === selectionForDialog && await lifecycle() === lifecycleForDialog &&
      await page.evaluate(() => window.copyRequests.length) === clipboardBefore);

    await focusTagColorFromIcon();
    await page.keyboard.press("Enter");
    await colorDialog.waitFor({ state: "visible" });
    await page.evaluate(id => { state.dismissed[id] = true; commit(); }, iconID);
    await colorDialog.locator('[data-close="tag-color-dialog"]').click();
    await page.waitForFunction(() => {
      const workspace = document.querySelector('[data-workspace="stress"]');
      const rows = [...workspace.querySelectorAll("[data-row]")].map(row => row.querySelector(".row-main")).filter(canRestoreFocus);
      const fallback = rows[0] || workspace.querySelector(".workspace-select");
      return fallback === document.activeElement;
    });
    check("S55 a filtered icon origin restores the deterministic visible local fallback",
      await page.evaluate(() => {
        const workspace = document.querySelector('[data-workspace="stress"]');
        const rows = [...workspace.querySelectorAll("[data-row]")].map(row => row.querySelector(".row-main")).filter(canRestoreFocus);
        return document.activeElement === (rows[0] || workspace.querySelector(".workspace-select"));
      }));
    check("S55 fallback does not change the selected tab or write the clipboard",
      await active() === selectionForDialog && await page.evaluate(() => window.copyRequests.length) === clipboardBefore);
    check("No runtime errors or external requests", errors.length === 0 && requests.every(url => url.startsWith(baseURL)));
    console.log(`PASS: ${checks.length} issue #112 S53-S55 reference checks.`);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
