---
title: "5. Provider、Handle 与 Bundle 加载复用"
slug: yooasset-307-loading
date: 2026-11-19
lastmod: 2026-11-19
description: "沿两层缓存追踪加载过程，定位 LoadFromFile 与 LoadAsset 的 Unity API 调用。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 5
draft: true
toc: true
---

两个资源在同一个 Bundle 中，是否共用 Provider？两次加载同一个地址，是否返回同一个 Handle？本文从 ResourceManager 的两组字典进入，追到 Unity 的 AssetBundle 和资源对象加载接口。

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

## 两层复用与一份使用凭证 {#reuse-layers}

ResourceManager 同时缓存 Provider 和 Bundle Loader，范围是当前 Package。Provider 的查询键描述加载方法、资源路径和类型；Loader 的查询键是 BundleName。每次有效加载请求都会通过 Provider 创建一个新的 Handle。

```text
h1 ─┐
    ├─ Player AssetProvider ─┐
h2 ─┘                       ├─ characters.bundle Loader
h3 ─── Enemy AssetProvider ──┘
```

上图假设 Player 与 Enemy 位于同一个主 Bundle，且三次请求类型一致。结果是三个 Handle、两个 Provider、一个共享的主 Bundle Loader。依赖 Bundle 也通过同样的管理器机制复用。

## Provider 按什么键复用 {#provider-key}

ResourceManager.LoadAssetAsync 的核心代码摘录：

```csharp
string providerKey = nameof(LoadAssetAsync) + assetInfo.AssetKey;
ProviderBase provider = GetAssetProvider(providerKey);
if (provider == null)
{
    provider = new AssetProvider(this, providerKey, assetInfo);
    provider.InitProviderDebugInfo();
    _providerDict.Add(providerKey, provider);
    AsyncOperationSystem.StartOperation(PackageName, provider);
}
provider.Priority = priority;
return provider.CreateHandle<AssetHandle>();
```

AssetKey 使用解析后的路径及类型名，所以不同地址形式解析到同一资源、请求类型一致时可以复用。相同地址分别请求 GameObject、UnityEngine.Object 时，键不同。加载子资源、全部资源也有各自的 Provider 类型和方法前缀。

复用不会只发生在加载结束之后。正在加载的 Provider 同样可以被多个 Handle 引用，从而合并进行中的请求。场景是特殊情况，当前实现为每次场景加载构造不同 ProviderKey，不能直接套用普通 AssetProvider 的复用结论。

## Bundle Loader 的字典在哪里 {#loader-cache}

`_bundleLoaderDict` 属于 ResourceManager，ProviderBase 只持有自己需要的主 Loader 和依赖 Loader 集合。核心代码如下：

```csharp
string bundleName = bundleInfo.Bundle.BundleName;
LoadBundleOperation loaderOperation = GetBundleLoader(bundleName);
if (loaderOperation != null)
    return loaderOperation;

loaderOperation = new LoadBundleOperation(this, bundleInfo);
_bundleLoaderDict.Add(bundleName, loaderOperation);
return loaderOperation;
```

这里是运行时加载对象缓存，区别于 SandboxBundleCache 按 FileHash 建立的磁盘文件索引。磁盘中可以保留不同哈希的版本，但运行时当前 Package 的 Loader 缓存不是以 PackageVersion 加哈希为键，所以切换清单必须处理已有加载状态。

## ProviderBase 怎样准备 Bundle {#provider-state}

ProviderBase 构造时取得主加载器、依赖加载器，并立即增加它们的引用。源码特别说明不要把这一步延迟到 InternalStart，否则共享 Loader 可能在引用尚未登记时被提前卸载。

其正常加载过程可概括为：

```text
启动各 Bundle Loader
    ↓
逐步更新并等待全部 Loader 完成
    ↓
检查失败结果
    ↓
取得主 Loader 的 BundleHandle
    ↓
交给具体 Provider 加载对象
```

主 Bundle 与依赖 Bundle 就绪后，AssetProvider 调用主 BundleHandle 的资源加载方法。资源对象加载期间，依赖 Loader 仍由 Provider 持有引用。

## 文件到 AssetBundle 的实际调用 {#load-bundle}

以沙盒中的普通 AssetBundle 为例：

