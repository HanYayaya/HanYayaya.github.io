---
title: "7. 多 Package 与关卡资源管理"
slug: yooasset-307-multiple-packages
date: 2026-11-19
lastmod: 2026-11-20
description: "从 Package 注册与管理边界出发，串联关卡包准备、显式加载、公共资源依赖、退出清理与跨包版本组合。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 7
draft: false
toc: true
---

## 从一个 Package 扩展到多个 Package {#package-layout}

### YooAssets 按名称登记 Package

```csharp
private static readonly Dictionary<string, ResourcePackage> s_packages = new Dictionary<string, ResourcePackage>(10);
```

CreatePackage 检查名称是否已经存在，然后创建对象、加入字典，并为该包注册异步调度器。下面是其中的核心代码：

```csharp
ResourcePackage package = new ResourcePackage(packageName);
s_packages.Add(packageName, package);

// 注册包裹调度器
AsyncOperationSystem.CreatePackageScheduler(packageName, packagePriority);
```

GetPackage 和 TryGetPackage 都在这张字典中按名称查找。GetPackage 在不存在时抛出异常，TryGetPackage 则通过返回值表示是否找到。因此，取得或创建 Package 可以写成：

```csharp
// 使用片段：假设 YooAssets 已完成全局初始化。
if (!YooAssets.TryGetPackage("Level01Package", out var level))
    level = YooAssets.CreatePackage("Level01Package");
```

这里得到的是已登记的 Package 对象，还不能据此判断它已经可以加载资源。ResourcePackage 的构造函数只记录 PackageName；创建核心管理对象和初始化文件系统，发生在后续的初始化操作中。

### 每个 Package 拥有自己的管理对象

InitializePackageOperation 在 CreateCore 阶段执行：

```csharp
string packageName = _package.PackageName;
var resourceManager = new ResourceManager(packageName);
var fileSystemHost = new FileSystemHost(packageName);
resourceManager.Initialize(_options, fileSystemHost);

_fileSystemHost = fileSystemHost;
_package.InternalInitialize(resourceManager, fileSystemHost);
```

多个 Package 初始化后，会分别持有各自的 ResourceManager 和 FileSystemHost。加载清单后，FileSystemHost 再保存该包的 ActiveManifest。

```text
YooAssets.s_packages
├─ DefaultPackage
│  ├─ FileSystemHost
│  │  ├─ 当前激活的 Manifest
│  │  └─ 当前包配置的文件系统
│  └─ ResourceManager
│     ├─ Provider 字典
│     └─ Bundle Loader 字典
├─ Level01Package
│  ├─ FileSystemHost
│  └─ ResourceManager
└─ Level02Package
   ├─ FileSystemHost
   └─ ResourceManager
```

DefaultPackage 在这个例子中只是公共包的名称。框架不会把它解释为其他 Package 的父包，也不会自动建立关卡包对它的依赖关系。哪些公共内容需要提前准备，由业务决定。

## 为什么要拆成多个 Package {#boundaries}

理解管理结构后，再看单 Package 配合标签和多 Package 的区别。

标签可以在同一份清单内划分下载范围。例如为第一关和第二关配置不同标签，进入第一关前只下载所需的 Bundle；资源的依赖关系仍然由这一个 Package 的清单描述，加载与卸载也仍由同一个 ResourceManager 管理。

拆成多个 Package 后，各个包分别构建、加载清单和选择版本，业务也分别管理它们的使用期。

| 维度 | 单 Package 配合标签 | 多 Package |
| --- | --- | --- |
| 清单与版本 | 共用一个当前清单和 PackageVersion | 各包分别选择当前版本 |
| 地址解析 | 在同一个 Package 中解析 | 先确定 Package，再解析地址 |
| 加载复用与引用计数 | 同一个 ResourceManager 管理 | 各包独立管理 |
| 下载范围 | 可按标签、资源信息或全包选择 | 每包内部仍可按这些方式选择 |
| 资源依赖 | 在同一份清单中组织 | 需要明确跨包资源的组合方式 |

所以，单纯要求“进入哪关下载哪关”，并不足以决定必须拆 Package。独立更新的关卡、可选内容或 DLC 可以采用多个包，但需要同时处理版本组合和公共资源的使用关系。标签和 Package 也可以结合使用，例如一个关卡包内部再区分进入关卡必需的资源和可选内容。

下面按公共包与关卡包分别管理的方案，继续分析进入 Level01 的流程。

