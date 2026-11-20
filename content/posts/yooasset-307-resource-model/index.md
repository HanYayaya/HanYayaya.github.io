---
title: "2. 资源清单与资源描述结构"
slug: yooasset-307-resource-model
date: 2026-11-19
lastmod: 2026-11-20
description: "分析清单如何连接资源与 Bundle，并追踪版本选择、清单反序列化、查询索引建立和激活过程。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 2
draft: false
toc: true
---

## 清单连接构建结果与运行时 {#manifest-role}

业务使用 `Player` 这样的地址定位资源，Unity 最终需要的却是具体 Bundle 文件，以及 Bundle 内的资源名称。两者之间的映射不能靠运行时遍历所有 Bundle 来推断，因此需要在构建时记录下来。

YooAsset 的 `TaskCreateManifest.CreateManifestFile` 从构建上下文中取得资源和 Bundle 信息，生成 `BuildManifest`，然后写出二进制清单。运行时通过 `DeserializeManifestOperation` 读取这些数据，生成 `PackageManifest`。

```text
资源收集与 Bundle 构建结果
    → BuildManifest：构建端整理地址、文件信息和依赖关系
    → 序列化为清单文件
    → PackageManifest：运行时还原描述并建立查询索引
```

这里讨论的是 YooAsset 的 Package 清单，与 Unity 自身的 `AssetBundleManifest` 不是同一个对象。YooAsset 除了记录 Bundle 关系，还需要记录业务寻址、资源级依赖、标签以及文件校验信息。

清单保存的是描述，不包含 Prefab、Texture 等已经加载的 Unity 对象。加载清单也不会将清单中的所有 Bundle 加载进内存。

## PackageManifest 的主体：两张列表 {#manifest-collections}

`PackageManifest` 中最重要的两个字段是：

```csharp
public List<PackageAsset> AssetList = new List<PackageAsset>();
public List<PackageBundle> BundleList = new List<PackageBundle>();
```

`AssetList` 描述可被框架主动查询的资源，`BundleList` 描述构建产生的资源包。两者分开保存，是因为资源与 Bundle 并非一一对应：一个 Bundle 可以容纳多个资源，一个资源又可能依赖多个其他 Bundle。

除此之外，清单还保存解释这两张列表所需的公共信息：

| 字段 | 作用 |
| --- | --- |
| PackageName、PackageVersion | 标识所属 Package 及本次资源版本 |
| FileVersion | 清单二进制格式版本，用于兼容性检查 |
| BuildPipeline、BuildBundleType | 描述构建管线与资源包类型 |
| OutputNameStyle | 决定如何从 Bundle 名称、文件哈希生成发布文件名 |
| EnableAddressable、SupportExtensionless | 控制可寻址地址、无扩展名路径等定位方式 |
| LocationToLower、IncludeAssetGuid、ReplaceAssetPathWithAddress | 控制定位比较方式、GUID 数据及路径替换行为 |

`PackageVersion` 与 `FileVersion` 要区分开：前者表示业务发布的某一版资源，例如 `v3`；后者表示框架应当按照哪一种二进制格式读取文件。

下面先使用一个普通的可寻址配置：启用 Address，保留原始 AssetPath。这样可以直观看到资源地址和 Bundle 文件之间的关系。

## PackageAsset：描述一个资源的位置 {#package-asset}

`PackageAsset` 的主要字段如下，摘录省略注释和属性标记：

```csharp
public string Address;
public string AssetPath;
public string AssetGuid;
public int BundleID;
public int[] DependentBundleIDs;
public PackageTags Tags;
```

其中，Address 是业务使用的可寻址地址，AssetPath 是资源定位路径，AssetGuid 是按配置保留的资源 GUID。Tags 用于资源分类。真正将资源连接到文件集合的是 `BundleID` 和 `DependentBundleIDs`。

假设 Player Prefab 位于角色 Bundle，材质和纹理位于其他 Bundle。以下是解释结构的示例，编号和文件名不代表实际构建结果：

```text
PackageAsset
    Address = Player
    AssetPath = Assets/GameRes/Player.prefab
    BundleID = 0
    DependentBundleIDs = [1, 2]

BundleList
    [0] characters.bundle
    [1] materials.bundle
    [2] textures.bundle
```

