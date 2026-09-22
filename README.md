# GlowSnake, source at the measured revision (git tag paper-glowsnake-2026-07-29)

## Title

GlowSnake: source code of the game and measurement harnesses studied in
"One Draw Call per Frame" (PeerJ Computer Science, manuscript 148811).

## Description

GlowSnake is a complete 2D arcade game whose whole frame renders through
one instanced draw call over uniform 96-byte instance records. This
package is the exact revision measured in the article (commit 01d105f,
2026-07-29): the iOS game as a single Swift file with a Metal renderer,
the Kotlin port of its platform-independent layers with an OpenGL ES 3
host for Android, and the measurement harnesses that extract the pure
layers from the Swift source at build time. Later revisions of the game
(an ink-fluid background and a neural-engine study, added from August
2026) are not part of this package and lie outside the article's scope.

## Code information

```
main.swift                 the whole iOS game (2,579 lines): model, draw-list,
                           scene builder, Metal renderer, glyph atlas, UIKit host;
                           the MSL shader is the string `shaderSource` inside it
Snake.xcodeproj, Info.plist
android/core/              Kotlin port of the pure layers (Model, Rand, DrawList,
                           SceneBuilder; 1,513 lines) + GoldenTraceTest
android/app/               Android host (MainActivity, GlRenderer; 574 lines)
paper/harness/             measurement harnesses (see below)
```

Section markers (`// MARK:`) in `main.swift` delimit the layers listed in
the article's line manifest (`LINE_MANIFEST.md` in the data package).

Harnesses (`paper/harness/`), each a build script that extracts the pure
layers and the shader from `../../main.swift` and compiles them with a
small driver:

| script | driver | produces |
|---|---|---|
| `build.sh` | `main.swift` (+ `GlyphAtlasStub.swift`) | headless census `headless_counts.csv`, golden trace |
| `gpu_build.sh` | `GPUMain.swift`, `SKBaselineMain.swift` | offscreen Metal sweeps, draw-call comparison, overdraw sweep, SpriteKit baseline, shader compile times |
| `heatmap_build.sh` | `HeatmapMain.swift`, `rasterize.swift` | peak-frame raster and per-pixel overdraw statistics |
| `swatch_build.sh` | `SwatchMain.swift` | pellet swatch figure |
| `variance_runner.sh`, `poco_variance_runner.sh`, `redmi_variance_runner.sh` | shell | on-device repeat runs (iOS via devicectl, Android via adb) |
| `variance_stats.sh` | shell, awk | per-run finale statistics of the device logs |

## Usage instructions

iOS (simulator, no signing):

```sh
xcodebuild -project Snake.xcodeproj -scheme Snake -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Physical device: add `-destination 'platform=iOS,id=<UDID>'
-allowProvisioningUpdates DEVELOPMENT_TEAM=<your team>`. The quality
tier ("Sparks", x1/x2/x4/x8) is a persisted setting in the gear menu;
the device runs inject it at launch with the argument `-fxScale N`
(`xcrun devicectl device process launch ... com.smoketest.snake -- -fxScale 8`).
`FX.benchMaxFinale = true` in this revision, so every finale is the full
30-rocket show, as stated in the article. The app writes one
`perf_<unixtime>_fxN.csv` per run into its Documents folder.

Android: `cd android && gradle :app:assembleRelease` (`build.sh` wraps
this with the author's Gradle path; edit it or call Gradle directly).
`gradle :core:test` runs the golden-trace unit test, which replays the
seeded script and compares against `golden_trace_seed12345.txt` from the
data package (place it at `paper/data/golden_trace_seed12345.txt`, the path the test reads).

Harnesses: `cd paper/harness && ./build.sh` (census), `./gpu_build.sh`
(GPU sweeps, writes to `../data/`), `./heatmap_build.sh` (writes to
`../figures/`). Each script documents its arguments in its header.

## Requirements

macOS with Xcode 15 or later (Swift 5.9+, Metal; verified with Xcode 27); iOS 15+ target. The
harnesses run on any Apple-silicon Mac (the article's M1 numbers were
taken with `swiftc -O`). Android: JDK 17, Android SDK 34, Gradle 8; the
device runners need `adb` and, for iOS, `xcrun devicectl`.

## Data

All measurements, the golden trace, screenshots and the line manifest
are in the data package on Zenodo, all-versions DOI
10.5281/zenodo.21736156. A zip of this repository at the tag
`paper-glowsnake-2026-07-29` is deposited there as well.

## Citation

Please cite the article (citation to be added on publication).

## License

PolyForm Noncommercial License 1.0.0 (see `LICENSE.txt`). Anyone may
read, build, run, modify and share this code for noncommercial
purposes, which includes reviewing and replicating the article's
results. Commercial use is not licensed; the author retains all
commercial rights.

Required Notice: Copyright Jos Timanta Tarigan (2026), Universitas
Sumatera Utara.

## Author

Jos Timanta Tarigan, Faculty of Computer Science and Information
Technology, Universitas Sumatera Utara, Medan, Indonesia.
ORCID 0000-0001-9433-2265. jostarigan@usu.ac.id