## 进入关卡前，准备目标 Package {#manager}

### 准备过程包含不同的完成状态

公共包可以在启动时准备，关卡包则可以在进入前按需准备，不必在启动时初始化全部关卡。以联机模式为例，Level01Package 的准备顺序为：

```text
取得或创建 Level01Package
    → 初始化 ResourceManager、FileSystemHost 与文件系统
    → 确定这次进入关卡使用的版本
    → 加载并激活该版本清单
    → 下载本次进入关卡所需的缺失 Bundle
    → 允许进入关卡加载阶段
```

前几章已经解释了这些操作的内部过程。在多包管理中，需要把每一步完成的含义区分开：

| 已完成的步骤 | 能说明什么 | 还不能说明什么 |
| --- | --- | --- |
| TryGetPackage 找到对象 | Package 已登记 | 初始化或清单加载成功 |
| InitializeStatus 为 Succeeded | 包初始化操作成功 | 目标版本清单已激活 |
| 目标清单加载成功 | 可以按目标清单解析资源 | 所需 Bundle 全部在本地 |
| 所需范围的下载操作成功 | 该范围的缺失文件已完成下载 | 场景和 Unity 对象已加载到内存 |

ResourcePackage.PackageValid 检查的是 FileSystemHost 是否存在以及 ActiveManifest 是否非空。它也不表示预下载已经完成，更不表示当前清单一定是业务本次要求的版本。

### 激活清单与预下载分别推进

版本可以通过版本请求取得，也可以来自业务发布配置。假设包初始化已经成功，目标版本已确定为 v3，可使用以下协程片段加载清单：

```csharp
var manifestOp = level.LoadPackageManifestAsync(new LoadPackageManifestOptions("v3", 60));
yield return manifestOp;

if (manifestOp.Status != EOperationStatus.Succeeded)
{
    UnityEngine.Debug.LogError(manifestOp.Error);
    yield break;
}
```

LoadPackageManifestOperation 成功取得清单后调用 SetActiveManifest，将其设为当前清单。若当前已经激活同一版本，则直接完成。

如果业务要求整关资源准备完成后再进入，可以随后创建该包的全量下载器：

```csharp
var downloader = level.CreateResourceDownloader(new ResourceDownloaderOptions(10, 3));
downloader.StartDownload();
yield return downloader;

if (downloader.Status != EOperationStatus.Succeeded)
{
    UnityEngine.Debug.LogError(downloader.Error);
    yield break;
}

// 本次关卡包准备成功，可以继续加载关卡场景。
```

这里的 10 和 3 分别是最大下载并发数与失败后的重试次数。ResourceDownloaderOptions 的这个构造函数将 Tags 设为 null，FileSystemHost 因而从当前清单中筛选所有需要下载的 Bundle。已有可用本地文件的内容不会仅因创建全量下载器就重新下载。

创建下载器和开始下载是两个动作。DownloaderOperation.StartDownload 才启动下载操作。上述代码是流程片段；实际管理器还应把失败状态和错误返回给进入关卡的调用方。

Level01Package 的下载器只根据 Level01Package 的清单生成需求。公共包也需要被纳入进入条件，不能认为关卡包下载完成就已经顺带准备好了 DefaultPackage。

### 业务管理器合并重复的准备请求

可以把这些步骤封装成业务方法 `EnsurePackageReady(packageName, version)`。它不是 YooAsset 自带的 API，而是对框架操作的协调。

例如，关卡界面和匹配流程同时要求准备 Level01Package v3，管理器应该让它们等待同一份准备任务，避免重复初始化。源码中只要 `_initializeOp` 已存在，重复调用 InitializePackageAsync 就会受到检查；TryGetPackage 成功并不能代替对进行中任务的等待。

管理器至少需要记录当前阶段、目标版本、进行中的操作和失败信息。如果准备范围包含标签等条件，还需要区分“哪部分资源已经准备好”，不能用一个全局 Ready 标记代表所有下载范围。

若一个调用方要求 v3，另一个要求 v4，则不能把它们当成同一个请求。FileSystemHost 只有一个 ActiveManifest，需要由业务决定等待、拒绝或安排版本切换。ResourcePackage 在已有 Loader 时加载清单会输出警告，但不会自动替业务完成旧场景、旧 Handle 和旧 Bundle 的清理。切换应发生在协调好旧资源使用之后。

## 加载时显式确定 Package 和地址 {#loading}

