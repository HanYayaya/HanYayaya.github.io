---
title: "5. 值类型传递与运行时优化"
slug: xlua-value-types-and-performance
date: 2026-09-15
lastmod: 2026-11-19
description: "分析 GCOptimize、WrapPusher、PackUnpack 的值类型表示、Push/Get/Update，以及缓存和 Native 扩展优化。"
categories:
  - "Lua/XLua/XLua 2.1.16 源码阅读"
tags:
  - Lua
  - XLua
  - Unity
series:
  - XLua 2.1.16 源码阅读
series_order: 5
draft: false
toc: true
---

## 值类型与 GCOptimize {#gc-optimize}

普通 struct 经过 `object`、`ObjectPool<object>` 或反射 `object[]` 时容易发生装箱。对于配置为 GC 优化的值类型，XLua 会生成专用的 WrapPusher 与 PackUnpack，并把 struct 数据直接存入 native userdata。

这条路径主要包含三类操作：

```text
push：   C# struct → userdata 内存
get：    userdata 内存 → C# struct
update：修改后的 C# struct → 原 userdata
```

运行时不需要先把 struct 装箱成 `object` 再存入普通 `ObjectPool`，从而减少：

- 值类型装箱；
- 托管堆临时对象；
- userdata 与通用 `object` 之间的中间转换。

