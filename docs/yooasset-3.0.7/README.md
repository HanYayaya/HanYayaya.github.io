# YooAsset 3.0.7 源码阅读：草稿与校验入口

分类路径：`Unity/YooAsset/YooAsset 3.0.7 源码阅读`。按现有 xLua 系列格式组织八篇草稿，使用相同的分类树、series、series_order、折叠目录及主题页脚导航。所有文章为 `draft: true`，本轮不提交、不推送、不发布。

## 系列文章

1. [从全局入口到 Package 初始化](../../content/posts/yooasset-307-initialization/index.md)
2. [文件系统、沙盒缓存与内置资源](../../content/posts/yooasset-307-filesystems/index.md)
3. [资源版本、清单与首包交付](../../content/posts/yooasset-307-version-and-delivery/index.md)
4. [ResourcePackage 与资源描述结构](../../content/posts/yooasset-307-resource-model/index.md)
5. [Provider、Handle 与 Bundle 加载复用](../../content/posts/yooasset-307-loading/index.md)
6. [引用计数、实例与资源卸载](../../content/posts/yooasset-307-lifetime/index.md)
7. [多 Package 与关卡资源管理](../../content/posts/yooasset-307-multiple-packages/index.md)
8. [SpriteAtlas 的构建、加载与生命周期](../../content/posts/yooasset-307-sprite-atlas/index.md)

## 来源与范围

- 内容来自本次 YooAsset 学习讨论，重新组织为可独立阅读的文章，未照搬对话中的提问和重复确认。
- 源码工作区：`E:/Project/YooAsset`；package.json 版本 3.0.7；固定提交 `8cb910de899050d95b01644e7a3bd7a643f226c0`。
- 工程标注 Unity 2022.3.62f2，包最低 Unity 要求与具体项目编辑器版本不混用。
- 文章源码链接指向固定提交，生成前检查所引用文件在当前仓库存在。没有声称对所有平台、Unity 版本执行过运行测试。
- 现有源码仓库的 Packages 配置、Resources 和 .idea 本地修改不属于本次文稿修改。

## 本轮重点纠正与统一

- BundleID 是清单索引；BundleGuid 为 FileHash；Loader 复用键为 Package 内的 BundleName。
- Sandbox __info 不保存 GUID，默认 Low 不重算文件哈希；高等级检查 CRC。
- 内置 Catalog 登记原件，解包缓存与下载缓存分别扫描自己的目录。
- Package 初始化、目标版本选择、Manifest 激活、预下载及对象加载是独立阶段。
- .version 表达发布选择，不保证最大版本；本地文件存在仅表示已有目标缓存。
- 首包是完整构建结果的副本子集，CDN 发布可以保留全部 Bundle。
- Handle 释放、Provider 销毁、Loader 移除、磁盘缓存淘汰分别解释。
- Atlas 章节区分源码已证实行为、Unity API 使用语义和待进行的真实构建实验。

## 后续可扩展主题

本轮覆盖已经讨论的核心链路。后续可独立扩展下载调度与断点续传、构建收集和共享依赖、异步状态机深入分析、失败恢复与诊断工具等内容，不提前填充未经核对的结论。

## 校验

构建命令、生成页检查与统计结果见同目录 `validation.json`。Markdown 片段不作为独立 C# 项目编译；Hugo 构建不等于 Unity 运行验证。
