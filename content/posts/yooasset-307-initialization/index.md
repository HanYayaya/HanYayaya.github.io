---
title: "1. 从全局入口到 Package 初始化"
slug: yooasset-307-initialization
date: 2026-11-19
lastmod: 2026-11-19
description: "梳理运行模式、核心对象、异步驱动，以及初始化和清单激活的边界。"
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

调用 `LoadAssetAsync("Player")` 之前，框架需要先准备哪些东西？本文从全局初始化开始，将 Package、文件系统、资源清单和异步操作放到同一条启动链路中。

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

## 资源系统首先解决什么问题 {#overview}

Unity 的 AssetBundle API 提供文件加载、对象加载和卸载能力。一个可交付的资源系统还需要知道：地址对应哪个文件、依赖如何准备、文件是否下载过、应该使用哪个版本，以及什么时候可以释放资源。

可以按职责将 YooAsset 分成三部分：

| 部分 | 核心问题 | 主要对象 |
| --- | --- | --- |
| 编辑器构建 | 资源如何组织为 Bundle，如何生成发布信息 | Collector、构建管线、BuildManifest |
| 文件交付 | 目标文件在哪里，是否需要下载或解包 | FileSystemHost、IFileSystem、BundleCache |
| 运行时加载 | 如何复用加载工作，如何管理引用 | ResourceManager、Provider、Handle |

后续讨论中要始终区分四种状态：文件已经下载、Bundle 已加载、资源对象已加载、Prefab 已实例化。这四件事分别消耗不同资源，也有不同的生命周期。

## 全局入口与 Package {#global-and-package}

`YooAssets.Initialize()` 创建挂有 `YooAssetsDriver` 的 GameObject，设置 `DontDestroyOnLoad`，初始化 `AsyncOperationSystem`，并配置日志。相应编译条件下还会添加诊断组件。

随后可以创建 Package：

```csharp
YooAssets.Initialize();
var package = YooAssets.CreatePackage("DefaultPackage");
```

`CreatePackage` 将对象登记到全局字典，并注册这个 Package 的异步调度器。此时尚未创建完整的文件系统和资源管理器。Package 名称是管理边界，不等于一个 AssetBundle 文件名，一个 Package 可以包含大量 Bundle。

```text
YooAssets
├─ 全局驱动与异步系统
└─ Package 字典
   └─ DefaultPackage
      ├─ ResourceManager
      └─ FileSystemHost
         ├─ 文件系统列表
         └─ ActiveManifest
```

## 四种运行模式改变什么 {#play-modes}

运行模式主要选择文件系统组合。业务仍然通过 Package 的加载接口使用资源。

| 模式 | 默认资源来源 | 主要用途 |
| --- | --- | --- |
| EditorSimulateMode | 编辑器工程资源、模拟构建信息 | 日常开发，无需每次构建真实 Bundle |
| OfflinePlayMode | 内置文件系统 | 全部所需内容随应用交付 |
| HostPlayMode | 内置文件系统与缓存文件系统 | 热更新、首包、按需下载 |
| WebPlayMode | Web 服务器与 Web 网络文件系统，或平台适配 | 浏览器与相关 Web 运行环境 |

联机、离线描述的是资源交付方式。连接战斗服务器的游戏同样可以使用离线资源模式。模拟模式可以验证地址和业务流程，但无法代替真实 Bundle 的平台、内存和依赖验证。

当前实现还提供 `CustomPlayModeOptions`，允许业务配置文件系统列表。Web 平台的访问和缓存机制与原生文件目录不同，不能直接套用沙盒扫描规则。

## Package 初始化的内部顺序 {#initialize-package}

以默认联机配置为例，下面是初始化参数片段，`remoteService` 由业务提供：

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

`CreateDefaultSandboxFileSystemParameters` 只创建配置，尚未建立沙盒对象。真正的创建发生在初始化操作中：