下文将分别展开 [值类型转换器：WrapPusher.cs](#wrap-pusher) 与 [值类型布局与序列化：PackUnpack.cs](#pack-unpack) 的生成内容。分析这些代码时需要注意：GCOptimize 只优化命中专用转换器的调用路径。如果 struct 仍然经过 `object`、反射接口或其他通用 API，装箱并不会自动消失。

## 值类型转换器：WrapPusher.cs {#wrap-pusher}

`WrapPusher.cs` 不是普通类型 Wrap，也不负责注册类型的方法、属性和构造函数。它解决的是 C# struct 和 enum 在 Lua 与 C# 之间传递时，应该如何表示、压栈、取回和原地更新，从而避免装箱以及由此产生的 C# 托管堆分配。

两者的职责可以先区分为：

```text
普通类型 Wrap：
负责让 Lua 调用 C# 类型的成员

WrapPusher.cs：
负责 C# 值类型与 Lua 栈之间的数据转换
```

### 普通值类型路径为什么会产生 GC

假设定义了一个值类型：

```csharp
public struct Position
{
    public float x;
    public float y;
    public float z;
}
```

如果没有生成专用转换代码，普通 Wrap 在压入 `Position` 时只能走通用入口：

```csharp
translator.Push(L, position);
```

但 `ObjectTranslator` 的通用入口接收的是 `object`：

```csharp
public void Push(RealStatePtr L, object o)
```

把 `Position` 传给 `object` 会先发生装箱。随后 `ObjectTranslator.Push` 将装箱对象放入对象池，并让 Lua userdata 保存对象池索引：

```csharp
index = addObject(o, isValueType, isEnum);
LuaAPI.xlua_pushcsobj(
    L,
    index,
    typeId,
    needCache,
    cacheRef);
```

完整路径为：

```text
Position struct
    ↓ boxing
C# 托管堆上的 object
    ↓
ObjectTranslator.objects
    ↓
Lua userdata 保存对象池索引
```

频繁传递 `Vector3`、`Quaternion` 等值类型时，这条路径会产生大量装箱对象和 C# GC Alloc。

`WrapPusher.cs` 则为具体类型生成强类型入口：

```csharp
public void PushPosition(RealStatePtr L, Position value)
```

参数直接按 `Position` 传递，不需要先转换成 `object`，从入口处避免装箱。

### 哪些类型会生成到 WrapPusher

生成器调用：

```csharp
GenWrapPusher(gcOptimizeList
                .Concat(wraps.Where(type => type.IsEnum))
                .Distinct(),
            savePath);
```

因此 `WrapPusher.cs` 主要处理两类类型。

第一类是配置到 `GCOptimize` 的类型：

```csharp
[GCOptimize]
public struct Position
{
    public float x;
    public float y;
    public float z;
}
```

也可以通过静态配置提供：

```csharp
[GCOptimize]
public static List<Type> GCOptimizeTypes = new List<Type>
{
    typeof(Position)
};
```

第二类是配置到 `LuaCallCSharp` 的枚举。枚举不需要额外配置 `GCOptimize`：

```csharp
[LuaCallCSharp]
public enum PlayerState
{
    Idle,
    Run,
    Attack
}
```

`WrapPusher.cs` 是集中式生成文件，而不是为每个值类型生成一个独立文件：

```text
WrapPusher.cs
├── PushUnityEngineVector3
├── Get(... out Vector3)
├── UpdateUnityEngineVector3
├── PushUnityEngineQuaternion
├── Get(... out Quaternion)
├── UpdateUnityEngineQuaternion
├── PushGamePlayerState
├── Get(... out PlayerState)
└── UpdateGamePlayerState
```

### 哪些 struct 可以按二进制打包

生成器通过 `SizeOf(Type)` 判断一个 struct 是否能够直接打包。它原生支持以下字段类型：

```csharp
byte
sbyte
short
ushort
int
uint
long
ulong
float
double
decimal
```

struct 可以继续嵌套其他符合条件的 struct：

```csharp
public struct Position
{
    public float x;
    public float y;
    public float z;
}

public struct TransformData
{
    public Position position;
    public Position scale;
}
```

生成器递归计算每个字段在 XLua 数据布局中的尺寸。例如：

```text
Position
= float + float + float
= 4 + 4 + 4
= 12 字节
```

如果字段中出现不能按值打包的引用类型：

```csharp
public struct PlayerData
{
    public int id;
    public string name;
}
```

那么 `SizeOf(PlayerData)` 返回 `-1`，该类型不能使用默认的二进制 userdata 打包路径。

这里计算的是 XLua 自己定义的字段序列化布局，不是简单地对 CLR struct 调用 `Marshal.SizeOf`，也不是直接复制 CLR struct 的原始内存。

### 初始化时注册 Push、Get 与 Update

`WrapPusher.cs` 是 `ObjectTranslator` 的一个 `partial` 实现。生成文件中的辅助初始化类会调用 `LuaEnv.AddIniter`：

```csharp
public partial class ObjectTranslator
{
    class IniterAdderPosition
    {
        static IniterAdderPosition()
        {
            LuaEnv.AddIniter(Init);
        }

        static void Init(LuaEnv luaenv, ObjectTranslator translator)
        {
            translator.RegisterPushAndGetAndUpdate<Position>(
                translator.PushPosition,
                translator.Get,
                translator.UpdatePosition);
        }
    }
}
```

它向 `ObjectTranslator` 注册三种操作：

```text
Position
├── Push   → PushPosition
├── Get    → Get(... out Position)
└── Update → UpdatePosition
```

`RegisterPushAndGetAndUpdate<T>` 会同时将这些函数加入：

```csharp
push_func_with_type
get_func_with_type

custom_push_funcs
custom_get_funcs
custom_update_funcs
```

这样，无论调用点掌握的是编译期泛型类型，还是运行时 `System.Type`，`ObjectTranslator` 都能找到对应的专用转换代码。

### Push：把 C# struct 写入 Lua userdata

以 `Position` 为例，生成的 Push 近似如下：

```csharp
int Position_TypeID = -1;

public void PushPosition(RealStatePtr L, Position value)
{
    if (Position_TypeID == -1)
    {
        bool isFirst;
        Position_TypeID = getTypeId(L, typeof(Position), out isFirst);
    }

    IntPtr buffer = LuaAPI.xlua_pushstruct(L, 12, Position_TypeID);

    if (!CopyByValue.Pack(buffer, 0, value))
    {
        throw new Exception("pack fail for Position, value=" + value);
    }
}
```

Push 主要分为三步。

第一步，通过 `getTypeId` 取得该类型注册在 Lua Registry 中的实例元表编号：

```csharp
Position_TypeID = getTypeId(L, typeof(Position), out isFirst);
```

值类型 userdata 会绑定同一个实例元表，因此它仍然可以使用普通 Wrap 注册的方法、属性和元方法。

第二步，通过 `xlua_pushstruct` 创建一个能够内联保存 struct 数据的 userdata：

```csharp
IntPtr buffer = LuaAPI.xlua_pushstruct(L, 12, Position_TypeID);
```

C 层的数据结构为：

```c
typedef struct {
    int fake_id;
    unsigned int len;
    char data[1];
} CSharpStruct;
```

`xlua_pushstruct` 的核心逻辑是：

```c
CSharpStruct *css = lua_newuserdata( L, size + sizeof(int) + sizeof(unsigned int));

css->fake_id = -1;
css->len = size;

lua_rawgeti(L, LUA_REGISTRYINDEX, meta_ref);
lua_setmetatable(L, -2);

return css;
```

创建出的 userdata 可以理解为：

```text
Position userdata
├── fake_id = -1
├── len = 12
└── data
    ├── x：4 字节
    ├── y：4 字节
    └── z：4 字节
```

`fake_id = -1` 表示该 userdata 保存的不是 `ObjectTranslator.objects` 中的对象索引，而是一段内联值类型数据。

第三步，通过 `CopyByValue.Pack` 把字段写入 userdata：

```csharp
CopyByValue.Pack(buffer, 0, value);
```

对于 `Position`，最终生成的字段写入代码近似为：

```csharp
LuaAPI.xlua_pack_float3(
    buffer,
    0,
    value.x,
    value.y,
    value.z);
```

这里的职责边界是：

```text
WrapPusher.cs
负责创建 userdata、绑定元表、检查类型以及组织 Push/Get/Update

PackUnpack.cs
负责具体 struct 的字段布局，以及字段的二进制写入和读出
```

### 为什么优化路径不产生 C# GC Alloc

普通路径为：

```text
Position
    ↓ 装箱
object
    ↓
ObjectTranslator 对象池
    ↓
Lua userdata 保存对象索引
```

优化路径变成：

```text
Position
    ↓ 强类型 PushPosition
xlua_pushstruct
    ↓
字段直接复制到 Lua userdata
```

因此不再需要：

- 把 struct 装箱成 `object`；
- 在 C# 托管堆创建装箱对象；
- 将装箱对象加入 `ObjectTranslator.objects`；
- 维护该装箱对象的正向和反向映射。

不过 `GCOptimize` 主要指不产生 C# 托管堆 GC Alloc，并不代表完全没有内存分配。`lua_newuserdata` 仍然会在 Lua 管理的内存中创建 userdata，最终由 Lua GC 回收。

### Get：把 Lua userdata 还原为 C# struct

生成的 Get 近似如下：

```csharp
public void Get(RealStatePtr L, int index, out Position value)
{
    LuaTypes type = LuaAPI.lua_type(L, index);

    if (type == LuaTypes.LUA_TUSERDATA)
    {
        if (LuaAPI.xlua_gettypeid(L, index) != Position_TypeID)
        {
            throw new Exception("invalid userdata for Position");
        }

        IntPtr buffer = LuaAPI.lua_touserdata(L, index);

        if (!CopyByValue.UnPack(buffer, 0, out value))
        {
            throw new Exception("unpack fail for Position");
        }
    }
    else if (type == LuaTypes.LUA_TTABLE)
    {
        CopyByValue.UnPack(this, L, index, out value);
    }
    else
    {
        value = (Position)objectCasters.GetCaster(typeof(Position))(L, index, null);
    }
}
```

userdata 路径的完整过程为：

```text
检查 Lua 值是 userdata
    ↓
读取 userdata 元表中的 typeId
    ↓
确认它确实是 Position
    ↓
取得 userdata 内存地址
    ↓
CopyByValue.UnPack
    ↓
构造 C# Position 值
```

解包代码最终可能近似为：

```csharp
float x;
float y;
float z;

LuaAPI.xlua_unpack_float3(
    buffer,
    0,
    out x,
    out y,
    out z);

value = new Position
{
    x = x,
    y = y,
    z = z
};
```

Get 返回的是从 userdata 内容复制出来的 C# struct，而不是指向 userdata 内存的 C# 引用。

### Update：把修改后的 struct 写回原 userdata

Get 得到的是 struct 副本：

```csharp
Position value;
translator.Get(L, 1, out value);
```

如果 Lua 调用了一个可能修改 struct 自身的 C# 实例方法：

```lua
position:Set(1, 2, 3)
```

普通类型 Wrap 内部首先操作的是局部副本：

```csharp
Position value;
translator.Get(L, 1, out value);

value.Set(1, 2, 3);
```

如果不进行写回，Lua 中原来的 userdata 不会发生变化。因此生成的 Wrap 会在调用结束后追加：

```csharp
translator.UpdatePosition(L, 1, value);
```

对应的 Update 近似如下：

```csharp
public void UpdatePosition(RealStatePtr L, int index, Position value)
{
    if (LuaAPI.lua_type(L, index) == LuaTypes.LUA_TUSERDATA)
    {
        if (LuaAPI.xlua_gettypeid(L, index) != Position_TypeID)
        {
            throw new Exception("invalid userdata for Position");
        }

        IntPtr buffer = LuaAPI.lua_touserdata(L, index);

        if (!CopyByValue.Pack(buffer, 0, value))
        {
            throw new Exception("pack fail for Position");
        }
    }
    else
    {
        throw new Exception("try to update a data with lua type:" + LuaAPI.lua_type(L, index));
    }
}
```

Update 不会创建新的 userdata，而是覆盖原 userdata 的数据区域：

```text
原 userdata
    ↓ Get
C# struct 局部副本
    ↓ 调用实例方法、setter 或 ref 方法
修改后的 struct
    ↓ Update
覆盖原 userdata 的 data 区域
```

Update 主要用于：

- 值类型实例方法可能修改 `this`；
- 值类型属性或字段 setter；
- `ref` 参数调用完成后的原参数写回；
- 某些数组或容器元素更新。

因此三个操作的职责分别是：

```text
Push：
C# struct → 新的 Lua userdata

Get：
Lua userdata → C# struct 副本

Update：
修改后的 C# struct → 写回原 Lua userdata
```

### 优化不会改变 struct 的值语义

假设 C# 执行：

```csharp
Position position = new Position
{
    x = 1,
    y = 2,
    z = 3
};

luaEnv.Global.Set("position", position);
```

`Set` 会把字段复制进 Lua userdata：

```text
C# position                 Lua userdata
{x=1,y=2,z=3}  ──复制──→   {x=1,y=2,z=3}
```

之后 Lua 修改 userdata：

```lua
position.x = 10
```

不会自动修改原来的 C# 局部变量：

```text
C# position  = {x=1, y=2, z=3}
Lua userdata = {x=10,y=2,z=3}
```

只有再次从 Lua 取回值：

```csharp
Position result = luaEnv.Global.Get<Position>("position");
```

或者经过明确的 `ref/out` 写回路径，Lua 中的数据才会重新复制给 C#。

所以 WrapPusher 优化的是值类型的传递方式，并不会把 struct 改造成引用类型。

### 值类型数组的专用转换路径

`WrapPusher.cs` 还会生成值类型数组的快速读写代码：

```csharp
internal static bool __tryArrayGet(
    Type type,
    RealStatePtr L,
    ObjectTranslator translator,
    object obj,
    int index)
{
    if (type == typeof(Position[]))
    {
        Position[] array = obj as Position[];
        translator.PushPosition(L, array[index]);
        return true;
    }

    return false;
}
```

数组写入路径为：

```csharp
internal static bool __tryArraySet(
    Type type,
    RealStatePtr L,
    ObjectTranslator translator,
    object obj,
    int arrayIndex,
    int luaIndex)
{
    if (type == typeof(Position[]))
    {
        Position[] array = obj as Position[];
        translator.Get(L, luaIndex, out array[arrayIndex]);
        return true;
    }

    return false;
}
```

这样访问：

```lua
local position = positions[1]
positions[1] = position
```

可以直接操作强类型 `Position[]`，避免 `Array.GetValue`、`Array.SetValue` 等通用数组路径带来的装箱和拆箱。

### 无法连续打包的类型转换

`GenWrapPusher` 会把输入类型进一步分成两组：

```text
purevaluetypes：
枚举，或者 SizeOf(type) != -1 的纯值类型

tableoptimzetypes：
非枚举，并且 SizeOf(type) == -1 的复杂类型
```

后者不能使用连续二进制 userdata，但 `WrapPusher.cs` 仍会生成 table 到目标类型的逐字段转换函数，并通过 `RegisterCaster<T>` 注册：

```csharp
translator.RegisterCaster<PlayerData>(translator.Get);
```

生成的 Get 核心结构近似如下：

```csharp
public void Get(RealStatePtr L, int index, out PlayerData value)
{
    LuaTypes type = LuaAPI.lua_type(L, index);

    if (type == LuaTypes.LUA_TUSERDATA)
    {
        value = (PlayerData)FastGetCSObj(L, index);
    }
    else if (type == LuaTypes.LUA_TTABLE)
    {
        value = new PlayerData();
        int top = LuaAPI.lua_gettop(L);

        if (Utils.LoadField(L, index, "id"))
        {
            Get(L, top + 1, out value.id);
        }
        LuaAPI.lua_pop(L, 1);

        if (Utils.LoadField(L, index, "name"))
        {
            Get(L, top + 1, out value.name);
        }
        LuaAPI.lua_pop(L, 1);
    }
    else
    {
        throw new Exception(
            "can not cast "
            + LuaAPI.lua_type(L, index)
            + " to PlayerData");
    }
}
```

这条路径优化的是 Lua table 到 C# 对象或复杂 struct 的逐字段转换，减少运行时反射查找；它并不具备纯值类型二进制 userdata 路径的内联存储能力。

### `PackAsTable` 表示方式

除了默认的二进制 userdata，XLua 还支持：

```csharp
[GCOptimize(OptimizeFlag.PackAsTable)]
public struct Position
{
    public float x;
    public float y;
}
```

此时 Push 不再调用 `xlua_pushstruct`，而是创建带有目标类型元表的 Lua table，并逐字段写入：

```csharp
LuaAPI.xlua_pushcstable(
    L,
    2,
    Position_TypeID);

LuaAPI.xlua_pushasciistring(L, "x");
LuaAPI.lua_pushnumber(L, value.x);
LuaAPI.lua_rawset(L, -3);

LuaAPI.xlua_pushasciistring(L, "y");
LuaAPI.lua_pushnumber(L, value.y);
LuaAPI.lua_rawset(L, -3);
```

Lua 侧得到的是：

```lua
{
    x = 1,
    y = 2
}
```

两种表示方式的差异如下：

| 默认模式 | `PackAsTable` |
|---|---|
| Lua userdata | Lua table |
| 字段保存在连续数据区 | 字段保存为键值对 |
| 内存更紧凑 | Lua 访问字段更直接 |
| 通过 `Pack/UnPack` 转换 | 逐字段读写 |
| Update 可以覆盖原二进制数据 | Lua 直接修改 table 字段 |
| 可以使用 `xlua.genaccessor` 访问内存 | 可以直接使用 Lua table 操作 |

官方 `ReImplementInLua` 示例使用 `PackAsTable`，就是为了允许 Lua 直接给 struct table 增加 Lua 方法并操作字段。常见的 `Vector3`、`Quaternion` 等 Unity 值类型则主要使用默认的二进制 userdata 路径。

### 优化结果

整个优化过程可以概括为：

```text
未优化的 struct
    ↓
装箱为 object
    ↓
进入 ObjectTranslator 对象池
    ↓
Lua userdata 保存对象池索引
    ↓
产生 C# GC Alloc


GCOptimize struct
    ↓
调用强类型 Push
    ↓
字段直接写入 Lua userdata
    ↓
不进入 C# 对象池
    ↓
避免装箱和 C# GC Alloc
```

所以 `WrapPusher.cs` 的主要优化不只是减少反射，而是改变值类型在 Lua 中的底层表示：从“userdata 引用 C# 对象池中的装箱对象”，变成“userdata 自己内联保存 struct 的字段数据”。

这也是 XLua 针对 Unity 高频值类型传递所做的关键 GC 优化。

## 值类型布局与序列化：PackUnpack.cs {#pack-unpack}

`PackUnpack.cs` 是 XLua 为 `GCOptimize` 值类型生成的内部序列化与反序列化代码，负责在 C# struct 和 Lua userdata 的二进制数据区之间复制数据：

```text
C# struct
    ↓ CopyByValue.Pack
Lua userdata 数据区

Lua userdata 数据区
    ↓ CopyByValue.UnPack
C# struct
```

它与 `WrapPusher.cs` 的职责不同：

```text
WrapPusher.cs
负责 Push、Get、Update，以及 userdata 的创建和类型检查

PackUnpack.cs
负责 struct 字段的序列化和反序列化
```

例如，`WrapPusher` 创建 userdata 后会调用：

```csharp
IntPtr buffer = LuaAPI.xlua_pushstruct(
    L,
    12,
    Position_TypeID);

CopyByValue.Pack(buffer, 0, position);
```

其中 `xlua_pushstruct` 负责创建值类型容器，`CopyByValue.Pack` 负责把 `position` 的具体字段写入容器的数据区。

### 生成的 Pack 与 UnPack

假设定义了：

```csharp
[GCOptimize]
public struct Position
{
    public float x;
    public float y;
    public float z;
}
```

`PackUnpack.cs` 会在 `CopyByValue` 的 partial 类中生成：

```csharp
public static bool Pack(IntPtr buffer, int offset, Position value)
{
    return LuaAPI.xlua_pack_float3(
        buffer,
        offset,
        value.x,
        value.y,
        value.z);
}
```

它把三个字段依次写入 userdata：

```text
offset 0：x
offset 4：y
offset 8：z
```

反序列化代码为：

```csharp
public static bool UnPack(IntPtr buffer, int offset, out Position value)
{
    value = default(Position);

    float x;
    float y;
    float z;

    if (!LuaAPI.xlua_unpack_float3(
        buffer,
        offset,
        out x,
        out y,
        out z))
    {
        return false;
    }

    value.x = x;
    value.y = y;
    value.z = z;
    return true;
}
```

由此完成：

```text
Position → userdata.data
userdata.data → Position
```

### 基础类型与复合类型

XLua 源码中的 `CopyByValue.cs` 已经提供基础类型的重载：

```csharp
Pack(buffer, offset, intValue);
Pack(buffer, offset, floatValue);

UnPack(buffer, offset, out intValue);
UnPack(buffer, offset, out floatValue);
```

生成的 `PackUnpack.cs` 则为复合 struct 补充重载：

```csharp
Pack(buffer, offset, positionValue);
UnPack(buffer, offset, out positionValue);
```

如果 struct 包含不同类型的字段，生成代码会逐字段调用对应的基础类型重载。例如：

```csharp
public struct PlayerData
{
    public int id;
    public float speed;
}
```

生成结果近似为：

```csharp
public static bool Pack(IntPtr buffer, int offset, PlayerData value)
{
    if (!Pack(buffer, offset, value.id))
        return false;

    if (!Pack(buffer, offset + 4, value.speed))
        return false;

    return true;
}
```

嵌套 struct 也通过相同方式递归处理。生成器会为子结构生成对应的 `Pack/UnPack`，最终把所有字段写入同一个 userdata 数据区。

### float 字段的批量优化

Unity 中常见的 `Vector2`、`Vector3`、`Vector4`、`Quaternion` 等类型都由多个 float 组成。XLua 为此提供：

```text
xlua_pack_float2 ～ xlua_pack_float6
xlua_unpack_float2 ～ xlua_unpack_float6
```

例如 `Vector3` 可以通过一次调用写入三个 float：

```csharp
LuaAPI.xlua_pack_float3(
    buffer,
    offset,
    value.x,
    value.y,
    value.z);
```

而不需要分别调用：

```csharp
xlua_pack_float(... value.x);
xlua_pack_float(... value.y);
xlua_pack_float(... value.z);
```

这项优化不会减少复制的数据量，主要目的是减少 C# 与 Native 之间的调用次数。

### Lua table 的反序列化支持

对于直接配置的根类型，`PackUnpack.cs` 还会生成 Lua table 到 C# struct 的转换：

```csharp
public static void UnPack(
    ObjectTranslator translator,
    RealStatePtr L,
    int index,
    out Position value)
{
    value = new Position();

    // 读取 table["x"]
    // 读取 table["y"]
    // 读取 table["z"]
}
```

因此 `WrapPusher.Get` 可以同时处理：

```text
二进制 userdata → C# struct
Lua table       → C# struct
```

`PackUnpack.cs` 不会单独向 Lua 注册类型，它由 `WrapPusher.cs` 的 `Push/Get/Update` 直接调用。

## 其他运行时成本与优化 {#runtime-optimization-overview}

生成 Wrap 与反射回退的差异已经在 [生成 Wrap 的方法调用过程](/posts/xlua-lua-call-csharp/#generated-method-call) 和 [未生成 Wrap 时的反射回退](/posts/xlua-lua-call-csharp/#reflection-fallback) 中完整解释。本文不再重复调用链，而是讨论 XLua 还通过哪些机制缩短运行时路径。

| 成本来源 | 对应优化 |
| --- | --- |
| 反射调用 | 预生成静态 Wrap |
| 重复类型与参数分析 | Type ID、MethodWrap、Caster、Checker 缓存 |
| userdata 合法性检查 | 在已确认上下文中使用 `FastGetCSObj` |
| struct 装箱 | `GCOptimize`、WrapPusher、PackUnpack |
| 重复创建 userdata | `reverseMap` 与弱 `cacheRef` |
| 多次 P/Invoke 往返 | `xlua_*` Native 扩展函数 |

## Caster、Checker 与类型缓存 {#conversion-caches}

`ObjectTranslator` 为类型转换维护多组缓存：

- `ObjectCheckers`：判断 Lua 值能否赋给目标 C# 类型；
- `ObjectCasters`：将 Lua 值真正转换成指定 C# 类型；
- `typeIdMap`：保存 C# `Type` 与 Lua metatable/type ID 的关系；
- `delayWrap` 与 `loaded_types`：保存 Wrap loader 和类型加载状态；
- `MethodWrapsCache`：保存反射路径已经构建的方法调用计划。

Checker 与 Caster 的职责不同。重载分派阶段只需要回答“当前参数能否匹配这个签名”，因此使用 Checker；选定目标重载以后，才通过 Caster 执行真正的取值和转换：

```text
Lua 实参
    ↓
ObjectCheck[]：选择可用重载
    ↓
ObjectCast[]：Lua 值转换成 C# 参数
    ↓
调用目标方法
```

反射路径中的 `OverloadMethodWrap` 会提前保存每个参数对应的 Checker、Caster、默认值、`ref/out` 位置以及 `params` 信息。缓存消除的是重复查找类型和分析签名的成本，每次调用仍然必须执行实际的参数检查和类型转换。

对于泛型 `Get<T>` 和 `PushByType<T>`，XLua 还会优先查找已经为目标类型建立的专用 get/push 委托，避免每次都从 `object` 通用入口重新判断类型。

## SafeGetCSObj 与 FastGetCSObj {#safe-and-fast-object-access}

userdata 中保存的是 `ObjectPool` index。XLua 提供两条从 userdata 取得 C# 对象的路径：

```csharp
SafeGetCSObj(L, index)
FastGetCSObj(L, index)
```

两者最终都会通过 index 查询 `ObjectPool`，区别在于 Native 层取得 index 时采用的前置检查不同：

- `SafeGetCSObj` 使用安全读取入口，适合尚未确认栈值来源的通用转换逻辑；
- `FastGetCSObj` 假设当前栈位置已经是合法的 XLua userdata，减少重复验证。

生成 Wrap 的实例方法由固定 metatable 中的回调进入，并且重载检查已经确认了调用上下文，因此通常可以直接使用：

```csharp
SomeType self =
    (SomeType)translator.FastGetCSObj(L, 1);
```

而通用 API、动态转换和外部传入的任意栈值不能依赖这个前提，需要使用安全路径。该优化的本质是：由生成器和前置分派证明安全条件，运行时再走更短的读取路径。

## Native 扩展如何减少边界往返 {#native-extensions}

XLua 不只导入标准 Lua C API，还在 Native 层增加了多组 `xlua_*` 扩展函数：

```text
xlua_pushcsobj
xlua_tryget_cachedud
xlua_tocsobj_safe
xlua_tocsobj_fast
xlua_pushstruct
xlua_tostruct
```

这些函数封装了 userdata 创建、对象索引读写、弱缓存查询、安全检查和 struct 内存访问等组合操作。

如果完全通过标准 Lua C API 实现一次 userdata 查询，C# 侧可能需要多次 P/Invoke：取得缓存表、压入 key、读取值、检查 userdata、读取 index。XLua 将这些连续操作合并到 Native 层，使 C# 只需要调用一个 `xlua_*` 函数即可取得结果。

因此，Native 扩展优化的不是某一个 C# 方法本身，而是减少一次逻辑操作所需的 Managed/Native 边界往返次数。
