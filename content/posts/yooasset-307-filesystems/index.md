---
title: "2. 文件系统、沙盒缓存与内置资源"
slug: yooasset-307-filesystems
date: 2026-11-19
lastmod: 2026-11-19
description: "追踪文件系统选择、缓存扫描、info 校验、内置 Catalog 与解包副本。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 2
draft: true
toc: true
---

联机模式中，同一次资源加载可能使用安装包内文件、以前下载的缓存，也可能触发新的下载。本文沿文件系统选择、索引初始化与本地文件布局，解释框架如何判断资源文件是否已经就绪。

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

## 文件系统抽象与沙盒目录 {#filesystem-and-sandbox}

操作系统提供应用可访问的存储空间及权限边界。YooAsset 的 `IFileSystem` 是 C# 层面的资源交付接口，负责判断是否能接收 Bundle、是否需要下载以及怎样加载文件。`SandboxFileSystem` 使用可写目录保存资源，不负责建立操作系统级的安全隔离。

默认联机模式配置 Builtin 与 Sandbox 两个文件系统。前者管理随应用交付的资源；后者管理下载、导入的本地缓存及远端获取。二者的存储方式和更新生命周期不同，因此分别实现，再通过统一接口组合。

## 谁提供一个 Bundle {#owner-selection}

Manifest 先给出 `PackageBundle` 描述，包含文件哈希、名称、大小等信息。`FileSystemHost.GetOwnerFileSystem` 再按注册顺序选择第一个接收者，以下摘录保留核心逻辑：

```csharp
for (int i = 0; i < _fileSystems.Count; i++)
{
    IFileSystem fileSystem = _fileSystems[i];
    if (fileSystem.CanAcceptBundle(packageBundle))
        return fileSystem;
}
```

Builtin 检查内置索引是否包含所需 `BundleGuid`；默认 Sandbox 返回 `true` 作为后备。沙盒接管后再判断使用缓存还是下载，不会继续转给另一个独立的 CDN 文件系统。

```text
当前清单要求 BundleGuid BBB
    → Builtin 有 BBB：内置系统处理
    → Builtin 没有 BBB：Sandbox 处理
         → 缓存有 BBB：本地加载
         → 缓存没有 BBB：按配置下载，或返回失败
```

清单决定找什么，文件系统的顺序与 `CanAcceptBundle` 决定谁提供。它不在清单中预先写死“这个文件必须从沙盒加载”。

## 沙盒文件布局与缓存字典 {#cache-layout}

当前实现 `PackageBundle.BundleGuid` 直接返回 `FileHash`，与清单中的整数 `BundleID` 不同。假设文件哈希简写为 `abcd`：

```text
Package 根目录/
├─ BundleFiles/
│  └─ ab/                 ← 哈希前两位分片
│     └─ abcd/            ← 完整 BundleGuid
│        ├─ __data        ← Bundle 数据
│        └─ __info        ← 缓存元信息
├─ ManifestFiles/
└─ TempFiles/
```

运行时可用文件登记在 `SandboxBundleCache._cacheEntries` 中：

```csharp
public bool IsCached(string bundleGuid)
{
    return _cacheEntries.ContainsKey(bundleGuid);
}
```

这个判断只查询索引，不会每次加载都扫描磁盘或计算哈希。索引是内存对象，`__data` 是磁盘文件，不能将这两层缓存混为一谈。

## 初始化如何重建索引 {#scan-and-verify}

`SandboxFileSystem.OnCreate` 确定路径并创建 `SandboxBundleCache` 对象，之后异步初始化才进行扫描：

```text
SFSInitializeOperation
    → BundleCache.InitializeAsync
    → SBCInitializeOperation
         → SearchCacheFilesOperation
         → VerifyCacheFilesOperation
         → AddEntry
```

扫描范围是当前缓存实例的 Bundle 根目录，不是整个应用沙盒。扫描器枚举分片目录下的 BundleGuid 目录，以目录名为标识，收集数据、信息文件路径。校验通过后登记缓存，失败的条目会清理。旧版本残留文件也可能被扫描；这一步不要求它们都属于当前激活清单。

初始化扫描分帧推进，文件校验任务通过线程池执行，结果再由主线程分帧登记。异步执行降低主线程连续占用，但 Package 初始化仍需要等待它完成。

## __info 到底保存什么 {#info-format}

当前信息文件写入六个字段，共 36 字节：

