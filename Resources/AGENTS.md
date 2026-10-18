# AGENTS.md — the app icons

Four Icon Composer documents sit under `Resources/`, all four in the app target's Resources build
phase. Two axes pick the one that ships, and both reach `ASSETCATALOG_COMPILER_APPICON_NAME`
through `RUNTIME_VIEWER_APP_ICON_NAME` in the app's Debug / Release xcconfigs:

- **Channel** — `AppIcon` versus `AppIconBeta`, the latter being the former plus a BETA badge
  lifted from Xcode's own icon. `ArchiveScript.sh` overrides `RUNTIME_VIEWER_APP_ICON_BASE_NAME`
  with `AppIconBeta` when the release channel is `beta` (inferred from a `-beta` / `-RC` /
  `-alpha` version tag); everything else — local Debug builds included — gets `AppIcon`. The
  indirection exists because a plain `ASSETCATALOG_COMPILER_APPICON_NAME=` override on the
  `xcodebuild` command line reaches every target in the scheme, including
  `RuntimeViewerCatalystHelper`, whose icon is its own `CatalystHelperIcon` document and has no beta
  variant.
- **Toolchain** — the originals versus their `Xcode26` variants. **Xcode 26's actool cannot open
  an Icon Composer 27 document at all**: a top-level `"features"` key makes it fail with
  `Could not open "…"` and write no output whatsoever — no icns, no `Assets.car`, no partial
  `Info.plist`. A build under Xcode 26 therefore gets `AppIconXcode26.icon` /
  `AppIconBetaXcode26.icon`, selected by
  `RUNTIME_VIEWER_APP_ICON_VARIANT_$(XCODE_VERSION_MAJOR)`, which is undefined for 2700 and
  later — so every Xcode after 26 gets the originals.

**The assignment lives in `Configurations/RuntimeViewerUsingAppKit/Shared.xcconfig`, and the target
must not set `ASSETCATALOG_COMPILER_APPICON_NAME` itself.** A target-level value in the project file
outranks every xcconfig, so a literal there pins one icon for both channels and both toolchains — which
is what happened from 5d16aad6 until the 2026-09-23 fix: no variant and no beta badge was ever picked.
The App Icon field in the target's General tab edits that target-level setting, so leave it alone.

**Edit the originals, then regenerate the pair in the same commit.** `AppIcon.icon` and
`AppIconBeta.icon` are the Icon Composer 27 documents to open and edit; `AppIconXcode26.icon` and
`AppIconBetaXcode26.icon` come out of
`swift Resources/AppIconTools/GenerateXcode26IconDocuments.swift`, run from the repository root.
The same script produces the Catalyst helper's pair, below. Background: evolution 0020.

**The Catalyst helper has an icon of its own: the app's, plus a CATALYST badge.**
`CatalystHelperIcon.icon` and its generated `CatalystHelperIconXcode26.icon` live in
`RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/`, which is a synchronized folder of the helper
target, so they are its resources without any file reference in the project — and never the app's.
The toolchain rule lives in the helper's own xcconfig, `Configurations/RuntimeViewerCatalystHelper/Shared.xcconfig`:
`ASSETCATALOG_COMPILER_APPICON_NAME` expands
`RUNTIME_VIEWER_CATALYST_HELPER_ICON_VARIANT_$(XCODE_VERSION_MAJOR)`. It has no beta variant. Its
three lower groups and their assets are copies of `AppIcon.icon`'s, so an edit to the shared layers
goes into `AppIcon.icon`, `AppIconBeta.icon` and `CatalystHelperIcon.icon` alike, then the variants
are regenerated. The badge's two layers come out of
`swift Resources/AppIconTools/GenerateCatalystBadgeLayers.swift <the .icon's Assets directory>`;
its group settings are the BETA badge's. Background: `Documentations/Evolutions/0028-catalyst-helper-icon.md`.

