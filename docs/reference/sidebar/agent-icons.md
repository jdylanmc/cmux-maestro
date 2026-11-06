# Agent icons

Part of [sidebar presentation](../sidebar-presentation.md). Previous page is [Display clock, expiry and CPU acceptance](display-clock.md). Next page is [Hover previews and copy](hover-previews.md).

Agent icons come from the bundled **Nerd Fonts Symbols 3.5.1** font and its
pinned glyph-name catalog. No system font installation or uploaded images are
required. Catalog offers **10,994 drawable names**. Intentionally empty
`cod-blank` entry is excluded. Role favorites are presets, not the selection limit.
Ordinary terminal tabs use `md-ghost`. Browsers use `fa-edge` (U+F282).
**Sidebar settings → Agent icon** chooses the fallback robot or Copilot glyph for
sessions without explicit selection.

Click or right-click an **agent, terminal, or browser icon** to open its anchored
picker. Search all bundled glyph names (including role aliases), choose a color,
use **Done** or Escape to close. Keyboard: activate the icon button,
use Down from search and arrow keys in the grid, or Tab through controls.
**Show details** stays a separate action inside the popover. Opening the picker
and changing appearance do not focus a terminal, mark attention as read, or send input.
Provider-child observations and native agent surfaces without exact session
identity are not customizable. Other surface kinds keep standard icons.

**Your choice** wins over later agent metadata. **Reset to default** explicitly
chooses standard appearance. **Reset to agent selection** follows the
agent's current choice (or default when absent). Human preferences persist
by exact session UUID, or stable native surface UUID for non-agents, across restarts,
view changes and pane moves. They never transfer to a replacement session in the
same pane. Agent metadata stays separate and untouched. Sandbox stores these
bounded, coordinated preferences in its own Application Support
`CMUXMaestroPreview/sidebar-icons.json`. No additional filesystem or network grant
is required. Read/write failures are visible. **Sidebar settings > Reset all icon
preferences** is the explicit recovery action. Pets have their own picker (see
[Pets](../pets-and-icons/pets-cmux-maestro-native-maestro-pet.md)). Favicon fetching is not part of
either picker.

`SidebarIconPicker` is a controlled, reusable SwiftUI view. Inject a
`SidebarGlyphCatalog`, `SidebarIconChoice`, source/notice text, and callbacks for
selection, resets and dismissal. `SidebarIconPickerButton` provides the native
primary/secondary-click and keyboard anchor. Neither component reads preferences,
knows session identity, or calls the host. `SidebarItemIcon` is the thin sidebar
adapter. It owns the popover and connects those components to persistence.
Picker uses inherited native appearance and semantic colors, with a neutral
catalog grid. Only an explicitly selected icon color and the swatches add color.
It does not hardcode themes. Automatic CMUX/Ghostty palette inheritance (for
example, switching between Nord and Tokyo Night) is tracked in
[#67](https://github.com/jdylanmc/cmux-maestro/issues/67). Pinned
sidebar SDK does not expose the host's resolved theme colors. Native light/dark
adaptation is not a claim of custom terminal-palette matching.
