# Draft - RuntimeBookmarkScope：把持久化身份从显示名手里拿走

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-08-27
- **最后更新**: 2026-08-27
- **所属愿景**: 无
- **关联提案**: [0013](0013-inject-ios-simulator-process.md)（本提案处理它暴露出的持久化身份问题）
- **实现分支 / PR**: 待定 —— 等 0013 的 PR #106 合入 `next` 后开新分支
- **配套文档**: 待定 —— 落地时登记实现说明的链接

## 摘要

新建 `RuntimeBookmarkScope` 作为「一台对端」的**稳定持久化身份**，取代目前散落在三处、各自用
显示名或含 pid 的 identifier 拼出来的键：

| 现状 | 键的实际内容 | 后果 |
|---|---|---|
| 书签字典 `[RuntimeSource: …]` | Bonjour client 是 `{deviceID}-{pid}` | 对端每次启动书签全部失效，且死记录永久累积 |
| sidebar 的 `expansionAutosaveName` / `identifier` / `autosaveName` | `source.description`，即对端**进程显示名** | 两台设备注入同名进程即互相覆盖展开状态 |
| 落盘编码 | `JSONEncoder` 把键编码成含 `name` 的对象 | 键比较忽略 `name`，解码时后者静默覆盖前者 |

同时把书签的落盘从 `@FileStorage` 换成本项目自己的薄封装，让「读不动就备份、能读多少读多少」
成为可能——现在解码异常被完全吞掉，文件损坏即全部书签静默清空。

## 动机

### 三处症状，同一个病根

**病根是「用给人看的名字当给机器用的键」。** 三处独立地犯了同一个错误，且互相之间没有共享任何
身份类型，所以修好一处不会带动另外两处。

**第一处 —— 书签键含 pid**（`PR106.1`）。`RuntimeSource` 对 `.bonjour` 的 `==` / `hash` 只看
`Identifier`。0013 把客户端 `Identifier` 从对端服务名改成 `{deviceID}-{pid}`，pid 每次对端启动
都变，于是上次存的书签再也读不到，且字典按对端每次启动累积一条死记录，全仓库没有任何裁剪逻辑。
读写点共 4 处：`SidebarRootBookmarkViewModel`、`SidebarRuntimeObjectBookmarkViewModel`、
`SidebarRootDirectoryViewModel`、`SidebarRuntimeObjectListViewModel`。

**第二处 —— sidebar 持久化键用显示名**（`PR106X.1`）。`RuntimeEngineManager` 把 Bonjour client
引擎命名为 `endpoint.processName ?? endpoint.name`，`RuntimeSource.description` 原样返回它，而
`SidebarRootViewController:122,140` 与 `SidebarRuntimeObjectViewController:263,264` 把这个字符串
直接拼进 `NSOutlineView` 的 `identifier` / `expansionAutosaveName` / `autosaveName`。两台模拟器
各注入一个 SpringBoard —— 也就是 0013 的核心场景 —— 就会写同一个键。

**第三处 —— 落盘编码与相等性不一致**（`PR106.1` 附带）。`@FileStorage`（来自 `RxSwiftPlus` 的
`RxDefaultsPlus`）用裸 `JSONEncoder` 把 `[RuntimeSource: X]` 落成键值交替的 JSON 数组，键对象里
**编码了 `name`**，而 `Hashable` / `Equatable` **忽略 `name`**。落盘里两个只有 `name` 不同的键，
解码时 `==` 且 hash 相同，`Dictionary` 的无键容器解码是裸 `self[key] = value`、不做重复检测，
于是**后者静默覆盖前者**。即：对端改个显示名就可能在加载时静默销毁书签，无任何诊断。

### 项目自己知道这是错的

`RuntimeSource.identifier` 的注释原文：

> Keyed by the identifier, never the name: a Bonjour client's name is the peer's *process* display
> name, which two processes on one device can share.

`RuntimeNetworkBonjour.localServiceName` 的文档把 sidebar 的 autosave 键称作
*"the part that does lasting damage"*。

也就是说这条原则已经被写下来两次，只是每次都只落实在当时那一处。缺的不是认识，是**一个所有人
都必须用的类型**。

### 有一次方向相反的前史

`917002cc`（2026-03-04）新增 `DeviceIdentifier`，并给 `RuntimeSource` 写了忽略 `name` 的自定义
`Equatable` / `Hashable`，目的正是让持久化身份与显示名解耦。0013 把 pid 塞回键里、把显示名绑回
autosave 键，撤销了那次决策的目的。本提案是把它重新做对，并且这次做成一个**无法绕过**的类型。

