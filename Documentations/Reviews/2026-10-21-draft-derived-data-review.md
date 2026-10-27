---
reviewed_file: Documentations/Evolutions/0061-derived-data.md
reviewed_at: 2026-10-21
reviewer_model: claude-opus-5-5
doc_type: evolution
extra_instructions: 用户要求开多个 agent 做对抗审查。四位审查者并行（xhigh），立场是默认提案有漏洞、尽力构造反例，分别侧重缓存键与失效、架构与规则集成、性能论断与证据、范围目标与验收；本文件是四份报告去重合并的结果
critical_count: 4
should_fix_count: 12
suggestion_count: 9
---

## 📄 文档信息

- **路径**: `Documentations/Evolutions/0061-derived-data.md`（审查时还是草案 `draft-derived-data.md`）
- **类型**: evolution
- **文档行数**: 507
- **审查日期**: 2026-10-21

本报告由四份报告合并而成。每条末尾的「审查者」注明是哪几位独立报告了它：
- 键：缓存键与失效。
- 集成：架构与规则集成。
- 性能：性能论断与证据。
- 范围：范围、目标与验收。

合并时，主 agent 亲自复核了以下几条，均属实：
- `ownRuntimeSymbolNamesByAddress` 的调用子树里没有一帧解混淆。
- 关联类型的跳板反汇编只对 `MachOFile` 开放。
- `VisibilityCondition.Requirement.init` 带 `precondition`。
- 设置开关的实际名字是「Keep Interfaces Searchable」。
- 内容区对没有 section 的对象拿不到接口。

---

### 🔴 Critical (4)

**1.** [D 可行性] `line 168–169, 380–381, 499` — 恢复只挂在批次开始，手动打开的镜像和已索引的根都恢复不到
> 恢复只有两个入口，`.batchStarted` 与 Engine 重新就绪（line 380–381）。`RuntimeInterfaceCorpusStore.build` 只查内存里的 `corpora`（`RuntimeInterfaceCorpusStore.swift:377`），不读盘。
> - **手动打开的镜像**：不开批次。仓库里没有任何地方创建 `.manual` 批次，打开走的是 `imageDidIndexPublisher` → `FindCorpusCoordinator.imageDidIndex` → `requestBuild`（`FindCorpusCoordinator.swift:666`）。所以 line 169「下次它被索引时，直接从磁盘恢复」和 line 499 的同一说法，都没有代码路径能触发。
> - **已经索引过的根**：BFS 遇到已索引的镜像直接 `continue`，`guard !items.isEmpty else { return nil }` 也不发任何事件（`RuntimeBackgroundIndexingManager.swift:230, 321`）。
> - **启发式批次会抢先**：它默认开启、深度 1，根是服务进程的可执行文件，而这个文件直接链接 AppKit、SwiftUI、Foundation、libswiftCore（`otool -L` 可见）。这几个 Always Index 根如果先被启发式批次索引了，自己就不再开批次。
> - **默认设置下从不恢复**：`Settings.Indexing.isEnabled` 默认 `false`（`Settings+Types.swift:149`），按默认设置用的人只写盘、从不恢复。
>
> 另外三处没写清：哪些批次原因会触发恢复（`.appLaunch` 算不算）；「Keep Interfaces Searchable」关掉时还恢复不恢复；重新就绪时的恢复，会和 `RuntimeBackgroundIndexingCoordinator.swift:353–367` 的批次重派重复。
> 建议: 让 `build` 在打印前先查派生数据；批次开始时的恢复只作为「section 建好之前就能搜」的提前量；写明认哪些批次原因、开关关闭时怎么办。
> 审查者：集成、范围