通过这个资源描述，可以先找到所属的 `BundleList[0]`，再找到所需的 `BundleList[1]` 和 `BundleList[2]`。对应的源码入口是：

```csharp
public PackageBundle GetMainPackageBundle(PackageAsset packageAsset)
{
    return GetMainPackageBundle(packageAsset.BundleID);
}
```

整数重载检查索引范围后，返回 `BundleList[bundleID]`。因此，**BundleID 是当前清单内部的列表索引**。

构建端也能证实这一点：`CreatePackageBundleList` 按 BundleName 排序；`ProcessPackageAsset` 将 Bundle 名称映射为该列表中的位置，再写入资源的 BundleID。下一版清单增加或删除 Bundle 后，索引可能改变，不能把 `0` 这样的编号直接当作跨版本文件身份。

AssetList 也不是 Bundle 中所有 Unity 对象的展开列表。仅作为依赖被打入的材质、纹理，以及 FBX 或图片内的子对象，不一定各自拥有独立的 PackageAsset 条目。应当区分“内容被打进 Bundle”和“资源被收集为可主动寻址的条目”。

## PackageBundle：描述实际需要的文件 {#package-bundle}

知道资源位于 `BundleList[0]` 后，还需要知道这个 Bundle 对应哪份文件。`PackageBundle` 保存了这部分信息：

| 字段或属性 | 含义 |
| --- | --- |
| BundleName | 构建产生的 Bundle 名称，运行时也用于查询对应的 Bundle Loader |
| FileHash | 文件哈希，区分不同内容的文件 |
| BundleGuid | 当前实现直接返回 FileHash |
| FileCrc、FileSize | 文件完整性检查所需的 CRC 和大小 |
| UnityCrc | Unity 构建产生的 CRC，与 FileCrc 分开保存 |
| IsEncrypted | 文件是否经过加密处理 |
| DependentBundleIDs | Bundle 层面的依赖索引集合 |
| Tags | Bundle 的分类标签 |

BundleGuid 的实现非常直接：

```csharp
public string BundleGuid
{
    get { return FileHash; }
}
```

它不同于 PackageAsset 的 AssetGuid，也不同于 BundleID。资源 GUID 标识工程资源，BundleID 用于清单内部寻址，BundleGuid 则用于标识目标 Bundle 文件。

发布文件名由 `PackageBundle.Initialize` 计算：

```csharp
_manifest = manifest;
_fileName = BundleFileNaming.GetBundleFileName(
    manifest.OutputNameStyle, BundleName, FileHash);
```

因此，BundleName、文件哈希和最终文件名也不能混为一谈。文件名的生成受命名规则影响；下载后如何在本地保存，则由文件系统决定。

至此，前面的映射可以再向下延伸一层：

```text
Player
    → PackageAsset.BundleID = 0
    → BundleList[0]
    → BundleName、BundleGuid、文件名、大小、CRC 等文件描述
```

清单已经能够说明“需要什么文件”。这些文件是否已经存在于安装包或下载缓存中，还需要文件系统判断。

## 为什么资源和 Bundle 都有依赖列表 {#dependencies}

PackageAsset 与 PackageBundle 都有 `DependentBundleIDs`，但两者的数据来源和查询目的不同。

构建时，`ProcessPackageAsset` 使用框架收集到的资源依赖，生成资源级的依赖 Bundle 列表；`ProcessBundleDepends` 则查询引擎构建得到的 Bundle 依赖，并转换为清单中的索引。不能仅因为字段名称相同，就认为它们保存的是同一组结果。

例如，一个角色 Bundle 中同时包含 Player 和 Enemy。概念上，Player 可能需要纹理包 A，Enemy 需要纹理包 B，而整个角色 Bundle 的依赖范围需要覆盖两者。实际集合仍以构建结果和框架处理为准。

运行时，`PackageManifest` 为这两种关系提供不同接口：

```text
GetAllAssetDependencies(PackageAsset)
    → 遍历这个资源的 DependentBundleIDs

GetAllBundleDependencies(PackageBundle)
    → 遍历这个 Bundle 的 DependentBundleIDs
```

