const { chromium } = require("playwright");
const assert = require("node:assert/strict");

(async () => {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const checks = [], errors = [], requests = [];
  const baseURL = new URL(process.env.PROTOTYPE_URL || "http://127.0.0.1:8765/").href;
  const check = (name, passed) => { assert.ok(passed, name); checks.push(name); };
  try {
    const context = await browser.newContext({ viewport: { width: 1512, height: 940 }, reducedMotion: "reduce", timezoneId: "Asia/Kolkata", locale: "en-US" });
    const page = await context.newPage();
    page.on("pageerror", error => errors.push(error.message));
    page.on("request", request => requests.push(request.url()));
    await page.goto(baseURL);
    await page.locator("#reset-demo").click();
    const popover = page.locator("#beats-popover"), button = page.locator("#beats-button");
    const rows = page.locator("#beats-popover .beat-row");
    const row = id => page.locator(`[data-beat-row="${id}"]`);
    const save = () => page.getByRole("button", { name: "Save", exact: true }).click();
    const open = async () => { await button.click(); await popover.waitFor({ state: "visible" }); };
    const nextPattern = /^Next: (Sun|Mon|Tue|Wed|Thu|Fri|Sat), (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2} at \d{1,2}:\d{2} (AM|PM)$/;

    check("Beats is the second header icon and starts closed", await page.locator(".sidebar-heading-actions button").nth(1).getAttribute("id") === "beats-button" && !await popover.isVisible() && await button.getAttribute("aria-expanded") === "false");
    const lit = await button.evaluate(element => { const style = getComputedStyle(element); return { color: style.color, filter: style.filter, animation: style.animationName }; });
    check("Header icon is lit (accent blue, static glow, no animation) while a Beat is enabled", lit.color === "rgb(110, 168, 255)" && lit.filter.includes("drop-shadow") && lit.animation === "none");

    await open();
    check("Click opens a popover, not a content tab", await page.locator("#native-layout [data-close-tool]").count() === 0 && await page.evaluate(() => !("beats" in state.utilityTabs) && state.active === "implementer") && await button.getAttribute("aria-expanded") === "true");
    const geometry = await page.evaluate(() => {
      const box = selector => document.querySelector(selector).getBoundingClientRect();
      const icon = box("#beats-button"), pop = box("#beats-popover"), arrow = box(".beats-arrow");
      return { iconCenter: icon.left + icon.width / 2, arrowCenter: arrow.left + arrow.width / 2, iconBottom: icon.bottom, popTop: pop.top, popLeft: pop.left, popRight: pop.right, vw: innerWidth };
    });
    check("Popover sits directly under the Beats icon with its arrow pointing at it", geometry.popTop > geometry.iconBottom && geometry.popTop - geometry.iconBottom < 20 && Math.abs(geometry.arrowCenter - geometry.iconCenter) <= 2 && geometry.popLeft >= 0 && geometry.popRight <= geometry.vw);
    check("Title and caption match the shipped copy", await page.locator("#beats-title").textContent() === "Beats" && await page.locator("#beats-caption").textContent() === "Recurring prompts for exact agent sessions. Each session schedules its own through Copilot, so the session must be running.");
    check("List rows and a New Beat button with a plus icon are shown", await rows.count() === 4 && await page.locator("[data-beat-new] svg").count() === 1 && (await page.locator("[data-beat-new]").textContent()).trim() === "New Beat");
    check("The list is scrollable", await page.locator(".beats-list").evaluate(element => ["auto", "scroll"].includes(getComputedStyle(element).overflowY)));

    const review = row("beat-review"), paused = row("beat-notes");
    check("Active row shows the target session title on one line", await review.locator(".beat-session").textContent() === "Design reviewer" || await review.locator(".beat-session").textContent() === await page.evaluate(() => beatSessionTitle("reviewer")));
    check("Active status text and monospace cron are shown", await review.locator(".beat-status").textContent() === "Active" && await review.locator(".beat-cron-text").textContent() === "*/10 * * * *" && (await review.locator(".beat-cron-text").evaluate(element => getComputedStyle(element).fontFamily)).includes("monospace"));
    check("Next line uses 'Wed, Oct 7 at 9:00 AM' formatting", nextPattern.test(await review.locator(".beat-next").textContent()));
    check("Row actions are Pause, Edit and a right-aligned Delete", (await review.locator(".beat-actions button").allTextContents()).join("|") === "Pause|Edit|Delete" && await review.locator(".beat-actions > .beat-delete").evaluate(element => getComputedStyle(element).marginLeft !== "0px"));
    check("Prompt is secondary text clamped to two lines", await review.locator(".beat-prompt-text").evaluate(element => getComputedStyle(element).webkitLineClamp === "2"));
    check("Paused row: Paused status, no Next line, Resume action", await paused.locator(".beat-status").textContent() === "Paused" && await paused.locator(".beat-next").count() === 0 && (await paused.locator(".beat-actions button").allTextContents()).join("|") === "Resume|Edit|Delete");

    const local = await page.evaluate(() => ({
      next: nextCron("30 9 * * *", Date.UTC(2026, 9, 10, 0, 0)),
      sunday7: nextCron("0 0 * * 7", Date.UTC(2026, 9, 10)) === nextCron("0 0 * * 0", Date.UTC(2026, 9, 10)),
      label: beatTime(nextCron("30 9 * * *", Date.UTC(2026, 9, 10, 0, 0))),
      steps: nextCronTimes("*/20 * * * *", Date.UTC(2026, 9, 10, 0, 0), 3).map(time => new Date(time).getMinutes())
    }));
    check("Cron is evaluated in the local time zone, not UTC (Asia/Kolkata 09:30 = 04:00 UTC)", local.next === Date.UTC(2026, 9, 10, 4, 0) && local.label === "Sat, Oct 10 at 9:30 AM");
    check("Weekday 7 means Sunday and steps still work", local.sunday7 && local.steps.join(",") === "40,0,20");

    await review.getByRole("button", { name: "Pause" }).click();
    check("Pause turns a Beat off; Resume replaces Pause and Next disappears", await page.evaluate(() => state.beats.find(beat => beat.id === "beat-review").enabled === false) && await review.locator(".beat-status").textContent() === "Paused" && await review.locator(".beat-next").count() === 0 && await review.getByRole("button", { name: "Resume" }).count() === 1);
    for (const id of ["beat-progress", "beat-checks"]) await row(id).getByRole("button", { name: "Pause" }).click();
    check("Icon is plain once no Beat is enabled", !await button.evaluate(element => element.classList.contains("lit")) && await button.evaluate(element => getComputedStyle(element).filter) === "none");
    await review.getByRole("button", { name: "Resume" }).click();
    check("Resume lights the icon again and restores Next", await button.evaluate(element => element.classList.contains("lit")) && nextPattern.test(await review.locator(".beat-next").textContent()));
    for (const id of ["beat-progress", "beat-checks"]) await row(id).getByRole("button", { name: "Resume" }).click();

    await review.getByRole("button", { name: "Delete", exact: true }).click();
    check("Delete turns inline into Delete? and Keep", (await review.locator(".beat-actions").textContent()).includes("Delete?") && await review.getByRole("button", { name: "Keep" }).count() === 1 && await rows.count() === 4);
    await review.getByRole("button", { name: "Keep" }).click();
    check("Keep restores the row without deleting", await rows.count() === 4 && await review.getByRole("button", { name: "Delete", exact: true }).count() === 1);
    await review.getByRole("button", { name: "Delete", exact: true }).click();
    await review.getByRole("button", { name: "Delete?" }).click();
    check("Delete? removes the Beat and leaves its session alone", await rows.count() === 3 && await page.evaluate(() => !state.beats.some(beat => beat.id === "beat-review") && !state.dismissed.reviewer));

    await page.evaluate(() => { state.beats.push({ id: "beat-gone", agentId: "abcdefghijkl", cron: "0 * * * *", prompt: "x", enabled: false }); state.dismissed.notes = true; commit(); });
    check("A Beat whose session is not open shows 'Session <first 8 chars> (not open)'", await row("beat-gone").locator(".beat-session").textContent() === "Session abcdefgh (not open)" && await row("beat-notes").locator(".beat-session").textContent() === "Session notes (not open)");
    await page.evaluate(() => { state.beats = state.beats.filter(beat => beat.id !== "beat-gone"); delete state.dismissed.notes; commit(); });

    await row("beat-progress").getByRole("button", { name: "Edit" }).click();
    check("Edit shows the form in the same popover with the session picker", await popover.isVisible() && await page.locator("#beats-title").textContent() === "Edit Beat" && await page.locator("#beat-session").inputValue() === "implementer");
    check("Form has presets, a live next-3 preview in local time, a byte counter, Save and Cancel", await page.locator("#beat-preset option").allTextContents().then(labels => ["Every 5 minutes", "Every 15 minutes", "Hourly", "Weekdays at 9:00"].every(label => labels.includes(label))) && await page.locator("#beat-preview li").count() === 3 && /Asia\/(Kolkata|Calcutta)/.test(await page.locator(".beat-preview-title").textContent()) && (await page.locator("#beat-bytes").textContent()).endsWith("/ 4096 bytes") && await page.getByRole("button", { name: "Save", exact: true }).count() === 1 && await page.locator("[data-beat-cancel]").count() === 1);
    await page.locator("#beat-preset").selectOption("0 9 * * 1-5");
    check("Choosing a preset fills the cron field and refreshes the preview", await page.locator("#beat-cron").inputValue() === "0 9 * * 1-5" && (await page.locator("#beat-preview li").allTextContents()).every(text => /^(Mon|Tue|Wed|Thu|Fri), .* at 9:00 AM$/.test(text)));
    for (const invalid of ["@daily", "mon * * * *", "* * * *", "61 * * * *", "* * * * 8", "*/0 * * * *"]) {
      await page.locator("#beat-cron").fill(invalid);
      check(`Invalid cron "${invalid}" shows an inline error and blocks the preview`, (await page.locator("#beat-cron-error").textContent()).length > 0 && await page.locator("#beat-cron").getAttribute("aria-invalid") === "true" && (await page.locator("#beat-preview").textContent()).includes("Fix the cron"));
    }
    await save();
    check("Saving an invalid cron keeps the form open and the Beat unchanged", await page.locator("#beat-form").isVisible() && await page.evaluate(() => state.beats.find(beat => beat.id === "beat-progress").cron === "*/15 * * * *"));
    await page.locator("#beat-cron").fill("0 7 * * 1,3,5");
    check("Lists, ranges and steps validate and clear the error", await page.locator("#beat-cron-error").textContent() === "" && await page.locator("#beat-preview li").count() === 3);
    await page.locator("#beat-prompt").fill("   ");
    await save();
    check("An empty prompt shows an inline error", (await page.locator("#beat-prompt-error").textContent()).includes("prompt") && await page.locator("#beat-form").isVisible());
    await page.locator("#beat-prompt").fill("é".repeat(2049));
    check("Byte counter counts UTF-8 bytes and flags more than 4096", await page.locator("#beat-bytes").textContent() === "4098 / 4096 bytes" && await page.locator("#beat-bytes").evaluate(element => element.classList.contains("over")) && (await page.locator("#beat-prompt-error").textContent()).includes("4096"));
    await save();
    check("An over-limit prompt cannot be saved", await page.locator("#beat-form").isVisible() && await page.evaluate(() => state.beats.find(beat => beat.id === "beat-progress").prompt.startsWith("Check progress")));
    await page.locator("#beat-prompt").fill("Check the build every other morning.");
    await save();
    check("Saving updates the row, returns to the list and persists", await page.locator("#beat-form").count() === 0 && (await row("beat-progress").locator(".beat-prompt-text").textContent()) === "Check the build every other morning." && await row("beat-progress").locator(".beat-cron-text").textContent() === "0 7 * * 1,3,5" && await page.evaluate(() => JSON.parse(localStorage.getItem(STORAGE)).beats.some(beat => beat.id === "beat-progress" && beat.cron === "0 7 * * 1,3,5")));

    await page.evaluate(() => { state.dismissed.notes = true; commit(); });
    await page.locator("[data-beat-new]").click();
    check("New Beat opens an empty form listing open sessions only", await page.locator("#beats-title").textContent() === "New Beat" && await page.locator("#beat-prompt").inputValue() === "" && !(await page.locator("#beat-session option").evaluateAll(options => options.map(option => option.value))).includes("notes") && (await page.locator("#beat-session option").count()) > 1);
    await page.evaluate(() => { delete state.dismissed.notes; });
    await page.locator("#beat-session").selectOption("researcher");
    await page.locator("#beat-prompt").fill("Summarize new research notes.");
    await save();
    check("A new Beat is added as Active for the chosen session", await rows.count() === 4 && await page.evaluate(() => { const beat = state.beats.at(-1); return beat.agentId === "researcher" && beat.enabled && beat.cron === "*/15 * * * *"; }));

    await page.evaluate(() => { for (let index = state.beats.filter(beat => beat.agentId === "coordinator").length; index < 16; index++) state.beats.push({ id: `fill-${index}`, agentId: "coordinator", cron: "0 * * * *", prompt: "fill", enabled: false }); commit(); });
    await page.locator("[data-beat-new]").click();
    await page.locator("#beat-session").selectOption("coordinator");
    await page.locator("#beat-prompt").fill("One too many.");
    await save();
    check("At most 16 Beats per session", (await page.locator("#beat-prompt-error").textContent()).includes("16") && await page.evaluate(() => state.beats.filter(beat => beat.agentId === "coordinator").length === 16));
    await page.locator("[data-beat-cancel]").click();
    await page.evaluate(() => { state.beats = state.beats.filter(beat => !beat.id.startsWith("fill-")); for (let index = 0; state.beats.length < 256; index++) state.beats.push({ id: `bulk-${index}`, agentId: `bulk-session-${Math.floor(index / 16)}`, cron: "0 * * * *", prompt: "bulk", enabled: false }); commit(); });
    await page.locator("[data-beat-new]").click();
    await page.locator("#beat-prompt").fill("Over the total.");
    await save();
    check("At most 256 Beats in total", (await page.locator("#beat-prompt-error").textContent()).includes("256") && await page.evaluate(() => state.beats.length === 256));
    await page.locator("[data-beat-cancel]").click();
    await page.evaluate(() => { state.beats = initialBeats(); commit(); });

    const text = await popover.innerText();
    const disclaimer = "Synthetic prototype · nothing is scheduled and no real prompts are sent.";
    check("Popover has no queue, Run now, simulator, availability, recovery or UTC wording", !/queue|run now|simulat|availab|recover|utc/i.test(text.replace(disclaimer, "")));
    check("Popover says nothing is sent", text.includes("no real prompts are sent"));
    const pageText = await page.evaluate(() => document.body.textContent);
    check("Explanatory copy no longer describes Beats as a tab, UTC or a queue", !/UTC|can wait once|1 queued|Pending queue|Cancel queued|Run now|Add beat/.test(pageText) && pageText.includes("Beats is a popover, not a tab") && pageText.includes("no scheduler"));

    await page.locator("#beats-popover [data-beats-close]").click();
    check("The × button closes the popover and returns focus to the icon", !await popover.isVisible() && await button.evaluate(element => element === document.activeElement));
    await open();
    await page.locator(".stage-header h2").click();
    check("Clicking away closes the popover", !await popover.isVisible());
    await open();
    await page.keyboard.press("Escape");
    check("Escape closes the popover", !await popover.isVisible());
    await page.reload();
    await open();
    check("Beats persist across reload", await rows.count() === 4);
    await page.keyboard.press("Escape");

    await page.setViewportSize({ width: 700, height: 600 });
    await open();
    check("Popover stays inside a small viewport", await popover.evaluate(element => { const box = element.getBoundingClientRect(); return box.left >= 0 && box.right <= innerWidth && box.bottom <= innerHeight; }));
    await page.keyboard.press("Escape");
    await page.setViewportSize({ width: 1512, height: 940 });

    await page.locator("#taskboard-button").click();
    check("Taskboard still opens as a tab", await page.evaluate(() => state.active === "tool-taskboard" && !!state.utilityTabs.taskboard) && await page.locator("#taskboard").isVisible());
    await page.locator('#native-layout [data-tool-move="taskboard"]').click();
    await page.locator("#tool-move-workspace").selectOption("scratch");
    await page.locator("#tool-move-pane").selectOption("1");
    await page.locator('#tool-move-form button[type="submit"]').click();
    check("Taskboard still moves between workspaces and panes", await page.evaluate(() => state.utilityTabs.taskboard.workspace === "scratch" && state.utilityTabs.taskboard.pane === 1 && state.active === "tool-taskboard"));
    await page.locator('#native-layout [data-close-tool="taskboard"]').click();
    check("Taskboard still closes", await page.evaluate(() => !state.utilityTabs.taskboard && state.active !== "tool-taskboard") && await page.locator("#taskboard").count() === 0);

    check("No JavaScript runtime errors", errors.length === 0);
    check("No external requests", requests.every(url => url.startsWith(baseURL)));
    console.log(`PASS: ${checks.length} Beats popover checks.`);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