**2.** [D 可行性] `line 320, 342–347, 381` — 读回校验有漏项，坏数据会让「My Mac」的 service 反复崩溃
> 提案承诺「任何一步失败都按「没有缓存」处理」，但列出的校验漏了以下几种情况，它们会在构造对象时直接 trap，来不及走回退：
> - `VisibilityCondition.Requirement.init` 的两条 `precondition`：选项名不能为空，不能含控制字符（swift-semantic-string `VisibilityCondition.swift:33-38`）。
> - span 三列长度必须相等。库自带的解码器检查这一点（`FrozenSemanticString+Codable.swift:109`「Span column counts differ」），提案没列。
> - `nestedRanges` 与 `entries` 的起止下标出现 lower > upper 或越界。
> - 区间必须对齐 span 边界。投影默认「Regions are runs of whole spans」，自己不检查（`VisibilityProjection.swift:109`）。
>
> 校验和只能拦住磁盘损坏，拦不住同一个写入端写错的数据。而启动时要恢复（line 168），每次重连也要恢复（line 381），于是 trap → service 重启 → 重连 → 再恢复 → 再 trap，「My Mac」进入崩溃循环，直到用户手动删除派生数据。
> 建议: 把以上几项补进校验，尽量复用 `FrozenSemanticString` 已有的带校验解码；恢复前留一个「正在恢复」标记，进程死在半途时把对应文件隔离掉。
> 审查者：键、范围

**3.** [G 代码一致性] `line 105–123, 182–183, 503` — 实测归因有误：「已经看到的两处重复劳动」不成立，命令行的数字不能搬到 App
> - **那 2 秒不是解混淆**：`ownRuntimeSymbolNamesByAddress` 是 `MachOThunkEnvironment` 上的 `private lazy var`（`MachOThunkEnvironment.swift:127-141`），而 `AccessorThunkReader.read` 每次都新建一个 environment（`AccessorThunkReader.swift:67`）。实际是每读一个跳板就把整张符号表重扫一遍。它的调用子树里没有一帧解混淆，栈顶是 `String.init`、`Symbols64.Iterator.next`、`String.hash`（主 agent 复核：1404 个样本，解混淆 0 个）。所以存解混淆结果省不掉这 2 秒。
> - **两处都在 App 不走的路径上**：关联类型推算一开头就是 `guard let machOFile = machO as? MachOFile else { return nil }`（`Node+OpaqueType.swift:281`）；RuntimeViewer 的 section 建在 `MachOImage` 上（`RuntimeSwiftSection.swift:73`），走的是进程内的运行时解析。`ObjCMethodThunkReferences` 的 `MachOImage` 重载也不建 `ThunkAddressSpace`。所以 line 182「已经看到两处」与 line 183 的「关联类型推算表」，在 App 里都没有对应的开销。
> - **SwiftUI 的合计算错了**：表里写 10.9 秒，各行相加是 8.8 秒，正好等于日志里 `Indexing completed` 的 8.76 秒。多出的 2.17 秒是命令行自己的 `collectModules()`，App 不跑这一步。
> - **样本换算成秒的口径不一**：三处分别按约 3、1.4、0.56 ms/样本换算。按同一口径，命令行逐行新建日期格式器的开销约占 25%，主要集中在类型一行（800 个样本里占 538 个）和协议遵循一行（3366 里占 1181）。
> - **AppKit 的采样与阶段表对不上**：`prepare()` 只有 275 个样本，`printRoot()` 有 2144 个；`applyObjCMembers` 全在打印路径下。「扩展那 5 秒几乎都在反汇编」这个说法，采样支撑不了。
>
> 决策日志 line 503 记下的「先量先修」这个选择本身仍然成立，而且更有必要了，但它引用的证据要改。
> 建议: 删去两处「已看到」，候选改为「待 App 进程内测量后确定」；表格统一口径，注明哪些行含命令行自身的开销，单列「命令行收集 import（App 不做）」。
> 审查者：性能、范围

**4.** [B 一致性] `line 1, 14, 168, 201, 205, 419` — 标题承诺「不重建」，第一期只做到「语料不重打」
> 标题是「系统没更新就不重建」，摘要（line 14）把 section、语料、交叉引用并列为每次启动重做的三件事。可本提案的交付只有语料：
> - section「照常在后台建（Always Index 的行为不变）」（line 168）。
> - 「不把交叉引用表存盘」（line 201）。
> - 「不在本提案里实现上游的任何缓存或优化」（line 205）。
>
> 而替代方案否掉的恰恰是「只存语料……满足不了「系统没更新就不重建」」（line 419）。「影响」一节也没告诉读者：启动时开销最大的 section（AppKit 8.9 秒）照旧会建。
> 建议: 标题与摘要改成第一期实际做到的事，并在「用户可见变化」里写明 section 与交叉引用照旧重建、CPU 开销的大头不变。
> 审查者：范围

