---
title: "1. 整体架构与初始化流程"
slug: yooasset-307-initialization
date: 2026-11-19
lastmod: 2026-11-19
description: "从 Editor、文件系统与 ResourceManager 的职责划分出发，沿全局初始化、Package 创建、运行模式选择和文件系统初始化阅读源码。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 1
draft: true
toc: true
---



## YooAsset初始化流程为

```text
YooAssets.Initialize
    → 建立全局驱动与异步操作系统
YooAssets.CreatePackage
    → 创建 Package，并注册其调度器
ResourcePackage.InitializePackageAsync
    → 根据运行模式创建 ResourceManager、FileSystemHost
    → 创建并初始化配置的文件系统
    → 返回 Package 初始化结果
```

## 全局初始化 {#global-initialize}

业务首先调用：

```csharp
YooAssets.Initialize();
```

它进入 `YooAssets.Initialize(ILogger logger)`。下面摘录其中建立运行环境的代码，省略重复初始化检查和诊断组件分支：

```csharp
YooLogger.Current = logger;

s_driver = new UnityEngine.GameObject($"[{nameof(YooAssets)}]");
s_driver.AddComponent<YooAssetsDriver>();
UnityEngine.Object.DontDestroyOnLoad(s_driver);

AsyncOperationSystem.Initialize();
s_isInitialized = true;
```

这里首先创建一个常驻的 GameObject，并挂上 `YooAssetsDriver`。它把 YooAsset 接入 Unity 的每帧更新，使后续异步操作能够持续推进：

```text
YooAssetsDriver.Update
    → YooAssets.Update
    → AsyncOperationSystem.Update
    → 各调度器推进已登记的异步操作
```

后面遇到的 Package 初始化、文件系统初始化，都是由 Operation 表达的异步操作。它们可能需要跨帧等待，所以在创建具体 Package 之前，要先准备好统一的驱动和调度系统。这里的异步也不意味着所有工作都放到后台线程执行。

到这一步，框架具备了运行异步操作的基础，但还没有创建任何具体 Package 的 ResourceManager 或文件系统。这些对象属于具体资源集合，需要在 Package 初始化时建立。

## 创建 Package {#create-package}

全局系统就绪后，创建一个 Package：

```csharp
var package = YooAssets.CreatePackage("DefaultPackage");
```

`CreatePackage` 检查全局初始化状态和同名 Package 后，执行以下核心逻辑：

```csharp
ResourcePackage package = new ResourcePackage(packageName);
s_packages.Add(packageName, package);
AsyncOperationSystem.CreatePackageScheduler(packageName, packagePriority);
return package;
```

`ResourcePackage` 的构造函数此时只记录 `PackageName`。全局字典负责按名称查找它，对应的调度器则负责管理该 Package 后续提交的异步操作。

Package 是资源管理的范围，一个 Package 可以包含很多 Bundle。后面创建的 ResourceManager 和 FileSystemHost 都属于这个 Package，加载清单也会针对这个 Package 进行。`DefaultPackage` 是这里使用的名称，并不会自动让它成为其他 Package 的父级。

创建完成后，为什么还要单独调用初始化接口？因为仅凭 Package 名称，还无法知道运行环境应该使用编辑器资源、安装包资源，还是远端资源。接下来需要通过运行模式和参数，将资源来源配置进去。

## 选择运行模式 {#play-modes}

YooAsset 提供了四种常用运行模式：编辑器模拟、离线、联机和 Web。它们通过不同的初始化选项表达，最终影响 FileSystemHost 中配置哪些文件系统。ResourcePackage 仍然提供统一的业务入口。

理解模式时，需要同时考虑两个问题：资源从哪里来，以及当前平台允许怎样访问这些资源。

### 编辑器模拟模式：直接使用工程资源 {#editor-mode}

`EditorSimulateModeOptions` 使用 `EditorFileSystemParameters`，默认对应 EditorFileSystem。它结合模拟构建生成的描述信息，在编辑器中通过 AssetDatabase 等接口访问工程资源，不需要为每次资源修改构建真实的 AssetBundle。

