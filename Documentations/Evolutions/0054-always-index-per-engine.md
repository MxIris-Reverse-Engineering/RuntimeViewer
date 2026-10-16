# 0054 - Always Index 按 Engine 区分

- **状态**: Implemented
- **创建日期**: 2026-10-15
- **最后更新**: 2026-10-15

## 摘要

Settings › Indexing 的 Always Index 清单原先是全局的。文档打开、切换 Engine、清单变化时，都会把整张清单派发给文档当前所在的 Engine。结果是 My Mac、Mac Catalyst、Attach 的进程、设备各索引一遍，而注入进程的索引是在目标进程里面跑的。改为每个条目自己选适用的 Engine：每行加一个多选菜单，选「All Engines」或具体几个 Engine；协调器只派发适用于自己那个 Engine 的条目。现有条目解码后是 All Engines，行为不变。

## 方案

**数据**（`RuntimeViewerSettings`）

- `AlwaysIndexEntry` 新增两个字段，都带 `@Default`，旧 `settings.json` 照常解码：
  - `appliesToAllEngines: Bool = true`
  - `engines: [EngineReference] = []`：只在前者为 false 时生效。切回 All 时不清空，再切回来可恢复原来的选择。
- 新增 `EngineReference { key, name, hostName }`。`key` 用来匹配 Engine；`name` 和 `hostName` 是选中那一刻的 Engine 名和所在主机名，只在该 Engine 没连上时用来显示。
- 勾选规则写在 `AlwaysIndexEntry` 上：`applies(toEngineWithKey:)` 判断是否派发，`selectsEngine(withKey:)` 和 `setEngine(_:isSelected:)` 供菜单读写。设置页只做绑定。

**Engine 的键**：`EngineReference.key(for:)`，放在 `RuntimeViewerSettings`，设置页和协调器共用。

- 默认用 `scope:` 加 `engine.bookmarkScope.bookmarkKey`，书签和 Find 的最近查询已经在用它。下面这些 Engine 都已稳定：My Mac；Mac Catalyst；设备和模拟器里的进程（按「设备 + 进程名」认，重新注入也不变）；直连 TCP。
- 例外是身份里带 pid 的那一类，也就是本机 Attach 的进程（XPC 和 socket 两种传输都算）。它们改用 `process:` 加进程名 `engine.source.description` 作键，目标重启后仍能匹配。判据是 `.remote` / `.localSocket` 身份的 identifier 能解析成 pid；同为 `.remote` 的 Mac Catalyst 身份是固定名字，不受影响。
- 两类键前缀不同，进程名不可能冒充成身份。键写进了 `settings.json`，拼法由测试钉住。

**协调器**（`RuntimeBackgroundIndexingCoordinator`）

- 先把条目投影到本 Engine：只留 `isEnabled` 为真、且对本 Engine 适用的条目，每条只取标识和 Recursive（`AlwaysIndexDispatch`）。`startAlwaysIndexBatches()` 只派发投影里的条目。
- 设置变化时比较前后两次投影，不比较条目本身。这样只改了别的 Engine 的选择，不会在本 Engine 上重新派发。
- 条目改成不含本 Engine，按现有「关掉 / 删掉这一行」的语义处理：在跑的批次自然跑完，之后不再派发。
- 键每次从当前 Engine 现算；切换 Engine 时，用新 Engine 的投影重设比较基线。

**设置页**（`AlwaysIndexSection`）

- 每行在输入框后加一个 Engine 多选菜单：顶部是「All Engines」，下面按主机分组列出 Engine，和工具栏的 Engine 切换菜单一样。菜单标签显示 `All Engines`、单个 Engine 名、`N Engines` 或 `No Engines`。
- 菜单里列出两类 Engine：
  - 当前已连上的，订阅 `RuntimeEngineManager.$runtimeEngineSections`（工具栏用的同一份列表）。同一主机分组内同键的 Engine 只列一次。为此 `RuntimeViewerSettingsUI` 新增对 `RuntimeViewerEngineManagement` 的依赖，只在 macOS 上。
  - 这一行限定了、但现在没连上的，列在最后的「Not Connected」组，显示「名字 — 主机名」。All Engines 状态下不列，因为那时记着的选择不生效。
- 勾选规则：
  - 勾「All Engines」，对全部 Engine 生效。
  - 当前是 All 时勾某个 Engine，变成只选它。
  - 其余情况逐个增减。
  - 全部取消就是 No Engines，这一行哪里都不索引。不自动回落到 All，否则取消勾选反而会扩大范围。
- 同步改 footer 文案。

**没有询问、直接采用的假设**

