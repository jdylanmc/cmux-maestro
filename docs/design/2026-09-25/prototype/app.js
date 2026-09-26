"use strict";

const $ = (selector) => document.querySelector(selector);
const escapeHTML = (value) => String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const iconPaths = {
  robot: '<rect x="4" y="7" width="16" height="13" rx="5"/><path d="M12 3v4M2 12v4m20-4v4"/><circle cx="8.5" cy="13" r="1"/><circle cx="15.5" cy="13" r="1"/><path d="M9 17h6"/>',
  terminal: '<rect x="2" y="4" width="20" height="16" rx="3"/><path d="m6 9 3 3-3 3m6 1h5"/>',
  code: '<path d="m8 6-6 6 6 6m8-12 6 6-6 6M14 3l-4 18"/>',
  compass: '<circle cx="12" cy="12" r="9"/><path d="m16 8-3 5-5 3 3-5z"/>',
  leaf: '<path d="M20 3C5 2 1 11 7 17s15 2 13-14Z"/><path d="m5 21 11-13"/>',
  flask: '<path d="M9 3h6m-5 0v7L4 19q-1 2 2 2h12q3 0 2-2l-6-9V3M7 15h10"/>',
  globe: '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
  spark: '<path d="m12 2 3 7 7 3-7 3-3 7-3-7-7-3 7-3z"/>',
  shield: '<path d="m12 2 8 4v6q0 6-8 10-8-4-8-10V6z"/><path d="m8 12 3 3 5-6"/>',
  book: '<path d="M12 5q-5-3-10-1v15q5-2 10 1 5-3 10-1V4q-5-2-10 1v15"/>',
  bolt: '<path d="M14 2 4 14h7l-1 8 10-13h-7z"/>',
  moon: '<path d="M20 16A9 9 0 0 1 8 4a9 9 0 1 0 12 12Z"/>',
  diamond: '<path d="m12 2 10 10-10 10L2 12z"/><path d="M2 12h20M12 2l-4 10 4 10 4-10z"/>',
  eye: '<path d="M2 12q10-14 20 0-10 14-20 0Z"/><circle cx="12" cy="12" r="3"/>',
  branch: '<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="5" r="2"/><path d="M6 7v10m0-5h6q6 0 6-5"/>',
  heart: '<path d="M12 21 3 12C-3 3 8-2 12 6c4-8 15-3 9 6z"/>',
  layers: '<path d="m12 2 10 6-10 6L2 8zM2 12l10 6 10-6M2 16l10 6 10-6"/>',
  brush: '<path d="m10 14 9-11q3-2 2 2l-8 12M10 14q-8-2-7 7 8 1 10-4z"/>',
  star: '<path d="m12 2 3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z"/>',
  flag: '<path d="M5 22V3q4-3 8 0t7 0v10q-4 3-7 0t-8 0"/>',
  beats: '<path d="M15 3v13"/><ellipse cx="11" cy="17" rx="4" ry="3" transform="rotate(-20 11 17)" fill="currentColor" stroke="none"/>',
  taskboard: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M15 4v16"/>',
  wand: '<path d="m4 20 12-12 4 4L8 24M14 10l4 4" transform="translate(0 -3)"/><path d="M5 3v4M3 5h4M19 2v4M17 4h4M20 17v4M18 19h4"/>'
};
function icon(name, color = "currentColor") {
  return `<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${iconPaths[name] || iconPaths.robot}</svg>`;
}
const colors = [
  ["Silver", "#c5cdd8"], ["Green", "#70d99b"], ["Mint", "#79d7cc"], ["Blue", "#8caef7"],
  ["Violet", "#b5a0ee"], ["Rose", "#e8a2c5"], ["Red", "#ed8890"]
];
const petNames = ["Sprout", "Pebble", "Orbit"];
function pet(name) {
  const shapes = {
    Sprout: '<path d="M27 23V12M27 15Q10 16 13 5Q26 3 27 15M27 12Q40 12 41 3Q28 0 27 12" stroke="#70d99b" fill="#47876c"/><rect x="12" y="23" width="30" height="29" rx="10" fill="#92bfa4"/><path d="M16 49v6m22-6v6" stroke="#92bfa4" stroke-width="6"/>',
    Pebble: '<path d="M9 40 13 19 27 11 43 23 47 44 34 53 18 51Z" fill="#b5a0ee"/><path d="m17 22 9-5" stroke="#d3c9f2" stroke-width="3"/>',
    Orbit: '<circle cx="28" cy="31" r="18" fill="#8caef7"/><ellipse cx="28" cy="33" rx="26" ry="7" transform="rotate(-24 28 33)" fill="none" stroke="#aebffd" stroke-width="3"/><circle cx="49" cy="19" r="4" fill="#e8a2c5"/>'
  };
  return `<svg class="pet" viewBox="0 0 58 64" aria-hidden="true">${shapes[name] || shapes.Sprout}<circle cx="22" cy="33" r="2" fill="#263341"/><circle cx="34" cy="33" r="2" fill="#263341"/><path d="M24 41q4 3 8 0" stroke="#263341" fill="none" stroke-width="1.5"/></svg>`;
}
const worktrees = {
  main: { name: "cmux-maestro", branch: "main", path: "/demo/cmux-maestro", exactID: "tree-001" },
  sidebar: { name: "cmux-maestro", branch: "Detached HEAD · a4c71e2", path: "/demo/worktrees/sidebar-design/cmux-maestro", exactID: "tree-002" }
};
const workspaces = [
  { id: "design", name: "Maestro design", subtitle: "Sidebar & personalization", backlog: "#57 Cosmetic overhaul" },
  { id: "scratch", name: "Scratch space", subtitle: "Non-repository work", backlog: null }
];
const surfaces = [
  { id: "coordinator", workspace: "design", name: "Design coordinator", task: "Shape the sidebar overhaul", kind: "agent", state: "working", worktree: "main", parent: null, pane: 1, glyph: "compass", color: "#79d7cc", pet: "Sprout", model: "Copilot · demo model", elapsed: "24m", context: "38%", files: 4, add: 82, del: 19, agentTags: ["coordination"] },
  { id: "implementer", workspace: "design", name: "Sidebar implementer", task: "Build compact worktree rows", kind: "agent", state: "working", worktree: "sidebar", parent: "coordinator", pane: 2, glyph: "robot", color: "#70d99b", pet: "Sprout", model: "Copilot · demo model", elapsed: "12m", context: "26%", files: 6, add: 147, del: 32, agentTags: ["frontend"] },
  { id: "researcher", workspace: "design", name: "Native conventions", task: "Research native CMUX layout", kind: "agent", state: "done", worktree: "main", parent: "coordinator", pane: 1, glyph: "book", color: "#c5cdd8", pet: "Pebble", model: "Copilot · demo model", elapsed: "18m", context: "Unavailable", files: 0, add: 0, del: 0, agentTags: ["research"] },
  { id: "writer", workspace: "design", name: "Interaction writer", task: "Clarify labels and empty states", kind: "agent", state: "working", worktree: "main", parent: "reviewer", pane: 1, glyph: "brush", color: "#79d7cc", pet: "Pebble", model: "Copilot · demo model", elapsed: "7m", context: "15%", files: 2, add: 24, del: 8, agentTags: ["content"] },
  { id: "reviewer", workspace: "design", name: "Design reviewer", task: "Choose a hover interaction", kind: "agent", state: "input", worktree: "sidebar", parent: null, pane: 1, glyph: "eye", color: "#b5a0ee", pet: "Orbit", model: "Copilot · demo model", elapsed: "8m", context: "31%", files: 6, add: 147, del: 32, agentTags: ["review"] },
  { id: "accessibility", workspace: "design", name: "Accessibility review", task: "Check keyboard and contrast", kind: "agent", state: "working", worktree: "sidebar", parent: "reviewer", pane: 2, glyph: "shield", color: "#8caef7", pet: "Pebble", model: "Copilot · demo model", elapsed: "4m", context: "17%", files: 6, add: 147, del: 32, agentTags: ["accessibility"] },
  { id: "scratch-agent", workspace: "design", name: "Quick question", task: "Compare two design ideas", kind: "agent", state: "idle", worktree: null, parent: null, pane: 1, glyph: "spark", color: "#e8a2c5", pet: "Orbit", model: "Copilot · demo model", elapsed: "2m", context: "9%", files: null, agentTags: [], directory: "/demo/notes" },
  { id: "github", workspace: "design", name: "GitHub · design backlog", kind: "browser", state: "idle", pane: 2, site: "github", url: "github.com", glyph: "globe", color: "#c5cdd8" },
  { id: "azure", workspace: "design", name: "Azure DevOps · demo board", kind: "browser", state: "idle", pane: 2, site: "azure", url: "dev.azure.com", glyph: "globe", color: "#c5cdd8" },
  { id: "shell", workspace: "design", name: "Build terminal", kind: "terminal", state: "idle", pane: 1, glyph: "terminal", color: "#c5cdd8" },
  { id: "notes", workspace: "scratch", name: "Notes assistant", task: "Outline a personal project", kind: "agent", state: "idle", worktree: null, parent: null, pane: 1, glyph: "leaf", color: "#79d7cc", pet: "Pebble", model: "Copilot · demo model", elapsed: "6m", context: "12%", files: null, agentTags: [], directory: "/demo/scratch" },
  { id: "notes-child", workspace: "scratch", name: "Notes outline review", task: "Review the personal outline", kind: "agent", state: "idle", worktree: null, parent: "notes", pane: 2, glyph: "book", color: "#79d7cc", pet: "Sprout", model: "Copilot · demo model", elapsed: "2m", context: "8%", files: null, agentTags: [], directory: "/demo/scratch" }
];
const observedChildren = [];
const allSurfaces = () => [...surfaces, ...utilitySurfaces(state.utilityTabs)];
const byId = id => allSurfaces().find(s => s.id === id);
const STORAGE = "maestro-cosmetic-lab-v2";
const initialState = () => ({
  version: 2, active: "implementer", grouping: "worktrees",
  collapsed: { "design:main": true }, workspaceCollapsed: { scratch: true }, ancestryCollapsed: {}, paneCollapsed: {}, tabOrder: {},
  icons: {}, pets: {}, tags: {}, panes: {}, paneSelected: {}, agentChoices: {}, dismissed: {}, showEnded: false, petHidden: {}, workspaceOrder: ["design", "scratch"],
  utilityTabs: {}, beats: initialBeats(), selectedBeat: "beat-review", beatClock: Date.UTC(2026, 8, 25, 20, 0), beatAvailability: {}, fermata: false, workspaceFinished: {}, sidebarOrders: {}, createdDirectories: [], tagColors: {}
});
let state = initialState();
let startupNotice = "";
let migratedGrouping = false;
let refreshedDemoSelection = false;
try {
  const raw = localStorage.getItem(STORAGE);
  if (raw) {
    const saved = JSON.parse(raw);
    const directories = saved.createdDirectories ?? [];
    const directoryStateValid = validCreatedDirectories(directories);
    const savedWorkspaces = directoryStateValid ? [...workspaces, ...directories.map(directoryWorkspace)] : workspaces;
    const savedSurfaces = directoryStateValid ? [...surfaces, ...directories.map(directorySurface)] : surfaces;
    const removedSelection = ["unknown-agent", "stale-agent"].includes(saved.active);
    if (removedSelection) {
      saved.active = "implementer";
      startupNotice = "Edge-case demo agents removed. Selected Sidebar implementer; saved Beats and preferences retained.";
    }
    const maps = ["collapsed", "workspaceCollapsed", "ancestryCollapsed", "icons", "pets", "tags", "panes", "petHidden", "paneSelected", "agentChoices"];
    if (saved.version !== 2 || !directoryStateValid || !validTagColors(saved.tagColors) || !validUtilityState(saved) || ![...savedSurfaces, ...utilitySurfaces(saved.utilityTabs)].some(item => item.id === saved.active) || !maps.every(key => saved[key] && typeof saved[key] === "object" && !Array.isArray(saved[key])) ||
        !Array.isArray(saved.workspaceOrder) || saved.workspaceOrder.length !== savedWorkspaces.length || new Set(saved.workspaceOrder).size !== savedWorkspaces.length || !saved.workspaceOrder.every(id => savedWorkspaces.some(w => w.id === id))) {
      startupNotice = "Saved demo preferences are incompatible. Showing defaults; use Reset demo to clear them.";
    } else {
      const { views: legacyViews, ...preferences } = saved;
      workspaces.push(...directories.map(directoryWorkspace));
      surfaces.push(...directories.map(directorySurface));
      state = { ...state, ...preferences };
      refreshedDemoSelection = removedSelection;
      if (!["worktrees", "subagents", "workspace"].includes(state.grouping)) state.grouping = "worktrees";
      if (legacyViews && saved.grouping === undefined) {
        state.grouping = legacyViews[byId(state.active).workspace] === "subagents" ? "subagents" : "worktrees";
        startupNotice = "Grouping now applies globally. Previous active-workspace choice adopted; other demo preferences retained.";
        migratedGrouping = true;
      }
    }
  }
} catch (error) {
  startupNotice = `Could not load demo preferences (${error.name}). Changes may not survive reload.`;
}
let noticeTimer, hoverTimer, leaveTimer, hoveredId = null, pickerTarget = null, pickerType = "icon", iconQuery = "", tagTarget = null, tagColorTarget = null, draggedId = null, pendingDismiss = [], pendingDismissScope = null;
function notify(text) {
  $("#notice").textContent = text;
  $("#notice").classList.add("visible");
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => $("#notice").classList.remove("visible"), 4500);
}
function save() {
  try { localStorage.setItem(STORAGE, JSON.stringify(state)); }
  catch (error) { notify(`Preference save failed (${error.name}); this change is temporary.`); }
}
function restoreFocus(focus) {
  if (focus?.isConnected) { focus.focus({ preventScroll: true }); return; }
  if (focus?.id && document.getElementById(focus.id)) { document.getElementById(focus.id).focus({ preventScroll: true }); return; }
  if (!focus?.dataset) return;
  const entries = Object.entries(focus.dataset);
  const replacement = [...document.querySelectorAll("button")].find(button => entries.length && entries.every(([key, value]) => button.dataset[key] === value));
  replacement?.focus({ preventScroll: true });
}
function commit() { const focus = document.activeElement; save(); render(); restoreFocus(focus); }
function resolvedIcon(surface) {
  if (surface.kind === "tool") return { glyph: surface.tool, color: "#afb5c0" };
  const override = state.icons[surface.id];
  if (override?.mode === "custom" && iconPaths[override.glyph] && colors.some(([, color]) => color === override.color)) return override;
  if (override?.mode === "favicon" && surface.kind === "browser") return { mode: "favicon" };
  if (override?.mode === "default") return { glyph: surface.kind === "agent" ? "robot" : surface.kind === "browser" ? "globe" : "terminal", color: "#c5cdd8" };
  return state.agentChoices[surface.id]?.icon || { glyph: surface.glyph, color: surface.color };
}
function iconFor(surface) {
  const choice = resolvedIcon(surface);
  if (choice.mode === "favicon") return `<span class="favicon ${surface.site === "azure" ? "azure" : ""}" aria-hidden="true">${surface.site === "azure" ? "Az" : "GH"}</span>`;
  return icon(choice.glyph, choice.color);
}
function resolvedPet(surface) {
  const choice = state.pets[surface.id];
  return choice?.mode === "default" ? "Sprout" : choice?.mode === "custom" && petNames.includes(choice.name) ? choice.name : state.agentChoices[surface.id]?.pet || surface.pet || "Sprout";
}
const stateLabel = item => ({ working: "Working", idle: "Idle", input: "Needs input", done: "Finished", unknown: "Unknown" }[item.state]);
const dot = item => `<span class="state-dot ${item.state}" role="img" aria-label="${stateLabel(item)}" title="${stateLabel(item)}"></span>`;
const paneFor = item => [1, 2].includes(state.panes[item.id]) ? state.panes[item.id] : item.pane;
const activeWorkspace = () => byId(state.active).workspace;
function validCreatedDirectories(records) {
  return Array.isArray(records) && new Set(records.map(item => item?.id)).size === records.length &&
    records.every(item => item && /^directory-[a-f0-9-]{36}$/.test(item.id) && typeof item.directory === "string" && item.directory.length > 0 && item.directory.length <= 240);
}
function directoryWorkspace(record) {
  return { id: record.id, name: record.directory.replace(/\/+$/, "").split("/").pop() || "Root directory", subtitle: record.directory, backlog: null };
}
function directorySurface(record) {
  return { id: `${record.id}-terminal`, workspace: record.id, name: "Terminal", kind: "terminal", state: "idle", pane: 1, glyph: "terminal", color: "#c5cdd8", task: `Shell in ${record.directory}` };
}
function orderedSidebar(items, container, id = item => item.id) {
  const order = state.sidebarOrders[container] || [];
  return [...order.map(key => items.find(item => String(id(item)) === key)).filter(Boolean), ...items.filter(item => !order.includes(String(id(item))))];
}
function orderedPanes(workspace) { return orderedSidebar([1, 2], `panes:${workspace}`, pane => pane); }
function sortAttributes(kind, id, container) {
  return `draggable="true" data-sort-kind="${kind}" data-sort-id="${id}" data-sort-container="${container}" aria-description="Drag to reorder among siblings. Option+Up or Option+Down also reorders."`;
}
function sidebarSiblingIDs(container) {
  const [type, workspace, group] = container.split(":");
  if (type === "workspaces") return [...state.workspaceOrder];
  if (type === "tabs") return orderedPaneItems(workspace, Number(group)).map(item => item.id);
  let ids;
  if (type === "panes") ids = ["1", "2"];
  else if (type === "worktrees") ids = Object.keys(worktrees);
  else if (type === "members") ids = surfaces.filter(item => item.workspace === workspace && item.kind === "agent" && item.worktree === group).map(item => item.id);
  else if (type === "standalone") ids = surfaces.filter(item => item.workspace === workspace && item.kind === "agent" && !item.worktree).map(item => item.id);
  else if (type === "other") ids = allSurfaces().filter(item => item.workspace === workspace && item.kind !== "agent").map(item => item.id);
  else if (type === "family") {
    const items = visibleAgents(workspace, "subagents");
    ids = items.filter(item => group === "root" ? !items.some(parent => parent.id === item.parent) : item.parent === group).map(item => item.id);
  } else return [];
  return orderedSidebar(ids, container, id => id);
}
function reorderSidebar(source, target, after) {
  if (!target || source.container !== target.container || source.kind !== target.kind) {
    notify("Reorder within the same container only. No items were moved."); return false;
  }
  const ids = sidebarSiblingIDs(source.container);
  if (!ids.includes(source.id) || !ids.includes(target.id)) { notify("That sidebar item is no longer available."); return false; }
  if (source.id === target.id) return false;
  const ordered = ids.filter(id => id !== source.id), index = ordered.indexOf(target.id);
  ordered.splice(index + (after ? 1 : 0), 0, source.id);
  if (ordered.every((id, position) => id === ids[position])) return false;
  if (source.container === "workspaces") state.workspaceOrder = ordered;
  else if (source.container.startsWith("tabs:")) state.tabOrder[source.container.slice(5)] = ordered;
  else state.sidebarOrders[source.container] = ordered;
  const scroll = $("#workspaces").scrollTop;
  commit(); $("#workspaces").scrollTop = scroll;
  notify("Sidebar order updated. Children, identities, and active selection are unchanged.");
  return true;
}
function sortIdentity(element) {
  return element ? { kind: element.dataset.sortKind, id: element.dataset.sortId, container: element.dataset.sortContainer } : null;
}
let sidebarDrag = null;
function clearSidebarDrop() {
  document.querySelectorAll("[data-drop-edge], .sidebar-drop-invalid").forEach(element => {
    element.removeAttribute("data-drop-edge"); element.classList.remove("sidebar-drop-invalid");
  });
}
function endSidebarDrag() {
  sidebarDrag = null; clearSidebarDrop();
  document.querySelectorAll(".sidebar-dragging").forEach(element => element.classList.remove("sidebar-dragging"));
}
function sidebarDropTarget(target) {
  const marker = target.closest("[data-sort-kind]");
  if (marker?.dataset.sortContainer === sidebarDrag?.container) return marker;
  for (let element = target; element && element !== $("#workspaces"); element = element.parentElement) {
    const header = element.matches(".workspace") ? element.querySelector(":scope > .workspace-title") :
      element.matches(".worktree") ? element.querySelector(":scope > .group-heading") :
      element.matches(".native-outline-pane") ? element.querySelector(":scope > .native-pane-disclose") :
      element.matches(".ancestor") ? element.querySelector(":scope > .ancestor-row [data-sort-kind]") : null;
    if (header?.dataset.sortContainer === sidebarDrag?.container) return header;
  }
  return marker;
}
function orderedPaneItems(workspace, pane) {
  const members = allSurfaces().filter(item => item.workspace === workspace && paneFor(item) === pane && !state.dismissed[item.id]);
  const order = state.tabOrder[`${workspace}:${pane}`] || [];
  return [...order.map(id => members.find(item => item.id === id)).filter(Boolean), ...members.filter(item => !order.includes(item.id))];
}
function identityContext(item) {
  if (item.kind === "tool") return `${item.name} · all workspaces · movable view`;
  if (item.worktree) return `${worktrees[item.worktree].branch} · ${worktrees[item.worktree].path} · verified ${worktrees[item.worktree].exactID}`;
  if (item.evidence === "stale") return `Stale evidence · previously ${worktrees[item.lastWorktree].exactID}; current membership unverified`;
  if (item.kind === "agent") return item.worktree === null ? `${item.directory} · confirmed non-repository (synthetic evidence)` : "Membership unknown · unavailable probe is not proof of non-repository";
  return item.url || "Local shell · synthetic";
}
function visibleAgents(workspace, mode) {
  const agents = surfaces.filter(s => s.workspace === workspace && s.kind === "agent" && !state.dismissed[s.id]);
  const visible = new Set(agents.filter(a => showsFinished(workspace) || a.state !== "done").map(a => a.id));
  if (mode === "subagents") {
    for (const item of agents) {
      if (!visible.has(item.id)) continue;
      let parent = byId(item.parent);
      while (parent && !state.dismissed[parent.id] && parent.workspace === workspace && !visible.has(parent.id)) {
        visible.add(parent.id);
        parent = byId(parent.parent);
      }
    }
  }
  return agents.filter(a => visible.has(a.id));
}
const panelType = item => item.kind === "tool" ? item.name : item.kind === "browser" ? "Browser" : "Terminal";
function renderRow(item, ordinal = null, container = null, kind = "row") {
  const sortable = container ? sortAttributes(kind, item.id, container) : "";
  if (item.kind === "tool") return `<div class="surface-row ${state.active === item.id ? "selected" : ""}" data-row="${item.id}" ${sortable} ${ordinal === null ? "" : `data-native-surface="${item.id}"`}><button class="identity-icon" data-focus="${item.id}" aria-label="Open ${item.name}">${iconFor(item)}</button><button class="row-main" data-focus="${item.id}"><span class="row-name">${item.name}</span><span class="row-meta">All workspaces · view only</span></button><button class="row-accessory" data-tool-move="${item.tool}" aria-label="Move ${item.name} tab">⇄</button></div>`;
  return `<div class="${item.kind === "agent" ? "agent-row" : "surface-row"} ${state.active === item.id ? "selected" : ""}" data-row="${item.id}" data-hover="${item.id}" ${sortable} ${ordinal === null ? "" : `data-native-surface="${item.id}"`}>
    <button class="identity-icon" data-icon="${item.id}" aria-label="Choose icon for ${escapeHTML(item.name)}" title="Right-click to choose icon">${iconFor(item)}</button>
    <button class="row-main" data-focus="${item.id}" ${state.active === item.id ? 'aria-current="true"' : ""} ${ordinal === null ? "" : `aria-label="${escapeHTML(item.name)}, tab ${ordinal}, ${panelType(item)} panel"`}><span class="row-title"><span class="row-name">${escapeHTML(item.name)}</span>${tagMarkup(item, true)}</span><span class="row-meta">${dot(item)}<span>${ordinal !== null ? `${panelType(item)} panel` : item.kind === "agent" ? escapeHTML(item.task) : item.kind === "browser" ? item.url : `Pane ${paneFor(item)}`}</span></span></button>
    <button class="row-accessory" data-menu="${item.id}" aria-label="Actions for ${escapeHTML(item.name)}">···</button>
  </div>`;
}
function strip(items, key) {
  return `<div class="summary-strip">${items.slice(0, 4).map(item => `<button class="strip-agent ${state.active === item.id ? "selected" : ""}" data-focus="${item.id}" data-hover="${item.id}" ${sortAttributes("row", item.id, `members:${key}`)} data-sort-axis="horizontal" aria-label="${escapeHTML(item.name)}, ${stateLabel(item)}"><span class="strip-identity">${dot(item)}${iconFor(item)}</span>${tagMarkup(item, true)}</button>`).join("")}
    <button class="expand-strip" data-expand="${key}" aria-label="Expand ${items.length} agents">${items.length > 4 ? `+${items.length - 4} · ` : ""}${items.length} ${items.length === 1 ? "agent" : "agents"} ›</button></div>`;
}
function worktreeView(workspace) {
  const items = visibleAgents(workspace, "worktrees");
  let html = orderedSidebar(Object.entries(worktrees), `worktrees:${workspace}`, item => item[0]).map(([key, tree]) => {
    const members = orderedSidebar(items.filter(a => a.worktree === key), `members:${workspace}:${key}`);
    if (!members.length) return "";
    const groupKey = `${workspace}:${key}`, closed = !!state.collapsed[groupKey];
    return `<section class="worktree" data-worktree-id="${tree.exactID}"><div class="group-heading" ${sortAttributes("worktree", key, `worktrees:${workspace}`)}><button class="group-disclose" data-expand="${groupKey}" aria-expanded="${!closed}" aria-label="${closed ? "Expand" : "Collapse"} worktree ${tree.name}, ${tree.branch}, ${tree.exactID}" title="Verified synthetic membership ${tree.exactID} · same basename is not identity"><span class="chevron" aria-hidden="true">${closed ? "›" : "⌄"}</span><span class="branch-mark">${icon("branch")}</span><span class="group-title"><b>${tree.name}</b><span class="branch-label">${tree.branch} · ${tree.exactID}</span></span><span class="count">${members.length}</span></button></div>${closed ? strip(members, groupKey) : `<div class="group-rows">${members.map(item => renderRow(item, null, `members:${workspace}:${key}`)).join("")}</div>`}</section>`;
  }).join("");
  html += orderedSidebar(items.filter(item => !item.worktree), `standalone:${workspace}`).map(item => renderRow(item, null, `standalone:${workspace}`)).join("");
  return html;
}
function observedRow(item) {
  return `<div class="observed-row" data-observed="${item.id}"><span class="observed-mark">↳</span><div><b>${escapeHTML(item.name)}</b><span>No separate surface observed</span><small>Parent: ${escapeHTML(byId(item.parent).name)}<br>Worktree unknown · no own chat, pet, or exit action</small>${state.dismissed[item.parent] ? '<small>Parent chat closed · child state unverified</small>' : `<button data-parent-chat="${item.parent}">Open parent chat</button>`}</div></div>`;
}
function ancestryView(workspace) {
  const items = visibleAgents(workspace, "subagents");
  function branch(item, container) {
    const childContainer = `family:${workspace}:${item.id}`;
    const children = orderedSidebar(items.filter(a => a.parent === item.id), childContainer), closed = !!state.ancestryCollapsed[item.id];
    const observed = observedChildren.filter(child => child.parent === item.id);
    const count = children.length + observed.length;
    return `<div class="ancestor"><div class="ancestor-row">${count ? `<button class="chevron" data-ancestry="${item.id}" aria-label="${closed ? "Expand" : "Collapse"} children of ${escapeHTML(item.name)}" aria-expanded="${!closed}">${closed ? "›" : "⌄"}</button>` : ""}${renderRow(item, null, container, "agent-tree")}</div>${count ? closed ? `<div class="group-subtitle">${children.length} agent windows · ${observed.length} observed children</div>` : `<div class="tree-children">${children.map(child => branch(child, childContainer)).join("")}${observed.map(observedRow).join("")}</div>` : ""}</div>`;
  }
  const orphanedActivity = observedChildren.filter(child => byId(child.parent).workspace === workspace && state.dismissed[child.parent]);
  const rootContainer = `family:${workspace}:root`;
  return orderedSidebar(items.filter(a => !items.some(parent => parent.id === a.parent)), rootContainer).map(item => `${item.parent && state.dismissed[item.parent] ? `<div class="retained-parent" data-retained-parent="${item.parent}">Spawned by ${escapeHTML(byId(item.parent).name)} · session closed<br>Recorded ancestry retained; child still open.</div>` : ""}${branch(item, rootContainer)}`).join("") + orphanedActivity.map(observedRow).join("");
}
function showsFinished(workspace) {
  return state.workspaceFinished[workspace] ?? state.showEnded;
}
function renderFinishedToggle(workspace) {
  const native = state.grouping === "workspace", visible = native || showsFinished(workspace.id);
  return `<button class="finished-toggle" data-toggle-finished="${workspace.id}" aria-label="Show finished agents in ${escapeHTML(workspace.name)}" aria-pressed="${visible}" ${native ? "disabled" : ""} title="${native ? "Workspace view includes all open tabs" : visible ? "Hide finished agents" : "Show finished agents"}"><svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${iconPaths.eye}${!visible ? '<path d="m3 3 18 18"/>' : ""}</svg></button>`;
}
function renderWorkspace(workspace) {
  const closed = !!state.workspaceCollapsed[workspace.id], view = state.grouping;
  return `<section class="workspace ${workspace.id === activeWorkspace() ? "active" : ""}" data-workspace="${workspace.id}" data-grouping-mode="${view}">
    <header class="workspace-title" ${sortAttributes("workspace", workspace.id, "workspaces")}><button class="workspace-collapse" data-workspace-collapse="${workspace.id}" aria-label="${closed ? "Expand" : "Collapse"} workspace ${escapeHTML(workspace.name)}" aria-expanded="${!closed}" aria-controls="workspace-content-${workspace.id}" title="${closed ? "Expand" : "Collapse"} workspace"><span aria-hidden="true">${closed ? "+" : "−"}</span></button><button class="workspace-select" data-workspace-select="${workspace.id}"><span data-hover-workspace="${workspace.id}">${escapeHTML(workspace.name)}</span></button><div class="workspace-actions">${renderFinishedToggle(workspace)}<button data-backlog="${workspace.id}" aria-label="Backlog for ${escapeHTML(workspace.name)}" title="Workspace backlog">↗</button><button data-workspace-menu="${workspace.id}" aria-label="Actions for ${escapeHTML(workspace.name)}">···</button></div></header>
    <div id="workspace-content-${workspace.id}" ${closed ? "hidden" : ""}>${closed ? "" : view === "workspace" ? nativeWorkspaceView(workspace.id) : `${view === "worktrees" ? worktreeView(workspace.id) : ancestryView(workspace.id)}<div class="nonagents">${orderedSidebar(allSurfaces().filter(s => s.workspace === workspace.id && s.kind !== "agent"), `other:${workspace.id}`).map(item => renderRow(item, null, `other:${workspace.id}`)).join("")}</div>`}</div>
  </section>`;
}
function nativeWorkspaceView(workspace) {
  const panes = orderedPanes(workspace).map((pane, paneIndex) => {
    const key = `${workspace}:${pane}`, closed = !!state.paneCollapsed[key], items = orderedPaneItems(workspace, pane);
    return `<section class="native-outline-pane" data-native-pane="${key}"><button class="native-pane-disclose" ${sortAttributes("pane", pane, `panes:${workspace}`)} data-pane-collapse="${key}" aria-expanded="${!closed}" aria-label="${closed ? "Expand" : "Collapse"} pane ${pane} in ${escapeHTML(workspaces.find(item => item.id === workspace).name)}"><span class="chevron" aria-hidden="true">${closed ? "›" : "⌄"}</span>${icon("layers")}<b>Pane ${pane}</b><span>${items.length} ${items.length === 1 ? "tab" : "tabs"} · ${paneIndex === 0 ? "left" : "right"} split</span></button>${closed ? "" : `<div class="native-surface-list">${items.map((item, index) => renderRow(item, index + 1, `tabs:${workspace}:${pane}`)).join("") || '<p class="empty">Empty split region · drop a tab here in the layout.</p>'}</div>`}</section>`;
  }).join("");
  return panes;
}
function metrics(item) {
  return item.kind === "agent" ? `<div class="detail-metrics"><span>${item.context} context</span><span>${item.elapsed} elapsed</span><span>${item.files === null ? "Git unavailable" : `${item.files} files <b class="additions">+${item.add}</b> <b class="deletions">−${item.del}</b>`}</span></div>` : `<div class="detail-metrics"><span>${item.kind === "browser" ? item.url : "No attached agent"}</span><span>Pane ${paneFor(item)}</span></div>`;
}
const tagSwatches = [
  ["Rose", "#efb8c8"], ["Peach", "#efc2a1"], ["Gold", "#e8d28d"], ["Lime", "#c8dda0"],
  ["Mint", "#a6d8b9"], ["Teal", "#9ed7d1"], ["Sky", "#add5ed"], ["Periwinkle", "#b7c5ed"],
  ["Lavender", "#cbb9ed"], ["Orchid", "#dfb2dd"], ["Slate", "#c3cad4"],
  ["Forest", "#275641"], ["Ocean", "#294f75"], ["Plum", "#644270"]
];
function tagSlug(text) {
  return String(text).normalize("NFKC").trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "");
}
function validTagColors(overrides) {
  return overrides === undefined || (overrides && typeof overrides === "object" && !Array.isArray(overrides) &&
    Object.entries(overrides).every(([slug, color]) => tagSlug(slug) === slug && slug.length > 0 && /^#[a-f0-9]{6}$/i.test(color)));
}
function defaultTagColor(slug) {
  let hash = 2166136261;
  for (const character of slug) hash = Math.imul(hash ^ character.codePointAt(0), 16777619) >>> 0;
  const hue = (hash % 360) / 60, saturation = .48 + ((hash >>> 9) % 13) / 100, lightness = .64 + ((hash >>> 17) % 9) / 100;
  const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation, x = chroma * (1 - Math.abs(hue % 2 - 1)), m = lightness - chroma / 2;
  const channels = hue < 1 ? [chroma, x, 0] : hue < 2 ? [x, chroma, 0] : hue < 3 ? [0, chroma, x] : hue < 4 ? [0, x, chroma] : hue < 5 ? [x, 0, chroma] : [chroma, 0, x];
  return `#${channels.map(channel => Math.round((channel + m) * 255).toString(16).padStart(2, "0")).join("")}`;
}
function tagColorScheme(slug) {
  const background = Object.hasOwn(state.tagColors, slug) ? state.tagColors[slug] : defaultTagColor(slug);
  const channels = background.slice(1).match(/../g).map(hex => {
    const value = parseInt(hex, 16) / 255;
    return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
  });
  const luminance = channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
  const blackContrast = (luminance + .05) / .05, whiteContrast = 1.05 / (luminance + .05);
  return { background, foreground: blackContrast >= whiteContrast ? "#000000" : "#ffffff", contrast: Math.max(blackContrast, whiteContrast) };
}
function agentTags(item) {
  const tags = new Map();
  for (const [owner, values] of [["you", state.tags[item.id] || []], ["agent", item.agentTags || []]]) {
    for (const value of values) {
      const slug = tagSlug(value);
      if (!slug) continue;
      if (!tags.has(slug)) tags.set(slug, { slug, owners: [] });
      if (!tags.get(slug).owners.includes(owner)) tags.get(slug).owners.push(owner);
    }
  }
  return [...tags.values()];
}
function tagChip(tag, compact = false, interactive = !compact) {
  const scheme = tagColorScheme(tag.slug), ownership = tag.owners.join(" + ");
  const element = interactive ? "button" : "span";
  const action = interactive ? ` type="button" data-tag-color="${escapeHTML(tag.slug)}" aria-label="Change color for ${escapeHTML(tag.slug)}"` : "";
  return `<${element} class="tag ${tag.owners.length === 1 && tag.owners[0] === "agent" ? "agent" : ""}" data-tag-slug="${escapeHTML(tag.slug)}" data-tag-owners="${ownership}" style="--tag-bg:${scheme.background};--tag-fg:${scheme.foreground}" title="${escapeHTML(tag.slug)} · ${ownership}${interactive ? " · Change color everywhere" : ""}"${action}><span class="tag-name">${escapeHTML(tag.slug)}</span>${compact ? "" : `<span class="tag-owner"> · ${ownership}</span>`}</${element}>`;
}
function tagMarkup(item, compact = false) {
  if (item.kind !== "agent") return "";
  const tags = agentTags(item);
  if (compact && !tags.length) return "";
  return `<span class="tags tag-chips${compact ? " tags-compact" : ""}">${tags.map(tag => tagChip(tag, compact)).join("")}${compact ? "" : `<button class="tag-edit" data-tags="${item.id}">+ Tags</button>`}</span>`;
}
function renderTagEditorColors() {
  const item = byId(tagTarget);
  $("#tag-editor-colors").innerHTML = agentTags(item).map(tag => tagChip(tag)).join("") || '<span class="muted">Save a tag to choose its color.</span>';
}
function renderTagColorPicker() {
  const scheme = tagColorScheme(tagColorTarget), custom = Object.hasOwn(state.tagColors, tagColorTarget);
  $("#tag-color-title").textContent = `Color for ${tagColorTarget}`;
  $("#tag-color-preview").innerHTML = tagChip({ slug: tagColorTarget, owners: ["you"] }, true, false);
  $("#tag-color-options").innerHTML = tagSwatches.map(([name, color]) => `<button class="tag-swatch" type="button" data-tag-swatch="${color}" style="--swatch:${color}" aria-label="${name}" aria-pressed="${custom && scheme.background === color}" title="${name}"></button>`).join("");
  $("#tag-color-source").textContent = custom ? "Your color · shared by every tag with this slug" : "Automatic color · derived from this slug";
}
function openTagColor(slug) {
  tagColorTarget = slug;
  renderTagColorPicker(); openDialog("tag-color-dialog");
}
function renderPinned() {
  const item = byId(state.active);
  $("#pinned-details").dataset.active = item.id;
  if (item.kind === "tool") {
    $("#pinned-details").innerHTML = `<div class="pinned-heading"><span>Active tab</span><span>Prototype</span></div><div class="tool-pinned">${iconFor(item)}<div><b>${item.name}</b><p>${escapeHTML(workspaces.find(workspace => workspace.id === item.workspace).name)} · Pane ${paneFor(item)}</p></div></div><p class="session-note">A movable view. Closing this tab does not change agents or schedules.</p>`;
    return;
  }
  $("#pinned-details").innerHTML = `<div class="pinned-heading"><span class="eyebrow">Active window · pinned</span><span>Demo metadata</span></div>
    <div class="detail-identity">${item.kind === "agent" ? `<button class="pet-button" data-pet="${item.id}" aria-label="Choose pet for ${escapeHTML(item.name)}" title="Choose pet · original placeholder">${state.petHidden[item.id] ? icon("spark", "#9ba6b6") : pet(resolvedPet(item))}</button>` : `<button class="identity-icon" data-icon="${item.id}" aria-label="Choose icon">${iconFor(item)}</button>`}<div class="detail-info"><div class="detail-name">${escapeHTML(item.name)}</div><div class="muted">${dot(item)} ${stateLabel(item)} · Pane ${paneFor(item)}</div><div class="muted">${item.model || (item.kind === "browser" ? "Browser window" : "Terminal window")}</div></div></div>
    ${metrics(item)}<div class="detail-path" title="${escapeHTML(identityContext(item))}">${escapeHTML(identityContext(item))}</div>${tagMarkup(item)}${item.kind === "agent" ? `<div class="session-note">Session demo:${item.id} · original placeholder pet</div><button class="dismiss-inline" data-dismiss="${item.id}">Exit session & close tab · simulated</button>` : ""}`;
}
function renderStage() {
  const workspace = workspaces.find(w => w.id === activeWorkspace());
  $("#stage-title").textContent = workspace.name;
  const active = byId(state.active);
  const panes = orderedPanes(workspace.id);
  $("#native-layout").className = `native-layout${active.kind === "tool" ? ` utility-pane-${panes.indexOf(paneFor(active)) + 1}` : ""}`;
  $("#native-layout").innerHTML = panes.map(pane => {
    const items = orderedPaneItems(workspace.id, pane);
    const selected = items.find(s => s.id === state.active) || items.find(s => s.id === state.paneSelected[`${workspace.id}:${pane}`]) || items[0];
    return `<section class="pane" data-pane="${pane}"><header class="pane-header"><b>Pane ${pane}</b><span>· ${selected?.id === state.active ? "Focused" : "Visible, not focused"}</span></header><div class="tab-list" role="group" aria-label="Surface tabs in pane ${pane}">${items.map(item => `<div class="native-tab ${item.id === state.active ? "focused" : ""} ${item.kind === "tool" ? "utility-tab" : ""}" draggable="true" data-drag="${item.id}"><button data-focus="${item.id}" ${selected?.id === item.id ? 'aria-current="page"' : ""}>${item.kind === "tool" ? iconFor(item) : ""}${escapeHTML(item.name)}</button>${item.kind === "tool" ? `<button class="move-tab" data-tool-move="${item.tool}" aria-label="Move ${item.name} tab">⇄</button><button class="move-tab" data-close-tool="${item.tool}" aria-label="Close ${item.name} tab">×</button>` : `<button class="move-tab" data-move="${item.id}" aria-label="Move ${escapeHTML(item.name)} to pane ${pane === 1 ? 2 : 1}">⇄</button>`}</div>`).join("") || '<span class="empty">Drop a tab here</span>'}</div>${selected?.kind === "tool" ? `<div class="utility-content">${selected.tool === "beats" ? renderBeats() : renderTaskboard()}</div>` : `<div class="terminal-preview" role="region" aria-label="${selected ? `${panelType(selected)} panel for ${escapeHTML(selected.name)}` : "Empty pane"}">${selected ? `<div class="panel-content-label">${panelType(selected)} panel · selected tab content</div><div class="prompt">${selected.kind === "agent" ? "❯" : "›"} ${escapeHTML(selected.name)}</div><strong>${escapeHTML(selected.task || selected.url || "npm run build")}</strong><br><br>${selected.kind === "agent" ? "Interactive agent surface<br>Input remains untouched." : selected.kind === "browser" ? "Browser surface · synthetic page<br>No website or favicon requests." : "Terminal surface · synthetic output"}<br><span class="cursor"></span>` : "No selected surface."}</div>`}</section>`;
  }).join("");
}
function render() {
  hideHover();
  $("#workspaces").innerHTML = state.workspaceOrder.map(id => renderWorkspace(workspaces.find(w => w.id === id))).join("");
  $("#window-context").hidden = state.grouping !== "workspace";
  document.querySelectorAll("[data-grouping]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.grouping === state.grouping)));
  document.querySelectorAll("[data-open-tool]").forEach(button => {
    if (state.active === `tool-${button.dataset.openTool}`) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  $("#fermata-button").setAttribute("aria-pressed", String(state.fermata));
  $("#fermata-button").title = `Fermata · Keep Mac Awake ${state.fermata ? "on" : "off"} (simulated)`;
  renderPinned(); renderStage();
}
function focusItem(id) {
  const item = byId(id);
  if (!item || state.dismissed[id]) return;
  state.active = id;
  state.paneSelected[`${item.workspace}:${paneFor(item)}`] = id;
  state.workspaceCollapsed[item.workspace] = false;
  commit();
}
function hideHover() {
  clearTimeout(hoverTimer); clearTimeout(leaveTimer); hoveredId = null; $("#hover-card").hidden = true;
}
function place(element, rect, width = 280) {
  element.style.left = `${Math.max(12, Math.min(rect.right + 9, window.innerWidth - width - 12))}px`;
  element.style.top = `${Math.max(12, Math.min(rect.top, window.innerHeight - element.offsetHeight - 12))}px`;
}
function showHover(id, anchor, isWorkspace = false) {
  if (document.querySelector("dialog[open]")) return;
  clearTimeout(leaveTimer);
  hoveredId = id;
  const card = $("#hover-card");
  if (isWorkspace) {
    const workspace = workspaces.find(w => w.id === id);
    const agents = surfaces.filter(s => s.workspace === id && s.kind === "agent" && !state.dismissed[s.id]);
    card.innerHTML = `<span class="eyebrow">WORKSPACE PREVIEW</span><h3>${escapeHTML(workspace.name)}</h3><p>${escapeHTML(workspace.subtitle)}</p><p>${agents.length} agents · ${agents.filter(a => a.state === "working").length} working</p><p>${workspace.backlog || "No backlog configured"}</p><footer>Preview only · active window stays pinned</footer>`;
  } else {
    const item = byId(id);
    const showPet = item.kind === "agent" && !state.petHidden[item.id];
    const petPreview = showPet ? `<span class="hover-pet" role="img" aria-label="${escapeHTML(resolvedPet(item))}, original placeholder pet for ${escapeHTML(item.name)}">${pet(resolvedPet(item))}</span>` : "";
    card.innerHTML = `<span class="eyebrow">Window preview · no focus change</span><div class="hover-identity"><h3 class="hover-title">${iconFor(item)} ${escapeHTML(item.name)}</h3>${petPreview}</div><p>${escapeHTML(item.task || item.url || "Terminal")}</p><p>${dot(item)} ${stateLabel(item)} · Pane ${paneFor(item)}</p>${metrics(item)}<div class="detail-path">${escapeHTML(identityContext(item))}</div>${tagMarkup(item)}<footer>Synthetic metadata · ${item.parent ? `spawned by ${escapeHTML(byId(item.parent).name)}${state.dismissed[item.parent] ? " (parent session exited)" : ""}` : "no recorded parent"}<br>Preview never marks attention seen.${item.kind === "agent" ? `<br><span class="hover-pet-note">${showPet ? "Original placeholder pet" : "Pet hidden by preference"}</span>` : ""}</footer>`;
  }
  card.hidden = false;
  const anchorRect = anchor.getBoundingClientRect();
  place(card, { top: anchorRect.top, right: $("#sidebar").getBoundingClientRect().right });
}
function openDialog(id) {
  hideHover();
  const dialog = $(`#${id}`);
  if (!dialog.open) { dialog.returnFocus = document.activeElement; dialog.showModal(); }
  return dialog;
}
function openPicker(id, type, anchor) {
  pickerTarget = id; pickerType = type; iconQuery = "";
  const dialog = $("#picker"); renderPicker();
  openDialog("picker");
  if (anchor instanceof HTMLElement) dialog.returnFocus = anchor;
  place(dialog, anchor.getBoundingClientRect(), 316);
  if (type === "icon") $("#icon-search").focus();
}
function renderPicker() {
  const focus = document.activeElement;
  const item = byId(pickerTarget);
  $("#picker-kind").textContent = pickerType === "pet" ? "AGENT COMPANION" : "WINDOW APPEARANCE";
  $("#picker-title").textContent = item.name;
  if (pickerType === "pet") {
    const name = resolvedPet(item), mode = state.pets[item.id]?.mode || "agent";
    $("#picker-content").innerHTML = `<div class="pet-grid">${petNames.map(n => `<button class="pet-choice" data-pet-choice="${n}" aria-pressed="${n === name}">${pet(n)}<span>${n}</span></button>`).join("")}</div><p class="picker-status">${mode === "agent" ? "Following agent selection" : mode === "default" ? "Default · human controlled" : "Your choice · agent updates cannot replace it"}</p><p class="pet-note">Original placeholder pets. Actual Codex artwork is not included.</p><div class="reset-actions"><button data-pet-reset="default">Reset to default</button><button data-pet-reset="agent">Reset to agent selection</button><button data-pet-hide>${state.petHidden[item.id] ? "Show pet" : "Hide pet for this agent"}</button></div>`;
  } else {
    const selected = resolvedIcon(item), mode = state.icons[item.id]?.mode || (item.kind === "agent" ? "agent" : "default");
    $("#picker-content").innerHTML = `<input id="icon-search" class="picker-search" type="search" placeholder="Search icons…" aria-label="Search icons" value="${escapeHTML(iconQuery)}"><div id="icon-grid" class="icon-grid">${iconChoices(selected)}</div><div class="picker-label">COLOR</div><div class="palette">${colors.map(([name, color]) => `<button class="swatch" style="--swatch:${color}" data-color="${color}" aria-label="${name}" aria-pressed="${selected.color === color}"></button>`).join("")}</div><p class="picker-status">${mode === "agent" ? "Following agent selection" : mode === "default" ? "Default appearance · human controlled" : mode === "favicon" ? "Website icon · native colors (simulated)" : "Your choice · agent updates cannot replace it"}</p><div class="reset-actions">${item.kind === "browser" ? '<button data-icon-reset="favicon" class="primary">Use website favicon</button>' : ""}<button data-icon-reset="default">Reset to default</button>${item.kind === "agent" ? '<button data-icon-reset="agent">Reset to agent selection</button>' : ""}</div>`;
  }
  if (item.kind === "agent") $("#picker-content").insertAdjacentHTML("beforeend", '<button class="agent-update" data-agent-update>Simulate agent choosing a new icon & pet</button>');
  restoreFocus(focus);
}
function iconChoices(selected) {
  const names = Object.keys(iconPaths).filter(name => name.includes(iconQuery.toLowerCase().trim()));
  return names.length ? names.map(name => `<button class="icon-choice" data-glyph="${name}" aria-label="${name}" title="${name}" aria-pressed="${selected.glyph === name}">${icon(name, selected.color || "#c5cdd8")}</button>`).join("") : '<span class="empty">No matching icons</span>';
}
function openContext(id, anchor) {
  const item = byId(id);
  $("#context-content").innerHTML = `<div class="menu-label">${escapeHTML(item.name)}</div><button data-menu-focus="${id}">${item.kind === "agent" ? "Open existing chat" : "Focus window"}</button><button data-menu-icon="${id}">Choose icon & color…</button>${item.kind === "agent" ? `<button data-menu-pet="${id}">Choose pet…</button><button data-menu-tags="${id}">Edit your tags…</button><button data-dismiss="${id}">Exit session & close tab · simulated</button>${surfaces.some(child => child.parent === id && !state.dismissed[child.id]) ? `<button data-close-children="${id}">Direct orchestrator: close children…</button>` : ""}` : ""}<button data-menu-move="${id}">Move to pane ${paneFor(item) === 1 ? 2 : 1}</button><button data-close="context-menu">Cancel</button>`;
  const dialog = openDialog("context-menu");
  dialog.returnFocus = anchor.matches("button") ? anchor : anchor.querySelector(".row-main");
  place(dialog, anchor.getBoundingClientRect(), 218);
}
function editTags(id) {
  tagTarget = id; $("#tag-input").value = (state.tags[id] || []).join(", ");
  $("#agent-tags").textContent = `Agent-owned: ${(byId(id).agentTags || []).join(", ") || "none"}`;
  $("#tag-editor-error").textContent = "";
  renderTagEditorColors();
  openDialog("tags-dialog"); $("#tag-input").focus();
}
function moveTab(id, pane) {
  const item = byId(id);
  if (item.kind === "tool") { moveUtility(item.tool, item.workspace, pane); return; }
  const source = `${item.workspace}:${paneFor(item)}`, target = `${item.workspace}:${pane}`;
  if (source === target) { notify("Tab already belongs to that pane; native tab order unchanged."); return; }
  const sourceOrder = orderedPaneItems(item.workspace, paneFor(item)).filter(member => member.id !== id).map(member => member.id);
  const targetOrder = orderedPaneItems(item.workspace, pane).map(member => member.id);
  state.tabOrder[source] = sourceOrder;
  state.tabOrder[target] = [...targetOrder, id];
  state.panes[id] = pane; commit();
  notify(`Moved to pane ${pane}. Worktree, ancestry, and active window unchanged.`);
}
function renderHistory() {
  $("#history-content").innerHTML = surfaces.filter(item => item.state === "done" || state.dismissed[item.id]).map(item => `<div class="history-entry" data-history-entry="${item.id}"><b>${escapeHTML(item.name)}</b>${tagMarkup(item, true)}${state.dismissed[item.id] ? '<span>Session exited & terminal tab closed · simulated</span><p>No reopen-after-exit capability is implied.</p>' : `<span>${escapeHTML(item.task)} · completed turn, session open</span><p>Existing chat remains in Pane ${paneFor(item)} for continued interaction.</p><div class="button-row"><button data-history-open="${item.id}" class="primary">Open chat · simulated</button><button data-dismiss="${item.id}">Exit session & close tab · simulated</button></div>`}</div>`).join("") || '<p class="muted">No completed or dismissed sessions in this synthetic scenario.</p>';
}
function openDescendants(ids) {
  const seen = new Set(ids), queue = [...ids], open = [];
  while (queue.length) {
    const parent = queue.shift();
    for (const child of surfaces) {
      if (child.kind !== "agent" || child.parent !== parent || seen.has(child.id)) continue;
      seen.add(child.id);
      queue.push(child.id);
      if (!state.dismissed[child.id]) open.push(child.id);
    }
  }
  return open;
}
function requestDismiss(ids, orchestrator = null, scopeChosen = false) {
  const eligible = ids.filter(id => byId(id)?.kind === "agent" && !state.dismissed[id]);
  $("#context-menu").close();
  $("#history-dialog").close();
  if (!eligible.length) { notify("No separately addressable child sessions to close."); return; }
  const descendants = openDescendants(eligible);
  if (!scopeChosen && descendants.length) {
    pendingDismissScope = { roots: eligible, descendants, orchestrator };
    $("#dismiss-scope-content").innerHTML = `<p><b>${eligible.map(id => escapeHTML(byId(id).name)).join(", ")}</b> ${eligible.length === 1 ? "has" : "have"} ${descendants.length} open descendant session${descendants.length === 1 ? "" : "s"}.</p><ul>${descendants.map(id => `<li>${escapeHTML(byId(id).name)} · ${stateLabel(byId(id))}</li>`).join("")}</ul><p>Closing only the selected ${eligible.length === 1 ? "agent leaves its children" : "agents leaves their children"} open with recorded ancestry unchanged. Descendant closure includes all exact spawn generations, even across worktrees. Unrelated same-worktree peers are never included.</p><p>Activity-only children have no independent session or exit target.</p>`;
    $('[data-dismiss-scope="only"]').textContent = eligible.length === 1 ? "Close only this agent" : "Close only selected agents";
    $('[data-dismiss-scope="descendants"]').textContent = eligible.length === 1 ? "Close agent & descendants" : "Close selected agents & descendants";
    openDialog("dismiss-scope-dialog");
    return;
  }
  pendingDismiss = eligible;
  const cautious = eligible.some(id => !["idle", "done"].includes(byId(id).state));
  if (!cautious) { simulateDismiss(); return; }
  $("#dismiss-content").innerHTML = `<p>${orchestrator ? `Human-directed ${escapeHTML(byId(orchestrator).name)} closure of the explicitly selected spawn-related sessions.` : "An agent is still working, awaiting input, or has unknown state."}</p><ul>${eligible.map(id => `<li>${escapeHTML(byId(id).name)} · ${stateLabel(byId(id))}</li>`).join("")}</ul><p>Confirm before exiting these sessions and closing their tabs. Unknown-state confirmation is a conservative prototype choice. Observed activity is not assigned an independent exit action.</p>`;
  openDialog("dismiss-dialog");
}
function simulateDismiss() {
  const ids = pendingDismiss.slice(), previousWorkspace = activeWorkspace();
  pendingDismiss = [];
  ids.forEach(id => { state.dismissed[id] = true; });
  $("#dismiss-dialog").close();
  if (state.dismissed[state.active]) {
    state.active = (surfaces.find(item => item.workspace === previousWorkspace && !state.dismissed[item.id]) || surfaces.find(item => !state.dismissed[item.id])).id;
  }
  commit();
  $(`#native-layout [data-focus="${state.active}"]`)?.focus({ preventScroll: true });
  notify(`Simulated exit of ${ids.length} session${ids.length === 1 ? "" : "s"} and closure of their terminal tabs. No live operation occurred.`);
}
function renderInstallStatus() {
  const scenario = $("#install-scenario").value;
  const descriptions = { matching: "✓ Matches this build · simulated comparison", missing: "Not installed · simulated", different: "Installed content differs · not an upstream-version check", unreadable: "Cannot read installed content · status unknown" };
  $("#install-status").innerHTML = `<span class="integration-status ${scenario}">${descriptions[scenario]}</span>`;
}
document.addEventListener("click", event => {
  const button = event.target.closest("button");
  if (!button) return;
  const d = button.dataset;
  if ("openDirectory" in d) { $("#directory-error").textContent = ""; openDialog("directory-dialog"); $("#directory-path").focus(); return; }
  if (d.tagColor) { openTagColor(d.tagColor); return; }
  if (d.tagSwatch || "tagColorReset" in d) {
    if (!tagColorTarget || (d.tagSwatch && !tagSwatches.some(([, color]) => color === d.tagSwatch))) { notify("Choose an available tag color."); return; }
    if (d.tagSwatch) state.tagColors[tagColorTarget] = d.tagSwatch;
    else delete state.tagColors[tagColorTarget];
    commit(); renderTagColorPicker();
    if ($("#tags-dialog").open) renderTagEditorColors();
    if ($("#history-dialog").open) renderHistory();
    notify(`Color for ${tagColorTarget} updated everywhere in this prototype.`);
    return;
  }
  if ("menuDismiss" in d) $("#context-menu").close();
  if (d.close) { $(`#${d.close}`).close(); return; }
  if (d.dismissScope && pendingDismissScope) {
    const scope = pendingDismissScope;
    pendingDismissScope = null;
    $("#dismiss-scope-dialog").close();
    requestDismiss(d.dismissScope === "descendants" ? [...scope.roots, ...scope.descendants] : scope.roots, scope.orchestrator, true);
    return;
  }
  if (d.dismiss) { requestDismiss([d.dismiss]); return; }
  if (d.closeChildren) { requestDismiss(surfaces.filter(item => item.parent === d.closeChildren).map(item => item.id), d.closeChildren); return; }
  if (d.parentChat) { focusItem(d.parentChat); notify("Opened the parent chat only. No separate child surface is observed."); return; }
  if (d.historyOpen) { $("#history-dialog").close(); focusItem(d.historyOpen); notify("Simulated completed chat opened. Its session remains open for continued interaction."); return; }
  if (d.menu) { openContext(d.menu, button); return; }
  if ("agentUpdate" in d) {
    const current = state.agentChoices[pickerTarget];
    state.agentChoices[pickerTarget] = current?.pet === "Orbit" ? { icon: { glyph: "leaf", color: "#79d7cc" }, pet: "Pebble" } : { icon: { glyph: "star", color: "#8caef7" }, pet: "Orbit" };
    commit(); renderPicker(); notify("Synthetic agent updated its preferences. Human overrides stay in place."); return;
  }
  if (d.focus) { focusItem(d.focus); return; }
  if (d.toggleFinished) { state.workspaceFinished[d.toggleFinished] = !showsFinished(d.toggleFinished); commit(); return; }
  if (d.grouping) { state.grouping = d.grouping; commit(); return; }
  if (d.paneCollapse) { state.paneCollapsed[d.paneCollapse] = !state.paneCollapsed[d.paneCollapse]; commit(); return; }
  if (d.expand) { state.collapsed[d.expand] = !state.collapsed[d.expand]; commit(); return; }
  if (d.ancestry) { state.ancestryCollapsed[d.ancestry] = !state.ancestryCollapsed[d.ancestry]; commit(); return; }
  if (d.workspaceCollapse) { state.workspaceCollapsed[d.workspaceCollapse] = !state.workspaceCollapsed[d.workspaceCollapse]; commit(); return; }
  if (d.workspaceSelect) { const candidate = surfaces.find(s => s.workspace === d.workspaceSelect && !state.dismissed[s.id]); if (candidate) focusItem(candidate.id); else notify("No open windows remain in this synthetic workspace."); return; }
  if (d.icon) { openPicker(d.icon, "icon", button); return; }
  if (d.pet) { openPicker(d.pet, "pet", button); return; }
  if (d.tags) { editTags(d.tags); return; }
  if (d.move) { moveTab(d.move, paneFor(byId(d.move)) === 1 ? 2 : 1); return; }
  if (d.backlog) { const workspace = workspaces.find(w => w.id === d.backlog); notify(workspace.backlog ? `Demo shortcut: ${workspace.backlog}. No external tracker was opened.` : "No backlog configured for this workspace."); return; }
  if (d.workspaceMenu) {
    $("#context-content").innerHTML = `<div class="menu-label">Workspace actions</div><button data-workspace-collapse="${d.workspaceMenu}" data-menu-dismiss>Collapse / expand</button><button data-workspace-reorder="${d.workspaceMenu}">Move ${state.workspaceOrder[0] === d.workspaceMenu ? "down" : "up"}</button><button data-backlog="${d.workspaceMenu}" data-menu-dismiss>Open backlog shortcut</button><button data-close="context-menu">Cancel</button>`;
    place(openDialog("context-menu"), button.getBoundingClientRect(), 218); return;
  }
  if (d.workspaceReorder) {
    const index = state.workspaceOrder.indexOf(d.workspaceReorder), target = state.workspaceOrder[index === 0 ? 1 : index - 1];
    $("#context-menu").close();
    if (target) reorderSidebar({ kind: "workspace", id: d.workspaceReorder, container: "workspaces" }, { kind: "workspace", id: target, container: "workspaces" }, index === 0);
    return;
  }
  if (d.menuFocus || d.menuMove || d.menuIcon || d.menuPet || d.menuTags) {
    const rect = $("#context-menu").getBoundingClientRect();
    $("#context-menu").close();
    if (d.menuFocus) focusItem(d.menuFocus);
    if (d.menuMove) moveTab(d.menuMove, paneFor(byId(d.menuMove)) === 1 ? 2 : 1);
    if (d.menuIcon) openPicker(d.menuIcon, "icon", { getBoundingClientRect: () => ({ ...rect, top: rect.top, right: rect.left }) });
    if (d.menuPet) openPicker(d.menuPet, "pet", { getBoundingClientRect: () => ({ top: rect.top, right: rect.left }) });
    if (d.menuTags) editTags(d.menuTags);
    return;
  }
  if (d.glyph || d.color) {
    const selected = resolvedIcon(byId(pickerTarget));
    state.icons[pickerTarget] = { mode: "custom", glyph: d.glyph || selected.glyph || "globe", color: d.color || selected.color || "#c5cdd8" };
    commit(); renderPicker(); return;
  }
  if (d.iconReset) { if (d.iconReset === "agent") delete state.icons[pickerTarget]; else state.icons[pickerTarget] = { mode: d.iconReset }; commit(); renderPicker(); return; }
  if (d.petChoice) { state.pets[pickerTarget] = { mode: "custom", name: d.petChoice }; state.petHidden[pickerTarget] = false; commit(); renderPicker(); return; }
  if (d.petReset) { if (d.petReset === "agent") delete state.pets[pickerTarget]; else state.pets[pickerTarget] = { mode: "default" }; state.petHidden[pickerTarget] = false; commit(); renderPicker(); return; }
  if ("petHide" in d) { state.petHidden[pickerTarget] = !state.petHidden[pickerTarget]; commit(); renderPicker(); }
});
document.addEventListener("contextmenu", event => {
  const iconTarget = event.target.closest("[data-icon]"), rowTarget = event.target.closest("[data-row]"), workspaceTarget = event.target.closest("[data-workspace]");
  if (iconTarget) { event.preventDefault(); openPicker(iconTarget.dataset.icon, "icon", iconTarget); }
  else if (rowTarget) { event.preventDefault(); openContext(rowTarget.dataset.row, rowTarget); }
  else if (workspaceTarget) { event.preventDefault(); workspaceTarget.querySelector("[data-workspace-menu]").click(); }
});
document.addEventListener("input", event => {
  if (event.target.id === "icon-search") { iconQuery = event.target.value; $("#icon-grid").innerHTML = iconChoices(resolvedIcon(byId(pickerTarget))); }
});
document.addEventListener("pointerover", event => {
  if (sidebarDrag || draggedId) return;
  const target = event.target.closest("[data-hover], [data-hover-workspace]");
  if (!target || target.contains(event.relatedTarget)) return;
  clearTimeout(hoverTimer); clearTimeout(leaveTimer);
  hoverTimer = setTimeout(() => showHover(target.dataset.hover || target.dataset.hoverWorkspace, target, !!target.dataset.hoverWorkspace), 350);
});
document.addEventListener("pointerout", event => {
  const target = event.target.closest("[data-hover], [data-hover-workspace]");
  if (!target || target.contains(event.relatedTarget)) return;
  clearTimeout(hoverTimer);
  leaveTimer = setTimeout(hideHover, 220);
});
$("#hover-card").addEventListener("pointerenter", () => clearTimeout(leaveTimer));
$("#hover-card").addEventListener("pointerleave", () => { if (!$("#hover-card").contains(document.activeElement)) leaveTimer = setTimeout(hideHover, 220); });
$("#hover-card").addEventListener("focusin", () => clearTimeout(leaveTimer));
document.addEventListener("focusin", event => {
  const row = event.target.matches(".row-main") ? event.target.closest("[data-hover]") : null;
  if (row && !sidebarDrag && !draggedId) showHover(row.dataset.hover, row);
});
document.addEventListener("focusout", event => {
  const row = event.target.closest("[data-hover]");
  if (row && !row.contains(event.relatedTarget) && !$("#hover-card").contains(event.relatedTarget)) hideHover();
});
document.addEventListener("keydown", event => {
  if (event.altKey && !event.ctrlKey && !event.metaKey && ["ArrowUp", "ArrowDown"].includes(event.key)) {
    const unit = event.target.closest("[data-sort-kind]");
    if (unit && !document.querySelector("dialog[open]")) {
      event.preventDefault();
      const source = sortIdentity(unit);
      const siblings = [...$("#workspaces").querySelectorAll("[data-sort-kind]")].filter(item => item.dataset.sortContainer === source.container && item.dataset.sortKind === source.kind);
      const index = siblings.indexOf(unit), target = siblings[index + (event.key === "ArrowUp" ? -1 : 1)];
      if (target) reorderSidebar(source, sortIdentity(target), event.key === "ArrowDown");
      else notify("Already at the edge of this container.");
      return;
    }
  }
  if (event.key === "Escape") {
    hideHover(); endSidebarDrag();
  }
  if ($("#context-menu").open && ["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
    event.preventDefault();
    const buttons = [...$("#context-menu").querySelectorAll("button")], index = buttons.indexOf(document.activeElement);
    const next = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : (index + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
    buttons[next].focus();
  }
  if ((event.shiftKey && event.key === "F10") || event.key === "ContextMenu") {
    const iconTarget = event.target.closest("[data-icon]");
    if (iconTarget) { event.preventDefault(); openPicker(iconTarget.dataset.icon, "icon", iconTarget); return; }
    const rowTarget = event.target.closest("[data-row]");
    if (rowTarget) { event.preventDefault(); openContext(rowTarget.dataset.row, rowTarget); }
  }
});
document.querySelectorAll("dialog").forEach(dialog => {
  dialog.addEventListener("close", () => {
    const current = document.activeElement;
    if (current === document.body || !current?.isConnected || dialog.contains(current)) restoreFocus(dialog.returnFocus);
  });
  dialog.addEventListener("click", event => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
  });
});
document.addEventListener("dragstart", event => {
  const unit = event.target.closest("[data-sort-kind]");
  if (unit) {
    sidebarDrag = sortIdentity(unit); draggedId = null;
    unit.classList.add("sidebar-dragging");
    event.dataTransfer.setData("text/plain", sidebarDrag.id);
    event.dataTransfer.effectAllowed = "move"; hideHover(); return;
  }
  const tab = event.target.closest("[data-drag]");
  if (!tab) return;
  draggedId = tab.dataset.drag;
  event.dataTransfer.setData("text/plain", draggedId); event.dataTransfer.effectAllowed = "move"; hideHover();
});
document.addEventListener("dragover", event => {
  if (sidebarDrag) {
    event.preventDefault(); clearSidebarDrop();
    const target = sidebarDropTarget(event.target), identity = sortIdentity(target);
    const valid = identity && identity.container === sidebarDrag.container && identity.kind === sidebarDrag.kind;
    event.dataTransfer.dropEffect = valid ? "move" : "none";
    if (valid && identity.id !== sidebarDrag.id) {
      const rect = target.getBoundingClientRect();
      const after = target.dataset.sortAxis === "horizontal" ? event.clientX > rect.left + rect.width / 2 : event.clientY > rect.top + rect.height / 2;
      target.dataset.dropEdge = after ? "after" : "before";
    } else if (!valid && target) target.classList.add("sidebar-drop-invalid");
    return;
  }
  const pane = event.target.closest("[data-pane]");
  if (pane && draggedId) { event.preventDefault(); pane.classList.add("drag-over"); }
});
document.addEventListener("dragleave", event => {
  const pane = event.target.closest("[data-pane]");
  if (pane && !pane.contains(event.relatedTarget)) pane.classList.remove("drag-over");
});
document.addEventListener("drop", event => {
  if (sidebarDrag) {
    event.preventDefault();
    const source = sidebarDrag, target = sidebarDropTarget(event.target), identity = sortIdentity(target);
    const rect = target?.getBoundingClientRect();
    const after = rect ? target.dataset.sortAxis === "horizontal" ? event.clientX > rect.left + rect.width / 2 : event.clientY > rect.top + rect.height / 2 : false;
    endSidebarDrag(); reorderSidebar(source, identity, after); return;
  }
  const pane = event.target.closest("[data-pane]");
  const workspace = event.target.closest("[data-workspace]");
  const item = byId(draggedId);
  if (item?.kind === "tool" && workspace) { event.preventDefault(); moveUtility(item.tool, workspace.dataset.workspace, 1); }
  else if (pane && draggedId && item?.workspace === activeWorkspace()) { event.preventDefault(); moveTab(draggedId, Number(pane.dataset.pane)); }
  draggedId = null; document.querySelectorAll(".drag-over").forEach(el => el.classList.remove("drag-over"));
});
document.addEventListener("dragend", () => { endSidebarDrag(); draggedId = null; document.querySelectorAll(".drag-over").forEach(el => el.classList.remove("drag-over")); });
$("#history-button").onclick = () => {
  renderHistory();
  openDialog("history-dialog");
};
$("#confirm-dismiss").onclick = simulateDismiss;
$("#sidebar-width").oninput = event => { document.documentElement.style.setProperty("--sidebar-width", `${event.target.value}px`); hideHover(); };
$("#reset-demo").onclick = () => {
  const created = new Set(state.createdDirectories.map(record => record.id));
  for (let index = workspaces.length - 1; index >= 0; index--) if (created.has(workspaces[index].id)) workspaces.splice(index, 1);
  for (let index = surfaces.length - 1; index >= 0; index--) if (created.has(surfaces[index].workspace)) surfaces.splice(index, 1);
  state = initialState(); endSidebarDrag(); commit(); notify("Synthetic preferences reset. No real app settings changed.");
};
$("#settings-button").onclick = () => { renderInstallStatus(); openDialog("settings-dialog"); };
$("#capability-button").onclick = () => openDialog("notes-dialog");
$("#install-scenario").onchange = renderInstallStatus;
$("#recheck").onclick = () => { renderInstallStatus(); notify("Demo re-check complete. This is simulated, not an installed-file inspection."); };
$("#copy-command").onclick = async () => {
  try { await navigator.clipboard.writeText("npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy"); notify("Command copied. Nothing was executed."); }
  catch (error) { notify(`Copy failed (${error.name}). Select the visible command to copy manually.`); }
};
$("#tag-form").onsubmit = event => {
  event.preventDefault();
  const values = $("#tag-input").value.split(",").map(tag => tag.trim()).filter(Boolean), normalized = values.map(tagSlug);
  if (normalized.some(slug => !slug)) { $("#tag-editor-error").textContent = "Each tag needs at least one letter or number."; return; }
  const tags = [...new Set(normalized)];
  if (tags.length > 6 || tags.some(tag => tag.length > 24)) { $("#tag-editor-error").textContent = "Use at most six tags, each 24 characters or fewer after normalization."; return; }
  state.tags[tagTarget] = tags; $("#tags-dialog").close(); commit();
};
$("#directory-form").onsubmit = event => {
  event.preventDefault();
  const directory = $("#directory-path").value.trim();
  if (!directory || !(directory.startsWith("/") || directory === "~" || directory.startsWith("~/"))) {
    $("#directory-error").textContent = "Use an example absolute path or a path beginning with ~/."; return;
  }
  const record = { id: `directory-${crypto.randomUUID()}`, directory };
  state.createdDirectories.push(record);
  workspaces.push(directoryWorkspace(record)); surfaces.push(directorySurface(record));
  state.workspaceOrder.push(record.id); state.workspaceCollapsed[record.id] = false;
  $("#directory-dialog").close(); $("#directory-path").value = "";
  focusItem(`${record.id}-terminal`);
  notify("Demo workspace opened. No directory was read and no terminal process was started.");
};
window.addEventListener("resize", hideHover);
$("#workspaces").addEventListener("scroll", hideHover);
render();
if (startupNotice) notify(startupNotice);
if (migratedGrouping || refreshedDemoSelection) save();
