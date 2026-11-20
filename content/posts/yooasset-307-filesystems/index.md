---
title: "3. 文件系统、沙盒缓存与内置资源"
slug: yooasset-307-filesystems
date: 2026-11-19
lastmod: 2026-11-20
description: "从清单中的 Bundle 描述出发，分析文件系统归属、内置与沙盒索引初始化，以及缓存命中、下载入库和解包读取流程。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 3
draft: false
toc: true
---

## 从清单描述到文件系统 {#filesystem-and-sandbox}

Manifest 已经把资源地址转换为主 Bundle 和依赖 Bundle 的描述。每个 PackageBundle 都给出了名称、文件哈希、大小等信息，但这些描述还不能说明文件在当前设备上的位置。

同一个 Bundle 可能随应用安装，也可能在之前的运行中下载过，还可能尚未存在于本地。文件系统负责根据这些情况提供文件，并接入相应的 Bundle 加载操作。本篇以原生平台的默认联机组合 BuiltinFileSystem 与 SandboxFileSystem 为主线，分析文件归属、索引初始化和文件获取过程。

先区分三个层次：

| 层次 | 负责什么 |
| --- | --- |
| FileSystemHost | 管理当前 Package 的文件系统列表，为 Bundle 选择提供者 |
| IFileSystem | 定义版本查询、清单读取、Bundle 获取和加载等统一接口 |
| BundleCache | 管理某种来源的文件条目，提供文件查询、加载及相应缓存操作 |

这里的文件系统是 YooAsset 的资源访问抽象，不等同于操作系统文件系统。“沙盒”在本章主要指应用可写的资源存储区域；SandboxFileSystem 使用这样的目录保存下载内容，并不负责创建操作系统级的安全隔离。

默认联机配置将安装包内容与下载内容分开管理，因为前者随应用交付，后者可以在运行期间写入、更新或清理。对上层而言，两者都通过 IFileSystem 接入同一个 Package。

## FileSystemHost 怎样选择提供者 {#owner-selection}

`FileSystemHost` 得到 PackageBundle 后，会调用 `CreateBundleInfo`，为描述选择文件系统，再将两者包装为 BundleInfo：

```text
ActiveManifest 查询 PackageBundle
    → CreateBundleInfo
    → GetOwnerFileSystem
    → new BundleInfo(fileSystem, packageBundle)
```

`GetOwnerFileSystem` 的核心逻辑是按注册顺序查找第一个接收者：

```csharp
for (int i = 0; i < _fileSystems.Count; i++)
{
    IFileSystem fileSystem = _fileSystems[i];
    if (fileSystem.CanAcceptBundle(packageBundle))
    {
        return fileSystem;
    }
}
```

默认联机模式先注册 Builtin，再注册 Sandbox。两者对 `CanAcceptBundle` 的实现不同：

```csharp
// BuiltinFileSystem
public bool CanAcceptBundle(PackageBundle bundle)
{
    return BuiltinBundleCache.IsCached(bundle.BundleGuid);
}

// SandboxFileSystem
public bool CanAcceptBundle(PackageBundle bundle)
{
    return true;
}
```

Builtin 通过内置索引判断它是否包含清单要求的文件；Sandbox 则接管剩余 Bundle。这里比较的是 BundleGuid，即当前实现中的 FileHash，不是业务 Address，也不是 BundleName。

例如当前清单要求 `characters.bundle` 的哈希为 BBB，而安装包只有同名 Bundle 的旧文件 AAA，Builtin 就不会接收 BBB。即使业务仍然加载同一个 Player 地址，所需文件也由当前清单决定。

**CanAcceptBundle 判断的是由谁负责，不能统一解释为文件已经在本地。** Sandbox 返回 true 时，文件可能已经缓存，也可能还需要下载。选定 Sandbox 后，由它完成后续判断，不会再把请求转交给另一套独立的“CDN 文件系统”。

这与清单加载入口也不同：清单使用注册列表最后一项作为主文件系统；Bundle 则逐项调用 CanAcceptBundle，为主 Bundle 和每个依赖 Bundle 分别选择提供者。

## 联机模式中的资源来源与读取方式 {#resource-sources}

FileSystemHost 已经将请求交给具体文件系统。要理解 Builtin 和 Sandbox 为什么这样分工，需要先看联机模式中的资源如何到达客户端，以及到达后如何读取。

