---
title: "3. C# 如何调用 Lua"
slug: xlua-csharp-call-lua
date: 2026-09-15
lastmod: 2026-11-19
description: "分析 DoString、LoadString、LuaFunction 与 Registry 引用，追踪 DelegateBridge 和 InterfaceBridge 的生成及调用。"
categories:
  - "Lua/XLua/XLua 2.1.16 源码阅读"
tags:
  - Lua
  - XLua
  - Unity
series:
  - XLua 2.1.16 源码阅读
series_order: 3
draft: false
toc: true
---


从 C# 侧进入 Lua，主要有四类入口：

- `LuaEnv.DoString`：编译并立即执行一段 Lua Chunk；
- `LuaEnv.LoadString`：只编译 Chunk，将其转换成 `LuaFunction` 或 C# Delegate；
- `LuaFunction` 与 `LuaTable`：由 C# 直接持有并操作 Lua 对象；
- DelegateBridge 与 InterfaceBridge：将 Lua function/table 适配成强类型 C# 调用接口。

它们最终都依赖 Lua Stack 传递参数和返回值，并由 `ObjectTranslator` 完成 C# 值与 Lua 值之间的转换。

## DoString：编译并立即执行 Lua Chunk {#do-string}

`LuaEnv.DoString` 的核心实现如下：

```csharp
int oldTop = LuaAPI.lua_gettop(L);
int errFunc = LuaAPI.load_error_func(L, errorFuncRef);

if (LuaAPI.xluaL_loadbuffer(L, chunk, chunk.Length, chunkName) == 0)
{
    if (LuaAPI.lua_pcall(L, 0, -1, errFunc) == 0)
    {
        LuaAPI.lua_remove(L, errFunc);
        return translator.popValues(L, oldTop);
    }
}
```

完整过程是：

```text
LuaEnv.DoString
    ↓
xluaL_loadbuffer
把 Lua 源码编译成 Closure，并压入 Lua Stack
    ↓
lua_pcall
执行 Closure
    ↓
Lua 返回值留在栈上
    ↓
ObjectTranslator.popValues
Lua 值转换成 C# object[]
    ↓
恢复调用前的 Lua Stack
```

`xluaL_loadbuffer` 只负责编译 Lua 代码，真正执行代码的是 `lua_pcall`。`DoString` 使用 `object[]` 接收全部返回值，适合初始化和执行临时代码，但会产生数组、装箱和动态类型转换。

## LoadString：只编译，不立即执行 {#load-string}

`LoadString<T>` 在调用 `xluaL_loadbuffer` 后没有继续调用 `lua_pcall`，而是将栈顶的 Lua function 转换成 `LuaFunction` 或 C# Delegate：

```csharp
LuaAPI.xluaL_loadbuffer(L, chunk, chunk.Length, chunkName);

T result = (T)translator.GetObject(L, -1, typeof(T));

LuaAPI.lua_settop(L, oldTop);
return result;
```

例如，可以直接把编译后的 Chunk 转换成强类型 Delegate：

```csharp
Func<int, int, int> add =
    luaEnv.LoadString<Func<int, int, int>>(
        "local a, b = ...; return a + b"
    );

int result = add(10, 20);
```

这段代码的转换过程是：

```text
LoadString
    ↓
xluaL_loadbuffer
    ↓
Lua Stack 顶部得到 Lua function
    ↓
ObjectTranslator.GetObject
    ↓
LuaFunction 或 DelegateBridge
```

因此，`DoString` 是“编译并执行”，`LoadString` 是“编译并返回可调用对象”。

## C# 如何长期持有 Lua function 和 table {#lua-registry-references}

Lua function 和 table 都由 Lua GC 管理。C# 不能只保存一个指向 Lua 对象的裸指针，否则 Lua 对象可能在 C# 使用之前被回收。

XLua 使用 Lua Registry 引用这些对象。以 `LuaFunction` 为例，其创建过程是：

```csharp
LuaAPI.lua_pushvalue(L, idx);
return new LuaFunction(
    LuaAPI.luaL_ref(L),
    translator.luaEnv
);
```

`luaL_ref` 将对象保存到 Registry，并返回一个整数引用：

```text
Lua function/table
    ↓
luaL_ref
    ↓
Registry[reference] = Lua 对象
    ↓
LuaFunction/LuaTable 保存 reference
```

