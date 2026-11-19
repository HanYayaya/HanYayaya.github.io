# Xlua源码阅读 (2.1.16)：拆分记录与审阅入口

本轮根据完整源码分析的方向，将原稿拆成六篇工作稿。文章均位于 `content/posts/`，设置为 `draft: true`，尚未发布。

分类路径为 `Lua/XLua/Xlua源码阅读 (2.1.16)`，文章标题按 `1. 从 LuaEnv 到类型延迟注册` 至 `6. Hotfix 的构建期注入与运行时分派` 编号。侧栏按分类层级展开，系列内使用 `series_order` 升序排列；原有文章 slug 和链接不变。

## 六篇草稿

| 顺序 | 草稿 | 原稿内容 | 初次拆分行数 | 代码与示意块 |
| --- | --- | --- | ---: | ---: |
| 1 | [从 LuaEnv 到类型延迟注册](../../content/posts/xlua-initialization/index.md) | 第 3 章、1.2—1.5、1.1.8 | 923 | 64 |
| 2 | [Lua 如何调用 C#](../../content/posts/xlua-lua-call-csharp/index.md) | 2.2、1.1.1—1.1.3 | 1124 | 85 |
| 3 | [C# 如何调用 Lua](../../content/posts/xlua-csharp-call-lua/index.md) | 2.1、1.1.4—1.1.5 | 1175 | 95 |
| 4 | [对象映射与跨语言生命周期](../../content/posts/xlua-object-lifecycle/index.md) | 第 4 章 | 241 | 13 |
| 5 | [值类型传递与运行时优化](../../content/posts/xlua-value-types-and-performance/index.md) | 1.1.6—1.1.7、第 5 章 | 1197 | 77 |
| 6 | [Hotfix 的构建期注入与运行时分派](../../content/posts/xlua-hotfix/index.md) | 第 6—8 章 | 177 | 8 |

上表行数记录初次拆分时的 Front Matter、系列目录和手写前后篇链接，仅用于比较内容体量。页脚导航现已由主题根据 `series` 和 `series_order` 自动生成，左侧为上一篇、右侧为下一篇；各篇 Markdown 不再手写这些链接。

## 本轮编排

- 第一篇从整体运行结构进入 `new LuaEnv()` 的初始化流程，再详细分析总注册器。新增生成文件职责表，为后续各篇提供入口。
- 第二篇沿类型查找、Wrap 注册、实例调用组织内容，再讨论枚举、C# Delegate 和反射回退。
- 第三篇从执行 Chunk、持有 Lua 对象和 LuaFunction 调用，进入 DelegateBridge 与 InterfaceBridge 的生成及使用。
- 第四篇将对象表示、三组映射、弱缓存、userdata 回收、Registry 引用释放和跨 GC 引用环组织为六节。
- 第五篇将 GCOptimize 总览提前，再展开 WrapPusher、PackUnpack 和其他运行时优化。
- 第六篇保留 Hotfix 原理、构建期流程和运行时安装分派三部分。

各篇补充了导语、可折叠系列目录、前后篇链接和稳定的章节锚点。原稿的 10 处 Obsidian 章节引用已转成篇内或篇间链接，两处 callout 已改用主题现有的 `notice` shortcode。

原有示例和调用链均保留。相近主题的多个例子也暂时保留，后续可以结合源码核对，决定是否合并重复解释。本轮仅调整章节顺序、标题层级、衔接语，以及下列两处表述：

- 将“DelegateBridge 包装 LuaFunction.Call”改为“DelegateBridge 的目标方法通过 Lua Stack、Registry 引用和 lua_pcall 调用”，避免把共享的底层机制误写成对 `LuaFunction.Call` 的实际包装。
- 补完原稿 Delegate Wrap 小节末尾悬空的“准确结论是：”，归纳该节已经说明的公共 metatable、调用包装缓存与反射执行路径。

## 下一轮内容讨论

这部分记录待讨论的补充方向，本轮未据此扩写。

| 篇目 | 根据现有内容可讨论的补充方向 |
| --- | --- |
| 全系列 | 按指定的 XLua 2.1.16 核对具体源码或 commit、Lua 后端及相关编译条件；统一标注源码摘录、删减代码和概念示意 |
| 第一篇 | 生成阶段与运行阶段的总流程图，LuaEnv 构造函数及初始化器的源码定位 |
| 第二篇 | 选一个完整类型，串联生成模板、生成的 Wrap、Native indexer 和最终 C# 调用；核对特殊类型分支 |
| 第三篇 | 补齐成功与异常路径的 Lua 栈变化，结合模板定位 DelegateBridge 与 InterfaceBridge 的生成逻辑 |
| 第四篇 | 结合 ObjectPool、collectObject、LuaBase 与 Tick 的实际源码展开回收顺序，演示旧 userdata 与新映射的时序关系 |
| 第五篇 | 对照 Native 数据结构说明 userdata 内存布局，区分 Lua 分配、C# 装箱和边界调用各自的成本 |
| 第六篇 | 用同一个方法贯穿 Cecil 注入代码、注入后的 IL、补丁安装函数与 DelegateBridge 分派，补足目前以概念流程为主的分析 |

建议先讨论第四、六篇的源码深度；第二、三、五篇已有较多细节，可以先结合具体版本核对并合并重复解释。

## 原稿与校验

- 原稿：`E:/Project/XLua 设计原理：对象映射、生命周期与 Hotfix.md`。
- 原稿 SHA-256：`4b260597f6f6c3eebf984eaa0b04416f54139603a687e55e27d814fc2497d26d`。
- 六篇草稿合计保留原稿全部 342 个 fenced block，逐块内容及出现次数一致。
- 原稿正文均已分配，去掉的六行仅为被新文章结构替代的父级标题。
- 已检查系列链接、跨篇锚点、篇内锚点、代码围栏配对及 notice shortcode 配对。
- 原稿日期保留为 `2026-09-15`，整理日期记录为 `lastmod: 2026-11-19`；发布日期留待讨论发布方案时统一确定。
- 本轮未按特定 XLua commit 逐项校核技术结论；源码版本确认与内容补充放在下一轮讨论。
- 已用 Hugo Extended 0.168.0 完成包含草稿的页面构建；六篇文章均已生成，生成 HTML 中的系列链接、章节锚点及两处 notice 提示框检查通过。本地预览使用 README 中的启动命令。