资源有两种交付方式：一部分随应用安装，另一部分在运行时从服务器下载。随应用安装的资源又存在两种读取路径：能够直接访问的使用包内原件；受平台、文件类型或解密方式限制的，需要先提取到可写目录，再从副本读取。

```text
联机模式中的资源
├─ 随应用安装
│  ├─ 可以直接读取 → 使用包内原件
│  └─ 需要先解包   → 提取到可写目录，使用副本
│
└─ 后续下载
   └─ 下载到可写目录，使用本地缓存
```

包内原件和解包副本可能是同一个 Bundle 的两种存放形态。解包是提取副本，安装包中的原件仍然存在；也不是所有随包资源都必须解包。

这样便出现了三类需要管理的文件：安装包原件、解包副本和下载文件。原件在应用发布时确定，可以预先记录其目录；后两者都写入可写目录，会随着运行而增加或被清理，需要恢复、校验和维护本地文件记录。

## 文件系统与缓存对象如何对应这些资源 {#resource-management}

YooAsset 根据上述来源和存储需求组织管理对象：

```text
BuiltinFileSystem：管理随包资源及其读取方式
├─ BuiltinBundleCache：登记安装包原件
└─ UnpackBundleCache：管理解包副本
     实际类型为 SandboxBundleCache

SandboxFileSystem：管理后续下载、导入的资源
└─ BundleCache：管理本地缓存文件
     实际类型为 SandboxBundleCache
```

BuiltinFileSystem 负责随包资源的直接读取与解包读取。SandboxFileSystem 负责远端获取及下载缓存。两者并不是按“文件是否位于可写目录”划分归属，因此解包副本仍然由 BuiltinFileSystem 管理。

解包副本与下载文件有相同的本地存储需求，所以复用 SandboxBundleCache 实现文件布局、校验和索引管理。这里复用的是实现类型，每个文件系统分别持有自己的缓存实例、根目录和 Entry 字典。

因此，阅读源码时需要分清两个名称：SandboxFileSystem 是文件系统实现；SandboxBundleCache 是可写文件缓存实现，也能被 BuiltinFileSystem 使用。下面先交代这些对象的初始化顺序，再分别看原件登记、解包判断与可写缓存的处理。

## 索引初始化 {#initialization-order}

`InitializeFileSystemOperation` 已经创建并初始化了文件系统。对应到默认联机组合，主干顺序是：

```text
创建 BuiltinFileSystem → BFSInitializeOperation
    → 初始化内置资源索引
    → 初始化解包副本索引

创建 SandboxFileSystem → SFSInitializeOperation
    → 初始化下载缓存索引

Package 初始化完成
    → 后续加载、激活目标 Manifest
    → 根据 PackageBundle 查询上述索引
```

因此，缓存索引的建立不依赖本次激活的 Manifest。索引记录当前文件来源里有哪些文件；清单激活后，再描述本次需要哪些文件。这也解释了为什么磁盘上属于旧资源版本的文件仍可能被登记到缓存中。

两种文件系统初始化时还会检查平台、处理应用安装标记，并按配置执行覆盖安装后的缓存清理；随后建立缓存索引，最后创建下载或解包调度器。Builtin 还包含可配置的内置清单复制步骤。复制文件只是准备本地数据，不等于将其设置为 ActiveManifest。

下面分别看内置内容和可写缓存如何建立索引。两者的内容来源不同，因此发现文件的方式也不同。

## 内置资源：通过 Catalog 建立索引 {#builtin-catalog}

安装包资源在发布时已经确定。YooAsset 在构建交付阶段生成 `BuiltinCatalog.bytes`，让运行时直接读取这个目录文件，而不必枚举安装包内部的所有 Bundle。

Catalog 位于内置 Package 根目录。默认目录结构可表示为：

```text
StreamingAssets/yoo/DefaultPackage/
    BuiltinCatalog.bytes
    首包 Bundle 文件
    随包交付的清单、版本和校验文件
```

这里的根目录可以配置，运行时通过缓存对象计算 Catalog 的加载路径。Android 等平台的 StreamingAssets 可能位于应用归档中，不能将上述结构一概视为可用普通文件 API 遍历的目录。

`BuiltinCatalog` 的主体信息如下：

