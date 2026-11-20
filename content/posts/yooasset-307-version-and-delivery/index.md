---
title: "4. 资源版本、清单与首包交付"
slug: yooasset-307-version-and-delivery
date: 2026-11-19
lastmod: 2026-11-20
description: "沿构建输出、首包复制、CDN 发布与客户端预下载，分析资源版本选择、缓存复用和回滚边界。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 4
draft: false
toc: true
---

## 从文件管理到资源交付 {#delivery-overview}

本篇以 `DefaultPackage` 从 v2 更新到 v3 为例，沿着构建输出、首包复制、CDN 发布、版本选择和文件补齐展开, 重点关注这些机制怎样组成一次资源交付。

```text
构建 DefaultPackage / v3
    → 生成完整发布文件
        ├─ 复制首包子集 → 随应用安装
        └─ 上传发布内容 → CDN
    → 发布端提供目标版本
    → 客户端取得并激活对应清单
    → 复用内置文件与已有缓存，补齐缺失文件
```

这条流程中，构建、复制、查询和下载有框架对应的实现；上传 CDN、何时切换发布版本以及选择哪一版资源，则需要业务的发布流程协调。

## 一次构建产生哪些发布文件 {#release-files}

构建参数中的 `PackageName` 表示资源集合，`PackageVersion` 表示这次发布标识。资源版本由业务指定，不要求与应用安装包版本一致，也不等于任何一个 Bundle 的文件哈希。

默认没有文件名前缀时，`DefaultPackage / v3` 的主要产物为：

```text
DefaultPackage.version     内容为 v3，供版本查询
DefaultPackage_v3.bytes    v3 的资源清单
DefaultPackage_v3.hash     v3 清单的校验信息
各 Bundle 文件             按构建命名规则输出
```

`TaskCreateManifest.CreateManifestFile` 写出清单后，计算清单文件的 CRC32 并写入 `.hash`，再将 `PackageVersion` 写入 `.version`。这里的 `.hash` 验证清单文件本身；Bundle 的哈希、大小与 CRC 则记录在清单中。

两个目录配置分别负责完整输出和首包内容：

| 配置 | 用途 |
| --- | --- |
| BuildOutputRoot | 资源构建输出根目录 |
| BundledFileRoot | 首包资源复制根目录 |

`BuildParameters` 默认按以下规则计算路径：

```text
发布输出：BuildOutputRoot / BuildTarget / PackageName / PackageVersion
首包目录：BundledFileRoot / PackageName
```

使用默认 Helper，Android 平台可以得到：

```text
工程/Bundles/Android/DefaultPackage/v3/
工程/Assets/StreamingAssets/yoo/DefaultPackage/
```

因此，划分首包不是先把构建输出改到 StreamingAssets。完整发布内容有自己的目录，首包是随后从其中复制出的子集。默认构建窗口会设置这两类根目录；是否执行首包复制，还取决于复制选项。

## 从完整输出中复制首包资源 {#builtin-copy}

首包的含义是“随应用交付哪些 Bundle”。例如启动 UI 和公共配置需要在启动阶段可用，可以给相应资源设置 `builtin` 标签，再通过构建选项指定复制范围。

下面是构建参数片段，其他平台、管线及 Package 参数由构建脚本提供：

```csharp
buildParameters.BuildOutputRoot = BundleBuilderHelper.GetDefaultBuildOutputRoot();
buildParameters.BundledFileRoot = BundleBuilderHelper.GetStreamingAssetsRoot();
buildParameters.BundledCopyOption = EBundledCopyOption.ClearAndCopyByTags;
buildParameters.BundledCopyParams = "builtin";
```

`TaskCopyBundledFiles.CopyBundledFilesToStreaming` 先按选项处理目标目录，然后复制清单、清单校验文件与版本文件，最后选择要复制的 Bundle。

| 复制选项 | 行为 |
| --- | --- |
| None | 跳过本次首包复制，不自动清理已有首包文件 |
| ClearAndCopyAll | 清理当前 Package 首包目录，再复制全部 Bundle |
| ClearAndCopyByTags | 清理当前 Package 首包目录，再按标签复制 Bundle |
| OnlyCopyAll / OnlyCopyByTags | 执行相应复制，保留原目录中的其他文件 |

按标签复制的核心判断是：

