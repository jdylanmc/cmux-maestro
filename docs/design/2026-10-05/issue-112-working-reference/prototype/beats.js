"use strict";

// Synthetic interaction model only: no scheduler, network, or provider connection.
// Shipped model: Beats is a header popover; a Beat is simply on or off and Copilot runs it.
const BEAT_LIMITS = { perSession: 16, total: 256, promptBytes: 4096 };
const BEAT_PRESETS = [
  ["*/5 * * * *", "Every 5 minutes"], ["*/15 * * * *", "Every 15 minutes"],
  ["0 * * * *", "Hourly"], ["0 9 * * 1-5", "Weekdays at 9:00"]
];

function initialBeats() {
  const seed = (id, agentId, prompt, cron, enabled = true) => ({ id, agentId, prompt, cron, enabled });
  return [
    seed("beat-review", "reviewer", "Review open pull requests. Summarize blockers and any changes that need my attention.", "*/10 * * * *"),
    seed("beat-progress", "implementer", "Check progress against the current issue. Continue the next unblocked step.", "*/15 * * * *"),
    seed("beat-checks", "reviewer", "Check the latest CI results. Report new failures without retrying or merging anything.", "0 * * * *"),
    seed("beat-notes", "notes", "Review my project notes and suggest the next useful action.", "0 9 * * 1-5", false)
  ];
}

