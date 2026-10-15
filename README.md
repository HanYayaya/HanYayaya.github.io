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