```text
InitializePackageOperation
  SetPlayMode → CheckOptions → CreateCore → InitFileSystem
                                 │              │
                                 │              └─ InitializeFileSystemOperation
                                 │                   → 创建文件系统实例
                                 │                   → SetParameter / OnCreate
                                 │                   → InitializeAsync
                                 └─ 创建 ResourceManager、FileSystemHost
```

`InitializeFileSystemOperation` 按参数列表顺序初始化各文件系统。默认联机组合先初始化 Builtin，再初始化 Sandbox。文件系统内部准备路径、缓存索引、下载后端和调度器，具体过程见第二篇。

`ResourceManager` 同时接收 Bundle 加载并发上限、自动卸载等选项。此时只是建立运行设施，不会为清单里每个资源预先创建 Provider。

## 初始化成功与清单就绪是两个状态 {#manifest-ready}

在本版本中，`InitializePackageAsync` 不会自动完成“查询资源版本并激活目标清单”的业务流程。典型启动顺序是：

```text
初始化 Package
    ↓
查询或指定目标资源版本
    ↓
LoadPackageManifestAsync
    ↓
清单校验、解析、建立索引、设置 ActiveManifest
    ↓
按需要预下载资源
    ↓
加载启动场景或其他资源
```

`InitializeStatus` 描述初始化操作状态；`PackageValid` 会检查文件系统宿主及激活清单。两者表达的准备程度不同。加载资源需要有效的当前清单，因为文件缓存本身无法回答地址与依赖的关系。

## 谁在推进这些异步操作 {#operation-driver}

驱动链路为：

```text
YooAssetsDriver.Update
    → YooAssets.Update
    → AsyncOperationSystem.Update
    → 各 AsyncOperationScheduler.Update
    → Operation.UpdateOperation
```

调度器管理待加入与运行中的操作，并考虑优先级、全局时间片预算。各具体 Operation 通过状态机调用子操作的启动、更新接口，再检查其状态。这里的异步主要表示操作可以跨帧推进；文件校验的后台任务、Unity 自身的异步请求和网络请求各自有独立执行机制。

读取操作时可以固定追踪三个位置：`InternalStart()` 设置起始状态，`InternalUpdate()` 推进步骤，结果状态将成功或错误传播给外层。`yield return operation` 是等待接口，不负责替代全局驱动器执行操作。

操作完成也不等于底层资源被卸载。一个 Provider 可以完成加载后继续被缓存、持有对象，直到引用与卸载策略允许销毁。异步操作生命周期和资源生命周期需要分别理解。

## 失败后重试哪个阶段 {#failure-boundaries}

`ResourcePackage.InitializePackageAsync` 会检查重复初始化；初始化失败时，后续调用前的 `TryResetAfterFailure` 会销毁已建立的内部状态。业务仍需等待操作结束并检查错误。

清单获取失败与文件系统初始化失败属于不同阶段。文件系统已经初始化成功时，通常应针对清单流程重试，而不是再次初始化同一个已成功初始化的 Package。

覆盖安装的缓存策略也在文件系统初始化中执行：`ApplicationFootprint` 记录安装标记，变化后按 `InstallCleanupMode` 清理相关内容，再重建缓存索引。它与业务选择 v2、v3 资源版本并非同一个判断。

## 源码阅读入口 {#source}

- [YooAssets.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/YooAssets.cs)：全局初始化、Package 登记。
- [InitializePackageOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/InitializePackageOperation.cs)：创建核心对象与模式分派。
- [InitializeFileSystemOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/Internal/InitializeFileSystemOperation.cs)：逐个创建、初始化文件系统。
- [AsyncOperationSystem.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/AsyncOperation/AsyncOperationSystem.cs) 与 [AsyncOperationScheduler.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/AsyncOperation/AsyncOperationScheduler.cs)：每帧调度。
- [LoadPackageManifestOperation.cs](https://github.com/tuyoogame/YooAsset/blob/8cb910de899050d95b01644e7a3bd7a643f226c0/Assets/YooAsset/Runtime/ResourcePackage/Operations/LoadPackageManifestOperation.cs)：激活清单的独立操作。
