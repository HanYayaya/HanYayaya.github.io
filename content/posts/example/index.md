---
title: "Hugo 主题综合测试文章"
slug: "example"
date: 2026-10-14T12:00:00+08:00
lastmod: 2026-10-15T12:00:00+08:00
description: "用于验证 Hugo 部署链路、文章排版和未来主题组件的综合测试文章。"
categories:
  - 技术
tags:
  - Hugo
  - GitHub Pages
  - 主题开发
cover: "cover.svg"
draft: false
toc: true
---

这是一篇用于开发博客主题的综合测试文章。它会保留在项目中，帮助我们在每次调整样式后快速检查排版是否发生回归。

{{< notice type="info" title="测试说明" >}}
当前页面首先验证 Hugo 的内容渲染和 GitHub Pages 部署。视觉设计会在部署链路跑通之后逐步替换。
{{< /notice >}}

## 基础文字排版

这是一段中英文混排文本：Hugo is a fast static site generator。这里包含 **粗体文字**、*斜体文字*、~~删除线~~、`inline code`，以及一个指向 [Hugo 官方网站](https://gohugo.io/) 的外部链接。

> 写作系统最重要的不是功能数量，而是让作者能够长期、稳定、低摩擦地持续输出。

### 列表

无序列表：

- 第一项内容
- 第二项内容
  - 二级嵌套项目
  - 另一个嵌套项目
- 第三项内容

有序列表：

1. 编写 Markdown
2. 提交到 Git
3. GitHub Actions 自动构建
4. GitHub Pages 自动发布

任务列表：

- [x] 创建 GitHub 仓库
- [x] 初始化 Hugo 项目
- [ ] 完成专属主题

## 代码块

```go {linenos=table,hl_lines=[4]}
package main

import "fmt"

func main() {
	fmt.Println("Hello, Hugo!")
}
```

```javascript
const site = {
  generator: "Hugo",
  hosting: "GitHub Pages",
  ready: true,
};
```

## 表格

| 项目 | 方案 | 状态 |
| --- | --- | --- |
| 静态生成器 | Hugo Extended | 已确定 |
| 部署平台 | GitHub Pages | 测试中 |
| 自动化 | GitHub Actions | 测试中 |
| 主题 | 专属 Hugo Theme | 待开发 |

## 图片

![用于测试宽图、圆角和说明文字的示意封面](cover.svg "主题开发测试封面")

图片应当在桌面端和移动端自适应容器宽度，不能产生横向滚动。

## 折叠内容

<details>
  <summary>点击展开测试内容</summary>

这里用于测试原生 `details` 元素在深色主题中的表现。

</details>

## 脚注与分割线

Hugo 使用 Goldmark 渲染 Markdown。[^goldmark]

[^goldmark]: Goldmark 是 Hugo 默认使用的 Markdown 解析器。

---

如果你能在线看到这段文字，说明从 Markdown、Hugo 构建、GitHub Actions 到 GitHub Pages 的最小发布链路已经工作。
