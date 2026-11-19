---
title: "2. Lua 如何调用 C#"
slug: xlua-lua-call-csharp
date: 2026-09-15
lastmod: 2026-11-19
description: "从 CS 类型访问入口追踪到生成 Wrap，分析类型元表、成员分派、枚举、Delegate 与反射回退。"
categories:
  - "Lua/XLua/Xlua源码阅读 (2.1.16)"
tags:
  - Lua
  - XLua
  - Unity
series:
  - Xlua源码阅读 (2.1.16)
series_order: 2
draft: true
toc: true
---

一行 `go:SetActive(false)` 如何从 Lua 进入真实的 C# 方法？本文从 `CS` 表的类型解析开始，分析 Wrap 如何建立 class table 和实例 metatable，再追踪参数读取、直接调用与返回值压栈，并继续讨论枚举、C# Delegate 和未生成 Wrap 时的回退路径。

<details>
<summary>Xlua源码阅读 (2.1.16) · 系列目录</summary>

1. [从 LuaEnv 到类型延迟注册](/posts/xlua-initialization/)
2. [Lua 如何调用 C#](/posts/xlua-lua-call-csharp/)
3. [C# 如何调用 Lua](/posts/xlua-csharp-call-lua/)
4. [对象映射与跨语言生命周期](/posts/xlua-object-lifecycle/)
5. [值类型传递与运行时优化](/posts/xlua-value-types-and-performance/)
6. [Hotfix 的构建期注入与运行时分派](/posts/xlua-hotfix/)

</details>

Lua 调用 C# 可以分成两个阶段：

```text
第一阶段：CS.UnityEngine.GameObject 如何找到并注册 C# 类型
第二阶段：构造、方法和属性如何通过 Wrap 进入 C#
```

## CS 表如何解析 C# 类型 {#cs-type-resolution}

`LuaEnv` 初始化时并不会提前生成完整的 C# 类型树，而是只创建 `CS` table，并为它设置统一的 metatable：

```lua
CS = CS or {}
setmetatable(CS, metatable)
```

当 Lua 首次访问：

```lua
CS.UnityEngine.GameObject
```

每一级不存在的字段都会触发 `CS` metatable 的 `__index`：

```lua
function metatable:__index(key)
    local fqn = rawget(self, '.fqn')
    fqn = ((fqn and fqn .. '.') or '') .. key

    local obj = import_type(fqn)

    if obj == nil then
        obj = { ['.fqn'] = fqn }
        setmetatable(obj, metatable)
    elseif obj == true then
        return rawget(self, key)
    end

    rawset(self, key, obj)
    return obj
end
```

第一次访问 `UnityEngine` 时：

```text
import_type("UnityEngine")
    ↓
没有找到同名 C# 类型
    ↓
创建带有 .fqn = "UnityEngine" 的命名空间代理 table
```

继续访问 `GameObject` 时：

```text
import_type("UnityEngine.GameObject")
    ↓
ObjectTranslator.FindType
    ↓
找到 System.Type
    ↓
ObjectTranslator.GetTypeId
```

`ImportType` 的核心逻辑如下：

```csharp
Type type = translator.FindType(className);

if (type != null)
{
    if (translator.GetTypeId(L, type) >= 0)
        LuaAPI.lua_pushboolean(L, true);
}
else
{
    LuaAPI.lua_pushnil(L);
}
```

`ImportType` 找到类型后，不是直接把 `System.Type` 返回给 Lua，而是通过 `GetTypeId` 确保这个类型完成注册。类型注册过程中，`SetCSTable` 会把真正的 class table 写入对应路径：

```text
CS.UnityEngine.GameObject = class table
```

所以 `import_type` 返回 `true` 后，Lua 再执行：

```lua
rawget(self, key)
```

取出刚刚安装好的 class table。完整过程为：

```text
CS.UnityEngine.GameObject
    ↓
CS metatable.__index
    ↓
xlua.import_type("UnityEngine.GameObject")
    ↓
ObjectTranslator.FindType
    ↓
ObjectTranslator.GetTypeId
    ↓
ObjectTranslator.TryDelayWrapLoader
    ↓
GameObjectWrap.__Register
    ↓
Utils.SetCSTable
    ↓
CS.UnityEngine.GameObject = class table
```

## 普通类型 Wrap 的生成与注册 {#type-wrap}

以 `UnityEngine.GameObject` 为例，`LuaClassWrap.tpl.txt` 会生成一个 `UnityEngineGameObjectWrap`。其中 `__Register` 描述这个类型向 Lua 暴露哪些构造函数、实例方法、静态方法、字段、属性、事件和运算符：

```csharp
public class UnityEngineGameObjectWrap
{
    public static void __Register(RealStatePtr L)
    {
        ObjectTranslator translator = ObjectTranslatorPool.Instance.Find(L);
        Type type = typeof(UnityEngine.GameObject);

        // 注册实例侧的 metatable、方法表、getter 表和 setter 表。
        Utils.BeginObjectRegister(type, L, translator, 0, 1, 1, 0);
        Utils.RegisterFunc(L, Utils.METHOD_IDX, "SetActive", _m_SetActive);
        Utils.RegisterFunc(L, Utils.GETTER_IDX, "activeSelf", _g_get_activeSelf);
        Utils.EndObjectRegister(type, L, translator, null, null, null, null, null);

        // 注册 CS.UnityEngine.GameObject 对应的类表和构造函数。
        Utils.BeginClassRegister(type, L, __CreateInstance, 1, 0, 0);
        Utils.RegisterFunc(L, Utils.CLS_IDX, "Find", _m_Find);
        Utils.EndClassRegister(type, L, translator);
    }
}
```

每个生成的回调都符合 Lua 所需的 `lua_CFunction` 形式。方法体直接从 Lua 栈读取参数、取得 `self`、调用目标 C# 方法，再把返回值写回 Lua 栈：

```csharp
[MonoPInvokeCallback(typeof(LuaCSFunction))]
static int _m_SetActive(RealStatePtr L)
{
    try
    {
        ObjectTranslator translator = ObjectTranslatorPool.Instance.Find(L);

        if (LuaAPI.lua_gettop(L) == 2 &&
            translator.Assignable<UnityEngine.GameObject>(L, 1) &&
            LuaAPI.lua_isboolean(L, 2))
        {
            UnityEngine.GameObject self =
                (UnityEngine.GameObject)translator.FastGetCSObj(L, 1);
            bool value = LuaAPI.lua_toboolean(L, 2);

            self.SetActive(value);       // 静态绑定后的直接 C# 调用
            return 0;
        }

        return LuaAPI.luaL_error(L, "invalid arguments to GameObject.SetActive");
    }
    catch (Exception e)
    {
        return LuaAPI.luaL_error(L, "c# exception:" + e);
    }
}
```

如果方法有重载，生成代码会把参数数量与每个参数的 Checker 展开成一组 `if` 分支；`ref/out` 参数和返回值则会按 Lua 多返回值规则逐个压栈。

### Wrap 何时执行

`XLuaGenAutoRegister.cs` 先把下面的映射放进`ObjectTranslator.delayWrap`

```text
typeof(GameObject) → UnityEngineGameObjectWrap.__Register
```

Lua 第一次访问 `CS.UnityEngine.GameObject` 时，`xlua.import_type` 找到 `System.Type`，然后调用 `ObjectTranslator.GetTypeId`。如果该类型的 metatable 尚不存在，调用链为：

```text
GetTypeId
    ↓
getTypeId
    ↓
TryDelayWrapLoader
    ↓
UnityEngineGameObjectWrap.__Register
```

`TryDelayWrapLoader` 会先调用 `luaL_newmetatable(type.FullName)` 创建一张以类型全名命名的 metatable，再执行 `__Register` 填充它。提前创建是为了处理 Wrap 注册过程中再次使用同一类型的循环依赖。

### `BeginObjectRegister` 建立什么

它取得前面创建的 metatable，并在 Lua 栈上准备四个位置：

```text
-4  GameObject metatable
-3  methods table
-2  getters table
-1  setters table
```

随后 `RegisterFunc` 根据目标索引把生成回调写入不同位置：

```csharp
// methods["SetActive"] = _m_SetActive
Utils.RegisterFunc(L, Utils.METHOD_IDX, "SetActive", _m_SetActive);

// getters["activeSelf"] = _g_get_activeSelf
Utils.RegisterFunc(L, Utils.GETTER_IDX, "activeSelf", _g_get_activeSelf);

// metatable["__add"] = __AddMeta
Utils.RegisterFunc(L, Utils.OBJ_META_IDX, "__add", __AddMeta);
```

`__gc`、`__tostring` 和运算符等是真正直接保存在 metatable 上的元方法。普通方法、getter 和 setter 不直接存入 metatable，而是进入各自的分派表。

### `EndObjectRegister` 生成 `__index/__newindex`

`EndObjectRegister` 把 methods、getters、C# 索引器、基类类型和继承分派表作为 upvalue，调用 Native 的 `gen_obj_indexer` 创建闭包：

```text
metatable.__index = obj_indexer closure
    upvalue 1：methods
    upvalue 2：getters
    upvalue 3：C# indexer
    upvalue 4：base type
    upvalue 5：各类型的 __index 分派表
    upvalue 6：array indexer
    upvalue 7：缓存的 base __index
```

读取 `obj[key]` 时，Native `obj_indexer` 的主要查找顺序是：

```text
methods[key]
    ↓ 未找到
getters[key]
    ↓ 未找到
array indexer / C# indexer
    ↓ 未找到
基类的 __index
```

找到方法时，`__index` 直接返回生成的 Lua CFunction；找到 getter 时，则立即执行 `getter(obj)` 并返回属性值。`__newindex` 同理由 setters、C# newindexer、数组写入和基类 `__newindex` 组成。

因此注册结束后的类型结构可以概括为：

```text
GameObject metatable
├─ __gc
├─ __tostring
├─ __index ───→ obj_indexer(methods, getters, indexer, base, ...)
├─ __newindex → obj_newindexer(setters, newindexer, base, ...)
└─ __add、__eq 等直接元方法
```

### metatable 如何变成 `typeId`

Wrap 注册完成后，`getTypeId` 重新取得这张 metatable，通过 `luaL_ref` 把它保存为 Lua Registry 的整数引用：

```csharp
LuaAPI.lua_pushvalue(L, -1);
int typeId = LuaAPI.luaL_ref(L, LuaIndexes.LUA_REGISTRYINDEX);
typeIdMap.Add(typeof(GameObject), typeId);
```

此时两个 Registry key 指向同一张表：

```text
Registry["UnityEngine.GameObject"] → GameObject metatable
Registry[typeId]                   → GameObject metatable
```

XLua 还会写入 `metatable[1] = typeId`，Native 的 `xlua_gettypeid` 因而可以从 userdata 的 metatable 反查类型。这里的 `typeId` 本质上是 Lua Registry reference，不是 CLR 内部类型编号。

### userdata 如何获得这张 metatable

当构造函数或其他 C# 方法把一个 `GameObject` 返回给 Lua 时，生成 Wrap 最终调用 `ObjectTranslator.Push`。Translator 先取得该对象的 `ObjectPool index` 和 `typeId`，再进入 Native：

```c
LUA_API void xlua_pushcsobj(
    lua_State* L, int key, int meta_ref,
    int need_cache, int cache_ref)
{
    int* pointer = (int*)lua_newuserdata(L, sizeof(int));
    *pointer = key;                                      // ObjectPool index

    if (need_cache)
        cacheud(L, key, cache_ref);

    lua_rawgeti(L, LUA_REGISTRYINDEX, meta_ref);         // 取回类型 metatable
    lua_setmetatable(L, -2);                             // 绑定到 userdata
}
```

所以 `__Register` 并不是给某一个具体 userdata 设置元表，而是创建一张类型级 metatable；以后每次 Push 该类型对象时，`xlua_pushcsobj` 才通过 `typeId` 取回它。同类型 userdata 共享同一张 metatable：

```text
userdata go1 ──┐
userdata go2 ──┼──→ GameObject metatable
userdata go3 ──┘
```

### 一次实例方法调用

Lua 代码：

```lua
go:SetActive(false)
```

等价于：

```lua
go.SetActive(go, false)
```

完整调用链是：

```text
读取 go["SetActive"]
    ↓
userdata 触发 GameObject metatable.__index
    ↓
obj_indexer 从 methods["SetActive"] 取得 _m_SetActive
    ↓
Lua 调用 _m_SetActive(go, false)
    ↓
Wrap 从 go userdata 读取 ObjectPool index
    ↓
ObjectPool[index] 取得真实 GameObject
    ↓
直接执行 GameObject.SetActive(false)
```

`BeginClassRegister` 处理的是另一张表：`CS.UnityEngine.GameObject` 对应的 Lua class table。它的 metatable 保存构造函数 `__call`、静态方法和静态属性；`BeginObjectRegister` 创建的 metatable 才会绑定到具体对象的 userdata。二者关系是：

```text
GameObject class table.__call
    ↓
Wrap.__CreateInstance
    ↓
创建 C# GameObject
    ↓
ObjectTranslator.Push
    ↓
创建 userdata，并绑定 GameObject 实例 metatable
```

## class table 负责静态成员和构造函数 {#class-table}

类型注册完成后，Lua 中的 `CS.UnityEngine.GameObject` 是一个 class table，其主要结构为：

```text
class table
├── 静态方法
├── 静态只读字段
├── UnderlyingSystemType
└── metatable
    ├── __call
    ├── __index
    └── __newindex
```

调用静态方法：

```lua
CS.SomeType.StaticMethod()
```

会直接取得注册在 class table 中的静态方法 Wrap。

创建实例：

```lua
local obj = CS.SomeType()
```

会触发 class table metatable 的 `__call`，进入 Wrap 中的：

```csharp
static int __CreateInstance(RealStatePtr L)
```

访问静态属性：

```lua
local value = CS.SomeType.Value
CS.SomeType.Value = 10
```

则分别触发 class table metatable 的 `__index` 和 `__newindex`，再进入相应的 getter/setter Wrap。

## C# 实例在 Lua 中表现为 userdata {#instance-userdata}

构造函数或者其他 C# 方法返回对象后，`ObjectTranslator.Push` 会把该对象压入 Lua，并表现为 userdata。

对于普通引用类型，userdata 不直接保存完整的 C# 对象，而是保存对象映射编号。真正的 C# 对象由 `ObjectTranslator` 的对象池维护：

```text
Lua userdata
├── C# object id
└── type id
       ↓
ObjectTranslator.objects
       ↓
真实 C# 对象
```

userdata 根据 `type id` 使用对应类型的实例 metatable。因此执行：

```lua
obj:Move(10)
```

首先发生的是成员查找：

```text
userdata.__index("Move")
    ↓
实例 method table
    ↓
取得 _m_Move 回调
```

Lua 的冒号调用会自动传入 `self`，所以进入 Wrap 时的 Lua Stack 为：

```text
栈位置 1：obj userdata
栈位置 2：10
```

## 生成 Wrap 的方法调用过程 {#generated-method-call}

Lua VM 不认识 C# 方法，只认识符合下面签名的回调：

```c
typedef int (*lua_CFunction)(lua_State* L);
```

因此，生成 Wrap 中的方法本质上是符合 `lua_CFunction` 调用约定的 C# 静态函数。其结构可以简化为：

```csharp
static int _m_Move(RealStatePtr L)
{
    try
    {
        ObjectTranslator translator =
            ObjectTranslatorPool.Instance.Find(L);

        SomeType self =
            (SomeType)translator.FastGetCSObj(L, 1);

        int distance;
        translator.Get(L, 2, out distance);

        int result = self.Move(distance);

        translator.Push(L, result);
        return 1;
    }
    catch (Exception e)
    {
        return LuaAPI.luaL_error(L, "c# exception:" + e);
    }
}
```

完整调用链为：

```text
Lua：obj:Move(10)
    ↓
userdata.__index
    ↓
找到 _m_Move
    ↓
Lua VM 调用 lua_CFunction
    ↓
Native → Managed 反向调用
    ↓
FastGetCSObj 取得 self
    ↓
检查参数数量和类型
    ↓
ObjectTranslator.Get 读取参数
    ↓
直接执行 self.Move(10)
    ↓
ObjectTranslator.Push 压入返回值
    ↓
return 返回值数量
    ↓
Lua VM 将栈顶值作为 Lua 返回值
```

`lua_CFunction` 返回的整数不是业务返回值，而是告诉 Lua VM 当前回调向栈顶压入了多少个返回值：

```csharp
return 0; // Lua 无返回值
return 1; // Lua 有一个返回值
return 3; // return、ref、out 共三个返回值
```

## 重载、ref 和 out {#overloads-ref-out}

如果 C# 方法存在多个重载，生成 Wrap 会根据下列条件进行匹配：

- Lua Stack 中的参数数量；
- 每个参数位置的 Lua 类型；
- Lua 值是否能够转换成目标 C# 类型；
- 可选参数及其默认值；
- `params` 可变参数。

匹配成功后，Wrap 直接调用对应的 C# 重载。

例如 C# 方法为：

```csharp
bool TryGet(int id, out Item item);
```

Lua 可以通过多返回值接收方法返回值和 `out` 参数：

```lua
local success, item = obj:TryGet(10)
```

Wrap 会依次把普通返回值、`ref` 参数和 `out` 参数压入 Lua Stack，并返回对应的结果数量。

## 枚举 Wrap：EnumWrap.cs {#enum-wrap}

XLua 不会为当前 AppDomain 中的所有枚举生成代码。生成器只筛选最终进入 `LuaCallCSharp` 的枚举：

```csharp
var enumTypes = LuaCallCSharp.Where(type => type.IsEnum).Distinct();
```

假设项目配置了：

```csharp
namespace Game
{
    [LuaCallCSharp]
    public enum PlayerState
    {
        Idle = 0,
        Move = 1,
        Attack = 2
    }
}
```

生成器会为 `Game.PlayerState` 创建一个 `GamePlayerStateWrap`。与普通类型不同，枚举 Wrap 不按类型拆成多个物理文件，而是全部集中写入 `EnumWrap.cs`：

```text
EnumWrap.cs
├─ GamePlayerStateWrap
├─ UnityEngineSpaceWrap
└─ 其他已配置枚举的 Wrap
```

`XLuaGenAutoRegister.cs` 仍然为每个枚举类型分别登记延迟 loader：

```csharp
translator.DelayWrapLoader(
    typeof(Game.PlayerState),
    GamePlayerStateWrap.__Register);
```

因此，一个枚举对应一个 Wrap 类和一条延迟加载记录，但多个枚举 Wrap 类共存在同一个 `EnumWrap.cs` 中。

### Enum Wrap 注册了什么

`GamePlayerStateWrap.__Register` 可以简化为：

```csharp
public class GamePlayerStateWrap
{
    public static void __Register(RealStatePtr L)
    {
        ObjectTranslator translator = ObjectTranslatorPool.Instance.Find(L);
        Type type = typeof(Game.PlayerState);

        // 创建 PlayerState 枚举值使用的实例 metatable。
        Utils.BeginObjectRegister(type, L, translator, 0, 0, 0, 0);
        Utils.EndObjectRegister(type, L, translator, null, null, null, null, null);

        // 创建 CS.Game.PlayerState 对应的 class table。
        // creator 为 null，因此枚举类型本身不可像构造函数一样调用。
        Utils.BeginClassRegister(type, L, null, 4, 0, 0);
        Utils.RegisterObject(L, translator, Utils.CLS_IDX,
            "Idle", Game.PlayerState.Idle);
        Utils.RegisterObject(L, translator, Utils.CLS_IDX,
            "Move", Game.PlayerState.Move);
        Utils.RegisterObject(L, translator, Utils.CLS_IDX,
            "Attack", Game.PlayerState.Attack);
        Utils.RegisterFunc(L, Utils.CLS_IDX, "__CastFrom", __CastFrom);
        Utils.EndClassRegister(type, L, translator);
    }
}
```

注册结束后，可以把 Lua 侧结构近似理解为：

```text
CS.Game.PlayerState                  PlayerState metatable
├─ Idle   → PlayerState userdata     ├─ __gc
├─ Move   → PlayerState userdata     ├─ __tostring
├─ Attack → PlayerState userdata     ├─ __band
└─ __CastFrom → 转换函数              └─ __bor
```

左侧是枚举类型的 class table，用于访问枚举成员；右侧是绑定到具体枚举值 userdata 的实例 metatable。`getTypeId` 会额外为枚举 metatable 加入 `__band` 和 `__bor`，支持 Lua 5.3 的枚举按位与、按位或操作。

### Lua 如何找到枚举类型

第一次执行：

```lua
local PlayerState = CS.Game.PlayerState
```

会经过 `CS` table 的类型导入逻辑：

```text
读取 CS.Game
    ↓
尚不能确定是类型，将其作为命名空间代理 table
    ↓
读取 CS.Game.PlayerState
    ↓
xlua.import_type("Game.PlayerState")
    ↓
ObjectTranslator.FindType
    ↓
GetTypeId → TryDelayWrapLoader
    ↓
GamePlayerStateWrap.__Register
    ↓
BeginClassRegister / SetCSTable
    ↓
CS.Game.PlayerState 指向真正的枚举 class table
```

`init_xlua` 中的 `CS.__index` 在 `import_type` 返回 `true` 后，会重新从当前命名空间 table 中读取 `PlayerState`。此时 `SetCSTable` 已经把 Wrap 创建的 class table 放到了对应位置。

### Lua 如何读取和使用枚举成员

注册完成后，Lua 直接按成员名访问：

```lua
local idle = CS.Game.PlayerState.Idle
local attack = CS.Game.PlayerState.Attack

player:SetState(CS.Game.PlayerState.Attack)
```

最后一行的调用链为：

```text
CS.Game.PlayerState.Attack
    ↓
从 PlayerState class table 取得 Attack userdata
    ↓
Player Wrap 按 PlayerState 类型读取参数
    ↓
从 userdata 解包底层整数 2
    ↓
转换为 Game.PlayerState.Attack
    ↓
调用 C# player.SetState(PlayerState.Attack)
```

因此，Lua 侧通常应传递：

```lua
player:SetState(CS.Game.PlayerState.Attack)
```

而不是依赖一个没有类型信息的 Lua number：

```lua
player:SetState(2)
```

### 枚举值在 Lua 中的表示

除了 `EnumWrap.cs`，生成器还会在 `WrapPusher.cs` 中为每个 `LuaCallCSharp` 枚举生成强类型 push/get/update：

```csharp
translator.RegisterPushAndGetAndUpdate<Game.PlayerState>(
    translator.PushGamePlayerState,
    translator.Get,
    translator.UpdateGamePlayerState);
```

压入枚举值时，生成代码创建一个 4 字节的 struct userdata，将枚举底层整数写入其中：

```csharp
IntPtr buffer = LuaAPI.xlua_pushstruct(
    L,
    4,
    GamePlayerState_TypeID);

CopyByValue.Pack(buffer, 0, (int)value);
```

因此 `CS.Game.PlayerState.Attack` 通常不是 Lua number，而是：

```text
PlayerState userdata
├─ 数据部分：int 2
└─ metatable：PlayerState metatable
```

读取回 C# 时，专用 `Get` 会先校验 userdata 的 typeId，再解包整数并强制转换为目标枚举：

```csharp
if (LuaAPI.xlua_gettypeid(L, index) != GamePlayerState_TypeID)
    throw new Exception("invalid PlayerState userdata");

int rawValue;
CopyByValue.UnPack(buffer, 0, out rawValue);
value = (Game.PlayerState)rawValue;
```

所以两个底层数值相同的不同枚举，在 Lua 中仍然具有不同 metatable 和 typeId，不会因为都等于整数 `2` 就失去类型区别。

### 同一个枚举值的 userdata 缓存

专用 Push 会先按照底层整数在该枚举的 class table 中查找缓存：

```csharp
if (LuaAPI.xlua_tryget_cachedud(
    L,
    (int)value,
    GamePlayerState_EnumRef) == 1)
{
    return;
}
```

第一次创建后，再把 userdata 写入枚举 class table 的整数索引：

```text
CS.Game.PlayerState
├─ "Idle"   → Idle userdata
├─ "Move"   → Move userdata
├─ "Attack" → Attack userdata
├─ 0         → Idle userdata
├─ 1         → Move userdata
└─ 2         → Attack userdata
```

后续再次把 `PlayerState.Attack` 压入 Lua 时，可以直接复用缓存的 userdata。多个名称映射到同一个底层值时，也会复用同一份值对象。

### `__CastFrom`：从 number/string 创建强类型枚举

Wrap 会额外生成 `__CastFrom`：

```csharp
static int __CastFrom(RealStatePtr L)
{
    ObjectTranslator translator = ObjectTranslatorPool.Instance.Find(L);
    LuaTypes luaType = LuaAPI.lua_type(L, 1);

    if (luaType == LuaTypes.LUA_TNUMBER)
    {
        translator.PushGamePlayerState(
            L,
            (Game.PlayerState)LuaAPI.xlua_tointeger(L, 1));
        return 1;
    }

    if (luaType == LuaTypes.LUA_TSTRING)
    {
        if (LuaAPI.xlua_is_eq_str(L, 1, "Idle"))
            translator.PushGamePlayerState(L, Game.PlayerState.Idle);
        else if (LuaAPI.xlua_is_eq_str(L, 1, "Move"))
            translator.PushGamePlayerState(L, Game.PlayerState.Move);
        else if (LuaAPI.xlua_is_eq_str(L, 1, "Attack"))
            translator.PushGamePlayerState(L, Game.PlayerState.Attack);
        else
            return LuaAPI.luaL_error(L, "invalid PlayerState name");

        return 1;
    }

    return LuaAPI.luaL_error(L, "expect number or string");
}
```

Lua 可以写成：

```lua
local state1 = CS.Game.PlayerState.__CastFrom(2)
local state2 = CS.Game.PlayerState.__CastFrom("Attack")
```

由于 `BeginClassRegister` 的 creator 为 `null`，枚举 class table 没有构造用的 `__call`，不能把下面的形式当作枚举转换：

```lua
-- 不应这样转换
local state = CS.Game.PlayerState(2)
```

### 成员数量超过 20 时

小枚举会把每一个成员直接展开为 `RegisterObject`，从而避免注册时反射：

```csharp
Utils.RegisterObject(
    L, translator, Utils.CLS_IDX,
    "Attack", Game.PlayerState.Attack);
```

成员超过 20 个时，模板不再逐项生成，而是调用：

```csharp
Utils.RegisterEnumType(L, typeof(Game.PlayerState));
```

其内部在首次注册时执行一次：

```csharp
foreach (string name in Enum.GetNames(type))
{
    RegisterObject(
        L,
        translator,
        Utils.CLS_IDX,
        name,
        Enum.Parse(type, name));
}
```

两条路径在 Lua 侧没有区别，仍然通过 `CS.Game.PlayerState.Attack` 访问。小枚举选择更彻底的静态展开；大枚举则用一次注册期反射换取较小的生成代码体积。

## Lua 调用 C# Delegate：公共 metatable 与调用包装 {#delegate-wrap}

当前版本的标准 `Generate Code` 不会为每一种 Delegate 生成独立的 `<DelegateName>Wrap.cs`。生成器整理 `LuaCallCSharp` 配置时会过滤所有 Delegate 类型：

```csharp
LuaCallCSharp = LuaCallCSharp
    .Distinct()
    .Where(type => IsPublic(type) && !isObsolete(type))
    .Where(type => !typeof(Delegate).IsAssignableFrom(type))
    .ToList();
```

因此当前的实际结构不是：

```text
DamageHandler userdata → DamageHandlerWrap
Action userdata        → ActionWrap
Func<int,int> userdata → FuncIntIntWrap
```

而是所有进入 Lua 的 C# Delegate userdata 共用一张 `common_delegate_meta`。

### 公共 Delegate metatable

`LuaEnv` 初始化末尾调用 `CreateDelegateMetatable`，向公共 metatable 注册三个元方法：

```csharp
public void CreateDelegateMetatable(RealStatePtr L)
{
    Utils.BeginObjectRegister(
        null, L, this, 3, 0, 0, 0, common_delegate_meta);

    Utils.RegisterFunc(
        L, Utils.OBJ_META_IDX,
        "__call", StaticLuaCallbacks.DelegateCall);

    Utils.RegisterFunc(
        L, Utils.OBJ_META_IDX,
        "__add", StaticLuaCallbacks.DelegateCombine);

    Utils.RegisterFunc(
        L, Utils.OBJ_META_IDX,
        "__sub", StaticLuaCallbacks.DelegateRemove);

    Utils.EndObjectRegister(
        null, L, this, null, null,
        typeof(MulticastDelegate), null, null);
}
```

不同 Delegate 类型共用它：

```text
Action userdata ────────────┐
DamageHandler userdata ─────┼──→ common_delegate_meta
Func<int, int> userdata ────┘
```

`ObjectTranslator.getTypeId` 遇到 `MulticastDelegate` 的派生类型时，直接返回 `common_delegate_meta`，所以 `xlua_pushcsobj` 创建 Delegate userdata 后绑定的都是这张公共 metatable。

### Lua 调用 C# Delegate

假设 C# 对象向 Lua 暴露：

```csharp
public Func<int, int> Callback;
```

Lua 可以直接调用：

```lua
local result = obj.Callback(10)
```

调用链为：

```text
Callback Delegate userdata
    ↓
common_delegate_meta.__call
    ↓
StaticLuaCallbacks.DelegateCall
    ↓
从 userdata 取得真实 C# Delegate
    ↓
根据 Delegate 的运行时类型取得 Invoke 包装
    ↓
调用 C# Delegate
    ↓
返回值压回 Lua
```

公共的 `DelegateCall` 本身不知道 Delegate 的具体参数签名，只负责取得真实对象，再转交给 `MethodWrapsCache`：

```csharp
public static int DelegateCall(RealStatePtr L)
{
    ObjectTranslator translator =
        ObjectTranslatorPool.Instance.Find(L);

    object objDelegate = translator.FastGetCSObj(L, 1);
    if (!(objDelegate is Delegate))
        return LuaAPI.luaL_error(L, "value is not delegate");

    return translator.methodWrapsCache
        .GetDelegateWrap(objDelegate.GetType())(L);
}
```

### Delegate 调用包装的缓存

第一次调用某种 Delegate 类型时，`GetDelegateWrap` 通过反射取得该类型的 `Invoke` 方法，并生成通用 `MethodWrap`：

```csharp
public LuaCSFunction GetDelegateWrap(Type type)
{
    if (!delegateCache.ContainsKey(type))
    {
        delegateCache[type] = _GenMethodWrap(
            type,
            type.ToString(),
            new MethodBase[] { type.GetMethod("Invoke") }).Call;
    }

    return delegateCache[type];
}
```

缓存关系为：

```text
Delegate Type
    → Invoke 的参数、返回值、ref/out、Caster 和 Checker
    → LuaCSFunction / MethodWrap
```

后续相同类型的 Delegate 会直接复用缓存，不再重复扫描 `Invoke` 的签名。但实际执行仍然经过：

```csharp
method.Invoke(target, args);
```

所以缓存消除的是重复的反射查找和签名分析，没有消除每次调用的 `MethodInfo.Invoke`、通用参数数组及可能的装箱成本。

### Delegate 的合并与移除

公共 metatable 的 `__add` 和 `__sub` 分别对应：

```csharp
Delegate.Combine(left, right);
Delegate.Remove(left, right);
```

Lua 可以写成：

```lua
local combined = callback1 + callback2
local remaining = combined - callback2
```

因此，本文所分析的 Delegate 调用路径共用 `common_delegate_meta`，并按具体 Delegate 类型缓存其 `Invoke` 的调用包装；这条路径仍通过反射执行实际调用。

## 未生成 Wrap 时的反射回退 {#reflection-fallback}

当 `GetTypeId` 发现某个类型尚未建立 metatable 时，会调用：

```csharp
TryDelayWrapLoader(L, type);
```

其处理顺序是：

```text
存在 delayWrap
    ↓
执行生成代码中的 Wrap.__Register

不存在 delayWrap
    ↓
Editor/Mono 的部分配置中动态 Emit TypeWrap

否则
    ↓
Utils.ReflectionWrap
```

`ReflectionWrap` 最终建立的 Lua 侧结构与生成 Wrap 基本一致：

```text
class table
实例 metatable
方法表
getter 表
setter 表
```

所以从 Lua 侧看，下列调用方式没有区别：

```lua
obj:Method()
obj.Property
CS.SomeType.StaticMethod()
```

真正的区别发生在回调内部。生成 Wrap 的调用链是：

```text
读取参数
    ↓
直接调用 obj.Method(...)
```

反射 Wrap 的调用链是：

```text
MethodWrap
    ↓
选择 OverloadMethodWrap
    ↓
ObjectCheck 检查参数
    ↓
ObjectCast 转换参数
    ↓
MethodInfo.Invoke
    ↓
压入返回值
```

`MethodWrapsCache` 会按类型和方法名缓存已经生成的反射回调。每个 `OverloadMethodWrap` 还会预先保存：

- `MethodBase`；
- 参数检查器；
- 参数转换器；
- `ref/out` 参数位置；
- 可选参数默认值；
- `params` 参数信息。

因此，反射路径不会在每次调用时重新扫描类型并分析全部 `MethodInfo`。但是每次实际执行仍然需要进行重载检查、构造 `object[]` 参数、参数装箱以及调用 `MethodInfo.Invoke`。

反射缓存减少的是重复查找和分析反射信息的成本，并没有把反射调用转换成生成代码的直接调用。这也是 XLua 推荐为高频调用类型生成 Wrap 的主要原因。
