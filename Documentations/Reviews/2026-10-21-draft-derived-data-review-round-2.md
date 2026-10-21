---
reviewed_file: Documentations/Evolutions/draft-derived-data.md
reviewed_at: 2026-10-21
reviewer_model: claude-opus-5-5
doc_type: evolution
extra_instructions: 第二轮对抗审查，针对按第一轮意见修订后的版本。用户要求做第二轮、有问题直接修、修完提交推送。四位审查者并行（xhigh），侧重与第一轮相同（缓存键与失效、架构集成、性能论断与证据、范围与验收），除了找新问题，还逐条核对第一轮是否闭环；本文件是四份报告去重合并的结果
critical_count: 1
should_fix_count: 17
suggestion_count: 13
---

## 📄 文档信息

- **路径**: `Documentations/Evolutions/draft-derived-data.md`（审查的是第一次修订稿，660 行；第一轮报告见 [2026-10-21-draft-derived-data-review.md](2026-10-21-draft-derived-data-review.md)）
- **类型**: evolution
- **文档行数**: 660
- **审查日期**: 2026-10-21

本报告由四份报告合并而成。每条末尾的「审查者」注明是哪几位独立报告了它：
- 键：缓存键与失效。
- 集成：架构与规则集成。
- 性能：性能论断与证据。
- 范围：范围、目标与验收。

用户要求有问题直接修，所以每条另附「处理」一行，说明修订后的提案怎么处理了它。

合并时主 agent 亲自复核了以下几条：
- **Transformer 摘要（属实）**：用户的 Release 与 Debug 两份设置里，C 类型替换都存成键、值交替的列表，同样 11 对，顺序不同；`Pattern` 没有遵循 `CodingKeyRepresentable`。
- **另外三条（属实）**：语料与建 section 的 CPU 数字（`ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md:75-76`），带滑动指针的打印位置，内容区只跟随对象、生成选项与 Transformer 取接口。
- **一条没能坐实**：「另一台 Mac 的 Find 会经 App 进程里的 Bonjour 服务端引擎建语料」。那台引擎是 `pushesRuntimeData: false` 的管理用引擎。不过它确实不转发请求，修法不受影响。

### 第一轮闭环情况

第一轮的 16 条 🔴🟡 中，7 条已闭环，8 条部分闭环，1 条未闭环：

| 情况 | 第一轮条目 |
|---|---|
| 已闭环 | 🔴1 恢复挂在批次开始；🔴4 标题承诺；🟡4 设置页层次；🟡7 带滑动的指针；🟡8 元数据与删除；🟡9 读写成本；🟡10 上游键的层级 |
| 部分闭环 | 🔴2 校验与崩溃循环；🔴3 实测归因；🟡1 点开结果的空窗；🟡2 已恢复状态与 Report；🟡3 读取与构建的先后；🟡5 身份与清理；🟡11 验收与身份测试；🟡12 完成点与闸门 |
| 未闭环 | 🟡6 Transformer 摘要（见下面 🔴1） |

部分闭环的部分并入下面的新条目。

---

### 🔴 Critical (1)

**1.** [D 可行性] `line 407–410, 91, 654` — Transformer 摘要的排序键编码对 `replacements` 无效
> 修订稿写「把 `Transformer.Configuration` 用 `JSONEncoder` 加 `.sortedKeys` 编码，取 SHA-256」。但 `replacements: [Pattern: String]` 的键 `Pattern` 是 `String` 原始值的枚举（MachOObjCSection `Transformer+CType.swift:122`），没有遵循 `CodingKeyRepresentable`，标准库把这种字典编码成键、值交替的无键数组，顺序就是本进程里的遍历顺序；`.sortedKeys` 只排有键的容器。用户的两份设置就是证据：同样 11 对，Release 以 `long, NSInteger` 开头，Debug 以 `uint, uint32_t` 开头。设置页三个预设会写入 10、5、11 条（`TransformerSettingsView.swift:188/195/202`）。后果：用过预设的用户每次启动变体名都可能不同，永远读不到，写盘时还删掉上次写的文件；成功标准「第二次启动打印 0」对用户自己的配置必然失败。同一进程里换插入顺序的测试抓不到。
> 审查者：范围、键
> 处理：先按 `Pattern.rawValue` 排序成规范形式再算摘要；测试改为把同样内容、不同数组顺序的两份设置 JSON 解码后比摘要，以用户的 Debug 与 Release 设置为样本。

