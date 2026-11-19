---
title: "4. ResourcePackage 与资源描述结构"
slug: yooasset-307-resource-model
date: 2026-11-19
lastmod: 2026-11-19
description: "区分 PackageManifest、PackageAsset、PackageBundle、AssetInfo 与 BundleInfo。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 4
draft: true
toc: true
---

调用 `LoadAssetAsync<GameObject>("Player")` 时，字符串如何变成加载器需要的信息？本文集中阅读 ResourcePackage 层的数据对象，区分清单描述与运行时包装，为后续 Provider、Handle 分析建立输入模型。

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

## ResourcePackage 是管理入口 {#package-entry}

`ResourcePackage` 对外提供初始化、加载清单、查询资源、加载资源和下载等接口。它持有初始化操作、`ResourceManager`、`FileSystemHost`。当前 `PackageManifest` 保存在后者的 `ActiveManifest` 属性中。

```text
ResourcePackage
├─ _initializeOp
├─ _resourceManager
└─ _fileSystemHost
   ├─ ActiveManifest
   └─ IFileSystem 列表
```

Package 对象有自己的生命周期；Manifest 描述其中某个资源版本。更换资源版本不等于改一个普通字段：已有加载器依赖之前的描述和对象，必须协调其生命周期。

## PackageManifest 的列表与索引 {#manifest-collections}

清单包含 PackageName、PackageVersion、命名风格、构建类型以及寻址配置，还有两张主体列表：

```csharp
public List<PackageAsset> AssetList;
public List<PackageBundle> BundleList;
```

反序列化过程中构造索引：

| 字典 | 查询键 | 值 |
| --- | --- | --- |
| AssetsByLocation | 地址、路径及配置允许的路径形式 | PackageAsset |
| AssetsByGuid | 资源 GUID，取决于是否包含该数据 | PackageAsset |
| BundlesByBundleName | BundleName | PackageBundle |
| BundlesByFileName | 构建命名规则生成的文件名 | PackageBundle |
| BundlesByGuid | FileHash / BundleGuid | PackageBundle |

这些索引指向列表中的同一批描述对象。地址、完整路径可能指向同一个 PackageAsset，不需要重复保存整份描述。是否允许无扩展名路径、地址大小写等，要按清单配置和对应解析分支理解。

## PackageAsset 与 BundleID {#package-asset}

PackageAsset 记录主动收集资源的地址、路径、可选 GUID、标签、所属 BundleID 和依赖 BundleID 数组。例如下面是概念示例，编号和路径并非仓库实际资源：

```text
Address = Player
AssetPath = Assets/GameRes/Player.prefab
BundleID = 2
DependentBundleIDs = [5, 8]
```

读取主 Bundle 的核心代码：

```csharp
public PackageBundle GetMainPackageBundle(PackageAsset packageAsset)
{
    return GetMainPackageBundle(packageAsset.BundleID);
}
```

整数 BundleID 是当前 Manifest 的 BundleList 索引。不同版本中 ID 可能重新排列，不能单独拿它当磁盘文件身份。

PackageAsset 是描述，不持有 GameObject、Texture 或加载进度。清单的 AssetList 也不应理解为工程中所有隐式依赖子对象的枚举。

## PackageBundle 与文件身份 {#package-bundle}

PackageBundle 包含 BundleName、UnityCrc、FileHash、FileCrc、FileSize、IsEncrypted、依赖及标签。`BundleGuid` 是对 FileHash 的属性包装。

```text
BundleName：运行时管理器查询 Loader 使用的名称
BundleID：当前清单内部的列表索引
BundleGuid：文件内容身份，当前实现等于 FileHash
FileName：按 OutputNameStyle 计算的发布文件名
```

当前命名风格包括哈希名、Bundle 名、Bundle 名加哈希。例如 `player.bundle` 和哈希 `abcd` 可以输出 `abcd.bundle` 或 `player_abcd.bundle`。沙盒写入后仍统一保存成哈希目录下的 `__data`。

