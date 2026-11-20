---
title: "6. 引用计数、实例与资源卸载"
slug: yooasset-307-lifetime
date: 2026-11-19
lastmod: 2026-11-20
description: "沿 Handle 释放、Provider 销毁到 Bundle 卸载的调用链，分析两层引用计数、清理策略以及实例、对象池和场景的使用期。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 6
draft: false
toc: true
---

加载完成后，Provider 保存资源对象，Loader 保存底层 BundleHandle，它们仍留在 ResourceManager 的字典中，供后续请求复用。

当业务不再使用资源时，需要沿这条关系反向释放。本章从 Handle.Release 开始，分析引用如何减少、Provider 和 Loader 何时从缓存中移除，以及最终怎样卸载 Unity 中的 AssetBundle。

## 两层引用计数 {#reference-chain}

先沿用上一章的例子：Player 和 Enemy 位于同一个 characters.bundle 中，Player 被加载两次，Enemy 被加载一次。假设三个请求都已完成，暂不考虑额外的依赖 Bundle。

```text
h1 ─┐
    ├─ Player Provider ─┐
h2 ─┘                   ├─ characters.bundle Loader → BundleHandle
h3 ─── Enemy Provider ──┘
```

这里需要区分两种使用关系：业务通过 Handle 使用 Provider；Provider 通过 Loader 使用 Bundle。源码分别为它们维护引用计数。

| 计数 | 增加时机 | 减少时机 | 当前示例 |
| --- | --- | --- | --- |
| Provider.RefCount | CreateHandle 创建一个新句柄 | ReleaseHandle 释放该句柄 | Player 为 2，Enemy 为 1 |
| LoadBundleOperation.RefCount | Provider 构造时取得 Loader 并调用 Reference | Provider 销毁时调用 Loader.Release | 共享主 Loader 为 2 |

Player 的两个 Handle 复用了同一个 Provider，因此不会对 Loader 重复增加两份引用。若 Player 还依赖材质 Bundle，它的 Provider 会同时持有主 Loader 与依赖 Loader，并分别增加引用。

这些计数由 YooAsset 的方法显式维护。给变量赋值、把 Texture 赋给 UI、创建一个 Prefab 实例，都不会自动改变这些数字。即使业务把 Handle 变量设为 null，Provider 的 `_handles` 集合仍然保留该句柄，也不会因此执行 Release。

## Release 实际执行什么 {#release-handle}

HandleBase.Release 的完整方法很短：

```csharp
public void Release()
{
    if (CheckValidWithWarning() == false)
        return;
    Provider.ReleaseHandle(this);

    // 主动卸载零引用的资源包
    if (Provider.RefCount == 0)
        Provider.TryUnloadBundle();

    Provider = null;
}
```

首先，Provider.ReleaseHandle 从 `_handles` 中移除当前 Handle，并减少 Provider.RefCount。只有计数减到零，才会继续调用 TryUnloadBundle。最后将当前 Handle 的 Provider 置空，这个 Handle 随之失效。

释放 h1 时，Player Provider 的计数从 2 变为 1，h2 仍然有效。释放 h2 时，计数才归零，进入尝试清理的入口。此时是否真的销毁 Provider，还取决于卸载配置和加载状态。

HandleBase 也实现了 IDisposable，其 Dispose 直接调用 Release。使用 `using` 只是把释放时机放到作用域结束处；如果作用域结束后，UI 或实例还要继续使用资源，就不能让唯一的资源句柄提前随之释放。

这一步还没有直接调用 Unity 的卸载接口。Handle.Release 先结束本次请求的使用关系，后续清理才能逐层解除 Provider 对 Loader 的占用。

## 自动卸载与主动清理 {#unload-policy}

继续进入 Provider.TryUnloadBundle：

```csharp
public void TryUnloadBundle()
{
    if (_resourceManager.AutoUnloadBundleWhenUnused)
    {
        _resourceManager.TryUnloadUnusedAsset(MainAssetInfo, 10);
    }
}
```

InitializePackageOptions 中的 AutoUnloadBundleWhenUnused 默认为 false。这个配置决定最后一个 Handle 释放时，是否立即尝试卸载相关 Bundle。

### 关闭自动卸载：在业务边界集中清理

保持默认配置时，Release 仍会减少引用计数，但零引用的 Provider 和 Loader 可以继续保留在缓存中。再次以相同加载入口和 AssetKey 请求资源时，还可以复用尚未销毁的 Provider。

业务需要在合适的时机主动清理，例如关闭一个功能模块或退出关卡之后：