`FileSystemHost.GetDependentBundleInfos` 在加载整个 Bundle 的全部资源，即 `LoadAllAssets` 路径上，采用 Bundle 级依赖查询；其他常规资源请求采用资源级依赖查询。这里先了解数据的区别，具体加载行为到 ResourceManager 篇再展开。

## 选择版本并请求清单 {#select-version}

理解数据结构后，再回到初始化结束的位置：Package 已经有运行环境，但 `FileSystemHost.ActiveManifest` 仍然为空。下一步需要选择并加载某个版本的清单。

默认没有文件名前缀时，构建 `DefaultPackage` 的 `v3` 版本会生成以下相关文件：

```text
DefaultPackage.version     记录版本字符串 v3
DefaultPackage_v3.bytes    二进制清单
DefaultPackage_v3.hash     清单文件的校验信息
```

当前 `TaskCreateManifest` 写出的 `.hash` 内容是清单文件的 CRC32 校验值；运行时的校验 Helper 还兼容 MD5 格式。这个文件验证的是清单本身，不是清单中每一个 Bundle。

版本查询和清单加载是两次操作。业务可以调用 `RequestPackageVersionAsync`，取得其 `PackageVersion`；也可以已经知道目标版本，直接传给清单加载接口：

```csharp
// 协程片段：package 已完成初始化，业务确定使用 v3。
var operation = package.LoadPackageManifestAsync(new LoadPackageManifestOptions("v3", 60));
yield return operation;
if (operation.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(operation.Error);
    yield break;
}
```

`.version` 表达发布端选定的版本，并不负责寻找数值最大或时间最新的目录。直接指定 `v3` 省略的是版本查询，目标清单不存在于本地时，仍可能需要联网获取。

`LoadPackageManifestOperation` 先检查参数和当前激活版本。如果已经激活同名版本，会直接成功；否则取得主文件系统，开始加载：

```csharp
var mainFileSystem = _host.GetMainFileSystem();
_loadPackageManifestOp = mainFileSystem.LoadPackageManifestAsync(
    _options.ConvertTo());
```

主文件系统是 FileSystemHost 注册列表中的最后一项。默认联机组合中是 SandboxFileSystem，离线模式中则是 BuiltinFileSystem。加载清单先走这个固定入口，而不是对每个文件系统尝试 Bundle 匹配。

## 从文件数据到 PackageManifest {#deserialize}

以默认联机模式为例，Sandbox 对应的清单操作会先确保目标 `.hash` 和 `.bytes` 文件存在，再读取、校验并解析。已有对应缓存文件时会跳过下载步骤，但后续仍要校验和读取。

```text
LoadPackageManifestOperation
    → SFSLoadPackageManifestOperation
        → 准备目标版本的校验文件和清单文件
        → LoadCachePackageManifestOperation
            → 读取文件字节
            → VerifyManifestData
            → DeserializeManifestOperation
```

这里先将文件系统视为提供字节数据的接口。缓存具体存放在哪里、下载由谁执行，不影响理解接下来的反序列化过程。

`DeserializeManifestOperation` 的主体状态顺序为：

```text
DecryptManifest
    → DeserializeFileHeader
    → PrepareAssetList / DeserializeAssetList
    → PrepareBundleList / DeserializeBundleList
    → InitManifest
```

如果配置了解密器，先处理清单字节；然后检查文件标记与格式版本，读取 PackageName、PackageVersion 和寻址选项等公共信息。格式版本不匹配会返回错误，资源版本字符串并不能绕过这种格式兼容性要求。

接下来分别读取 PackageAsset 和 PackageBundle。资源列表中读取地址、路径、GUID、BundleID 和依赖索引；Bundle 列表中读取名称、哈希、CRC、大小等描述，并调用 `PackageBundle.Initialize` 计算文件名。

这不是简单地将 C# 对象交给通用序列化器保存和恢复。当前格式使用全局目录表和标签表，条目通过索引引用这些公共数据；例如标签索引会被还原为 `PackageTags`。源码中的 `[NonSerialized]` 也不能单独用来判断某项业务数据是否进入了这套自定义二进制格式。

