# 0008 - ObjC 与 Swift 索引层的对称化

- **状态**: Implemented（验收标准 6「内存」实测无差异，动机三已作废，见「落地记录」）
- **作者**: JH
- **日期**: 2026-08-15
- **实现分支**: `next`（worktree `.claude/worktrees/RuntimeViewer`）
- **关联提案**:
  - [0007 - ObjC 关系索引归还应用侧](0007-objc-relationship-index-returns-to-application.md)
    —— **本提案取代 0007 的关系索引设计**，但保留其"渲染与解析层搬进库"的部分。两者的关系见「与 0007 的关系」一节。
  - MachOObjCSection [0003 - ObjC 关系反向表移出索引层，归还应用](https://github.com/MxIris-Reverse-Engineering/MachOObjCSection/blob/main/Documentations/Evolutions/0003-objc-relationship-tables-return-to-application.md)
    —— 库侧的前置改动，其设计论证不在此重复。

## 摘要

MachOObjCSection 把 ObjC 的解析、渲染和索引搬进了库，并移除了关系反向表。应用侧需要重建这些表。

0007 的做法是新增一个只服务于关系的 `RuntimeObjCRelationshipIndex`：从事件流累积事件、首次查询时才建表，同时删掉 `RuntimeObjCSectionFactory` 的聚合索引器，让 `RuntimeRelationshipsResolver` 自己逐 image 遍历。

本提案改为**让 ObjC 侧回到与 Swift 侧同构的形态**：`RuntimeObjCInterfaceIndexer` 作为库侧 `ObjCInterfaceIndexer` 的应用侧包装，与 `RuntimeSwiftInterfaceIndexer` 包装 `SwiftDeclarationIndexer` 逐条对应——同样的 `upstream` + `@dynamicMemberLookup` 转发、同样的 eager 反向表、同样的 `addSubIndexer` / `removeSubIndexer` 聚合、同样由 factory 持有聚合器。`RuntimeRelationshipsResolver` 相应地从"遍历所有 image"退回成"查两次聚合器"。

对用户没有可见变化：Relationships 面板的内容与顺序保持逐条等价。

## 动机

### 一、main 上两侧本来是对称的，0007 单方面打破了它

`main` 上两个索引层是刻意对称的，`RuntimeSwiftInterfaceIndexer` 的 doc comment 里逐条写着"Mirrors `ObjCInterfaceIndexer`"：

| | ObjC（main） | Swift（main） |
|---|---|---|
| 类型 | `RuntimeObjCInterfaceIndexer`（628 行） | `RuntimeSwiftInterfaceIndexer`（285 行） |
| 关系反向表 | 有，`prepare()` 中 eager 建 | 有，`prepare()` 中 eager 建 |
| 聚合 | `addSubIndexer` + `subIndexers` fan-out | 同左 |
| 聚合器持有者 | `RuntimeObjCSectionFactory` | `RuntimeSwiftSectionFactory` |

0007 之后，ObjC 侧变成：没有包装类型（`RuntimeObjCInterfaceIndexer` 整个删除）、关系表 lazy 建、没有聚合器。Swift 侧原封不动。于是同一个 `RuntimeRelationshipsResolver` 里出现两套取数方式，`relationships(for:)` 的循环体里全是 `isObjCClass` / `isSwiftClass` 的分叉。

**对称本身是有价值的**：两侧的差异越小，一处发现的缺陷就越容易在另一处被找到并同样修掉。`removeSubIndexer` 的缺失就是这样被发现的（见下文第四点）。

### 二、关系查询退化成 N 次 per-image 查找

0007 删掉聚合器的理由是它"只写不读"——每个 per-image 索引器都注册进去，却没有任何地方查询它。这个观察是对的，但由此得出的结论走反了方向：**正确的修法是让 resolver 去读它，而不是把它删掉。**

删掉之后，`RuntimeRelationshipsResolver.relationships(for:)` 只能自己遍历 `indexedImagePaths()`：

```swift
for imagePath in await indexedImagePaths() {          // 数百个 image
    if let objcSection = await objcSectionFactory.existingSection(for: imagePath) {   // 每次一跳 actor
        for reference in objcSection.objcRelationshipIndex.subclasses(of: objcKey) { … }
    }
    if let swiftSection = await swiftSectionFactory.existingSection(for: imagePath) { // 又一跳
        …
    }
}
```

查一次 `NSObject` 的子类，就是数百轮循环、每轮两次跨 actor 调用、两次字典查找，其中绝大多数 image 对这个 key 返回空。而 Swift 侧的聚合器本来就能一次查全（`RuntimeSwiftSection.swift:268` 每个 section 都把自己注册了进去），resolver 却没用它。

### 三、事件数组常驻内存

`RuntimeObjCRelationshipIndex` 把事件先存进 `pendingEvents`，直到**首次查询**才回放建表并释放：

```swift
func record(_ event: ObjCIndexingEvent) {
    …
    if tables != nil { apply(event, into: &tables!) } else { pendingEvents.append(event) }
}
```

0007 明确说这是个权衡：热路径上"一次 append 比库原来的两次字典查找加 `OrderedSet.append` 更便宜"。问题在于收益和代价不对称——

- **代价是常驻的**：绝大多数 image 的 Relationships 面板永远不会被打开，它们的 `pendingEvents` 就永远不会被释放。后台索引（提案 0002）又会主动索引依赖闭包里的所有 image，所以这是默认路径而非边缘情况。
- **收益是一次性的**：省下的是 parse 期间的几次字典操作。

而且事件数组比它折叠成的表**更大**：表做了按 key 聚合和 `OrderedSet` 去重，事件数组没有。

> **已测量（2026-08-15）——这条动机不成立，见「落地记录」。**
>
> 实测结果是两种方案的进程 footprint **分辨不出差异**：三次重复测量各自的波动范围
> （0007 为 [133.08, 138.80] MB，0008 为 [133.42, 137.61] MB）几乎完全重叠，均值只差
> 0.51 MB。事件数组相对于索引数据总量（约 135 MB）太小，被噪声淹没。
>
> 上面关于"代价常驻、收益一次性"的结构描述本身没有错——`pendingEvents` 确实到首次查询才释放
> ——但它带来的**内存收益小到测不出来**，因此不构成做这次改动的理由。按本提案自己定的规矩，
> 本条动机作废。第一、二、四条（对称性、遍历退化、handler 可遗漏）不依赖它，仍然成立，
> 并且足以支撑本提案。
>
> 即时折叠仍然保留，但理由改为它更简单：`prepare()` 返回即表完整，没有第二个步骤可以忘记，
> 也没有"查询发生在走查中途"这个需要单独处理的时序（0007 为此写了一段专门的分支）。

### 四、"忘了装 handler" 是设计问题，不是文档问题

0007 的 commit message 用了一整段解释这个坑：`eventHandler` 从旁观者变成了关系数据的**唯一**通道，而 `RuntimeObjCSection` 原本只在有 progress stream 时才装 handler；七个 section 创建点里六个不传 stream，照旧写法会让几乎每个 image 的关系面板静默变空，**而且照样编译、照样过大部分测试**。

0007 的修法是把 handler 改成无条件安装，并写一大段注释警告后人别改回去。但只要 `ObjCInterfaceIndexer` 是由调用方构造并自行传入 handler 的，这个坑就一直敞着。

Swift 侧不存在这个问题，因为 `RuntimeSwiftInterfaceIndexer` 在自己的 `init` 里构造 upstream：

```swift
init(machO: MachOImage, eventHandlers: [SwiftIndexEvents.Handler] = []) {
    self.upstream = .init(configuration: …, eventHandlers: eventHandlers, in: machO)
}
```

调用方拿不到一个"没装 handler 的 upstream"。对称化顺带把这个坑从"靠注释提醒"变成"类型上不可能"。

### 非目标

- **不**改变 Relationships 面板的任何用户可见行为——内容、顺序、跨 image 语义全部保持等价。
- **不**动 0007 已完成的"渲染与解析层搬进库"部分。`ObjCInterfaceBuilder`、`ObjCDeclarationRendering`、`ObjCOutputTransformer` 留在库侧，本提案不把它们搬回来。
- **不**改库侧接口。`ObjCIndexingEvent` 与 `ObjCInterfaceIndexer` 按 0.8.104 现状使用，不要求 MachOObjCSection 再发版。
- **不**重构 `RuntimeObjCSection` 的其余职责（`allObjects` / `interface` / `memberAddresses` / `classHierarchy`）。它们与关系索引正交，拆分另开提案。
- **不**引入跨 image 的单一全局表。那是比"聚合器 fan-out"更快的形态，但它两侧都不像现状，会同时改写 Swift 侧的存储结构；见「替代方案考量 A」。

## 提议方案

### 对称结构

```
              库侧 upstream（只解析，不记忆关系）      应用侧包装（关系表 + 聚合）
ObjC     ObjCInterfaceIndexer (MachOObjCSection)  ←  RuntimeObjCInterfaceIndexer
Swift    SwiftDeclarationIndexer (MachOSwiftSection) ← RuntimeSwiftInterfaceIndexer
                                                        ↑ factory 持有 aggregate
                                              RuntimeRelationshipsResolver 各查一次
```

两个包装类型的骨架逐条对应：

| 成员 | ObjC | Swift |
|---|---|---|
| upstream | `let upstream: ObjCInterfaceIndexer` | `let upstream: SwiftDeclarationIndexer<MachOImage>` |
| 转发 | `@dynamicMemberLookup` → upstream | 同左（已有） |
| 反向表 | `@Mutex` 保护，eager | 同左（已有） |
| 建表时机 | handler 内折叠，`prepare()` 返回即完整 | `prepare()` 内一次性建 |
| 聚合 | `subIndexers` + `addSubIndexer` / `removeSubIndexer` | 同左 |
| 聚合器持有 | `RuntimeObjCSectionFactory.indexer` | `RuntimeSwiftSectionFactory.indexer` |

### `RuntimeObjCInterfaceIndexer`

```swift
@dynamicMemberLookup
final class RuntimeObjCInterfaceIndexer: @unchecked Sendable {
    /// upstream 由本类型在 init 内构造，外部无从旁路。这是关系数据
    /// 唯一的来源保证：不存在"没装 handler 的 upstream"。
    let upstream: ObjCInterfaceIndexer

    @Mutex private var subclassesByClassName: [String: OrderedSet<RuntimeObjCClassReference>] = [:]
    @Mutex private var conformingClassesByProtocolName: [String: OrderedSet<RuntimeObjCClassReference>] = [:]
    @Mutex private var subIndexers: [RuntimeObjCInterfaceIndexer] = []

    init(machO: MachOImage, imagePath: String, progressContinuation: LoadingEventContinuation? = nil) {
        // 两阶段构造：handler 需要捕获 self，故先建表容器再建 upstream。
        let tables = Tables()
        self.tables = tables
        self.upstream = ObjCInterfaceIndexer(machO: machO, imagePath: imagePath) { event in
            tables.fold(event)                       // ← 直接折叠，不缓存事件
            progressContinuation?.forward(event)     // ← 仅进度转发是可选的
        }
    }

    func prepare() async throws { try await upstream.prepare() }

    subscript<Value>(dynamicMember keyPath: KeyPath<ObjCInterfaceIndexer, Value>) -> Value {
        upstream[keyPath: keyPath]
    }

    func subclasses(of className: String) -> [RuntimeObjCClassReference] { /* self + subIndexers fan-out */ }
    func conformingClasses(toProtocol name: String) -> [RuntimeObjCClassReference] { /* 同上 */ }

    func addSubIndexer(_ subIndexer: RuntimeObjCInterfaceIndexer) { … }
    func removeSubIndexer(_ subIndexer: RuntimeObjCInterfaceIndexer) { … }
}
```

要点：

1. **事件直接折叠，不留 `pendingEvents`。** 折叠在锁内进行，代价是热路径上两次字典查找加一次 `OrderedSet.append`——即库移除反向表之前它自己做的那份工作。

   > **落地后修正**：本条原写作"对第三点动机（内存）的直接兑现"。动机三经实测不成立（见该节与「落地记录」），
   > 因此保留即时折叠的理由改为**它更简单**：`prepare()` 返回即表完整，没有第二个步骤可以忘记，
   > 也不存在"查询发生在走查中途"这一需要单独分支处理的时序。这不是事后找补——它本来就是折叠方案
   > 附带的性质，只是当初把内存当成了主要论据。
2. **顺序保证不受影响。** 库承诺发射顺序稳定但不承诺执行线程，所以折叠必须在锁内。锁内折叠与 0007 的锁内 append 一样是串行的，`OrderedSet` 的插入顺序仍然等于事件到达顺序。
3. **`upstream` 用 `let` 且在 `init` 内构造**，handler 无从遗漏（动机第四点）。
4. **`RuntimeObjCClassReference` 保持 internal、非 Codable。** 与 0007 一致：关系引用不跨进程，跨 XPC 的是已物化的 `RuntimeObject`。

### 三个等价性性质原样保留

0007 识别出的三条必须复现的性质继续成立，且各自保留其单元测试：

1. 内联采纳与 category 贡献的采纳落进**同一张**表。
2. 事件按到达顺序折叠，内联采纳排在 category 之前。
3. `OrderedSet` 按三个字段整体去重，而非只按 `className`——同一个类可以因 `isSwiftStable` 不同而合法地出现两次。

### 生命周期：`addSubIndexer` / `removeSubIndexer` 必须成对

这是恢复聚合器必须同时解决的问题，也是对称化带来的第一个直接收益。

`main` 上两侧都只有 `addSubIndexer`、没有逆操作，于是 `removeSection(for:)` 丢掉 `sections` 条目后什么也没释放——聚合器仍持有该 image 的索引器，而聚合器活得和 engine 一样久。#101（`feature/node-store-adoption`）的 `f41648a` 已经诊断并修复了这一点，给**两侧**都加了 `removeSubIndexer`，并在两个 factory 的 `removeSection` / `removeAllSections` 里先摘除再丢条目，同时从 `RuntimeEngine.stop()` 调用拆卸。

0007 绕开了这个问题——它删掉了 ObjC 侧的聚合器，"没有聚合就没有可摘除的东西"。本提案既然把聚合器请回来，就**必须**同时承接 `f41648a` 的修复，否则会重新引入它修掉的泄漏。

因此本提案与 #101 之间存在明确的接口约定：

- 若 #101 先落地，本提案直接沿用其 `removeSubIndexer`，只需保证新的 `RuntimeObjCInterfaceIndexer` 实现了它并接进 factory 的拆卸路径。
- 若本提案先落地，则 `removeSubIndexer` 及其两个 factory 调用点由本提案自带，#101 落地时相应去重。

无论顺序如何，**"聚合器有加无减"这个状态一天都不允许存在于集成分支上。**

### `RuntimeRelationshipsResolver` 简化

`relationships(for:)` 的 image 遍历整个消失，退回成对两个聚合器各一次查询：

```swift
// 之前：for imagePath in await indexedImagePaths() { …两次 actor 跳转… }
// 之后：
if wantsSubclasses, let objcKey {
    for reference in await objcSectionFactory.indexer.subclasses(of: objcKey) {
        if let object = await materializeRelationshipReference(reference) { subclasses.append(object) }
    }
}
```

物化逻辑（`materializeRelationshipReference`、`isSwiftStable` 决定物化成 Swift 还是 ObjC 对象、`@objc(customName)` 失败时丢弃而非降级）原样保留，不在本提案范围内。

`indexedImagePaths()` 随之失去唯一调用方。**需要在落地时确认它是否还有别的语义价值**（它表达的是"两侧 section 都已缓存"这个"完全索引"判据），无用则一并删除，有用则保留并注明新的用途。

### 依赖 pin

0007 的落地记录里写着它被 pin 阻塞：MachOSwiftSection 0.15.0 把 MachOObjCSection 锁在 `exact` 0.8.102，因此只能靠 `USING_LOCAL_DEPENDENCIES=1` 构建，无法进 main。**该阻塞现已解除**：

| 依赖 | 0007 分支的 pin | 本提案的 pin | 说明 |
|---|---|---|---|
| MachOObjCSection | 0.8.102 | **0.8.104** | 移除反向表的 `0b2a2f5` 在 **0.8.103** 才进入；0.8.102 里 `subclasses(of:)` 与 `ObjCClassReference` 仍然存在。0.8.104 另含 `edac0da fix: strip synthesized setters using their real selector`。 |
| MachOSwiftSection | 0.15.0 | **0.15.1** | `e95942c8 chore(deps): require MachOObjCSection as a range, not an exact pin` 解除了 exact 锁。 |

也就是说 **0007 分支当前的 pin 与其代码互相矛盾**：代码假定库已移除反向表，pin 指向的却是仍带反向表的版本。本提案落地时以 0.8.104 + 0.15.1 为准，届时可对着远端 pin 正常 resolve，不再需要 `USING_LOCAL_DEPENDENCIES=1`，因而**可以直接走 main，不必只能进 next**。

### 与 0007 的关系

0007 是两件事打包在一条分支上：

1. **渲染与解析层搬进库** —— `RuntimeObjCSection` 从 617 行降到 471 行，`ObjCDump+SemanticString.swift`（896 行）等搬走。**本提案保留这部分，不推翻。**
2. **关系索引的重建方式** —— `RuntimeObjCRelationshipIndex` + 删聚合器 + resolver 自己遍历。**本提案取代这部分。**

按项目约定，0007 保持原貌不回改；其状态在本提案被接受时更新，并在头部登记「被 0008 取代（关系索引部分）」。0007 的三个等价性单元测试与那份 `relationships-baseline.txt` 基线快照**继续使用**——它们验证的是行为而非实现，正是本提案需要的回归网。

## 影响（App 型）

- **用户可见变化**：无。Relationships 面板内容与顺序逐条等价，由基线快照强制。
- **可发现性**：无新增入口。
- **数据与配置兼容**：无持久化格式变化。`RuntimeObjCClassReference` 不跨进程、不入库。
- **平台与最低版本**：不变。
- **发布影响**：依赖 pin 推进到 MachOObjCSection 0.8.104 / MachOSwiftSection 0.15.1，随本提案同批次落地。

## 验收标准

1. `relationships(for:)` 对 `relationships-baseline.txt` 逐条等价——307 个 `NSObject` 子类、9 个 `NSCoding`、68 个 `NSCopying`，顺序与 `imagePath` 完全一致。
2. 三条等价性性质各有单元测试（沿用 0007 的三个测试）。
3. 无 progress stream 构造的 section 仍然产出完整关系数据（沿用 0007 的 `RelationshipsWithoutProgressStreamTests`）。
4. `RuntimeObjCInterfaceIndexer` 与 `RuntimeSwiftInterfaceIndexer` 的公开成员集合逐条对应，差异只允许出现在两种语言本身的差异上，且每处差异有注释说明。
5. `removeSection` / `removeAllSections` / `RuntimeEngine.stop()` 之后，聚合器不再持有该 image 的索引器（引用计数或 memory graph 验证）。
6. 索引后未查询关系的稳态内存不高于 0007 方案（对应动机第三点的实测要求）。
7. 对着远端 pin 干净 resolve，不依赖 `USING_LOCAL_DEPENDENCIES=1`。

## 风险与假设

### 风险

- **热路径变慢**：折叠比 append 贵。量级上这是每个类每个协议几次字典操作，与库移除反向表之前的成本相同，因此上界是已知的历史基线。需在落地时用后台索引全量跑一遍确认无回归。
- **与 #101 的接口**：`removeSubIndexer` 由谁提供取决于落地顺序，见上文。**这是本提案唯一的跨分支硬依赖，不能靠合并时自然消解。**
- **与 #101 的代码冲突**：两条线都重写 `RuntimeObjCInterfaceIndexer.swift`。本提案实际上是把该文件从 0007 的"删除"状态改回"存在但重写"，与 #101 对同一文件的修改必然冲突，需要人工合并而非择一。
- **对称是目标而非教条**：两侧的 upstream 能力不同（Swift 侧 upstream 自带 `conformingTypesByProtocolName`，ObjC 侧完全靠事件流），强行对齐到最后一行会制造无意义的包装。验收标准 4 因此只要求公开成员对应，并允许带注释的差异。

### 假设

- 库承诺的事件发射顺序稳定（`ObjCIndexingEvent` 的 doc comment 明确声明"Changing the order is a breaking change"）。折叠顺序依赖此承诺。
- `categoryConformanceIndexed` 的 `imagePath` 指向声明 category 的 image 而非目标类的 image，这一不对称是库刻意保留的，本提案原样透传，不"修正"。

## 替代方案考量

### A. 引擎级跨 image 单一全局表

一张表、image 索引完成时整块提交、卸载时整块移除，查询是一次 `O(1)` 查找而非 fan-out 到 N 个 sub-indexer。ObjC 与 Swift 共用同一张表，靠 key 的 enum 区分，`relationships(for:)` 里那堆 `isObjCClass` / `isSwiftClass` 分叉也一并消失。

**这在性能与代码量上都优于本提案**，但它要求同时改写 Swift 侧的存储结构，而 Swift 侧的 `subclassesBySuperclassMangledName` / `typeNameByMangledName` / `protocolNameByMangledName` 与 `RuntimeSwiftSection` 的多处读取耦合，且 `feature/node-store-adoption` 正在改动同一批代码。

本提案先把两侧拉回同构——这是走向 A 的前置条件而非替代品：两侧同构之后，A 变成一次机械替换，而不是同时改两套不同的东西。**A 应在本提案落地后单独立案。**

### B. 保留 0007 的 lazy 事件累积，只补回聚合器

改动最小，能解决动机第二点（遍历）但不解决第三点（内存）和第四点（handler 可遗漏），也不恢复对称。既然要动这块代码，一次做到位。

### C. 让库继续持有反向表

即请求 MachOObjCSection 回退 0003。库侧的取舍已在 0003 论证完毕（库负责解析与广播，不负责记忆领域关系），不在此重开。

## 测试策略

- **等价性回归**：`RelationshipsEquivalenceSnapshotTests` + `relationships-baseline.txt` 原样沿用。基线是在 pin 移动**之前**通过 `relationships(for:)` 抓取的，是唯一在改动两侧都存在的观测点，因此对本提案同样有效。
- **性质测试**：`RuntimeObjCRelationshipIndexTests` 的三条性质迁移到新类型上。
- **无 stream 路径**：`RelationshipsWithoutProgressStreamTests` 沿用。
- **对称性**：新增一个测试或 lint，断言两个包装类型的公开成员集合对应（验收标准 4）。形式待定——可能只是一份带注释的清单，自动化的收益未必抵得上维护成本。
- **生命周期**：新增测试覆盖 `removeSection` 后聚合器不再持有该 image 索引器（验收标准 5）。
- **内存**：索引 AppKit 量级 image 后不查询关系，对比稳态占用（验收标准 6）。非自动化，用 Instruments 记录数值到落地记录。

## 落地步骤

1. 推进 pin 到 MachOObjCSection 0.8.104 / MachOSwiftSection 0.15.1，确认远端 resolve 干净。
2. 新建 `RuntimeObjCInterfaceIndexer`（关系表 + 聚合 + upstream 包装），迁移 0007 的三条等价性性质。
3. `RuntimeObjCSectionFactory` 恢复 `indexer` 聚合器，section 创建时注册。
4. 接上 `removeSubIndexer` 拆卸路径（与 #101 协调，见「生命周期」）。
5. `RuntimeRelationshipsResolver` 改为查聚合器，删除 image 遍历；判定 `indexedImagePaths()` 去留。
6. 删除 `RuntimeObjCRelationshipIndex`。
7. 跑基线等价性 + 三条性质 + 无 stream 路径测试。
8. 测内存与后台索引耗时，数值记入落地记录。
9. 更新 0007 头部，登记「关系索引部分被 0008 取代」。

## 落地记录（2026-08-15，分支 `next`）

### 提交

| commit | 内容 |
|---|---|
| `84b3e58` | 本提案落盘并接受 |
| `6cf23b0` | 合并 `feature/objc-rendering-and-indexing`，pin 推进到 0.8.104 / 0.15.1 |
| `801be38` | 对称化本体 |
| `3421d87` | 两侧差异的说明落成文字 |

### 验收标准结果

| # | 标准 | 结果 |
|---|---|---|
| 1 | 基线逐条等价 | ✅ `RelationshipsEquivalenceSnapshotTests` 通过，基线未改动 |
| 2 | 三条性质各有测试 | ✅ 迁移至 `RuntimeObjCRelationshipTablesTests`（测 `fold(_:)`） |
| 3 | 无 progress stream 路径 | ✅ `RelationshipsWithoutProgressStreamTests` 通过 |
| 4 | 两侧公开成员对应 | ✅ 5 处差异，逐条写入 `RuntimeObjCInterfaceIndexer` 的 doc comment |
| 5 | 拆卸后聚合器不再持有 | ✅ 新增 `IndexAggregateLifecycleTests`（3 例，ObjC + Swift） |
| 6 | 内存不高于 0007 | ⚠️ **测不出差异**，见下 |
| 7 | 远端 pin 干净 resolve | ✅ `USING_LOCAL_DEPENDENCIES` 未设时 resolve + build + 394 测试全过 |

### 验收标准 6：结论是「测不出来」

加载 libobjc + Foundation + AppKit + CoreFoundation（5735 个对象），索引完成后**不查询关系**，
测 `phys_footprint` 相对进程基线的增量，各重复三次：

| | run 1 | run 2 | run 3 | 均值 | 范围 |
|---|---|---|---|---|---|
| 0007（事件队列） | 137.16 | 138.80 | 133.08 | 136.35 | [133.08, 138.80] |
| 0008（即时折叠） | 133.42 | 137.61 | 136.50 | 135.84 | [133.42, 137.61] |

单位 MB。两组范围几乎完全重叠，均值差 0.51 MB，**远小于各自 4 MB 以上的组内波动**。

第一次测量得到 137.16 vs 133.42（差 3.73 MB）看起来像是收益，重复之后才看出那是噪声。
**只跑一次就会得出错误结论**，这一点值得记下来。

要真正量出事件数组本身的大小，需要对该数组插桩，而不是测整个进程 footprint——索引数据总量
（约 135 MB）比事件数组大一个量级以上，后者在前者的波动里没有信号。本提案没有做这个插桩：
动机三既然作废，它就不再是决策依据，为一个已经不影响结论的数字加插桩没有价值。

**这不影响本提案的其余部分。** 动机一（两侧不对称）、二（关系查询退化成 N 次 per-image 查找）、
四（handler 可被遗漏）都不依赖内存论证，且都已在实现中兑现。

### 实现过程中发现的问题

**`machO.imagePath` 与 factory 的缓存键不是同一个字符串。** 两个 factory 都按
`DyldUtilities.patchImagePathForDyld` 产出的 dyld-canonical path 建键，而 `machO.imagePath`
是 dyld 报告的原始路径。原先的 per-image 走查全程只用 canonical path，所以从未暴露；改成聚合
查询后，引用需要自带来源 image，一旦用 `machO.imagePath` 打标，`existingSection(for:)` 就找不
到对应 section，**所有 Swift 关系结果被静默丢弃**。

表现为 `RelationshipsTests` 两例失败（`anchor == nil`），而 ObjC 侧一切正常——因为
`RuntimeObjCInterfaceIndexer` 一直是显式接收 canonical `imagePath` 的。修法即对称化本身：
`RuntimeSwiftInterfaceIndexer` 也改为 `init(machO:imagePath:)`。

这是一个只有端到端测试能抓到的错误：类型正确、编译通过、单元测试全绿，只是结果为空。

### 尚未接通的部分

`removeSection` / `removeAllSections` 在本分支**没有任何生产调用方**——把 teardown 接进
`RuntimeEngine.stop()` 的是 `feature/node-store-adoption` 的 `f41648a`。因此本提案加的 detach
逻辑正确但尚未被触发，目前只有 `IndexAggregateLifecycleTests` 在验证它。

这不改变「聚合器有加无减不允许存在」的结论：等 #101 落地时 teardown 一接上，detach 立即生效，
而不是到那时才发现没有逆操作。
