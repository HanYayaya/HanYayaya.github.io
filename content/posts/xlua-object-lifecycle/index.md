---
title: "4. 对象映射与跨语言生命周期"
slug: xlua-object-lifecycle
date: 2026-09-15
lastmod: 2026-11-19
description: "分析 ObjectPool、reverseMap、弱 userdata 缓存，以及 Lua 引用释放、Delegate 生命周期和跨 GC 引用环。"
categories:
  - "Lua/XLua/XLua 2.1.16 源码阅读"
tags:
  - Lua
  - XLua
  - Unity
series:
  - XLua 2.1.16 源码阅读
series_order: 4
draft: false
toc: true
---

C# GC 与 Lua GC 相互独立。XLua 除了完成值转换，还必须解决以下问题：

- C# 对象在 Lua 中如何表示；
- 同一个 C# 对象多次进入 Lua 时如何保持身份一致；
- userdata 被 Lua GC 回收后，如何释放 C# 引用；
- C# 持有 Lua 对象时，如何安全释放 Registry 引用；
- 两个 GC 系统之间形成引用环时应该如何处理。

## C# 对象如何表示为 userdata {#userdata-object-index}

XLua 不会把托管对象地址直接写进 userdata。普通引用类型进入 Lua 时，先被放入 `ObjectPool`，userdata 中只保存对应的整数索引：

```text
Lua userdata
    │ 保存 int index
    ▼
ObjectPool[index]
    │
    ▼
真实 C# object
```

Native 层的数据写入可以概括为：

```c
int* pointer = (int*)lua_newuserdata(L, sizeof(int));
*pointer = key;
```

随后，XLua 根据 C# 类型对应的 type ID，为 userdata 设置已经注册好的实例 metatable。成员查找和 Wrap 调用过程已经在 [C# 实例在 Lua 中表现为 userdata](/posts/xlua-lua-call-csharp/#instance-userdata) 与 [生成 Wrap 的方法调用过程](/posts/xlua-lua-call-csharp/#generated-method-call) 中说明，本文只关注对象身份和生命周期。

`ObjectPool` 内部是带空闲链表的 `Slot[]`：

```csharp
struct Slot
{
    public int next;
    public object obj;
}
```

它承担两项职责：

1. 通过整数索引快速取得真实 C# 对象；
2. 在 Lua userdata 存活期间强引用 C# 对象，避免 C# GC 提前回收它。

对象从池中移除后，槽位会加入 freelist，供后续对象复用。这样既不需要在 userdata 中保存托管地址，也不需要为每个对象单独创建 `GCHandle`。

## ObjectPool、reverseMap 与 cacheRef {#object-mapping}

如果只有 `ObjectPool`，同一个 C# 对象每次进入 Lua 都会创建新的 index 和 userdata，不仅产生重复包装，也会破坏 Lua 侧的对象身份。

XLua 因此同时维护三组映射：

```text
ObjectPool: index → C# object
reverseMap: C# object → index
cacheRef:   index → Lua userdata
```

三者分别回答不同问题：

- `ObjectPool`：通过 userdata 中的 index 找到真实 C# 对象；
- `reverseMap`：判断当前 C# 对象是否已经进入过 Lua；
- `cacheRef`：根据已有 index 找回并复用原来的 userdata。

`reverseMap` 使用引用相等比较。即使两个对象的 `Equals` 返回 `true`，只要它们不是同一个 C# 引用，就不会被映射到同一个 userdata。

同一个引用再次被 Push 时，主要过程是：

```text
reverseMap 是否存在该 C# 引用？
    ├─ 否：ObjectPool.Add，创建 userdata 和三组映射
    └─ 是：得到已有 index
             ↓
          cacheRef 中是否还有 userdata？
             ├─ 是：直接复用
             └─ 否：重新创建 userdata 并更新映射
```

普通引用类型通过这套映射维持身份。普通值类型表达的是值而不是引用身份，因此默认不通过 `reverseMap` 复用。

## cacheRef 为什么必须是弱值表 {#weak-userdata-cache}

`cacheRef` 保存在 Lua Registry 中，并被设置成弱值表：

```lua
setmetatable(cache, { __mode = "v" })
```

第一次 Push 对象后，引用关系为：

```text
C# GameObject
      ↓
ObjectPool[42] = GameObject
reverseMap[GameObject] = 42
      ↓
cacheRef[42] = userdata
      ↓
Lua 变量 go = userdata
```

其中业务变量和缓存对 userdata 的引用强度不同：

```text
go           ──强引用──→ userdata
cacheRef[42] ┄┄弱引用┄┄→ userdata
```

弱值表同时满足两个目标：