```csharp
// 使用片段：先结束资源使用，再释放本模块持有的句柄。
handle.Release();

// 在选定的业务边界，清理当前 Package 中已不再使用的资源。
yield return package.UnloadUnusedAssetsAsync();
```

ResourcePackage.UnloadUnusedAssetsAsync 创建 UnloadUnusedAssetsOperation。该操作通过 ResourceManager.DestroyUnusedBundle 扫描当前 Package 的 Loader，先清理符合条件的 Provider，再清理符合条件的 Loader。

### 开启自动卸载：在最后一个 Handle 释放时尝试清理

开启配置后，TryUnloadUnusedAsset 围绕当前资源的主 Bundle 和依赖 Bundle 进行清理。它先尝试销毁主 Loader 关联的无引用 Provider，再判断主 Loader 及依赖 Loader 能否卸载，最多尝试 10 轮；某轮没有卸载任何 Loader 时会提前结束。

这条路径并非每次都扫描整个 Package，也不是后台持续检查零引用资源的机制。它与主动清理使用相同的 Provider、Loader 销毁条件，但触发时机和检查范围不同。

选择策略时，需要结合资源的复用频率。频繁开关的 UI 如果每次关闭都卸载，下一次打开就要重新加载；集中清理可以保留这段时间内的复用机会。开启自动卸载可以更及时回收满足条件的 Bundle，但业务仍然需要正确释放 Handle，并处理加载中提前释放等边界。

## 从 Provider 销毁到 Loader 移除 {#destroy-loader}

明确清理入口后，就可以沿一次全包未使用资源清理，观察两层缓存如何退出。

### 先销毁不再使用的 Provider

ResourceManager.DestroyUnusedBundle 首先遍历 Loader，调用各自的 TryDestroyProviders。

Provider 构造时会把自己登记到主 Loader 的 `_providers` 列表；依赖 Loader 则通过引用计数记录占用。TryDestroyProviders 遍历这个列表，检查 Provider.CanDestroyProvider：

```csharp
public bool CanDestroyProvider()
{
    // 注意：正在加载中的任务不可以销毁
    if (IsLoading)
        return false;

    return RefCount <= 0;
}
```

符合条件的 Provider 会从主 Loader 的列表中移除，并执行 DestroyProvider。DestroyProvider 标记销毁状态，然后释放此前持有的所有 Loader 引用，核心动作是：

```csharp
foreach (var bundleLoader in _bundleLoaders)
{
    bundleLoader.Release();
}
```

最后，TryDestroyProviders 调用 ResourceManager.RemoveBundleProviders，按 ProviderKey 将这些 Provider 从 `_providerDict` 移除。

因此，Provider.RefCount 归零和 Loader.RefCount 减少发生在两个不同阶段。只要 Provider 还没被销毁，它对主 Bundle 和依赖 Bundle 的引用就还存在。DestroyProvider 本身也没有逐个调用 Destroy 去销毁它加载的 Texture、Prefab 等对象。

### 再判断 Loader 是否可以销毁

清理完 Provider 后，ResourceManager 再遍历 Loader，调用 LoadBundleOperation.CanDestroyLoader。它包含两层检查。

第一层是 IsReleasable：Loader 不处于 LoadBundleFile 阶段，并且 RefCount 不大于零。正在加载 Bundle 或仍被 Provider 使用时，都不能按这条常规路径销毁。

第二层是反向依赖检查。这里会用到清单中 PackageBundle.ReferrerBundleIDs，确认引用当前 Bundle 的其他 Bundle 是否已经销毁。

例如 A 依赖 B，即使两者的 Provider 都已经销毁，B 的反向依赖中仍记录着 A。默认编译分支要求 A 的 Loader 先销毁，B 才满足条件。如果 A 的 Loader 已不在字典中，也视为通过检查。这个约束保证依赖资源的 Bundle 不先于引用它的 Bundle 被卸载。

### 最后卸载 Bundle，并移出字典

ResourceManager 将符合条件的 Loader 收集到临时列表，再逐个执行：

```text
loader.DestroyLoader()
    → BundleHandle.UnloadBundle()
    → _bundleLoaderDict.Remove(BundleName)
```

对于普通 AssetBundle 路径，AssetBundleHandle.UnloadBundle 最终调用：

```csharp
if (_assetBundle != null)
{
    _assetBundle.Unload(true);
}

if (_bundleStream != null)
{
    _bundleStream.Dispose();
}
```

Unload(true) 会卸载 Bundle 及从中加载的对象。此时即使业务仍持有某个 Unity 对象的 C# 引用，也不能依靠这个引用阻止卸载。这正是使用资源期间需要保留有效 Handle 的原因。

整个常规释放顺序可以串成一条链：

