---
title: "1. 从 LuaEnv 到类型延迟注册"
slug: xlua-initialization
date: 2026-09-15
lastmod: 2026-11-19
description: "沿 LuaEnv 的初始化过程，分析 Lua VM、ObjectTranslator、生成代码接入与 Wrap 延迟注册。"
categories:
  - "Lua/XLua/XLua 2.1.16 源码阅读"
tags:
  - Lua
  - XLua
  - Unity
series:
  - XLua 2.1.16 源码阅读
series_order: 1
draft: false
toc: true
---

## XLua 的整体运行时结构 {#runtime-architecture}

每个 `LuaEnv` 对应一个独立的 Lua VM，并持有一个为该 VM 服务的 `ObjectTranslator`：

```text
LuaEnv
├── lua_State
├── ObjectTranslator
│   ├── 类型系统与 Wrap 加载
│   ├── C# 对象映射
│   ├── Lua 对象引用
│   ├── 参数与返回值转换
│   └── Delegate/Interface 适配
└── ObjectTranslatorPool
    └── lua_State → ObjectTranslator
```

`ObjectTranslator` 并不只是一个类型转换工具。它实际上是当前 `LuaEnv` 的跨语言对象运行时，负责管理类型、对象身份、参数转换、Wrap、Delegate 以及两个 GC 系统之间的引用关系。

`ObjectTranslatorPool` 建立 `lua_State` 与 `ObjectTranslator` 的映射。查找时会通过 `xlua_gl(L)` 取得全局 Lua State，因此即使回调来自 Lua coroutine，也能找到属于主 Lua VM 的同一个 `ObjectTranslator`。

## Generate Code 的产物与职责 {#generated-code-overview}

Generate Code 为不同交互路径准备适配代码。先从各文件的职责建立整体认识，后续各篇再分析对应实现。