---

### 🟡 Should Fix (12)

**1.** [B 一致性] `line 440` — 「打开搜到的结果仍要等，和现在一样」不成立，这是第一期新带来的状态
> 现在语料只能为已索引的镜像建（`RuntimeEngine+Search.swift:134` 的 `_isImageIndexed` 守卫），所以打开搜索结果从来不用等。
> 恢复之后会第一次出现「有搜索结果、但没有 section」的状态。取接口只读 `existingSection`（`RuntimeEngine.swift:748, 761`），拿不到就返回 `nil`。主 agent 追了一遍路径：内容区先是空的，要等批次结束触发重新加载（`ContentTextViewModel.swift:133` 跟随 `dataChangePublisher`），接口才出来。
> 另外，Ancestor、Descendant、Conforming Types 和 Type References 这几种模式不读语料（`FindMode.readsCorpus`，`FindMode.swift:101-105`），启动后照旧要等。
> 建议: 补一段「点开尚未索引镜像里的结果」的交互设计（比如打开时转为前台加载）并加测试；把说法改成「读语料的模式启动即可用」。
> 审查者：集成、范围

**2.** [C 歧义] `line 174, 353, 382` — 「已恢复」状态怎么表示、Report 怎么展示都没定
> 两种做法都有问题：
> - **加进覆盖情况**：要给 `RuntimeInterfaceCorpusBuildState`（`RuntimeInterfaceSearch.swift:261`）加 case。它是 `Codable` 的线上类型，旧对端解码失败会被 `try?` 静默吞掉；新 case 的 `isBuilt == false` 还会让 `imageDidIndex`（`FindCorpusCoordinator.swift:669`）重新请求构建。
> - **只在 App 侧记列表**：`mergeCoverage`（`FindCorpusCoordinator.swift:600-625`）会把没跟踪过的 built 镜像当作「别处建好的」写进 `finishedBuilds`，恢复的镜像就会同时出现在新组和构建历史里，和 line 174「不再作为「构建」出现」相反。
>
> 以下几件事也都没写：Clear History（`ReportViewModel.swift:229-233`）清不清新组；新组里的镜像被常驻上限淘汰、或 Engine 重置时怎么处理；细节栏要显示的「恢复用时」，`RuntimeInterfaceCorpusRestoreResult` 里没有；新组还需要给 `ReportNodeIdentifier` 新增 case。
> 建议: 选「在 `RuntimeInterfaceCorpusCoverage` 里加一个带默认值的字段」或写出线上兼容方案，并写明新组在上面几种情况下的行为。
> 审查者：集成、范围

**3.** [D 可行性] `line 353, 383` — 恢复与现有构建流程的交接有两处漏洞
> - **恢复与在途构建**：同一镜像已经排队或正在构建时怎么办，没有定义。`pump()` 一出队就打印，不检查 `corpora`（`RuntimeInterfaceCorpusStore.swift:458`）；`finishBuild` 直接覆盖（`:609`）。小镜像几百毫秒就建好 section，构建请求会赶在大文件恢复完之前入队，结果照样打印一遍，还被记成一次构建。
> - **改 Transformer 后不重建**：重建只重新请求 `requestedImagePaths`（`FindCorpusCoordinator.swift:782`），而恢复的镜像永远进不了这个集合（`:293`、`:669`）。`evictInterfaceCorpus(nil)` 清掉它们之后不会重建，要等下一次搜索时的 reconcile 才补上，第一次搜索会漏掉这些镜像。
>
> 建议: 恢复命中时取消或合并同一镜像的在途构建；恢复成功的镜像也记进 `requestedImagePaths`；两种情况各补一条测试。
> 审查者：集成

