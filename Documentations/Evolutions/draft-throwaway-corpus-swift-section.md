# Draft - 语料用一次性的 Swift section 打印

- **状态**: In Progress
- **创建日期**: 2026-11-09
- **最后更新**: 2026-11-09
- **实现分支 / PR**: `feature/throwaway-corpus-swift-section`（从 `origin/next` 切出）

## 摘要

没有派生数据的那次启动（新构建后的第一次启动），服务进程比读回派生数据的启动多占约 130 MB。实测下来，其中约 70 MB 是打印 Find 语料时被懒加载出来的 Swift 定义成员：MachOSwiftSection 的定义要到打印时才解析自己的方法、属性、访问器与字段，打印是唯一的触发点，而语料要把镜像里每个定义都打印一遍，解析结果就一直挂在内容区共用的那份索引上。读回派生数据不打印，这些定义保持未解析。本提案让语料改用一次性的 Swift section 打印，构建结束就整个丢掉，常驻的 section 不再被语料打印碰到。

## 方案

**实测**（2026-11-09，Mac Studio Ultra，Debug；两个进程依次模拟两次启动，都索引 My Mac 的 5 个 Always Index 镜像，常驻语料相同，都是 AppKit 与 libswiftCore 共 54.8 MB）：

| | 打印语料的启动 | 读回派生数据的启动 |
|---|---|---|
| footprint（活动监视器显示的内存） | 450 MB | 318 MB |
| malloc 在用 | 341 MB | 247 MB |
| 推出常驻语料后的 malloc 在用（索引完时都是 191 MB） | 290 MB | 191 MB |

两次启动的内存图按类型相减，打印那次多 91.8 MB 活对象：

- 约 70 MB：定义被打印时解析出的成员——`orderedMembers`、`functions`、`variables`、访问器与字段的数组，以及为成员符号造的单行 `SymbolTable`（8.5 万个，约 19 MB）。
- 约 14 MB：MachOSwiftSection 的 `SymbolIndexStore` 为打印建的「按 owner 查符号」表。
- 约 6 MB：字段布局与反解的缓存、ObjC 方法索引、Swift 运行时元数据。
- 其余约 40 MB 是 footprint 与 malloc 在用之差多出的部分：打印的中间产物与装不下而丢掉的语料释放后，页没还给系统（[0065](0065-engine-resident-memory.md) 实测过同一现象）。
- ObjC 一侧两次启动一样：ObjC 的成员在建索引时就已读出，打印不多留东西。

**改动**

1. 打印一个镜像的语料时，引擎另建一个这个镜像的 `RuntimeSwiftSection`：同一个镜像，同一份索引配置，不进 factory 的缓存，也不挂到聚合索引器上。这次构建的 Swift 对象列表与全部打印都走它；构建结束（建完、失败或取消）就丢掉，它解析出的成员随之释放。
2. 内容区、Inspector、交叉引用用的常驻 section 不被语料打印碰到，其中的定义只在用户打开时才解析，与读回派生数据的启动一样。
3. `RuntimeInterfaceCorpusBuilding` 的两个调用（`corpusObjects(in:)`、`corpusPrints(of:transformer:)`）改为每次构建先向引擎要一个打印上下文，对象列表与打印都向它要，`RuntimeInterfaceCorpusStore.run` 持有它到构建结束。ObjC 部分在上下文里照旧用常驻的 ObjC section。测试替身随之改。
4. 代价：每打印一个镜像的语料，要多建一遍它的 Swift 索引。符号库按镜像共享、不会重建，重建的是类型、协议、遵循与扩展这几遍；构建期间同时存在两份定义的外壳。只在真正打印时发生，读回派生数据时没有。

**没有询问就采用的假设**

- 打印结果与现在逐字节相同：同一份代码、同一个镜像、同一套配置。用户手动做过的泛型特化本来就不进语料（读回的语料也没有），一次性 section 里没有它们，不算变化。
- 只改 RuntimeViewer。上游那张约 14 MB 的符号查找表与约 6 MB 的小缓存这次不动；要省，另给 MachOSwiftSection 提一条让查找表可以淘汰的提案。
- 约 40 MB 的碎片不处理，理由见「不做」。

**不做**

- 让 MachOSwiftSection 的定义提供「放掉已解析成员」的接口：成员会被内容区与语料打印并发读取，原地清空就要把成员的存储改成可原子替换，改动的是上游定义模型的核心，比本提案大得多。
- 把语料打印放到单独的进程里（例如本地 service 另起一个专门打印的实例，打完就退出）：碎片也能一起消掉，首次启动能和第二次一样，但要新的进程生命周期、跨进程的进度与设置同步，属于架构改动，要做就另立完整提案。离线 service 不行：它从磁盘读镜像，打印结果与进程内的不同，搜索命中会对不上内容区。