| 内容 | 含义 |
| --- | --- |
| FileVersion | Catalog 格式版本 |
| PackageName、PackageVersion | 生成时对应的 Package 和资源版本 |
| Entries | 内置文件列表，每项包含 BundleGuid 与 FileName |

它与 Manifest 的职责不同：Manifest 描述一个资源版本的地址、依赖和完整文件集合，Catalog 描述实际随包交付的文件集合。首包只包含部分 Bundle 时，两者覆盖的范围自然不同。

以 SBP 构建流程为例，首包复制之后执行 Catalog 创建任务。`BuiltinCatalogHelper.CreateFile` 读取该目录中的版本与清单，建立文件名到 BundleGuid 的映射，再根据目录内实际文件生成条目。具体首包配置留到资源交付篇展开。

运行时由 `BBCInitializeOperation` 读取 Catalog，随后登记每一项：

```csharp
foreach (var fileEntry in catalog.Entries)
{
    string filePath = PathUtility.Combine(_fileCache.RootPath, fileEntry.FileName);
    var cacheEntry = new BuiltinBundleCacheEntry(fileEntry.BundleGuid, filePath);
    _fileCache.AddEntry(fileEntry.BundleGuid, cacheEntry);
}
```

这样便建立了 `BundleGuid → 内置文件条目` 的关系。这里不会逐个打开 Bundle 计算 CRC，也不会为每个内置 Bundle 读取一份 `__info`。

这份索引还可以服务于后续的新清单：如果新清单仍要求同一哈希的 Bundle，内置文件依然可以满足请求。Builtin 的归属判断不要求 Catalog 的 PackageVersion 与当前 Manifest 的版本字符串相同。

## Builtin 的另一份索引：解包副本 {#unpack-cache}

Catalog 登记了包内原件，接下来要判断是否能够直接读取。需要先提取的文件由 BuiltinFileSystem 的 `UnpackBundleCache` 保存，其实现类型是前面介绍的 SandboxBundleCache。

为什么安装包已经有文件，还需要副本？因为部分平台的内置资源位于应用归档中，某些 Bundle 类型或解密方式需要普通文件路径或流访问。默认策略由 `DefaultBundleUnpackPolicy` 决定：

| 编译目标与条件 | 默认结果 |
| --- | --- |
| Android 或 OpenHarmony，文件加密 | 需要解包 |
| Android 或 OpenHarmony，RawBundle 或 ArchiveBundle | 需要解包 |
| 上述平台的其他情况 | 不解包 |
| 其他编译目标 | 不解包 |

这个策略结合当前平台、清单提供的加密标记与 Bundle 类型判断，也可以通过 `IBundleUnpackPolicy` 替换。

`BFSInitializeOperation` 先建立 Catalog 索引，再初始化解包缓存。后一部分只恢复已经存在的副本记录，不会在初始化时解包所有内置 Bundle。需要的新副本在后续获取文件时再生成。

至此，安装包原件通过 Catalog 登记，解包条件由策略决定。剩下的共同问题是：解包副本和后续下载文件如何保存在可写目录，以及每次启动如何恢复它们的索引。下面进入两条路径共用的 SandboxBundleCache。

## 可写文件缓存的目录布局 {#cache-layout}

BuiltinFileSystem 为解包副本创建一个 SandboxBundleCache，SandboxFileSystem 为下载缓存创建另一个。对象创建时，内存中的 `_cacheEntries` 尚未通过扫描填充；各自的 RootPath 下则可能保留着以前解包、下载或导入的文件。

两个实例使用相同的目录组织方式。假设 BundleGuid 简写为 `abcd`，每个缓存根目录下的布局是：

```text
RootPath/
└─ ab/                 哈希前两位形成的分片目录
   └─ abcd/            完整 BundleGuid
      ├─ __data        Bundle 文件内容
      └─ __info        缓存元信息
```

对于 SandboxFileSystem 的下载缓存，RootPath 指向 Package 根目录下的 `BundleFiles`；对于 BuiltinFileSystem 的解包副本，RootPath 指向它配置的解包文件目录。共享结构不表示共享同一个目录或同一份缓存字典。

`__data` 和 `__info` 是当前实现中的固定名称，与构建时的发布文件名无关。FileHash 决定条目的身份，PackageVersion 不直接作为 Bundle 缓存目录的层级。

