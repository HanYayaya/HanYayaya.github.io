---
title: "6. Hotfix 的构建期注入与运行时分派"
slug: xlua-hotfix
date: 2026-09-15
lastmod: 2026-11-19
description: "分析 Hotfix 的预留分支、Delegate 适配、Mono.Cecil 注入、IL2CPP 构建顺序与运行时补丁安装。"
categories:
  - "Lua/XLua/Xlua源码阅读 (2.1.16)"
tags:
  - Lua
  - XLua
  - Unity
  - Hotfix
series:
  - Xlua源码阅读 (2.1.16)
series_order: 6
draft: true
toc: true
---

XLua 如何让一个已经编译的 C# 方法执行 Lua 补丁？本文把过程分成构建期和运行时：构建期预留可切换的 Delegate 分支，运行时将 Lua function 适配后写入入口，再由原方法分派到补丁。

<details>
<summary>Xlua源码阅读 (2.1.16) · 系列目录</summary>

1. [从 LuaEnv 到类型延迟注册](/posts/xlua-initialization/)
2. [Lua 如何调用 C#](/posts/xlua-lua-call-csharp/)
3. [C# 如何调用 Lua](/posts/xlua-csharp-call-lua/)
4. [对象映射与跨语言生命周期](/posts/xlua-object-lifecycle/)
5. [值类型传递与运行时优化](/posts/xlua-value-types-and-performance/)
6. [Hotfix 的构建期注入与运行时分派](/posts/xlua-hotfix/)

</details>

## Hotfix 的本质 {#hotfix-principle}

{{< notice type="important" title="Hotfix 不是运行时修改 IL" >}}
XLua 在构建前给目标 C# 方法注入一个可选的 Lua Delegate 分支。运行时只是设置或清空预先生成的分派入口。
{{< /notice >}}

假设原始方法为：

```csharp
public int Add(int a, int b)
{
    return a - b;
}
```

经过 Hotfix 注入后，概念上相当于：

```csharp
private static HotfixDelegate __Hotfix0_Add;

public int Add(int a, int b)
{
    var fix = __Hotfix0_Add;

    if (fix != null)
    {
        return fix(this, a, b);
    }

    return a - b;
}
```

Hotfix 的核心技巧，是把“运行时替换一个已经编译的方法”转换成“运行时改变一个预编译条件分支所指向的 Delegate”。

Hotfix 本身不重新实现 C# → Lua 调用，而是复用 [Lua function 转换成 C# Delegate](/posts/xlua-csharp-call-lua/#lua-function-to-delegate) 中的 DelegateBridge、参数压栈和返回值转换能力。IL 注入只负责在原 C# 方法中预留一个可切换入口。

## Hotfix 的构建期流程 {#hotfix-build-process}

### 选择可热修复类型 {#hotfix-targets}

项目通过 `[Hotfix]` 配置选择需要注入的类型。配置必须在发布前确定，因为未注入的方法没有运行时替换入口。

### 生成 Delegate 适配代码 {#hotfix-delegate-generation}

被修复的 C# 方法最终会调用 Lua function，因此这是一次 C# → Lua 调用。XLua 必须为方法签名准备对应的 DelegateBridge：

```text
C# 方法参数
    ↓
签名匹配的 Delegate
    ↓
DelegateBridge
    ↓
参数压入 Lua Stack
    ↓
lua_pcall
    ↓
读取 Lua 返回值
```

这也是 Hotfix 流程要求先执行 Generate Code 的重要原因。

这里不再展开 DelegateBridge 内部如何调用 Lua，只需要明确：生成阶段必须为每一种被注入的方法签名准备可用的 C# Delegate 类型和对应 Bridge 入口。

### Mono.Cecil 注入 {#cecil-injection}

XLua 使用 Mono.Cecil 修改目标程序集：

1. 为方法添加私有静态 Delegate 字段；
2. 在方法体中插入读取 Delegate 字段的指令；
3. Delegate 为 `null` 时跳转到原始方法体；
4. Delegate 非空时加载 `this` 和方法参数；
5. 调用 Delegate；
6. 普通方法直接返回 Lua 补丁结果。

默认字段名称形如：

```text
__Hotfix0_MethodName
__Hotfix1_MethodName
__Hotfix2_MethodName
```

数字用于区分同名重载。构造函数字段会带 `_c` 前缀。

### IL2CPP 转换 {#il2cpp-build-order}

Hotfix 注入发生在 IL2CPP 之前：

```text
C# Assembly
    ↓ Mono.Cecil 注入
带 Hotfix 分支的 Assembly
    ↓ IL2CPP
C++
    ↓ Native 编译
最终 Player
```

因此最终 Native 程序中本来就存在条件分支、Delegate 字段和 DelegateBridge 调用路径。运行时不需要生成新的 C# 代码，也不需要修改 Native 机器码。

## Hotfix 的运行时安装与分派 {#hotfix-installation}

Lua 侧安装补丁：

```lua
xlua.hotfix(CS.HotfixCalc, "Add", function(self, a, b)
    return a + b
end)
```

可以拆解成：

```text
取得目标 C# Type
    ↓
寻找 __HotfixN_Add 静态字段
    ↓
根据字段的 Delegate 类型包装 Lua function
    ↓
创建或复用 DelegateBridge
    ↓
将 Delegate 写入静态字段
```

之后调用 C# 方法时：

```text
进入已经注入的方法
    ↓
读取 Hotfix Delegate
    ├─ null：执行原始 C# 方法
    └─ 非 null：调用 DelegateBridge
                     ↓
                  执行 Lua 补丁
```

给 `xlua.hotfix` 传入 `nil`，本质上是将注入字段重新设为 `null`，从而恢复原始 C# 路径。