`LuaFunction` 和 `LuaTable` 都继承自 `LuaBase`。它们保存的不是 Lua 对象本身，而是所属 `LuaEnv` 和一个 `luaReference`：

```text
LuaBase
├── LuaEnv
└── luaReference
        ↓
    Lua Registry 中的真实对象
```

后续需要使用该对象时，通过 `lua_getref` 将它重新压入 Lua Stack：

```csharp
internal virtual void push(RealStatePtr L)
{
    LuaAPI.lua_getref(L, luaReference);
}
```

当 `LuaFunction.Dispose()` 或 `LuaTable.Dispose()` 执行时，最终会通过 `lua_unref` 释放 Registry 引用。Registry 引用未释放之前，Lua GC 会认为该对象仍然存活。

## LuaFunction 的调用过程 {#lua-function-call}

以泛型调用接口为例：

```csharp
int result = luaFunction.Func<int, int, int>(10, 20);
```

其核心实现如下：

```csharp
int oldTop = LuaAPI.lua_gettop(L);
int errFunc = LuaAPI.load_error_func(L, luaEnv.errorFuncRef);

LuaAPI.lua_getref(L, luaReference);

translator.PushByType(L, a1);
translator.PushByType(L, a2);

int error = LuaAPI.lua_pcall(L, 2, 1, errFunc);

translator.Get(L, -1, out result);
LuaAPI.lua_settop(L, oldTop);
```

完整调用链为：

```text
C# 调用 LuaFunction.Func
    ↓
保存 oldTop，压入错误处理函数
    ↓
lua_getref 取回 Lua function
    ↓
ObjectTranslator.PushByType
C# 参数转换成 Lua 值
    ↓
lua_pcall
    ↓
ObjectTranslator.Get
Lua 返回值转换成 C# 返回值
    ↓
恢复 oldTop
```

`lua_pcall` 的参数明确描述了本次调用的输入和输出数量：

```csharp
lua_pcall(L, nArgs, nResults, errFunc);
```

无论调用成功还是参数转换、返回值转换发生异常，最终都必须恢复调用前的栈顶。否则一次调用残留的数据会污染之后的 Lua 调用。

`LuaFunction` 提供了两类接口：

```csharp
Func<T1, T2, TResult>()
Action<T1, T2>()
Call(params object[] args)
```

`Func/Action` 使用泛型 `PushByType/Get`，属于低分配路径；`Call` 使用 `object[]`、`PushAny` 和 `popValues`，更通用，但会产生数组、装箱和动态类型判断。

## LuaTable.Get/Set 也可能执行 Lua 代码 {#lua-table-access}

例如：

```csharp
int hp = luaEnv.Global.Get<int>("hp");
luaEnv.Global.Set("hp", 100);
```

读取过程是：

```csharp
LuaAPI.lua_getref(L, luaReference);
translator.PushByType(L, key);
LuaAPI.xlua_pgettable(L, -2);
translator.Get(L, -1, out value);
```

写入过程是：

```csharp
LuaAPI.lua_getref(L, luaReference);
translator.PushByType(L, key);
translator.PushByType(L, value);
LuaAPI.xlua_psettable(L, -3);
```

这里使用的是受保护的 table get/set，而不是简单的 `rawget/rawset`，因此访问过程中可能触发 Lua table 的 `__index` 和 `__newindex`。所以 `LuaTable.Get/Set` 虽然表现为字段访问，也可能间接执行 Lua 代码。

## 从 LuaTable.Get 取得强类型 Delegate {#lua-function-to-delegate}

实际项目中，更常见的调用方式是直接取得一个强类型 Delegate：

```csharp
Action<int> callback = luaEnv.Global.Get<Action<int>>("callback");

callback(10);
```

转换过程是：

```text
LuaTable.Get<Action<int>>
    ↓
ObjectTranslator.Get
    ↓
ObjectCasters 发现目标类型是 Delegate
    ↓
ObjectTranslator.CreateDelegateBridge
    ↓
DelegateBridge 创建真正的 Action<int>
```

之后调用 `Action<int>` 时，实际执行的是生成在 `DelegateBridge` 中的方法：