> 待核实：两轮复核对 `917002cc` 的 commit message 引文说法冲突（一份称
> `2026-08-24-pr106-review-findings.md` 里引的句子不是原文）。两边对该 commit 的内容判断一致，
> 仅引文出处存疑。写进最终稿前 `git show 917002cc` 核对一次。

## 前期调研

以下全部是实测/读码确认过的事实，不是推断。

### 磁盘现状

`~/Library/Application Support/AppStorage/imageBookmarksByRuntimeSource.json` 顶层是长度 4 的
**JSON 数组**（键值交替），键对象形如：

```json
{"remote": {"role": {"client": {}}, "identifier": "com.RuntimeViewer.RuntimeSource.MacCatalyst", "name": "My Mac (Mac Catalyst)"}}
```

关键点：**键里带 `name`**。这既是第三处缺陷的成因，也是迁移唯一能用来还原进程名的信息来源。

### 对端广播里有什么

`RuntimeNetworkBonjour.makeService(name:)` 写入的 TXT 键：`instanceID`、`hostName`、`modelID`、
`osVersion`、`isSimulator`、`deviceID`、`processName`、`processIdentifier`。

- **有** deviceID 与 processName，两者都是独立的键，不需要从字符串里解析。
- **没有** bundle identifier。所以「稳定的进程身份」今天最多做到「设备 + 进程名」。

发现侧的 `RuntimeNetworkEndpoint` 同样把 `deviceID` / `processName` / `processIdentifier` 存成
三个独立字段，本机直连时身份是现成的。

### `RuntimeSource` 是走线的协议数据

`RuntimeRemoteEngineDescriptor` 持有 `source: RuntimeSource`，并通过
`RuntimeEngine.requestEngineList` / `pushEngineListChanged` 在对端之间互推。**给 `.bonjour` 加
关联值会改变它的编码形状，混版时旧对端解不了。**

该结构体已有处理这类问题的先例：`hostID` 是后加的字段，用 MetaCodable 的 `@Default("")` 标注，
注释写着 *"Empty when the peer predates this field, in which case the receiver falls back to
`originChain.first`."*

### 已有迁移先例

`AppDefaults.init` 里已经有一次一次性迁移（扁平数组 → 按 source 分组），由 UserDefaults 开关
`bookmarkMigrationCompleted` 控制，旧字段标 `@available(*, deprecated)` 保留至今、没有删除。

### 键站点清单

| 位置 | 现在的键 |
|---|---|
| `AppDefaults.imageBookmarksByRuntimeSource` | `RuntimeSource` |
| `AppDefaults.objectBookmarksBySourceAndImagePath` | `RuntimeSource` → `imagePath` |
| `SidebarRootViewController:122` | `…identifier.\(source.description)` |
| `SidebarRootViewController:140` | `…autosaveName.\(source.description)` |
| `SidebarRuntimeObjectViewController:263` | `…identifier.\(source.description)` |
| `SidebarRuntimeObjectViewController:264` | `…autosaveName.\(source.description)` |

## 提议方案

### 1. `RuntimeBookmarkScope`

放在 `RuntimeViewerCommunication`（`RuntimeSource` 所在模块），这样 `RuntimeViewerCore` 的书签
类型与 AppKit 应用侧的 autosave 键都能拿到。

身份构成按来源分别取**各自已有的稳定标识**，而不是硬凑成统一形状：

| 来源 | scope 构成 |
|---|---|
| `.local` | 固定值 |
| `.remote`（XPC） | 已有的 `Identifier`（如 `com.RuntimeViewer.RuntimeSource.MacCatalyst`，本来就稳定） |
| `.localSocket` | 已有的 `Identifier` |
| `.directTCP` | host + port |
| `.bonjour` | **deviceID + processName** |

`role`（client / server）**进 scope**，与今天 `RuntimeSource` 的相等性语义一致，迁移时能 1:1
对得上，不会出现「两个旧键映射到同一个新 scope」而需要定义合并规则的边界情况。

**落盘表示是可读的、带格式版本号的字符串**，例如 `v1:bonjour:<deviceID>:<processName>`。版本号
现在就留好，理由见「与 UDID 隐私提案的交互」。

### 2. 身份怎么到达 scope —— 不动 `RuntimeSource`

