# Draft - RuntimeBookmarkScope：把持久化身份从显示名手里拿走

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-08-27
- **最后更新**: 2026-08-28
- **所属愿景**: 无
- **关联提案**: [0013](0013-inject-ios-simulator-process.md)（本提案处理它暴露出的持久化身份问题）
- **实现分支 / PR**: `feature/runtime-bookmark-scope`（从 `feature/inject-ios-simulator-process` 分出）
- **配套文档**: [`CommunicationAndEngineArchitecture.md`](../CommunicationAndEngineArchitecture.md) §2.3 的注与 `buildEngineDescriptors` 字段表（同批次更新）

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

> 已核实（2026-08-28，`git show 917002cc`）：commit body 原文为 *"Also includes: use stable
> DeviceIdentifier for Bonjour endpoint identity, custom Equatable/Hashable for RuntimeSource
> (name-independent matching)"*。`2026-08-24-pr106-review-findings.md` 引的片段与正文**逐字一致**，
> 只是做了截取并加着重号。「引的不是原文」的说法不成立，争议关闭。

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

~~放在 `RuntimeViewerCommunication`（`RuntimeSource` 所在模块），这样 `RuntimeViewerCore` 的书签
类型与 AppKit 应用侧的 autosave 键都能拿到。~~ **改放 `RuntimeViewerCore`，见「实现期修正」第 33 条。**

身份构成按来源分别取**各自已有的稳定标识**，而不是硬凑成统一形状：

| 来源 | scope 构成 |
|---|---|
| `.local` | 固定字面量 `local` |
| `.remote`（XPC） | 已有的 `Identifier`（如 `com.RuntimeViewer.RuntimeSource.MacCatalyst`，本来就稳定） |
| `.localSocket` | 已有的 `Identifier` |
| `.directTCP` | port + host（顺序见下 —— host 可以是含 `:` 的 IPv6 字面量） |
| `.bonjour` | **deviceID + processName** |

`role`（client / server）**进 scope**，`.directTCP` 也包括在内（今天 `RuntimeSource.==` 对它比较
的正是 host + port + role）。理由是与现有相等性语义一致，非 Bonjour 的旧键因此能 1:1 映射。

> **但 role 进 scope 并不能免掉合并规则。** 起草时曾这样论证，那是错的：磁盘上按 pid 累积的死
> 记录，deviceID、processName、role 全都相同、只有 pid 不同，会全部映射到同一个新 scope。role
> 挡掉的只是 client / server 合并那一种。合并规则见「6. 迁移」。

**落盘表示是可读的、带格式版本号的字符串。** 格式与解析规则必须一次定死，因为它**需要被反向
解析**——本提案自己预留的 v1 → v2 迁移（UDID 哈希化）就要从 v1 字符串里取出 deviceID 段再哈希：

- 段以 `:` 分隔，段序固定为 `<版本>:<种类>:<role>:<其余>`。
- 前三段保证不含 `:`（都是本项目定义的字面量集合）。
- **「其余」由每个种类自己定义，且除最后一个子段外都保证不含 `:`；最后一个子段吞掉剩余全部内容**，
  不再继续切分。于是无需任何转义：
  - `.bonjour` → `<deviceID>:<processName>`。deviceID 是 UUID 形状、不含 `:`；`processName` 落在
    吞尾段，可以含 `:`、空格与非 ASCII。
  - `.directTCP` → `<port>:<host>`。**port 在前**是为了让可能含 `:` 的 IPv6 host 落到吞尾段；
    port 是纯数字，无歧义。
  - `.remote` / `.localSocket` → 已有的 `Identifier`，整体落在吞尾段。
  - `.local` → 空。
- 反向解析保证能取出前三段与「其余」，以及「其余」的第一个子段。v1 → v2 只需要动 `.bonjour` 的
  deviceID，它正是那个第一子段。

### 2. 身份怎么到达 scope —— 不动 `RuntimeSource`

