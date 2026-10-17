# 交叉引用审查记录 — 2026-10-17

审查对象：`feature/cross-references`（提案 [draft-cross-references](../Evolutions/draft-cross-references.md) 的第 1–3 步，head `7e9b011a`，分叉点 `bd05a280`）连同它依赖的 MachOSwiftSection `feature/cross-reference-analysis`（`c2cefa9c`）。MachOSwiftSection 那一半的条目、修法与测试记在它自己的 `Roadmaps/2026-10-17-cross-reference-analysis-review-findings.md`，判为不修的登记在它的 `ReviewAdjudications.md` A62–A67。

**经过**
1. 四个子代理按模块并行通读（只读），交回 47 条候选，去重后 43 条（两个仓库合计）。每条由本人回到代码复核，能造复现的造复现，按四问汇报。
2. 用户 2026-10-17 批准「先按你推荐的路径修，修完接 UI，MCP 和 CLI 放最后」。每条要修的都先写了修复前失败的测试。

**约定**
- ID 为 `XR.<审查编号>`，审查编号按审查时的分组：A 扫描与寄存器跟踪、B 分析器与预筛、C 引擎侧（本仓库）、D 测试与文档、N 公开接口。下表只列本仓库的条目，以及本仓库要跟着动的上游条目。
- 四问里的「基线」是分叉点 `bd05a280`（`next`），那里没有这个功能：本表的每条都是这个分支引入、以前没修过，例外写在条目里。

## 条目

| ID | 问题 | 严重度 | 处理 |
|---|---|---|---|
| XR.C1 | 缓存外的镜像查不到，结果里的路径是空串或 `@rpath/…` | Major | 上游修（B3）后升级钉的版本；测试 `imagesOutsideTheCacheGoByTheirLoadedPath` |
| XR.C2 | 类型引用的每一条结果都附带整个被查对象，含全部子节点 | Minor | 已修：目标对象去掉子节点；测试 `typeReferencesCarryNoChildren` |
| XR.C3 | 一次超出预算的扫描把别的缓存全挤掉，再留下半截 | Minor | 已修：这一代记住超限的扫描、不再记录；测试 `oversizedScansAreNotRecordedAgain` |
| XR.C4 | 会话的内存上限只管函数表，分析器的类、类型索引与链接关系一直留着 | Minor | 不修：以缓存里的类与类型总数为上限；文档写明 |
| XR.C5 | 一次查询占满除一个之外的协作线程 | Minor | 不修 |
| XR.C6 | 类型查询解开的名字留在进程级缓存里 | Minor | 上游修（B2），升级钉的版本 |
| XR.C7 | 换分析器时没复查镜像列表 | Minor | 误报级：要镜像卸载后列表又恰好回到原样 |
| XR.C8 | 只剩导入名的调用标成「精确」，不看导入的是哪个库 | Minor | 不修 |
| XR.C9 | 结果数恰好在中间某张镜像到达上限时 `isComplete` 为 false | Nit | 误报 |
| XR.C10 | `RuntimeEngine.callers` 的注释还说按导入表与 selector 筛库 | Nit | 已改 |
| XR.C11 | 代码合并后的方法只取第一个类；成员按方法表命名时被调视图丢了 `self` 的类 | Nit | 不修 |
| XR.C12 | 会话单例没走 `@Dependency`；新 target 声明了没用到的依赖；`RuntimeViewerServer` 的锁文件还在 MachOSwiftSection 0.17.1 | Nit | 依赖已删；单例补一句注释说明；锁文件是基线就有的，不在本分支处理 |
| XR.C13 | 几个测试分辨不出它声称验证的东西；缺 `.member` 的往返编码与缓存外镜像的测试 | Minor | 已改，见条目 |
| XR.D1 | 两个「重复查询复用缓存」的测试不可能失败 | Major | 已改：跨全部镜像查，第一次报多次、第二次只报一次 |
| XR.D4 | 「跨镜像的类型引用」测试分辨不出按导入预筛与按链接预筛 | Minor | 已改：候选集要包含链接 Foundation 的每个镜像；另加 SharedWithYou 的单镜像查询 |
| XR.D6 | 测试注释说换系统版本不影响成立，部分断言钉的是 macOS 27.2 的代码 | Nit | 改注释 |
| XR.D10–D13 | 提案索引那一行、提案的摘要与方案第 4 条、第 5 节的错误枚举、第 3 节的表格都停在第二批之前 | Minor | 已改 |
| XR.B6 | 会话的字节估算没算字符串 | Minor | 误报：同一次扫描里重复的名字共用存储 |
| XR.B1 | 被改名再导出的 C 函数，跨库查调用者几乎全漏 | Major | 上游修，升级钉的版本 |

## XR.C1 — 缓存外的镜像

- **问题**：分析器拿镜像声明的安装名当路径；RuntimeViewer 用 dyld 的加载路径查（`DyldUtilities.imageNames()`）。注入第三方 App 后查它自己的代码（主程序、它带的 `@rpath` 框架、插件 bundle），或把范围限定在它们上，一律报 `imageNotFound`；在这些镜像里找到的调用者，路径是空串或 `@rpath/…`，界面没法跳过去。测试只用了缓存里的系统库，所以一直没暴露。
- **复现**：`imagesOutsideTheCacheGoByTheirLoadedPath`：查测试包（`MH_BUNDLE`，没有安装名）里一个函数的被调。旧版本的 MachOSwiftSection 上报 `imageNotFound`。
- **修法**：在上游（MachOSwiftSection 审查记录 B3、B4）；本仓库升级钉的版本。

