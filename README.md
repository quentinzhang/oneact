# OneAct

**One stage. One take.**

OneAct is an open-source, native macOS recorder that brings your screen, camera, audio, and teleprompter into one workspace. Compose your shot live and save a ready-to-use video.

[Website](https://quentinzhang.github.io/oneact/) · [Download](https://github.com/quentinzhang/oneact/releases/latest) · [Report an issue](https://github.com/quentinzhang/oneact/issues) · [简体中文](README.zh-CN.md)

![OneAct's real recording interface with an illustrative presentation and a fictional clay-style presenter](website/assets/hero-demo.png)

*The canvas shows an illustrative demo scene. The presenter is a fictional illustration, with no real-person footage.*

## Features

- **Live screen and camera compositing** — Record a display, app, or window. Choose a rounded rectangle, circle, person cutout, or hidden camera overlay.
- **Flexible composition** — Landscape, portrait, and square canvases; Fit, Fill, and Blur layouts; draggable picture-in-picture; custom colors and software zoom.
- **Built-in teleprompter** — Edit and scroll your script above the preview, with English and Chinese pacing and a countdown before recording.
- **Audio mixing** — Pick a microphone, include system audio, or turn the microphone off to record computer audio only.
- **H.264 and ProRes 422** — Save MOV files with AAC audio, with pause, resume, and global keyboard shortcuts.
- **Local processing** — No account required. Recording, scripts, and person segmentation stay on your Mac. Version checks connect to GitHub.

## Download and install

Requires an **Apple Silicon Mac running macOS 15 or later**. OneAct is currently in beta. Intel Macs have not been validated.

1. Download `OneAct-macOS-arm64.zip` from [GitHub Releases](https://github.com/quentinzhang/oneact/releases/latest).
2. Unzip it, drag `OneAct.app` to Applications, and open it.
3. Follow the prompts to allow camera, microphone, and screen recording access.

Each release states its signing and notarization status. **Beta builds that have not been notarized by Apple may be blocked by Gatekeeper.** After verifying the source, follow the macOS prompts in **System Settings → Privacy & Security** to allow opening, or build from source. You do not need to disable system security settings.

Each release includes `SHA256SUMS`. To verify your download, run this in the download folder:

```bash
shasum -a 256 -c SHA256SUMS
```

Use **OneAct → Check for Updates…** to check the GitHub Pages version feed and open the matching GitHub Release download. Replace the app manually to update. Versions up to 0.39 use the old update feed; download v0.40 or later manually to migrate.

## Build from source

You need macOS 15+ and Xcode or Command Line Tools with Swift 6 support. There are no third-party Swift dependencies.

```bash
git clone https://github.com/quentinzhang/oneact.git
cd oneact
./scripts/package-app.sh
open build/OneAct.app
```

Local builds use ad-hoc signing by default, so no developer certificate is required. Developer ID signing and Apple notarization are covered in the [release guide](docs/RELEASING.md) (Chinese).

To run the recording pipeline checks without a camera:

```bash
BIN_PATH="$(swift build -c release --show-bin-path)"
"$BIN_PATH/OneAct" --self-test /tmp/oneact-h264.mov
"$BIN_PATH/OneAct" --self-test /tmp/oneact-prores.mov --prores
```

These checks cover compositing, audio/video writing, pause and resume, and color round trips. Real devices and permission flows still need manual testing. See the [development notes](docs/DEVELOPMENT.md) (Chinese) for additional diagnostics and implementation details.

## Current limitations

- OneAct is early-stage software. Make a short test recording and check its audio and picture before an important session.
- Camera-only output is limited by the actual input resolution, crop, and zoom. Enlarging the output cannot create new source detail.
- ProRes uses 10-bit 4:2:2 encoding, but the current compositing buffer is 8-bit BGRA. HDR and RAW recording are not supported.
- The teleprompter window is marked as non-shareable. Verify its behavior with your macOS version and any third-party screen-sharing software.

## Contributing

Bug reports and focused pull requests are welcome. Please read the [contributing guide](CONTRIBUTING.md).

The website screenshot is reproducible without live camera or screen capture. See the [demo asset notes](Design/README.md).

## License

Copyright © 2026 OneAct contributors.

OneAct is licensed under the **GNU General Public License v3.0 only** (`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms. If you distribute modified versions, you must comply with the license, including its corresponding-source requirements. This software is provided without warranty.