`RuntimeSource` 的 case 签名**保持不变**。结构化身份改为在 `RuntimeRemoteEngineDescriptor` 上
并行新增一个字段，照抄 `hostID` 的模式用 `@Default` 标注，旧对端缺字段即为空、接收方回退。

运行时 scope 挂在 `RuntimeEngine` 上（由创建方注入）：

- **本机直连的 Bonjour client**：`RuntimeEngineManager` 从 `RuntimeNetworkEndpoint` 现成的
  `deviceID` / `processName` 字段构造，engine 创建时一并传入。
- **镜像引擎**：从 descriptor 的新字段构造。
- **旧对端的镜像引擎**（descriptor 缺字段）：先试着从 `name` 解析「设备名 (进程名)」形状；解析
  不出时落到 legacy scope，**且两个消费点的 legacy 取值必须分别定义**——起草时笼统写成「退回
  今天的行为（用现有 identifier 字符串）」，括号内外说的其实是两件事：
  - **书签**用 `source.identifier`。它今天就是书签键的来源，取值不变即行为不变。
  - **sidebar autosave 键**用 `source.description`（显示名）。**绝不能用 `source.identifier`**
    ——0013 之后 Bonjour client 的 identifier 含 pid，那样等于把 `PR106.10` 刚修掉的「每次启动换
    一套键并永久累积」搬进 sidebar，正是「替代方案考量」里痛斥的那个错误修法。
  - 验收标准「不比现状更差」按上面两条**逐个消费点**判定，不是笼统一句。

这样 sidebar 与书签的读取点都改为读 `runtimeEngine.bookmarkScope`，不再碰 `source.description`。

**已知并接受的缺口：跨主机镜像的非 Bonjour 引擎会撞 scope。** `.remote` / `.localSocket` 的 scope
取「已有的 `Identifier`」，而那是每台机器上都相同的常量（如
`com.RuntimeViewer.RuntimeSource.MacCatalyst`）。A、B 两台 Mac 的 Catalyst 引擎镜像到同一个宿主时
会落进同一个 scope，书签与展开状态互串。

**现状（用 `RuntimeSource` 做键）就已经这样，不是本提案引入的。** descriptor 上现成的 `hostID` 能
给镜像引擎的 scope 补一个 origin host 维度来根治，但那需要先为「同一个引擎，直连时与被镜像时」
定义 scope 是否相同——不同则跨主机看同一台机器会看到两份书签。那是一个独立的取舍，不塞进本提案。
**记账，不默默略过。**

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
- **合并规则（必须有，不是边界情况）**：多条旧键落进同一个新 scope 是**常态**而非例外——按 pid
  累积的死记录（`PR106.1` 点名的那种，`next` 上的用户磁盘就有）deviceID、processName、role 全都
  相同，只有 pid 不同。规则定为：**按旧键在磁盘上的出现顺序取并集，逐项去重**（用书签自身的相等性
  判定），先出现的排在前。不做「保留最新一条」之类的裁决——磁盘上没有时间戳，无从判断新旧。
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

**给 `RuntimeSource.bonjour` 加结构化字段 —— 否决，但理由不是兼容性。**

概念上最干净（身份集中在一处），一度也是选定方案。

> **起草时给的否决理由是错的，原样留在这里作为记录。** 当时写的是：`RuntimeSource` 跟着
> `RuntimeRemoteEngineDescriptor` 在对端之间互推，加关联值会改变编码形状、**混版时旧对端解不了**。
> 走线这个事实成立，推论不成立——复核做了空白实验（合成 `Codable` 的 enum，给 case 加两个
> Optional 关联值，模拟新旧两版互解）：新版解旧数据，缺失键得到 `nil`，成功；旧版解新数据，多余
> 键被忽略，成功。**加 Optional 关联值是双向兼容的，且不需要手写 `init(from:)`**；`RuntimeSource`
> 是纯合成 `Codable`（全仓库无手写 `init(from:)`），实验适用。当时甚至把风险方向说反了——keyed
> container 忽略多余键在任何版本都成立，有风险的方向本来是「新解旧」，而 Optional 正好化解了它。

