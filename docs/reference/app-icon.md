# App icon

The containing app uses the original **Legato / Glacier** artwork: a petrol
calligraphic signature on an ice-blue tile. This is product branding, not a
session icon or pet.

- Editable vector: [`Resources/AppIcon.svg`](../../Resources/AppIcon.svg).
- Raster master: `CMUXMaestroPreview/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`.
- Both app configurations already select `AppIcon`. The app's synchronized
  asset catalog supplies all ten macOS slots; no runtime icon override.

## Export

The committed 1024px transparent PNG is the raster master. To regenerate the
other nine catalog files on macOS, without additional dependencies:

```sh
python3 scripts/generate-app-icon.py
```

After an approved vector edit, first replace the master with a transparent
1024x1024 export of the SVG. The current master was rendered in Chromium at
device scale 1 with a 1024x1024 viewport and transparent background, then
resampled with macOS `sips`. Do not use Quick Look thumbnails: they flatten
transparency. Different SVG renderers or `sips` versions may change edge pixels;
inspect the 16px and 32px exports before committing.

With an existing Playwright browser, the master export is:

```js
const context = await browser.newContext({
  viewport: { width: 1024, height: 1024 },
  deviceScaleFactor: 1,
});
const page = await context.newPage();
await page.goto(pathToFileURL(resolve("Resources/AppIcon.svg")).href);
await page.screenshot({
  path: "CMUXMaestroPreview/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
  omitBackground: true,
});
await context.close();
```

`resolve` and `pathToFileURL` are Node's `node:path` and `node:url` exports.
Playwright is an optional artwork-export tool, not an app or build dependency.
Ordinary builds consume the committed PNGs.

## Verification

```sh
python3 scripts/test-build-metadata.py BuildMetadataTests.test_app_icon_compiles_all_macos_sizes_and_preserves_png_payloads
./scripts/build-unsigned.sh
```

The focused check compiles the catalog with `actool`, verifies all ten named
size/scale renditions in `Assets.car`, and compares the lossless 32px, 128px and
256px fallback PNGs extracted from `AppIcon.icns` with the authored files.
`actool` keeps only a subset in ICNS; `iconutil` also re-encodes its legacy 16px
representation. The unsigned app includes the catalog and fallback.
Neither check installs the app or proves the live Dock has refreshed its cache.