```text
Handle.Release
    → Provider.RefCount 减少
    → 清理时销毁无引用、未在加载的 Provider
    → 主 Loader 和依赖 Loader 的 RefCount 减少
    → 检查 Loader 状态与反向依赖
    → 卸载底层 Bundle
    → 按 BundleName 移除 Loader
```

这里移除的是运行时缓存。沙盒中的 Bundle 数据文件、Info 文件仍然保留，下一次加载可以继续使用本地文件。

## 一个共享 Bundle 的计数例子 {#reference-example}

回到开头的 Player、Enemy。假设关闭自动卸载，资源已经加载完成，也没有额外依赖约束，可以把释放过程展开如下：

| 动作 | Player Provider.RefCount | Enemy Provider.RefCount | 共享 Loader.RefCount |
| --- | --- | --- | --- |
| h1、h2 加载 Player，h3 加载 Enemy | 2 | 1 | 2 |
| 释放 h1 | 1 | 1 | 2 |
| 释放 h2，尚未主动清理 | 0 | 1 | 2 |
| 执行清理，销毁 Player Provider | 已销毁 | 1 | 1 |
| 释放 h3，尚未再次清理 | 已销毁 | 0 | 1 |
| 再次清理，销毁 Enemy Provider | 已销毁 | 已销毁 | 0，随后卸载 |

第一次清理后，Player Provider 已经从字典移除，但 characters.bundle 仍被 Enemy 使用，因此不会卸载。此时重新加载 Player，会创建新的 Player Provider，但可以复用仍在字典中的主 Loader。

这个例子也说明了 Bundle 划分对内存生命周期的影响：只要其中仍有资源被使用，整个 Bundle 就可能继续保留；一个资源的 Handle 全部释放，并不意味着它所在 Bundle 立刻被卸载。

## 为什么一次清理不一定释放所有零引用资源 {#unload-boundaries}

### 依赖链可能需要多轮检查

DestroyUnusedBundle 在收集可销毁 Loader 时，还没有执行本轮实际销毁。因此，对于 A → B → C 的依赖链，本轮可能只有 A 通过检查。销毁 A 后，下一轮才能让 B 通过，再下一轮轮到 C。

UnloadUnusedAssetsOperation 为此按 MaxLoopCount 多次调用 DestroyUnusedBundle。ResourcePackage 的无参入口默认设置 10 轮，操作在每轮扫描后检查时间片是否耗尽，必要时留到后续更新继续。

该操作的成功条件是完成规定的扫描轮数，并不会一直等到 Package 中所有 Loader 都消失。仍有引用、仍在加载、受依赖约束或本次轮数不足的 Loader 都可能留下。它也没有在内部调用 Unity 的 Resources.UnloadUnusedAssets，两者不能因为名称相近就视为同一个操作。

### 加载过程中释放 Handle，不等于取消加载

Provider.CanDestroyProvider 中的 IsLoading 具体指 WaitBundleLoader 和 ProcessBundleHandle 两个阶段。如果已经进入这些阶段，即使最后一个 Handle 被释放，Provider 仍要继续推进加载，常规清理不会立即销毁它。

如果尚处于 StartBundleLoader 阶段，零引用 Provider 会在更新时挂起；清理时则可以销毁。因而“提前释放”的结果需要结合所处阶段判断。

开启自动卸载时，也不能认为加载完成后必然再触发一次自动清理。TryUnloadBundle 是从最后一个 Handle 的 Release 进入的；Provider.SetSuccess 和 SetFail 本身没有追加同样的清理调用。如果释放时因正在加载而没能销毁，就需要在后续合适时机再次清理。

## 直接使用资源对象时，谁持有 Handle {#direct-asset}

框架能够维护请求之间的关系，但不知道某张 Texture 还被哪些 UI 使用。这部分使用期需要业务明确管理。

例如，一个界面加载 Texture 并赋给 RawImage，可以由界面控制器保存 Handle。界面更换纹理时，先解除对旧纹理的使用；确认这份 Handle 所负责的使用者都已不再需要旧纹理后，再释放它。释放时机可以是替换资源、关闭模块或销毁界面，关键是资源的实际使用期，而不是某个固定生命周期函数。

如果两个界面各自加载相同资源，它们会得到各自的 Handle。一个界面退出只释放自己的 Handle，另一个仍然保持 Provider 的引用。如果它们共用同一个 Handle，则必须由公共所有者协调释放，不能把同一个句柄当成两份独立引用。

对于加载器返回的共享 Texture、Material 等对象，通常也不应由某个使用者直接 Destroy；其他 Handle 可能仍在使用同一对象。运行时自行创建或克隆出来的对象，则需要按其自身生命周期管理。

