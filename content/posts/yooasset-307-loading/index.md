---
title: "5. Provider、Handle 与 Bundle 加载复用"
slug: yooasset-307-loading
date: 2026-11-19
lastmod: 2026-11-20
description: "沿一次 LoadAssetAsync 请求，分析 Provider、Bundle Loader 和 Handle 的创建、复用、异步推进及 Unity 对象加载。"
categories:
  - "Unity/YooAsset/YooAsset 3.0.7 源码阅读"
tags:
  - Unity
  - YooAsset
  - 源码阅读
series:
  - "YooAsset 3.0.7 源码阅读"
series_order: 5
draft: false
toc: true
---

## 资源加载 {#loading-entry}

```csharp
var handle = package.LoadAssetAsync<GameObject>("Player");
```

这个调用需要把清单中的资源描述变成可使用的 Unity 对象。文件已下载时，可以直接进入本地读取；文件尚未准备好时，则由第三章的文件系统流程补齐。ResourceManager 在这些文件访问能力之上，负责组织加载任务、复用已有工作，并向业务返回结果。

本篇以普通 AssetBundle 中的 Player Prefab 为例，沿一次加载请求追踪到 Unity API。先看对象如何建立联系，再看异步状态怎样推进，最后回到业务取得的 Handle。

## ResourcePackage 怎样把请求交给 ResourceManager {#request-description}

泛型入口 `LoadAssetAsync<TObject>` 先通过当前清单将 location 转换为 AssetInfo，再进入公共加载方法。下面是关键调用，省略前置检查：

```csharp
AssetInfo assetInfo = ConvertLocationToAssetInfo(location, typeof(TObject));
return LoadAssetInternal(assetInfo, false, priority);
```

AssetInfo 将 PackageAsset 与本次请求类型联系起来。例如，本次资源路径对应 Player Prefab，请求类型为 GameObject。它描述要加载什么，不持有已经加载的 Prefab。

`LoadAssetInternal` 接着设置加载方法，再交给当前 Package 的 ResourceManager：

```csharp
assetInfo.LoadMethod = ELoadMethod.LoadAsset;
var handle = _resourceManager.LoadAssetAsync(assetInfo, priority);
if (waitForAsyncComplete)
    handle.WaitForAsyncComplete();
return handle;
```

异步入口传入的 `waitForAsyncComplete` 为 false，所以这里返回 Handle，不等待资源对象就绪。同步入口也会经过这条路径，只是在返回前要求等待完成，后面再讨论这个区别。

至此，ResourcePackage 完成请求信息的整理。接下来的加载组织工作由 ResourceManager 负责。

## 为什么需要 Provider、Loader 和 Handle {#reuse-layers}

加载 Player 包含两类工作：先准备主 Bundle 与依赖 Bundle，再从主 Bundle 中取得 Player 对象。这两类工作需要分别管理，因为一个资源可能依赖多个 Bundle，而多个资源又可能使用同一个 Bundle。

ResourceManager 因此维护两层运行时对象，再通过 Handle 提供业务入口：

| 对象 | 本次加载中的职责 |
| --- | --- |
| AssetProvider | 组织 Player 的 Bundle 准备与对象加载，保存进度、状态和结果 |
| LoadBundleOperation | 管理一个 Bundle 的加载操作，取得底层 BundleHandle；下文简称 Loader |
| AssetHandle | 关联一个 Provider，供调用者等待、查询结果及结束自己的使用关系 |

Provider 可以被多次相同的资源请求共享，Loader 可以被使用同一 Bundle 的多个 Provider 共享。Handle 则为每次请求单独创建，业务不直接操作共享任务。

```text
AssetHandle → AssetProvider
                 ├─ 主 Bundle Loader
                 └─ 依赖 Bundle Loader 列表
```

## 查找或创建 Provider {#provider-key}

进入 `ResourceManager.LoadAssetAsync` 后，先检查加载是否被锁定、AssetInfo 是否有效。这些检查失败时，会创建已失败的 ErrorProvider 并返回相应 Handle，因此“拿到了 Handle”并不能证明请求成功。