这些文件可以跨应用运行保留。初始化接下来要搜索各自根目录中的文件，校验后将它们登记到本次运行的 Entry 字典；如果尚未产生任何缓存文件，搜索结果也可以为空。

## 可写缓存初始化：搜索、校验，再登记 {#scan-and-verify}

Builtin 的解包缓存和 Sandbox 的下载缓存，分别由各自文件系统的初始化操作调用 `InitializeAsync`，随后进入相同的缓存初始化实现：

```text
UnpackBundleCache.InitializeAsync 或 BundleCache.InitializeAsync
    → SBCInitializeOperation
        → SearchCacheFilesOperation
        → VerifyCacheFilesOperation
            → VerifyCacheFilesTask
            → 处理结果：AddEntry 或清理无效目录
```

`SearchCacheFilesOperation` 先取得 RootPath 下的分片目录，再枚举各分片里的 Bundle 目录。对每个尚未登记的目录，取其目录名作为 BundleGuid，拼出 `__data` 与 `__info` 路径，生成待校验的 SearchFileInfo。

搜索并不验证文件内容，也不根据 Manifest 筛选版本。它只回答“这里发现了哪些缓存候选项”。目录枚举保留跨帧状态，并检查时间片预算；这不意味着整个目录搜索都在后台线程运行。

随后，`VerifyCacheFilesOperation` 将候选项交给线程池中的校验任务。校验任务结束后，主线程分帧处理每个结果：

```text
条目校验通过
    → 创建 SandboxBundleCacheEntry
    → AddEntry(BundleGuid, entry)

条目校验不通过
    → 清理该缓存目录
    → 不登记为可用缓存
```

个别文件不通过校验，与整个校验任务执行失败要区分。前者可以作为无效条目被清理，其余有效文件仍然登记；后台任务自身失败时，操作会返回错误。Package 初始化仍需等待这个过程完成。

既然这时不依赖当前 Manifest，文件大小和 CRC 从哪里取得？答案是每个条目旁边的 `__info`。

## __info 与校验等级 {#info-format}

`SBCWriteCacheOperation` 写入缓存时，将 Bundle 的校验描述与时间信息一同保存。当前写出的信息文件为 36 字节：

| 字段 | 字节数 | 含义 |
| --- | ---: | --- |
| InfoFileMagic | 4 | `YOC1` 文件标记 |
| InfoFileVersion | 4 | 信息格式版本，当前为 1 |
| FileCrc | 4 | 数据文件的预期 CRC32 |
| FileSize | 8 | 数据文件的预期大小 |
| CreatedAtTicks | 8 | 创建时间记录 |
| LastAccessAtTicks | 8 | 最近访问时间记录 |

CRC 和大小来自写入操作收到的 PackageBundle；两个时间字段在初次写入时都使用 `DateTime.UtcNow.Ticks`。初始化读取这些字段时，不会用时间值判断文件内容是否正确。

`__info` 不保存 BundleGuid。扫描从目录名取得 GUID，信息文件提供本地校验依据，两者之间没有“对比两份 GUID”的步骤。

`VerifyCacheFilesTask.VerifyFile` 在所有等级下都会检查两个文件存在，并读取信息文件。当前长度检查是“至少 36 字节”，随后核对文件标记和格式版本，再按等级处理数据文件：

| 等级 | 对数据文件的检查 |
| --- | --- |
| Low，默认 | 在上述基础检查通过后返回成功，不比较内容大小和 CRC |
| Middle | 用信息文件中的大小校验数据文件 |
| High | 用信息文件中的大小和 CRC 校验数据文件 |

核心分支如下：

```csharp
if (verifyLevel == EFileVerifyLevel.Low)
    return EFileVerifyResult.Succeed;
else if (verifyLevel == EFileVerifyLevel.Middle)
    return FileVerifyHelper.VerifyFile(element.DataFilePath, dataFileSize, 0);
else if (verifyLevel == EFileVerifyLevel.High)
    return FileVerifyHelper.VerifyFile(element.DataFilePath, dataFileSize, dataFileCRC);
```

`FileVerifyHelper` 中只有预期大小、CRC 大于零时才执行对应比较，零值表示跳过该项。High 通常需要读取整个数据文件计算 CRC，但仍不是重算 FileHash 并与目录名比较。

