const { chromium } = require("playwright");
const assert = require("node:assert/strict");

const stressParagraph = "Inspect the complete sidebar while multiple independent sessions compare implementation details, revisit earlier decisions, wait for missing context, and record results that must remain distinguishable even when names share the same opening words. This deliberately oversized synthetic description should challenge truncation, wrapping, selection, previews, and access to controls without changing the identity or ownership of any item.";
const stressToken = "UnbrokenSyntheticIdentifier".repeat(16);
const rowIDs = ["implementer", "reviewer", "github", "shell"];
const identities = Object.fromEntries(rowIDs.map(id => [id, `${stressParagraph} ${stressToken} (${id})`]));
const workspaceIdentity = `Stress testing: ${stressParagraph} ${stressToken}`;

assert.equal(stressToken.length, 432, "Keep the original unbroken stress identifier intact.");

(async () => {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const checks = [], errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1024, height: 800 }, reducedMotion: "reduce" });
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/");
    await page.locator("#reset-demo").click();
    await page.evaluate(({ identities, workspaceIdentity }) => {
      for (const [id, name] of Object.entries(identities)) {
        const item = surfaces.find(surface => surface.id === id);
        if (!item) throw new Error(`Missing stress surface ${id}.`);
        item.name = name;
      }
      const workspace = workspaces.find(item => item.id === "design");
      if (!workspace) throw new Error("Missing stress workspace.");
      workspace.name = workspaceIdentity;
      render();
    }, { identities, workspaceIdentity });

    const check = (label, condition) => {
      assert.ok(condition, label);
      checks.push(label);
    };
    const state = () => page.evaluate(() => JSON.stringify({
      active: state.active,
      current: document.querySelector("#pinned-details").dataset.active,
      dismissed: state.dismissed,
      workspaceOrder: state.workspaceOrder,
      panes: state.panes,
      paneSelected: state.paneSelected
    }));
    const hasExactFocus = origin => origin.evaluate(element =>
      document.activeElement === element && window.issue132Origin === element);
    const before = await state();
    let expectedActionLabels;

    const inspectOpenMenu = async expectedIdentity => {
      const menu = page.locator("#context-menu");
      await menu.waitFor({ state: "visible" });
      const metrics = await menu.evaluate(element => {
        const rect = element.getBoundingClientRect();
        const identity = element.querySelector(".menu-label");
        const buttons = [...element.querySelectorAll("button")];
        return {
          left: rect.left,
          right: rect.right,
          top: rect.top,
          bottom: rect.bottom,
          width: element.clientWidth,
          height: element.clientHeight,
          scrollWidth: element.scrollWidth,
          scrollHeight: element.scrollHeight,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight,
          originRight: window.issue132Origin?.getBoundingClientRect().right,
          overflowX: getComputedStyle(element).overflowX,
          overflowY: getComputedStyle(element).overflowY,
          identity: identity.textContent,
          identityWidth: identity.clientWidth,
          identityScrollWidth: identity.scrollWidth,
          buttons: buttons.map(button => ({
            text: button.textContent.trim(),
            width: button.clientWidth,
            scrollWidth: button.scrollWidth,
            whiteSpace: getComputedStyle(button).whiteSpace
          }))
        };
      });
      check("Menu dialog exposes the full identity as its accessible name",
        await page.getByRole("dialog", { name: `Actions for ${expectedIdentity}`, exact: true }).count() === 1);
      check("Menu retains the complete visible identity without horizontal clipping",
        metrics.identity === `Actions for ${expectedIdentity}` &&
        metrics.identityScrollWidth <= metrics.identityWidth + 1);
      check("Menu stays within the viewport with no horizontal scrolling",
        metrics.left >= 11 && metrics.top >= 11 &&
        metrics.right <= metrics.viewportWidth - 11 &&
        metrics.bottom <= metrics.viewportHeight - 11 &&
        metrics.scrollWidth <= metrics.width + 1 &&
        metrics.overflowX === "hidden");
      check("Required action labels wrap instead of clipping",
        metrics.buttons.length > 1 &&
        metrics.buttons.every(button => button.scrollWidth <= button.width + 1 && button.whiteSpace === "normal"));
      return { menu, metrics };
    };

    const closeWith = async (key, origin) => {
      await page.keyboard.press(key);
      await page.locator("#context-menu").waitFor({ state: "hidden" });
      check(`Dismissal restores the exact originating control after ${key}`,
        await hasExactFocus(origin));
      check("Menu interaction preserves selection and lifecycle state", await state() === before);
    };

    for (const width of [280, 350, 460]) {
      await page.setViewportSize({ width: 1024, height: 800 });
      await page.evaluate(width => document.documentElement.style.setProperty("--sidebar-width", `${width}px`), width);
      check(`Sidebar uses the ${width}px logical width`,
        await page.locator("#sidebar").evaluate(element => element.getBoundingClientRect().width) === width);
      const origin = page.locator(`[data-menu="implementer"]`);
      await origin.scrollIntoViewIfNeeded();
      await origin.evaluate(element => { window.issue132Origin = element; });
      await origin.click();
      const { menu, metrics } = await inspectOpenMenu(identities.implementer);
      const buttons = menu.locator("button");
      const actionLabels = metrics.buttons.map(button => button.text);
      if (expectedActionLabels) {
        check("Action labels stay equivalent across sidebar widths",
          JSON.stringify(actionLabels) === JSON.stringify(expectedActionLabels));
      } else {
        expectedActionLabels = actionLabels;
      }
      await page.keyboard.press("Home");
      check("Home reaches the first action", await page.evaluate(() => document.activeElement.textContent.trim()) === (await buttons.first().textContent()).trim());
      await page.keyboard.press("ArrowDown");
      check("ArrowDown reaches the next action", await page.evaluate(() => document.activeElement.textContent.trim()) === (await buttons.nth(1).textContent()).trim());
      await page.keyboard.press("ArrowUp");
      check("ArrowUp returns to the previous action", await page.evaluate(() => document.activeElement.textContent.trim()) === (await buttons.first().textContent()).trim());
      await page.keyboard.press("End");
      check("End reaches the last action", (await page.evaluate(() => document.activeElement.textContent)).trim() === "Cancel");
      await closeWith("Escape", origin);
    }

    const rightClickOrigin = page.locator('[data-row="implementer"] .row-main');
    await rightClickOrigin.scrollIntoViewIfNeeded();
    await rightClickOrigin.evaluate(element => { window.issue132Origin = element; });
    await page.mouse.move(1000, 12);
    await page.waitForTimeout(300);
    const rightClickBounds = await rightClickOrigin.boundingBox();
    await page.mouse.click(rightClickBounds.x + 12, rightClickBounds.y + rightClickBounds.height / 2, { button: "right" });
    const { metrics: rightClickMetrics } = await inspectOpenMenu(identities.implementer);
    check("Right-click and overflow invocation expose the same actions",
      JSON.stringify(rightClickMetrics.buttons.map(button => button.text)) === JSON.stringify(expectedActionLabels));
    await closeWith("Escape", rightClickOrigin);

    await page.setViewportSize({ width: 300, height: 420 });
    await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "280px"));
    const shortWindowOrigin = page.locator('[data-menu="reviewer"]');
    await shortWindowOrigin.scrollIntoViewIfNeeded();
    await shortWindowOrigin.evaluate(element => { window.issue132Origin = element; });
    await shortWindowOrigin.click();
    const { menu: shortMenu, metrics: shortMetrics } = await inspectOpenMenu(identities.reviewer);
    check("Short-window menu anchors to the viewport edge without escaping it",
      shortMetrics.originRight > shortMetrics.viewportWidth - 40 &&
      Math.abs(shortMetrics.right - (shortMetrics.viewportWidth - 12)) <= 1 &&
      shortMetrics.top <= 14);
    check("Short windows bound a tall menu with vertical scrolling",
      shortMetrics.height <= shortMetrics.viewportHeight - 22 &&
      shortMetrics.scrollHeight > shortMetrics.height &&
      shortMetrics.overflowY === "auto");
    await page.keyboard.press("Home");
    await page.keyboard.press("End");
    const lastActionVisible = await shortMenu.locator("button").last().evaluate(button => {
      const dialog = button.closest("dialog");
      const buttonRect = button.getBoundingClientRect();
      const dialogRect = dialog.getBoundingClientRect();
      const top = dialogRect.top + dialog.clientTop;
      return buttonRect.top >= top - 1 && buttonRect.bottom <= top + dialog.clientHeight + 1;
    });
    check("The final action scrolls into view and remains keyboard reachable", lastActionVisible);
    await closeWith("Enter", shortWindowOrigin);

    const keyboardOrigin = page.locator('[data-row="github"] .row-main');
    await keyboardOrigin.scrollIntoViewIfNeeded();
    await keyboardOrigin.evaluate(element => { window.issue132Origin = element; });
    await keyboardOrigin.focus();
    await page.keyboard.press("Shift+F10");
    await inspectOpenMenu(identities.github);
    await page.keyboard.press("Escape");
    await page.locator("#context-menu").waitFor({ state: "hidden" });
    check("Keyboard invocation restores the exact originating row",
      await hasExactFocus(keyboardOrigin));
    check("Keyboard invocation preserves selection and lifecycle state", await state() === before);

    const overflowOrigin = page.locator('[data-menu="shell"]');
    await overflowOrigin.scrollIntoViewIfNeeded();
    await overflowOrigin.evaluate(element => { window.issue132Origin = element; });
    await overflowOrigin.click();
    await inspectOpenMenu(identities.shell);
    await page.keyboard.press("Escape");
    await page.locator("#context-menu").waitFor({ state: "hidden" });
    check("Overflow invocation restores the exact originating control",
      await hasExactFocus(overflowOrigin));
    check("Overflow invocation preserves selection and lifecycle state", await state() === before);

    const workspaceOrigin = page.locator('[data-workspace-menu="design"]');
    await workspaceOrigin.scrollIntoViewIfNeeded();
    await workspaceOrigin.evaluate(element => { window.issue132Origin = element; });
    await workspaceOrigin.click();
    await inspectOpenMenu(workspaceIdentity);
    await page.keyboard.press("Escape");
    await page.locator("#context-menu").waitFor({ state: "hidden" });
    check("Workspace menu dismissal restores its exact originating control",
      await hasExactFocus(workspaceOrigin));
    check("Workspace menu preserves selection and lifecycle state", await state() === before);
    check("No browser runtime errors", errors.length === 0);
    console.log(`PASS: ${checks.length} action-menu containment and focus checks.`);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
