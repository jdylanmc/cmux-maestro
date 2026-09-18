# Nerd Fonts symbols

Upstream: https://github.com/ryanoasis/nerd-fonts
Version: 3.5.1
Revision: b894ea7803af6aade63d60a4381e006098ec9c4d

`SymbolsNerdFont-Regular.ttf`, `glyphnames.json`, and `LICENSE` are unmodified
upstream files. Their SHA-256 digests are recorded in `manifest.json`.
The symbols-only distribution's MIT license is retained in `LICENSE`.
The constituent icon sets, sources, and license declarations are retained in
`GLYPH-SOURCES.md`; their authors retain their rights and attribution.

`presets.json` is Maestro's local list of favorites, not a restriction on
selectable glyphs. Identity colors and runtime state are separate.
The upstream `cod-blank` entry has no drawable outline and is excluded from
selection; the other 10,994 names are checked against the bundled font.

The font is loaded directly from this bundle for drawing icon outlines. It is
not installed system-wide and does not replace the app or terminal text font.