---

### 🟡 Should Fix (17)

**1.** [D 可行性] `line 435–441` — 「解码中」没有并入 `Build` 与订阅者模型
> 仓库是 actor，解码时一 `await` 就会被重入；现有的不变式是订阅者只在一处结算（`finishBuild`），`cancelBuild` 只在 `builds`、`pendingImagePaths`、`runningBuild` 里找。照字面「出队时跳过」，订阅者永远等不到结果，`hasActiveBuild` 一直为真，App 永远进不了 App Nap；解码途中关掉开关（`evictAll()`），读回的语料还会被塞回仓库。
> 审查者：集成
> 处理：读取成为 `Build` 的第一个阶段，带 identifier，经 `finishBuild` 结算；取消、淘汰都找得到它，读回后先核对 identifier；补上读取途中取消与淘汰的测试。

**2.** [D 可行性] `line 82–84, 402–405, 497` — 读取标记只罩住解码，罩不住使用时的 trap
> 坏的 span 会在之后遍历文本时 trap（`FrozenSemanticString.swift:73-77`，也就是搜索时），而标记是「读完删掉」的。崩溃 → 重连 → 批次重派 → 再读同一个文件（已无标记）→ `FindSession` 自动重跑查询 → 再崩，正是第一轮 🔴2 的循环。另外：清理会删掉超过一天的标记却留下容器；同一构建开两个实例时，会把对方正在读的文件当成坏文件删掉；同一进程里两条路径并发读同一镜像，后到的一方也可能删掉好文件。
> 审查者：键、集成、性能、范围
> 处理：标记记录读者的 PID 与启动时间；读后对每条语料完整遍历一次、按全开与全关各投影一次，都通过才删标记；进程还活着的标记视为别人在读、不删文件；同一进程按镜像合并读取；清理时标记与容器成对删除。

**3.** [D 可行性] `line 211, 637` — 「任何批次开始时提前读取」带来约 35 个镜像，与用户的决定不一致
> 启发式批次（主开关打开时默认开启、深度 1）以服务进程的可执行文件为根，Release 版直接链接 37 个库，几乎都在共享缓存里。每次启动除七个常驻镜像外还要读约 35 份语料，而且读取在存储的 actor 上排队，常驻镜像的读取可能排在后面。决策日志把这称作「细化」，实际是扩大，接近用户否掉的「启动时全部恢复」。批次里 `.failed` 的条目也没排除。
> 审查者：集成、范围
> 处理：提前读取只针对这个 Engine 的 Always Index（各行解析出的镜像，加上 Always Index 批次里 `.pending` 的条目）；`.failed` 不读；其余走构建路径；读取在 actor 外并行。

**4.** [D 可行性] `line 211, 474–476` — 提前读到的语料不会扩进正在显示的搜索
> 正在显示的搜索靠 `corpusBuilt` 扩展（`FindSession.swift:302-306, 731-735`），这个信号只在 `finishBuildRequest` 里发出（`FindCorpusCoordinator.swift:541`）。提前读取直接调命令，修订稿没写更新状态、发信号，屏上的结果要等 section 建好才补上。
> 审查者：集成
> 处理：读到的镜像和构建完成一样置为 `.built(summary)` 并发出 `corpusBuilt`；补测试。