- 新加的行默认 All Engines，和现有条目一致。
- 镜像来的 Engine 可能和本机同类 Engine 同键，从而共用选择。例如另一台 Mac 的 My Mac 和本机 My Mac 身份相同，这是 0033 已经记下的缺口，本提案不处理。菜单里两项各留在自己的主机分组，勾一个两个都显示勾上，用户看得出它们是同一个选择。
- 进程名取的是 Attach 列表里的本地化名（`NSRunningApplication.localizedName`）。系统语言切换后同一个 App 的名字会变，需要重选，接受这个代价。
- CLI 和 iOS 端没有后台索引的设置页，不受影响。旧版本 App 读到新文件会忽略新字段，条目回到对所有 Engine 生效。

**测试**

- `RuntimeViewerSettingsTests/AlwaysIndexEngineTests`（该测试 target 为此新增对 `RuntimeViewerCore` / `RuntimeViewerCommunication` 的依赖）：
  - 键推导：local、Catalyst、XPC Attach、socket Attach、设备进程、directTCP、legacy 各一例，期望值写成字面量；Attach 进程换 pid 后键不变；两台设备上的同名进程键不同。
  - 解码：不带新字段的旧 JSON 解码为 All Engines；限定了 Engine 的条目编码再解码不变。
  - 勾选规则：All 状态下勾一个只剩它；取消最后一个是 No Engines，不回落到 All；切到 All 再切回，原选择还在；重复勾选不重复记录。
- `RuntimeViewerApplicationTests/RuntimeBackgroundIndexingAlwaysIndexEngineTests`：用真实的进程内 `RuntimeEngine`，借 `bookmarkScope:` 参数造出不同身份。覆盖五种情况：
  - 只派发本 Engine 的条目；
  - All Engines 的条目在每个 Engine 上都派发；
  - 改别的 Engine 的选择，不在本 Engine 上重新派发；
  - 去掉本 Engine 后不取消在跑的批次，批次结束后也不再派发；
  - 切换 Engine 后，条目按新 Engine 匹配。
- 证明「没有派发」时不靠等待一段时间，而是等同一轮里排在后面的条目的批次落地：协调器按清单顺序起批次，后面的落地了，前面的若被派发早就起了。

**文档**：0002 的决策日志加了一行指向本提案，因为 Always Index 的语义变了；术语表新增「Engine 键」，紧挨「书签作用域」，说明它为什么在本机 Attach 的进程上偏离书签的规则。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-15 | Created as Draft | 用户原话：「加一个需求，"总是后台索引"要按Engine区分，现在是每个Engine都要索引一份」 |
| 2026-10-15 | 每个条目自己选 Engine（多选菜单）。不做「每个 Engine 一张清单」，也不做「整张清单按 Engine 开关」 | 用户选定。现有条目不用搬，点一下就能收窄到某个 Engine；同一个镜像要在几个 Engine 上索引也只写一行 |
| 2026-10-15 | 本机 Attach 的进程按进程名认 | 用户选定。这类 Engine 的 `RuntimeBookmarkScope` 带 pid，目标一重启就对不上，选择会丢，还会在设置里留下死记录。0033「持久化键不得用显示名」那条规则，防的是书签之类的数据被同名对端混在一起；这里的键是用户写的匹配规则，同名进程共用一个选择正是想要的结果。设备上注入的进程本来就按「设备 + 进程名」认 |
| 2026-10-15 | 只改 Always Index | 用户选定。总开关、Max Concurrent Tasks、Discover from Main Executable 仍是全局设置 |
| 2026-10-15 | 状态 → Accepted | 用户批准：「开工」 |
| 2026-10-15 | `EngineReference` 存 `name` 和 `hostName` 两个字段，不存一个 `displayName` | 没连上的 Engine 要能分清是哪台设备上的同名进程，比如两台 iPhone 上的 SpringBoard。菜单标签只放进程名，免得挤占一行的宽度；「Not Connected」组显示「名字 — 主机名」 |
| 2026-10-15 | 「Not Connected」只在这一行限定了 Engine 时列出 | All Engines 状态下记着的旧选择不生效，列出来会让人以为它们有作用。限定状态下列出的都是勾着的，取消勾选就忘掉 |
| 2026-10-15 | 同键的 Engine 只在同一主机分组内合并，不跨分组合并 | 跨分组合并会让另一台 Mac 的分组里少掉它的 My Mac，看起来像那台 Mac 没有本地 Engine |
| 2026-10-15 | 状态 → Implemented | RuntimeViewerPackages 全套测试通过；`RuntimeViewer macOS` 用 Debug workspace 编译通过。协调器的新测试经三种改坏法验证会变红：去掉 Engine 过滤、派发时不按 Engine 过滤、任何编辑都重新派发。设置页的菜单只编译过，没在 App 里目视验证。配套文档：不写使用指南，设置页 footer 已说明用法；不写实现说明，方案一节与代码注释已覆盖。术语表新增「Engine 键」 |
