"use strict";

// Synthetic interaction model only: no scheduler, network, or provider connection.
function initialBeats() {
  const seed = (id, agentId, prompt, cron, enabled = true) => ({
    id, agentId, prompt, cron, enabled, pending: false, pendingSince: null,
    lastAttempt: null, lastDelivered: null, deliveries: 0, skipped: 0, error: "", events: []
  });
  return [
    { ...seed("beat-review", "reviewer", "Review open pull requests. Summarize blockers and any changes that need my attention.", "*/10 * * * *"), pending: true, pendingSince: Date.UTC(2026, 8, 25, 19, 58) },
    seed("beat-progress", "implementer", "Check progress against the current issue. Continue the next unblocked step.", "*/15 * * * *"),
    seed("beat-checks", "reviewer", "Check the latest CI results. Report new failures without retrying or merging anything.", "0 * * * *"),
    seed("beat-notes", "notes", "Review my project notes and suggest the next useful action.", "0 9 * * 1-5", false)
  ];
}

function parseCron(expression) {
  const parts = expression.trim().split(/\s+/);
  if (parts.length !== 5) throw new Error("Use five fields: minute, hour, day, month, weekday.");
  const bounds = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];
  const fields = parts.map((field, index) => {
    if (field.length > 80) throw new Error("That cron field is too long for this prototype.");
    const [min, max] = bounds[index], values = new Set();
    for (const term of field.split(",")) {
      const match = /^(\*|\d+(?:-\d+)?)(?:\/([1-9]\d*))?$/.exec(term);
      if (!match) throw new Error("Use numeric fields, *, ranges, lists, or / steps. Names and seconds are not supported in this demo.");
      const step = match[2] ? Number(match[2]) : 1;
      let start = min, end = max;
      if (match[1] !== "*") {
        const range = match[1].split("-").map(Number);
        start = range[0];
        end = range[1] ?? (match[2] ? max : start);
      }
      if (start < min || end > max || start > end || step > max - min + 1) throw new Error(`Field ${index + 1} must stay within ${min}–${max}, with a valid step.`);
      for (let value = start; value <= end; value += step) values.add(index === 4 && value === 7 ? 0 : value);
    }
    return values;
  });
  return { fields, dayWildcard: parts[2].startsWith("*"), weekdayWildcard: parts[4].startsWith("*") };
}

function nextCron(expression, after) {
  const { fields: [minutes, hours, days, months, weekdays], dayWildcard, weekdayWildcard } = parseCron(expression);
  const date = new Date(Math.floor(after / 60000) * 60000 + 60000);
  const limit = date.getTime() + 366 * 86400000;
  while (date.getTime() < limit) {
    const day = days.has(date.getUTCDate()), weekday = weekdays.has(date.getUTCDay());
    const matchesDay = dayWildcard ? weekday : weekdayWildcard ? day : day || weekday;
    if (months.has(date.getUTCMonth() + 1) && matchesDay && hours.has(date.getUTCHours()) && minutes.has(date.getUTCMinutes())) return date.getTime();
    date.setUTCMinutes(date.getUTCMinutes() + 1);
  }
  return null;
}

function cronDescription(expression) {
  const parts = expression.trim().split(/\s+/);
  if (parts.slice(1).every(part => part === "*") && /^\*\/\d+$/.test(parts[0])) {
    const step = Number(parts[0].slice(2));
    return 60 % step === 0 ? `Every ${step} minute${step === 1 ? "" : "s"}` : `Every ${step}th minute within each hour; resets hourly`;
  }
  if (expression.trim() === "* * * * *") return "Every minute";
  if (/^\d+$/.test(parts[0]) && parts.slice(1).every(part => part === "*")) return `Hourly at minute ${parts[0]}`;
  if (/^\d+$/.test(parts[0]) && /^\d+$/.test(parts[1]) && parts[2] === "*" && parts[3] === "*") {
    const time = `${parts[1].padStart(2, "0")}:${parts[0].padStart(2, "0")}`;
    if (parts[4] === "*") return `Daily at ${time} UTC`;
    if (parts[4] === "1-5") return `Weekdays at ${time} UTC`;
  }
  return "Custom cron schedule · UTC";
}

