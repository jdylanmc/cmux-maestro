# Mood atlas contract

[↑ Pets and session icons](../pets-and-icons.md) | [← Pets: `/cmux-maestro-native:maestro-pet`](pets-cmux-maestro-native-maestro-pet.md) | [Reproduce the bundled art and upgrade copies →](reproduce-the-bundled-art.md)

The 20-row format preserves rows 0-8. Row 9 is Startled, and row 10 is reserved.
Partial extensions are refused. No manifest version bump or companion asset:
new Maestro reads legacy pets, but older Maestro rejects mood atlases.
Bundled Maestro authors all 15 moods in the 20-row atlas. Its decoded RGBA rows
0-8 remain byte-identical to the original nine-row asset. The extra expressions
change faces and poses, not UI badges. Startled has wide white eyes, an O mouth,
a lifted head, sweat and antenna sparks; Needs permission's raised palm differs
from Question. The [pet mood resolver](../pet-moods.md) selects the expression
from presentation-only evidence.

| Mood ID | Row | Frames | Legacy fallback row / frames |
| --- | --- | --- | --- |
| `idle` | 0 | 6 | 0 / 6 |
| `working` | 7 | 6 | 7 / 6 |
| `question` | 6 | 6 | 6 / 6 |
| `content` | 3 | 4 | 3 / 4 |
| `sad` | 5 | 8 | 5 / 8 |
| `startled` | 9 | 5 | 4 / 5 |
| `thinking` | 11 | 6 | 8 / 6 |
| `delegating` | 12 | 8 | 1 / 8 |
| `needs-permission` | 13 | 6 | 6 / 6 |
| `confused` | 14 | 6 | 8 / 6 |
| `compacting` | 15 | 6 | 2 / 8 |
| `sleepy` | 16 | 6 | 0 / 6 |
| `gone` | 17 | 6 | 0 / 6 |
| `proud` | 18 | 4 | 3 / 4 |
| `celebrating` | 19 | 5 | 4 / 5 |

Resolver seam: `SidebarPetSheet.Mood(rawValue:)` parses these IDs;
`SidebarPetSheet.playback(for:width:height:) -> SidebarPetSheet.Playback?`
returns `row` and `frameCount`, or `nil` for invalid geometry.
`SidebarPetStore.playback(petID:session:mood:)` resolves against the decoded sheet,
and `frame(petID:session:mood:index:)` crops it using that loop length.
All playback uses `mood:`. `SidebarPetMood` selects the expression; the sheet
and store only choose and crop authored rows.

Both formats retain the 10 MiB compressed limit. Extended width is capped before
native decoding, bounding the standard RGBA bitmap at 25,559,040 bytes, excluding
ImageIO overhead and cached crops. Legacy geometry retains its existing maximum
4096×8192 for compatibility. The new format does not increase that bound.
Top trim scans every playable mood or fallback cell, excluding reserved row 10.
Scaled cell origins round cumulatively, matching crop coordinates.

The kit's `PetSheet(moods=True)` generates all 20 rows and a 15-row preview.
Wholly undrawn mood rows copy the map's fallback, and partly drawn rows fail.
Row 10 stays transparent. Native imports validate geometry and decoding, not
art quality or blank-row content. Draw distinct mood art when authoring a full atlas.

Agents may self-report an enum-only mood for their own session
([self-reported moods](../self-reported-moods.md), ADR 0031). The sidebar reads it
as labelled presentation metadata.
