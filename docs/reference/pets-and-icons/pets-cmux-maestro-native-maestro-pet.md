# Pets: `/cmux-maestro-native:maestro-pet`

Part of [Pets and session icons](../pets-and-icons.md). Next page is [Mood atlas contract](mood-atlas-contract.md).

Active agent's pinned details show animated Codex-format pet (1536×1872 PNG/WebP,
8×9 cells of 192×208). Legacy sheets have width a multiple of 8, 512-4096,
and height from `ceil(9 * 208 * width / 1536)` through `2 * width`.
A v2 pet (1536×2288) works, and legacy tails are ignored. A fixed 20-row mood atlas
also works, with width 512-1536, a multiple of 8, and height exactly
`ceil(20 * 208 * width / 1536)` (standard 1536×4160).
Every agent starts with bundled, original **Maestro** robot-head
pet. Animation follows the [pet mood resolver](../pet-moods.md): thirteen derived
moods plus optional exact-session self-reports. Legacy sheets use explicit fallback rows.
Collect pets: while an agent uses an agent-made pet, hover its footer pet and click the centered **+** to
save it to your shared pets (the picker has the same **+** on agent-made cells and a confirmed **×**
on collected ones). Every agent's picker lists the whole collection. Removing a collected pet makes
agents using it fall back to their own pet or Maestro. Click pet to open picker: bundled pet, pets you saved or uploaded, pet
this agent made for itself. **Upload pet…** accepts Codex pet folder (`pet.json` plus
spritesheet) or bare sheet. Picker also links to online Codex pet galleries.

Bundled `maestro-pet` skill ships `pet_kit.py`: a Python standard-library drawing kit
(shapes, alpha, PNG writer). Any Copilot session in CMUX with Maestro's integration
draws its own original pet with no image provider, API key, network or package
install. Kit requires every frame of the five original rows, fills other Codex
rows from idle, and writes `pet.json`, `spritesheet.png` and `preview.png` to a new
folder. It never selects a pet. Agent adds pet with
`cmux-maestro-orchestrator pet --self --session-id … --add <folder>`. Command validates
format. It selects pet only after native identity helper proves session ownership.
Agent-made pet is **scoped to that session**. Use **Save to my pets** in picker to
keep it for every agent. Precedence: your choice, then agent's choice, then Maestro.
**Reset to default** chooses Maestro as your choice, so it wins over the agent's
pet until reset. **Reset to agent's pet** removes your choice. **Hide pet** /
**Show pet** applies to that session only; a hidden footer pet shows a small
sparkle that still opens the picker. Choices and hidden state follow the exact
session UUID across pane moves and app restarts; a replacement session in the
same pane starts fresh. Agent hover cards show the hovered session's own pet
and hidden state, never the active agent's. Row **Appearance > Choose pet…**
opens the same picker for that exact session; activity-only children, status-only
sessions, terminals and browsers have no pet. Reduce Motion shows still frame.

Pet playback uses a bounded render-server frame sequence at seven frames per second,
not a SwiftUI timeline. Working rings and input glows also animate in layers.
Hidden or detached native views remove their animations; changing the pet or state
replaces its sequence. No frame tick publishes evidence or requests sidebar layout.