**真正的否决理由是相等性两难。** `RuntimeSource` 同时是书签字典的键，它的 `==` / `hash` 是手写的：

- 新字段**不进**相等性：身份仍然要从别处比较，字段只是搭个便车，什么也没解决。
- 新字段**进**相等性：磁盘上的旧键解码后新字段为 `nil`，与运行时构造的新键不相等——**又一轮全量
  书签失效，正好重演本提案要修的那个事故**。

descriptor 方案没有这个两难。次要成本：`.bonjour(` 的构造与匹配点全仓库 25 处，而 enum case 不支持
默认参数，全都要跟着改。

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

拆成三个 PR，每个能独立审查、独立回滚。**中间态是安全的**：PR ① 合入后没有任何消费点读新字段，
行为与合入前相同；② 与 ③ 互不依赖，任一个先合都不会让书签或 sidebar 处于半坏状态。

**PR ① 身份层**
- 新增 `RuntimeBookmarkScope`（`RuntimeViewerCommunication`）及其可读带版本号的字符串表示。
- `RuntimeRemoteEngineDescriptor` 新增 `@Default` 结构化身份字段。
- `RuntimeEngine` 持有 scope；`RuntimeEngineManager` 在两条创建路径（endpoint / descriptor）注入。
- 旧对端的回退解析 + 日志。
- 测试：scope 构成与字符串往返（含 `processName` 带 `:` / 空格 / 非 ASCII、`.directTCP` 的 IPv6
  host）、旧对端回退**按消费点分别验证**、混版双向解码。
- **混版双向解码不需要第二台设备**，不要把它写成需要真机的验收条件：新解旧用手写的旧形状 JSON
  fixture，旧解新在测试里冻结一份 V1 镜像类型去解新编码。几十行即可，复核已用这个做法跑通。写不成
  这样，它就容易退化成「同一套类型自编自解」的同义反复。

**PR ② 存储与书签**（依赖 ①）
- 自写存储薄封装：逐条容错、坡坐备份、诊断日志。
- 书签字典换键、删 `source` 字段、迁移 + 开关。
- 测试：迁移（手写 fixture 覆盖已知历史形状，**不使用真实用户文件**）、坏条目跳过、整份损坏时备份、
  `name` 认不出格式时丢弃。

**PR ③ sidebar 键**（依赖 ①，不依赖 ②）
- 四处键站点换 scope。
- 旧 autosave 键清理。
- 测试：**不同设备上的**同名进程得到不同的键（同一设备上同名进程共享 scope 是本提案显式接受的
  代价，别把它当 bug 测）；清理只命中本项目前缀。

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
21. **旧对端缺字段时的回退**：尽力从 `name` 解析；解析不出形状时落到 legacy scope 并记日志。
    ~~验收标准是不比现状更差。~~ **本条在起草后的复核中被指出含糊并已改写**——见「2. 身份怎么
    到达 scope」，legacy 取值现在按消费点分别定义（书签用 `identifier`，sidebar 用 `description`），
    因为笼统那句的一种读法正好是本提案痛斥的错误修法。
22. **迁移测试的 fixture**：手写，覆盖已知的历史形状；不使用真实用户文件（避免把设备名与 UDID
    写进仓库，也避免测试依赖某台机器的磁盘状态）。

### 起草后的复核修正（2026-08-28）

草稿完成后交给同项目的另一个会话做只读复核，**它推翻了本提案的一处核心论证**，另有四处补正。
按「提案是决策快照、不回头修改让它符合实现」的约定，被推翻的原文保留在原处并标注，这里只记修正
本身：

23. **第五轮的选型依据（17）被实测证伪。** 「给 `RuntimeSource` 加字段会破坏混版兼容」不成立：
    加 Optional 关联值对合成 `Codable` 是双向兼容的。**结论（不动 `RuntimeSource`）保持不变，
    但换成一个更硬的理由——相等性两难**，详见「替代方案考量」。这条错误理由如果留着，会传播
    「加字段必破兼容」这个错误知识。