**5.** [D 可行性] `line 213, 479, 562` — 前台加载只修好了内容区
> Inspector 的关系与层级只跟随对象取数据（`InspectorRelationshipsViewModel.swift:65-77`），镜像建好后不会重取；前台加载失败时显示什么没写；「把状态切到加载中」与「一个状态枚举」的规则对不上，`ContentTextViewModel` 现在用同一个 `Observable.async` 上的 `trackActivity(_commonLoading)` 表示加载。
> 审查者：集成
> 处理：前台加载放进同一个取接口的任务，由现有的 `trackActivity` 覆盖，失败按取接口失败处理；Inspector 另外跟随 `imageDidIndexPublisher`，镜像建好时重取。

**6.** [G 代码一致性] `line 98` — 现状描述有两处不实，行号也错
> ObjC 类与协议不返回 `nil`，而是按类名或协议名现建 ObjC section（`RuntimeEngine.swift:770, 772` → `RuntimeObjCSection.swift:485-503`），不经前台加载闸门。「批次结束后重取」不存在：数据变化的订阅在 `RuntimeInterfaceCache.swift:130-139`，只清缓存；内容区只跟随对象、生成选项与 Transformer（`ContentTextViewModel.swift:164-168`），拿到 `nil` 后会一直空着，直到用户重新导航。引用的 `ContentTextViewModel.swift:133` 是一行 `#endif`。
> 审查者：集成、范围
> 处理：前期调研按实际改写；测试改用 Swift 对象覆盖新分支。

**7.** [B 一致性] `line 97, 560` — Call Hierarchy 也从语料找根，找调用者却只扫已索引的镜像
> `FindMode.readsCorpus` 对 `.callHierarchy`、`.callees` 也返回 true，根从语料里找；找调用者的候选镜像只从已索引的镜像里挑（`CrossReferenceQuery.swift:171-190`），根所在的镜像还没索引时，同一镜像里的调用者会被静默漏掉。
> 审查者：集成
> 处理：根所在镜像还没有 section 时先前台加载；写进「用户可见变化」并补测试。

**8.** [B 一致性] `line 182–184, 199–200, 378` — App 进程里不转发请求的引擎也会被启用
> 启用条件只有「所在 App 包是 RuntimeViewer」与「不转发请求的那一端」。App 进程里的 `.bonjour(role: .server)` 引擎（`RuntimeEngineManager.swift:396-398`）不转发请求，收到的命令在 App 进程里执行，按这两条它也会拿到派生数据，与「只在服务进程里读写」相反。
> 审查者：集成
> 处理：改为两个服务入口各调用一次 `RuntimeDerivedData.enableInThisProcess()` 显式开启。

**9.** [G 代码一致性] `line 110, 467, 579, 652` — 合成的 `Codable` 解不了旧对端发来的覆盖情况
> `RuntimeInterfaceCorpusCoverage` 的 `Codable` 是合成的，新增非可选字段会让解码缺键的旧 JSON 抛 `keyNotFound`，而协调器用 `try?` 取覆盖情况，失败被静默吞掉。修订稿一处说「带默认值」，一处说「可选字段」，类型又写成非可选。
> 审查者：集成
> 处理：手写 `init(from:)`，用 `decodeIfPresent(...) ?? [:]`（先例 `RuntimeHostInfo.swift:26`、`RuntimeDeviceMetadata.swift:43-44`）；补解码旧 JSON 的测试。

**10.** [C 歧义] `line 218–220, 466–468, 476–477, 482` — 「已读取」集合的语义与 Report 新组不完整
> 构建路径命中的镜像只在一个 `Set<String>` 里，拿不到读取用时；后台索引默认关闭时，所有读取都走构建路径，新组一行用时也显示不了。Clear History 后，下一次 `refreshCoverage()` 会把清掉的组带回来（现有构建历史正是为此才有 `imagePathsListedInHistory`）。仓库侧集合何时去掉条目没写，重新打印的镜像会同时出现在两组。
> 审查者：范围、集成
> 处理：覆盖情况改带 `restoredImagesByImagePath`（每个镜像的大小与用时），条目与 `corpora` 同进同出；协调器另记 `imagePathsListedAsRestored`。