1. 同一个 C# 对象再次进入 Lua 时，尽量复用原有 userdata；
2. 当业务 Lua 代码不再引用 userdata 时，缓存不能阻止 Lua GC 回收它。

如果 `cacheRef` 使用强引用，那么缓存会永久保留 userdata，userdata 又会通过 `ObjectPool` 保留 C# 对象，最终形成对象泄漏。

## userdata 回收与旧映射竞态 {#userdata-collection}

当 Lua 侧不再引用 userdata 时，Lua GC 会调用 userdata 的 `__gc`：

```text
userdata.__gc
    ↓
StaticLuaCallbacks.LuaGC
    ↓
读取 ObjectPool index
    ↓
ObjectTranslator.collectObject(index)
    ↓
ObjectPool.Remove(index)
    ↓
有条件地清理 reverseMap
```

从 `ObjectPool` 移除后，XLua 不再因为该 userdata 强引用 C# 对象。对象是否被 C# GC 回收，取决于 C# 世界中是否还有其他引用。

Lua GC 会先将 userdata 从弱表中移除，之后才延迟调用 `__gc`。在这个时间窗口中，同一个 C# 对象可能再次进入 Lua，并建立新的 index 或 userdata。

因此，XLua 不能在旧 userdata 的 `__gc` 中无条件删除 `reverseMap`，而是必须检查：

```text
reverseMap 中记录的当前 index
        ==
正在执行 __gc 的旧 userdata index
```

只有二者相等时才删除映射。否则，旧 userdata 的延迟回收可能误删后来重新建立的新映射。

## Lua 对象引用的释放 {#lua-reference-release}

Lua function 和 table 如何通过 `luaL_ref` 进入 C#，已经在 [C# 如何长期持有 Lua function 和 table](/posts/xlua-csharp-call-lua/#lua-registry-references) 中说明。这里继续讨论 Registry 引用如何释放。

释放存在两条路径：

```text
显式 Dispose
    → 立即调用 lua_unref

C# Finalizer
    → 将释放请求写入 LuaEnv.refQueue
    → LuaEnv.Tick
    → 调用 lua_unref
```

Finalizer 不能直接操作 `lua_State`，因为它的执行线程和执行时机都不可控，也不能保证此时 Lua VM 正处于允许访问的状态。因此 `LuaBase` 的 Finalizer 只把释放请求放入队列，由业务线程后续调用 `LuaEnv.Tick()` 完成真正的 Lua C API 操作。

这也意味着，如果项目长期不调用 `LuaEnv.Tick()`，由 Finalizer 触发的 Registry 引用释放会被推迟。对于生命周期明确的 `LuaFunction`、`LuaTable` 等对象，显式调用 `Dispose()` 更可控。

## Delegate 生命周期与跨 GC 引用环 {#delegate-lifetime-and-cycles}

DelegateBridge 的生成结构与调用过程见系列第三篇的 [DelegateBridge：DelegatesGensBridge.cs](/posts/xlua-csharp-call-lua/#delegate-bridge) 和 [Lua function 转换成 C# Delegate](/posts/xlua-csharp-call-lua/#lua-function-to-delegate)。这里仅关注它产生的引用关系。

同一个 Lua function 可能被转换成多个 C# Delegate 类型。XLua 使用以下结构尽量复用已有 Bridge：

```text
Lua Registry: Lua function → luaReference
C# Dictionary: luaReference → WeakReference<DelegateBridge>
DelegateBridge: Delegate Type → C# Delegate
```

第一次转换时，XLua 创建 Registry 引用和 DelegateBridge；后续转换优先复用已有 Bridge，并在 Bridge 内创建或取得目标 Delegate 类型。

如果 C# Delegate 仍然存活，DelegateBridge 就仍可能通过 `luaReference` 调用 Lua function。因此 `LuaEnv.Dispose()` 会检查是否存在尚未释放的 DelegateBridge；如果存在，则拒绝直接关闭 Lua VM，避免 Delegate 后续访问已经销毁的 `lua_State`。

{{< notice type="warning" title="XLua 不能自动发现所有跨虚拟机引用环" >}}
C# GC 只能看到托管堆，Lua GC 只能看到 Lua 堆。XLua 可以维持跨边界对象的存活关系，但无法像单一 GC 一样分析完整的跨虚拟机引用图。
{{< /notice >}}

一种典型引用环是：

```text
C# Event
 → C# Delegate
 → DelegateBridge
 → Lua Registry 中的 Lua function
 → Lua function 捕获的 userdata
 → ObjectPool 中的 C# object
 → C# Event
```

两边的 GC 都会认为下一段引用仍然可达。这类引用环需要业务层主动解除事件订阅、清空 Lua closure 捕获，或者显式释放相关包装对象。
