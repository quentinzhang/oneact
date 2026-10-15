# GitHub 发布指南

- 源码：<https://github.com/quentinzhang/oneact>
- 主页：<https://quentinzhang.github.io/oneact/>
- 固定下载入口：<https://github.com/quentinzhang/oneact/releases/latest/download/OneAct-macOS-arm64.zip>

## 首次配置

公开仓库默认分支为 `main`。在 Settings → Pages → Build and deployment 选择 **GitHub Actions**。`.github/workflows/pages.yml` 发布主页，`ci.yml` 在 macOS 上构建和运行自测。

`release.yml` 可手动运行，构建并发布当前 `main` 版本。默认产物为 **ad-hoc 签名、未公证测试包**，Release 与官网会明确显示这一状态。无需在 GitHub 保存 Apple 凭据。

## 本地准备

1. 更新 `Info.plist` 中版本号和递增 build，补充 `CHANGELOG.md`。
2. 运行两种格式的自测，检查真实设备录制、权限和声音。
3. 提交并推送 `main`。发布脚本要求工作区干净，且本地 HEAD 与远端 `main` 完全一致，确保二进制对应公开源码。
4. 运行：

```bash
./scripts/release.sh "本次版本说明"
```

产物位于 `build/releases/v<版本>/`：

- `OneAct-macOS-arm64.zip`：可直接解压的 `.app`，内含 GPL 许可证。
- `SHA256SUMS`：安装包校验和。
- `appcast.json`：版本、固定版本下载地址、校验和与公证状态。
- `release-notes.md`：发布说明，含同一 tag 的源码链接。

默认只打包，不修改官网、不上传、不创建 Git tag。当前公开安装包仅支持 arm64，发布脚本会拒绝其他架构。

## 正式签名与 Apple 公证

本地钥匙串须有有效 Developer ID Application 证书，并已通过 `xcrun notarytool store-credentials` 保存公证凭据。用自己的证书名称与 profile 替换示例：

先运行 `security find-identity -v -p codesigning`，确认存在有效 Developer ID Application 身份。仅安装 `.cer` 证书不够；签名还需要对应的私钥。迁移已有证书时，在本机“钥匙串访问”导入包含私钥的 `.p12`，密码只在本机输入。

尚未保存公证凭据时，在本机终端运行以下命令，按照交互提示输入 Apple ID、Team ID 与 App 专用密码；不要把密码写进脚本、命令参数、聊天或仓库：

```bash
xcrun notarytool store-credentials oneact-notary
```

也可使用已保存的 App Store Connect API profile；仅需把 profile 名称传给发布脚本。

```bash
CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
NOTARY_PROFILE="your-notary-profile" \
./scripts/release.sh "本次版本说明"
```

脚本保存公证提交结果与日志，要求结果为 Accepted，然后 staple、验证票据并检查 Gatekeeper，最后重新生成 zip。公证失败就停止；不会把失败结果标记为已公证。不要把证书、密码或私钥提交到仓库。提交结果和日志只保留在被忽略的本地 `build/releases/` 目录。

## 发布到 GitHub

确认已用 `gh auth login` 登录，然后运行：

```bash
./scripts/release.sh --publish "本次版本说明"
```

脚本会创建新 tag 和草稿 Release，上传三个发布资产后再公开 Release，并触发 Pages 更新。同一版本已存在时会停止，不覆盖用户已下载的文件。公开 Release 成功后若 Pages 触发失败，可单独在 Actions 运行 **GitHub Pages**，无需重新发布版本。

也可在 GitHub Actions 手动运行 **Release**。此方式默认使用未公证测试包；需要公证时请走上面的本地发布方式。`GITHUB_TOKEN` 需要 `contents: write` 和 `actions: write`，Pages 工作流使用独立的最小权限。

公开后检查主页、安装包及校验和可访问，且应用的 Check for Updates… 能读到相同版本。GitHub Releases 同时保留对应 tag 的源码，方便按 GPL 获取该二进制的完整对应源码。

## 旧版本迁移

v0.39 及更早的本地安装包仍读取旧域名的更新源。首次升级到 v0.40 或更新版本需手动从 GitHub 下载；升级后使用 GitHub Pages 更新源。