`RuntimeSource` 的 case 签名**保持不变**。结构化身份改为在 `RuntimeRemoteEngineDescriptor` 上
并行新增一个字段，照抄 `hostID` 的模式用 `@Default` 标注，旧对端缺字段即为空、接收方回退。

运行时 scope 挂在 `RuntimeEngine` 上（由创建方注入）：

- **本机直连的 Bonjour client**：`RuntimeEngineManager` 从 `RuntimeNetworkEndpoint` 现成的
  `deviceID` / `processName` 字段构造，engine 创建时一并传入。
- **镜像引擎**：从 descriptor 的新字段构造。
- **旧对端的镜像引擎**（descriptor 缺字段）：回退到从 `name` / `Identifier` 尽力解析；解析不出
  形状时退回今天的行为（用现有 identifier 字符串作为 legacy scope），并记日志。**不比现状更差**
  是这条回退的验收标准。

这样 sidebar 与书签的读取点都改为读 `runtimeEngine.bookmarkScope`，不再碰 `source.description`。

### 3. 书签存储换一层薄封装

书签不再直接用 `@FileStorage`，改用本项目自己的存储类型，把三件事放进去并做成可测的：

- **逐条容错**：坏条目跳过并记日志，不因为一条坏记录丢掉整份。
- **坡坐备份**：整份文件读不动时把它改名备份，再从空开始 —— 用户的数据始终还在磁盘上。
- **诊断**：所有降级路径都有日志。

字典的键变成 scope 的字符串表示，`[String: X]` 在 JSON 里就是正常对象而不是键值交替数组，
从根上消除「两个键解码后相等」的可能。

其余仍在用 `@FileStorage` 的字段不动。

### 4. 书签结构体删掉 `source` 字段

`RuntimeImageBookmark.source` / `RuntimeObjectBookmark.source` 删除。字典的键已经表达了归属，
字段是冗余的 —— 两处各存一份身份本身就是这类缺陷的温床，而且 `PR106.1` 已经点名「只改键不改值
会留下自带过期 source 的书签」。依赖 `bookmark.source` 的读取点（含早年那条「扁平数组 → 按
source 分组」的迁移代码）一并处理。

### 5. sidebar 换键并清理旧键

四处键站点改用 scope。展开状态**不迁移**（低价值、可再生的 UI 状态，重新展开一次就回来），但
**清掉旧键** —— 否则 `UserDefaults` 里会永久留着一堆再也读不到的条目，那正是 `PR106.10` 当初
要防的累积。

### 6. 迁移

一次性、尽力而为，沿用现有 `bookmarkMigrationCompleted` 那套开关：

- 非 Bonjour 的源：1:1 映射。
- Bonjour 的源：deviceID 从 `Identifier` 前缀取，processName 从磁盘键里那个 `name` 字段取 ——
  **但只在 `name` 形如「设备名 (进程名)」时才解析**，否则当作无法迁移，丢弃并记日志。
- 丢弃的条目**只记日志，不打扰用户**：旧文件本来就保留不删，事后可查可救；启动时弹窗说「几条
  书签没迁过来」对用户没有可操作性，只是制造焦虑。
- 迁移代码**永久保留**，沿用项目现有做法（早年那次迁移至今仍在，带 `@available(deprecated)` 标记）。

### 与 UDID 隐私提案的交互

`PR106.14` 已把「UDID 出现在 mDNS 与约 40 个 `.public` 日志点」推给一个独立的隐私提案，其结论是
替换成**固定盐**的哈希（非固定盐会把一个模拟器再拆成每个注入进程一个 section）。

那个提案若落地，`deviceID` 的取值会变 —— 也就是本提案的 scope 落盘键会**再变一次**。所以落盘
格式**现在就带版本号前缀**：届时能做一次有据可依的迁移，而不是又一次静默失效。这是本提案唯一
为将来预留的东西，其余一律不做前瞻设计。

## 替代方案考量

**改用 `source.identifier` 作 autosave 键 —— 否决，且比原问题更糟。**
这是最容易想到的修法，甚至有注释背书（`RuntimeSource.identifier` 的注释就说「用 identifier，
永远别用 name」）。但 Bonjour client 的 identifier 是 `bonjour.{deviceID}-{pid}`，**pid 每次启动
都变**。照此修等于把 `PR106.10` 刚刚修掉的「对端每次启动换一套 autosave 键、在 `UserDefaults`
里永久累积」原样搬到 sidebar 上。
这条一度已经作为建议发出去过，是第二份独立复核拦下来的 —— 记在这里，因为它说明**对修法的复核
和对发现的复核同等重要**。