正常请求进入以下逻辑：

```csharp
string providerKey = nameof(LoadAssetAsync) + assetInfo.AssetKey;
ProviderBase provider = GetAssetProvider(providerKey);
if (provider == null)
{
    provider = new AssetProvider(this, providerKey, assetInfo);
    provider.InitProviderDebugInfo();
    _providerDict.Add(providerKey, provider);
    AsyncOperationSystem.StartOperation(PackageName, provider);
}

provider.Priority = priority;
return provider.CreateHandle<AssetHandle>();
```

`_providerDict` 属于当前 Package 的 ResourceManager。它的键由加载方法前缀和 AssetKey 组成，AssetKey 在当前版本中的生成规则是：

```csharp
if (AssetType == null)
    _assetKey = $"[{AssetPath}][null]";
else
    _assetKey = $"[{AssetPath}][{AssetType.Name}]";
```

因此，Provider 不是简单地与业务输入的 Address 一一对应。地址先经过清单解析，真正进入键的是 AssetPath 与类型名；若两个合法定位方式解析到同一路径、请求类型一致，就会命中同一个键。

相反，同一路径分别请求 GameObject 与 UnityEngine.Object，会产生不同的键。LoadSubAssets、LoadAllAssets 也使用各自的加载方法前缀。这里的类型字符串实际使用 `Type.Name`，不能将其描述成程序集限定类型名。

复用查找发生在加载完成之前：只要 Provider 仍在字典中，后续相同键的请求就会取得它。于是正在进行的加载也能被合并，不必等第一个请求完成后才能复用。

## 每次请求怎样获得自己的 Handle {#create-handle}

无论是新建还是复用 Provider，最后都会调用 `CreateHandle<AssetHandle>`：

```csharp
public T CreateHandle<T>() where T : HandleBase
{
    RefCount++;
    HandleBase handle = HandleFactory.CreateHandle(this, typeof(T));
    _handles.Add(handle);
    return handle as T;
}
```

HandleFactory 根据类型创建新的句柄，句柄内部保存 Provider 引用；Provider 也记录关联的句柄，并增加使用计数。重复请求同一个 Player，复用的是 Provider，返回的 Handle 仍然各不相同。

这使不同调用者可以独立表达自己的使用关系，而不用各自创建一套加载任务。

从代码顺序上还要注意：`new AssetProvider(...)` 会先执行 ProviderBase 构造函数，主 Bundle 和依赖 Loader 在构造期间就已经取得。下面回到这一步，看 Provider 怎样建立底层关系。

## Provider 构造时取得主 Bundle 和依赖 Loader {#loader-cache}

ProviderBase 构造函数的主要逻辑如下，省略合法键检查和空列表分支：

```csharp
_mainBundleLoader = manager.GetOrCreateMainBundleLoader(assetInfo);
_mainBundleLoader.AddProvider(this);
_bundleLoaders.Add(_mainBundleLoader);

var dependLoaders = manager.GetOrCreateDependBundleLoaders(assetInfo);
_bundleLoaders.AddRange(dependLoaders);

foreach (var bundleLoader in _bundleLoaders)
{
    bundleLoader.Reference();
}
```

`_bundleLoaders` 包含主 Loader 以及依赖 Loader。取得它们时，ResourceManager 会连接前两章的清单与文件系统：

```text
AssetInfo
    → FileSystemHost 查询主 Bundle、依赖 Bundle 的描述
    → 为每个 PackageBundle 选择文件系统
    → 包装为 BundleInfo
    → ResourceManager 查找或创建对应 Loader
```

BundleInfo 携带 PackageBundle 和文件系统实例，供 Loader 创建实际文件系统加载操作。它本身还不是已经加载的 AssetBundle。

`GetOrCreateBundleLoader` 的核心代码为：