24. **「role 进 scope 就不必定义合并规则」的论证是错的。** 按 pid 累积的死记录会全部落进同一个新
    scope，合并是常态。已在「6. 迁移」补上并集去重的规则。
25. **落盘字符串格式补齐了解析规则。** 原稿只给了一个例子就往下走，漏了两件事：`.directTCP` 的
    host 可以是含 `:` 的 IPv6 字面量；以及本提案自己预留的 v1 → v2 迁移**需要反向解析**。已定死
    段序与「末段吞尾」规则。
26. **回退语义的歧义已消除**，见修正后的 21。
27. **新记一个已知缺口**：跨主机镜像的非 Bonjour 引擎会撞 scope（两台 Mac 的 Catalyst 引擎落进同
    一个常量 `Identifier`）。现状就已如此、非本提案引入，显式声明本轮不处理并写明根治方向。

另外复核替本提案关掉了一处「待核实」（`917002cc` 的引文之争，见「动机」一节），并指出
「混版双向解码」不需要第二台设备即可测——已写进落地步骤。

### 实现期修正（2026-08-28）

实现过程中发现两处原文与代码事实不符。按「提案是决策快照、被推翻的原文保留在原处」的约定，
原文不动，修正记在这里：

28. **迁移与回退的判据被改写了。** 原文（「6. 迁移」）说 Bonjour 的旧键「只在 `name` 形如
    『设备名 (进程名)』时才解析，否则当作无法迁移」。照此执行**一条 Bonjour 书签都迁不过来**：
    - 0013 之后写的键，`name` 是 `endpoint.processName ?? endpoint.name`，绝大多数情况就是**纯
      进程名**，不含括号 —— 会被这条规则全部丢弃，而这批恰恰是唯一能从 identifier 里取出
      deviceID 的、唯一迁得动的。
    - 0013 之前写的键，`name` 确实是「设备名 (进程名)」，但 identifier 是服务名，取不出
      deviceID，本来就迁不了。

    改为：**唯一的闸门是 identifier 能否被解析成 `{deviceID}-{processIdentifier}`**（那是构造
    scope 的硬前提，没有 deviceID 就没有 scope）。闸门一开就已经锁定了 `name` 的语义 —— 这种
    形状的 identifier 只可能是 0013 之后写的，此时 `name` 与运行时构造引擎用的是同一个字符串
    —— 所以 `name` **原样使用，不解析括号**。这既不是被否决的「无条件使用 `name`」（有闸门），
    也去掉了原规则里那个会误归类的解析步骤。

    落地为 `RuntimeBookmarkScope.recovered(from:)` 一个函数，迁移与旧对端回退共用，两者不可能
    再分叉。测试 `directConstructionAgreesWithRecovery` 把「直连构造出的 scope == 从同一对端的
    source 恢复出的 scope」钉成不变量。

    附带加固：identifier 尾段不只要求「全是数字」，还要求它是一个正 `Int32` 的精确十进制写法。
    UUID 的最后一组是 12 位十六进制，约每 200 个里有一个碰巧全是数字，只按「全数字」切会把
    deviceID 悄悄截短。这条是测试先失败才发现的，不是推理出来的。

29. **新记一个已知缺口：注入本机 App 的引擎，scope 同样每次失效。** 原文（「1.
    `RuntimeBookmarkScope`」）说 `.remote`（XPC）的 `Identifier`「本来就稳定」，举的例子是
    `com.RuntimeViewer.RuntimeSource.MacCatalyst`。对**注入**产生的引擎不成立：
    `RuntimeEngineManager` 用进程号当 identifier（`.remote(identifier: "\(pid)")` 与
    `.localSocket(identifier: "\(pid)")`），所以注入同一个 App 两次就是两个 scope，与本提案要修
    的 Bonjour 缺陷是同一个病。

    **本轮不处理**，理由与「跨主机镜像撞 scope」相同：现状就已如此、非本提案引入，且根治需要先
    为本机进程定义一个稳定身份（bundle identifier 是显然的候选，但那要改注入侧的记账格式，是独立
    取舍）。记账，不默默略过。