```csharp
public void __Gen_Delegate_Imp0(int p0)
{
    int errFunc = LuaAPI.pcall_prepare(L, errorFuncRef, luaReference);

    translator.PushByType(L, p0);
    PCall(L, 1, 0, errFunc);

    LuaAPI.lua_settop(L, errFunc - 1);
}
```

DelegateBridge 提供了强类型 C# Delegate 的目标方法，其内部仍通过 Lua Stack、Registry 引用和 `lua_pcall` 完成调用：

```text
C# Delegate
    ↓
DelegateBridge.__Gen_Delegate_Imp
    ↓
根据 luaReference 取回 Lua function
    ↓
压入强类型参数
    ↓
lua_pcall
    ↓
读取返回值、ref 和 out
```

生成代码已经确定参数和返回值类型，因此不需要每次通过 `object[]` 描述调用签名。

## DelegateBridge 的生成结构与运行过程 {#delegate-bridge}

Delegate Wrap 和 DelegateBridge 名称相近，但处理的是相反方向的问题：

| 组件 | 原始对象 | 调用方向 | 职责 |
| --- | --- | --- | --- |
| Delegate Wrap | 已存在的 C# Delegate | Lua → C# | 让 Lua 调用、合并和移除 C# Delegate |
| DelegateBridge | Lua function | C# → Lua | 把 Lua function 适配成指定类型的 C# Delegate |

例如，Lua 调用从 C# 取得的 `obj.Callback(10)` 属于 Delegate Wrap；Lua 把一个 `function` 传给参数类型为 `DamageHandler` 的 C# 方法，则需要 DelegateBridge。

### DelegateBridge 的基本结构

`DelegateBridge` 是继承 `LuaBase` 的 C# 托管对象：

```csharp
public abstract class DelegateBridgeBase : LuaBase
{
    ...
}

public partial class DelegateBridge : DelegateBridgeBase
{
    ...
}
```

它不是 userdata 的 metatable，而是连接 C# Delegate 与 Lua function 的中间对象，主要持有：

```text
Lua function 的 Registry reference
+ 所属 LuaEnv
+ error handler reference
+ 已创建的强类型 C# Delegate 缓存
```

引用关系为：

```text
C# DamageHandler
    │ Target
    ▼
DelegateBridge
    │ luaReference
    ▼
Lua Registry
    │
    ▼
Lua function
```

C# 需要的是一个签名确定的真实 Delegate。例如：

```csharp
public delegate int DamageHandler(int damage);
```

它要求目标方法也具有 `int Method(int)` 形式，Lua function 本身没有 CLR 方法签名，因此 XLua 必须预先准备一个强类型 C# 方法：

```csharp
public int __Gen_Delegate_Imp0(int damage)
{
    // 将 damage 压入 Lua 栈
    // 调用 luaReference 指向的 Lua function
    // 从 Lua 栈读取 int 返回值
}
```

然后用这个方法构造真正的 C# Delegate：

```csharp
new DamageHandler(__Gen_Delegate_Imp0);
```

### 生成范围

生成器从 `CSharpCallLua` 中筛选 Delegate：

```csharp
var delegateTypes = CSharpCallLua.Where(type => typeof(Delegate).IsAssignableFrom(type));
```

例如：

```csharp
[CSharpCallLua]
public static List<Type> CSharpCallLua = new List<Type>
{
    typeof(DamageHandler),
    typeof(Func<int, int>)
};
```

这些 Delegate 的 `Invoke` 签名会被提取出来；Hotfix 方法需要的签名也会进入相同的生成过程。生成结果集中写入 `DelegatesGensBridge.cs`，而不是为每个 Delegate 单独创建 Bridge 文件。

### 相同签名复用调用体

假设存在两个不同的 Delegate 类型：

```csharp
public delegate int DamageHandler(int value);
public delegate int ScoreCalculator(int value);
```

生成器比较返回值类型、参数数量、参数类型、`ref/out` 和 `params` 标记。二者签名相同，因此只生成一个：

```csharp
public int __Gen_Delegate_Imp0(int value)
{
    ...
}
```

再在 `GetDelegateByType` 中构造不同的 Delegate：

```csharp
public override Delegate GetDelegateByType(Type type)
{
    if (type == typeof(DamageHandler))
        return new DamageHandler(__Gen_Delegate_Imp0);

    if (type == typeof(ScoreCalculator))
        return new ScoreCalculator(__Gen_Delegate_Imp0);

    return null;
}
```