```text
LoadBundleOperation
    → BundleInfo.CreateBundleLoader
    → SFSLoadPackageBundleOperation
         → 必要时下载并缓存
    → SBCLoadAssetBundleOperation
    → LoadLocalAssetBundleOperation
    → AssetBundle.LoadFromFile / LoadFromFileAsync
```

直接读取内置文件时，中间换成 BFSLoadPackageBundleOperation、BBCLoadAssetBundleOperation，最终仍进入同一份本地 Bundle 加载实现。需要解包的内置资源则改用解包缓存加载。

普通未加密文件的最终调用：

```csharp
private void LoadFromFile()
{
    if (IsWaitForCompletion)
        _assetBundle = AssetBundle.LoadFromFile(_options.FilePath);
    else
        _createRequest = AssetBundle.LoadFromFileAsync(_options.FilePath);
}
```

加密文件按解密器接口选择带 offset 的 LoadFromFile、LoadFromMemory 或 LoadFromStream 及对应异步版本。加载成功后构造 AssetBundleHandle，封装 Unity AssetBundle 和可能持有的流。

Web 路径、编辑器虚拟 Bundle 路径不能一概归结为 LoadFromFile。模拟模式最终通过 AssetDatabase 获得工程对象。

## AssetBundle 到资源对象的实际调用 {#load-object}

```text
AssetProvider
    → LoadedBundleHandle.LoadAssetAsync(MainAssetInfo)
    → AssetBundleHandle
    → ABHLoadAssetOperation
    → AssetBundle.LoadAsset / LoadAssetAsync
```

以下摘录省略 AssetType 为空时的重载选择：

```csharp
if (IsWaitForCompletion)
    Result = _assetBundle.LoadAsset(
        _assetInfo.AssetPath, _assetInfo.AssetType);
else
    _request = _assetBundle.LoadAssetAsync(
        _assetInfo.AssetPath, _assetInfo.AssetType);
```

异步请求完成后取得 `_request.asset`，Provider 保存结果，Handle 提供状态及对象访问。加载 Prefab 到这一步只得到模板，尚未实例化场景对象。

同步入口仍沿同一管理链路执行，通过等待标记驱动同步完成。如果底层异步请求已经开始，源码有读取 Unity 请求结果、阻塞主线程的等待路径。同步接口不会消除加载成本，尤其不宜把需要网络下载的场景当作普通同步读取。

## 单对象、子资源、全部资源 {#load-methods}

| YooAsset 接口 | 普通 AssetBundle 底层接口 | 范围 |
| --- | --- | --- |
| LoadAssetAsync | LoadAssetAsync | 指定地址的一个匹配对象 |
| LoadSubAssetsAsync | LoadAssetWithSubAssetsAsync | 指定资源文件的匹配对象集合 |
| LoadAllAssetsAsync | LoadAllAssetsAsync | 地址所在 Bundle 的全部匹配对象 |
| LoadSceneAsync | 专门场景加载路径 | 场景 |

一张 Multiple 模式的图片可以产生多个 Sprite 子资源，FBX 可以包含 Mesh、AnimationClip。子资源不等于 Prefab 的子 GameObject，也不等于它引用的所有外部依赖。

AssetDatabase.LoadMainAssetAtPath 是编辑器接口。真实 Bundle 的 LoadAssetWithSubAssets 可包括匹配的主资源和子资源；当前模拟实现使用 LoadAllAssetRepresentationsAtPath，语义细节并非完全相同。业务应明确请求类型，并验证真实构建结果。

LoadAllAssets 的 location 用于定位 Bundle，实际底层调用不再传入单个资源路径。因此它与打包规则耦合，不能当作“加载整个 Package”。

## 源码阅读入口 {#source}

- [ResourceManager.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/ResourceManager.cs)：两组复用字典。
- [ProviderBase.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Providers/ProviderBase.cs) 与 [AssetProvider.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Providers/AssetProvider.cs)：依赖准备和对象加载。
- [LoadBundleOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourceManager/Operations/Internal/LoadBundleOperation.cs)：Bundle 状态与引用。
- [LoadLocalAssetBundleOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleCache/Operations/Common/LoadLocalAssetBundleOperation.cs)：LoadFromFile 等调用。
- [ABHLoadAssetOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleHandle/Services/AssetBundleHandle/Operations/ABHLoadAssetOperation.cs)：LoadAsset 等调用。
