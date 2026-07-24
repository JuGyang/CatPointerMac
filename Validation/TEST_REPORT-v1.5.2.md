# CatPointer v1.5.2 validation report

Validation date: 2026-07-24

Test host: Apple M4, macOS 26.3.2 (25D2140), Apple Silicon (arm64)

## Scope

This release fixes loss of access to CatPointer when a MacBook camera housing
or a crowded menu bar obscures the status item.

- The status item now has a stable autosave name, so macOS can preserve its
  user-arranged position.
- CatPointer checks the status item against `NSScreen.safeAreaInsets` and
  `auxiliaryTopRightArea` after launch, wake, session activation, and display
  changes.
- If the item is outside the unobscured right-hand area or its window is not
  visible, CatPointer switches to a temporary Dock fallback with Settings and
  Quit commands.
- When the menu bar entry becomes usable again, the app returns to accessory
  mode and removes the Dock presence.
- Reopening CatPointer always opens Settings, including when the menu bar item
  is unavailable.
- Slider guidance now says “choose a level, release to apply” instead of
  implying that the cursor itself changes continuously while dragging.
- The settings status confirms the size and speed after a successful apply,
  and explains when a Dock fallback is active.

## Regression results

- `make test`: passed.
- Settings copy regression:
  - size and speed guidance explicitly separates selection from application;
  - dynamic tooltips describe what changes after release;
  - one drag still produces one commit.
- Synthetic camera-housing geometry:
  - no housing: no fallback;
  - visible item inside the right safe area: no fallback;
  - item intersecting the housing: fallback;
  - missing/hidden status-item window: fallback.
- Activation-policy integration:
  - simulated obstruction changed the running test app from accessory to
    regular activation policy and installed the fallback app menu;
  - simulated recovery changed it back to accessory mode.
- Real non-notched 1920×1080 display:
  - safe-area top inset was `0`;
  - CatPointer remained accessory-only (`activationPolicy = 1`) and did not add
    an unnecessary Dock icon.
- Real reopen check:
  - reopening the already-running app produced one visible `猫标设置` window;
  - observed window size was 500×432 points including the title bar.
- Full packaged-app `--self-test`: passed, including 24-frame Arrow and I-beam
  registration, all five sizes, all four speed levels, live AppKit resolution,
  backup preservation, and final system-cursor restoration.
- `clang --analyze`: no source diagnostics.
- `codesign --verify --deep --strict`: passed.
- ZIP integrity test: passed.

The test host used an external display without a camera housing. The
camera-housing branches and activation-policy transitions were therefore
validated deterministically with synthetic screen geometry and an AppKit
activation-policy integration test rather than by changing physical hardware.

## Artifacts

| Artifact | SHA-256 |
| --- | --- |
| `CatPointer-v1.5.2-macOS-arm64.dmg` | `8812f7080e6b58ec8a22b2fcbb86ce08491bb46741192822e959c7435a856ccf` |
| `CatPointer-v1.5.2-macOS-arm64.zip` | `4761a375672d974d1adf670db05c9825ff77f2eb9a62ef51e914cbef01437e25` |
| Packaged `CatPointer` executable | `85a6908e0c827e9660391ab6bd104fdd746ebe7644af45417233dba8e32e22ac` |

The packaged app reports version 1.5.2 (build 8), requires macOS 13 or later,
is ad-hoc signed, and includes the project and third-party license files.
