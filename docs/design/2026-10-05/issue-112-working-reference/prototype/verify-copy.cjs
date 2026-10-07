const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

(async () => {
  const baseURL = new URL(process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/").href;
  const artifacts = process.env.PROTOTYPE_ARTIFACT_DIR || __dirname;
  fs.mkdirSync(artifacts, { recursive: true });
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 940 }, reducedMotion: "reduce" });
  const page = await context.newPage();
  const errors = [], requests = [], checks = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("request", request => requests.push(request.url()));
  await page.addInitScript(() => {
    // Keep clipboard tests inside this browser; never replace the human's clipboard.
    window.copyRequests = [];
    window.copyDenied = false;
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: async value => {
        if (window.copyDenied) throw new DOMException("Clipboard permission denied", "NotAllowedError");
        window.copyRequests.push(value);
      } }
    });
  });
  const check = (label, result) => { assert.ok(result, label); checks.push(label); };
  const revealed = button => button.evaluate(element => getComputedStyle(element).opacity === "1");
  const active = () => page.locator("#pinned-details").getAttribute("data-active");
  const lastCopy = () => page.evaluate(() => window.copyRequests.at(-1));
  const hoverAgent = async id => {
    await page.locator(`[data-row="${id}"] .row-main`).scrollIntoViewIfNeeded();
    await page.mouse.move(1100, 80);
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await page.locator(`[data-row="${id}"] .row-main`).hover();
    await page.waitForFunction(id => {
      const card = document.querySelector("#hover-card");
      return !card.hidden && card.querySelector(".hover-title")?.textContent.includes(byId(id).name);
    }, id);
  };
  const values = [
    ["session-id", "00000000-0000-4000-8000-000000000002"],
    ["observed", "2026-09-25T20:00:00.000Z"],
    ["child-history", "incomplete"],
    ["workspace-path", "/demo/cmux-maestro"],
    ["project-path", "/demo/worktrees/sidebar-design/cmux-maestro"],
    ["working-directory", "/demo/worktrees/sidebar-design/cmux-maestro"]
  ];
  try {
    await page.goto(baseURL);
    await page.locator("#reset-demo").click();
    await page.mouse.move(1100, 80);
    check("Copy buttons are hidden initially", await page.locator("#pinned-details .field-copy").evaluateAll(elements => elements.length === 6 && elements.every(element => getComputedStyle(element).opacity === "0" && getComputedStyle(element).pointerEvents === "none")));
    const prefsBefore = await page.evaluate(() => JSON.stringify(state));
    for (const surface of ["#pinned-details", "#hover-card"]) {
      if (surface === "#hover-card") await hoverAgent("reviewer");
      const fields = page.locator(`${surface} .detail-fields`);
      check(`${surface}: buttons belong to labels, never values`, await fields.locator("dt .field-copy").count() === 6 && await fields.locator("dd button").count() === 0);
      for (const [key, expected] of values) {
        const field = fields.locator(`[data-field="${key}"]`);
        const button = field.locator(".field-copy");
        await field.locator("dd").hover();
        check(`${surface} ${key}: value hover does not reveal copy`, !await revealed(button));
        const before = await field.locator("dd").boundingBox();
        await field.locator(".detail-field-label > span").hover();
        check(`${surface} ${key}: label hover reveals only its own copy button`, await revealed(button) && await fields.locator(".field-copy").evaluateAll(elements => elements.filter(element => getComputedStyle(element).opacity === "1").length) === 1);
        const after = await field.locator("dd").boundingBox();
        check(`${surface} ${key}: reveal does not shift layout`, JSON.stringify(before) === JSON.stringify(after));
        await button.hover();
        check(`${surface} ${key}: button remains reachable from label`, await revealed(button));
        await button.locator("svg").click();
        const raw = surface === "#hover-card" && key === "session-id" ? "00000000-0000-4000-8000-000000000005" : expected;
        check(`${surface} ${key}: copies the raw value`, await lastCopy() === raw);
        await field.locator("dd").hover();
        check(`${surface} ${key}: pointer click does not leave the button visible`, !await revealed(button));
      }
    }
    check("Copying hovered fields preserves active agent and all preferences", await active() === "implementer" && await page.evaluate(() => JSON.stringify(state)) === prefsBefore);
    check("Paths are shortened for display only", await page.locator('#hover-card [data-field="project-path"] dd').textContent() === "~/worktrees/sidebar-design/cmux-maestro");
    check("Observed display differs from raw ISO timestamp", await page.locator('#hover-card [data-field="observed"] dd').textContent() !== values[1][1]);

    const sessionField = page.locator('#hover-card [data-field="session-id"]');
    await sessionField.locator("dt").hover({ position: { x: 200, y: 10 } });
    check("Blank label-row space does not reveal a copy button", !await revealed(sessionField.locator(".field-copy")));
    await sessionField.locator(".detail-field-label > span").hover();
    await page.screenshot({ path: path.join(artifacts, "review-copy-hover.png") });
    await page.evaluate(() => { window.copyDenied = true; });
    const copyCount = await page.evaluate(() => window.copyRequests.length);
    await sessionField.locator(".field-copy").click();
    check("Clipboard rejection surfaces an error rather than success", (await page.locator("#notice").textContent()).includes("Copy failed (NotAllowedError)") && await page.evaluate(() => window.copyRequests.length) === copyCount);
    await page.evaluate(() => { window.copyDenied = false; });
    await sessionField.locator(".field-copy").click();
    check("Copy works after permission failure", await page.locator("#notice").textContent() === "Session ID copied.");

    await page.keyboard.press("Escape");
    await page.mouse.move(1100, 80);
    await page.locator('#pinned-details [data-pet="implementer"]').focus();
    await page.keyboard.press("Tab");
    const pinnedCopy = page.locator('#pinned-details [data-field="session-id"] .field-copy');
    check("Tab reveals a pinned copy button without pointer hover", await pinnedCopy.evaluate(element => element === document.activeElement) && await revealed(pinnedCopy));
    await page.keyboard.press("Space");
    check("Space copies the pinned raw session ID", await lastCopy() === values[0][1]);
    await page.keyboard.press("Tab");
    const observedCopy = page.locator('#pinned-details [data-field="observed"] .field-copy');
    check("Keyboard focus reveals only the new field", !await revealed(pinnedCopy) && await revealed(observedCopy));
    await page.keyboard.press("Enter");
    check("Enter copies the raw timestamp", await lastCopy() === values[1][1]);

    const origin = page.locator('[data-row="reviewer"] .row-main');
    await origin.focus();
    await page.keyboard.press("Tab");
    const hoverCopy = page.locator('#hover-card [data-field="session-id"] .field-copy');
    check("Tab enters the hovered agent's copy actions", await hoverCopy.evaluate(element => element === document.activeElement) && await revealed(hoverCopy) && await active() === "implementer");
    await page.keyboard.press("Enter");
    check("Keyboard preview copies hovered identity, not pinned identity", await lastCopy() === "00000000-0000-4000-8000-000000000005");
    const pointerDepartureWrites = await page.evaluate(() => window.copyRequests.length);
    await page.keyboard.press("Shift+Tab");
    check("Shift+Tab from the first action returns to the origin", await origin.evaluate(element => element === document.activeElement));
    await page.keyboard.press("Tab");
    check("R2 re-enters the preview with visible keyboard focus", await hoverCopy.evaluate(element => element === document.activeElement) && await revealed(hoverCopy));
    await page.mouse.move(1100, 80);
    await page.waitForTimeout(300);
    check("Pointer departure does not dismiss keyboard interaction", await page.locator("#hover-card").isVisible());
    check("R2 keeps the exact focused copy action and selection through the 220ms leave timer",
      await page.locator("#hover-card").isVisible() &&
      await hoverCopy.evaluate(element => element === document.activeElement && getComputedStyle(element).opacity === "1") &&
      await active() === "implementer" &&
      await page.evaluate(() => window.copyRequests.length) === pointerDepartureWrites);
    await page.keyboard.press("Escape");
    check("Escape closes preview and restores the original row", !await page.locator("#hover-card").isVisible() && await origin.evaluate(element => element === document.activeElement));
    await page.locator("#global-grouping button").first().focus();
    await origin.focus();
    await page.keyboard.press("Tab");
    const actionCount = await page.locator("#hover-card button").count();
    for (let index = 1; index < actionCount; index++) await page.keyboard.press("Tab");
    check("All preview actions remain keyboard reachable", await page.locator("#hover-card button").last().evaluate(element => element === document.activeElement));
    await page.keyboard.press("Tab");
    check("Tab leaves preview at the origin's next row control", !await page.locator("#hover-card").isVisible() && await page.locator('[data-menu="reviewer"]').evaluate(element => element === document.activeElement));

    await page.locator('[data-drag="scratch-agent"] [data-focus]').click();
    check("A non-repository project field offers no fabricated copy value", await page.locator('#pinned-details [data-field="project-path"] dd').textContent() === "Not a repository" && await page.locator('#pinned-details [data-field="project-path"] button').count() === 0);
    await page.locator('[data-drag="github"] [data-focus]').click();
    check("Non-agent details do not gain synthetic session fields", await page.locator("#pinned-details .detail-fields").count() === 0);

    await page.locator("#reset-demo").click();
    const longPath = `/demo/${"long-directory/".repeat(15)}quoted"&<directory>`;
    await page.evaluate(value => { worktrees.sidebar.path = value; render(); }, longPath);
    const pathField = page.locator('#pinned-details [data-field="working-directory"]');
    await pathField.locator(".detail-field-label > span").hover();
    await pathField.locator(".field-copy").click();
    check("Wrapped paths copy in full with special characters intact", await lastCopy() === longPath && await pathField.locator("dd").textContent() === `~${longPath.slice(5)}`);
    for (const width of [280, 350, 460]) {
      await page.locator("#sidebar-width").fill(String(width));
      check(`Long metadata fits a ${width}px sidebar`, await page.locator("#pinned-details").evaluate(element => element.scrollWidth <= element.clientWidth));
    }
    await page.setViewportSize({ width: 900, height: 600 });
    await hoverAgent("reviewer");
    check("Tall preview scrolls within the viewport", await page.locator("#hover-card").evaluate(element => {
      const box = element.getBoundingClientRect();
      return box.top >= 0 && box.bottom <= window.innerHeight && element.scrollWidth <= element.clientWidth && element.scrollHeight > element.clientHeight;
    }));
    await page.locator('#hover-card [data-field="working-directory"] .detail-field-label > span').hover();
    await page.locator('#hover-card [data-field="working-directory"] .field-copy').click();
    check("Scrolled preview still copies the complete raw value", await lastCopy() === longPath);
    await page.screenshot({ path: path.join(artifacts, "review-copy-narrow.png") });
    check("No JavaScript runtime errors", errors.length === 0);
    check("No external requests", requests.every(url => url.startsWith(baseURL)));
    console.log(`PASS: ${checks.length} field-copy checks.`);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