```csharp
string bundleName = bundleInfo.Bundle.BundleName;
LoadBundleOperation loaderOperation = GetBundleLoader(bundleName);
if (loaderOperation != null)
    return loaderOperation;

loaderOperation = new LoadBundleOperation(this, bundleInfo);
_bundleLoaderDict.Add(bundleName, loaderOperation);
return loaderOperation;
```

`_bundleLoaderDict` 同样属于 ResourceManager，键是 BundleName。ProviderBase 只持有自身需要的 Loader 引用，不拥有一个独立的全包 Loader 字典。

所以不同 Provider 使用同一个 BundleName 时，会共享一个 Loader，这个键也没有包含 PackageVersion 或 FileHash, 主 Bundle 和依赖 Bundle 都可以通过这套机制复用。

构造阶段会立即调用 Loader.Reference。源码特别指出，这部分不能延迟到 Provider 的 InternalStart，否则共享 Loader 在新使用关系尚未登记时可能被提前卸载。建立引用与实际开始读取文件，是两个不同的时点。

## Provider 如何推进异步加载 {#provider-state}

ProviderBase 继承 AsyncOperationBase。新 Provider 注册到当前 Package 的异步调度器后，由第一章的全局驱动推进，其状态机主干为：

```text
StartBundleLoader
    → WaitBundleLoader
    → ProcessBundleHandle
    → Done
```

StartBundleLoader 会启动所需 Loader，并将它们登记为子操作。WaitBundleLoader 更新这些 Loader、汇总进度，并检查它们是否全部成功。

这里不是必须先加载完主 Bundle，再串行加载每个依赖。Provider 会推进其 Loader 集合，具体允许多少 Bundle 加载操作同时进入执行阶段，由 ResourceManager 的并发控制决定。

多个 Provider 可能持有同一个 Loader，但它们调用的是同一个操作对象。AsyncOperationBase 的 StartOperation 只在状态为 None 时启动，已结束操作也不会因为再次更新就重新执行底层加载。因此共享引用不意味着重复创建 Unity 的 Bundle 请求。

主 Bundle 与依赖全部完成后，Provider 从主 Loader 取得结果：

```csharp
LoadedBundleHandle = _mainBundleLoader.BundleHandle;
```

若结果为空或某个 Loader 失败，Provider 会进入失败处理。只有准备成功，才进入 ProcessBundleHandle，由具体 Provider 决定怎样读取资源对象。

主 Loader 返回的 `IBundleHandle` 是内部的 Bundle 访问接口，与业务持有的 AssetHandle 不同：前者封装底层 Bundle 能力，后者关联资源 Provider。下面先看 Loader 如何得到这个内部结果。

## Loader 如何连接文件系统与 Unity Bundle 加载 {#load-bundle}

`LoadBundleOperation` 的主要状态为：

```text
CheckConcurrency → LoadBundleFile → Done
```

异步加载先检查当前 Package 的 Bundle 加载并发是否已满；允许执行后，再通过 BundleInfo 创建文件系统加载操作：

```csharp
_loadPackageBundleOp = LoadBundleInfo.CreateBundleLoader();
_loadPackageBundleOp.StartOperation();
AddChildOperation(_loadPackageBundleOp);
```

`BundleInfo.CreateBundleLoader` 最终调用其持有文件系统的 `LoadPackageBundleAsync`。这里的命名容易混淆：ResourceManager 字典里复用的是外层 LoadBundleOperation，这个方法创建的是它内部使用的文件系统操作。

以 Sandbox 中普通 AssetBundle 的正常加载路径为例：

```text
LoadBundleOperation
    → SFSLoadPackageBundleOperation
        → 必要时下载并缓存文件
        → SandboxBundleCache.LoadBundleAsync
            → SBCLoadAssetBundleOperation
                → LoadLocalAssetBundleOperation
                    → AssetBundle.LoadFromFileAsync
```

Builtin 直接读取原件时，中间换成 BFSLoadPackageBundleOperation 和 BBCLoadAssetBundleOperation；使用解包副本时，则由相应缓存接入加载。

普通未加密文件在 `LoadLocalAssetBundleOperation` 中执行：