这适合日常开发：修改 Prefab、UI 或配置后，可以较快验证业务效果，同时继续使用 Package 的寻址和加载接口。

它模拟的是资源系统的使用流程。真实 Bundle 的文件读取、压缩、平台格式和构建依赖问题，仍需要使用实际构建产物验证。因此，模拟模式是开发阶段的便利，并不能覆盖真机资源交付的全部行为。

### 离线运行模式：使用随应用交付的资源 {#offline-mode}

`OfflinePlayModeOptions` 使用 `BuiltinFileSystemParameters`，默认对应 BuiltinFileSystem。资源在发布前完成构建，并随应用交付，运行时通过内置文件系统访问。

这种模式适合全部所需资源已经包含在应用中的场景，默认组合不提供远端资源补齐能力。需要更新这部分资源时，通常通过应用更新重新交付。

这里的“离线”描述资源交付方式。游戏即使需要登录服务器或联网战斗，也可以使用离线资源模式，只要资源本身已经随应用准备好。

### 联机运行模式：组合内置资源与下载缓存 {#host-mode}

`HostPlayModeOptions` 提供两个配置位置：

```text
BuiltinFileSystemParameters → 内置文件系统
CacheFileSystemParameters   → 缓存文件系统
```

默认组合是 BuiltinFileSystem 与 SandboxFileSystem。前者管理安装包中的资源，后者管理可写目录中的下载缓存，并通过远端服务取得缺少的文件。

这样，应用可以只携带启动所需的首包资源，其余内容通过网络交付；已经下载的文件也可以在后续启动时继续使用。它同样支持应用先携带较完整的资源，再通过远端发布更新内容。

两个配置分别对应两种存储来源及其生命周期：安装包内的内容随应用交付，下载缓存可以在运行期间增加或清理。联机模式将它们接入同一个 Package，具体文件由谁提供，会在第二篇分析。

### Web 运行模式：适配浏览器的资源访问方式 {#web-mode}

`WebPlayModeOptions` 面向 WebGL 等 Web 运行环境，提供 `WebServerFileSystemParameters` 和 `WebNetworkFileSystemParameters`。默认实现分别为 WebServerFileSystem 和 WebNetworkFileSystem。

WebServerFileSystem 对接随 Web 应用部署的资源集合；WebNetworkFileSystem 通过配置的远端服务取得网络资源。与原生平台相比，浏览器中的文件访问和缓存受 Web 环境约束，即使资源随应用一起部署，读取时也可能需要通过 URL 请求。

因此，Web 模式不能简单理解为“把联机模式的下载地址换一下”。它使用适合 Web 环境的文件系统和网络缓存机制，不能直接照搬原生平台扫描沙盒目录、读取本地文件的流程。

四种模式可以归纳为：

| 模式 | 默认接入方式 | 主要使用场景 |
| --- | --- | --- |
| EditorSimulateMode | 编辑器文件系统 | 快速开发、使用工程资源 |
| OfflinePlayMode | 内置文件系统 | 所需资源全部随应用交付 |
| HostPlayMode | 内置文件系统 + 沙盒文件系统 | 首包、资源更新与后续下载 |
| WebPlayMode | Web 服务器文件系统、Web 网络文件系统 | 浏览器环境中的资源访问 |

3.0.7 还提供 `CustomPlayModeOptions`，允许直接配置文件系统参数列表。双文件系统入口会过滤空参数，因此上表描述的是常见默认组合，不表示每次都必须创建两套文件系统。

模式选择至此就落实为具体配置了。接下来以联机模式为例，看这些参数怎样变成真正的运行时对象。

## Package 初始化 {#initialize-package}

以下是初始化调用片段，假设 `package` 已创建，`remoteService` 是业务实现的远端资源地址服务：

```csharp
var options = new HostPlayModeOptions
{
    BuiltinFileSystemParameters =
        FileSystemParameters.CreateDefaultBuiltinFileSystemParameters(),
    CacheFileSystemParameters =
        FileSystemParameters.CreateDefaultSandboxFileSystemParameters(
            remoteService)
};

var operation = package.InitializePackageAsync(options);
yield return operation;
if (operation.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(operation.Error);
    yield break;
}
```