function triggerBeat(beat, availability, now, source) {
  if (source === "schedule" && !beat.enabled) return { beat, message: "Paused: this occurrence was not queued." };
  const next = { ...beat, lastAttempt: now, error: "" };
  let message;
  if (beat.pending) {
    next.skipped += 1;
    message = "Already queued. No second prompt added.";
  } else if (availability === "unavailable") {
    next.error = "Target agent unavailable. No prompt delivered or redirected.";
    message = next.error;
  } else if (availability === "busy" || availability === "input") {
    next.pending = true;
    next.pendingSince = now;
    message = availability === "input" ? "Queued once. Awaiting human input; no approval answered." : "Queued once. Waiting for the agent to become available.";
  } else {
    next.pending = false;
    next.pendingSince = null;
    next.lastDelivered = now;
    next.deliveries += 1;
    message = "Prompt delivered · simulated. Agent completion is not implied.";
  }
  next.events = [{ at: now, message }, ...beat.events].slice(0, 5);
  return { beat: next, message };
}

function utilitySurfaces(tabs = {}) {
  return Object.entries(tabs).map(([tool, location]) => ({
    id: `tool-${tool}`, tool, kind: "tool", name: tool === "beats" ? "Beats" : "Taskboard",
    workspace: location.workspace, pane: location.pane, state: "idle", glyph: tool, color: "#afb5c0"
  }));
}

function validUtilityState(saved) {
  const tabs = saved.utilityTabs ?? {};
  if (!tabs || typeof tabs !== "object" || Array.isArray(tabs)) return false;
  const workspaceIDs = ["design", "scratch", ...(saved.createdDirectories || []).map(record => record.id)];
  if (!Object.entries(tabs).every(([tool, location]) => ["beats", "taskboard"].includes(tool) && location && workspaceIDs.includes(location.workspace) && [1, 2].includes(location.pane))) return false;
  if (saved.sidebarOrders !== undefined && (!saved.sidebarOrders || typeof saved.sidebarOrders !== "object" || Array.isArray(saved.sidebarOrders) || !Object.values(saved.sidebarOrders).every(order => Array.isArray(order) && order.every(id => typeof id === "string") && new Set(order).size === order.length))) return false;
  if (saved.beats !== undefined && (!Array.isArray(saved.beats) || !saved.beats.every(beat => beat && typeof beat.id === "string" && typeof beat.agentId === "string" && typeof beat.cron === "string" && typeof beat.prompt === "string" && typeof beat.enabled === "boolean" && typeof beat.pending === "boolean" && Array.isArray(beat.events)))) return false;
  if (saved.beatAvailability !== undefined && (!saved.beatAvailability || typeof saved.beatAvailability !== "object" || Array.isArray(saved.beatAvailability))) return false;
  return saved.beatClock === undefined || Number.isFinite(saved.beatClock);
}

let movingTool = null, removingBeat = null, simulatorOpen = false, eventsOpen = false;
const beatDrafts = new Map();

function openUtility(tool) {
  if (!["beats", "taskboard"].includes(tool)) return;
  if (!state.utilityTabs[tool]) state.utilityTabs[tool] = { workspace: activeWorkspace(), pane: 2 };
  focusItem(`tool-${tool}`);
}

function moveUtility(tool, workspace, pane) {
  const item = byId(`tool-${tool}`);
  if (!item || !workspaces.some(candidate => candidate.id === workspace) || ![1, 2].includes(pane)) { notify("Cannot move this prototype tab: destination unavailable."); return; }
  const source = `${item.workspace}:${paneFor(item)}`;
  state.tabOrder[source] = orderedPaneItems(item.workspace, paneFor(item)).filter(candidate => candidate.id !== item.id).map(candidate => candidate.id);
  if (state.paneSelected[source] === item.id) delete state.paneSelected[source];
  state.utilityTabs[tool] = { workspace, pane };
  delete state.panes[item.id];
  const destination = `${workspace}:${pane}`;
  state.tabOrder[destination] = [...orderedPaneItems(workspace, pane).filter(candidate => candidate.id !== item.id).map(candidate => candidate.id), item.id];
  state.paneSelected[destination] = item.id;
  state.workspaceCollapsed[workspace] = false;
  commit();
  notify(`${item.name} moved to ${workspaces.find(candidate => candidate.id === workspace).name}, Pane ${pane}. Agent targets and Beats unchanged.`);
}