准备完成后，资源加载仍使用第五章分析的入口，只是业务需要先取得正确的 Package：

```csharp
// 使用片段：假设公共包与关卡包均已按要求准备成功。
var common = YooAssets.GetPackage("DefaultPackage");
var level = YooAssets.GetPackage("Level01Package");

var hudHandle = common.LoadAssetAsync<UnityEngine.GameObject>("BattleHUD");
var enemyHandle = level.LoadAssetAsync<UnityEngine.GameObject>("Enemy");
var sceneHandle = level.LoadSceneAsync("LevelScene", UnityEngine.SceneManagement.LoadSceneMode.Additive);
```

这些调用返回后，仍需等待各自的加载结果、检查状态，并保存后续负责释放的 Handle。准备文件和完成对象加载是两个阶段。

从业务路由来看，资源由 PackageName 与 Address 共同定位。Level01Package 和 Level02Package 可以分别拥有一个 LevelScene 地址，因为它们各自在自己的清单中解析。

```text
Level01Package + LevelScene
    → Level01Package 的清单
    → Level01Package 的 Provider、Loader

Level02Package + LevelScene
    → Level02Package 的清单
    → Level02Package 的 Provider、Loader
```

框架不会在当前包找不到地址时，自动遍历其他 Package 寻找。统一的业务加载入口可以接收 `packageName` 和 `address`，或接收包含这两个字段的资源配置，再转发给对应 ResourcePackage。

这种显式归属不仅决定去哪里加载，也决定引用计数落在哪个 ResourceManager 中。上例中的 hudHandle 属于公共包，enemyHandle 和 sceneHandle 属于关卡包。关卡退出时，必须把这几份使用关系都纳入管理。

## 公共资源如何被关卡使用 {#cross-package}

### 直接引用不会自动变成跨 Package 依赖

假设 Level01 中的 Enemy.prefab 在 Inspector 中直接引用 Common.mat，而 Common.mat 又被配置在 DefaultPackage 的收集范围内。这样的配置并不会自动生成“加载 Enemy 时，去 DefaultPackage 加载 Common.mat”的运行时关系。

先看构建入口。TaskGetBuildMap.CreateBuildMap 取得当前构建参数的 PackageName，再按这个包开始收集：

```csharp
var packageName = buildParameters.PackageName;
```

收集结果进入本次构建的 allBuildAssetInfos。任务接着录入主动收集资源的依赖，并在本次构建上下文中处理共享资源的 Bundle 划分。一个依赖资源即使没有作为当前包的主资源收集，也仍可能因为直接引用而进入当前构建的依赖处理。

因此，把某个资源配置到公共包，并不等于其他包构建时会自动排除它并改为引用公共包的产物。分别构建多个包，可能使同一份材质、纹理等数据出现在多个包的产物中，具体结果需要查看构建报告及实际 Bundle。

再看运行时。FileSystemHost.GetDependentBundleInfos 对普通资源的依赖查询使用：

```csharp
depends = ActiveManifest.GetAllAssetDependencies(assetInfo.Asset);
```

LoadAllAssets 路径同样从当前 ActiveManifest 查询 Bundle 依赖。依赖 ID 在这一份清单中解析，没有携带另一 Package 的名称，也没有转向另一个 ResourceManager 的步骤。

这两端结合起来就能解释：提前加载 DefaultPackage，不会自动替换 Level01Package 中的序列化引用；公共包已经加载了某张纹理，也不意味着关卡包一定复用同一个内存对象。

### 按依赖关系选择组织方式

如果多个关卡大量直接引用同一套材质、纹理和 Prefab，可以优先考虑放在同一个 Package 中，用标签控制下载范围，并通过打包规则组织共享 Bundle。这样直接依赖可以在同一份清单中描述；是否真正避免重复打包，仍取决于具体收集和打包配置。

如果关卡确实需要独立 Package，则可以通过业务资源标识来组合公共内容。例如关卡配置记录一个公共角色 ID，由业务将它映射到 `DefaultPackage + Player`，显式从公共包加载角色 Prefab，再把实例放入关卡场景。它的 Handle 属于公共包，使用期则可以由本次关卡会话管理。

对于运行时赋值的材质、图集等资源也一样：加载来源与释放责任需要明确。如果原 Prefab 仍保留对同一资源的直接序列化引用，仅仅在运行时重新赋值，并不能消除构建时已经产生的依赖。

