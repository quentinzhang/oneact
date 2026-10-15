# Contributing to OneAct

Contributions are welcome. Before starting a substantial feature, open an issue describing the use case and your proposed approach.

## Local development

Use macOS 15+ and a Swift 6 toolchain. Run `./scripts/package-app.sh` to build the app. The [README](README.md) covers running it and the self-tests. The default ad-hoc signing does not require a developer certificate.

## Reporting a problem

Include your OneAct version, macOS version, Mac chip, recording mode, expected behavior, and reproduction steps. For audio or video issues, also include device models, output format, resolution, and any macOS video effects in use.

Diagnostic files may contain your screen, camera image, or script. Review and redact them before sharing.

## Pull requests

- Keep the change focused. Explain the problem, the resulting behavior, and how you verified it.
- Run both H.264 and ProRes self-tests for compositing, encoding, pause, timing, or color changes. Capture and permission changes also need real-device testing.
- For website changes, check narrow layouts, keyboard navigation, download links, and the fallback when JavaScript is unavailable.
- Do not commit recordings, personal scripts, diagnostic footage, build outputs, or signing credentials.

By contributing, you confirm that you have the right to provide your contribution and agree to release it under the project's GPL-3.0-only license. Identify the source and license of any third-party assets, and ensure they are compatible with the project's distribution.
