---
title: "6. 引用计数、实例与资源卸载"
slug: yooasset-307-lifetime
date: 2026-11-19
lastmod: 2026-11-19
description: "分析 Handle、Provider 和 Loader 的引用链，以及自动卸载和主动清理策略。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 6
draft: true
toc: true
---

一个 Handle 被释放之后，Provider、Bundle Loader 和 Unity 对象是否立即消失？答案取决于两层引用计数、正在执行的加载和卸载策略。本文先还原计数关系，再讨论 UI、实例和对象池如何持有资源。

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

## 两层引用计数 {#reference-chain}

```text
业务持有的 Handle
    → Provider.RefCount
    → Provider 持有主 Bundle 与依赖 Bundle Loader
    → LoadBundleOperation.RefCount
    → 底层 BundleHandle
```

Provider.CreateHandle 为每次请求增加 Provider.RefCount；Handle.Release 调用 Provider.ReleaseHandle 减少它。创建一个 Provider 时，它对所有需要的 Bundle Loader 增加引用；销毁 Provider 时，才对这些 Loader 释放引用。

因此“Handle 减一”与“Loader 减一”不是同一个动作。一个 Provider 可以有多个 Handle，但通常只代表对某个相关 Loader 的一份 Provider 使用引用。

## Release 实际执行什么 {#release-handle}

HandleBase.Release 的核心逻辑：

```csharp
Provider.ReleaseHandle(this);
if (Provider.RefCount == 0)
    Provider.TryUnloadBundle();
Provider = null;
```

Provider.TryUnloadBundle 又会检查 `AutoUnloadBundleWhenUnused`，开启时才进入针对资源的卸载尝试。Release 的含义是调用者结束这份使用关系，不保证当场释放 Unity 对象。

两个 Handle 指向一个 Provider 时，释放其中一个仍然保留另一个引用。Handle 失效后也不应继续通过它访问结果。

## Loader 从字典移除的顺序 {#destroy-loader}

常规未使用资源清理进入 ResourceManager.DestroyUnusedBundle：

```text
尝试销毁无人使用且不在加载的 Provider
    ↓
Provider.DestroyProvider 释放相关 Loader 引用
    ↓
遍历 Loader，判断 CanDestroyLoader
    ↓
DestroyLoader
    ↓
_bundleLoaderDict.Remove(BundleName)
```

Provider.CanDestroyProvider 检查其引用计数及加载状态。Loader.IsReleasable 要求无正引用且不在 LoadBundleFile 阶段；CanDestroyLoader 还检查反向 Bundle 依赖。默认编译分支要求相关引用方已销毁，实验分支有不同检查，不能简化成只看一个整数。

复杂依赖链可能需要多轮清理。UnloadUnusedAssetsOperation 根据 MaxLoopCount 和时间片推进，依次移除能够释放的对象。

普通 AssetBundleHandle.UnloadBundle 最终调用：

```csharp
_assetBundle.Unload(true);
```

这会影响从 Bundle 加载的对象，业务必须先结束相关使用。清理 Loader 不会删除沙盒里的 __data、__info；磁盘缓存淘汰属于另一套操作。

## 一个共享 Bundle 的计数例子 {#reference-example}

假设 Player 与 Enemy 已加载完成，分别有一个 Provider，且无额外依赖约束：

| 阶段 | Player Provider | Enemy Provider | 共享 Loader |
| --- | --- | --- | --- |
| 两者均在使用 | Handle 引用 1 | Handle 引用 1 | Provider 引用 2 |
| Player Handle 释放，尚未清理 | 0 | 1 | 仍为 2 |
| 清理销毁 Player Provider | 已销毁 | 1 | 1 |
| Enemy 也释放并完成清理 | 已销毁 | 已销毁 | 0，可销毁并移除 |

第三行是容易忽略的时机差：关闭自动卸载时，零引用 Provider 暂时存在，其 Loader 引用也仍然存在，直到主动清理。

## 自动卸载与主动清理 {#unload-policy}

初始化参数 `AutoUnloadBundleWhenUnused` 默认是 false。可选择保持默认，在业务边界清理：

```csharp
handle.Release();
// 模块退出、关卡结束等合适时机执行：
yield return package.UnloadUnusedAssetsAsync();
```

这有利于短时间重复使用的 UI、角色或音效复用已有加载结果。代价是需要安排清理，否则无人使用的内容也可能继续占用内存。

开启自动卸载后，最后一个 Handle 释放会触发卸载尝试。它并不是持续扫描的“引用为零必定立即卸载”保证：正在加载或受依赖约束时，尝试可能无法销毁。若加载中提前释放，不能假设后续完成时一定自动重试同一清理动作。

大型、低频使用资源可以更积极清理，常用公共内容则应有明确的常驻所有者。应结合加载频率和内存数据选择，而不是把自动卸载作为通用最优设置。

## 直接使用资源对象 {#direct-asset}

Texture 加载后赋给 UI，Handle 应覆盖所有使用者的使用期。UI 更换纹理并且没有其他使用者时，即可释放旧 Handle，不一定要等 UI 销毁。

通常不要先手动 Destroy 由加载器共享的 Texture，再释放句柄；另一个 Handle 可能仍在使用同一个对象。Unity 对象依赖并不会自动转成 YooAsset 的句柄计数。

场景使用专门接口。当前 SceneHandle.UnloadSceneAsync 在场景卸载成功后会释放该场景句柄的引用。卸载场景与清理剩余无引用 Bundle 仍然是两个层面。

## Prefab 实例与对象池 {#instances}

普通 Object.Instantiate 不会自动增加 YooAsset 的引用计数。一个 Handle 创建 100 个实例，Provider 的 Handle 计数不会因此变成 100。

```text
对象池 / 工厂
├─ 持有 Prefab 的 Handle
└─ 管理由该 Prefab 创建的实例
```

只要这些实例仍可能使用材质、纹理等依赖，就必须维持有效的资源引用。对象只是隐藏或禁用，仍属于使用期。清空对象池、结束实例使用且不再需要模板后，再释放对应 Handle。

普通 Destroy 的销毁发生在 Unity 后续时机，业务不应把“发出了 Destroy 调用”与“所有对象已经结束使用”无条件视为同一瞬间。清理流程应安排好时序。

不同实例化辅助接口是否自动绑定生命周期，需要阅读具体实现。本节结论针对普通 Object.Instantiate，不把任何辅助封装都假定为自动持有句柄。

## Package 销毁不是缓存删除 {#package-destruction}

彻底退出一个 Package 时，先结束场景和对象使用，再等待 DestroyPackageAsync 成功；需要从 YooAssets 注册表移除时，之后调用 RemovePackage。全量卸载与销毁可能主动释放句柄，应当是业务明确的生命周期终点。

已下载 Bundle 可以继续留在磁盘，之后重新初始化和加载 Package 时复用。清理内存、销毁运行时 Package、删除磁盘缓存是三个独立决策。

## 源码阅读入口 {#source}

- [HandleBase.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Handles/HandleBase.cs)
- [ProviderBase.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Providers/ProviderBase.cs)
- [ResourceManager.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/ResourceManager.cs)
- [LoadBundleOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Operations/Internal/LoadBundleOperation.cs)
- [UnloadUnusedAssetsOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Operations/UnloadUnusedAssetsOperation.cs)
- [AssetBundleHandle.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleHandle/Services/AssetBundleHandle/AssetBundleHandle.cs)
