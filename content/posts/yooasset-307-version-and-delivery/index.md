---
title: "3. 资源版本、清单与首包交付"
slug: yooasset-307-version-and-delivery
date: 2026-11-19
lastmod: 2026-11-19
description: "理解版本查询、清单缓存、回滚、CDN 目录以及按标签复制首包资源。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 3
draft: true
toc: true
---

资源版本回答“这次使用哪份清单”，缓存回答“清单要求的文件是否已经可用”，首包配置回答“哪些文件随应用交付”。把这三个问题分开，才能清楚解释更新、回滚和进游戏前下载。

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

## 一次资源发布的三个入口文件 {#release-files}

构建参数 `PackageName` 与 `PackageVersion` 决定包裹和发布标识。版本是业务指定的字符串，不要求与 APK 版本一致，也不是单个 Bundle 的哈希。

默认无文件名前缀时，构建 `DefaultPackage / v3` 会生成：

```text
DefaultPackage.version     文本内容 v3
DefaultPackage_v3.bytes    资源清单
DefaultPackage_v3.hash     清单校验信息
```

`.version` 文件名固定，用来找到目标清单。它记录构建或发布选择的版本，不负责比较哪个字符串更新。线上将它改回 v2，就是让后续查询选择 v2；客户端不会自动扫描服务器目录找最大版本。

## 版本查询与直接指定 {#select-version}

Package 初始化成功后，可以查询版本：

```csharp
var versionOp = package.RequestPackageVersionAsync();
yield return versionOp;
if (versionOp.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(versionOp.Error);
    yield break;
}
string targetVersion = versionOp.PackageVersion;
```

默认联机配置由主文件系统 Sandbox 查询远端。`IRemoteService.GetRemoteUrls(fileName)` 提供候选 URL，URL 策略选择地址，下载后端读取文本。当前操作只把版本字符串保存在结果属性中，没有写入沙盒 `.version` 文件的步骤。安装包中随构建复制的版本文件则仍然存在，供内置文件系统读取。

业务已经确定目标版本时，可以省略查询，直接加载清单：

```csharp
var manifestOp = package.LoadPackageManifestAsync(
    new LoadPackageManifestOptions("v3", 60));
yield return manifestOp;
if (manifestOp.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(manifestOp.Error);
    yield break;
}
```

直接指定版本只省略版本查询，不保证后续不联网。本地缺少目标清单时仍需要下载。

## 清单怎样缓存、解析和激活 {#manifest-loading}

`LoadPackageManifestOperation` 使用 `FileSystemHost.GetMainFileSystem()`，即注册列表中最后一个文件系统。这个路径与逐个 Bundle 调用 `CanAcceptBundle` 选提供者不同。

默认 Sandbox 的处理为：

```text
确保目标版本 .hash 存在
    → 确保目标版本 .bytes 存在
    → 读取 .hash 和 .bytes
    → 校验清单数据
    → 按配置解密并反序列化
    → 构建查询索引
    → SetActiveManifest
```

本地对应文件存在时跳过下载，随后仍然校验。`PackageManifestHelper.VerifyManifestData` 支持按校验文本格式选择 MD5 或 CRC32；这是清单校验，区别于 Bundle 的缓存校验。

缓存位置按固定规则拼接：

```text
PackageRoot/
├─ ManifestFiles/
│  ├─ DefaultPackage_v2.bytes
│  ├─ DefaultPackage_v2.hash
│  ├─ DefaultPackage_v3.bytes
│  └─ DefaultPackage_v3.hash
└─ BundleFiles/
```

PackageRoot 可以在创建沙盒参数时指定。默认编辑器位于工程 `Library/yoo/PackageName`，移动平台位于 `persistentDataPath/yoo/PackageName`；当前实现 Windows、Linux 独立程序默认使用 `dataPath/yoo/PackageName`，macOS 使用持久化目录。不要将平台默认路径误当成统一常量。

清单损坏时，当前操作会失败并清理相应缓存清单与校验文件，业务需要处理重试。已激活同版本时外层操作也会直接成功，因此发布内容改变时应分配新版本标识，避免同名版本缓存掩盖更新。

## 文件哈希如何支持更新与回滚 {#rollback}

假设 v2 清单的 Player 指向 AAA，v3 指向 BBB：

```text
v2：Player → PackageAsset → BundleGuid AAA
v3：Player → PackageAsset → BundleGuid BBB
```

激活 v3 后，本地只有 AAA 不满足 BBB 的要求，允许按需下载时补齐 BBB。AAA 与 BBB 可以同时留在磁盘。重新激活 v2 后，只要 AAA 未被清理，就可以复用旧文件。

版本间未变化的 Bundle 哈希相同，可以复用一份本地缓存。清单版本用于选择内容集合，缓存目录按文件内容标识组织，不会为每个 PackageVersion 复制一套 Bundle。