`CreateDefault...Parameters` 返回的是配置对象。到这里，文件系统实例还没有创建。

`ResourcePackage.InitializePackageAsync` 检查参数和重复初始化状态后，创建初始化操作，并交给前面注册的 Package 调度器：

```csharp
_initializeOp = new InitializePackageOperation(this, options);
AsyncOperationSystem.StartOperation(PackageName, _initializeOp);
return _initializeOp;
```

这也解释了前面全局初始化和创建 Package 的必要性：初始化操作需要提交给调度器，再由全局驱动逐帧推进。业务中的 `yield return operation` 用于等待它完成。

进入 `InitializePackageOperation` 后，状态顺序如下：

```text
SetPlayMode → CheckOptions → CreateCore → InitFileSystem → Done
```

`SetPlayMode` 根据 options 的实际类型确定运行模式；`CheckOptions` 检查 Bundle 加载最大并发数必须大于零。随后在 `CreateCore` 中，创建属于当前 Package 的两个核心对象：

```csharp
string packageName = _package.PackageName;
var resourceManager = new ResourceManager(packageName);
var fileSystemHost = new FileSystemHost(packageName);
resourceManager.Initialize(_options, fileSystemHost);

_fileSystemHost = fileSystemHost;
_package.InternalInitialize(resourceManager, fileSystemHost);
```

`ResourceManager.Initialize` 接收加载并发、自动卸载等管理选项，并保存文件系统宿主接口。`InternalInitialize` 再将 ResourceManager 和 FileSystemHost 交给 Package 持有。

开头提到的运行时两部分，由此在同一个 Package 下建立了联系：ResourceManager 负责后续加载和生命周期管理，FileSystemHost 统一管理资源文件的访问入口。但宿主此时还没有完成具体文件系统的初始化，所以下一步继续处理运行模式带来的配置。

## 文件系统初始化 {#initialize-filesystems}

联机模式在 `InitFileSystem` 阶段调用：

```csharp
_initializeFileSystemOp = _fileSystemHost.InitializeAsync(
    initializeParameters.BuiltinFileSystemParameters,
    initializeParameters.CacheFileSystemParameters);
```

其他模式也在这里分派，只是传入的参数不同。FileSystemHost 将参数整理成列表，交给 `InitializeFileSystemOperation` 顺序处理。

对列表中的每一项，主要执行以下步骤：

```text
FileSystemParameters.CreateFileSystem
    → 按配置类型创建 IFileSystem 实例
    → SetParameter 注入参数
    → OnCreate 设置 Package 与根目录等信息
    ↓
FileSystemHost.AddFileSystem
    ↓
文件系统.InitializeAsync
    → 等待该文件系统完成准备
    → 成功后继续下一项
```

`CreateFileSystem` 通过配置保存的类型名称实例化文件系统。这使模式参数与具体实现分离：模式负责组织配置，配置负责创建实例，实例再负责自己的初始化工作。

对于默认联机组合，先初始化 BuiltinFileSystem，再初始化 SandboxFileSystem。内置系统准备内置资源索引等访问设施，沙盒系统准备下载缓存索引等运行状态。Catalog 怎样读取、缓存目录怎样扫描、校验做到什么程度，属于各文件系统内部的实现，第二篇再沿这条入口向下分析。

外层 `InitializePackageOperation` 会等待整个文件系统初始化操作完成，并传播进度与错误。全部成功后，才将 Package 初始化标记为成功；其中某一步失败，外层也会返回失败，业务应检查 `Status` 和 `Error`。

## 初始化结束时，系统处于什么状态 {#initialization-result}

走到这里，最初的 Package 已经具有以下运行结构：

```text
YooAssets
├─ 全局驱动与异步操作系统
└─ DefaultPackage
   ├─ 对应的异步调度器（由异步操作系统管理）
   ├─ ResourceManager
   └─ FileSystemHost
      ├─ BuiltinFileSystem
      └─ SandboxFileSystem
```

全局系统负责驱动，Package 确定管理范围，ResourceManager 接收管理策略，FileSystemHost 下的文件系统准备好资源访问能力。这就是本次初始化建立起来的运行环境。