| 生成产物 | 主要职责 | 详细分析 |
| --- | --- | --- |
| `<TypeName>Wrap.cs` | 暴露构造函数、方法、属性与元方法 | [第二篇](/posts/xlua-lua-call-csharp/#type-wrap) |
| `EnumWrap.cs` | 注册枚举成员与转换入口 | [第二篇](/posts/xlua-lua-call-csharp/#enum-wrap) |
| `DelegatesGensBridge.cs` | 将 Lua function 适配为 C# Delegate | [第三篇](/posts/xlua-csharp-call-lua/#delegate-bridge) |
| `<InterfaceName>Bridge.cs` | 将 Lua table 适配为 C# 接口对象 | [第三篇](/posts/xlua-csharp-call-lua/#interface-bridge) |
| `WrapPusher.cs` | 值类型的 Push、Get、Update 与专用转换 | [第五篇](/posts/xlua-value-types-and-performance/#wrap-pusher) |
| `PackUnpack.cs` | 复制 struct 字段与 userdata 数据区之间的数据 | [第五篇](/posts/xlua-value-types-and-performance/#pack-unpack) |
| `XLuaGenAutoRegister.cs` | 为当前 LuaEnv 登记 Wrap、接口创建器等生成能力 | [本文下文](#generated-registration) |

这些文件在构建前生成；`LuaEnv` 初始化时接入生成能力，具体类型的 Wrap 则在首次使用时加载。

## 创建 Native Lua 环境 {#native-lua-environment}

`LuaEnv` 首先校验 C# 封装层与 Native XLua 插件的版本，并从 Native 层取得当前实现使用的 Registry 伪索引：

```csharp
if (LuaAPI.xlua_get_lib_version() != LIB_VERSION_EXPECT)
{
    throw new InvalidProgramException("wrong lib version");
}

LuaIndexes.LUA_REGISTRYINDEX = LuaAPI.xlua_get_registry_index();
```

版本校验用于尽早发现 C# 源码和 `xlua.dll`、`.so` 或 `.a` 不匹配的问题；Registry 伪索引由 Native 层提供，是为了兼容不同 Lua/LuaJIT 实现。

随后创建 Lua VM，并打开运行所需的基础库：

```csharp
rawL = LuaAPI.luaL_newstate();

LuaAPI.luaopen_xlua(rawL);
LuaAPI.luaopen_i64lib(rawL);
```

三者的职责分别是：

```text
luaL_newstate
    → 创建 Lua State

luaopen_xlua
    → 打开 Lua 标准库
    → 注册 XLua Native 扩展

luaopen_i64lib
    → 注册 int64/uint64 扩展支持
```

`luaL_newstate` 只创建 Lua State，并不会自动打开标准库。完成这一步后，XLua 得到了一个具备基础 Lua 运行能力、但尚未建立 C# 对象映射的 Lua State。

## 建立 ObjectTranslator 与核心桥接 {#object-translator}

Lua State 创建完成后，`LuaEnv` 为它创建一个专属的 `ObjectTranslator`：

```csharp
translator = new ObjectTranslator(this, rawL);
```

`ObjectTranslator` 是当前 `LuaEnv` 中所有 C# 与 Lua 数据转换的中心：

```text
LuaEnv
├── lua_State
└── ObjectTranslator
    ├── ObjectPool 与 reverseMap
    ├── userdata 弱值缓存
    ├── ObjectCasters
    ├── ObjectCheckers
    ├── MethodWrapsCache
    ├── delayWrap
    └── interfaceBridgeCreators
```

它负责：

```text
C# 对象 → Lua userdata
Lua 值   → C# 对象
参数检查与类型转换
Wrap 延迟加载
Delegate 与 Interface 适配
```

构造过程中还会在 Lua Registry 中创建 userdata 弱值缓存，等价结构为：

```lua
local cacheRef = setmetatable({}, { __mode = "v" })
```

它与 `ObjectPool`、`reverseMap` 共同维护 C# 对象和 Lua userdata 的身份映射，使同一个 C# 引用对象多次进入 Lua 时可以尽量复用同一个 userdata。具体引用关系见系列第四篇的[ObjectPool、reverseMap 与 cacheRef](/posts/xlua-object-lifecycle/#object-mapping)。

随后 `LuaEnv` 建立基础回调并把 Translator 加入全局池：

```csharp
translator.createFunctionMetatable(rawL);
translator.OpenLib(rawL);

ObjectTranslatorPool.Instance.Add(rawL, translator);
```

`OpenLib` 向 Lua 侧提供 `xlua.import_type`、`xlua.load_assembly`、`xlua.cast` 等基础入口。`ObjectTranslatorPool` 则建立：

```text
lua_State*
    → ObjectTranslator
```

以后静态 `lua_CFunction` 从 Lua 回调 C# 时，可以根据当前 `lua_State*` 找回正确的 Translator。异常处理、Unity `print` 重定向等基础运行支持也在这一阶段完成。

## 初始化 Lua 侧运行环境 {#lua-runtime-initialization}

XLua 会在 Lua 原生模块加载机制中插入自己的搜索入口，以支持内建模块、用户通过 `LuaEnv.AddLoader` 提供的自定义 Loader，以及 Unity `Resources`、`StreamingAssets` 等脚本来源。具体搜索顺序会随平台和编译配置变化，不影响 C# 与 Lua 交互的核心设计。

随后执行内置 Lua 初始化脚本 `init_xlua`，建立 Lua 侧使用 XLua 的主要入口，包括：

```text
全局 CS table
typeof 与 cast
xlua.hotfix
xlua.getmetatable / setmetatable
xlua.setclass
```

其中最关键的是 `CS` table。Lua 访问 C# 类型时的基本链路为：

```text
CS.UnityEngine.GameObject
    ↓
CS.__index 逐段拼接完整类型名
    ↓
xlua.import_type("UnityEngine.GameObject")
    ↓
ObjectTranslator.FindType
    ↓
GetTypeId
    ↓
必要时 TryDelayWrapLoader
```

这里建立的是 Lua 查找和使用 C# 类型的统一入口。具体的 `GameObjectWrap.__Register` 通常还没有执行，而是在第一次真正使用该类型时延迟加载。

XLua 还会在 Registry 中建立实例成员和静态成员的读写分派表，供不同类型的 `__index/__newindex` 共享，并保存：

- 主 Lua thread；
- 全局 `CS` table；
- `_G` 对应的 `LuaTable`；
- 统一 error handler 的 Registry reference。

这些 Registry 内容为 coroutine、`require "CS"`、`LuaEnv.Global`、成员分派以及带 traceback 的错误处理提供基础支持。

## 接入生成代码并完成初始化 {#complete-initialization}

通用基础设施建立后，`LuaEnv` 执行所有生成代码登记的初始化器：

```csharp
for (int i = 0; i < initers.Count; i++)
{
    initers[i](this, translator);
}
```

这些初始化器会把生成代码接入当前 `ObjectTranslator`：

```text
普通类型与枚举 Wrap
    → 登记到 delayWrap

InterfaceBridge
    → 登记 Bridge Creator

GCOptimize struct
    → 登记 Push/Get/Update

table optimize 类型
    → 登记专用 Caster
```

初始化器的静态触发方式、各生成产物的接入职责以及 Wrap 的延迟加载过程，将在下文的[总注册器：XLuaGenAutoRegister.cs](#generated-registration)中展开。

构造函数最后创建数组、Delegate 和 `IEnumerable` 的公共支持：

```text
数组公共 metatable
    → Length、索引读取与写入

Delegate 公共 metatable
    → 调用、合并与移除

IEnumerable pairs
    → 支持 Lua 侧迭代
```

`new LuaEnv()` 返回时，初始化结果可以归纳为：

```text
立即建立
├── Lua VM 与基础库
├── ObjectTranslator 与对象缓存
├── C#/Lua 基础回调
├── CS 类型访问入口
├── Registry 公共结构
└── 生成代码映射

延迟建立
└── 具体类型的 Wrap、class table 和实例 metatable
```

因此，XLua 初始化采用的核心策略是：通用运行设施立即建立，普通类型只登记 Wrap loader，具体 Wrap 在类型第一次使用时才真正注册。

## 总注册器：XLuaGenAutoRegister.cs {#generated-registration}

`XLuaGenAutoRegister.cs` 的核心作用是把 Generate Code 生成的类型适配代码接入每一个 `LuaEnv`，让 `ObjectTranslator` 知道某个 C# 类型应该使用哪个 Wrap 或 InterfaceBridge。

不过，“总注册器”并不表示所有生成文件都由它注册。各类生成产物的接入方式如下：

| 生成内容            | 接入方式                              |
| --------------- | --------------------------------- |
| 普通类型 Wrap       | 注册延迟加载函数                          |
| Enum Wrap       | 注册延迟加载函数                          |
| InterfaceBridge | 注册 Bridge 创建函数                    |
| 扩展方法            | 建立目标类型到 `MethodInfo` 的映射          |
| 值类型数组转换         | 连接 `WrapPusher` 生成的数组回调           |
| WrapPusher      | 使用自己的 `LuaEnv.AddIniter` 注册       |
| PackUnpack      | 静态方法，无须注册                         |
| DelegateBridge  | 由 `ObjectTranslator` 直接创建，无须在这里注册 |

因此，它更准确的定位是普通 Wrap、Enum Wrap、InterfaceBridge 以及部分全局生成能力的集中接入点。

### 生成的基本结构

文件名是 `XLuaGenAutoRegister.cs`，但其中主要的注册类叫作 `XLua_Gen_Initer_Register__`。生成代码近似如下：

```csharp
namespace XLua.CSObjectWrap
{
    public class XLua_Gen_Initer_Register__
    {
        static void wrapInit0(LuaEnv luaEnv, ObjectTranslator translator)
        {
            translator.DelayWrapLoader(typeof(Game.Player), GamePlayerWrap.__Register);

            translator.DelayWrapLoader(typeof(Game.Enemy), GameEnemyWrap.__Register);

            translator.DelayWrapLoader(typeof(Game.PlayerState), GamePlayerStateWrap.__Register);
        }

        static void Init(LuaEnv luaEnv, ObjectTranslator translator)
        {
            wrapInit0(luaEnv, translator);

            translator.AddInterfaceBridgeCreator(typeof(IPlayerView), IPlayerViewBridge.__Create);
        }

        static XLua_Gen_Initer_Register__()
        {
            LuaEnv.AddIniter(Init);
        }
    }
}
```

这里有两个主要入口：

```text
DelayWrapLoader
    → 普通类型 Wrap 和 Enum Wrap

AddInterfaceBridgeCreator
    → InterfaceBridge
```

### 注册器如何被自动触发

生成文件还会给 `ObjectTranslator` 添加一个静态占位字段：

```csharp
namespace XLua
{
    public partial class ObjectTranslator
    {
        static XLua.CSObjectWrap.XLua_Gen_Initer_Register__ s_gen_reg_dumb_obj = new XLua.CSObjectWrap.XLua_Gen_Initer_Register__();
    }
}
```

当 `ObjectTranslator` 类型进行静态初始化时，会创建 `XLua_Gen_Initer_Register__`，从而触发它的静态构造函数：

```csharp
static XLua_Gen_Initer_Register__()
{
    LuaEnv.AddIniter(Init);
}
```

`LuaEnv.AddIniter` 不会立即注册到某个 Lua State，而是把初始化函数加入一个静态列表：

```csharp
private static List<Action<LuaEnv, ObjectTranslator>> initers;

public static void AddIniter(Action<LuaEnv, ObjectTranslator> initer)
{
    if (initers == null)
    {
        initers = new List<Action<LuaEnv, ObjectTranslator>>();
    }

    initers.Add(initer);
}
```

这一阶段建立的是：

```text
XLua 生成代码
    ↓
LuaEnv.initers
    ↓
保存 Init 委托
```

### 每个 LuaEnv 都会执行一次 Init

创建新的 `LuaEnv` 时，XLua 先创建 Lua State 和 `ObjectTranslator`，然后执行所有初始化器：

```csharp
translator = new ObjectTranslator(this, rawL);

// 初始化 Lua 基础环境……

if (initers != null)
{
    for (int i = 0; i < initers.Count; i++)
    {
        initers[i](this, translator);
    }
}
```

完整触发链路为：

```text
ObjectTranslator 类型初始化
    ↓
创建 XLua_Gen_Initer_Register__
    ↓
静态构造函数调用 LuaEnv.AddIniter(Init)
    ↓
Init 被保存到全局初始化器列表
    ↓
创建 LuaEnv
    ↓
创建该 LuaEnv 的 ObjectTranslator
    ↓
遍历 LuaEnv.initers
    ↓
执行 XLua_Gen_Initer_Register__.Init
```

`initers` 列表是静态共享的，但下面这些字典属于具体的 `ObjectTranslator`：

```csharp
delayWrap
interfaceBridgeCreators
loaded_types
```

因此，生成代码的初始化函数只登记一次，但每个 `LuaEnv` 都会把注册信息写入自己的 `ObjectTranslator`。不同 `LuaEnv` 拥有不同的 Lua State、Registry 和 metatable，实际的 Lua 注册结果不能共用。

### 普通 Wrap 与 Enum Wrap 使用延迟注册

总注册器并不会在 `LuaEnv` 创建时立即执行：

```csharp
GamePlayerWrap.__Register(L);
```

它只是保存类型与注册函数之间的映射：

```csharp
translator.DelayWrapLoader(typeof(Game.Player), GamePlayerWrap.__Register);
```

`ObjectTranslator` 内部保存：

```csharp
private readonly Dictionary<Type, Action<RealStatePtr>> delayWrap;
```

此时形成：

```text
Game.Player
    → GamePlayerWrap.__Register
```

但 `Player` 的 Lua class table 和实例 metatable 尚未真正创建。

当 Lua 第一次访问：

```lua
local player = CS.Game.Player()
```

或者 C# 第一次把 `Player` 对象压入 Lua 时，XLua 最终会调用：

```csharp
ObjectTranslator.GetTypeId
```

如果该类型尚未加载，就会进入：

```csharp
TryDelayWrapLoader(L, typeof(Player));
```

其核心逻辑近似为：

```csharp
public bool TryDelayWrapLoader(RealStatePtr L, Type type)
{
    if (loaded_types.ContainsKey(type))
    {
        return true;
    }

    loaded_types.Add(type, true);

    Action<RealStatePtr> loader;

    if (delayWrap.TryGetValue(type, out loader))
    {
        delayWrap.Remove(type);
        loader(L);
    }
    else
    {
        Utils.ReflectionWrap(L, type, ...);
    }

    return true;
}
```

如果找到生成代码，`loader(L)` 实际调用的就是：

```csharp
GamePlayerWrap.__Register(L);
```

随后由 Wrap 内部完成：

```text
BeginObjectRegister
    ↓
注册实例方法、getter、setter 和元方法
    ↓
EndObjectRegister
    ↓
BeginClassRegister
    ↓
注册构造函数与静态成员
    ↓
EndClassRegister
```

所以完整链路是：

```text
LuaEnv 初始化
    ↓
DelayWrapLoader(Player, PlayerWrap.__Register)
    ↓
只保存 loader，不创建 metatable
    ↓
第一次访问或压入 Player
    ↓
GetTypeId(Player)
    ↓
TryDelayWrapLoader(Player)
    ↓
PlayerWrap.__Register(L)
    ↓
真正创建 class table 与实例 metatable
```

枚举使用同一套延迟加载机制：

```csharp
translator.DelayWrapLoader(typeof(PlayerState), PlayerStateWrap.__Register);
```

当 Lua 第一次访问：

```lua
CS.Game.PlayerState.Attack
```

才会调用 `PlayerStateWrap.__Register(L)`，完成枚举成员和 `__CastFrom` 等内容的注册。

### 为什么采用延迟注册

如果项目配置了几百个 `LuaCallCSharp` 类型，而当前 Lua 业务只使用其中几十个，在初始化时执行所有 Wrap 会创建大量暂时用不到的 class table、metatable 和回调，并增加 `LuaEnv` 的初始化时间。

延迟注册之后：

```text
LuaEnv 初始化
    ↓
只建立 Type → Wrap.__Register 映射
    ↓
真正使用某个类型时再注册
```

因此 `XLuaGenAutoRegister` 对 Wrap 的准确行为是自动登记 Wrap 的加载方式，而不是立即执行所有 Wrap 注册。

### 防止重复注册与循环依赖

`ObjectTranslator` 使用 `loaded_types` 记录已经加载过或正在加载的类型：

```csharp
if (loaded_types.ContainsKey(type))
{
    return true;
}

loaded_types.Add(type, true);
```

一个类型在同一个 `LuaEnv` 中最多执行一次 `Wrap.__Register`。调用后还会从 `delayWrap` 中移除 loader：

```csharp
delayWrap.Remove(type);
```

执行 loader 前，XLua 还会先创建一个空 metatable：

```csharp
LuaAPI.luaL_newmetatable(L, type.FullName);
LuaAPI.lua_pop(L, 1);
```

这是为了处理注册过程中的循环依赖。例如：

```csharp
public class Player
{
    public static readonly Player Default = new Player();
}
```

注册 `PlayerWrap` 时可能需要把 `Player.Default` 压入 Lua，而压入该对象又需要取得 `Player` 的 metatable。提前把类型加入 `loaded_types` 并创建空 metatable，可以避免递归注册。

注册完成后还会检查 Lua 栈顶：

```csharp
if (top != LuaAPI.lua_gettop(L))
{
    throw new Exception("top change, before:" + top + ", after:" + LuaAPI.lua_gettop(L));
}
```

用于确保 `__Register` 没有破坏 Lua 栈平衡。

### InterfaceBridge Creator 的注册

InterfaceBridge 不需要创建供 Lua 调用的 class table 或实例 metatable。它解决的是：

```text
Lua table → 指定 C# 接口对象
```

因此总注册器直接建立接口类型与 Bridge 创建函数之间的映射：

```csharp
translator.AddInterfaceBridgeCreator(typeof(IPlayerView), IPlayerViewBridge.__Create);
```

`ObjectTranslator` 内部保存：

```csharp
Dictionary<Type, Func<int, LuaEnv, LuaBase>> interfaceBridgeCreators;
```

运行时转换链路是：

```text
目标类型是 IPlayerView
    ↓
CreateInterfaceBridge
    ↓
查找 interfaceBridgeCreators
    ↓
找到 IPlayerViewBridge.__Create
    ↓
创建 IPlayerViewBridge
```

接口 creator 在 `LuaEnv` 初始化时直接登记，但真正的 Bridge 对象仍然只在发生类型转换时创建。

### DelegateBridge、WrapPusher 与 PackUnpack 的接入方式

`DelegateBridge` 不需要在这里注册。它使用统一生成的 `DelegateBridge` 类型，`ObjectTranslator.CreateDelegateBridge` 会直接创建：

```csharp
bridge = new DelegateBridge(reference, luaEnv);
```

随后调用：

```csharp
bridge.GetDelegateByType(delegateType);
```

根据目标 Delegate 类型返回对应委托，所以不需要维护 `Delegate Type → Bridge Creator` 映射。

`WrapPusher.cs` 则有自己的初始化器：

```csharp
static void Init(LuaEnv luaEnv, ObjectTranslator translator)
{
    translator.RegisterPushAndGetAndUpdate<Vector3>(
        translator.PushUnityEngineVector3,
        translator.Get,
        translator.UpdateUnityEngineVector3);
}
```

它同样通过自己的静态初始化代码调用：

```csharp
LuaEnv.AddIniter(Init);
```

因此两者最终都会进入 `LuaEnv.initers`，但来源不同：

```text
XLuaGenAutoRegister.cs
    → Wrap loader
    → InterfaceBridge creator

WrapPusher.cs
    → 值类型 Push/Get/Update
    → table caster
```

`PackUnpack.cs` 只是静态 `CopyByValue` 方法，由 `WrapPusher` 直接调用，不包含运行时映射，因此完全无须注册。

### 值类型数组回调的接入

`WrapPusher.cs` 会生成：

```csharp
StaticLuaCallbacks.__tryArrayGet
StaticLuaCallbacks.__tryArraySet
```

用于快速访问 `Vector3[]`、`Quaternion[]` 等值类型数组。`XLuaGenAutoRegister.cs` 中生成的 `InternalGlobals` 静态初始化代码会把它们接入全局调用点：

```csharp
genTryArrayGetPtr = StaticLuaCallbacks.__tryArrayGet;

genTryArraySetPtr = StaticLuaCallbacks.__tryArraySet;
```

数组访问时，XLua 先尝试这些生成回调：

```csharp
if (InternalGlobals.genTryArrayGetPtr != null)
{
    if (InternalGlobals.genTryArrayGetPtr(
        type,
        L,
        translator,
        array,
        index))
    {
        return 1;
    }
}
```

如果匹配到配置的值类型数组，就走生成的强类型路径；否则才退回 `Array.GetValue` 等通用路径，从而避免值类型数组访问中的装箱。

### 扩展方法映射

总注册器还会为配置的扩展方法生成：

```csharp
Dictionary<Type, IEnumerable<MethodInfo>>
```

例如：

```csharp
public static class PlayerExtensions
{
    public static void ResetState(this Player player)
    {
    }
}
```

会形成：

```text
Player
    → PlayerExtensions.ResetState
```

生成代码近似为：

```csharp
extensionMethodMap = new Dictionary<Type, IEnumerable<MethodInfo>>
    {
        {
            typeof(Player),
            new List<MethodInfo>
            {
                new ExtensionDelegate(PlayerExtensions.ResetState).Method
            }
        }
    };
```

当 XLua 为目标类型建立反射 Wrap 或补充扩展方法时，可以直接从 `InternalGlobals.extensionMethodMap` 取得相应方法，不需要重复扫描所有程序集和扩展方法容器。

### 拆分 wrapInitN

如果把数百个 Wrap 的登记语句全部放在一个 `Init` 方法中，会使单个方法体过大。因此模板将注册代码拆分为多个方法：

```csharp
static void wrapInit0(...)
{
    // 第一批类型
}

static void wrapInit1(...)
{
    // 下一批类型
}

static void wrapInit2(...)
{
    // 下一批类型
}
```

主入口只负责依次调用：

```csharp
static void Init(LuaEnv luaEnv, ObjectTranslator translator)
{
    wrapInit0(luaEnv, translator);
    wrapInit1(luaEnv, translator);
    wrapInit2(luaEnv, translator);

    // 注册 InterfaceBridge creator
}
```

这可以控制生成方法的大小，降低 C# 编译器、Mono 和 IL2CPP 处理超大方法时的压力。

### 完整流程

总注册器参与的完整流程可以概括为：

```text
生成代码进入程序集
    ↓
ObjectTranslator 静态初始化
    ↓
XLua_Gen_Initer_Register__ 静态构造
    ↓
LuaEnv.AddIniter(Init)
    ↓
创建新的 LuaEnv
    ↓
创建对应 ObjectTranslator
    ↓
LuaEnv 执行所有 initers
    ↓
登记 Type → Wrap.__Register
登记 Interface → Bridge.__Create
登记值类型 Push/Get/Update
    ↓
LuaEnv 初始化完成
```

此时普通 Wrap 尚未真正注册到 Lua。直到首次使用某个类型：

```text
第一次访问 CS.Game.Player
或者第一次把 Player 对象压入 Lua
    ↓
GetTypeId(Player)
    ↓
TryDelayWrapLoader(Player)
    ↓
PlayerWrap.__Register(L)
    ↓
创建 Player class table
创建 Player 实例 metatable
注册成员与元方法
    ↓
后续直接复用
```

所以 `XLuaGenAutoRegister.cs` 最重要的设计是：将生成代码自动接入每一个 `LuaEnv`，并对普通 Wrap 和 Enum Wrap 采用按类型延迟注册，避免把全部注册成本集中在 `LuaEnv` 初始化阶段。