function parseCron(expression) {
  const parts = expression.trim().split(/\s+/);
  if (parts.length !== 5) throw new Error("Use five fields: minute, hour, day-of-month, month, weekday.");
  const bounds = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];
  const fields = parts.map((field, index) => {
    if (field.length > 80) throw new Error("That cron field is too long for this prototype.");
    const [min, max] = bounds[index], values = new Set();
    for (const term of field.split(",")) {
      const match = /^(\*|\d+(?:-\d+)?)(?:\/([1-9]\d*))?$/.exec(term);
      if (!match) throw new Error("Use numeric fields, *, ranges, lists, or / steps. Names and macros are not supported.");
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

// Evaluated in the viewer's local time zone, like Copilot's own scheduler.
function nextCron(expression, after) {
  const { fields: [minutes, hours, days, months, weekdays], dayWildcard, weekdayWildcard } = parseCron(expression);
  const date = new Date(Math.floor(after / 60000) * 60000 + 60000);
  const limit = date.getTime() + 366 * 86400000;
  while (date.getTime() < limit) {
    const day = days.has(date.getDate()), weekday = weekdays.has(date.getDay());
    const matchesDay = dayWildcard ? weekday : weekdayWildcard ? day : day || weekday;
    if (months.has(date.getMonth() + 1) && matchesDay && hours.has(date.getHours()) && minutes.has(date.getMinutes())) return date.getTime();
    date.setMinutes(date.getMinutes() + 1);
  }
  return null;
}

function nextCronTimes(expression, after, count) {
  const times = [];
  for (let from = after; times.length < count;) {
    const next = nextCron(expression, from);
    if (next === null) break;
    times.push(next); from = next;
  }
  return times;
}

function beatTime(timestamp) {
  const date = new Date(timestamp);
  const day = new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric" }).format(date);
  const time = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" }).format(date);
  return `${day} at ${time}`;
}

const beatZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "local time";
const beatBytes = text => new TextEncoder().encode(text).length;
const beatCronOf = value => value.trim().replace(/\s+/g, " ");

function utilitySurfaces(tabs = {}) {
  return Object.entries(tabs).map(([tool, location]) => ({
    id: `tool-${tool}`, tool, kind: "tool", name: "Taskboard",
    workspace: location.workspace, pane: location.pane, state: "idle", glyph: tool, color: "#afb5c0"
  }));
}

// Older saves modelled Beats as a content tab with queue and simulator fields; drop them.
function migrateLegacyBeatState(saved) {
  if (saved.utilityTabs && typeof saved.utilityTabs === "object" && !Array.isArray(saved.utilityTabs)) delete saved.utilityTabs.beats;
  delete saved.beatAvailability; delete saved.beatClock; delete saved.selectedBeat;
  if (Array.isArray(saved.beats)) {
    saved.beats = saved.beats.filter(beat => beat && typeof beat.id === "string" && typeof beat.agentId === "string" && typeof beat.cron === "string" && typeof beat.prompt === "string" && typeof beat.enabled === "boolean")
      .map(({ id, agentId, cron, prompt, enabled }) => ({ id, agentId, cron, prompt, enabled }));
  }
  const legacy = "tool-beats";
  if (saved.active === legacy) saved.active = "implementer";
  for (const map of [saved.panes, saved.paneSelected]) if (map && typeof map === "object") for (const key of Object.keys(map)) if (key === legacy || map[key] === legacy) delete map[key];
  if (saved.tabOrder && typeof saved.tabOrder === "object") for (const key of Object.keys(saved.tabOrder)) if (Array.isArray(saved.tabOrder[key])) saved.tabOrder[key] = saved.tabOrder[key].filter(id => id !== legacy);
}

function validUtilityState(saved) {
  const tabs = saved.utilityTabs ?? {};
  if (!tabs || typeof tabs !== "object" || Array.isArray(tabs)) return false;
  const workspaceIDs = [...workspaces.map(workspace => workspace.id), ...(saved.createdDirectories || []).map(record => record.id)];
  if (!Object.entries(tabs).every(([tool, location]) => tool === "taskboard" && location && workspaceIDs.includes(location.workspace) && [1, 2].includes(location.pane))) return false;
  if (saved.sidebarOrders !== undefined && (!saved.sidebarOrders || typeof saved.sidebarOrders !== "object" || Array.isArray(saved.sidebarOrders) || !Object.values(saved.sidebarOrders).every(order => Array.isArray(order) && order.every(id => typeof id === "string") && new Set(order).size === order.length))) return false;
  return saved.beats === undefined || (Array.isArray(saved.beats) && saved.beats.every(beat => beat && typeof beat.id === "string" && typeof beat.agentId === "string" && typeof beat.cron === "string" && typeof beat.prompt === "string" && typeof beat.enabled === "boolean"));
}

let movingTool = null;
const beatsUI = { open: false, mode: "list", confirmDelete: null, draft: null };

function openUtility(tool) {
  if (tool !== "taskboard") return;
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
  notify(`${item.name} moved to ${workspaces.find(candidate => candidate.id === workspace).name}, Pane ${pane}. Agent sessions unchanged.`);
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
  notify(`${item.name} view closed. Agent sessions are unchanged.`);
}

function renderTaskboard() {
  return `<section id="taskboard" class="tool-panel" aria-label="Taskboard"><header class="tool-panel-header"><div><h2>Taskboard</h2><p>All workspaces · synthetic agent activity</p></div></header><p class="experiment-note">Exploratory content tab. Switching tabs changes the view, not the agents.</p><div class="board-columns">${["input", "working", "idle", "done", "unknown"].map(status => `<section data-board-status="${status}"><h3>${({ working: "Working", input: "Needs you", idle: "Idle", done: "Done", unknown: "Unknown" })[status]}</h3>${surfaces.filter(item => item.kind === "agent" && item.state === status && !state.dismissed[item.id]).map(item => `<button data-focus="${item.id}">${iconFor(item)}<b>${escapeHTML(item.name)}</b><span>${escapeHTML(item.task)}</span>${tagMarkup(item, true)}<small>${escapeHTML(workspaces.find(workspace => workspace.id === item.workspace).name)}</small></button>`).join("")}</section>`).join("")}</div><details class="quiet-history"><summary>Quiet skill & shell history · synthetic</summary><p>Skill: design review · completed<br>Shell: local build check · completed</p><p>Activity records only; no separate session controls inferred.</p></details></section>`;
}

const openBeatSessions = () => surfaces.filter(item => item.kind === "agent" && !state.dismissed[item.id]);
const beatSessionTitle = agentId => {
  const agent = surfaces.find(item => item.id === agentId && item.kind === "agent" && !state.dismissed[item.id]);
  return agent ? agent.name : `Session ${agentId.slice(0, 8)} (not open)`;
};

function beatNextText(beat) {
  try {
    const next = nextCron(beat.cron, Date.now());
    return next === null ? "Next: no match in the next 366 days" : `Next: ${beatTime(next)}`;
  } catch (error) { return ""; }
}

function renderBeatRow(beat) {
  const confirming = beatsUI.confirmDelete === beat.id, next = beat.enabled ? beatNextText(beat) : "";
  return `<article class="beat-row ${beat.enabled ? "active" : "paused"}" data-beat-row="${beat.id}"><div class="beat-row-head"><span class="beat-dot" aria-hidden="true"></span><b class="beat-session">${escapeHTML(beatSessionTitle(beat.agentId))}</b><span class="beat-status">${beat.enabled ? "Active" : "Paused"}</span></div><code class="beat-cron-text">${escapeHTML(beat.cron)}</code>${next ? `<p class="beat-next">${next}</p>` : ""}<p class="beat-prompt-text">${escapeHTML(beat.prompt)}</p><div class="beat-actions"><button data-beat-toggle="${beat.id}">${beat.enabled ? "Pause" : "Resume"}</button><button data-beat-edit="${beat.id}">Edit</button>${confirming ? `<span class="beat-delete-group"><button class="beat-delete" data-beat-delete-confirm="${beat.id}">Delete?</button><button data-beat-keep>Keep</button></span>` : `<button class="beat-delete" data-beat-delete="${beat.id}">Delete</button>`}</div></article>`;
}

function renderBeatForm() {
  const draft = beatsUI.draft, sessions = openBeatSessions();
  const preset = BEAT_PRESETS.some(([cron]) => cron === beatCronOf(draft.cron)) ? beatCronOf(draft.cron) : "";
  return `<form id="beat-form" novalidate><label>Session<select id="beat-session">${!sessions.some(item => item.id === draft.agentId) ? `<option value="${escapeHTML(draft.agentId)}" selected disabled>${draft.agentId ? escapeHTML(beatSessionTitle(draft.agentId)) : "Choose an open session"}</option>` : ""}${sessions.map(item => `<option value="${item.id}" ${draft.agentId === item.id ? "selected" : ""}>${escapeHTML(item.name)}</option>`).join("")}</select></label>
    <label>Schedule preset<select id="beat-preset"><option value="" ${preset ? "" : "selected"}>Custom</option>${BEAT_PRESETS.map(([cron, label]) => `<option value="${cron}" ${preset === cron ? "selected" : ""}>${label}</option>`).join("")}</select></label>
    <label>Cron expression<input id="beat-cron" value="${escapeHTML(draft.cron)}" maxlength="100" spellcheck="false" autocomplete="off" aria-describedby="beat-cron-error beat-preview"></label>
    <p id="beat-cron-error" class="beat-error" role="alert"></p>
    <div class="beat-preview-block"><span class="beat-preview-title">Next 3 fire times · ${escapeHTML(beatZone())}</span><ol id="beat-preview"></ol></div>
    <label>Prompt<textarea id="beat-prompt" rows="4" placeholder="What should this session do on each beat?" aria-describedby="beat-prompt-error beat-bytes">${escapeHTML(draft.prompt)}</textarea></label>
    <div class="beat-byte-row"><p id="beat-prompt-error" class="beat-error" role="alert"></p><span id="beat-bytes"></span></div>
    <div class="beat-form-actions"><button type="submit" class="primary">Save</button><button type="button" data-beat-cancel>Cancel</button></div></form>`;
}

function renderBeatsPopover() {
  const popover = $("#beats-popover"), button = $("#beats-button");
  button.classList.toggle("lit", state.beats.some(beat => beat.enabled));
  button.setAttribute("aria-expanded", String(beatsUI.open));
  popover.hidden = !beatsUI.open;
  if (!beatsUI.open) return;
  positionBeatsPopover();
  if (beatsUI.mode === "form" && popover.querySelector("#beat-form")) return;
  const focused = popover.contains(document.activeElement) ? Object.entries(document.activeElement.dataset)[0] : null;
  const listScroll = popover.querySelector(".beats-list")?.scrollTop ?? 0;
  const editing = beatsUI.mode === "form";
  $("#beats-title").textContent = editing ? (beatsUI.draft.id ? "Edit Beat" : "New Beat") : "Beats";
  $("#beats-caption").hidden = editing;
  $("#beats-body").innerHTML = editing ? renderBeatForm() : `<div class="beats-list">${state.beats.map(renderBeatRow).join("") || '<p class="beats-empty">No Beats yet.</p>'}</div><button class="beat-new" data-beat-new><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true" focusable="false"><path d="M12 5v14M5 12h14"/></svg>New Beat</button>`;
  if (editing) updateBeatFormFeedback(); else popover.querySelector(".beats-list").scrollTop = listScroll;
  if (focused) popover.querySelector(`[data-${focused[0].replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}="${focused[1]}"]`)?.focus();
}

function positionBeatsPopover() {
  const popover = $("#beats-popover"), anchor = $("#beats-button").getBoundingClientRect();
  const width = popover.offsetWidth, center = anchor.left + anchor.width / 2;
  const left = Math.max(8, Math.min(center - width / 2, window.innerWidth - width - 8));
  popover.style.left = `${left}px`;
  popover.style.top = `${anchor.bottom + 10}px`;
  popover.style.maxHeight = `${Math.max(240, window.innerHeight - anchor.bottom - 22)}px`;
  popover.style.setProperty("--arrow-left", `${center - left}px`);
}

function openBeatsPopover() {
  Object.assign(beatsUI, { open: true, mode: "list", confirmDelete: null, draft: null });
  $("#beats-popover").hidden = false;
  renderBeatsPopover();
  $("#beats-popover [data-beats-close]").focus();
}

function closeBeatsPopover(restoreFocus = true) {
  if (!beatsUI.open) return;
  Object.assign(beatsUI, { open: false, mode: "list", confirmDelete: null, draft: null });
  renderBeatsPopover();
  if (restoreFocus) $("#beats-button").focus();
}

function startBeatForm(beat) {
  const sessions = openBeatSessions();
  beatsUI.mode = "form"; beatsUI.confirmDelete = null;
  beatsUI.draft = beat
    ? { id: beat.id, agentId: beat.agentId, cron: beat.cron, prompt: beat.prompt }
    : { id: "", agentId: (sessions.find(item => item.id === state.active) || sessions[0])?.id || "", cron: "*/15 * * * *", prompt: "" };
  renderBeatsPopover();
  $("#beat-prompt").focus();
}

function beatCronError(cron) {
  try { parseCron(cron); return ""; } catch (error) { return error.message; }
}

function beatPromptError(prompt) {
  if (!prompt.trim()) return "Write the prompt this Beat should send.";
  if (beatBytes(prompt) > BEAT_LIMITS.promptBytes) return `Prompt is over the ${BEAT_LIMITS.promptBytes}-byte limit.`;
  return "";
}

function setBeatInvalid(field, message) {
  if (message) field.setAttribute("aria-invalid", "true"); else field.removeAttribute("aria-invalid");
}

function updateBeatFormFeedback(showEmptyPrompt = false) {
  const draft = beatsUI.draft, cronError = beatCronError(draft.cron);
  $("#beat-cron-error").textContent = cronError;
  setBeatInvalid($("#beat-cron"), cronError);
  $("#beat-preview").innerHTML = cronError ? "<li>Fix the cron expression to preview fire times.</li>"
    : nextCronTimes(draft.cron, Date.now(), 3).map(time => `<li>${beatTime(time)}</li>`).join("") || "<li>No match in the next 366 days.</li>";
  const bytes = beatBytes(draft.prompt), promptError = bytes > BEAT_LIMITS.promptBytes || showEmptyPrompt ? beatPromptError(draft.prompt) : "";
  $("#beat-prompt-error").textContent = promptError;
  setBeatInvalid($("#beat-prompt"), promptError);
  $("#beat-bytes").textContent = `${bytes} / ${BEAT_LIMITS.promptBytes} bytes`;
  $("#beat-bytes").classList.toggle("over", bytes > BEAT_LIMITS.promptBytes);
}

function saveBeatForm() {
  const draft = beatsUI.draft, session = surfaces.find(item => item.id === draft.agentId && item.kind === "agent" && !state.dismissed[item.id]);
  updateBeatFormFeedback(true);
  if (beatCronError(draft.cron) || beatPromptError(draft.prompt)) return;
  const others = state.beats.filter(beat => beat.id !== draft.id);
  let error = "";
  if (!session) error = "Choose an open session.";
  else if (others.filter(beat => beat.agentId === session.id).length >= BEAT_LIMITS.perSession) error = `This session already has ${BEAT_LIMITS.perSession} Beats.`;
  else if (others.length >= BEAT_LIMITS.total) error = `The limit is ${BEAT_LIMITS.total} Beats in total.`;
  if (error) { $("#beat-prompt-error").textContent = error; return; }
  const value = { agentId: session.id, cron: beatCronOf(draft.cron), prompt: draft.prompt.trim() };
  const current = state.beats.find(beat => beat.id === draft.id);
  if (current) Object.assign(current, value);
  else state.beats.push({ id: `beat-${crypto.randomUUID()}`, enabled: true, ...value });
  beatsUI.mode = "list"; beatsUI.draft = null;
  commit(); notify("Beat saved · synthetic. No prompt will be sent.");
}

document.addEventListener("click", event => {
  if (beatsUI.open && !event.composedPath().some(node => node.id === "beats-popover" || node.id === "beats-button")) closeBeatsPopover(false);
  const button = event.target.closest("button");
  if (!button) return;
  const d = button.dataset;
  if (button.id === "beats-button") { beatsUI.open ? closeBeatsPopover() : openBeatsPopover(); return; }
  if ("beatsClose" in d) { closeBeatsPopover(); return; }
  if ("beatNew" in d) { startBeatForm(null); return; }
  if (d.beatEdit) { startBeatForm(state.beats.find(beat => beat.id === d.beatEdit)); return; }
  if ("beatCancel" in d) { beatsUI.mode = "list"; beatsUI.draft = null; renderBeatsPopover(); return; }
  if (d.beatToggle) {
    const beat = state.beats.find(item => item.id === d.beatToggle);
    beat.enabled = !beat.enabled; commit(); notify(beat.enabled ? "Beat resumed · synthetic." : "Beat paused · synthetic."); return;
  }
  if (d.beatDelete) { beatsUI.confirmDelete = d.beatDelete; renderBeatsPopover(); return; }
  if ("beatKeep" in d) { beatsUI.confirmDelete = null; renderBeatsPopover(); return; }
  if (d.beatDeleteConfirm) {
    state.beats = state.beats.filter(beat => beat.id !== d.beatDeleteConfirm);
    beatsUI.confirmDelete = null; commit(); notify("Beat deleted. Its session is unchanged."); return;
  }
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
});

document.addEventListener("input", event => {
  const draft = beatsUI.draft;
  if (!draft || !event.target.closest("#beat-form")) return;
  if (event.target.id === "beat-preset" && event.target.value) { draft.cron = event.target.value; $("#beat-cron").value = draft.cron; }
  else if (event.target.id === "beat-cron") { draft.cron = event.target.value; $("#beat-preset").value = BEAT_PRESETS.some(([cron]) => cron === beatCronOf(draft.cron)) ? beatCronOf(draft.cron) : ""; }
  else if (event.target.id === "beat-prompt") draft.prompt = event.target.value;
  else if (event.target.id === "beat-session") draft.agentId = event.target.value;
  updateBeatFormFeedback();
});

document.addEventListener("keydown", event => {
  if (event.key === "Escape" && beatsUI.open && !document.querySelector("dialog[open]")) { event.preventDefault(); closeBeatsPopover(); }
});

window.addEventListener("resize", () => { if (beatsUI.open) positionBeatsPopover(); });

document.addEventListener("submit", event => {
  if (event.target.id === "tool-move-form") {
    event.preventDefault(); $("#tool-move-dialog").close();
    moveUtility(movingTool, $("#tool-move-workspace").value, Number($("#tool-move-pane").value)); return;
  }
  if (event.target.id === "beat-form") { event.preventDefault(); saveBeatForm(); }
});

document.addEventListener("dragover", event => {
  const workspace = event.target.closest("[data-workspace]");
  if (workspace && byId(draggedId)?.kind === "tool") { event.preventDefault(); event.dataTransfer.dropEffect = "move"; }
});