反序列化后还补充 `MainAssets` 与 `ReferrerBundleIDs`，分别表示 Bundle 包含的主动收集资源，以及引用它的 Bundle。后者会参与卸载条件判断。

## 两种依赖列表不能混用 {#dependencies}

PackageAsset 与 PackageBundle 都有 `DependentBundleIDs`，但观察角度不同。前者对应资源级依赖，后者对应构建得到的 Bundle 级依赖。

假设一个 Bundle 内有 Player 与 Enemy，Player 需要纹理包 A，Enemy 需要纹理包 B。加载单个 Player 时，框架可以查询资源级依赖；加载整个 Bundle 的全部资源时，需要考虑 Bundle 范围内的依赖集合。

`FileSystemHost.GetDependentBundleInfos` 对 `ELoadMethod.LoadAllAssets` 选择 Bundle 依赖查询，其他常规路径查询资源依赖。实际内容分布受构建规则决定，上述示例用于说明两个集合存在的必要性。

## AssetInfo：描述加请求上下文 {#asset-info}

AssetInfo 内部引用 PackageAsset，并补充 PackageName、AssetType、LoadMethod、Error 等信息：

```text
PackageAsset：Player 的位置及依赖
    + AssetType = GameObject
    + LoadMethod = LoadAsset
    ↓
AssetInfo：这次加载请求使用的信息
```

其 AssetKey 在当前实现中按路径和类型名生成：

```csharp
if (AssetType == null)
    _assetKey = $"[{AssetPath}][null]";
else
    _assetKey = $"[{AssetPath}][{AssetType.Name}]";
```

这里使用的是 `Type.Name`，不是完整程序集限定类型名。阅读源码时应以实际键规则为准，不把它描述成更强的全局类型唯一标识。

AssetInfo 可以由 `GetAssetInfo` 查询获得，创建它本身不意味着开始加载。查找失败时它也可以携带 Error，后续由加载流程生成失败结果。

## BundleInfo：描述加文件系统 {#bundle-info}

BundleInfo 则组合另一类上下文：

```csharp
private readonly IFileSystem _fileSystem;
public readonly PackageBundle Bundle;
```

FileSystemHost 解析主 Bundle、依赖 Bundle，选择能够处理它们的文件系统，再构造 BundleInfo。它封装加载、确保文件就绪和下载操作的创建入口。

```text
PackageBundle：需要 BBB 这份文件
BundleInfo：需要 BBB，由某个 SandboxFileSystem 实例负责
```

BundleInfo 不持有已经加载的 Unity AssetBundle，也不是 Bundle 引用计数的所有者。真正的加载状态及引用由后续 LoadBundleOperation 管理。

## 一次请求怎样跨过数据层 {#request-flow}

```text
ResourcePackage.LoadAssetAsync<GameObject>(Player)
    → Manifest 将地址转换为 PackageAsset
    → 包装 AssetInfo
    → 设置 LoadMethod
    → ResourceManager 查找或创建 Provider
         → Provider 请求主 Bundle 和依赖 Bundle 加载器
         → FileSystemHost 查询 PackageBundle、选择文件系统
         → 创建 BundleInfo
         → ResourceManager 查找或创建 LoadBundleOperation
    → 返回新的 AssetHandle
```

AssetInfo、BundleInfo 按查询和加载需求产生，不是初始化时为所有资源预建。清单描述在加载期间继续存在，Provider 通过包装对象引用这些信息；它们并没有被转换后丢弃。

## 源码阅读入口 {#source}

- [ResourcePackage.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/ResourcePackage.cs)
- [PackageManifest.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/PackageManifest.cs)
- [PackageAsset.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/PackageAsset.cs) 与 [PackageBundle.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/PackageBundle.cs)
- [AssetInfo.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/AssetInfo.cs) 与 [BundleInfo.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/BundleInfo.cs)
- [DeserializeManifestOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/Internal/DeserializeManifestOperation.cs)
