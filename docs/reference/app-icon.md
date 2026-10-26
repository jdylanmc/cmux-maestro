# App icon

The containing app uses original **Legato / Glacier** artwork: a petrol
calligraphic signature on ice blue, inverted for dark appearance. This is
product branding, not a session icon or pet.

- Editable vectors: [`Resources/AppIcon.svg`](../../Resources/AppIcon.svg)
  and [`Resources/AppIcon-dark.svg`](../../Resources/AppIcon-dark.svg).
- Native document: `CMUXMaestroPreview/AppIcon.icon/icon.json`.
- Full-bleed 1024px masters: `AppIcon.icon/Assets/Glacier-light.png` and
  `Glacier-dark.png`.
- Both app configurations select `AppIcon`. The synchronized app group includes
  the native document; Xcode compiles the appearance stacks, sizes and fallback.
  The superseded ten-slot catalog is removed, not a second fallback source.

## System appearance and compatibility

The deployment target remains macOS 14. On macOS 26+, system icon style controls
the native appearances. In **System Settings > Appearance > Icon & widget style**,
**Dark > Auto** follows light/dark appearance. Default, Always, and tinted styles
remain user choices; the app does not change system settings.

Older macOS receives Xcode's generated static light icon. Icon Composer owns
the mask, rim/bevel and fallback padding/shadow; this native finish is approved,
not pixel-identical to the original flat artwork. Layer glass, specular,
translucency and shadow are disabled to preserve the mark and authored colors,
but system rendering still varies by platform generation.

There is no Dock-only override, bundle mutation or runtime icon-selection code.
Offscreen renders and compiled assets do **not** establish live Dock/Finder
refresh behavior or Notification Center badge appearance/refresh. Notification
communication avatars and session pets are separate concerns.

Apple references: [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
and [macOS appearance settings](https://support.apple.com/guide/mac-help/change-appearance-settings-mchlp1225/26/mac/26).

## Export

Ordinary builds consume the committed PNG masters with the repository's Xcode
toolchain; no extra dependency is needed. After an approved vector edit, prepare
full-bleed SVGs:

```sh
python3 scripts/generate-app-icon.py
```

The script maps the original tile bounds to the native canvas and removes its
baked mask, without redrawing the signature or changing gradient coordinates.
Rasterize the generated SVGs at 1024x1024, device scale 1. The current masters
use Chromium. With an existing Playwright browser:

```js
const context = await browser.newContext({
  viewport: { width: 1024, height: 1024 },
  deviceScaleFactor: 1,
});
const page = await context.newPage();
for (const appearance of ["light", "dark"]) {
  await page.goto(pathToFileURL(resolve(
    `.build/app-icon-source/Glacier-${appearance}.svg`
  )).href);
  await page.screenshot({
    path: `CMUXMaestroPreview/AppIcon.icon/Assets/Glacier-${appearance}.png`,
    omitBackground: true,
  });
}
await context.close();
```

`resolve` and `pathToFileURL` are Node's `node:path` and `node:url` exports.
Playwright is an optional artwork-export tool, not an app or build dependency.
Inspect native light/dark renders and the generated legacy fallback at large,
32px and 16px sizes after any export. Do not bake the native mask or glass
effects into the masters.

## Verification

```sh
python3 scripts/test-build-metadata.py BuildMetadataTests.test_app_icon_compiles_native_appearances_and_light_legacy_fallback
./scripts/build-unsigned.sh
```

The focused check compiles the document and catalog with `actool` at minimum
macOS 14, verifies distinct 1024px source payloads and Aqua/DarkAqua icon stacks
in `Assets.car`, and checks generated static sizes and the ICNS subset. Native
`ictool` renders must have opposite background/signature contrast; the extracted
legacy icon must stay light. These are rendering/compilation assertions, not
merely JSON checks.

The unsigned app must contain those same native stacks and `AppIcon.icns`, with
`CFBundleIconName` and `CFBundleIconFile` set to `AppIcon`. Neither command
installs the production app or proves a live icon cache has refreshed.
