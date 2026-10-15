# OneAct

[English](README.md) · 简体中文

**一个人，一块幕布，一次就演完。**

OneAct 是开源的原生 macOS 录制工具，把屏幕、摄像头、声音与提词器放到一个工作台。实时构图，直接得到合成视频。

A native macOS recorder with live screen and camera compositing, person cutout, and a built-in teleprompter. Recording and processing stay on your Mac.

[项目主页](https://quentinzhang.github.io/oneact/) · [下载与版本说明](https://github.com/quentinzhang/oneact/releases/latest) · [反馈问题](https://github.com/quentinzhang/oneact/issues) · [GPL-3.0](LICENSE)

![OneAct 真实界面，画布内为演示文稿和虚构插画人物](website/assets/hero-demo.png)

*截图中的画布为示例场景，人物是插画，不使用真人影像。*

## 功能

- **屏幕与摄像头实时合成**：录制显示器、应用或窗口；支持圆角矩形、圆形、人物抠像和隐藏画中画。
- **自由构图**：横屏、竖屏和方形画布，Fit / Fill / Blur 布局，可拖动画中画、自选底色和调整软件缩放。
- **内置提词器**：在预览舞台顶部编辑与滚动脚本，中英文语速适配，录制前倒计时。
- **音频混合**：选择麦克风，可加入系统声音，也可关闭麦克风只录电脑声音。
- **H.264 / ProRes 422**：输出 `.mov` 与 AAC 音轨，支持暂停、继续和全局快捷键。
- **本地处理**：无需账号；视频、脚本与人物分割均在 Mac 上处理。版本检查会连接 GitHub。

## 下载与安装

需要 **Apple Silicon Mac、macOS 15 或更新版本**。当前提供测试版本；Intel Mac 尚未验证。

1. 从 [GitHub Releases](https://github.com/quentinzhang/oneact/releases/latest) 下载 `OneAct-macOS-arm64.zip`。
2. 解压，将 `OneAct.app` 拖入“应用程序”，然后打开。
3. 根据提示允许摄像头、麦克风和屏幕录制权限。

发布说明会注明签名与公证状态。**未经过 Apple 公证的测试包可能被 Gatekeeper 阻止**；确认来源后，可按 macOS 提示在“系统设置 → 隐私与安全性”中允许打开，或自行从源码构建。无需关闭系统安全设置。

同一 Release 提供 `SHA256SUMS`。在下载目录核对文件：

```bash
shasum -a 256 -c SHA256SUMS
```

应用菜单中的 **Check for Updates…** 从 GitHub Pages 读取版本信息，并打开对应的 GitHub Release 下载链接；更新需手动替换应用。

## 从源码构建

需要 macOS 15+ 和支持 Swift 6 的 Xcode / Command Line Tools。项目没有第三方 Swift 依赖。

```bash
git clone https://github.com/quentinzhang/oneact.git
cd oneact
./scripts/package-app.sh
open build/OneAct.app
```

默认使用 ad-hoc 签名，适合本地开发。公开分发时如需 Developer ID 签名与 Apple 公证，见 [发布指南](docs/RELEASING.md)。

```bash
BIN_PATH="$(swift build -c release --show-bin-path)"
"$BIN_PATH/OneAct" --self-test /tmp/oneact-h264.mov
"$BIN_PATH/OneAct" --self-test /tmp/oneact-prores.mov --prores
```

这两项自测无需真实摄像头，验证合成、音视频写入、暂停续录与色彩往返；真实设备和权限仍需人工验证。更多诊断方式与实现说明见 [开发文档](docs/DEVELOPMENT.md)。

## 已知限制

- 软件仍处于早期阶段，重要录制前请先录制短片并检查声音与画面。
- 纯摄像头模式会按实际输入、裁切和缩放限制输出尺寸；不会通过放大创造原始细节。
- ProRes 使用 10-bit 4:2:2 编码，当前合成缓冲区为 8-bit BGRA，不提供 HDR 或 RAW 录制。
- 提词器子窗口设置为不共享；不同 macOS 版本及第三方共享软件的表现请实测确认。

## 参与贡献

欢迎通过 Issue 报告问题，通过 Pull Request 提交改进。请先阅读 [贡献指南](CONTRIBUTING.md)。

## 许可证

Copyright © 2026 OneAct contributors.

OneAct 按 **GNU General Public License v3.0 only**（`GPL-3.0-only`）提供。完整条款见 [LICENSE](LICENSE)。分发修改后的软件时，须遵守该许可证的源码提供等要求。软件不提供任何担保。