磁盘文件共存不表示可以随意热切换已加载对象。Provider 和 Loader 仍然持有当前加载结果，Loader 字典还按 BundleName 复用。切换清单前应结束旧内容使用并释放相关加载器，源码也对已有加载器时更新清单给出提示。

## CDN 按版本目录部署 {#cdn-layout}

可以采用业务定义的发布布局：

```text
CDN/Android/DefaultPackage/
├─ DefaultPackage.version
├─ v2/  清单、hash、完整 Bundle 集合
└─ v3/  清单、hash、完整 Bundle 集合
```

远端服务对 `.version` 返回根目录地址；查询得到目标版本后，业务固定本次版本，其他文件请求拼接该版本目录。这是业务 URL 路由约定，不是 YooAsset 自动添加的目录。

每次发布先上传完整版本目录，再更新根目录版本记录。下载期间不要中途改变服务对象的目标版本，否则 v3 清单可能去请求 v2 的文件。不同 Package 应维护独立路由状态。

## 首包是完整输出的一个副本子集 {#builtin-copy}

YooAsset 资源构建先产生完整发布资源，再按配置复制首包内容。关键参数片段：

```csharp
buildParameters.BuildOutputRoot =
    BundleBuilderHelper.GetDefaultBuildOutputRoot();
buildParameters.BundledFileRoot =
    BundleBuilderHelper.GetStreamingAssetsRoot();
buildParameters.BundledCopyOption =
    EBundledCopyOption.ClearAndCopyByTags;
buildParameters.BundledCopyParams = "builtin";
```

收集配置的 Group 或 Collector 可以给首包资源标记 `builtin`。构建逻辑会处理主资源与依赖 Bundle 的标签，再按 Bundle 标签复制。多个匹配标签使用分号分隔。

```text
Bundles/Android/DefaultPackage/v3/
    全部发布资源，包括首包 Bundle

Assets/StreamingAssets/yoo/DefaultPackage/
    选定的首包 Bundle、清单、版本、hash、Catalog
```

默认 SBP 窗口已经将构建输出与首包根目录分别设置好。Unity 构建 APK 是后续步骤，它把 StreamingAssets 纳入应用。上传完整发布输出时，首包 Bundle 同样在 CDN 上；客户端命中内置哈希后不需要重复下载。

`ClearAndCopyByTags` 先清理当前 Package 首包目录；`OnlyCopyByTags` 保留旧文件，重新划分首包时可能造成多余文件继续进入应用。复制以 Bundle 为单位，一个 Bundle 混入首包与非首包内容时，整个 Bundle 都会进入首包。

## Catalog 在复制之后生成 {#catalog-generation}

SBP 的任务顺序是 `TaskCopyBundledFiles_SBP` 后接 `TaskCreateCatalog_SBP`，首包复制选项为 None 时不执行该 Catalog 创建任务。Helper 扫描首包实际文件，通过 Manifest 映射得到 GUID，再生成 `BuiltinCatalog.bytes` 和 JSON 表示。

Catalog 描述实际内置集合，Manifest 描述完整资源版本。运行时读取内置根目录下固定名称 `BuiltinCatalog.bytes`，不需要遍历寻找文件。

## 进入游戏前补齐资源 {#predownload}

清单激活后，创建全 Package 或指定标签的下载器，检查缺失集合并等待下载结果。核心协程片段：

```csharp
var downloader = package.CreateResourceDownloader(
    new ResourceDownloaderOptions(10, 3));
if (downloader.TotalDownloadCount > 0)
{
    downloader.StartDownload();
    yield return downloader;
    if (downloader.Status != EOperationStatus.Succeeded)
    {
        Debug.LogError(downloader.Error);
        yield break;
    }
}
// 所需文件就绪后，再进入资源对象加载阶段。
```

下载完成只保证所需文件已经取得，不会提前实例化角色或把所有纹理加载进内存。离线场景也需要加载清单，只是版本及清单从内置资源读取，并且没有默认远端补齐能力。

## 源码阅读入口 {#source}

- [RequestRemotePackageVersionOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/FileSystem/Services/SandboxFileSystem/Operations/Internal/RequestRemotePackageVersionOperation.cs)
- [SFSLoadPackageManifestOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/FileSystem/Services/SandboxFileSystem/Operations/SFSLoadPackageManifestOperation.cs)
- [DeserializeManifestOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/Internal/DeserializeManifestOperation.cs)
- [TaskCopyBundledFiles.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Editor/BundleBuilder/BuildTasks/TaskCopyBundledFiles.cs)
- [BuiltinCatalogHelper.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleCache/Services/BuiltinBundleCache/BuiltinCatalogHelper.cs)