**验收**

- 回归测试：建完一个 Swift 镜像的语料后，常驻 section 里的定义仍是未解析状态。改代码前先确认它是红的。
- 现有的语料、派生数据往返与快照测试全部通过：打印结果不变。
- 重跑同一探针：打印那次推出语料后的 malloc 在用，比索引完时多出的不超过 25 MB（现在多 99 MB）；footprint 只作参考，碎片会让它少降一部分。
- 记下 SwiftUI 语料构建多花的时间。

**落地步骤**

1. [x] 一次性 Swift section 与回归测试：factory 新增建一次性 section 的调用，`RuntimeInterfaceCorpusBuilding` 改为返回打印上下文，store 把打印阶段拆成单独一步、打完就放掉上下文，测试替身随之改。回归测试先在未改的代码上确认是红的，改完转绿；语料相关测试全过。
2. [ ] 验收与文档：Core 全量测试；重跑探针并记下 SwiftUI 语料构建的耗时；同步 `Documentations/DerivedData.md` 与语料仓库的注释。

探针是临时分支 `probe/derived-data-memory` 上的 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/DerivedDataMemoryProbe.swift`，用 `RUNTIMEVIEWER_MEMORY_PROBE_DIRECTORY=<空目录> swift test --skip-build --filter DerivedDataMemoryProbe` 运行；验收完删分支。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-09 | Created as Draft | 没有派生数据的那次启动，服务进程比读回派生数据的启动多占约 130 MB。用探针实测：约 92 MB 是打印语料留下的活对象，其中约 70 MB 是 Swift 定义被打印时解析出的成员；约 40 MB 是碎片。用户选择先写精简提案再修。 |
| 2026-11-09 | 选一次性 Swift section，不改上游定义模型，也不另起进程 | 一次性 section 只改 RuntimeViewer，与内容区不共享任何定义，没有并发问题。上游加释放接口要重做成员存储；单独进程能连碎片一起省，但属于架构改动。 |
| 2026-11-09 | 用户批准，开始实现；补上两个落地步骤 | 精简提案原本没有分步，按各自能构建验证的粒度拆开。 |
| 2026-11-09 | 提案随功能分支的第一个提交走，功能分支从 `origin/next` 切 | 本地 `next` 上有另一条线（Tuist 本地依赖模式）在本地合进来、还在等用户看过的提交；提案不能单独推到 `next`，功能分支也不该把那次合并带进来。 |
| 2026-11-09 | 回归测试先在未改的代码上确认是红的 | 建完 libswiftObservation 的语料后，常驻 section 里已解析的定义从 0 变成 59；改后保持 0。测试经 SwiftIndexing 的 `Support` SPI 读定义表。 |
| 2026-11-09 | 验收（内存）：活对象省下约 67 MB，未达 25 MB 的验收线，差额记在这里，不另改代码 | 同一探针、同一台 Ultra：打印那次的 footprint 由 448.7 MB 降到 380.1 MB，malloc 在用由 341.0 MB 降到 274.1 MB；推出常驻语料后比索引完时多 31.6 MB（改前 99 MB），比验收线多 6.6 MB。两次启动的内存图里定义对象数相同，一次性 section 没被留住；剩下的差额都是进程级缓存：符号查找表约 11 MB、反解节点约 3 MB、ObjC 方法层级约 2.6 MB、Swift 运行时元数据约 1.3 MB，以及字段布局、反解缓存与打印出的语料多出的容量。它们属于「不做」里的上游缓存；25 MB 这条线是按改前内存图估的，没有算全。 |
| 2026-11-09 | 验收（耗时）：多出的构建时间记在这里，不另优化 | Debug 测试进程里五个镜像的语料构建由 70.9 秒变成 119.4 秒：SwiftUI 25.0 → 32.4 秒、AppKit 12.7 → 32.3 秒、Foundation 9.3 → 24.3 秒。采样显示多出的时间在一次性 section 的 `prepare()` 里，其中约四分之一是测试进程独有的开销：MachOSwiftSection 给每个类型读一次 `@Dependency(\.symbolIndexStore)`，swift-dependencies 在测试进程里每读一次都 `dlsym` 找当前测试；App 进程里 `TestContext.current` 先看 `isTesting`，不走这条路，所以 App 里多出的时间比这里少。只在没有派生数据、真正打印时发生。 |