关系是：

```text
DamageHandler ───────┐
                     ├──→ __Gen_Delegate_Imp0(int) → int
ScoreCalculator ─────┘
```

复用的是参数压栈、Lua 调用和返回值读取逻辑；创建出的仍然是类型不同的 C# Delegate。

### 生成的 Bridge 方法

`DamageHandler` 对应的调用体可以简化为：

```csharp
public partial class DelegateBridge : DelegateBridgeBase
{
    public int __Gen_Delegate_Imp0(int damage)
    {
        RealStatePtr L = luaEnv.rawL;
        int errFunc = LuaAPI.pcall_prepare(L, errorFuncRef, luaReference);

        LuaAPI.xlua_pushinteger(L, damage);
        PCall(L, 1, 1, errFunc);

        int result = LuaAPI.xlua_tointeger(L, errFunc + 1);
        LuaAPI.lua_settop(L, errFunc - 1);
        return result;
    }
}
```

`pcall_prepare` 从 Registry 取出 error handler 和目标 Lua function：

```c
LUA_API int pcall_prepare(
    lua_State* L,
    int error_func_ref,
    int func_ref)
{
    lua_rawgeti(L, LUA_REGISTRYINDEX, error_func_ref);
    lua_rawgeti(L, LUA_REGISTRYINDEX, func_ref);
    return lua_gettop(L) - 1;
}
```

调用前的 Lua 栈近似为：

```text
errFunc     error handler
errFunc+1   Lua function
errFunc+2   damage
```

执行 `lua_pcall` 后，Lua function 和参数被弹出，返回值位于 `errFunc + 1`。读取完成后，`lua_settop(L, errFunc - 1)` 将 Lua 栈恢复到调用前状态。真实模板还会在 `THREAD_SAFE` 或 `HOTFIX_ENABLE` 下对整个调用过程加 `luaEnvLock`。

### Lua function 转成 C# Delegate

假设 C# 方法为：

```csharp
public void SetCallback(DamageHandler callback)
{
    this.callback = callback;
}
```

Lua 调用：

```lua
player:SetCallback(function(damage)
    return damage * 2
end)
```

`PlayerWrap` 读取参数时发现 Lua 栈上是 function，而目标参数类型是 `DamageHandler`，`ObjectCaster` 随后调用：

```csharp
translator.CreateDelegateBridge(
    L,
    typeof(DamageHandler),
    luaIndex);
```

完整转换过程为：

```text
Lua function
    ↓
ObjectCaster 确认目标类型是 DamageHandler
    ↓
CreateDelegateBridge
    ↓
为 Lua function 创建 Registry reference
    ↓
创建 DelegateBridge(reference, luaEnv)
    ↓
GetDelegateByType(typeof(DamageHandler))
    ↓
new DamageHandler(bridge.__Gen_Delegate_Imp0)
    ↓
将真正的 DamageHandler 传给 C# 方法
```

转换完成后，C# Delegate 的结构可以理解为：

```text
DamageHandler
├─ Target：DelegateBridge
└─ Method：__Gen_Delegate_Imp0
```

当 C# 执行：

```csharp
int result = callback(10);
```

调用链为：

```text
C# callback(10)
    ↓
DelegateBridge.__Gen_Delegate_Imp0(10)
    ↓
根据 luaReference 从 Registry 取出 Lua function
    ↓
将参数 10 压入 Lua 栈
    ↓
lua_pcall
    ↓
Lua function 返回 20
    ↓
从 Lua 栈读取 int
    ↓
返回 C# result = 20
```

### `ref/out` 与多返回值

假设 Delegate 为：

```csharp
public delegate bool TryGetValue(
    string key,
    out int value);
```

对应 Lua function需要返回两个值：

```lua
function(key)
    if key == "hp" then
        return true, 100
    end

    return false, 0
end
```

返回顺序为：

```text
第一个 Lua 返回值：C# Delegate 的返回值 bool
第二个 Lua 返回值：out int value
```

纯 `out` 参数在调用 Lua 前不会压入初始值；`ref` 参数既是输入也是输出，因此先作为参数传给 Lua，再从返回值中读取新值。模板按照“普通返回值在前、`ref/out` 依次在后”的顺序读取，并写回 C# 参数。

对于 `params`，生成方法会把数组元素展开为多个 Lua 参数，并按展开后的参数数量调用 `PCall`。