**11.** [C 歧义] `line 196, 321–329, 377` — 哪些映像算进生产者、什么时候取，没有定义
> 按「存储第一次被用到时已加载的全部映像」理解，经 Load Frameworks… 载入的东西会改变摘要；而 Debug 构建的 service 带一个指向 App 包外构建产物目录的 rpath，日后动态链接包框架时，这部分代码不计入摘要。
> 审查者：键
> 处理：只算含有 RuntimeViewerCore 的映像（本地 service 的可执行文件、Catalyst service 的插件）与它在本进程里加载的非共享缓存依赖，不论在包内还是包外；找不到含有 Core 的映像就不启用。

**12.** [D 可行性] `line 290, 485–486, 496` — 「当前正被使用的目录会保留」没有机制支撑
> 生产者摘要只有服务进程算得出，App 认不出哪个目录正被使用；使用时间每个进程只刷新一次，连续运行超过 14 天的实例会被别的构建清掉；一个 14 天没开过的构建，启动时 App 的清理可能删掉它正要读的目录。
> 审查者：键、性能、集成、范围
> 处理：清理改由服务进程做：第一次用到派生数据时先刷新自己的 `LastUsed`，再清理，并在每次写盘与每 24 小时刷新一次；App 只做统计与手动删除。

**13.** [D 可行性] `line 207, 438, 566` — 「空闲 5 秒后写盘」落在后台档，退出就丢
> 服务进程里没有现成的「空闲」信号（在建的 section 只记在各 factory 的私有状态里）；满足条件时服务没有请求挂着，落在 Darwin 后台档，同样的工作慢 2.5 到 4 倍；短会话退出时没写的部分会丢，下次照旧全部重打；队列持有什么也没写。
> 审查者：性能、集成
> 处理：撤回空闲等待，写盘改为构建的结尾：语料先放进仓库供搜索，再在同一个构建任务里写盘，写完才结算。

**14.** [B 一致性] `line 25, 535, 561` — 「section 是启动时 CPU 的大头」与实测相反，交叉引用也被算了进去
> AppKit（Debug 探针）加载与索引 27.96 秒墙钟、27.92 秒 CPU，语料 12.71 秒墙钟、39.90 秒 CPU；SwiftUI 语料在 Release、并发 4 路时 6.7 秒墙钟、22 秒 CPU。修订稿只抄了墙钟时间，把第一期省下的 CPU 说小了。摘要还说交叉引用表是大头，而它在 Release 下只要零点几秒、决定只放内存。
> 审查者：性能、范围
> 处理：「代价」改成带 CPU 列的表，摘要与「用户可见变化」写明语料打印的 CPU 至少与建 section 相当、Release 下的比例没有直接测过；交叉引用改为「便宜、只放内存」。

**15.** [F 可测试性] `line 223–234, 604, 610` — 成功标准测不了：七个镜像分属两个 Engine，起止点与读数没写
> 用户设置里 UIKitCore、UIKitMacHelper 只作用于 Mac Catalyst 引擎，其余五个只作用于 My Mac；语料协调器与 Report 都按 Engine 分，一个文档里看不到七个。起点前后两处说法不一，「冷启动」没定义，没有 signpost 或日志可读；单镜像用时在两步各量一次、口径不明；首轮写盘什么时候完成看不见。
> 审查者：范围、性能
> 处理：两个 Engine 各测一次；起点是 Always Index 派发、开始提前读取，终点是最后一个镜像可搜，用 `#signpostInterval` 与汇总日志读数；冷启动指重新启动 App、不清文件系统缓存；构建在写盘之后才结束，Report 显示完成即已写盘。

**16.** [E 范围] `line 27, 236–238, 596, 616` — App 进程内的测量是不是本提案的收尾条件，没说清
> 它既是「上游的索引加速」的第一步，又是本提案落地第 1 步，而第 7 步之后才置为 Implemented。
> 审查者：范围
> 处理：测量只属于上游那条线，从本提案的落地步骤里移出。