**`actool` fails silently here.** Ask for an app icon that is not among its inputs and it exits 0
with an *empty* partial `Info.plist`: no error, no icon, a shipped app with a blank tile. That is
why `ArchiveScript.sh` re-reads `CFBundleIconName` out of the exported bundle — the app's and the
embedded Catalyst helper's — and fails the run when either does not match the name the channel and
the toolchain imply. That check restates the build settings' rule in shell on purpose: two
independent derivations, so getting either one wrong fails the archive instead of shipping the
wrong icon.

**Preview with `ictool`, not by building.** Icon Composer ships a command-line renderer that
exports any appearance of a document straight to PNG, whatever the system appearance is set to:
`"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" X.icon --export-image --output-file out.png --platform macOS --rendition Dark --width 512 --height 512 --scale 1`
(`Default` for light). It also renders an old revision restored with `git show`, which is how to
compare before and after. `Resources/AppIcon.png`, the README's icon, is the dark rendition as the
system composites it: the 824-point body at (100, 100) on a 1024 canvas, over a drop shadow
`ictool` does not draw. The shadow depends only on the outline, so re-export it by compositing an
824-pixel `ictool` Dark render over the existing file at +100+100 — measured against the system's
own rendering, that differs in under half a percent of the body's pixels, all on the rim.

**The badge borrows Xcode's shapes, not its colours.** Both SVGs come from Xcode's own `.icon`, but the
pale glass lozenge was replaced by the disc's near-black with a white wordmark, matching the
dark-plate-carrying-white-content pairing of the rest of the icon. Before touching that group: Xcode's
wordmark layer uses the `multiply` blend mode, which renders white as *nothing at all* — the whole group
is on `normal` now — and Xcode's second lozenge pass, which existed only to lift the pale glass in dark
appearance, was deleted rather than left at zero opacity.

Five things to know before editing any of them:

- **Never use `stroke` in these SVG assets.** Icon Composer's SVG pipeline through Icon Composer
  1.6 ignores `stroke` and fills the shape instead, so a `fill="none"` ring renders as a solid
  disc. `DiscOutline.svg` and `Magnifier.svg` were stroked until 2026-09-21 and covered the whole
  foreground on macOS 26 while looking perfectly correct in Icon Composer 27. Convert strokes to
  filled outlines — and remember a `round` line cap extends the line by half the stroke width at
  each end, which the outline has to reproduce.
  `Documentations/ResolvedIssues/2026-09-21-icon-strokes-rendered-as-fills.md`
- **Four visible groups is a hard ceiling** — `actool` rejects a fifth with
  `Too many visible groups`. `AppIconBeta.icon` and `CatalystHelperIcon.icon` already use all
  four, so adding a layer group means merging two existing ones first.
- **An SVG layer's viewBox units and a bitmap layer's pixels are the same unit.** Every layer
  here uses an 824-unit viewBox at `scale: 1.3`, which is what the original 824-pixel bitmap
  foreground occupied.
- **The dark-appearance background gradient is not yours to set.** A `dark` entry under the
  top-level `fill` is ignored — verified by compiling one with deliberately absurd colours and
  finding the system's own grey pair in the output. Per-layer `fill-specializations` do work, and
  are how the disc, outline, magnifier and code listing adapt.
- **A vector layer with no `dark` fill gets recoloured, not left alone.** Without a `dark` entry the
  dark appearance tints the layer with the background's hue — the white code listing came out
  blue. A layer meant to stay white in dark appearance needs its `dark` entry set to white.
  `Documentations/ResolvedIssues/2026-09-28-icon-code-listing-too-thin.md`

`Resources/AppIconTools/GenerateCodeListingLayer.swift` regenerates the code-listing layer, which
is a few hundred glyph outlines and cannot be hand-edited. Its header records the metrics the
layer was fitted to — the face's weight included, which the line width alone cannot pin down
(every weight of a monospaced face is equally wide) and was once got wrong because of it.
