# Reproduce the bundled art and upgrade copies

[↑ Pets and session icons](../pets-and-icons.md) | [← Mood atlas contract](mood-atlas-contract.md) | [Choose your session icon →](choose-your-session-icon-cmux-maestro.md)

The original project's legacy drawing code remains in
`scripts/generate-maestro-pet.py`; `scripts/maestro_pet_art.py` draws the new
expressions with `pet_kit.Canvas`. A lossless WebP roundtrip retains the original
decoder's zero-alpha RGB behavior. Pillow is a **development-only** dependency;
the installed drawing kit remains standard-library-only. From the repository:

```sh
python3 -m venv .build/pet-art-env
.build/pet-art-env/bin/python -m pip install -r scripts/requirements-pet-art.txt
.build/pet-art-env/bin/python scripts/generate-maestro-pet.py
.build/pet-art-env/bin/python scripts/test-maestro-pet-art.py
python3 scripts/test-pet-kit.py
```

The generator writes only the selected output directory (default:
`CMUXMaestroSidebar/Pets`). It never installs or selects a pet. Pass a new output
directory to compare a regeneration before replacing checked-in assets.
Art tests pin the original decoded RGBA digest, require exact bundled WebP
reproduction, nonempty bounded frames and transparent reserved/unused cells.
Native collection tests render frame zero for all 15 moods at 38/46pt in
light/dark at 2x, compare exact pixels against explicit-row native references,
and reject identical bare frames. Contact sheets and individual references are
written under `.build/layout-validation/offscreen/pet-moods`. They are synthetic
offscreen evidence, not proof of hosted UI, live selection or mood resolution.

## Explicit offline copy upgrade

Only run on a **supplied** legacy PNG/WebP or pet folder, with the human's
direction. Never discover local pets or point output at an installed collection.
After preparing the development environment above:

```sh
.build/pet-art-env/bin/python scripts/upgrade-pet-moods.py \
  --source ./supplied-pet \
  --output ./upgraded-copy \
  --id example-mood-copy --name "Example Mood Copy"
```

The output must not exist, its parent must exist, and it must be outside the
source folder. Symlink inputs and manifest paths outside a direct child are
refused. Inputs must fully decode, be static PNG/WebP, at most 10 MiB, and use
legacy geometry at widths 512-1536 divisible by 8. Wider legacy pets are
explicitly refused rather than silently rescaled. A 20-row input is also refused.
Scaled and v2 inputs retain all decoded first-nine-row pixels; at fractional
cell heights new fallback crops alone may be nearest-neighbor fitted.

The new folder contains `pet.json`, `spritesheet.png`, `upgrade.json` with source
and legacy pixel hashes, a byte-for-byte `original-sheet.png` or
`original-sheet.webp`, and `original-pet.json` when supplied. V2 tails survive in
the untouched original and backup, not in reserved row 10. The source is never
written. Existing output is never replaced, including on a second invocation.
A write failure may leave a partial new folder; preserve it for inspection and
choose another new destination rather than retrying over it.

This is **generic fallback recomposition**, not automatic anatomy recognition:
new rows reuse old poses and may look identical. Inspect the copy, author
distinct expressions if desired, then separately use **Upload pet…** only with
human approval. Nothing in this command installs, chooses or updates local pets.
Local-pet rollout remains a separate approved operation.