30. **旧 autosave 键的清理时机定为「迁移时一并做」。**「尚未决定」里留的两个选项，按「取简单者」
    选了后者：`SidebarAutosaveKeyCleanup` 由 `AppDefaults` 的迁移序列在第一次解析该依赖时跑一次，
    带自己的 `UserDefaults` 开关。时序上够早——sidebar 的 ViewModel 在构造时就取
    `@Dependency(\.appDefaults)`，早于任何 `NSOutlineView` 写入新键。

    清理判据是「键里同时含 `com.JH.RuntimeViewer.` 与 `.autosaveName.`」，因为 AppKit 会把我们给的
    名字包一层（列宽是 `NSTableView Columns <name>`，展开状态是 `NSOutlineView Items <name>`），
    单纯的前缀匹配一个都命中不了。

    **它必须只跑一次，不能做成每次启动都扫。** 落到 legacy scope 的对端会持续用显示名当键写入，
    那是当前状态而非残留；反复清扫等于每次启动都删掉活数据。

31. **架构文档同批次更新**：`CommunicationAndEngineArchitecture.md` 新增一节说明「连接身份 vs
    落盘身份」，并在 `buildEngineDescriptors` 的字段清单里补上那个身份字段（当时叫
    `bookmarkScopeIdentity`，第 34 条改名为 `stableIdentity`）与它的
    双向兼容性。不另写实现说明——本提案已经涵盖取舍，再开一份只会分散权威来源。

32. **不新建术语表。** 按 evolution 流程要求显式裁决：本轮唯一的新术语是 `RuntimeBookmarkScope`，
    它在架构文档 §2.3 的注里已有完整定义、在本提案有完整取舍，项目至今没有 `Glossary.md`。为一个条目
    新开一份术语表只是多一个要维护的索引，权威来源反而分散。**下次再引入跨文档复用的术语时再建。**

33. **模块归属从 `RuntimeViewerCommunication` 改到 `RuntimeViewerCore`。** 原文给的理由是「放
    `RuntimeSource` 所在模块，两边都能拿到」——查过依赖图后这个理由不成立：`RuntimeViewerPackages`
    里**每一个**依赖 `RuntimeViewerCommunication` 的 target（`RuntimeViewerService`、
    `RuntimeViewerHelperClient`、`RuntimeViewerCatalystExtensions`）都同时依赖 `RuntimeViewerCore`，
    所以放 Core 一样人人拿得到。

    理由换成职责：`RuntimeViewerCommunication` 是连接层，**不该知道「书签」这回事**。scope 由
    source 派生，但它本质是应用层的持久化键，和 `RuntimeImageBookmark` / `RuntimeObjectBookmark`
    以及持有它的 `RuntimeEngine` 同属 Core。文件因此落在 `RuntimeViewerCore/Common/`，与书签模型
    并列，测试一并从 `RuntimeViewerCommunicationTests` 移到 `RuntimeViewerCoreTests`。

    唯一被牵动的是 `RuntimeRemoteEngineDescriptor`：字段留在 Communication（它只是个不透明字符串，
    无类型依赖），把它解回 scope 的那个计算属性搬到 Core。

    > ~~**字段名保留 `bookmarkScopeIdentity`，不改。** 它确实把「书签」这个词留在了通信层，但
    > descriptor 早就不是纯连接类型——`iconData` 是 App 图标 PNG，`originChain` 是环检测——为一个词
    > 改走线 key 不划算。~~ **这条判断被推翻了，见第 34 条**：「别的地方也漏了」不是继续漏的理由。