function closeUtility(tool) {
  const id = `tool-${tool}`, item = byId(id);
  if (!item) return;
  const fallback = orderedPaneItems(item.workspace, paneFor(item)).find(candidate => candidate.id !== id) || surfaces.find(candidate => candidate.workspace === item.workspace && !state.dismissed[candidate.id]) || surfaces.find(candidate => !state.dismissed[candidate.id]);
  if (!fallback) { notify("No remaining prototype surface is available."); return; }
  delete state.utilityTabs[tool];
  delete state.panes[id];
  for (const key of Object.keys(state.paneSelected)) if (state.paneSelected[key] === id) delete state.paneSelected[key];
  for (const key of Object.keys(state.tabOrder)) state.tabOrder[key] = state.tabOrder[key].filter(candidate => candidate !== id);
  if (state.active === id) state.active = fallback.id;
  commit();
  notify(`${item.name} view closed. Saved Beats and agent sessions are unchanged.`);
}

function renderTaskboard() {
  return `<section id="taskboard" class="tool-panel" aria-label="Taskboard"><header class="tool-panel-header"><div><h2>Taskboard</h2><p>All workspaces · synthetic agent activity</p></div></header><p class="experiment-note">Exploratory content tab. Switching tabs changes the view, not the agents.</p><div class="board-columns">${["input", "working", "idle", "done", "unknown"].map(status => `<section data-board-status="${status}"><h3>${({ working: "Working", input: "Needs you", idle: "Idle", done: "Done", unknown: "Unknown" })[status]}</h3>${surfaces.filter(item => item.kind === "agent" && item.state === status && !state.dismissed[item.id]).map(item => `<button data-focus="${item.id}">${iconFor(item)}<b>${escapeHTML(item.name)}</b><span>${escapeHTML(item.task)}</span>${tagMarkup(item, true)}<small>${escapeHTML(workspaces.find(workspace => workspace.id === item.workspace).name)}</small></button>`).join("")}</section>`).join("")}</div><details class="quiet-history"><summary>Quiet skill & shell history · synthetic</summary><p>Skill: design review · completed<br>Shell: local build check · completed</p><p>Activity records only; no separate session controls inferred.</p></details></section>`;
}

function availabilityFor(agentId) {
  const agent = byId(agentId);
  if (!agent || agent.kind !== "agent" || state.dismissed[agentId]) return "unavailable";
  return state.beatAvailability[agentId] || ({ working: "busy", input: "input", unknown: "unavailable" }[agent.state] || "available");
}

function beatTime(timestamp) {
  return timestamp === null || timestamp === undefined ? "Not yet" : new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "short", hour: "2-digit", minute: "2-digit" }).format(timestamp);
}

function beatStatus(beat) {
  if (beat.error) return "Delivery failed";
  if (availabilityFor(beat.agentId) === "unavailable") return "Agent unavailable";
  if (beat.pending) return beat.enabled ? "1 queued" : "Paused · 1 queued";
  return beat.enabled ? "Active" : "Paused";
}

function draftFor(beat) {
  if (!beatDrafts.has(beat.id)) beatDrafts.set(beat.id, { agentId: beat.agentId, cron: beat.cron, prompt: beat.prompt });
  return beatDrafts.get(beat.id);
}

function selectedBeat() {
  if (state.selectedBeat === "new") return { id: "new", agentId: surfaces.find(item => item.kind === "agent" && !state.dismissed[item.id])?.id || "", cron: "*/15 * * * *", prompt: "", enabled: true, pending: false, events: [] };
  return state.beats.find(beat => beat.id === state.selectedBeat) || state.beats[0];
}

function beatIsDirty(beat, draft) {
  return beat.id === "new" || ["agentId", "cron", "prompt"].some(key => beat[key] !== draft[key]);
}

function nextBeatText(beat) {
  if (!beat.enabled) return "Paused";
  try { const next = nextCron(beat.cron, state.beatClock); return next === null ? "No match in next 366 days" : `${beatTime(next)} UTC`; }
  catch (error) { return `Invalid schedule: ${error.message}`; }
}