因此，“初始化扫描本地缓存”不等于“启动时为所有 Bundle 重算哈希”。严格程度由配置控制，初始化所依据的是本地缓存元信息，而非刚从服务器取得的新清单。

## 初始化结果：Entry 字典如何支持后续查询 {#cache-entries}

校验通过后，`VerifyCacheFilesOperation` 才将候选文件转换为正式缓存条目：

```csharp
var cacheEntry = new SandboxBundleCacheEntry(
    verifyElement.BundleGuid,
    verifyElement.InfoFilePath,
    verifyElement.DataFilePath);
_fileCache.AddEntry(verifyElement.BundleGuid, cacheEntry);
```

Entry 记录文件标识和路径，不是把整个 Bundle 数据读进字典。`AddEntry` 将它登记到 `_cacheEntries`，于是磁盘数据与本次运行的内存索引连接起来：

```text
当前缓存目录中已有的 __data、__info
    → 初始化搜索：生成 SearchFileInfo 候选项
    → 校验通过：创建 SandboxBundleCacheEntry
    → AddEntry：登记到 _cacheEntries
    → 后续 IsCached：按 BundleGuid 查询
```

`IsCached` 的实现因此只需要查询字典：

```csharp
public bool IsCached(string bundleGuid)
{
    return _cacheEntries.ContainsKey(bundleGuid);
}
```

## 选定文件系统后，如何取得 Bundle {#obtain-bundle}

现在两类索引都已建立，可以回到本章开头的请求：清单要求 BundleGuid BBB，FileSystemHost 先确定负责它的文件系统，随后进入该文件系统的加载操作。

### Sandbox：命中缓存或获取缺失文件 {#sandbox-load}

`SFSLoadPackageBundleOperation` 在 Prepare 阶段查询 `BundleCache.IsCached`：

```text
BBB 已缓存
    → BundleCache.LoadBundleAsync

BBB 未缓存
    ├─ DisableOnDemandDownload 开启：返回缺少缓存的错误
    └─ 允许按需下载：DownloadBundleAsync
         → 下载并写入缓存
         → BundleCache.LoadBundleAsync
```

远端 URL 来自业务配置的 `IRemoteService.GetRemoteUrls(bundle.GetFileName())`。下载器取得文件后，`DownloadAndCacheFileOperation` 调用缓存的写入操作；清单描述提供期望大小和 CRC。

`SBCWriteCacheOperation` 的主干是：

```text
校验取得的临时文件
    → 准备目标 BundleGuid 目录
    → 写入 __data.tmp 和 __info.tmp
    → 分别替换正式的 __data 和 __info
    → AddEntry 登记内存索引
```

新文件成功写入后立即登记，因此本次运行无需重新扫描整个缓存目录。下次启动再通过扫描恢复同一条记录。

写入前的临时文件校验与启动时的 Low/Middle/High 分支是两条路径，不能用默认 Low 推断“下载文件入库时也不校验大小或 CRC”。另外，数据和信息文件是分别提交的，并非两个文件共同构成一个不可分割的事务；中途失败时不会继续正常登记，重新启动后的扫描会按配置检查磁盘条目。

### Builtin：直接读取或先提取副本 {#builtin-load}

`BFSLoadPackageBundleOperation` 则先调用解包策略：

```text
不需要解包
    → BuiltinBundleCache.LoadBundleAsync

需要解包
    ├─ 副本已缓存：UnpackBundleCache.LoadBundleAsync
    └─ 副本未缓存：提取内置文件 → 校验、写入副本缓存 → 加载
```

这里的提取通过 Builtin 的下载操作接口进入，但来源是安装包中的文件，不是因为方法叫 Download 就一定访问 CDN。解包的含义是取得可访问的文件副本，不等同于解密；加密内容后续仍需要相应解密加载流程处理。

## 文件索引、清单与加载结果的边界 {#index-boundary}

至此，一次文件选择可以连起来看：

```text
Manifest：本次需要 BBB
    → FileSystemHost：Builtin 能否提供 BBB？
        ├─ 能：直接读取，或通过解包副本读取
        └─ 不能：交给 Sandbox
             ├─ 已缓存：本地读取
             └─ 未缓存：允许时下载、校验并登记，再读取
```

Manifest 描述目标文件，Catalog 或缓存索引描述某个来源可提供的文件，Bundle 加载操作再实际取得加载结果。它们分别回答不同问题。