**4.** [G 代码一致性] `line 385–392, 414, 476` — App 层控制器放错了层：设置页引用不到，也没有测试 target
> 设置页 `IndexingSettingsView` 在 package `RuntimeViewerSettingsUI` 里，引用不到 App target 里声明的 `@Dependency(\.runtimeDerivedDataController)`。项目现有的做法是：客户端在 `RuntimeViewerSettings` 里声明，实际实现由 App 提供（`UpdaterClient+DependencyValues.swift`、`ApplicationRelauncher.swift`）。
> 另外，App 工程里唯一的单元测试 target 是 `RuntimeViewerSourceEditorBridgeTests`，清理与「先改名再删」的测试没地方放；新建 target 又要同步 Tuist 描述，提案没算进去。
> 建议: 在 `RuntimeViewerSettings` 里声明一个派生数据客户端；清理与删除逻辑放进 package，App 层只负责转交。
> 审查者：集成、范围

**5.** [D 可行性] `line 160, 171, 255–258, 279, 312, 399, 458` — 生产者身份与清理规则：同 bundle id 的多份构建互删，旧代码的产物可能贴上新摘要
> - **互删**：多个 worktree、`RunScript.sh`、`TuistScript.sh` 编出的同一配置，bundle id 都是 `dev.JH.RuntimeViewer.arm64e`（`CodeSigning.xcconfig:8`），摘要却各不相同。按 line 399「生产者摘要不等于本 App 当前摘要的，删掉」：交替启动时，每次都会删掉另一份的数据；两份同时运行时，后启动的那份会删掉前一份 service 正在写的目录。
> - **整包摘要的理由不成立**：line 279 用「两个 service 互删」来论证整包摘要，可清理只在 App 里做，系统目录又按平台分开，两个 service 本来就碰不到对方的数据。
> - **旧代码的产物贴上新摘要**：摘要是按磁盘上的 App 包懒计算的。`RunScript.sh` 原地重编，最后的 `open` 只是把还在运行的旧实例切到前台（`:232-234`）。旧 service 如果在重编之后才第一次算摘要，就会给旧代码的输出贴上新摘要，违反 line 430「绝不读到旧代码产出的数据」。
>
> 建议: 进程一启动就从本进程已加载映像的 LC_UUID（内存里的）算身份；清理改为按最近使用时间淘汰，而不是「不是本 App 就删」。
> 审查者：键、集成、性能、范围

**6.** [C 歧义] `line 221, 353, 409` — 「Transformer 摘要」没有定义算法，而配置里有 Dictionary
> Core 里没有现成的摘要函数。`Transformer.CType.replacements` 的类型是 `[Pattern: String]`（`Transformer+CType.swift:26`），Swift Dictionary 的遍历顺序每个进程都不同。如果直接用 `hashValue`，或用不排序键的编码结果算摘要，配置了两条以上 C 类型替换的用户每次启动都恢复不到；每次写盘还会按 line 301–303 删掉「其他变体」，也就是上一次启动写下的文件。
> 建议: 写明用排序键的规范编码，或者读回时用 `Equatable` 比对容器里存的完整配置；补一条跨进程摘要稳定的测试。
> 审查者：键、集成

**7.** [D 可行性] `line 86–89` — 「打印出的地址重启后照样有效」有一个例外
> 在进程内（`MachOImage`）模式下，名字解析不出来的 opaque type 符号引用，会带着描述符的绝对进程内指针打印出来，形如 `opaque type symbolic reference 0x…`（MachOSwiftSection `Node+OpaqueType.swift:254/307/347`，审查者另引 `SymbolicDemangler.swift:444-461`）。这是加了滑动的地址，重启后就失效。
> 在同一个进程里做往返测试测不出来。命令行文件模式的输出里这段文字出现 0 次，进程内的实际频率未知。
> 建议: 上游改成打印未滑动地址；或者在提案里写明这个例外，并检查恢复出的文本里不含绝对指针。
> 审查者：键