function renderBeats() {
  const beat = selectedBeat();
  return `<section id="beats-panel" class="tool-panel" aria-label="Beats"><header class="tool-panel-header"><div><h2>Beats</h2><p>A cron expression. A prompt. An agent.</p></div><button class="primary" data-beat-add>+ Add beat</button></header><div class="beat-scope"><span>All workspaces</span><span>Synthetic · no prompts sent</span></div><div class="beats-layout"><nav class="beat-list" aria-label="Saved Beats">${state.beats.map(item => {
    const agent = byId(item.agentId), selected = beat?.id === item.id;
    return `<button class="beat-list-item" data-beat-select="${item.id}" ${selected ? 'aria-current="true"' : ""}><span class="beat-agent">${agent ? iconFor(agent) : icon("robot")} ${escapeHTML(agent?.name || "Agent unavailable")}</span>${agent ? tagMarkup(agent, true) : ""}<b>${escapeHTML(item.prompt.split("\n")[0])}</b><code>${escapeHTML(item.cron)}</code><span class="beat-list-status ${item.error ? "failed" : item.pending ? "queued" : item.enabled ? "enabled" : ""}"><span class="beat-status-dot"></span>${beatStatus(item)}</span></button>`;
  }).join("") || '<p class="empty">No Beats yet. Add a cron prompt for an agent.</p>'}<p class="beat-list-count">${state.beats.length} Beats · ${state.beats.filter(item => item.enabled).length} enabled</p></nav><div class="beat-detail">${beat ? renderBeatEditor(beat) : '<div class="beat-empty"><h3>Keep a useful prompt on repeat.</h3><p>Choose an agent, write a prompt, and give it a cron expression.</p><button data-beat-add class="primary">Add your first beat</button></div>'}</div></div></section>`;
}

function renderBeatEditor(beat) {
  const draft = draftFor(beat), dirty = beatIsDirty(beat, draft), isNew = beat.id === "new";
  const agents = surfaces.filter(item => item.kind === "agent");
  return `<div class="beat-editor-heading"><h3>${isNew ? "New beat" : "Cron prompt"}</h3><span id="beat-draft-status">${dirty ? "Unsaved changes" : "Saved locally"}</span></div>
    <form id="beat-editor-form" data-beat-id="${beat.id}">
      <label>Agent<select id="beat-agent">${!agents.some(agent => agent.id === draft.agentId) ? `<option value="${escapeHTML(draft.agentId)}" selected disabled>${draft.agentId ? "Saved agent unavailable" : "Choose an available agent"}</option>` : ""}${agents.map(agent => `<option value="${agent.id}" ${draft.agentId === agent.id ? "selected" : ""} ${state.dismissed[agent.id] ? "disabled" : ""}>${escapeHTML(agent.name)} · ${workspaces.find(workspace => workspace.id === agent.workspace).name}${state.dismissed[agent.id] ? " · closed" : ""}</option>`).join("")}</select></label>
      <div class="beat-field-label"><label for="beat-cron">Cron expression</label><span>UTC · demo</span></div>
      <div class="cron-input-row"><input id="beat-cron" value="${escapeHTML(draft.cron)}" maxlength="100" spellcheck="false" aria-describedby="beat-cron-description" required><button type="button" data-cron-builder title="Build cron expression" aria-label="Build cron expression" aria-haspopup="dialog">${icon("wand")}</button></div>
      <p id="beat-cron-description" class="field-hint">${escapeHTML(cronDescription(draft.cron))}</p>
      <label>Prompt<textarea id="beat-prompt" rows="5" maxlength="2000" placeholder="What should this agent do on each beat?" required>${escapeHTML(draft.prompt)}</textarea></label>
      <p id="beat-form-error" class="beat-error" role="alert"></p>
      <div class="beat-save-row"><button type="submit" class="primary">Save beat</button><button type="button" data-beat-discard="${beat.id}">Discard edits</button>${!isNew ? `<button type="button" data-beat-remove="${beat.id}" class="beat-remove">Remove</button>` : ""}</div>
    </form>
    ${removingBeat === beat.id ? `<div class="beat-remove-confirm" role="alert"><p>Remove this Beat and its queued occurrence? The agent stays open.</p><button data-beat-remove-confirm="${beat.id}">Remove beat</button><button data-beat-remove-cancel>Keep beat</button></div>` : ""}
    ${isNew ? '<p class="field-hint">No schedule runs in this prototype. Save to explore delivery and queue states.</p>' : `<div class="beat-run-actions"><button data-beat-run="${beat.id}" ${dirty ? "disabled" : ""}>Run now</button><button data-beat-pause="${beat.id}">${beat.enabled ? "Pause future runs" : "Resume schedule"}</button>${beat.pending ? `<button data-beat-cancel="${beat.id}">Cancel queued</button>` : ""}</div>
      <p class="field-hint">Run now uses the saved prompt, even while paused. Delivery is not task completion.</p>
      <div class="beat-diagnostic-status ${beat.error ? "failed" : ""}"><span>${beatStatus(beat)}</span>${beat.pending ? "<small>One pending prompt for this Beat. Further occurrences add nothing.</small>" : ""}${beat.error ? `<small>${escapeHTML(beat.error)}</small>` : ""}</div>
      <dl class="beat-diagnostics"><div><dt>Next occurrence</dt><dd>${nextBeatText(beat)}</dd></div><div><dt>Last delivery</dt><dd>${beatTime(beat.lastDelivered)}</dd></div><div><dt>Last trigger</dt><dd>${beatTime(beat.lastAttempt)}</dd></div><div><dt>Extra occurrences skipped</dt><dd>${beat.skipped}</dd></div></dl>
      <div class="beat-binding"><span>Target: <code>demo:${escapeHTML(beat.agentId)}</code></span><button data-beat-reveal="${beat.agentId}">Reveal agent ↗</button></div>
      <details class="beat-simulator" ${simulatorOpen ? "open" : ""}><summary>Explore scheduling behavior</summary><p>Demo clock: ${beatTime(state.beatClock)} UTC. Nothing runs automatically.</p><label>Simulated target state<select id="beat-availability" data-agent-id="${beat.agentId}">${[["available", "Available"], ["busy", "Busy"], ["input", "Awaiting human input"], ["unavailable", "Unavailable"]].map(([value, label]) => `<option value="${value}" ${availabilityFor(beat.agentId) === value ? "selected" : ""}>${label}</option>`).join("")}</select></label><button data-beat-tick="${beat.id}">Simulate scheduled occurrence</button><p>Try twice while busy: only one prompt queues. Set Available to deliver it. Pause stops future ticks; use Cancel queued to remove an existing pending prompt.</p></details>
      ${beat.events.length ? `<details class="beat-log" ${eventsOpen ? "open" : ""}><summary>Recent simulated events</summary><ol>${beat.events.map(event => `<li><time>${beatTime(event.at)}</time><span>${escapeHTML(event.message)}</span></li>`).join("")}</ol></details>` : ""}`}`;
}

