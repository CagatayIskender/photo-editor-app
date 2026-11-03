# AURUM for Android

Phase 4: the Android port of AURUM's photo editor. It is Kotlin with Jetpack Compose, and it reads the same catalogues, brand file, fonts, sticker artwork and translations as the iOS app.

```
android/
  core/    Pure Kotlin/JVM domain model (kotlinx.serialization), the pixel renderer and JUnit tests
  app/     Compose app (minSdk 26, target/compile 35)
  tools/   sync_android_assets.py, svg_to_vector.py
  l10n/    android_strings.json (Android-only wording, EN + TR)
```

## Build

You need JDK 17 or newer. `:app` also needs an Android SDK with platform 35.

```sh
cd android
./gradlew :core:test                      # runs anywhere; no Android SDK needed
python3 tools/sync_android_assets.py      # after changing anything shared at the repo root
./gradlew :app:assembleDebug              # needs the SDK: local.properties sdk.dir=… or ANDROID_HOME
```

The build only includes `:app` when it finds an SDK, either from `local.properties` `sdk.dir` or from `ANDROID_HOME` / `ANDROID_SDK_ROOT`. That way `:core:test` also works on CI images that have no Android tooling. To force it either way, pass `-Paurum.includeApp=true|false`.

`preBuild` runs `tools/sync_android_assets.py --check` and fails if:
- any Android copy is stale, or
- a `tr("…")` key used in app code has no string.

On a machine without Python, skip that check with `-Paurum.skipAssetCheck`.

## Shared sources

`tools/sync_android_assets.py` is the only thing that writes these files. Run it from anywhere. Add `--check` to verify without writing anything.

| Source (repo root) | Android copy |
|---|---|
| `Looks/catalog.json`, `Content/*.json`, `Brand/brand.json` | `app/src/main/assets/{looks,content,brand}/` |
| `App/Fonts/*.ttf` | `app/src/main/res/font/<snake_case>.ttf`, copied byte for byte |
| `App/Fonts/licenses/*.txt` | `app/src/main/assets/licenses/` |
| `App/Assets.xcassets/sticker.*/*.svg` | `app/src/main/res/drawable/sticker_*.xml` (VectorDrawable) |
| `App/Localizable.xcstrings` plus `l10n/android_strings.json` | `res/values/strings.xml`, `res/values-tr/strings.xml`, `L10nKeys.kt` |

Strings:
- Screens call `tr("Begin")` with the English source text, just as SwiftUI does, so both apps share one translation table.
- Swift format specifiers are converted: `%lld` becomes `%d` and `%@` becomes `%s`. When a string has more than one argument, they become positional.
- `l10n/android_strings.json` holds the Android wording. For example: phone instead of iPhone, Google Play instead of the App Store and Settings, and "Coming to Android".

Stickers:
- `tools/svg_to_vector.py` converts exactly the SVG subset the stickers use: paths, basic shapes, rotate/translate transforms, opacity, and dashes on straight lines. It fails loudly on anything else.
- No PNGs are generated.
- Every sticker was checked by rendering the SVG and the generated VectorDrawable side by side.

## What is ported

### `core` (pure JVM)
These are 1:1 ports of `AurumCore`. The JSON they read and write matches what Swift `Codable` produces:
- sorted keys
- upper-case UUIDs
- whole-second ISO-8601 dates
- tagged unions, including Swift's enum-with-associated-values shape
- `[UUID: Int]` encoded as a flat array

`PresetTest` and `JsonCompatibilityTest` compare against Swift output byte for byte.

The ported pieces:
- EditDocument with its operations and migrator
- EditHistory (transactions)
- LookCatalog with search
- Preset and its link codec
- ExportGate (free: watermark and 2048 px; member: full resolution, including the video and collage decisions)
- VideoProject timing (clips, transitions, layers, split and move)
- AnimatedEffect
- BeatGrid, BeatDetector and TemplateBuilder
- AI job model and CreditLedger
- Collage layouts and Carousel
- Drops, DayStamp and Streak
- ColorCube and LookSuggestion

There is also `render/PixelRenderer`: a CPU renderer for looks and adjustments, explained below.

### `app`
- **Onboarding**: the promise, choosing up to three aesthetics, and privacy.
- **Shell**:
  - Salon: featured collection, Create tiles, Auto Studio tiles, the active drop and creating streak, drafts to continue, and look rows by collection.
  - Create: the photo picker plus tiles.
  - Vault: drafts, and presets you can use, share or delete.
- **Photo Picker API** (`PickVisualMedia`, images only). AURUM needs no storage permission to read photos. Drafts keep a persisted URI permission where the picker grants one.
- **Studio**:
  - Looks:
    - The strip shows the photo rendered in each look.
    - Collections, Saved (long-press to save a look), search with synonyms, intensity, and Refine (grain, fade, vignette, light leak).
    - Save as preset.
    - Swipe across the photo to step through the looks in a collection.
  - Adjust: all 17 controls, plus Reset all.
  - Crop: aspect presets, straighten, rotate 90°, flip.
  - Text: the six fonts, the brand palette, and the styles Plain, Shadow, Outline, Glow, Gilded and Label. Drag, pinch and rotate to place it.
  - Stickers: all 15, by category.
  - Undo and redo (one drag is one step), and touch-and-hold compare.
  - Drafts are saved automatically when you leave the Studio.
- **Export**:
  - It applies the `ExportGate` rules:
    - A free edit that uses member items shows the gate, with "Join" or "Export without them".
    - Free exports are capped at 2048 px and carry the watermark: Playfair at 26 units, ivory at 0.8, 32-unit margin, as on iOS.
    - Members export at full resolution with no mark.
  - Exports are saved as JPEG (quality 92) to `Pictures/AURUM` through MediaStore. Android 8–9 asks for `WRITE_EXTERNAL_STORAGE`; later versions don't need it.
  - After export you can share the photo, and the export counts toward the streak.
