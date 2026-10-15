# HanYayaya.github.io

基于 Hugo 的个人博客，通过 GitHub Actions 自动部署到 GitHub Pages。

## 本地预览

需要 Hugo Extended 0.168.0：

```powershell
hugo server -D
```

访问 `http://localhost:1313/`。

## 新建文章

```powershell
hugo new content posts/my-article/index.md
```

推送到 `main` 分支后，GitHub Actions 会自动构建并发布站点。

## 从 Obsidian 发布

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