function updateBeatDraft() {
  const form = document.querySelector("#beat-editor-form");
  if (!form) return;
  const draft = { agentId: $("#beat-agent").value, cron: $("#beat-cron").value, prompt: $("#beat-prompt").value };
  beatDrafts.set(form.dataset.beatId, draft);
  const dirty = beatIsDirty(selectedBeat(), draft);
  $("#beat-draft-status").textContent = dirty ? "Unsaved changes" : "Saved locally";
  const run = document.querySelector("[data-beat-run]");
  if (run) run.disabled = dirty;
  try {
    parseCron(draft.cron);
    $("#beat-cron-description").textContent = cronDescription(draft.cron);
    $("#beat-cron").removeAttribute("aria-invalid");
  } catch (error) {
    $("#beat-cron-description").textContent = error.message;
    $("#beat-cron").setAttribute("aria-invalid", "true");
  }
}

function simulateBeat(id, source) {
  const index = state.beats.findIndex(beat => beat.id === id);
  if (index < 0) return;
  state.beatClock += 60000;
  const result = triggerBeat(state.beats[index], availabilityFor(state.beats[index].agentId), state.beatClock, source);
  state.beats[index] = result.beat;
  commit();
  notify(result.message);
}

function cronBuilderValue() {
  const frequency = $("#cron-frequency").value;
  const interval = Number($("#cron-interval").value), minute = Number($("#cron-minute").value);
  const [hour, timeMinute] = $("#cron-time").value.split(":").map(Number);
  if (frequency === "minutes") {
    if (!Number.isInteger(interval) || interval < 1 || interval > 59) throw new Error("Choose a minute step from 1 to 59.");
    return `*/${interval} * * * *`;
  }
  if (frequency === "hourly") {
    if (!Number.isInteger(minute) || minute < 0 || minute > 59) throw new Error("Choose a minute from 0 to 59.");
    return `${minute} * * * *`;
  }
  if (!Number.isInteger(hour) || !Number.isInteger(timeMinute)) throw new Error("Choose a valid time.");
  return `${timeMinute} ${hour} * * ${frequency === "weekdays" ? "1-5" : frequency === "weekly" ? $("#cron-weekday").value : "*"}`;
}