## XR.C2 — 类型引用的目标带着整棵子树

- **问题**：每条类型引用的目标是 `.type(name:object:)`，带着查询的那个对象；合成的 `Codable` 把 `children`（嵌套类型、特化）整棵编码。几千条引用就把同一棵子树编码几千遍，进度报告与最终结果各一遍。
- **复现**：`typeReferencesCarryNoChildren`：给 `URL` 挂一个子节点再查，旧代码的每条结果都带着它（Foundation 里 100 条引用，100 处失败）。
- **修法**：目标对象只留身份与显示所需的字段，`children` 为空。跳转只用对象的身份。

## XR.C3 — 超出预算的扫描

- **问题**：一次超过 64 MB 预算的扫描（`init` 的调用者）在增长过程中按 LRU 逐个淘汰别的缓存，超限后丢掉自己；下一张镜像又从头记，最后留下半截。结果仍然正确，但别的缓存每问一次就被清空一次。
- **复现**：`oversizedScansAreNotRecordedAgain`：预算设成大扫描的一半。旧代码上大扫描留下半截，再问一次又把小扫描挤掉。
- **修法**：超限的扫描键记进 `oversizedScanKeys`，同一代里不再记录；换代（镜像变化）时清空。第一次增长时挤掉的别的缓存仍会被挤掉——那时还不知道它会超限。

## XR.D1 — 复用缓存的测试

- **问题**：`typeScansAreReused` 与 `scansAreReusedWithinTheSession` 都限定在单个镜像里。复用时报一次进度，重新扫一遍也只报一次，断言分不出两者。
- **修法**：改成跨全部镜像、但只筛出少量候选的查询（`orderWindow:relativeTo:` 的发送者、`NSWindow` 的类型引用）：第一次每扫完一张镜像报一次，第二次全从缓存来、只报一次。临时让会话从不返回已存的扫描，两个测试都在「只报一次」那条断言上失败，已恢复。
- **整套一起跑时的坑**：单独跑通过、整套一起跑却失败。原因是 Objective-C 运行时第一次用到时会加载 `libobjc-trampolines.dylib`（不在共享缓存里），缓存外的镜像列表变了，会话正确地换代、丢掉全部扫描。所以会话改为从参数取「缓存外镜像列表」（默认仍读进程自己的），这几个测试给它一个不变的列表。这不是产品缺陷：只有镜像真的变了才换代，而这个库在一个进程里只加载一次。

## XR.D4 — 类型的候选集

- 原测试只要在 Foundation 之外找到一处引用就通过，而按导入预筛也能找到（确有少数镜像按名字导入 `URL` 的符号）。改成 `typeCandidatesFollowTheLinkage`：候选集要包含每一个链接 Foundation 的镜像（与 `swiftFunctionCandidatesFollowTheLinkage` 同法）；另加 `typeReferencesWithoutAnImport`：SharedWithYou 没有任何 `URL` 的导入记录，单查它也要找到引用。

## XR.C13 — 测试的鉴别力

- `calleesOfAnObjectiveCMethod` 里「接收者已知则精确、未知则按 selector」的循环照抄了实现，不可能失败。换成具体的期望：`[self orderWindow:… relativeTo:…]` 的目标是发给 `NSWindow`、精确。
- 「错误描述在往返后保持含义」其实没有往返，只查描述非空。改名为「每个错误都说清出了什么事、关于谁」，并检查描述里带着它的路径、地址或名字。
- 补上 `.member` 主体的往返编码，以及缓存外镜像的查询（XR.C1）。

## 不修与误报

- **XR.C4**：分析器留着扫描碰到的每个镜像的类索引、类型索引与链接关系，会话只在镜像变化或起过名的镜像超过 64 个时换分析器。它们以缓存里的类与类型总数为上限（macOS 27.2 有 203,621 个类名），不会无界增长；没有单独测过占用。MachOSwiftSection 的模块文档写明了这一点。复审条件：实测本地运行时 service 在长时间使用后被这些索引撑大。
- **XR.C5**：每个子任务扫完一张镜像就让出线程（最大的镜像约 0.1 秒），别的请求最多等这么久，不会卡死。复审条件：两个文档同时查询时界面明显卡顿。
- **XR.C7**：`noteFunctionTables` 换分析器时沿用同一代。要出错，必须在两次查询之间有镜像被卸载、而镜像列表又恰好回到原样——下一次 `currentAnalyzer` 比对列表时就会换代。判为误报级，不修。
- **XR.C8**：`.importedSymbol` 只在桩的槽位读不出时出现，进程内只有缺失的弱导入会这样；按名字比对、标成精确，实际没见到错配。若将来在 macOS / iOS 26 的缓存上（那里的桩被改写成直接跳转，MachOSwiftSection A64）按名字报的调用变多，再改成「候选」。
- **XR.C9**：查询确实在中途停了，没扫完的镜像里有没有更多不知道，`isComplete` 为 false 正是文档的定义。误报。
- **XR.C11**：代码合并的方法里恰好有发给自己的消息、且合并的方法属于不同的类，才会取错类；没见到实例。
- **XR.C12**：`RuntimeViewerCore` 不依赖 swift-dependencies，会话单例只在定义它的文件里被取用，测试各自注入自己的会话；补了注释。`RuntimeViewerServer.xcodeproj` 自带的锁文件落后是基线就有的状态。
- **XR.B6**：会话按引用的定长部分估算，不算字符串的堆存储。复核发现 selector 与导入名在扫描器里按指针记忆、类名在类索引里按类记忆，同一次扫描里重复的名字共用一份存储，审查说的「可能到预算的两倍」不成立。误报。