**给 `RuntimeSource.bonjour` 加结构化字段 —— 否决。**
概念上最干净（身份集中在一处），一度也是选定方案，直到查出 `RuntimeSource` 会跟着
`RuntimeRemoteEngineDescriptor` 在对端之间互推。加关联值会改变编码形状，而 iOS 端有外部用户、
混版是常态。手写向后兼容的 `init(from:)` 可以解决，但那段回退解析正是本提案要消灭的东西，为了
兼容把它写进来并长期保留，得不偿失。

**scope 只到设备级 —— 否决。** 最稳、永不失效，但同一设备上多个注入进程的书签会互相串，而多进程
注入正是 0013 存在的理由。

**scope 用不透明哈希 —— 否决。** 落盘不含设备名与 UDID，天然对齐隐私方向。但排查时完全看不出
一份书签属于谁，且哈希算法日后要改就没有迁移路径 —— 从哈希还原不回原值。可读 + 版本号在同样的
场景下更可控。

**继续用 `@FileStorage`，容错写进 `Codable` —— 否决。** 机制统一、改动小，但「整份文件读不动时
坡坐备份」做不到 —— 异常在 `@FileStorage` 里就被吞了，拿不到原文件也无从备份，只能做到一半。

**去上游改 `RxSwiftPlus` 的 `FileStorage` —— 否决。** 所有用它的地方都受益，但本提案的时间线会
被外部依赖卡住。

**迁移时无条件使用磁盘上的 `name` —— 否决。** 能救回最多书签，但 `name` 的语义跨版本变过（基线
是设备名、0013 之后是进程名），无条件当进程名用会把书签归到一个不存在的 scope —— 看上去迁移
成功了，实际上永远读不到。只解析认得出格式的，宁可丢也不误归类。

**把 `deduplicateForwardedMirrors` 一并纳入 —— 否决，单独记账。**
它同样用 `source.description` 做身份，但注释明写 "same display name"，是**有意**按显示名设计的，
改它属于改变既有设计意图，与本提案「把持久化键从显示名换成稳定身份」不是同一件事 —— 去重结果
不落盘，误判只影响当次会话。而且它在 `main` 上就存在，不是 0013 引入的。已登记在
`2026-08-27-pr106-cross-review-findings.md` 的 `PR106X.1` 横向排查里。

## 影响

**项目型别：App（macOS，AppKit）。** 不涉及 ABI。

### 用户可见变化

- 收藏（书签）在对端重启后**仍然在**。这是修复，不是新功能 —— 用户今天遇到的是「昨天收藏的东西
  今天没了」。
- 升级后**首次启动时 sidebar 的展开状态会重置一次**，之后恢复正常。属于一次性代价。
- 少数旧书签可能迁移不过来（`name` 认不出格式的），只写日志、不提示；旧文件保留，事后可救。

### 数据与配置兼容

- 书签落盘格式**变更**：键值交替数组 → 以 scope 字符串为键的 JSON 对象；值删掉 `source` 字段。
- 旧文件保留不删，迁移一次性执行、由 UserDefaults 开关控制。
- `UserDefaults` 里旧的 `NSOutlineView` autosave 键会被主动清理。

### 跨版本互通

- `RuntimeRemoteEngineDescriptor` 新增一个 `@Default` 字段：新对端能读旧对端（字段为空、回退），
  旧对端能读新对端（多一个它不认识的键，MetaCodable 忽略）。**双向兼容，不需要同版本。**
- `RuntimeSource` 的编码形状不变。

### 平台与最低版本

无变化。

### 发布影响

无需特殊发布步骤。建议合入后手工验证一次「连上 iOS 对端 → 收藏 → 重启对端 → 收藏还在」。

## 落地步骤

**前置**：等 0013 的 PR #106 合入 `next`。本提案的身份构成建立在它把 deviceID 与 processName
放进 TXT 记录的改造之上，而那个 PR 仍在审查中、仍在变（两轮共 24 条发现，第二轮又改了五处），
并行开工只会反复 rebase。

拆成三个 PR，每个能独立审查、独立回滚：

**PR ① 身份层**
- 新增 `RuntimeBookmarkScope`（`RuntimeViewerCommunication`）及其可读带版本号的字符串表示。
- `RuntimeRemoteEngineDescriptor` 新增 `@Default` 结构化身份字段。
- `RuntimeEngine` 持有 scope；`RuntimeEngineManager` 在两条创建路径（endpoint / descriptor）注入。
- 旧对端的回退解析 + 日志。
- 测试：scope 构成与字符串往返、旧对端回退、混版双向解码。

