# Draft - Filter Scope 按 Engine 与 Image 记住

- **状态**: In Progress
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **所属愿景**: 无
- **关联提案**: [0049](0049-scope-filter-all-object-properties.md)（Filter Scope 补齐全部属性）、[0054](0054-always-index-per-engine.md)（Engine 的稳定键：本机 Attach 的进程按进程名认）、[0022](0022-reveal-in-sidebar-navigator.md)（Reveal 为露出那一行清掉过滤条件）
- **实现分支 / PR**: `feature/filter-scope-memory`（从 `next` 切出）

## 摘要

侧栏对象列表的 Filter Scope 只存在页面的 ViewModel 里：每次进入一个 Image，侧栏都新建这个 Image 的列表页与书签页，Scope 回到默认；同一个 Image 的两个页面也各有一份，互不相通。改为按 Engine 与 Image 记住：存进 `AppDefaults` 的一个文件，键是 Engine 的稳定键（与 Always Index 认 Engine 的键相同）加 Image 路径。同一个 Image 的两个页面、别的窗口里的同一个 Image 都读写这一份，改一处其余跟着变，重开 App 之后还在。Match Case 开关同时改为全局记住，与 Filter Mode 一样。

## 方案

**存储**

- `RuntimeObjectScope` 可编码，存成 `{"excludedKinds": [...], "propertyStates": {"notExported": "exclude"}}`，没有内容的键不写。种类存「被排除的」而不是白名单：白名单里不会有以后新增的种类，按白名单存，记住的 Scope 会把用户从没见过、也没选过要隐藏的新种类挡掉。属性与状态按原始值（rawValue）存，`Property` 与 `PropertyState` 的原始值从此是存盘格式，不得改名。
- 读取宽松：认不出的种类、属性或状态只丢那一项，不丢整个 Scope；整个 Scope 解不出来只丢这个 Image 的那一条（`LenientlyDecodable`，与书签相同的 `ResilientFileStorage`）。
- `AppDefaults.runtimeObjectScopesByEngineAndImagePath`：`[Engine 键: [Image 路径: Scope]]`，文件 `AppStorage/runtimeObjectScopesByEngineAndImagePath.json`。只存起作用的 Scope：改回默认（Reset，或把每一项都改回）就删掉这一条，Engine 下没有条目了连 Engine 键一起删。
- Engine 键用 `Settings.Indexing.EngineReference.key(for:)`：本机 Attach 的进程按进程名认，目标重启后照样记得；其他 Engine 用书签的 scope 键。键的拼法与增删规则只写在 `RuntimeObjectScopeMemory` 一处。
- `AppDefaults.isRuntimeObjectFilterCaseSensitive`：Match Case 开关，存在 user defaults 里。

**ViewModel**（`SidebarRuntimeObjectViewModel`，列表页与书签页共用的基类）

- 初始化时取出记住的 Scope 作为初值，第一次加载就按它过滤。
- `scope` 每次变化（弹窗里的改动、Reveal 清过滤）写回存储；存储一变（另一个页面或另一个窗口改了同一个 Image 的 Scope）就读出存储的**当前值**，与自己的不同才赋值。不用变化事件里带的值：存储的写是异步的，事件到达时可能已经有更新的一次写，拿事件里的旧值会把新值改回去。
- Match Case 的初值取 `AppDefaults`，变了就写回。视图在建 `Input` 之前把按钮设成这个初值。

**弹窗**

- 当前 Image 里没有对象带的属性照旧隐藏，但有约束的行一律显示：记住的 Scope 可能约束一个暂时还没有对象带上的属性（比如后台索引完成之前的 Not Exported），藏起来就既看不出列表为什么空、也撤不掉。

**没有询问就采用的假设**

- 同一个 Image 的列表页与书签页共用一份 Scope（原来各有一份）。
- 没配置过的 Image 从空 Scope 开始，不沿用别的 Image 的。
- Reveal in Sidebar Navigator 为露出那一行清掉 Scope 时，记住的也一并清掉，与 Xcode 揭示文件时清掉导航器过滤一致：记住的总是用户看到的。
- 过滤框里的文字不记。
- 不设条目上限：只存改过的 Scope，量很小。
- 另一台 Mac 镜像过来的 Engine 与本机同类 Engine 同键时共用一份，与 0054 记下的缺口相同。

**落地步骤**

1. ✅ `RuntimeObjectScope` 的编码与宽松解码、`RuntimeObjectScopeMemory`、`AppDefaults` 的两项；单元测试。
2. `SidebarRuntimeObjectViewModel` 接入记忆、页面间同步与 Match Case；ViewModel 测试。
3. 视图：Match Case 按钮的初值、弹窗显示有约束的行；`AGENTS.md` 补一条规则（`Property` 的原始值是存盘格式）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created as Draft | 侧栏的 Filter Scope 每次进入 Image 都回到默认，用户希望按 Engine 与 Image 记住 |
| 2026-11-11 | 用户批准，提案由 agent 起草、用户事前未审阅全文 | 用户看过交互缺口的盘点与默认做法后，选择三块（本提案、右键菜单、键盘与标准命令）都做，经 `implement-feature` 一路实现 |
| 2026-11-11 | 开始实现 | |
| 2026-11-11 | 种类存「被排除的」 | 白名单存盘后，以后新增的种类会被已记住的 Scope 隐藏 |
| 2026-11-11 | Engine 键沿用 Always Index 的 `EngineReference.key(for:)`，不用书签的 scope 键 | 书签键对本机 Attach 的进程带 pid，目标一重启就对不上；Scope 是用户写的过滤条件，按进程名共用正合适 |