**17.** [F 可测试性] `line 329, 377–378, 513, 518, 523–529` — 测试要用的注入点在设计里没有
> 生产者摘要只有读当前进程的入口，测试里换不了 UUID；存储是按进程的 `fileprivate static let`，引擎自己 `lazy` 建语料仓库，`RuntimeEngine.init` 没有对应参数，Packages 层六条测试拿不到带临时目录的真引擎；「等空闲」的延时也没有注入点。
> 审查者：范围、集成
> 处理：加上 `digest(of:)` 与引擎的 internal 注入点，写明 Packages 测试如何预先放好容器；空闲等待已撤回。

---

### 🔵 Suggestion (13)

**1.** [B 一致性] `line 146–147` — 「约三成样本」应为约四成（3366 个里的 1404 个），MachOFile 专有路径约占一半；日期格式器是每处理一个索引事件建一次，不是「每打一行日志」。审查者：性能。处理：已改。

**2.** [B 一致性] `line 155–162, 644` — 压缩率测的是按默认选项打印的接口，没有地址、注释也少，语料按全部选项打印，压缩率会有出入。审查者：性能。处理：已注明。

**3.** [F 可测试性] `line 400, 507` — 「对照 `FrozenSemanticString+Codable` 的判定」只覆盖文本与 span 几列，区间、条件、条目下标与嵌套区间要另外判定。审查者：键、范围。处理：已写明。

**4.** [B 一致性] `line 280, 289–290` — 一处说清理不依赖 `Info.plist`，一处又说按 `Info.plist` 里的使用时间清理。审查者：键。处理：使用时间改为单独的 `LastUsed` 文件，两个 `Info.plist` 只给人看。

**5.** [G 代码一致性] `line 95` — 引用的 `Node+OpaqueType.swift:254, 307, 347` 是文档注释，实际的打印点与写入点是 swift-demangling `NodePrinter.swift:574`、MachOSwiftSection `NodePrintable.swift:149` 与 `SymbolicDemangler.swift:459-477`。审查者：键。处理：已改引。

**6.** [H 结构] `line 10` — 决策日志没有覆盖第一轮 🟡8、🟡10 的处理与「重新就绪时读取」的删除；「5 秒」没标可推翻，「一天」没进日志。审查者：范围。处理：已补行、已标注。

**7.** [C 歧义] 全文 — 「恢复」同时指从磁盘读语料、第二期的读取后补建、上游缓存建 section。审查者：范围。处理：第一期统一用「读取」，Report 的英文标题保留。

**8.** [A 完整性] `line 43–49` — 小标题写「Release」却列了 Debug 数字；「每次启动之后的几十秒里」没有实测。审查者：范围。处理：表格分列构建配置与 CPU，「几十秒」改为未测。

**9.** [H 结构] `line 185, 276` — 「374 MB、19 个 Mach-O」与根目录 `Info.plist` 的「布局版本」已经没有用处。审查者：范围。处理：已删。

**10.** [B 一致性] `line 600, 613` — 新建 `RuntimeViewerCore/Tests/AGENTS.md` 在第 2 步与第 7 步各列了一次。审查者：范围。处理：只留在第一步。

**11.** [C 歧义] `line 560, 571` — 「启动后即可搜」要后台索引打开才成立，而它默认关闭，按默认设置的用户得到什么没写。审查者：范围。处理：「用户可见变化」补上默认设置的情形。

**12.** [G 代码一致性] `line 480–482` — Report 的改动面没列全：两处穷举 switch、`ReportTreeBuilder.corpusCategory` 的签名与测试，以及 `ReportOutlineBindingTests` 钉住的递归 `isContentEqual` 约定。审查者：集成。处理：已列出。

**13.** [B 一致性] `line 487, 609` — 「AppDelegate 只多两行」说少了，还要一条 `@Dependency` 与一个 `@objc` 方法。审查者：集成。处理：启动清理移到服务进程后，AppDelegate 只多一条依赖与一个一行转交的菜单动作，已照实写。

---

### ✅ Strength (3)

