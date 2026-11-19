---
title: "8. SpriteAtlas 的构建、加载与生命周期"
slug: yooasset-307-sprite-atlas
date: 2026-11-19
lastmod: 2026-11-19
description: "连接 Unity 图集打包、YooAsset 构建依赖、显式加载、延迟绑定和释放。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 8
draft: true
toc: true
---

SpriteAtlas 同时涉及 Unity 导入、图集纹理生成、构建依赖、运行时绑定和资源引用。本文分别说明 Unity 与 YooAsset 的职责，并对照仓库示例解释显式加载和延迟绑定两种使用方式。

<details>
<summary>YooAsset 3.0.7 源码阅读 · 系列目录</summary>

1. [整体架构与初始化流程](/posts/yooasset-307-initialization/)
2. [文件系统、沙盒缓存与内置资源](/posts/yooasset-307-filesystems/)
3. [资源版本、清单与首包交付](/posts/yooasset-307-version-and-delivery/)
4. [ResourcePackage 与资源描述结构](/posts/yooasset-307-resource-model/)
5. [Provider、Handle 与 Bundle 加载复用](/posts/yooasset-307-loading/)
6. [引用计数、实例与资源卸载](/posts/yooasset-307-lifetime/)
7. [多 Package 与关卡资源管理](/posts/yooasset-307-multiple-packages/)
8. [SpriteAtlas 的构建、加载与生命周期](/posts/yooasset-307-sprite-atlas/)

</details>