**8.** [C 歧义] `line 173, 214–218, 389, 398–400` — 目录元数据与删除的收尾没定义
> - **`Info.plist` 谁写、何时写，没定义**：「Delete Derived Data…」之后，按 line 173 写回的新目录里不会有 `Info.plist`。下次清理时要么把当前数据当成过期删掉，要么永远不清。
> - **「最近使用时间」没有任何地方读**。
> - **改名移开的旧根目录会残留**：删到一半时 App 退出，这个目录不在清理规则里，也不计入占用。
>
> 建议: 每次写盘都确保各级 `Info.plist` 存在，或者让清理直接解析目录名；启动时顺带回收改了名的残留目录。
> 审查者：键、集成、范围

**9.** [D 可行性] `line 135, 319, 340–347, 352, 444` — 恢复与写盘的成本被低估
> **读回**，「几千条只要几毫秒」（line 340）没标推测，实际的量级更大：
> - 成员有 4.1 万条（SwiftUI）和 9 万条（AppKit），要用二进制 plist 的 Codable 逐条解码。
> - 每条都要重建 `RuntimeInterfaceLineTable`（`RuntimeInterfaceCorpusStore.swift:51-55`）。
> - 首尾相接存的列，要切回每条各自的字符串和数组。
> - 每段还要算 SHA-256、做 LZFSE 解压，所以 `.alwaysMapped` 换不来零拷贝。
>
> **写盘**，line 352 用 utility 优先级在后台编码。可提案 0027 已经证明，同一进程里的工作会互相拖慢，「QoS 帮不上忙」。系统更新后第一次启动时，建语料、编码、压缩、写盘，会和后台批次、前台加载挤在同一个 service 里。
> 建议: 第 3 步加 SwiftUI、AppKit 的恢复耗时测量，并据此决定成员段要不要改成定长列；写盘推迟到后台批次空闲之后。
> 审查者：性能、范围

**10.** [D 可行性] `line 96–99, 183` — 上游缓存的候选不都是「扁平的表」，也不都是「单个镜像的纯函数」
> - **不扁平**：`SymbolIndexStore.Storage` 除了节点库和符号表，还有 `typeInfoByName`、三层嵌套的 `memberSymbolRowsByKind`、`thunkAttributeMembersByKindAndTypeName`、`symbolRowsByOffset`，以及按结构哈希重建的表和可追加的 `lateNameStore`（`SymbolIndexStore.swift:145-330`）。第 4 阶段只覆盖节点库。
> - **不是单镜像的纯函数**：ObjC 成员表会沿父类链读进别的镜像（`ObjCAncestorResolver.swift:71-79`，`ObjCClassMethodIndex` 的文档注释）。所以上游缓存的键只能放在共享缓存 UUID 这一层之下。
>
> 建议: 「扁平」只用来说节点库和符号行；其余字典的读回成本列入 App 进程内的测量；把键的层级要求写给上游提案。
> 审查者：性能、键

**11.** [F 可测试性] `## 测试`、`## 落地步骤` — 第一期没有可判定的验收标准，身份推导也没有测试
> - **没有数值标准**：核心收益「启动后 Find 立刻可用」没有任何数字，读回耗时、磁盘占用、摘要耗时也都是推测。没有哪一步测「七个镜像从冷启动到全部可搜」要多久、在哪种构建下测。
> - **身份推导没有测试**：最容易静默出错的「谁启用」不在测试里。`enclosingApplication(of:)` 对 App 本身、XPC service、`Contents/Applications` 下的工具要返回同一个位置，对注入载荷和独立工具要返回 `nil`；`applicationBundle(at:)` 要保证各进程算出同一个摘要。可测试一律注入临时目录，真实的推导路径完全不经过测试。
>
> 建议: 加一步「Release 构建、七个常驻镜像、前后两次冷启动」的对比，并写下验收数字；在临时目录里搭一个假 `.app` 结构，测推导结果与摘要稳定性。
> 审查者：范围、集成、性能