- **Paywall**:
  - It is reachable only from export ("Join", or "Remove mark").
  - Purchases go through the `MembershipStore` interface:
    - `FakeMembershipStore` in debug builds: no Google Play calls, and membership is simulated. Clear app data to become a free user again.
    - `PlayBillingMembershipStore` in release builds: Play Billing 7, using the product ids from `brand.json`, with free trials read from the offer phases and purchases acknowledged.
- **Localisation**: English and Turkish (`values`, `values-tr`, plus `locales_config` for per-app language).
- **Accessibility**:
  - When the system "Remove animations" setting is on, every transition becomes a cut. This is `LocalReduceMotion`, which watches `ANIMATOR_DURATION_SCALE`.
  - Controls have content descriptions, roles and selected state.
  - Saving or removing a look and deleting a draft are also available as accessibility actions.
- **Studio Retouch**: the iOS retouch sheet. Faces come from ML Kit face detection (bundled model, contours and landmarks); `core/render/RetouchRenderer` draws it in the preview and the export.
- **Video editor** (`ui/video`, `video/`): clips and photos from the picker, trim, split, speed, reverse, transitions, looks, animated effects, text layers, intro/outro cards and imported music with beat detection. Preview and export run through Media3 Transformer with one GPU shader (`AurumFrameEffect`); exports go to `Movies/AURUM`, 1920 px with the mark for free users, up to 4K for members.
- **Templates** (`ui/templates`): beat templates built with `TemplateBuilder`, then opened in the video editor.
- **Camera** (`ui/camera`, `camera/`): CameraX with the chosen look applied live (a 25³ LUT on analysis frames), front/back, flash, timer, grid and tap to focus. The shot opens in the Studio wearing the look.
- **Auto Studio** (`ui/autostudio`, `ondevice/`): auto enhance, portrait blur, background, relight, retouch, straighten, object removal (classic inpainting in `core/Inpainting`) and portrait looks. Everything runs on the phone: ML Kit face detection and selfie segmentation with bundled models, plus pixel processing. Nothing is uploaded and there is no generative AI.
- **3D Motion**: estimated depth (ground gradient plus the ML Kit person mask), near/far layers with a blur fill, live preview, and MP4 export with MediaCodec.
- **Collage and Carousel** (`ui/collage`, `collage/`): layouts, pan and zoom per cell, spacing, corners, background; carousel panels for swipe posts.
- **Motion** (`ui/common/MotionKit.kt`): entrances, press states, shimmer, ambient glow, drawn checkmark and gold progress ring, all still or fade-only when "Remove animations" is on.

## Rendering, and what is approximated

Looks and adjustments are rendered on the CPU by `core/render/PixelRenderer`, not with `ColorMatrix` or `RenderEffect`. The reasons:
- `RuntimeShader` needs API 33, and `ColorMatrix` cannot express curves, split toning or vibrance.
- A pure-Kotlin renderer runs the same code for the preview, the export and the JVM unit tests (`RendererTest` runs every shipped look).

Each operation's colour steps are baked into one 33³ LUT. The spatial steps then run per pixel. The order follows the iOS `FilterGraph`.

These are approximations of Core Image, where Core Image has no public formula:
- **Highlights and shadows**: a global tone curve. `CIHighlightShadowAdjust` is local, so high-contrast scenes differ the most.
- **Temperature and tint**: per-channel gains that approximate `CITemperatureAndTint` (6500 K ± 2500 K).
- **Tone curve and fade**: piecewise-linear through five points. Core Image uses a spline.
- **Grain**: seeded hash noise blended in soft light, with the same seed derivation as iOS (FNV-1a of the document id). The pattern differs from `CIRandomGenerator`, but it is stable for each document.
- **Bloom, vignette, light leak, clarity, structure, sharpness**: three-pass box blurs and unsharp masks, sized to the image (scale relative to 1080 px), rather than Core Image's kernels.
- **LUT quantisation**: 33³ trilinear sampling, as with iOS `.cube` LUTs. The error is at most about 1/255 on smooth gradients.
- **Overlay blend "soft light"** before Android 10 falls back to overlay.
- **Text**: `StaticLayout` with the same TTFs and metrics roles. Line breaking and kerning can differ slightly from Core Text.

## Not on Android yet

- **3D Motion** always estimates depth: Android has no common way to read Portrait-mode depth maps.
- **Auto Studio** scene labels are "sky" and "people" only (no bundled scene classifier); the horizon finder, auto tone, red-eye and noise reduction are pixel approximations of the Core Image and Vision versions.
- **Video**: the preview re-renders about 350 ms after an edit; during a transition the outgoing clip is a held last frame. Bloom has no blur in video.
- The licensed music library is still empty on both platforms; songs can be imported from Files.
- **Crop**: aspect presets are centred. There are no drag handles for a free crop rectangle yet; "Free" keeps the current frame.
- **Member exports** use full resolution up to what the heap allows (`largeHeap`, about 24 bytes per pixel at peak). Larger photos are scaled to fit, which on most devices means roughly 12–25 MP. Tiled rendering would remove that limit.
- Remote config and catalogue updates use the bundled defaults.

## Rules

- Never commit build outputs, `local.properties` or an SDK (see `.gitignore`).
- Files generated under `app/src/main/{assets,res/font,res/drawable/sticker_*,res/values*/strings.xml}` and `L10nKeys.kt` are committed but never edited by hand. Change the source at the repository root and run the sync script.
