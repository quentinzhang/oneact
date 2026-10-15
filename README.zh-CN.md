# OneAct

[English](README.md) · 简体中文

**一个舞台，一镜到底。**

把想说的话，好好说完。OneAct 是开源的原生 macOS 录制工具，让你按自己的节奏，一次录成完整视频。**所拍即所得**：在画布上实时构图，停下录制，画面与声音就已经合在同一个视频里。

喝口水，理清下一句，或为下一个场景重新构图。**随时暂停，再在同一次录制里继续。** 暂停的等待不会进入成片，让表达有停顿，也有从容。

[项目主页](https://quentinzhang.github.io/oneact/) · [下载与版本说明](https://github.com/quentinzhang/oneact/releases/latest) · [反馈问题](https://github.com/quentinzhang/oneact/issues) · [GPL-3.0](LICENSE)

![OneAct 真实 Camera 界面，画布内为暖色场景和虚构插画人物](website/assets/demo-camera.png)

*截图中的画布为示例场景，人物是插画，不使用真人影像。*

### 三种录制场景

| Camera | Screen + Camera | 开启提词器 |
| --- | --- | --- |
| [![Camera 模式](website/assets/demo-camera.png)](website/assets/demo-camera.png) | [![屏幕与摄像头模式](website/assets/hero-demo.png)](website/assets/hero-demo.png) | [![开启提词器](website/assets/demo-teleprompter.png)](website/assets/demo-teleprompter.png) |
| 一段心里话、一堂课、一个值得分享的想法。 | 当表达需要演示时，把屏幕带进画面。 | 把下一句放在眼前，稿件不进入成片。 |

[在主页切换查看三种场景](https://quentinzhang.github.io/oneact/#demo)。提词器可以配合 Camera 或 Screen + Camera 使用。

## 功能

- **暂停一下，从容继续**：暂停与继续始终保留在同一次录制中，暂停时间不进入成片。暂停时可重新构图、在 Camera 与 Screen + Camera 之间切换，再接着讲下去；也可使用全局快捷键控制。
- **所拍即所得**：画布实时合成，构图、背景与摄像头位置直接成为成片的一部分。
- **把下一句放在眼前**：内置提词器支持中英文语速和录制前倒计时，随录制一起暂停、继续；稿件留在画布上方，不进入视频。
- **需要演示时，再分享屏幕**：把显示器、应用或窗口带进教程、演示和产品讲解中，可按需叠加摄像头画面。
- **让画面有你的样子**：横屏、竖屏和方形画布，Fit / Fill / Blur 布局，可拖动画中画、人物抠像、自选底色与软件缩放。
- **把声音一起录好**：选择麦克风，可加入系统声音，也可单独录制电脑声音。
- **为下一步准备好文件**：输出 `.mov` 与 AAC 音轨；日常分享可选 H.264，后续剪辑可选 ProRes 422。
- **在自己的 Mac 上完成**：无需账号；录制、脚本与人物分割均在本机处理。版本检查会连接 GitHub。

## 下载与安装

需要 **Apple Silicon Mac、macOS 15 或更新版本**。当前提供测试版本；Intel Mac 尚未验证。

1. 从 [GitHub Releases](https://github.com/quentinzhang/oneact/releases/latest) 下载 `OneAct-macOS-arm64.zip`。
2. 解压，将 `OneAct.app` 拖入“应用程序”，然后打开。
3. 根据提示允许摄像头、麦克风和屏幕录制权限。

[v0.41 发布版](https://github.com/quentinzhang/oneact/releases/tag/v0.41) 已完成 **Developer ID 签名与 Apple 公证**。各版本的签名状态以对应发布说明为准。

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