**12.** [F 可测试性] `line 195, 205, 481–482` — 本提案何时算完成没写，第二期闸门也判定不了
> - **完成点不清**：落地第 7 步是别的仓库的提案，第 8 步要等上游做完；做完第 6 步后，本提案能不能标为 Implemented，没写。
> - **闸门没有判定标准**：只说量「一个大镜像」，没指定镜像、构建配置和通过线。
> - **「一两秒」缺 ObjC 侧的依据**：AppKit 的 ObjC 部分单独就要 6.7 秒；SwiftUI 扩展阶段 388 个样本里有 352 个是 `ObjCClassMethodIndex.hierarchy`；`allObjects()` 还要重新 mangle（`RuntimeSwiftSection.swift:240, 262, 279`）。按现有数据，AppKit 达不到这个前提。
>
> 建议: 写明第 6 步后本提案即可收尾，把第二期与闸门挪进第二期自己的提案；或者给闸门指定镜像、Release、两个 section 合计的目标值。
> 审查者：范围、性能

---

### 🔵 Suggestion (9)

**1.** [G 代码一致性] `line 193, 352` — 「Keep Corpus Ready」不存在，实际是 `Toggle("Keep Interfaces Searchable", isOn: $search.isCorpusEnabled)`（`SearchSettingsView.swift:17`）。审查者：键、集成、范围

**2.** [E Scope] `line 162, 200, 462` — 读写方的范围与实际路径不符。审查者：集成、范围
> - CLI 与 MCP 都不建语料（grep `buildInterfaceCorpus` 为空），第一期命令行宿主其实不读写。
> - `Contents/Applications/RuntimeViewerCatalystHelper.app` 算不算适用位置，没写清。
> - 镜像另一台 Mac 的引擎时，对方的 service 会读写它自己的派生数据，与非目标「不覆盖远程设备」不符。

**3.** [A 完整性] `line 340, 423` — 「几千条只要几毫秒」「压缩之后差别基本消失」都没标「推测，未实测」。审查者：范围

**4.** [A 完整性] `line 78, 342` — swift-semantic-string 的 `FrozenSemanticString+Codable.swift:39-107` 已经按同样的列布局做了全套校验，应复用，或说明为什么另写。审查者：性能、范围

**5.** [B 一致性] `line 162, 478` — 计划写进 AGENTS.md 的「派生数据只在服务进程里读写」，与 App 要做清理、统计、删除相冲突。审查者：范围

**6.** [G 代码一致性] `line 405, 479` — 「测试不得碰真实派生数据目录」要写进 `RuntimeViewerPackages/Tests/AGENTS.md`，但那份只管 Application 测试；派生数据的测试主要在 `RuntimeViewerCore/Tests`，那里没有 AGENTS.md。审查者：范围

**7.** [B 一致性] `line 387, 391` — 「AppDelegate 只多一个菜单动作」，可启动清理还需要在 AppDelegate 里加一行调用。审查者：集成

**8.** [H 结构] `line 4, 46, 502, 505` — 头部作者是 JH，正文的「作者的常驻配置」也指用户，决策日志却写「作者提出，用户确认」；「始终索引」和「Always Index」混用。审查者：范围

**9.** [B 一致性] `line 280` — 「几十个 Mach-O」实际是 19 个（`/Applications/RuntimeViewer.app` 共 374 MB，每个 2–3 个 slice）。「几毫秒」的估计不受影响。审查者：性能

---

### ✅ Strength (3)

- 引用密且准：四位审查者合计抽查了几十处文件与行号，包括上游的 `DyldCacheHeader.uuid`、swift-demangling 提案 0001 的 `:40`/`:119`、`CodeSigning.xcconfig`、两份 entitlements，几乎全部相符。
- 实测的原始数据完整保留，AppKit 各阶段的数字能从日志精确复算，审查因此能逐项复核，包括找出上面第 3 条的错误。
- 失效路径简单可靠：读回失败一律当作没有缓存并删掉文件，生产者一变整个目录作废，不做格式迁移，不会静默读到旧格式。Core 里的进程级存储照 `CrossReferenceSession` 的先例写，并说明了不走 `@Dependency` 的理由。

