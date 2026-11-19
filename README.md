# HanYayaya.github.io

基于 Hugo 的个人博客，通过 GitHub Actions 自动部署到 GitHub Pages。

## 本地预览

博客已经包含站点配置和主题，无须重新初始化。预览需要 Hugo Extended 0.168.0，`-D` 用于包含草稿。

仓库已随附 Windows amd64 版 Hugo Extended 0.168.0 及其许可文件。Windows 用户克隆仓库后，可以直接在仓库根目录执行：

```powershell
.\.tools\hugo\0.168.0\hugo.exe server -D
```

其他系统需要从 [Hugo 官方发行页](https://github.com/gohugoio/hugo/releases/tag/v0.168.0) 安装对应平台的 **Extended 0.168.0**。如果 Hugo 已加入系统 `PATH`，也可以使用：

```powershell
hugo server -D
```

访问 `http://localhost:1313/`。

命令运行期间保持终端打开，修改文章后预览会自动更新；按 `Ctrl+C` 停止预览。程序产生的本地缓存和日志不会提交到仓库。

## 工具与生成文件的提交范围

`.tools/` 仅放行下表列出的固定版本程序和许可文件，其余内容继续由 `.gitignore` 忽略。

| 内容 | 是否提交 |
| --- | --- |
| `.tools/hugo/0.168.0/hugo.exe`、同目录的 `LICENSE` | 提交，Windows 克隆后可直接预览，并随附上游许可 |
| Hugo 下载压缩包、发行包校验清单、其他版本目录 | 忽略，避免重复保存下载产物 |
| `.tools/hugo-cache/`、各个预览构建目录、截图、日志和 PID 文件 | 忽略，均为本地缓存或检查产物 |
| `public/`、`resources/_gen/`、`.hugo_build.lock` | 忽略，由 Hugo 自动生成 |
| `content/`、`static/`、主题模板、CSS、JavaScript、文档和 `publish.ps1` | 提交，属于博客源码或必要资源 |
| `hugo.yaml`、`.github/workflows/deploy.yml`、`.gitignore` | 提交，保存站点配置、Hugo 版本和构建方式 |

`themes/han-theme/assets/css/chroma.css` 虽然由 Hugo 生成，但它是主题直接依赖的高亮样式，因此需要提交。以后新增可复用的安装或预览脚本，放在仓库的 `scripts/` 中提交。

随附程序来自 Hugo 官方 `hugo_extended_0.168.0_windows-amd64.zip`，未经修改。`hugo.exe` 的 SHA-256 为 `dc793d3e3722f9d233f7f9345a19a86bc6152f078bf0e13ad67623c987160710`。升级时需要同步更新程序、许可文件、`.gitignore` 中的版本路径和部署配置中的 Hugo 版本。

GitHub Actions 会根据部署配置独立安装 Hugo，部署不依赖本机的 `.tools`。正式构建默认跳过 `draft: true` 的文章；本地使用 `-D` 才会显示草稿。

## 新建文章

```powershell
hugo new content posts/my-article/index.md
```

推送到 `main` 分支后，GitHub Actions 会自动构建并发布站点。

## 从 Obsidian 发布

分类支持用 `/` 表示层级，例如 `categories: ["Lua/XLua/Xlua源码阅读 (2.1.16)"]`。左侧会逐级展开；同一分类内的文章都设置 `series_order` 时按该编号排列，否则按发布日期倒序排列。首页文章流仍按发布日期倒序显示。

同一系列的文章设置相同的 `series` 和递增的 `series_order`，主题会在正文末尾自动生成左侧上一篇、右侧下一篇的导航，无须在 Markdown 中手写链接。

仓库根目录提供 `publish.ps1`。它会将 Obsidian Markdown 导入为 Hugo Page Bundle、复制本地图片、转换 `![[image.png]]` 图片语法，并执行 Hugo 构建验证。

准备文章并验证构建：

```powershell
.\publish.ps1 `
  -Source "D:\Obsidian\博客\我的文章.md" `
  -Slug "my-article" `
  -HugoPath "C:\path\to\hugo.exe"
```

启动本地预览：

```powershell
.\publish.ps1 `
  -Source "D:\Obsidian\博客\我的文章.md" `
  -Slug "my-article" `
  -HugoPath "C:\path\to\hugo.exe" `
  -Force `
  -Preview
```

确认后提交并推送：

```powershell
.\publish.ps1 `
  -Source "D:\Obsidian\博客\我的文章.md" `
  -Slug "my-article" `
  -HugoPath "C:\path\to\hugo.exe" `
  -Force `
  -Push
```

也可以将 Hugo 路径保存到当前终端环境变量，之后省略 `-HugoPath`：

```powershell
$env:HUGO_PATH = "C:\path\to\hugo.exe"
```

常用可选参数包括 `-Title`、`-Description`、`-Category`、`-Tags`、`-Cover` 和 `-CommitMessage`。如果源文件没有 Front Matter，脚本会自动生成；目标文章已存在时必须显式添加 `-Force`。