| 字段 | 字节数 | 含义 |
| --- | ---: | --- |
| InfoFileMagic | 4 | `YOC1` 文件头标识 |
| InfoFileVersion | 4 | 信息文件格式版本，目前为 1 |
| FileCrc | 4 | 数据文件预期 CRC32 |
| FileSize | 8 | 数据文件预期大小 |
| CreatedAtTicks | 8 | 创建时间 |
| LastAccessAtTicks | 8 | 最后访问时间记录 |

写入缓存时，CRC 和大小来自目标 Bundle 的清单描述，两个时间初始值来自 `DateTime.UtcNow.Ticks`。`__info` 不保存 BundleGuid，目录名与信息文件之间没有“两个 GUID 对比”的步骤。

所有初始化校验等级都会读取 `__info`：

| 等级 | 检查 |
| --- | --- |
| Low，默认 | `__data`、`__info` 存在，信息文件长度、文件头、格式版本有效 |
| Middle | 再比较数据文件实际大小 |
| High | 再计算数据文件 CRC32 与记录值比较 |

`FileVerifyHelper` 将大小或 CRC 为零视为对应检查不启用。正常配置下 High 需要读取文件内容；Low、Middle 不重新计算内容哈希。即使 High 也不是重算 `FileHash` 与目录名比较。

下载完成后的缓存写入是另一条路径：临时文件按清单给定信息验证，写入正式 `__data`、`__info`，最后才 `AddEntry`。临时下载文件不能直接算作有效缓存。

## 内置目录为何不用同样扫描 {#builtin-catalog}

`BuiltinBundleCache` 通过预先生成的 `BuiltinCatalog.bytes` 建立索引。它位于内置 Package 根目录，每项保存 `BundleGuid` 和实际 `FileName`。

```text
加载 Catalog
    → 遍历 Entries
    → RootPath + FileName
    → 登记 BundleGuid 对应的路径
```

这个登记过程不逐个读取 Bundle 做 CRC 校验。安装包内容在发布时已经确定，而且部分平台不支持像普通目录那样枚举安装包内部文件。Catalog 将“发现有哪些文件”的工作提前到了构建阶段。

## Builtin 为什么还有解包缓存 {#unpack-cache}

Builtin 内部还持有 `UnpackBundleCache`，实际类型同样是 `SandboxBundleCache`，但根目录用于保存内置文件的解包副本。这部分会走目录扫描与信息校验流程。

资源在安装包内存在，不代表所有加载器都能直接用文件流访问。当前默认解包策略在 Android、OpenHarmony 编译目标上，对加密 Bundle、RawBundle、ArchiveBundle 返回需要解包；其他情况默认直接加载。可以通过 `IBundleUnpackPolicy` 替换策略。

```text
BuiltinFileSystem
├─ BuiltinBundleCache：安装包原件，读取 Catalog
└─ UnpackBundleCache：可写目录副本，扫描并校验

SandboxFileSystem
└─ BundleCache：下载缓存，扫描并校验
```

需要解包时，先检查副本是否存在，已有则直接加载，否则提取、校验并写入后加载。初始化副本索引不意味着立即解包全部内置内容。这里“解包”是提取文件，仍可能保留加密数据，后续再按解密器处理。

## 索引的有效性边界 {#index-boundary}

`IsCached` 信任内存登记结果。如果业务绕开框架直接删除磁盘文件，索引不会因为每次查询而自动重新校验；后续加载仍可能失败。文件存在性检查、内容完整性检查与加载失败处理属于不同阶段。

## 源码阅读入口 {#source}

- [FileSystemHost.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/FileSystemHost.cs)：选择资源文件的提供者。
- [SBCInitializeOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleCache/Services/SandboxBundleCache/Operations/SBCInitializeOperation.cs)：扫描与校验编排。
- [VerifyCacheFilesTask.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleCache/Services/SandboxBundleCache/Operations/Internal/VerifyCacheFilesTask.cs)：各校验等级的实际分支。
- [SBCWriteCacheOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleCache/Services/SandboxBundleCache/Operations/SBCWriteCacheOperation.cs)：信息写入与缓存登记。
- [BBCInitializeOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/BundleCache/Services/BuiltinBundleCache/Operations/BBCInitializeOperation.cs)：Catalog 索引建立。
- [DefaultBundleUnpackPolicy.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/FileSystem/Policies/DefaultBundleUnpackPolicy.cs)：平台与类型判断。