---

### 📊 摘要

| 严重程度 | 数量 |
|---------|------|
| 🔴 Critical | 4 |
| 🟡 Should Fix | 12 |
| 🔵 Suggestion | 9 |
| ✅ Strength | 3 |

**维度分布**:
- A 完整性: 2    B 一致性: 5    C 歧义: 3    D 可行性: 7
- E Scope: 1    F 验收: 2    G 代码一致性: 4    H 结构: 1

---

### 已淘汰候选 (Dropped Candidates)

- [F 可测试性] 测试依赖本机共享缓存，在 CI 上不稳 — 淘汰原因: 现有的语料测试也是这么做的；往返测试只在同一台机器上前后比对；仓库没有跑测试的 CI（只有 `release.yml`）。（范围）
- [E Scope] 为一种数据建整套机制属于过度设计；`imageDirectory(forImageAt:)` 没人用 — 淘汰原因: 第一期明确把通用机制和上游接口列为目标。（范围、键）
- [D 可行性] 语料协调器创建得比 `documentDidOpen()` 晚，会错过 `.batchStarted` — 淘汰原因: `events` 会给后来的订阅者补发进行中批次的 `.batchStarted`（`RuntimeBackgroundIndexingManager.swift:60-88`）。（集成）
- [D 可行性] App Nap 没覆盖恢复与写盘 — 淘汰原因: 恢复由一个进行中的批次触发，期间 `hasActiveBatch` 为真；写盘构造不出具体的失败场景。（集成）
- [D 可行性] Core 的新代码在 watchOS、tvOS、visionOS 上编不过 — 淘汰原因: 所用 API 都满足 Core 的最低版本，`DyldCacheLoaded` 包在 `canImport(Darwin)` 里。（集成、性能）
- [D 可行性] `fileprivate static let` 违反 singleton 规则 — 淘汰原因: 有 `CrossReferenceSession` 的先例，且 Core 不依赖 swift-dependencies。（集成）
- [D 可行性] 用户做的泛型特化会混进语料 — 淘汰原因: `allObjectsCache` 第一次列举后就不再变；打印单个类型时不遍历 `specializedChildren`。（集成、键）
- [D 可行性] 注入的载荷经 `enclosingApplication` 被误启用 — 淘汰原因: 载荷进程的 `Bundle.main` 是目标 App，它的 Info.plist 里没有那个键。（键）
- [D 可行性] 并发写同一个文件，或已映射的文件被删除导致 SIGBUS — 淘汰原因: 「临时文件 + rename」和「先改名再删」都不会截断已映射的文件。（键、性能）
- [D 可行性] 符号表的行指向 `mappedStringTableBase`，所以没法存盘 — 淘汰原因: 行里存的是相对偏移，可以重定位。（性能）
- [D 可行性] 一次恢复七个镜像会超出 256 MB 的常驻上限 — 淘汰原因: 没有七个镜像合计大小的实测证据。（性能）
- [D 可行性] ObjC 的 `<invalid 0x…>`、ivar 偏移会带着滑动值打印 — 淘汰原因: 构造不出触发场景。（键）
- [D 可行性] Catalyst 进程的 `operatingSystemVersion` 与 macOS 编号不同 — 淘汰原因: 离线无法核实，而且清理只按 build 判断。（键、性能、范围）
- [G 代码一致性] 改原生工程却没同步 Tuist；新设置项缺 `accessPersistedValues()` — 淘汰原因: 提案既不新增 target，也不新增持久化设置。（集成）
- [G 代码一致性] 引用的路径与行号不存在 — 淘汰原因: 四位审查者都抽查过，全部存在且内容相符。（全体）
- [B 一致性] 决策日志说「后台补建照常显示」，line 174 说「不再作为构建出现」，二者矛盾 — 淘汰原因: 前者指 section 批次，后者指语料构建，说的不是一回事。（范围）
- [H 结构] 章节缺失 — 淘汰原因: 完整模板的各章节都在。（全体）