### 同一个 Lua function 的 Bridge 复用

`CreateDelegateBridge` 会用 Lua function 本身查询 Registry：

```text
Registry[Lua function] → luaReference
```

第一次转换时，它通过 `luaL_ref` 强引用 Lua function，创建 `DelegateBridge`，并保存：

```text
luaReference → WeakReference<DelegateBridge>
```

再次转换同一个 Lua function 时，如果原 Bridge 仍然存活，就直接复用。`DelegateBridgeBase` 内部还缓存：

```text
Delegate Type → C# Delegate
```

因此同一个 Lua function 多次转成 `DamageHandler` 时，会返回已经创建的 Delegate；同一个 Lua function 转换成多个已支持的 Delegate 类型时，则共享一个 Bridge：

```text
同一个 Lua function
    ↓
同一个 DelegateBridge
├─ DamageHandler    → DamageHandler Delegate
└─ ScoreCalculator → ScoreCalculator Delegate
```

只有一种类型时，Bridge 使用 `firstKey/firstValue` 保存首个缓存，避免立即创建 Dictionary；出现第二种 Delegate 类型后，才升级为 `Dictionary<Type, Delegate>`。

### 生命周期与双向引用

只要 C# Delegate 仍然存活，目标 Lua function 就不能被 Lua GC 回收：

```text
C# Delegate
    ──强引用──→ DelegateBridge
                   │ luaReference
                   ▼
              Lua Registry
                   ──强引用──→ Lua function
```

`ObjectTranslator.delegate_bridges` 只保存 `WeakReference<DelegateBridge>`，避免 Translator 永久强引用所有 Bridge。真正让 Bridge 存活的是 C# 侧持有的 Delegate，因为该 Delegate 的 Target 就是 Bridge。

Bridge 释放时，XLua会执行：

```text
luaL_unref(luaReference)
    ↓
删除 Registry[Lua function] → luaReference 映射
    ↓
从 delegate_bridges 删除记录
```

如果由 C# Finalizer 触发释放，则不会直接在 Finalizer 线程操作 Lua VM，而是把释放请求加入 `LuaEnv` 队列，等待 `LuaEnv.Tick()` 处理。

销毁 `LuaEnv` 时还会检查是否存在活跃 Bridge：

```csharp
if (!translator.AllDelegateBridgeReleased())
{
    throw new InvalidOperationException(
        "try to dispose a LuaEnv with C# callback!");
}
```

如果 C# 仍持有 Delegate 就关闭 Lua VM，之后调用该 Delegate 将访问已经失效的 `lua_State*`，因此 XLua 直接阻止这种销毁顺序。

### AOT/IL2CPP 与生成代码

Editor/.NET 环境可以在运行时 Emit 与 Delegate 签名匹配的桥接方法，IL2CPP 则不能在运行时创建新的托管类型和方法。因此需要提前生成：

```csharp
public int __Gen_Delegate_Imp0(int value)
```

以及：

```csharp
return new DamageHandler(__Gen_Delegate_Imp0);
```

这样 IL2CPP 在构建期就能看到具体 Delegate 类型、参数和返回值类型、Bridge 方法及 Delegate 构造关系。复杂 Delegate 应明确加入 `CSharpCallLua`；如果找不到生成方法或受支持的通用适配方法，运行时会抛出：

```text
This type must add to CSharpCallLua
```

XLua 对少量简单签名还提供通用 `Action/Func` 适配路径，主要覆盖不超过四个参数、没有 `ref/out`、参数与返回值满足限制的情况，但这不能替代完整的生成配置。

### 运行时成本

生成后的 Bridge 不需要在每次调用时反射扫描 Delegate 的 `Invoke`、执行 `MethodInfo.Invoke` 或动态 Emit。调用路径已经静态展开为：

```text
强类型 C# Delegate
    ↓
强类型 __Gen_Delegate_ImpN
    ↓
参数压入 Lua 栈
    ↓
lua_pcall
    ↓
返回值和 ref/out 转换
```

仍然存在的成本包括 Lua C API 调用、参数 Push、`lua_pcall`、Lua 代码执行、返回值 Get、引用类型对象映射，以及特定编译配置下的线程锁和错误处理。

## 从 LuaTable.Get 取得接口对象 {#lua-table-to-interface}

