# CatPointer v1.6.1 validation report

Validation date: 2026-08-01

Test host: Apple M4, macOS 26.3.2 (25D2140), Apple Silicon (arm64)

## Scope

This release expands the original CatPointer artwork from two cursor actions
to seven:

- normal Arrow;
- text I-beam;
- link selection;
- working in background;
- busy/wait;
- horizontal resize;
- vertical resize.

Every action uses the original PNG sequence from the pinned upstream revision.
No missing action was redrawn or inferred from another cursor.

Classic Cat Slow now plays the existing 24 registered original-artwork frames
at 8 FPS instead of stretching them across the original 4.29–4.62 second
loops. Medium, Fast, and Extreme remain 12, 20, and 30 FPS.

## Source artwork

| Action | Original frames | Original cycle | macOS frames |
| --- | ---: | ---: | ---: |
| Arrow | 130 | 4.290 s | 24 |
| Text | 140 | 4.620 s | 24 |
| Link | 94 | 3.099 s | 24 |
| Working in background | 45 | 1.482 s | 24 |
| Busy | 44 | 1.449 s | 24 |
| Horizontal resize | 127 | 4.191 s | 24 |
| Vertical resize | 164 | 5.412 s | 24 |

The link, working-in-background, and busy sequences intentionally contain a
30 ms final frame after their 33 ms frames. Asset parsing preserves that
original total duration. Every configuration and frame sequence is checked
against a pinned SHA-256 digest before rendering.

## Regression and integration results

- `make test`: passed.
- All seven roles rendered at 80%, 90%, 100%, 110%, and 120%, with 1× and 2×
  representations and preserved hotspots.
- Motion-aware sampling selected 24 distinct points from every original
  timeline.
- Full packaged-app `--self-test`: passed.
- WindowServer accepted all 25 cursor identifiers discovered for the seven
  roles:
  - 3 Arrow identifiers;
  - 4 text identifiers;
  - 2 link identifiers;
  - 3 working-in-background identifiers;
  - 1 busy identifier;
  - 6 horizontal-resize identifiers;
  - 6 vertical-resize identifiers.
- All 25 registered snapshots matched the expected 24-frame image data and
  20 FPS test duration.
- All five size levels and all four speed levels passed repeated live
  re-registration.
- Slow, Medium, Fast, and Extreme registered 24 frames at 8, 12, 20, and
  30 FPS; Slow read back a 125 ms frame duration from WindowServer.
- Maximum cached size switch: 82.6 ms.
- Maximum speed switch: 62.8 ms.
- AppKit resolved the installed Arrow and text images from a fresh process.
- Original cursor backups survived repeated changes and were restored before
  the self-test exited.
- An idle sample after startup reported 0.0% CPU and 98,000 KiB
  resident memory after the bounded seven-role size cache had warmed.
- `clang --analyze`: no source diagnostics.
- `codesign --verify --deep --strict`: passed for the packaged app and the app
  extracted from the ZIP.
- ZIP integrity test: passed.
- `hdiutil verify`: passed for the DMG.
- The package contains exactly the seven documented cursor resource
  directories.

## Artifacts

| Artifact | SHA-256 |
| --- | --- |
| `CatPointer-v1.6.1-macOS-arm64.dmg` | `32f47ab2d5226652a39e415e1c3c6d122ce83506580be5e029246b19daef1c0e` |
| `CatPointer-v1.6.1-macOS-arm64.zip` | `1040ac1e68c840a8a55d008ff8404c56ecd0fd47270ecd330693aa45a51b78d8` |
| Packaged `CatPointer` executable | `66804f5670365961694500ce748563038c8266e7165984826b6a0cefe79c84ea` |

The packaged app reports version 1.6.1 (build 11), requires macOS 13 or later,
is ad-hoc signed, and includes the project and third-party license files.