> 版本基线：当前仓库包版本为 **3.0.7**，源码对照提交为 [`8cb910de8990`](https://github.com/tuyoogame/YooAsset/tree/8cb910de899050d95b01644e7a3bd7a643f226c0)。调用链与配置按此快照解释；未标注为完整脚本的代码块为源码摘录或使用片段。

## 从源图片到 SpriteAtlas {#asset-model}

以背包图标为例：

```text
Sword.png、Shield.png、Potion.png
    → Unity 导入生成 Sprite 对象
    → Inventory.spriteatlas 收集这些 Sprite
    → 打包生成一张或多张图集纹理及相关数据
```

Sprite 不只是像素，还描述关联纹理、区域、UV、Pivot、Border 和几何信息等。SpriteAtlas 资产描述收集对象及打包、纹理设置；构建产物中的图集数据由 Unity 处理，不是把工程 PNG 原文件直接改名合并。

一张 Multiple 模式图片产生多个 Sprite 子资源，与多个源 Sprite 被收进 SpriteAtlas 是两个概念。前者可以通过 LoadSubAssets 获取，后者通常加载 SpriteAtlas 后调用 GetSprite，或通过 Unity 的绑定机制使用。

一个 Atlas 不保证只包含一张纹理页，也不保证其中所有 UI 一定合批。材质、Canvas、遮罩和绘制顺序等仍然影响渲染。取一个小图标可能涉及较大的图集页，因此按共同使用生命周期划分图集，比单纯追求一个大图集更容易控制内存。

## Prefab 的 Sprite 引用与 Atlas 关系 {#sprite-reference}

在 Image 上拖入 Sword 后，序列化关系是 Prefab 的 Image 引用 Sprite。Atlas 的收集列表包含该 Sprite，是另一层关系。不能把这两条关系直接视为普通字段上的 `Prefab → SpriteAtlas` 强引用。

Unity 会在导入、构建和运行时绑定中处理图集关联，行为受 Unity 版本、Atlas 配置和构建管线影响。本文仓库工程标注 Unity 2022.3.62f2；下文对 Unity API 的说明是使用层语义，不代表已经对所有 Atlas 版本和平台执行同一组实验。

## Unity 打图集与 YooAsset 打 Bundle {#build}

两层构建职责分别是：

| 层次 | 工作 |
| --- | --- |
| Unity 图集系统 | 排列 Sprite 像素、生成图集纹理和绑定所需数据 |
| YooAsset 收集与打包规则 | 组织资源进入 Bundle，调用 Unity 管线，生成清单及依赖 |

当前 SBP 任务包含 `RebuildSpriteAtlasCache`。图集对象、纹理页及引用数据实际落在哪些 Bundle，需要查看构建结果，不能仅从工程目录推断。

`ScriptableBuildParameters.TrackSpriteAtlasDependencies` 默认 false。启用且满足相应构建条件时，TaskCreateManifest 会根据构建图中的引用关系，补充资源对 Atlas Bundle 的依赖，并传播标签。它处理清单中的依赖记录，不负责图集像素打包，也不是 atlasRequested 的运行时开关。

仓库还提供 UIPanelMonitor 示例，在编辑器保存 Prefab 时为 PanelManifest 填入显式的图集引用列表。这是基于目录约定的示例方案，需要按项目资源布局适配。

## 显式加载 Atlas，再取 Sprite {#explicit-load}

适合运行时按配置显示物品、头像、商店图标。以下片段假设 package 和 image 已准备好：

```csharp
var handle = package.LoadAssetAsync<SpriteAtlas>("InventoryAtlas");
yield return handle;
if (handle.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(handle.Error);
    handle.Release();
    yield break;
}
var atlas = handle.AssetObject as SpriteAtlas;
Sprite sword = atlas.GetSprite("Sword");
image.sprite = sword;
// 所有使用者结束使用之前，继续持有 handle。
```

完整路径为：

```text
YooAsset Address
    → Manifest 定位 Atlas 所属 Bundle 与依赖
    → 文件获取与 Bundle 加载
    → LoadAssetAsync<SpriteAtlas>
    → Unity SpriteAtlas.GetSprite(name)
```

InventoryAtlas 是资源地址，Sword 是 Atlas 内部 Sprite 名称。GetSprite 不会再创建一个 YooAsset Provider，也不会单独触发 Bundle 下载。

Unity 文档说明 GetSprite 返回 Sprite 克隆。它与图集纹理的资源关系仍需管理，反复调用也可能产生多个 Sprite 对象。图标服务可以缓存自己创建的克隆，并明确其所有权。

## 延迟绑定：让 Unity 请求图集 {#late-binding}

对于 Prefab 已经配置 Sprite 的 UI，可以由 Unity 使用已有图集；需要延迟提供图集时，通过 `SpriteAtlasManager.atlasRequested` 接收请求。

```text
Unity 请求 Atlas tag
    → 业务映射到 PackageName 与 Address
    → YooAsset 加载 SpriteAtlas
    → 调用请求提供的 callback(atlas)
    → Unity 完成图集注册、绑定
```

仓库 SpriteAtlasLoader 示例注册事件后，固定从 DefaultPackage 同步加载图集，将图集对象缓存在字典中，保留加载 Handle，并回调 Unity。组件销毁时注销事件、释放句柄。

示例把请求标识直接当作 YooAsset 地址，这是约定，不是两者天然相同。实际项目可以维护 `Atlas tag → PackageName + Address` 映射，并改为异步加载、合并进行中的请求。

尤其是需要网络下载的图集，应提前准备或异步提供，不宜把同步示例直接作为生产网络加载方案。错误、组件退出、迟到回调和使用者计数都需要业务图集管理器处理。

## Include in Build 与首包标签 {#include-in-build}

Unity 的 Include in Build 控制图集的自动包含、可用性相关行为；YooAsset 首包标签决定哪些构建 Bundle 复制到 StreamingAssets。二者不是同一个选项。

Unity 文档中的延迟绑定流程涉及取消图集自动包含，再由 AssetBundle 等渠道提供。项目应结合所使用的 SpriteAtlas 版本和构建管线验证，不能仅凭一个勾选项推导最终 Bundle 依赖或安装包内容。

## 图集的释放边界 {#lifetime}

调用 GetSprite 不会增加 YooAsset Handle 引用计数。一个背包模块可以持有一份 Atlas Handle，并管理自己取得的 Sprite 克隆：

```text
停止所有 UI 对这些 Sprite 的使用
    → 销毁本模块拥有的 Sprite 克隆
    → 释放 Atlas Handle
    → 按策略清理不再使用的 Bundle
```

通过 Prefab 引用、Unity 绑定得到的共享 Sprite，不能当成自己 GetSprite 创建的克隆随意 Destroy。延迟绑定管理器也不能只根据某个面板关闭就释放图集，其他场景或 UI 可能仍使用它。

Atlas 中的 Sprite 使用关系不会自动转换为业务图集服务的计数；Prefab 依赖 Provider 的引用与显式加载 Atlas 的 Handle 也需要按实际构建、加载路径分析。

## 验证时观察哪些结果 {#verification}

真实项目建议分别验证以下场景，而不是只看模拟模式能否显示：

| 场景 | 观察内容 |
| --- | --- |
| 显式加载 Atlas 后 GetSprite | 对象是否返回、纹理页是否符合预期 |
| 加载直接引用 Sprite 的 Prefab | 是否触发 Atlas 请求、依赖 Bundle 是否齐全 |
| 清空下载缓存后首次进入 UI | 网络加载期间的占位、失败和恢复 |
| 两个面板共用图集，关闭其中一个 | 剩余面板是否仍可显示 |
| 全部使用结束后卸载，再重新打开 | 引用释放、重复加载与克隆数量 |

本文依据源码梳理行为，未将这些运行实验标记为已执行。后续可以据构建报告、Frame Debugger 与内存采样补充案例。

## 源码与 Unity 文档入口 {#source}

- [SpriteAtlasLoader.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Samples~/Extension/Runtime/SpriteAtlasLoader/SpriteAtlasLoader.cs)
- [TestLoadSpriteAtlas.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Samples~/Tests/Runtime/CommonTests/TestLoadSpriteAtlas.cs)
- [ScriptableBuildTasks.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Editor/BundleBuilder/BuildPipeline/ScriptableBuildPipeline/ScriptableBuildTasks.cs)
- [TaskCreateManifest.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Editor/BundleBuilder/BuildTasks/TaskCreateManifest.cs)
- [UIPanelMonitor.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Samples~/Extension/Runtime/UIPanelMonitor/UIPanelMonitor.cs)
- [Unity 2022.3：SpriteAtlas.GetSprite](https://docs.unity3d.com/2022.3/Documentation/ScriptReference/U2D.SpriteAtlas.GetSprite.html)
- [Unity 2022.3：SpriteAtlasManager.atlasRequested](https://docs.unity3d.com/2022.3/Documentation/ScriptReference/U2D.SpriteAtlasManager-atlasRequested.html)
- [Unity 2022.3：Sprite Atlas late binding](https://docs.unity3d.com/2022.3/Documentation/Manual/SpriteAtlasDistribution.html)