```csharp
private void LoadFromFile()
{
    if (IsWaitForCompletion)
        _assetBundle = AssetBundle.LoadFromFile(_options.FilePath);
    else
        _createRequest = AssetBundle.LoadFromFileAsync(_options.FilePath);
}
```

异步请求结束后取得 `_createRequest.assetBundle`，检查结果非空，再包装为 AssetBundleHandle，沿文件系统操作返回给外层 Loader。这个对象实现 IBundleHandle，并保存真正的 Unity AssetBundle。

加密文件根据解密器走带偏移量的 LoadFromFile、LoadFromMemory 或 LoadFromStream 及对应异步接口。Web 和编辑器模拟模式也有不同实现，不能将所有平台的加载都归结为 LoadFromFileAsync。本节追踪的是普通本地 AssetBundle 的路径。

## AssetProvider 如何从 Bundle 中读取对象 {#load-object}

回到已经进入 ProcessBundleHandle 的 Provider。AssetProvider 实现 `InternalProcessBundleHandle`，第一次执行时创建对象加载操作：

```csharp
_loadAssetOp = LoadedBundleHandle.LoadAssetAsync(MainAssetInfo);
_loadAssetOp.StartOperation();
AddChildOperation(_loadAssetOp);
```

此时传入的是本次请求的 AssetInfo，而不是重新传入业务 Address。普通 AssetBundleHandle 会创建 `ABHLoadAssetOperation`，使用其中的 AssetPath 和 AssetType 调用 Unity API。

以下摘录省略 AssetType 为 null 时的重载：

```csharp
if (IsWaitForCompletion)
{
    Result = _assetBundle.LoadAsset(_assetInfo.AssetPath, _assetInfo.AssetType);
}
else
{
    _request = _assetBundle.LoadAssetAsync(_assetInfo.AssetPath, _assetInfo.AssetType);
}
```

异步请求结束后读取 `_request.asset`。若结果为空，操作返回失败；成功时，AssetProvider 将结果保存到自己的 AssetObject，并设置完成状态：

```csharp
AssetObject = _loadAssetOp.Result;
SetSuccess();
```

至此，文件层和资源对象层的两次加载都完成了：

```text
Bundle 文件 → Unity AssetBundle → Player Prefab 对象
```

前一次加载为后一次提供读取入口。依赖 Loader 在资源对象加载期间仍由 Provider 持有，不能因为主 Bundle 已经返回就结束相关使用关系。

## Handle 怎样提供状态和结果 {#handle-result}

Handle 不再保存另一套独立加载任务。有效句柄的 Status、Progress、IsDone 等查询转向关联 Provider，AssetHandle.AssetObject 也直接读取 Provider 的结果：

```csharp
public UnityEngine.Object AssetObject
{
    get
    {
        if (CheckValidWithWarning() == false)
            return null;
        return Provider.AssetObject;
    }
}
```

协程可以通过 HandleBase 实现的 IEnumerator 等待完成；它的 MoveNext 返回 `!IsDone`。框架自身的推进仍由全局驱动及操作链负责，`yield return handle` 表达业务等待关系。

业务侧的最小使用片段如下：

```csharp
var handle = package.LoadAssetAsync<GameObject>("Player");
yield return handle;
if (handle.Status != EOperationStatus.Succeeded)
{
    Debug.LogError(handle.Error);
    handle.Release();
    yield break;
}

var prefab = handle.AssetObject as GameObject;
// prefab 是加载的模板；使用期间保留 handle，结束使用后再释放。
```

也可以注册 Completed 回调。正常的 SetSuccess、SetFail 路径都会通知仍有效的关联句柄，因此 Completed 表示操作结束，业务仍需检查 Status。若注册回调时 Provider 已经完成，AssetHandle 的事件添加逻辑会立即调用该回调，不能假设它一定发生在下一帧。

加载 Prefab 到这里只得到模板，不会自动在场景中创建角色实例。实例化是业务后续的另一项操作，其资源持有关系将在生命周期篇展开。