**PR ② 存储与书签**（依赖 ①）
- 自写存储薄封装：逐条容错、坡坐备份、诊断日志。
- 书签字典换键、删 `source` 字段、迁移 + 开关。
- 测试：迁移（手写 fixture 覆盖已知历史形状，**不使用真实用户文件**）、坏条目跳过、整份损坏时备份、
  `name` 认不出格式时丢弃。

**PR ③ sidebar 键**（依赖 ①，不依赖 ②）
- 四处键站点换 scope。
- 旧 autosave 键清理。
- 测试：两个同名进程得到不同的键；清理只命中本项目前缀。

## 决策日志

本提案动笔前做了五轮澄清提问，逐轮结论如下。**被否掉的方向记在「替代方案考量」里，这里只记
决定本身与它解锁了什么。**

### 第一轮

1. **scope 身份构成**：设备 ID + 进程名。理由：两者都已在 TXT 里，不改广播协议，旧对端也有。
   接受「同设备两个同名进程共享书签」这个代价。
2. **迁移策略**：一次性尽力迁移，沿用现有开关与 deprecated 保留的做法。
3. **提案范围**：书签 + sidebar autosave 键**一起改**。两者是同一个问题的两面，分开做等于把同
   一套取舍吵两遍。
4. **`@FileStorage` 缺陷**：在本项目侧修，换掉落盘表示。

### 第二轮

5. **非 Bonjour 源**：各用自己已有的稳定标识，不硬凑统一形状。`directTCP` 的对端根本没有设备 ID。
6. **迁移数据源**：用磁盘键里的 `name`，但**只解析认得出格式的**。
7. **展开状态**：不迁移，但清掉旧键。
8. **读失败行为**：能读多少读多少 + 整份读不动时坡坐备份。

### 第三轮

9. **落盘格式**：可读 + 带格式版本号。版本号是为 `PR106.14` 的 UDID 隐私提案预留的迁移抓手。
10. **书签结构体的 `source` 字段**：删掉。字典键已经表达归属。
11. **交付时机**：等 PR #106 合入 `next` 再开。
12. **`deduplicateForwardedMirrors`**：不纳入，单独记账（它是有意按显示名设计的）。

### 第四轮

13. **身份来源**：给 `RuntimeSource` 加结构化字段。
14. **role**：进 scope，保持现有语义。
15. **存储层**：自写薄封装（`@FileStorage` 吞异常，做不到坡坐备份）。
16. **迁移丢弃的告知**：只记日志。

### 第五轮 —— 推翻了 13

**第四轮的 13 是在一个没查清的前提下做的决定。** 提问时我以为改 `RuntimeSource` 的代价只是
「构造点要改、落盘格式变」，实际上它跟着 `RuntimeRemoteEngineDescriptor` 走线，混版时旧对端
解不了。查清后重定：

17. **跨版本兼容**：**不动 `RuntimeSource`**，在 descriptor 上并行加 `@Default` 字段。这**取代了
    第四轮的 13**。
18. **PR 切分**：三个。
19. **迁移代码寿命**：永久保留。

### 第六轮（未提问，按推荐默认执行）

用户在第六轮提问前指示「其余按默认走」。以下三项按推荐值定，**落地时若发现代价与判断不符，
应回来修订本节而不是默默改实现**：

20. **scope 运行时挂在哪**：挂在 `RuntimeEngine` 上，由创建方注入。理由：sidebar 与书签的读取点
    都已经能拿到 `runtimeEngine`，不需要新的传递通道。
21. **旧对端缺字段时的回退**：尽力从 `name` / `Identifier` 解析；解析不出形状时退回今天的行为
    （用现有 identifier 字符串作为 legacy scope）并记日志。验收标准是**不比现状更差**。
22. **迁移测试的 fixture**：手写，覆盖已知的历史形状；不使用真实用户文件（避免把设备名与 UDID
    写进仓库，也避免测试依赖某台机器的磁盘状态）。

### 尚未决定

- 旧 autosave 键的**清理时机**（启动时扫一次 vs 迁移时一并做）—— 实现时按简单者取，两种都不改变
  外部行为。
- `PR106.14` 的 UDID 隐私提案落地后，版本号从 `v1` 到 `v2` 的具体迁移规则 —— 等那个提案定稿。
