# CatPointer for macOS

<p align="center">
  <img src="Validation/catpointer-demo.gif" width="560" alt="Animated preview of the CatPointer arrow and text cursors">
</p>

<p align="center">
  A native animated cat cursor for macOS — smooth, lightweight, and designed not to interfere with normal pointer use.
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a>
  ·
  <a href="https://github.com/JuGyang/CatPointerMac/releases/latest">Download</a>
  ·
  <a href="LICENSE">MIT License</a>
</p>

## Highlights

- Replaces the macOS Arrow and I-beam cursors at the WindowServer level.
- Uses the original HappyCadogt cat animation instead of a redrawn approximation.
- Offers five cursor sizes and four friendly animation-speed levels: Slow, Medium, Fast, and Extreme.
- Applies settings immediately while avoiding unnecessary cursor rebuilds.
- Runs as a native menu bar app with no mouse-event interception, overlay window, driver, or background helper.
- Restores the original system cursors when paused or exited normally.

CatPointer uses macOS private cursor-registration APIs. A future macOS update may change or remove these APIs; if registration is unavailable, the app stops safely and reports an error.

## System requirements

| Requirement | Supported |
| --- | --- |
| macOS | macOS 13 Ventura or later |
| Processor | Apple Silicon (arm64) for the prebuilt release |
| Permissions | No Accessibility, Screen Recording, or Input Monitoring permission required |
| Distribution | Ad-hoc signed; not Apple-notarized |

Intel Macs are not included in the current prebuilt release. The source can be compiled on a compatible Intel Mac with Xcode Command Line Tools, but that configuration is not part of the tested release matrix.

## Download and install

Download the latest release from the [Releases page](https://github.com/JuGyang/CatPointerMac/releases/latest).

### Recommended: DMG

1. Download `CatPointer-v1.5.1-macOS-arm64.dmg`.
2. Open the disk image.
3. Drag **CatPointer** into **Applications**.
4. Open CatPointer from Applications.

Because this community build is not notarized, macOS may block the first launch. Control-click the app and choose **Open**. If macOS still blocks it, go to **System Settings → Privacy & Security** and choose **Open Anyway** for CatPointer.

### Alternative: ZIP

Download `CatPointer-v1.5.1-macOS-arm64.zip`, extract it, and move `CatPointer.app` to Applications. The ZIP contains the same app as the DMG and is provided for automation and users who prefer archive downloads.

The release also includes `SHA256SUMS.txt`. Verify a download with:

```bash
shasum -a 256 CatPointer-v1.5.1-macOS-arm64.dmg
```

## Use

CatPointer installs the animated cursors as soon as it starts. Use its menu bar icon to:

- open Settings;
- pause or re-enable CatPointer;
- restore the original cursors and quit.

In Settings, drag the **Cursor size** and **Cat animation speed** sliders. Changes are reflected in the interface immediately and applied to the cursor without an artificial waiting period.

## Performance and input safety

WindowServer plays the animation. CatPointer does not use a per-frame app timer, listen to mouse events, place a floating window over the pointer, or inject input. Clicking, dragging, scrolling, resizing windows, and selecting text continue to use the normal macOS input path.

| Speed | Playback |
| --- | --- |
| Slow | Original animation timing |
| Medium | 12 FPS |
| Fast | 20 FPS |
| Extreme | 30 FPS |

Cursor sizes are available at 80%, 90%, 100%, 110%, and 120%. A fixed cache holds the five sizes for Arrow and I-beam, using approximately 16.7 MiB. In testing on Apple Silicon, idle CPU usage reads 0.0%.

## Restore the system cursor

The original cursor registrations are backed up before CatPointer installs its animation. They are restored when you pause CatPointer, choose **Quit and restore system cursors**, exit normally, or when the next launch detects a backup left by an interrupted session.

You can also restore explicitly:

```bash
/Applications/CatPointer.app/Contents/MacOS/CatPointer --restore
```

Avoid force-quitting the app while CatPointer is enabled. If another app briefly retains the last animated frame after exit, moving the pointer causes macOS to fetch the restored cursor.

## Build from source

Requirements:

- macOS 13 or later
- Xcode Command Line Tools
- `clang`, `make`, `codesign`, and `hdiutil`

```bash
git clone https://github.com/JuGyang/CatPointerMac.git
cd CatPointerMac
make test
make package
```

Release artifacts are written to `dist/`:

- `CatPointer.app`
- `CatPointer-v1.5.1-macOS-<architecture>.dmg`
- `CatPointer-v1.5.1-macOS-<architecture>.zip`
- `SHA256SUMS.txt`

Run the integration self-test after packaging:

```bash
dist/CatPointer.app/Contents/MacOS/CatPointer --self-test
```

Run the self-test only when another CatPointer instance is not active. It temporarily registers both cursor types, validates all animation frames and speed levels, and restores the original cursors before exiting.

## Artwork and licenses

The cursor artwork was created by [HappyCadogt (Bilibili @406949928)](https://space.bilibili.com/406949928). This project uses the original animation frames from [`Tseshongfeeshur/cat-cursors`](https://github.com/Tseshongfeeshur/cat-cursors) at commit [`d3d6ca1`](https://github.com/Tseshongfeeshur/cat-cursors/commit/d3d6ca1a31510f2e5dcf2b69155fb1a5294978e2). The frames are sampled to the stable macOS limit of 24 animation frames; they are not redrawn.

CatPointer source code and documentation are released under the [MIT License](LICENSE). Artwork attribution, upstream licensing, and the exact source revision are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The project and third-party license files are included inside every packaged app.

## Security and privacy

CatPointer does not read keystrokes, clicks, text fields, or screen contents. It does not install a driver, system extension, launch daemon, or privileged helper. Cursor assets and configuration files are checked against pinned SHA-256 values during startup and self-test.

Please report reproducible bugs through [GitHub Issues](https://github.com/JuGyang/CatPointerMac/issues).
