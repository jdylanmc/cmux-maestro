const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

function contrast(foreground, background) {
  const luminance = color => {
    const values = color.match(/\d+(?:\.\d+)?/g).slice(0, 3).map(Number).map(channel => {
      const value = channel / 255;
      return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
    });
    return values[0] * .2126 + values[1] * .7152 + values[2] * .0722;
  };
  const first = luminance(foreground), second = luminance(background);
  return (Math.max(first, second) + .05) / (Math.min(first, second) + .05);
}

(async () => {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const checks = [], errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1512, height: 1100 }, reducedMotion: "reduce" });
    page.on("pageerror", error => errors.push(error.message));
    const check = (name, condition) => { assert.ok(condition, name); checks.push(name); };
    const state = () => page.evaluate(() => JSON.parse(localStorage.getItem("maestro-cosmetic-lab-v2")));
    const editTags = async (agent, tags) => {
      const workspace = await page.evaluate(id => surfaces.find(item => item.id === id).workspace, agent);
      await page.locator(`[data-workspace-select="${workspace}"]`).click();
      await page.locator(`[data-drag="${agent}"] [data-focus]`).click();
      await page.locator(`#pinned-details [data-tags="${agent}"]`).click();
      await page.locator("#tag-input").fill(tags);
      await page.locator("#tag-form [type=submit]").click();
    };
    const colors = locator => locator.evaluateAll(elements => elements.map(element => {
      const chip = getComputedStyle(element), text = getComputedStyle(element.querySelector(".tag-name"));
      return { slug: element.dataset.tagSlug, background: chip.backgroundColor, foreground: text.color };
    }));
    await page.goto(process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/");
    await page.locator("#reset-demo").click();
    check("Agent quick rows show compact colored tags", await page.locator('[data-row="implementer"] [data-tag-slug="frontend"]').count() === 1);
    const inlineTag = await page.locator('[data-row="implementer"] .row-title').evaluate(element => {
      const title = element.getBoundingClientRect(), name = element.querySelector(".row-name").getBoundingClientRect(), chip = element.querySelector(".tag").getBoundingClientRect();
      return { aligned: Math.abs((name.top + name.bottom) / 2 - (chip.top + chip.bottom) / 2) < 1, rightAligned: Math.abs(chip.right - title.right) < 1, size: getComputedStyle(element.querySelector(".tag")).fontSize };
    });
    check("Tree tags keep their size and align right on the title line", inlineTag.aligned && inlineTag.rightAligned && inlineTag.size === "8px");
    check("Collapsed group participants show their own tags", await page.locator('.summary-strip [data-focus="coordinator"] [data-tag-slug="coordination"]').count() === 1);
    const deterministic = await page.evaluate(() => {
      const slugs = ["design-review", "frontend", "constructor", "a", "标签", "café", ...Array.from({ length: 5000 }, (_, index) => `agent-tag-${index}`)];
      return {
        minContrast: Math.min(...slugs.map(slug => tagColorScheme(slug).contrast)),
        deterministic: slugs.every(slug => defaultTagColor(slug) === defaultTagColor(slug)),
        normalizes: ["Design Review", "DESIGN_REVIEW", "design-review", "  design review  "].every(value => tagSlug(value) === "design-review"),
        defaultMapEmpty: Object.keys(state.tagColors).length === 0
      };
    });
    check("Slug-based colors are deterministic, normalized and contrast-safe across 5006 samples", deterministic.minContrast >= 4.5 && deterministic.deterministic && deterministic.normalizes && deterministic.defaultMapEmpty);
    await editTags("implementer", "Design Review, frontend, FRONTEND");
    assert.deepEqual((await state()).tags.implementer, ["design-review", "frontend"]);
    check("Slug deduplication preserves both human and agent ownership", await page.locator('#pinned-details [data-tag-slug="frontend"]').count() === 1 && await page.locator('#pinned-details [data-tag-slug="frontend"]').getAttribute("data-tag-owners") === "you + agent");
    await editTags("reviewer", "design_review");
    check("The same slug on separate agents gets the same automatic color", (await colors(page.locator('[data-row="implementer"] [data-tag-slug="design-review"]')))[0].background === (await colors(page.locator('[data-row="reviewer"] [data-tag-slug="design-review"]')))[0].background);
    await editTags("notes", "DESIGN-REVIEW");
    await page.locator('#pinned-details [data-tag-color="design-review"]').click();
    const automatic = await page.locator('#tag-color-preview [data-tag-slug]').evaluate(element => getComputedStyle(element).backgroundColor);
    await page.getByRole("button", { name: "Ocean", exact: true }).click();
    check("Only an explicit human swatch creates a shared override", (await state()).tagColors["design-review"] === "#294f75");
    await page.keyboard.press("Escape");
    await page.locator('[data-drag="notes"] [data-focus]').click();
    await page.locator('#pinned-details [data-tags="notes"]').click();
    check("Tag editor exposes the shared color on saved tags", (await colors(page.locator('#tag-editor-colors [data-tag-slug="design-review"]')))[0].background === "rgb(41, 79, 117)");
    await page.keyboard.press("Escape");
    await page.locator('[data-workspace-select="design"]').click();
    await page.locator('[data-row="implementer"] .row-main').focus();
    await page.locator("#hover-card").waitFor({ state: "visible" });
    check("Hover details use the same tag scheme", (await colors(page.locator('#hover-card [data-tag-slug="design-review"]')))[0].background === "rgb(41, 79, 117)");
    await page.keyboard.press("Escape");
    await page.locator('[data-drag="implementer"] [data-focus]').click();
    check("Pinned details use the shared human color", (await colors(page.locator('#pinned-details [data-tag-slug="design-review"]')))[0].background === "rgb(41, 79, 117)");
    await page.locator("#taskboard-button").click();
    check("Taskboard cards show matching tag colors across workspaces", (await colors(page.locator('#taskboard [data-tag-slug="design-review"]'))).length === 3 && (await colors(page.locator('#taskboard [data-tag-slug="design-review"]'))).every(value => value.background === "rgb(41, 79, 117)"));
    await page.locator("#beats-button").click();
    check("Beats agent summaries also show their tags", await page.locator('#beats-panel [data-tag-slug="design-review"]').count() === 4);
    await page.locator("#history-button").click();
    check("History retains agent tag chips", await page.locator('#history-content [data-tag-slug="research"]').count() === 1);
    await page.keyboard.press("Escape");
    const domColors = await colors(page.locator("[data-tag-slug]"));
    check("Actual rendered tag text exceeds 4.5:1 on every current surface", domColors.length > 5 && domColors.every(value => contrast(value.foreground, value.background) >= 4.5));
    await page.locator('[data-drag="implementer"] [data-focus]').click();
    await page.locator('#pinned-details [data-tag-color="design-review"]').click();
    for (const name of await page.locator("#tag-color-options button").evaluateAll(buttons => buttons.map(button => button.getAttribute("aria-label")))) {
      await page.locator("#tag-color-options").getByRole("button", { name, exact: true }).click();
      const rendered = (await colors(page.locator('#pinned-details [data-tag-slug="design-review"]')))[0];
      check(`Human ${name} swatch has readable text`, contrast(rendered.foreground, rendered.background) >= 4.5);
    }
    await page.locator("#tag-color-options").getByRole("button", { name: "Ocean", exact: true }).click();
    await page.keyboard.press("Escape");
    await page.evaluate(() => {
      surfaces.find(item => item.id === "accessibility").agentTags.push("Design Review");
      commit();
    });
    check("New agent assignment inherits the human override instead of picking its own color", (await colors(page.locator('[data-row="accessibility"] [data-tag-slug="design-review"]')))[0].background === "rgb(41, 79, 117)");
    await page.reload();
    check("Human tag color overrides persist across reload", (await state()).tagColors["design-review"] === "#294f75" && (await colors(page.locator('#pinned-details [data-tag-slug="design-review"]')))[0].background === "rgb(41, 79, 117)");
    await page.locator('#pinned-details [data-tag-color="design-review"]').focus();
    await page.keyboard.press("Enter");
    check("Tag color picker is keyboard accessible", await page.getByRole("dialog", { name: "Color for design-review", exact: true }).isVisible());
    await page.locator("[data-tag-color-reset]").click();
    check("Reset removes the shared override and restores the deterministic color", !Object.hasOwn((await state()).tagColors, "design-review") && await page.locator('#tag-color-preview [data-tag-slug]').evaluate(element => getComputedStyle(element).backgroundColor) === automatic);
    await page.keyboard.press("Escape");
    await page.locator('#pinned-details [data-tags="implementer"]').click();
    await page.locator("#tag-input").fill("!!!");
    await page.locator("#tag-form [type=submit]").click();
    check("An empty normalized slug is rejected without losing saved tags", (await page.locator("#tag-editor-error").textContent()).includes("letter or number") && (await state()).tags.implementer.includes("design-review"));
    await page.locator("#tag-input").fill("long-design-review, another-long-review-tag, third-long-review-label, four, five, six");
    await page.locator("#tag-form [type=submit]").click();
    await page.locator("#sidebar-width").fill("280");
    check("Long and multiple tag chips do not force horizontal sidebar overflow", await page.locator("#sidebar").evaluate(element => element.scrollWidth <= element.clientWidth) && await page.locator('[data-row="implementer"] .row-main').evaluate(element => element.scrollWidth <= element.clientWidth));
    await page.locator("#sidebar-width").fill("350");
    await editTags("implementer", "design-review, frontend");
    await page.mouse.move(1200, 50);
    await page.screenshot({ path: path.join(__dirname, "review-tags.png") });
    await page.locator('#pinned-details [data-tag-color="frontend"]').click();
    await page.screenshot({ path: path.join(__dirname, "review-tag-colors.png") });
    check("No JavaScript errors", errors.length === 0);
    fs.writeFileSync(path.join(__dirname, "verification-tags.json"), JSON.stringify({ checkedAt: new Date().toISOString(), checks, minimumGeneratedContrast: deterministic.minContrast, errors }, null, 2));
    console.log(`PASS: ${checks.length} tag checks; minimum sampled contrast ${deterministic.minContrast.toFixed(2)}:1.`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