function renderCronBuilder() {
  const frequency = $("#cron-frequency").value;
  for (const [field, visible] of [["interval", frequency === "minutes"], ["minute", frequency === "hourly"], ["time", ["daily", "weekdays", "weekly"].includes(frequency)], ["weekday", frequency === "weekly"]]) {
    $(`#cron-${field}-label`).hidden = !visible;
    $(`#cron-${field}`).disabled = !visible;
  }
  try { const expression = cronBuilderValue(); $("#cron-preview").textContent = `${expression}\n${cronDescription(expression)}`; $("#cron-form [type=submit]").disabled = false; }
  catch (error) { $("#cron-preview").textContent = error.message; $("#cron-form [type=submit]").disabled = true; }
}

document.addEventListener("click", event => {
  const button = event.target.closest("button");
  if (!button) return;
  const d = button.dataset;
  if (d.openTool) { openUtility(d.openTool); return; }
  if (d.closeTool) { closeUtility(d.closeTool); return; }
  if ("openSettings" in d) { renderInstallStatus(); openDialog("settings-dialog"); return; }
  if ("fermata" in d) { state.fermata = !state.fermata; commit(); notify(`Fermata ${state.fermata ? "on" : "off"} · simulated. Mac sleep settings are unchanged.`); return; }
  if (d.toolMove) {
    movingTool = d.toolMove;
    const item = byId(`tool-${movingTool}`);
    $("#tool-move-title").textContent = `Move ${item.name}`;
    $("#tool-move-workspace").innerHTML = workspaces.map(workspace => `<option value="${workspace.id}">${escapeHTML(workspace.name)}</option>`).join("");
    $("#tool-move-workspace").value = item.workspace;
    $("#tool-move-pane").value = String(paneFor(item));
    openDialog("tool-move-dialog"); return;
  }
  if ("beatAdd" in d) { state.selectedBeat = "new"; removingBeat = null; commit(); $("#beat-prompt").focus(); return; }
  if (d.beatSelect) { state.selectedBeat = d.beatSelect; removingBeat = null; commit(); return; }
  if (d.beatDiscard) { beatDrafts.delete(d.beatDiscard); if (d.beatDiscard === "new") state.selectedBeat = state.beats[0]?.id || ""; commit(); return; }
  if (d.beatRun) { simulateBeat(d.beatRun, "manual"); return; }
  if (d.beatTick) { simulateBeat(d.beatTick, "schedule"); return; }
  if (d.beatPause || d.beatCancel) {
    const beat = state.beats.find(item => item.id === (d.beatPause || d.beatCancel));
    if (d.beatPause) beat.enabled = !beat.enabled;
    else { beat.pending = false; beat.pendingSince = null; }
    commit(); notify(d.beatCancel ? "Queued occurrence cancelled." : beat.enabled ? "Schedule enabled · simulation only." : `Future runs paused.${beat.pending ? " The queued occurrence remains; cancel it separately." : ""}`); return;
  }
  if (d.beatRemove) { removingBeat = d.beatRemove; commit(); return; }
  if ("beatRemoveCancel" in d) { removingBeat = null; commit(); return; }
  if (d.beatRemoveConfirm) {
    state.beats = state.beats.filter(beat => beat.id !== d.beatRemoveConfirm);
    beatDrafts.delete(d.beatRemoveConfirm); state.selectedBeat = state.beats[0]?.id || ""; removingBeat = null; commit(); notify("Beat removed. Its agent is unchanged."); return;
  }
  if (d.beatReveal) {
    const agent = byId(d.beatReveal);
    if (!agent || state.dismissed[agent.id]) { notify("The exact target agent is unavailable. No replacement was selected."); return; }
    if (agent.worktree) state.collapsed[`${agent.workspace}:${agent.worktree}`] = false;
    focusItem(agent.id); return;
  }
  if ("cronBuilder" in d) {
    updateBeatDraft();
    const cron = $("#beat-cron").value.trim(), parts = cron.split(/\s+/);
    $("#cron-frequency").value = "minutes"; $("#cron-interval").value = "15";
    if (/^\*\/\d+ \* \* \* \*$/.test(cron)) $("#cron-interval").value = parts[0].slice(2);
    else if (/^\d+ \* \* \* \*$/.test(cron)) { $("#cron-frequency").value = "hourly"; $("#cron-minute").value = parts[0]; }
    else if (/^\d+ \d+ \* \* (\*|1-5|[0-6])$/.test(cron)) {
      $("#cron-frequency").value = parts[4] === "*" ? "daily" : parts[4] === "1-5" ? "weekdays" : "weekly";
      $("#cron-time").value = `${parts[1].padStart(2, "0")}:${parts[0].padStart(2, "0")}`;
      if (/^[0-6]$/.test(parts[4])) $("#cron-weekday").value = parts[4];
    }
    renderCronBuilder(); openDialog("cron-dialog"); return;
  }
  if (button.id === "reset-demo") { beatDrafts.clear(); removingBeat = null; simulatorOpen = false; eventsOpen = false; }
});