## Prefab 实例与对象池 {#instances}

Prefab 的情况多了一层：加载得到的是模板，Instantiate 创建的是场景中的实例。实例可以继续引用模板所使用的材质、纹理等资源，所以模板已经完成实例化，并不代表相关 Bundle 可以立即卸载。

```text
对象池持有一个 Prefab Handle
    → Provider 持有主 Bundle 与依赖 Bundle

对象池管理实例
    ├─ 正在使用的实例
    └─ 已回收、暂时隐藏的实例
```

普通 Object.Instantiate 不会增加 Provider.RefCount。一个 Handle 创建 100 个实例，仍然只有这一份 Handle 引用。对象池可以保留一个 Handle，覆盖模板和所有实例的使用期；回收实例到池中只是停止展示或逻辑活动，资源依赖仍然存在。

当前版本的内置实例化接口也遵循这个边界。在 AssetHandle 中，InstantiateSync 调用 InstantiateOperation.InstantiateInternal；InstantiateAsync 创建 InstantiateOperation，并把现有 Handle 传进去。

InstantiateOperation 只是保存传入的 Handle、等待资源可用并执行实例化，没有为实例另建 Handle，也没有自动绑定“实例销毁时释放资源”的组件。因此，调用这些辅助接口后仍由业务持有和释放原 Handle。

清空对象池时，应先停止新的实例化请求，结束在用实例和池中实例的使用，待它们实际销毁且不再需要模板后，再释放 Prefab Handle。Unity 的 Destroy 通常延迟执行，需要为这段时序留出空间，不能把发出 Destroy 调用直接等同于所有使用已经结束。

如果业务选择让每个实例独立管理资源引用，就应让它获得自己负责释放的 Handle，或由上层统一统计实例数量。把同一个 Handle 交给多个实例，并让每个实例在 OnDestroy 中分别 Release，会在第一个实例销毁时就释放唯一的那份引用。

## 场景卸载如何释放引用 {#scene-unload}

场景有专门的卸载路径。SceneHandle.UnloadSceneAsync 创建 UnloadSceneOperation，等待场景加载完成后，通过 SceneManager.UnloadSceneAsync 卸载场景。

实际释放 SceneHandle 的位置在 ResourceManager。初始化时，它订阅 SceneManager.sceneUnloaded；加载场景时，它把返回的句柄加入 `_sceneHandles`。收到场景卸载事件后，OnSceneUnloaded 查找对应句柄，执行 Release，再将其从场景句柄列表中移除。

```text
SceneHandle.UnloadSceneAsync
    → Unity 卸载场景
    → sceneUnloaded 事件
    → ResourceManager.OnSceneUnloaded
    → 对应 SceneHandle.Release
    → 后续遵循相同的 Provider、Loader 清理规则
```

因此，场景实际卸载后，框架会释放所跟踪的对应句柄；单独调用 SceneHandle.Release 并不会执行场景卸载。关闭自动卸载时，场景句柄释放后还可以在切换边界调用 UnloadUnusedAssetsAsync，清理剩余无引用资源。

如果场景中的对象被迁移到常驻区域，并且离开原场景后仍要使用其中的资源，就要另行维持覆盖这段使用期的有效资源引用，不能继续依赖原场景的句柄。

## 全量卸载与 Package 销毁 {#package-destruction}

前面的清理都尊重仍然存在的使用关系。彻底结束一个 Package 的使用时，还需要区分全量卸载与 Package 销毁。

ResourcePackage.UnloadAllAssetsAsync 的无参入口默认启用释放全部 Handle 和锁定新加载。UnloadAllAssetsOperation 会清空场景句柄记录、释放 Handle，向 Provider 和 Loader 发出强制销毁请求，等待 Provider 完成，然后销毁全部 Provider 与 Loader。

这个流程还会调用 Unity 的 Resources.UnloadUnusedAssets。默认无参入口不等待这个 Unity 操作完成；传入 UnloadAllAssetsOptions 并开启 ShouldWaitUnloadUnused 后，才会等待它完成。关闭 ShouldReleaseHandles 也不会让仍有业务引用的 Provider 被保留下来，后续仍会全量销毁。

因此，全量卸载应安排在业务已经停止使用该 Package 资源之后。它不是一次更积极的普通清理，也不能替代业务卸载场景、销毁实例和清空对象池的工作。

对于已初始化且有效的 Package，DestroyPackageOperation 会先执行全量卸载，并启用等待 Unity 卸载完成，然后调用 InternalDestroy 清理运行时状态及该 Package 的异步任务。如果还需要从 YooAssets 的注册表移除它，应在 DestroyPackageAsync 成功后调用 RemovePackage。