## 用三个请求回看两层复用 {#reuse-example}

假设 Player 与 Enemy 位于同一个主 Bundle，三次请求均使用 GameObject 类型，并且相关加载器尚未被移除：

```csharp
var h1 = package.LoadAssetAsync<GameObject>("Player");
var h2 = package.LoadAssetAsync<GameObject>("Player");
var h3 = package.LoadAssetAsync<GameObject>("Enemy");
```

形成的主干关系是：

```text
h1 ─┐
    ├─ Player AssetProvider ─┐
h2 ─┘                        ├─ characters.bundle Loader
h3 ─── Enemy AssetProvider ──┘
```

结果是三个 Handle、两个 Provider、一个共享的主 Bundle Loader。h1 与 h2 观察同一份 Player 加载状态和结果；Enemy 有独立的对象加载过程，但使用同一个已存在或正在加载的主 Bundle。

若还有依赖 Bundle，它们也按 BundleName 取得或创建对应 Loader。复用范围是当前 Package 的 ResourceManager，不会仅凭另一个 Package 中存在同名 Bundle，就自动共享同一加载器。

这解释了两张字典的必要性：只按资源复用，无法处理不同资源共用 Bundle；只按 Bundle 复用，又无法区分其中不同资源对象的加载结果。

## 同步加载与其他加载接口 {#load-methods}

主流程建立后，可以再看几个入口上的变化。

### 同步入口改变等待方式 {#sync-loading}

LoadAssetSync 也经过 LoadAssetInternal、ResourceManager 和 Provider，只是调用 `handle.WaitForAsyncComplete()`。等待向下传播到各操作，使底层在相应分支选择同步 API 或等待已经开始的异步请求完成。

因此同步入口仍然使用同一套 Provider 和 Loader 复用机制，不会另外创建一份同步加载缓存。底层请求若已经开始异步执行，源码存在读取请求结果并阻塞主线程的等待路径；同步等待也不会让网络和平台限制消失。

### 子资源、全部资源与场景改变加载行为 {#other-load-methods}

| 接口 | 普通 AssetBundle 路径中的主要行为 |
| --- | --- |
| LoadAssetAsync | 使用 LoadAssetAsync 读取指定路径的匹配对象 |
| LoadSubAssetsAsync | 使用 LoadAssetWithSubAssetsAsync 读取指定资源文件的匹配对象集合 |
| LoadAllAssetsAsync | 由 location 定位 Bundle，再使用 LoadAllAssetsAsync 读取该 Bundle 的全部匹配对象 |
| LoadSceneAsync | 使用场景 Provider 和场景加载路径 |

子资源可以是 Multiple 图片中的 Sprite、FBX 中的 Mesh 或 AnimationClip，不是 Prefab 的子 GameObject，也不是它引用的全部外部资源。LoadAllAssets 的范围则由 Bundle 边界决定，不是整个 Package。

这些入口使用对应的 Provider 和 Handle 类型。场景还有额外区别：当前实现为每次场景加载生成不同的 ProviderKey，不套用普通 AssetProvider 的同键复用规则。

编辑器模拟模式最终通过 AssetDatabase 取得工程对象，例如其子资源路径使用 LoadAllAssetRepresentationsAtPath；它与真实 Bundle 接口的主资源、子资源返回范围存在语义差别。具体使用应结合请求类型和真实构建结果验证。

## 加载完成之后仍有哪些关系 {#loading-complete}

本次请求可以按时间顺序收束为：

```text
ResourcePackage 整理 AssetInfo
    → ResourceManager 查找或创建 Provider
        → 新 Provider 构造时取得主 Loader 和依赖 Loader
    → 创建本次请求的 Handle 并返回
    → 后续更新推进 Bundle 加载
    → AssetProvider 读取资源对象
    → Provider 保存结果，Handle 提供状态与访问
```

操作完成后，Provider 与 Loader 仍可能保存在 ResourceManager 中，供当前使用者和后续请求复用。Handle 的使用关系、Provider 对 Loader 的引用也仍然存在。