### 磁盘缓存也不能默认跨包共享

SandboxFileSystem.OnCreate 在没有指定根目录时，通过 YooAssetConfiguration.GetDefaultCacheRoot(packageName) 取得当前包的默认缓存目录。

默认目录按包区分，因此不能因为两个包中的文件哈希相同，就认为它们必然共享一份下载缓存。自定义文件系统或存储方案可以另外设计共享机制，但那属于额外实现，不能由 Package 名称和哈希直接推导出来。

## 离开关卡时释放哪些资源 {#leave-level}

进入关卡时，业务同时建立了场景、实例和资源 Handle 的使用关系。离开时需要先结束这些使用，再决定关卡 Package 是否继续保留。

```text
停止关卡逻辑及新的加载、实例化请求
    → 卸载关卡场景，清理场景外实例及对象池
    → 结束使用后释放业务持有的资源 Handle
    → 对相关 Package 清理未使用资源
    → 按需要保留或销毁关卡 Package
```

场景卸载成功后，ResourceManager 会通过 sceneUnloaded 事件释放对应场景句柄，这条路径已经在第六章分析。独立加载的资源 Handle、常驻区域中的实例和对象池，则需要业务另外管理，不能依赖场景卸载自动处理。

### 释放责任要覆盖公共包的使用

例如本次关卡创建了 BattleHUD、Enemy 和一个公共角色，可以把其使用关系交给关卡会话统一记录：

| 本次关卡使用的内容 | 加载所属包 | 离开时的处理 |
| --- | --- | --- |
| 关卡场景 | Level01Package | 卸载场景，由事件释放对应场景句柄 |
| Enemy 模板和实例 | Level01Package | 清理实例、对象池，再释放模板 Handle |
| BattleHUD、公共角色 | DefaultPackage | 结束本次使用后，释放本次取得的 Handle |
| 全局常驻 UI | DefaultPackage | 继续由全局所有者持有自己的 Handle |

公共包的生命周期可以长于关卡，但其中某个资源的使用期不一定同样长。关卡退出时应该释放自己从公共包取得的 Handle；其他模块仍持有有效句柄的资源，会继续受到引用计数保护。

反过来，仅销毁 Level01Package，不会替业务释放从 DefaultPackage 取得的 Handle。Package 的管理边界和业务模块的使用边界并不总是重合，关卡会话需要记录的是自己持有的全部资源使用关系。

### 保留 Package 与销毁 Package

如果近期可能重新进入同一关卡，可以保留已经初始化的 Package，在结束使用后执行 UnloadUnusedAssetsAsync。符合条件的 Provider 和 Loader 被清理，当前清单和文件系统索引继续保留，下次可以复用这些初始化结果。未使用资源清理的扫描与等待边界仍遵循第六章的规则。

如果决定完全结束关卡包的运行时使用，可以执行以下片段：

```csharp
// 前提：已结束场景、实例以及其他业务对该包资源的使用。
var destroyOp = level.DestroyPackageAsync();
yield return destroyOp;

if (destroyOp.Status != EOperationStatus.Succeeded)
{
    UnityEngine.Debug.LogError(destroyOp.Error);
    yield break;
}

YooAssets.RemovePackage("Level01Package");
```

DestroyPackageOperation 负责卸载并清理包的运行时状态；RemovePackage 再销毁对应调度器，并从 YooAssets 的注册表移除该包。业务管理器也应同步移除旧的就绪状态和对象引用，下一次进入时重新走取得或创建流程。

销毁运行时 Package 不会删除沙盒中的下载文件。下次重新初始化时，仍可以建立本地缓存索引并复用这些文件。

## 独立版本与发布组合 {#versions}

完成进入、加载和退出的流程后，还需要明确：多个包分别选择版本，不等于任意版本都可以组合使用。

例如关卡 v3 要求公共配置中已经存在某个角色 ID，但公共包 v4 尚未包含它。即使两个包各自的初始化和下载都成功，这个组合仍不满足业务要求。PackageVersion 本身没有表达这种跨包兼容关系。

业务发布配置可以指定一组经过验证的版本：

```text
本次发布
DefaultPackage = v5
Level01Package = v3
Level02Package = v1
```

启动时确定本次使用的发布配置，进入关卡时再按配置准备对应包。这样不必在不同时间分别查询各包的“当前版本”，导致同一次游戏会话取得未经验证的组合。回滚时也应考虑恢复兼容的一组版本。