当 C# 将一个 Lua table 读取成接口类型时：

```csharp
IMoveable obj = luaEnv.Global.Get<IMoveable>("player");
```

`ObjectTranslator` 会调用：

```csharp
CreateInterfaceBridge(L, typeof(IMoveable), index);
```

生成的 InterfaceBridge 保存 Lua table 的 Registry 引用。当 C# 调用：

```csharp
obj.Move(10, 20);
```

Bridge 内部会执行：

```text
根据 luaReference 取回 Lua table
    ↓
读取 table["Move"]
    ↓
检查结果是否为 Lua function
    ↓
将 table 自身作为 self 压栈
    ↓
压入 10、20
    ↓
lua_pcall
    ↓
读取返回值
```

之所以需要额外压入 table，是为了匹配 Lua 的冒号调用语义：

```lua
function player:Move(x, y)
end
```

它等价于：

```lua
player.Move(player, x, y)
```

InterfaceBridge 中的方法会查找并执行 Lua 函数，而属性访问则直接对 Lua table 进行 get/set。

## InterfaceBridge 的生成结构与运行过程 {#interface-bridge}

InterfaceBridge 解决的是“如何把一个 Lua table 交给需要 C# 接口的代码使用”的问题。

Lua table 可以提供与某个接口同名的方法和属性，但 CLR 使用的是名义类型系统：一个对象只有在其运行时类型明确声明实现了某个接口时，才能赋值给该接口。Lua table 即使在结构上完全符合接口，也不是真正的 CLR 接口对象。

假设 C# 定义了如下接口：

```csharp
public interface IPlayerView
{
    string Name { get; set; }

    void SetHp(int hp);

    int GetHp();
}
```

Lua 可以提供一个结构与之对应的 table：

```lua
local view = {
    Name = "Player",
    hp = 100
}

function view:SetHp(hp)
    self.hp = hp
end

function view:GetHp()
    return self.hp
end

return view
```

从 Lua 的角度看，这个 table 已经具备 `IPlayerView` 要求的成员；但是从 CLR 的角度看，它既不是 `IPlayerView`，也不存在从 Lua table 到 `IPlayerView` 的直接类型转换。因此 XLua 必须创建一个真正实现 `IPlayerView` 的 C# 对象，再由这个对象将接口调用转发到 Lua table。

### 生成的 Bridge 类

配置在 `CSharpCallLua` 中的每个接口都会生成一个对应的 Bridge 文件。例如：

```csharp
[CSharpCallLua]
public interface IPlayerView
{
    string Name { get; set; }

    void SetHp(int hp);

    int GetHp();
}
```

会生成类似下面的类：

```csharp
public class IPlayerViewBridge : LuaBase, IPlayerView
{
    public static LuaBase __Create(int reference, LuaEnv luaenv)
    {
        return new IPlayerViewBridge(reference, luaenv);
    }

    public IPlayerViewBridge(int reference, LuaEnv luaenv)
        : base(reference, luaenv) { }

    // 这里继续生成 IPlayerView 所有成员的转发代码
}
```

其中最关键的是：

```csharp
IPlayerViewBridge : LuaBase, IPlayerView
```

`IPlayerViewBridge` 是一个真实的 CLR 类型，并且在类型定义中明确实现了 `IPlayerView`，所以 C# 可以正常持有和调用它：

```csharp
IPlayerView view = bridge;
view.SetHp(100);
```

但 Bridge 本身不实现具体的业务逻辑。它继承 `LuaBase`，通过其中的 `luaReference` 找到对应的 Lua table，再将接口成员调用转发给这个 table：

```text
C# 调用 IPlayerView
        ↓
IPlayerViewBridge
        ↓
luaReference
        ↓
Lua Registry 中的 table
        ↓
table 对应的方法、属性或事件
```

因此，InterfaceBridge 本质上是一个由 C# 生成、真正实现目标接口，并把接口操作转发给 Lua table 的代理对象。

### Bridge 的注册与创建

`XLuaGenAutoRegister.cs` 会把接口类型和对应的 Bridge 创建函数注册到 `ObjectTranslator`：

```csharp
translator.AddInterfaceBridgeCreator(
    typeof(IPlayerView),
    IPlayerViewBridge.__Create);
```

`ObjectTranslator` 内部由此建立如下映射：