document.addEventListener("toggle", event => {
  if (event.target.matches(".beat-simulator")) simulatorOpen = event.target.open;
  if (event.target.matches(".beat-log")) eventsOpen = event.target.open;
}, true);

document.addEventListener("input", event => {
  if (["beat-agent", "beat-cron", "beat-prompt"].includes(event.target.id)) updateBeatDraft();
  if (event.target.closest("#cron-form")) renderCronBuilder();
});

document.addEventListener("change", event => {
  if (event.target.id === "beat-agent") updateBeatDraft();
  if (event.target.id !== "beat-availability") return;
  const agentId = event.target.dataset.agentId;
  state.beatAvailability[agentId] = event.target.value;
  if (availabilityFor(agentId) === "available") {
    state.beats = state.beats.map(beat => beat.agentId === agentId && beat.pending ? triggerBeat({ ...beat, pending: false }, "available", state.beatClock, "delivery").beat : beat);
  }
  commit(); notify("Synthetic target state changed. No live agent was contacted.");
});

document.addEventListener("submit", event => {
  if (event.target.id === "tool-move-form") {
    event.preventDefault(); $("#tool-move-dialog").close();
    moveUtility(movingTool, $("#tool-move-workspace").value, Number($("#tool-move-pane").value)); return;
  }
  if (event.target.id === "cron-form") {
    event.preventDefault();
    try { $("#beat-cron").value = cronBuilderValue(); updateBeatDraft(); $("#cron-dialog").close(); $("#beat-cron").focus(); }
    catch (error) { $("#cron-preview").textContent = error.message; }
    return;
  }
  if (event.target.id !== "beat-editor-form") return;
  event.preventDefault(); updateBeatDraft();
  const id = event.target.dataset.beatId, draft = beatDrafts.get(id), agent = byId(draft.agentId);
  try {
    parseCron(draft.cron);
    if (!draft.prompt.trim()) throw new Error("Write the prompt this Beat should send.");
    if (!agent || agent.kind !== "agent" || state.dismissed[agent.id]) throw new Error("Select an existing agent. The saved target will not be replaced automatically.");
    const current = state.beats.find(beat => beat.id === id);
    if (current?.pending && ["agentId", "cron", "prompt"].some(key => current[key] !== draft[key])) throw new Error("Cancel the queued occurrence before changing this Beat. Its pending prompt and target must stay unambiguous.");
    const value = { ...draft, cron: draft.cron.trim().replace(/\s+/g, " "), prompt: draft.prompt.trim() };
    if (current) Object.assign(current, value);
    else {
      const newBeat = { ...initialBeats()[1], ...value, id: `beat-${crypto.randomUUID()}`, events: [] };
      state.beats.push(newBeat); state.selectedBeat = newBeat.id;
    }
    beatDrafts.delete(id); commit(); notify("Beat saved locally. No real schedule was created.");
  } catch (error) { $("#beat-form-error").textContent = error.message; }
});

document.addEventListener("dragover", event => {
  const workspace = event.target.closest("[data-workspace]");
  if (workspace && byId(draggedId)?.kind === "tool") { event.preventDefault(); event.dataTransfer.dropEffect = "move"; }
});