```csharp
string[] tags = copyParams.Split(';');
foreach (var buildBundle in manifest.BundleList)
{
    if (buildBundle.HasAnyTag(tags) == false)
        continue;
    // 将该 Bundle 从完整输出复制到首包目录。
}
```

多个标签用分号分隔，匹配任意一个标签即可。这里筛选的是 Bundle，不是逐个 Prefab 或 Texture 复制；同一个 Bundle 中只要包含被选入首包的内容，复制时就是整个文件。

### 资源标签怎样影响依赖 Bundle {#builtin-tags}

资源的标签来自收集配置，但实际复制读取的是 Bundle 标签。两者通过清单构建中的 `ProcessBundleTags` 连接：它将资源的标签加入主 Bundle，并传播到该资源描述中的依赖 Bundle，最后汇总到各 Bundle 的标签集合中。

因此，一个带 `builtin` 标签的启动界面需要的共享纹理 Bundle，也可能随之进入首包。共享 Bundle 的标签会汇集多个使用方的需求，首包大小不仅受标签选择影响，也受资源依赖和打包粒度影响。

重新划分首包时，如果使用保留旧文件的 OnlyCopy 选项，曾经复制的 Bundle 可能继续留在 StreamingAssets 中。None 也只是跳过复制。需要构建结果准确反映当前选择时，应明确采用相应的清理和复制策略。

复制完成后，完整输出中的文件仍然存在；首包复制不会把它们移走。于是同一个 Bundle 可以同时出现在完整输出和首包目录中。

## 复制之后生成 Catalog，再构建应用 {#catalog-generation}

SBP 的 YooAsset 构建任务中，相关顺序是：

```text
TaskCreateManifest_SBP
    → TaskCreateReport_SBP
    → TaskCreatePackage_SBP
    → TaskCopyBundledFiles_SBP
    → TaskCreateCatalog_SBP
```

首包复制选项不是 None 时，复制任务才执行，Catalog 任务也才生成内置目录记录。`BuiltinCatalogHelper` 根据首包目录中的实际文件与清单映射，生成 `BuiltinCatalog.bytes` 及其 JSON 表示。

最终首包目录中包含的是选定的 Bundle，加上完整资源清单、版本、校验文件和内置 Catalog。清单不会因为只复制了部分 Bundle，就自动裁剪成仅包含首包资源的清单；Catalog 才负责记录实际内置的文件集合。

到这里完成的是 YooAsset 的资源构建与复制。Unity 构建 APK 或其他应用安装包是后续步骤，它将 StreamingAssets 中的文件带入应用。客户端启动后，第三章介绍的 Builtin 文件系统才能通过 Catalog 登记这些内置文件。

## CDN 发布目录与请求地址如何对应 {#cdn-layout}

后续下载需要服务器提供清单及其引用的 Bundle。可以将完整发布输出部署到 CDN，也可以按业务设计组织目录；无论怎样组织，客户端请求到的文件必须与目标清单一致。

一种常见布局是为每个版本保存完整文件集合：

```text
CDN/Android/DefaultPackage/
├─ DefaultPackage.version          当前发布选择，例如 v3
├─ v2/
│  ├─ DefaultPackage_v2.bytes
│  ├─ DefaultPackage_v2.hash
│  └─ v2 所需的全部 Bundle
└─ v3/
   ├─ DefaultPackage_v3.bytes
   ├─ DefaultPackage_v3.hash
   └─ v3 所需的全部 Bundle
```

构建生成的 `.version` 原本也位于该次发布输出中。将它放到上述公共根目录、覆盖为当前发布选择，是部署流程的动作，YooAsset 不会自动上传或维护 CDN 上的这个入口。

### RemoteService 负责文件名到 URL 的映射 {#remote-routing}

默认 Sandbox 使用业务实现的 `IRemoteService` 查询候选地址：

```csharp
IReadOnlyList<string> GetRemoteUrls(string fileName);
```

接口接收的是文件名，没有单独的 PackageVersion 参数。采用上面的目录布局时，业务需要让对应 Package 的远端服务知道本次选定的版本，或者通过其他明确的路由规则定位文件。

例如，选定 v3 后的映射为：

| 请求的文件名 | 业务返回的地址路径 |
| --- | --- |
| DefaultPackage.version | 公共根目录/DefaultPackage.version |
| DefaultPackage_v3.bytes | 公共根目录/v3/DefaultPackage_v3.bytes |
| DefaultPackage_v3.hash | 公共根目录/v3/DefaultPackage_v3.hash |
| 某个 Bundle 文件名 | 公共根目录/v3/该文件名 |