```text
IPlayerView
    → IPlayerViewBridge.__Create
```

当 XLua 需要把 Lua 栈上的 table 转换成 `IPlayerView` 时，`ObjectTranslator.CreateInterfaceBridge` 会根据目标接口查找创建函数。核心过程可以简化为：

```csharp
LuaAPI.lua_pushvalue(L, index);

// 将 Lua table 放入 Registry，得到引用编号
int reference = LuaAPI.luaL_ref(L);

// 创建真正实现目标接口的 C# 对象
return creator(reference, luaEnv);
```

完整的转换链路是：

```text
Lua table
    ↓ Lua → C# 类型转换
目标类型是 IPlayerView
    ↓
ObjectTranslator 查找 interfaceBridgeCreators
    ↓
找到 IPlayerViewBridge.__Create
    ↓
将 table 保存到 Lua Registry
    ↓
得到 luaReference
    ↓
new IPlayerViewBridge(luaReference, luaEnv)
    ↓
以 IPlayerView 类型返回给 C#
```

Bridge 保存的不是 Lua table 的 C# 副本，而是 Lua Registry 中的引用编号。即使 table 已经离开原来的 Lua 栈，Bridge 仍能通过这个引用重新取得它。

### 接口方法的转发

例如 C# 调用：

```csharp
view.SetHp(100);
```

生成的显式接口实现会执行以下操作：

1. 根据 `luaReference` 从 Registry 取回 Lua table；
2. 读取 `table["SetHp"]`；
3. 检查取得的值是否为 Lua function；
4. 将 table 本身作为 `self` 压栈；
5. 将 C# 参数转换后压入 Lua 栈；
6. 通过 `lua_pcall` 调用 Lua 函数；
7. 读取返回值以及 `ref/out` 参数；
8. 处理错误并恢复 Lua 栈。

对应生成代码的核心结构如下：

```csharp
void IPlayerView.SetHp(int hp)
{
    RealStatePtr L = luaEnv.L;
    int oldTop = LuaAPI.lua_gettop(L);
    int errFunc = LuaAPI.load_error_func(L, luaEnv.errorFuncRef);

    LuaAPI.lua_getref(L, luaReference);       // 取回 Lua table
    LuaAPI.xlua_pushasciistring(L, "SetHp");
    LuaAPI.xlua_pgettable(L, -2);             // table["SetHp"]
    LuaAPI.lua_pushvalue(L, -2);              // table 作为 self
    LuaAPI.xlua_pushinteger(L, hp);            // C# 参数

    int error = LuaAPI.lua_pcall(L, 2, 0, errFunc);
    if (error != 0)
        luaEnv.ThrowExceptionFromError(oldTop);

    LuaAPI.lua_settop(L, oldTop);
}
```

Lua 侧对应的方法是：

```lua
function view:SetHp(hp)
    self.hp = hp
end
```

Lua 的冒号调用：

```lua
view:SetHp(100)
```

等价于：

```lua
view.SetHp(view, 100)
```

所以 Bridge 调用 Lua 函数时，除了压入接口方法的参数，还必须额外把 table 自身压入栈中作为 `self`。

如果接口方法有返回值：

```csharp
int hp = view.GetHp();
```

Bridge 会要求 Lua 函数返回一个值，再通过 `ObjectTranslator` 或对应的基础类型 API 将该值转换成 `int`，最后返回给 C#。模板也会展开多返回值、`ref`、`out` 和 `params` 等参数的压栈与回写逻辑。

### 接口属性的映射

接口属性直接映射到 Lua table 中的同名字段，而不是要求 Lua 提供 `get_Name` 和 `set_Name` 函数。

读取属性：

```csharp
string name = view.Name;
```

对应的操作是：

```text
从 Registry 取回 table
    ↓
读取 table["Name"]
    ↓
将 Lua 值转换成 string
    ↓
返回给 C#
```

设置属性：

```csharp
view.Name = "Alice";
```

对应：

```text
从 Registry 取回 table
    ↓
将 "Alice" 转换并压入 Lua 栈
    ↓
写入 table["Name"]
```

因此 Lua 侧可以直接提供字段：

```lua
local view = {
    Name = "Player"
}
```

### 接口事件与索引器的映射

假设接口声明了事件：

```csharp
event Action Changed;
```

C# 订阅事件：