读取列表的循环还会检查 `IsBusy`，允许操作按调度预算跨帧继续。反序列化结束后得到的是描述对象及其索引，仍然没有开始读取 Bundle 内的 Unity 资源。

## 建立索引：让描述能够被快速查询 {#runtime-indexes}

只有两张列表，理论上也能遍历查找资源，但运行时会反复进行地址和文件查询。因此，反序列化过程一边创建条目，一边建立字典：

| 索引 | 查询键 | 查询结果 |
| --- | --- | --- |
| AssetsByLocation | 资源路径，以及配置允许的地址、无后缀路径 | PackageAsset |
| AssetsByGuid | 资源 GUID，需包含 GUID 数据 | PackageAsset |
| BundlesByBundleName | BundleName | PackageBundle |
| BundlesByFileName | 按命名规则生成的文件名 | PackageBundle |
| BundlesByGuid | BundleGuid，即 FileHash | PackageBundle |

以普通可寻址配置为例，`FillAssetCollection` 将 `Player` 和 `Assets/GameRes/Player.prefab` 都映射到同一个 PackageAsset。查询字典不会为两个键再复制两份资源描述。

```text
AssetsByLocation["Player"] ──────────────────────┐
                                                 ├─ 同一个 PackageAsset
AssetsByLocation["Assets/GameRes/Player.prefab"] ┘
```

这些键并不是无条件全部存在：Address 映射受 `EnableAddressable` 控制，无后缀路径受 `SupportExtensionless` 控制。当前实现还明确禁止可寻址模式与 `LocationToLower` 同时启用；开启路径替换时，解析也有相应分支。因此不能把“地址、路径、大小写任意写都能找到”当作框架的默认规则。

Bundle 的索引填充则更直接：

```csharp
manifest.BundleList.Add(packageBundle);
manifest.BundlesByBundleName.Add(packageBundle.BundleName, packageBundle);
manifest.BundlesByFileName.Add(packageBundle.GetFileName(), packageBundle);
manifest.BundlesByGuid.Add(packageBundle.BundleGuid, packageBundle);
```

列表保留以整数索引连接的关系，字典提供不同入口的快速查找，两者各有用途。

## 补齐反向关系并激活清单 {#activate-manifest}

两张列表读取结束后，`InitManifest` 还会执行：

```csharp
FillBundleMainAssets(Manifest);
FillBundleReferrerBundleIDs(Manifest);
```

`FillBundleMainAssets` 根据每个 PackageAsset 的 BundleID，将资源加入所属 Bundle 的 `MainAssets`。这样除了从资源找到 Bundle，也能从 Bundle 查到其中有哪些主动收集资源。

`FillBundleReferrerBundleIDs` 则遍历 Bundle 的依赖集合，建立反向引用。例如角色包 `[0]` 依赖纹理包 `[2]`，则在 `[2].ReferrerBundleIDs` 中记录 `0`。它表示“哪些 Bundle 引用了我”，后续卸载判断会用到这份关系。

```text
资源 → 所属 Bundle             Bundle.MainAssets 补出反向查询
Bundle → 依赖 Bundle           ReferrerBundleIDs 补出引用方查询
```

反序列化操作完成后，结果逐层返回给 `LoadPackageManifestOperation`。外层确认成功，再调用：

```csharp
_host.SetActiveManifest(_loadPackageManifestOp.Manifest);
SetResult();
```

此时，清单才成为该 Package 的 `ActiveManifest`。文件下载完成、字节读取完成和清单激活完成是不同阶段。以完成的外层操作结果为准，业务才能继续使用这份资源描述。

## 从清单描述走向文件系统 {#request-context}

清单激活后，输入一个资源地址便可以得到完整的文件需求：

```text
Player
    → AssetsByLocation 查询 PackageAsset
    → BundleID 查询主 PackageBundle
    → DependentBundleIDs 查询依赖 PackageBundle
    → 得到所需文件的名称、哈希、大小等信息
```

至此，Package 已经知道要找什么资源、需要哪些文件, 本地可用性则由文件系统维护。