版本查询返回后，要先固定资源请求使用的 v3 路由，再开始加载清单和下载。Bundle 文件名不一定包含资源版本，因此不能仅靠分析 Bundle 文件名恢复应该请求哪个版本目录。

直接指定 v3 时同样要准备好这份路由状态。后续请求进行期间不应随意将它改为 v2，否则可能出现用 v3 清单去 v2 目录请求文件的情况。多 Package 的版本路由也应分别管理。

### 发布顺序与缓存策略 {#release-order}

按版本目录发布时，合理的流程是先上传 v3 所需的完整文件，确认客户端能够取得这些文件，再更新公共根目录中的版本入口。这样客户端读到 v3 时，相关文件已经可用。

不变的版本目录适合长期缓存；会改变的版本入口则需要相应的 CDN 缓存刷新或有效期策略。默认版本查询会附加时间参数，但 CDN 是否据此区分缓存仍取决于服务配置，不能把客户端加参数等同于服务器一定返回新内容。

首包 Bundle 也可以保留在 CDN 的完整版本目录中。客户端是否下载，取决于当前清单要求的文件能否从内置索引或下载缓存中获得，而不是“CDN 上有这个文件就必须下载”。这也让不同安装包基线的客户端能够从同一资源版本取得各自缺少的文件。

## 客户端如何确定本次目标版本 {#select-version}

Package 初始化完成后，默认联机配置通过主文件系统 Sandbox 查询远端版本：

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

`RequestRemotePackageVersionOperation` 通过 RemoteService 得到版本文件 URL，再由下载后端读取文本。当前操作将结果保存在 PackageVersion 中，没有将这个远端 `.version` 写入 Sandbox 缓存目录的步骤。

`.version` 表达发布端的选择，并不对版本字符串排序。其内容是 v2，客户端就取得 v2，不会扫描 CDN 目录寻找更大的版本号。

业务也可以从自己的发布配置中得到目标版本，省略以上查询。确定版本及对应 URL 路由后，将它交给 `LoadPackageManifestAsync`：

```csharp
var manifestOp = package.LoadPackageManifestAsync(new LoadPackageManifestOptions(targetVersion, 60));
yield return manifestOp;
if (manifestOp.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(manifestOp.Error);
    yield break;
}
```

## 清单缓存为什么要求版本内容保持稳定 {#manifest-loading}

默认 Sandbox 将不同版本的清单分别保存在 ManifestFiles 下：

```text
PackageRoot/
├─ ManifestFiles/
│  ├─ DefaultPackage_v2.bytes
│  ├─ DefaultPackage_v2.hash
│  ├─ DefaultPackage_v3.bytes
│  └─ DefaultPackage_v3.hash
└─ BundleFiles/
```

`DownloadPackageManifestOperation` 和对应的 hash 下载操作先检查目标文件是否存在。存在就跳过该文件下载，后续再进行清单读取与校验。外层 `LoadPackageManifestOperation` 遇到已经激活的同名版本，还会直接返回成功。

因此，“本地有 v3 清单”意味着客户端拥有一份目标版本缓存，不意味着它刚刚与服务器做过内容更新检查。如果服务器用同一个 v3 标识重新发布不同内容，已有客户端可能继续使用旧缓存。

发布时应将版本标识与一份确定的资源内容绑定：内容变化就分配新版本，而不是依赖覆盖同名文件让客户端自动刷新。

缓存清单读取或校验失败时，Sandbox 的清单操作会清理相应的缓存文件并返回失败，业务再安排重试。这里属于错误恢复，不应被当作同名版本更新机制。安装包内的版本和清单文件也仍然存在，供内置文件系统的相应流程使用；不要将远端查询不落盘理解成任何地方都没有本地版本文件。

## 激活清单后，下载器怎样计算缺失文件 {#predownload}

`FileSystemHost.CreateResourceDownloader` 在不指定标签时遍历当前清单的全部 Bundle，先选择其所属文件系统，再调用 `IsDownloadRequired`。默认联机组合的判断为：

| 归属与状态 | 是否列入远端下载 |
| --- | --- |
| Builtin 可以提供目标 BundleGuid | 否 |
| Sandbox 已缓存目标 BundleGuid | 否 |
| Sandbox 尚未缓存目标 BundleGuid | 是 |

