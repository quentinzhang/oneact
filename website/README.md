# OneAct 项目主页

线上地址：<https://quentinzhang.github.io/oneact/>。

此目录为纯静态站点源码。GitHub Actions 仅发布 `index.html`、`assets/` 与生成的 `appcast.json`，不发布开发文档或安装包。安装包单独放在 GitHub Releases。

主页的版本号、下载链接、公证状态来自 `appcast.json`。Pages 构建只从最新已发布 Release 下载该文件，因此尚未发布的源码版本不会让用户收到无效更新。没有 Release 时，首页保留 GitHub Releases 入口，不显示虚构的版本号。

本地预览源码：

```bash
python3 -m http.server 8787 --directory website
```

本地构建与线上相同的站点（需要网络访问 GitHub）：

```bash
python3 scripts/build-website.py --output build/site
python3 -m http.server 8787 --directory build/site
```

应用更新源在 `Info.plist` 与 `Sources/OneAct/UpdateChecker.swift` 中。发布步骤见 [发布指南](../docs/RELEASING.md)。
