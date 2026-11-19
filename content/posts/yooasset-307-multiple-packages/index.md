---
title: "7. 多 Package 与关卡资源管理"
slug: yooasset-307-multiple-packages
date: 2026-11-19
lastmod: 2026-11-19
description: "比较标签分包和独立 Package，说明版本组合、跨包依赖与关卡生命周期。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 7
draft: true
toc: true
---

首包和后续下载可以在一个 Package 中通过标签区分，也可以把公共内容和各关卡组织成不同 Package。二者都能控制交付范围，但独立版本、依赖解析和生命周期边界并不相同。

<details>
<summary>YooAsset 3.0.7 源码阅读 · 系列目录</summary>

1. [从全局入口到 Package 初始化](/posts/yooasset-307-initialization/)
2. [文件系统、沙盒缓存与内置资源](/posts/yooasset-307-filesystems/)
3. [资源版本、清单与首包交付](/posts/yooasset-307-version-and-delivery/)
4. [ResourcePackage 与资源描述结构](/posts/yooasset-307-resource-model/)
5. [Provider、Handle 与 Bundle 加载复用](/posts/yooasset-307-loading/)
6. [引用计数、实例与资源卸载](/posts/yooasset-307-lifetime/)
7. [多 Package 与关卡资源管理](/posts/yooasset-307-multiple-packages/)
8. [SpriteAtlas 的构建、加载与生命周期](/posts/yooasset-307-sprite-atlas/)

</details>

> 版本基线：当前仓库包版本为 **3.0.7**，源码对照提交为 [`8cb910de8990`](https://github.com/tuyoogame/YooAsset/tree/8cb910de899050d95b01644e7a3bd7a643f226c0)。调用链与配置按此快照解释；未标注为完整脚本的代码块为源码摘录或使用片段。

## 先区分标签分组与 Package 分组 {#boundaries}

| 维度 | 单 Package 配合标签 | 多 Package |
| --- | --- | --- |
| Manifest | 同一份当前清单 | 各自加载、激活 |
| 资源版本 | 同一个 PackageVersion | 每包独立选择 |
| 地址命名空间 | 同一个 Package 内 | 每包独立 |
| ResourceManager | 共用 | 每包独立 |
| 默认缓存根目录 | 同一个 PackageRoot | 按 Package 分开 |
| 下载范围 | 标签、资源信息或全包 | 每包创建自己的下载器 |

如果需求只是“进入哪关下载哪关”，标签已经能够完成。如果还需要独立发布、独立资源版本或 DLC 管理，多个 Package 才能提供更明确的边界。

## 公共包与关卡包的结构 {#package-layout}

```text
YooAssets
├─ DefaultPackage：公共 UI、公共配置等
├─ Level01Package：第一关内容
└─ Level02Package：第二关内容
```

DefaultPackage 只是名称，不会自动成为其他 Package 的父包。每个包都有自己的 ResourceManager、FileSystemHost 和 ActiveManifest，公共内容要由业务明确管理。

公共包适合启动时准备并保留；关卡包可以在进入前初始化、下载，离开后释放。无需在启动时扫描和初始化所有关卡包。

## 业务管理器负责准备状态 {#manager}

可以设计业务方法 `EnsurePackageReady(packageName, version)`，它不是框架现成 API，而是统一封装：

```text
取得或创建 Package
    → 等待或发起初始化
    → 激活指定版本清单
    → 按业务需要下载缺失文件
    → 返回可用于加载的 Package
```

管理器应记录阶段、错误和当前目标版本，合并同一包的并发请求。TryGetPackage 成功只表示对象已登记，不代表初始化、清单加载、预下载都成功。

正在使用的包切换版本需要协调旧句柄与加载器。不要在同一个共享实例上让两个请求各自把 Manifest 切到不同版本。

## 显式指定包与地址 {#loading}

以下片段假设两个 Package 已就绪：

```csharp
var common = YooAssets.GetPackage("DefaultPackage");
var level = YooAssets.GetPackage("Level01Package");

var hudHandle = common.LoadAssetAsync<GameObject>("BattleHUD");
var enemyHandle = level.LoadAssetAsync<GameObject>("Enemy");
var sceneHandle = level.LoadSceneAsync(
    "LevelScene", UnityEngine.SceneManagement.LoadSceneMode.Additive);
```

这里使用 PackageName 与 Address 共同定位资源。不同关卡包可以各有一个 LevelScene 地址，业务不应遍历所有 Package 猜测归属。需要统一入口时，包装 `LoadAsset(packageName, address)` 即可。

进入关卡前创建该包的全量下载器，也只会计算本包清单的资源，不会隐式下载公共包：

```csharp
var downloader = level.CreateResourceDownloader(
    new ResourceDownloaderOptions(10, 3));
```

公共包与关卡包都需要由业务纳入准备流程，检查成功后再进入场景。

## 跨 Package 依赖不是自动解析的 {#cross-package}

假设关卡 Prefab 在 Inspector 中直接引用公共材质，而材质又被配置到 DefaultPackage。不能据此认为关卡包加载时会自动去 DefaultPackage 取材质。

当前 FileSystemHost 查询依赖时使用本包 ActiveManifest，DependentBundleIDs 也只在这份清单内有意义。独立构建可能把共享引用的数据重复打入不同 Package；提前加载公共包并不会自动重写其他包中的序列化引用。

对大量共享且直接引用的内容，单 Package 配合标签通常更容易组织依赖。采用多包方案时，可以由业务通过 ID 或地址加载公共 Prefab、图集等，再组合到关卡对象上。是否存在重复 Bundle、纹理或材质，要以真实构建与内存结果核对。

默认的缓存根目录也按包分开，不要假设跨包哈希相同就自动共享同一份磁盘缓存。

## 独立版本与发布组合 {#versions}

CDN 可按平台、包名、资源版本分层：

```text
CDN/Android/
├─ DefaultPackage/
│  ├─ DefaultPackage.version
│  └─ v5/...
├─ Level01Package/
│  ├─ Level01Package.version
│  └─ v3/...
└─ Level02Package/
   ├─ Level02Package.version
   └─ v1/...
```

每包应有独立的 RemoteService 路由状态，避免共享可变的目标版本字段。存在兼容要求时，发布配置明确指定一组版本，比所有包分别请求“当前版本”更容易得到经过验证的组合：

```text
本次发布
DefaultPackage = v5
Level01Package = v3
Level02Package = v1
```

这是业务发布策略，YooAsset 的 PackageVersion 本身不表达跨包兼容矩阵。

## 离开关卡怎样处理 {#leave-level}

先切换或卸载关卡场景，结束实例和其他对象对关卡内容的使用，再释放资源句柄、清理未使用资源。决定完全移除 Package 时，等待 DestroyPackageAsync 成功后调用 YooAssets.RemovePackage。

保留已初始化的 Package 可以减少下一次进入时的初始化成本，但清单、索引等也继续占用内存；销毁运行时对象仍可以保留磁盘缓存，供下次使用。公共包只要还有公共 UI、角色或其他对象使用，就应继续保持有效的引用关系。

## 源码阅读入口 {#source}

- [YooAssets.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/YooAssets.cs)：Package 注册、查找和移除。
- [FileSystemHost.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/FileSystemHost.cs)：本包依赖解析与下载器创建。
- [DownloaderOptions.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/DownloaderOptions.cs)：按包、标签和资源选择下载范围。
- [SceneHandle.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Handles/SceneHandle.cs)：场景卸载入口。
- [DestroyPackageOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/DestroyPackageOperation.cs)：销毁顺序。