34. **把「应用层概念」彻底赶出连接层**——第 33 条只做了一半，本条补完。三处改动，判据都是同一条：
    `RuntimeViewerCommunication` 只该知道连接、source 与消息通道。

    - **字段 `bookmarkScopeIdentity` 更名为 `stableIdentity`**（走线 key 同步改）。原本以「descriptor
      早就不纯了」为由留着，但那是「别处也漏了」，不是继续漏的理由。新名字描述的是它对连接层而言
      的全部含义：一个跨对端重启稳定、**本层不解析**的不透明串。它与 `engineID` 的区别也因此说得清了
      ——后者是每会话的路由地址，内嵌 `source.identifier`，Bonjour 对端重启就变。
    - **`RuntimeRemoteEngineDescriptor` 整体移到 `RuntimeViewerCore`。** 连接层里对它的引用只有它
      自己的定义文件，**内部零使用**；而「engine」根本不是这一层的概念。测试里的
      `@Suite("RuntimeRemoteEngineDescriptor")` 一并从 `RuntimeViewerCommunicationTests` 拆到
      `RuntimeViewerCoreTests`，同文件里测 `RuntimeDeviceMetadata` / `RuntimeHostInfo` 的部分留下。
    - ~~**`SandboxProbe` 拆成两半。** 通用探测器（`isMachLookupBlocked(pid:globalName:)`，服务名是
      **参数**，自己不认识任何名字）移到 `RuntimeViewerUtilities`；绑定本项目服务名的那个便利方法
      作为 4 行 extension 留在 Communication。**不整块移走**：它回答的「用 XPC 还是 localhost
      socket」正是连接层的选型问题，整块搬走等于把传输选型反向泄漏进工具层或 Core。~~
      **只移一半的做法被推翻了，见第 35 条。**

    落地代价：`RuntimeViewerUtilities` 新增对 `RuntimeViewerCoreObjC` 的依赖（探测走
    `RVSandboxCheckGlobalName`）。另外 Utilities **没有**开 `.internalImportsByDefault`，所以
    `SandboxProbe` 里那句「签名用 `Int32` 是因为 `pid_t` 不够可见」在新位置已不成立，注释改写为
    真实理由。

35. **`SandboxProbe` 整块移到 `RuntimeViewerUtilities`，连接层不再留残余。** 第 34 条留了一个
    绑定服务名的 extension 在 Communication，被否掉了。

    **不是把便利方法搬过去**——那会把连接层身份倒灌进工具层。`RuntimeViewerMachServiceName` 在
    DEBUG 下不是常量而是依赖 `runtimeViewerIsARM64EVariant` 的计算属性，和 Debug-arm64e 变体的
    helper daemon 身份绑在一起，XPC 连接直接用它。工具层没有理由知道这一整套。

    做法是**删掉便利方法**，两个调用点（`RuntimeViewerServer`、`AttachToProcessViewModel`）显式传
    `globalName: RuntimeViewerMachServiceName`。两处本来就 import 了 Communication，多一个参数换来
    的是：探测器完全通用，服务名归调用方所有。

36. **`RuntimeViewerCoreObjC` 更名为 `RuntimeViewerObjC`。** 这是在纠正一处既有的不一致——该 target
    的 `.h` / `.m` 文件头注释里写的本来就是 `RuntimeViewerObjC`，只有 target 名和文件名带着 `Core`。
    SPM 的 C target 要求 umbrella header 与 target 同名，所以目录、`.h`、`.m` 一起改。

    顺带清掉一条依赖：`RuntimeViewerCommunication` 对该 target 的依赖只服务于 `SandboxProbe`，
    第 35 条把它移走后已经没有使用者，一并删除。

### 尚未决定

- `PR106.14` 的 UDID 隐私提案落地后，版本号从 `v1` 到 `v2` 的具体迁移规则 —— 等那个提案定稿。
- 注入本机 App 的引擎用进程号做 identifier（见「实现期修正」第 29 条）—— 需要先定一个稳定的本机
  进程身份，本提案不做。
- 跨主机镜像的非 Bonjour 引擎撞 scope（见「2. 身份怎么到达 scope」的已知缺口）—— 需要先决定
  「同一个引擎，直连时与被镜像时」是否算同一个 scope，本提案不做。