```csharp
view.Changed += OnChanged;
```

会被 Bridge 转发到 Lua table 的 `add_Changed` 方法；取消订阅：

```csharp
view.Changed -= OnChanged;
```

则会转发到 `remove_Changed`。因此 Lua table 需要提供：

```lua
function view:add_Changed(handler)
    -- 保存或组合 handler
end

function view:remove_Changed(handler)
    -- 移除 handler
end
```

传入 Lua 的 `handler` 是一个 C# Delegate userdata。接口索引器也会由模板生成对应的读取和写入转发代码，并完成索引参数、返回值以及赋值参数的类型转换。

### 为什么不能只通过反射完成接口转换

反射可以根据名称查找 Lua table 中的方法，但不能让一个现有对象在运行时突然实现新的 CLR 接口。即使 XLua 确认 table 中同时存在 `SetHp` 和 `GetHp`，下面的转换依然不成立：

```csharp
IPlayerView view = luaTable;
```

统一的 `LuaTable` 类型也不可能在编译时实现用户项目里所有可能出现的接口。这里实际存在两个不同的问题：

1. 如何找到并调用 Lua table 中的对应成员；
2. 如何获得一个能够通过 CLR 接口类型检查的对象。

成员查找只能解决第一个问题；生成 `IPlayerViewBridge : IPlayerView` 才能解决第二个问题。

这也是为什么通常需要为每个接口生成不同的 Bridge：

```text
IPlayerView
    → IPlayerViewBridge : LuaBase, IPlayerView

IEnemyView
    → IEnemyViewBridge : LuaBase, IEnemyView
```

CLR 的接口实现关系记录在类型元数据中，不能只生成一个不实现具体接口的通用 `InterfaceBridge`，然后在运行时把它任意转换成 `IPlayerView` 或 `IEnemyView`。

### Emit 路径与 IL2CPP/AOT

在支持运行时代码生成的 Editor、Mono 或部分 .NET 环境中，如果 `ObjectTranslator` 没有找到预生成的 Bridge 创建器，XLua 可以尝试调用：

```csharp
CodeEmit.EmitInterfaceImpl(interfaceType)
```

运行时动态生成一个继承 `LuaBase` 并实现目标接口的 CLR 类型。因此在这些环境中，未预生成 InterfaceBridge 的接口有时也能正常工作。

IL2CPP/AOT 环境不能在运行时生成新的 CLR 类型，接口实现关系必须在构建前已经确定。因此需要将接口配置到 `CSharpCallLua` 并执行 Generate Code，预先生成和注册对应的 Bridge。否则 `CreateInterfaceBridge` 找不到创建器时会抛出类似异常：

```text
This type must add to CSharpCallLua: IPlayerView
```

所以预生成 InterfaceBridge 不仅是对调用路径的优化，也是 AOT 环境中让 Lua table 获得合法 CLR 接口身份所必需的步骤。

### 生命周期与运行时成本

InterfaceBridge 通过继承 `LuaBase` 保存 `luaReference`，形成如下引用关系：

```text
C# 接口引用
    ↓
InterfaceBridge
    ↓ luaReference
Lua Registry
    ↓
Lua table
```

只要 C# 仍持有 Bridge，对应的 Lua table 就会被 Registry 强引用，不会被 Lua GC 回收。Bridge 释放后，XLua 最终通过 `luaL_unref` 解除 Registry 引用；当不存在其他引用时，Lua table 才能被回收。

一次 InterfaceBridge 调用的主要运行时成本包括：

- 根据 Registry reference 取回 Lua table；
- 按成员名读取函数或字段；
- C# 参数到 Lua 值的转换与压栈；
- `lua_pcall` 跨语言调用；
- 返回值以及 `ref/out` 参数的转换；
- Lua 栈恢复和错误处理。

InterfaceBridge 与普通类型 Wrap 处理的是两个相反方向的问题：

```text
普通类型 Wrap：
C# 对象 → 暴露给 Lua 调用

InterfaceBridge：
Lua table → 包装成真正实现指定接口的 C# 对象，交给 C# 调用
```

这里所谓“把 Lua table 包装成接口”，并不是 table 自身真的实现了接口。真正通过 CLR 类型检查的是生成的 `IPlayerViewBridge`，Lua table 是 Bridge 背后的状态和行为提供者。
