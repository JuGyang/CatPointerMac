# CatPointer v1.5.3 validation report

Validation date: 2026-07-24

Test host: Apple M4, macOS 26.3.2 (25D2140), Apple Silicon (arm64)

## Scope

This release brings the disk-image installation experience in line with
mainstream macOS applications without changing cursor behavior.

- The DMG opens at a fixed 720×472-point window size with Finder toolbar and
  status bar hidden.
- A deterministic 1×/2× background provides a clear drag-to-install arrow,
  concise Chinese guidance, and macOS/processor requirements.
- CatPointer and Applications are positioned symmetrically at a 104-point icon
  size.
- Applications is a native Finder alias that resolves to `/Applications`, not
  a decorative image or a folder inside the disk image.
- The alias carries the system Applications folder icon so it remains
  recognizable on macOS versions that render plain aliases as placeholders.
- The disk image uses the CatPointer icon as its custom volume icon.
- The application icon now isolates the complete cat component from the source
  frame, so no partial cursor arrow remains at Finder icon sizes.
- Packaging creates a writable image for layout metadata, then converts and
  verifies the final compressed read-only DMG.

## Regression results

- `make test`: passed.
- DMG background generation:
  - 1× image is 720×450 pixels;
  - 2× image is 1440×900 pixels;
  - both representations are combined into one multi-resolution TIFF.
- Finder layout:
  - saved window bounds are `{120, 120, 840, 592}`;
  - icon view uses 104-point icons and 13-point labels;
  - CatPointer is positioned at `{174, 250}`;
  - Applications is positioned at `{546, 250}`;
  - toolbar and status bar are hidden.
- Mounted-image inspection:
  - `CatPointer.app`, `Applications`, `.background/background.tiff`,
    `.VolumeIcon.icns`, and `.DS_Store` are present;
  - Applications is a macOS alias with a custom icon resource fork;
  - the alias resolves to `/Applications`;
  - Finder screenshot inspection confirmed that neither icon, label, title,
    arrow, nor footer overlaps.
- App-icon inspection:
  - the source frame's largest alpha component is isolated before scaling;
  - the complete cat has comfortable padding on every side;
  - the separate cursor arrow is absent at both source and 104-point Finder
    sizes.
- Full packaged-app `--self-test`: passed, including 24-frame Arrow and I-beam
  registration, all five sizes, all four speed levels, live AppKit resolution,
  backup preservation, and final system-cursor restoration.
- `clang --analyze`: no source diagnostics.
- `codesign --verify --deep --strict`: passed.
- ZIP integrity test: passed.
- `hdiutil verify`: passed during packaging.

## Artifacts

| Artifact | SHA-256 |
| --- | --- |
| `CatPointer-v1.5.3-macOS-arm64.dmg` | `840df4891a2bd2565ced7b341487e317fbeba736153b8e127ce93cecf3c22b85` |
| `CatPointer-v1.5.3-macOS-arm64.zip` | `1e4904cb33d0d00f56de8a37fac493c4d6330fd2975628172be09f1eda8599f4` |
| Packaged `CatPointer` executable | `36d9331492deb7e9b8b167881597b64f9ba085c7556435a4618e02d25d6e0db1` |

The packaged app reports version 1.5.3 (build 9), requires macOS 13 or later,
is ad-hoc signed, and includes the project and third-party license files.