- 第一轮的 🔴 大多真正落进了正文：构建路径先查盘一次补上三个漏口，读回校验写成完整清单，生产者身份改读内存里的映像，替代方案里留下了「审查后推翻」的记录。
- 命令行实测降为「粗略参考」，逐条写明不能搬到 App 的原因，表格里的数字都能从阶段日志逐项复算。
- 第二期移出本提案，闸门写明测什么、参考线多少、由谁拍板；设置页的客户端放在 `RuntimeViewerSettings`、清理逻辑放 Core，与项目的分层规则一致。

---

### 📊 摘要

| 严重程度 | 数量 |
|---------|------|
| 🔴 Critical | 1 |
| 🟡 Should Fix | 17 |
| 🔵 Suggestion | 13 |
| ✅ Strength | 3 |

**维度分布**:
- A 完整性: 1    B 一致性: 9    C 歧义: 4    D 可行性: 9
- E Scope: 1    F 验收: 4    G 代码一致性: 4    H 结构: 2

---

### 已淘汰候选 (Dropped Candidates)

- [D 可行性] 生产者身份的计算成本与时机 — 淘汰原因: 只是遍历已加载的映像、读内存里的 LC_UUID，不到毫秒级；Catalyst service 的插件在引擎启动前就已加载。（性能、键）
- [D 可行性] Core 新代码在旧平台上编不过 — 淘汰原因: CryptoKit 与 `NSData.compressed(using:)` 的最低版本与 `Package.swift:63` 一致，`sysctlbyname` 所有 Darwin 平台都有，服务本身已链接 CryptoKit。（性能）
- [D 可行性] 每次读取建、删一个标记文件开销太大 — 淘汰原因: 一次创建加一次删除，相对 0.5 秒的预算可以忽略。（性能）
- [D 可行性] 单镜像 0.5 秒、200 MB 达不到 — 淘汰原因: 提案写了实测与超标时的退路；按 27.3 MB 文本粗估，七个镜像压缩后远低于 200 MB。（性能）
- [D 可行性] 进程内的 ObjC 类别折叠让语料依赖用户载入的非系统镜像 — 淘汰原因: 共享缓存镜像的依赖闭包全是缓存镜像，折叠只读非缓存镜像。（键）
- [D 可行性] 还有别的形式会打印绝对地址 — 淘汰原因: 只有 opaque 一类节点存绝对指针，其余存偏移或未滑动地址；`RuntimeFunctions.swift:54` 说的是调用运行时时传入的指针，不进打印文本。（键）
- [D 可行性] `RuntimeObject`、`RuntimeMemberDeclaration` 的二进制 plist 解码会 trap — 淘汰原因: 合成与 MetaCodable 的解码出错都是抛错。（键）
- [D 可行性] 区间乱序、重叠，或未知类型码、越界标识符下标会 trap — 淘汰原因: 投影先排序、截断，未知类型码与越界下标都会降级。（键）
- [D 可行性] Xcode 的 `*.debug.dylib` 或注入库干扰生产者摘要 — 淘汰原因: 两个 service 都没有 debug dylib，Xcode 注入的库不是含 Core 映像的依赖。（键）
- [D 可行性] 跳转到定义会被前台加载误伤 — 淘汰原因: 点击目标带的是当前显示对象的镜像，那个镜像已经索引过。（集成）
- [D 可行性] 语料协调器比 `documentDidOpen()` 建得晚，会错过 `.batchStarted` — 淘汰原因: `events` 会给后来的订阅者补发进行中的批次。（集成）
- [G 代码一致性] `RuntimeViewerSettings` 不能依赖 Core — 淘汰原因: `Package.swift:405-411` 显示它已经依赖 `RuntimeViewerCore`。（集成）
- [F 可测试性] 第 5 步（App 层）没有测试 — 淘汰原因: 提案已说明 App 工程没有测试 target，逻辑放进 package 测。（范围）
- [G 代码一致性] 其余引用的路径与行号 — 淘汰原因: 四位审查者合计抽查了几十处，除上面列出的几处外全部存在且内容相符。（全体）