所以无需先把 v2 和 v3 的清单做一遍文件名差集，才能判断下载内容。当前清单列出目标文件，内置与沙盒索引给出已有内容，文件系统即可逐个判断缺失情况。

全 Package 预下载的协程片段如下，假设清单已成功激活：

```csharp
var downloader = package.CreateResourceDownloader(new ResourceDownloaderOptions(10, 3));
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
```

这里的参数分别是最大并发数与失败重试次数。创建下载器时先形成候选列表并统计大小，调用 StartDownload 后才启动下载流程。

### 按标签下载与首包标签复制并不完全相同 {#download-tags}

按关卡准备资源时，可以传入标签：

```csharp
var downloader = package.CreateResourceDownloader(
    new ResourceDownloaderOptions("level01", 10, 3));
```

当前 `GetBundleInfosByTags` 对需要下载的 Bundle 执行标签筛选：匹配指定标签的加入列表，**没有标签的 Bundle 也会作为公共依赖加入列表**。这与首包复制任务只按 `HasAnyTag` 匹配的规则不同，不能因为两处都使用标签就认为范围完全相同。

指定标签也不等于下载整个 Package。如果后续业务访问其他范围的资源，它仍可能触发按需下载。使用第三章介绍的 DisableOnDemandDownload 时，则需要业务提前保证所需文件已准备好。

### 下载完成与解包完成分别判断 {#predownload-boundary}

Builtin 的 `IsDownloadRequired` 返回 false，所以一个需要解包但尚无副本的内置 Bundle，不会因此加入远端下载列表。`TotalDownloadCount == 0` 只说明选定范围没有待远端下载项，不保证所有内置副本已准备好。

希望将解包耗时也放到进入游戏之前时，可以通过 `CreateResourceUnpacker` 和 `ResourceUnpackerOptions` 另行准备内置副本，并等待结果。否则，由后续文件获取流程按需解包。

无论预下载还是预解包，都不表示已经将所有 AssetBundle、纹理和 Prefab 加载进内存。文件交付和资源对象加载仍然是两个阶段。

## 文件哈希如何支持更新与回滚 {#rollback}

假设角色 Bundle 在 v2 的哈希为 AAA，在 v3 中变为 BBB，而公共 UI Bundle 的哈希始终为 CCC：

| 清单要求 | 客户端已有 | 结果 |
| --- | --- | --- |
| v3 的角色 BBB | 只有旧角色 AAA | 需要取得 BBB |
| v3 的公共 UI CCC | 内置或缓存已有 CCC | 可以复用 CCC |
| 回到 v2 后的角色 AAA | 缓存仍保留 AAA | 可以复用 AAA |

清单版本决定这一版内容由哪些文件组成，BundleGuid 决定某份文件的身份。在同一个 Package 的缓存范围内，相同哈希文件可以跨资源版本复用，不同哈希文件则可以同时留在磁盘中。即使 CDN 按 v2、v3 保存两套目录，客户端也不必为未变化的 Bundle 保存两份缓存。

这里判断的是构建后文件哈希是否相同。不能仅凭“没有修改这个 Prefab”，就断定它所在 Bundle 的哈希一定不变；打包规则、同包资源和构建条件也会影响输出。

如果业务通过公共 `.version` 查询版本，将入口切回 v2，会让后续查询的客户端选择 v2。它不会主动通知已经运行的客户端撤销 v3；直接由业务配置版本的客户端，也需要更新其对应的版本选择。

回滚还要求旧清单、需要的旧 Bundle 和相应业务代码兼容关系仍然可用。本地缓存已清理时，需要服务器仍能提供旧文件。清理缓存和删除 CDN 历史版本应考虑这一点，不能只修改版本入口却把旧文件全部移除。

### 磁盘版本切换不等于内存对象替换 {#rollback-runtime}

`ResourcePackage.LoadPackageManifestAsync` 会检查 ResourceManager 是否仍有 Loader，并在存在时给出警告。更换 Manifest 不会替换已经加载的 Unity 对象，也不会自动完成场景或对象池的退出流程。

因此，版本选择通常应放在资源使用开始前。运行中切换或回滚时，需要先结束旧内容的使用、释放相应句柄和加载器，再协调清单与远端路由切换。