# 0007 - ObjC 关系索引归还应用侧

- **状态**: 部分 Implemented，部分被 [0008](0008-symmetric-objc-and-swift-index-layers.md) 取代
  - **渲染与解析层搬进库** —— Implemented，随 `6cf23b0` 合入 `next`，**保留**
  - **关系索引的重建方式**（`RuntimeObjCRelationshipIndex`、删除工厂聚合、resolver 逐 image 遍历）
    —— **被 0008 取代**，实现已于 `801be38` 移除
- **作者**: JH
- **日期**: 2026-08-10
- **关联提案**: MachOObjCSection [0003 - ObjC 关系反向表移出索引层，归还应用](https://github.com/MxIris-Reverse-Engineering/MachOObjCSection/blob/main/Documentations/Evolutions/0003-objc-relationship-tables-return-to-application.md)
  —— **本提案是它的下游适配**，库侧的设计论证不在此重复
- **实现分支 / PR**: `next`（[PR #102](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/pull/102) 合入 `6cf23b0`）

> **本文按项目约定保持原貌，不回改以符合最终实现。** 下面正文描述的关系索引方案已不是代码的
> 现状，它记录的是当时的决策与理由，包括那个被 0008 判定为"应该由类型系统排除、而非由注释警告"
> 的 handler 安装风险——0008 的动机四正是从这里来的。
>
> 两点当时的判断已被事实修正，记在这里而不改正文：
>
> 1. **头部原写"合入 main 阻塞于 MachOSwiftSection 的 pin"**。该阻塞已解除：MachOObjCSection
>    `0.8.103` / `0.8.104` 与 MachOSwiftSection `0.15.1`（其 `e95942c8` 去掉了 exact 锁）均已发布。
> 2. **本分支的 pin 与其代码互相矛盾**：`Package.swift` 要求 `exact: 0.8.103`，`Package.resolved`
>    却停在 `0.8.102`，而 `0.8.102` 里 `subclasses(of:)` 与 `ObjCClassReference` 仍然存在——移除
>    反向表的 `0b2a2f5` 要到 `0.8.103` 才进去。合并时已按 0008 统一到 `0.8.104` / `0.15.1`。

## 摘要

MachOObjCSection 0003 把 ObjC 的继承 / 协议遵守反向表移出 `ObjCIndexing`，库改为只通过
`ObjCIndexingEvent` 广播发现、不再自己存表。本提案是 RuntimeViewer 侧的对应改动：

1. 新增 `RuntimeObjCRelationshipIndex`，在 `prepare()` 期间由事件流填充，取代原先直接查库的两个方法；
2. **把事件 handler 的安装与进度转发解耦** —— 这是本提案真正的风险点，不改会让绝大多数 image
   的关系数据静默变空；
3. 删除 `RuntimeObjCSectionFactory.objcInterfaceIndexer` 这个只写不读的聚合。

对用户没有任何可见变化：Relationships 标签页的内容与顺序保持逐条等价。

## 动机

### 一、库不再存表，应用必须自己存

0003 之后 `ObjCInterfaceIndexer` 不再有 `subclasses(of:)` / `conformingClasses(toProtocol:)`，
`ObjCClassReference` 类型也一并移除。`RuntimeRelationshipsResolver.swift:85` 与 `:118` 附近对
ObjC 关系的查询失去后端，必须在应用侧重建。

方向与取舍（为什么是事件流而不是重新走查、为什么 `isSwiftStable` 进 payload）已在 0003
论证完毕，本提案直接采用其结论，不重复。

### 二、事件 handler 现在是**条件安装**的，照搬会静默丢掉几乎全部关系数据

这是本提案存在的主要理由，也是唯一一处不改就出错的地方。

`RuntimeObjCSection.makeEventHandler(forwardingTo:)` 目前在没有进度流时直接返回 `nil`：

```swift
private static func makeEventHandler(
    forwardingTo progressContinuation: LoadingEventContinuation?
) -> (@Sendable (ObjCIndexingEvent) -> Void)? {
    guard let progressContinuation else { return nil }   // ← 没有进度流就完全不装 handler
    ...
}
```

今天这没有任何后果 —— 库无条件建表，handler 只负责转发进度。0003 之后，**没装 handler 就等于
放弃关系数据**。

而实际的调用点分布是压倒性的：创建 ObjC section 的 7 处调用里，只有 1 处传了
`progressContinuation`。

| 调用点 | 传 `progressContinuation`？ |
|---|---|
| `RuntimeEngine.swift:883` | ✅ 唯一一处 |
| `RuntimeEngine+BackgroundIndexing.swift:62` | ❌ |
| `RuntimeEngine.swift:534` | ❌ |
| `RuntimeEngine.swift:810` | ❌ |
| `RuntimeEngine.swift:572 / 574 / 626 / 628`（按名字查的四处） | ❌ |

其中 `RuntimeEngine+BackgroundIndexing.swift:62` 是**后台索引**的路径 —— 绝大多数 image 是被
它带进来的。所以直接照搬现有 handler 的结果不是「某个冷门路径缺数据」，而是「只有用户手动触发
那一次带进度条的加载有关系数据，其余全空」，且**完全静默**：不报错，Relationships 标签页看起来
就像"这个类确实没有子类"。

结论：handler 的安装必须与 progressContinuation 解绑。

### 三、工厂聚合是只写不读的死重，一并删除

`RuntimeObjCSectionFactory` 持有一个聚合 `ObjCInterfaceIndexer` 并在每次建 section 时
`addSubIndexer` 注册，但全仓库对它的引用只有四处 —— 声明（`RuntimeObjCSection.swift:379`）、
构造（`:383`）、两处 `addSubIndexer`（`:411`、`:432`），**没有任何一处读它**。真正的跨 image
合并是 `RuntimeRelationshipsResolver` 在调用点自己做的：遍历已索引 image 路径，逐个取该 image
自己的 indexer 查表。

0003 删掉库侧的 `addSubIndexer(_:)` 后这个聚合无法再构造，正好一并删除。附带收益是那个
「拿 `MachOImage.current()` 当占位」的构造 hack（`:381-384`）随之消失。

**Swift 侧不受影响**：`RuntimeSwiftSectionFactory.indexer` 是真被读的（`GenericSpecializer` /
`IndexerConformanceProvider` 走 `factory.indexer.upstream`，泛型特化还查 `allAllTypeDefinitions`），
是承重结构，本提案不碰。

### 四、它解掉一个已埋下的跨分支冲突

feeder 分支 `feature/node-store-adoption`（同时在 `next` 上）的 commit `f41648a` 修的是聚合造成的
内存泄漏 —— `addSubIndexer` 没有逆操作，聚合活得和 engine 一样长，浏览过的每个 image 的索引状态
永远释放不掉。它的修法是给本地的 `RuntimeObjCInterfaceIndexer` 加 `removeSubIndexer(_:)`，并在
`removeSection` / `removeAllSections` 里先摘再删。

但 main 上的 `889f1bd` 已经把 `RuntimeObjCInterfaceIndexer` 整个删了，顶替它的库类型没有
`removeSubIndexer`。两条线迟早要撞。

本提案把聚合整个删掉，泄漏源消失，逆操作不再需要 —— 冲突以「删除」的方式解决，而不是回头给库补
一个即将过时的 API。

> **合并提示**：`feature/node-store-adoption` 与 main 合并时，`RuntimeObjCSectionFactory`
> 的 `removeSection` / `removeAllSections` 里那两行 `objcInterfaceIndexer.removeSubIndexer(...)`
> 应当**随聚合一并删除**，不要试图移植到库类型上。Swift 侧那一半（`RuntimeSwiftSectionFactory`）
> 不受影响，正常保留。

## 提议方案

### 一、`RuntimeObjCRelationshipIndex`：应用侧的关系索引

新增一个 per-image 的关系索引，职责单一：接收 `ObjCIndexingEvent` 的三个关系事件，攒成两张表，
并提供原先由库提供的两个查询。

- 位置：`RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/`
  （放在 Relationships 而非 Indexing —— 它服务的是关系解析，不是接口解析）
- 与 `ObjCInterfaceIndexer` 一一对应：每个 `RuntimeObjCSection` 持有自己那一份
- 同时新增 `RuntimeObjCClassReference`，字段与原库类型逐字相同（`className` / `imagePath` /
  `isSwiftStable`），因为 `RuntimeRelationshipsResolver.materializeRelationshipReference(_:)`
  已经按这三个字段消费

### 二、handler 解耦：永远安装，进度转发才看 continuation

`makeEventHandler` 改为**总是**返回 handler。handler 内部分流：关系事件喂给
`RuntimeObjCRelationshipIndex`，`.progress` 事件仅在 continuation 存在时转发。

### 三、删除工厂聚合

删除 `RuntimeObjCSectionFactory.objcInterfaceIndexer` 的声明、构造与两处 `addSubIndexer` 调用。

### 非目标

- **不改 Relationships 的任何用户可见行为。** 顺序、内容、去重规则逐条等价。
- **不改 category 的 `imagePath` 语义。** 库侧 0003 已说明：category 产生的引用里 `className`
  与 `imagePath` 不属于同一个 image（`imagePath` 是 category 所在 image）。这是既有行为，
  原样保留；想改属行为变更，另开提案。
- **不动 Swift 侧。** `RuntimeSwiftInterfaceIndexer` 及其三张表保持现状。
- **不改 `RuntimeRelationshipsResolver` 的跨 image 扇出结构。** 它在调用点遍历 image 的做法不变，
  只把查询对象从 `objcSection.objcIndexer` 换成 `objcSection.objcRelationshipIndex`。
- **不引入新的关系查询能力**（如反向的「某类的所有超类」）。等价迁移，不夹带。
- **不"顺手"修同类双 `isSwiftStable` 的重复条目。** 见「详细设计」等价性细节第 3 条 ——
  那是现有行为，修它属于行为变更，会让等价性测试失败。

## 详细设计

### `RuntimeObjCRelationshipIndex`

```swift
/// An Objective-C class or bridged Swift class discovered to subclass another
/// class or to adopt a protocol.
///
/// `isSwiftStable` carries the structural signal (`class_t`'s
/// `FAST_IS_SWIFT_STABLE` bit) that lets `RuntimeRelationshipsResolver` decide
/// whether to materialize the reference as a Swift `RuntimeObject` or an
/// Objective-C one. The library reports the bit; the domain decision is made here.
struct RuntimeObjCClassReference: Hashable, Sendable {
    let className: String
    let imagePath: String
    let isSwiftStable: Bool
}

/// Per-image Objective-C relationship index, populated from the
/// `ObjCIndexingEvent` stream that `ObjCInterfaceIndexer.prepare()` emits.
///
/// MachOObjCSection 0003 removed the library-side reverse tables; the library
/// now only broadcasts what it discovers. This type is where those broadcasts
/// become the tables that back the Inspector's Relationships pane.
///
/// An instance is handed to the indexer as its event handler *before*
/// `prepare()` runs and accumulates throughout the walk. The tables are built
/// on first query; `prewarm()` merely pays that cost up front and is never
/// required for correctness.
final class RuntimeObjCRelationshipIndex: @unchecked Sendable {
    func record(_ event: ObjCIndexingEvent)

    /// Optional: build the tables now instead of on first query. Never required
    /// — skipping it, or failing to reach it because `prepare()` threw, costs
    /// nothing but the deferred build.
    func prewarm()

    func subclasses(of className: String) -> [RuntimeObjCClassReference]
    func conformingClasses(toProtocol protocolName: String) -> [RuntimeObjCClassReference]
}
```

`RuntimeObjCClassReference` 不带 `Codable`，也不是 `public`：全仓库对原库类型的引用只有两处
（`RuntimeRelationshipsResolver` 的一处 doc comment 和一个 `private` 方法签名），关系引用
从不跨进程 —— 越过 XPC 边界的是已经物化好的 `RuntimeObject`。搬迁正是收紧这类多余
conformance 的窗口。

**建表时机：惰性，不是外部契约。** 查询发现尚未建表就先建。**不采用「`prepare()` 之后必须调用
`freeze()`」的写法** —— 那会新造两条静默失效路径，而它们恰恰是本提案动机第二条要消灭的那一类：
忘了调 → 查询返回空、不报错；`prepare()` 是 `async throws`，抛错就跳过了调用点（除非包 `defer`），
该 section 的索引从此永远空着。惰性构建把这两条路径都变成不可能，代价只是查询路径上一次布尔检查。

**累积策略：单一队列，一次 `append`。** `record(_:)` 在锁下向**同一个**待处理队列追加，建表时
按队列顺序回放。单队列不只是为了锁内工作量小，更是行为等价的前提 —— 见下节。

> 锁保留。当前库侧走查是单线程的（`ObjCInterfaceIndexer` 内无 `TaskGroup` /
> `concurrentPerform` / `DispatchQueue` / `async let`），所以竞争接近于零、锁的成本可忽略；
> 但**这是当前实现的事实，不是库的承诺** —— 0003 的契约四明确不承诺 `eventHandler` 的执行
> 上下文，handler 声明为 `@Sendable` 正是为 0002 之后按 image / section 并行走查留的余地。
> 因此锁是必需的，不能以"反正是单线程"为由去掉。

### 与库侧原实现的三处等价性细节

「顺序、内容、去重规则逐条等价」不是一句口号，落到实现上有三条必须照做：

1. **两个 conformance 事件写进同一张表。** 库侧 `indexClass` 的 inline 采纳与 `indexCategory`
   的 category 采纳写的是**同一个** `_conformingClassesByProtocolName`，一次
   `conformingClasses(toProtocol:)` 同时返回两者。不得按事件 case 分成两张表。
2. **顺序是「inline 整体在前，category 整体在后」，不是交错。** 库侧 `prepare()` 先走完整个
   class 列表（`:272`）再走 category 列表（`:350`），所以同一协议的 conformer 里 inline 采纳
   的类整体排在 category 贡献的之前。按到达顺序回放单一队列天然保持这个顺序；一旦按 case 分组，
   合并时无论怎么拼都不等价。这条顺序由 0003 的**契约五**承诺（同一 image、同一库版本，
   两次 `prepare()` 事件序列完全相同；class 阶段整体先于 category 阶段），改动它算库的破坏性
   变更 —— 因此本提案可以放心依赖它，而不是依赖一个碰巧成立的实现细节。
3. **去重按全部三个字段，保留首次插入位置 —— 不要"顺手"改成按 `className` 去重。**
   同一个类可能同时通过 inline 与 category 采纳同一协议，而两条路径的 `isSwiftStable` 来源不同：
   inline 读类自己 `class_t` 上的 flag，category 读 `objcCategory.class(in: machO)` 跨 image
   解析的结果，**解析失败兜底 `false`**。因此在「解析失败 + 该类是 Swift 类 + 同时 inline 与
   category 采纳同一协议」的组合下，会出现 `className` 相同而 `isSwiftStable` 不同的两条引用，
   `OrderedSet` 不去重，Relationships 里该类出现两次、一次标 Swift 一次标 ObjC。

   场景罕见（category 的 target 通常在别的 image，那种情况下 inline 路径根本不会在本 indexer
   产生条目），但它是**现有行为**。按 `className` 去重、或在冲突时合并 `isSwiftStable`，
   看起来像修 bug，实际是行为变更，会让等价性测试失败。真要修另开提案。

### handler 安装

```swift
private static func makeEventHandler(
    relationshipIndex: RuntimeObjCRelationshipIndex,
    forwardingTo progressContinuation: LoadingEventContinuation?
) -> @Sendable (ObjCIndexingEvent) -> Void {
    { event in
        // Relationship events always build the index — this must NOT depend on
        // whether a progress stream exists. Only one of the seven section-creation
        // call sites passes a continuation; gating the handler on it would leave
        // every background-indexed image without relationship data, silently.
        relationshipIndex.record(event)

        guard let progressContinuation,
              case .progress(let phase, let itemDescription, let currentCount, let totalCount) = event
        else { return }

        progressContinuation.yield(...)
    }
}
```

两个 `init` 都改为：先构造 `relationshipIndex`，传入 handler，再 `await objcIndexer.prepare()`。
**`prepare()` 之后无需任何收尾调用** —— 建表是惰性的，`prepare()` 抛错也不会让索引卡在半成品状态。

### 调用点改动

`RuntimeRelationshipsResolver` 里两处，查询对象替换，其余结构不动：

```swift
// 改前
for reference in objcSection.objcIndexer.subclasses(of: objcKey) { ... }
for reference in objcSection.objcIndexer.conformingClasses(toProtocol: object.name) { ... }

// 改后
for reference in objcSection.objcRelationshipIndex.subclasses(of: objcKey) { ... }
for reference in objcSection.objcRelationshipIndex.conformingClasses(toProtocol: object.name) { ... }
```

`materializeRelationshipReference(_:)` 的参数类型从 `ObjCClassReference` 改为
`RuntimeObjCClassReference`，函数体不变（三个字段同名同义）。

## 影响（App 型）

- **用户可见变化**：无。Relationships 标签页的内容、顺序、去重行为逐条等价，这是本提案的硬性约束
  （见「验收标准」）。
- **可发现性**：无新增入口、无设置项、无菜单变化。
- **数据与配置兼容**：不涉及持久化格式，无迁移。
- **平台与最低版本**：不变。
- **发布影响**：需要 MachOObjCSection `0.8.103`。适配代码与 `exact: "0.8.102"` → `"0.8.103"`
  的 pin bump **同批次**提交；在库发版前本改动不能进 main。
- **内存**：预期小幅下降 —— 聚合删除后，`subIndexers` 不再为 engine 生命周期钉住每个 image 的
  索引状态（这正是 `f41648a` 想解决的问题）。具体数值不作承诺，落地后按需实测。

## 验收标准

1. Relationships 标签页对同一目标的结果，与改动前**逐条等价**（内容、顺序均一致）。
2. **不带 `progressContinuation` 创建的 section 同样能查到关系数据** —— 对应动机第二条。
3. 后台索引带进来的 image，其关系查询与手动加载的 image 无差别。
4. `RuntimeObjCSectionFactory` 中不再存在聚合 indexer。
5. `RuntimeViewerCore` 与 `RuntimeViewerPackages` 编译通过，测试退出码为 0。

## 测试策略

### 基线快照走公开 API，仍须在升级依赖之前采集

**落地时的修正（2026-08-11）**：本节原先假定必须比对内部的 `objcIndexer.subclasses(of:)`，
因而断言「没有任何一次运行能同时拿到新旧两个序列」。核实后发现更干净的路子 ——
`RuntimeEngine.relationships(for:)` 这个**公开 API 在重构前后都存在且签名不变**，
现有的 `RelationshipsTests` 就是走它。基线因此可以直接采集用户可见的输出，
既不依赖任何将被删除的内部接口，也正好锁住真正要保住的东西。

采集仍须在升级 pin 之前完成 —— 升级后旧实现就没了，拿不到对照基线。

**同时修正一处对影响面的判断**：`RuntimeRelationshipsResolver` 在返回前把
`subclasses` 与 `conformingTypes` **都按 `displayName` 排过序**
（`RuntimeRelationshipsResolver.swift:128-133`），所以库侧的走查顺序 / 事件发射顺序
**到不了用户界面** —— Relationships 列表一直是字母序。

由此，「详细设计」等价性细节的三条中：
- 第 1 条（两个 conformance 事件写进同一张表）**仍然承重** —— 它关乎结果集的*内容*，分表会丢结果；
- 第 3 条（按三个字段去重）**仍然承重** —— 同样关乎内容，会影响某个类是否出现两次；
- 第 2 条（inline 整体在前）**只关乎内部表的保真度，不影响用户可见输出**。仍然照做（单队列回放
  是最自然的实现，没有额外成本），但它不再是本提案的正确性支点。

0003 的契约五依旧成立，只是支撑它的是库侧自己的两条理由（顺序承诺的载体随方法一起被删、
不给承诺会让 0003 否决「重新走查」的论证塌掉一半），而**不是**本提案原先声称的
「并行化会静默改变 Relationships 顺序」—— 那条声称是错的，已向库侧更正。

### 快照覆盖

- `NSObject` 的子类集（跨 libobjc + Foundation，数量大）
- `NSCoding`、`NSCopying` 的遵守者集（inline 采纳与 category 采纳并存，验第 1 条等价性）

### 三条测试

- **回归测试（必须先红后绿）**：构造一个**不传 `progressContinuation`** 的
  `RuntimeObjCSection`，断言其关系查询非空。这条直接钉住动机第二条那个静默失效。
  它只有在依赖升级之后、handler 解耦之前才会红，因此落地步骤把它排在那个位置 —— **必须实际
  观察到红色**，否则它不构成回归防线。
- **等价性测试**：比对上述基线快照，序列完全一致（含顺序与重复项）。
- **category 路径测试**：用测试 bundle 自带的 fixture，而不是去 Apple 的二进制里翻。
  同模块内为 Swift 类写 `@objc extension` **通常不产出** `__objc_catlist` 条目（编译器掌控
  自己模块里的类，会把成员直接并进 method list）；可靠产出 category 的是**跨模块** extension：

  ```swift
  // The explicit runtime name is REQUIRED, not stylistic: an `@objc protocol`
  // without one is exposed to the ObjC runtime under its mangled spelling
  // (`_TtP<module><name>_`), which is what the indexer reads out of the binary
  // — so the event payload would carry a name the test does not recognize.
  @objc(ObjCIndexingFixtureProtocol)
  protocol ObjCIndexingFixtureProtocol { func fixtureMethod() }

  @objc extension NSString: ObjCIndexingFixtureProtocol {
      func fixtureMethod() {}
  }
  ```

  断言两条（形状取自库侧 0003 落地时的实测版本）：

  ```swift
  #expect(conformance.imagePath == fixturePath)      // 测试 bundle，不是 Foundation
  #expect(!indexer.classNames.contains("NSString"))  // 目标类确实不在本 image
  ```

  这就把「category 的 `imagePath` 是 category 所在 image、不是 target class 所在 image」
  变成了可执行断言 —— 在系统 image 里碰运气拿不到这个。

  它钉不住 `isSwiftStable == true`（`NSString` 不是 Swift 类），也无法区分「解析成功且目标
  非 Swift」与「解析失败兜底」—— 两者 payload 同形。要同时满足「必然产 category」和「target
  是 Swift 类」需要两个模块，成本另计，落地时视需要再定。

- 测试位置 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/`。落地时确认该 target 现有的
  image 加载设施可复用。
- **判定只认 `swift test` 退出码**，不看 xcsift 摘要（见 AGENTS.md）。

## 风险与假设

- **假设**：库侧三个关系事件覆盖了原两张表的全部写入点。0003 的前期调研已确认「三者一一对应，
  没有第四条写入路径」。若落地时发现遗漏，等价性测试会立刻失败。
- **风险**：库侧 `prepare()` 无幂等保护，重复调用会重放事件流，而本提案的累积队列不会自行去重。
  RuntimeViewer 每个 section 只在 `init` 里 prepare 一次且按 imagePath 缓存，当前不受影响；
  建表时的 `OrderedSet` 也会吸收完全相同的重复条目。仍需在类文档中写明这一前提。
- **已关闭的风险 —— 并行化打破顺序等价**：本提案的逐条等价建立在「事件按走查顺序到达」之上，
  而 0003 初稿的契约四只说不承诺执行上下文，连带把顺序也放掉了。经反馈，0003 已增补**契约五**：
  同一 image、同一库版本，两次 `prepare()` 产生完全相同的事件序列；class 阶段全部事件先于
  category 阶段；**改变该顺序算破坏性变更，须走提案**。因此并行化不再会静默改变 Relationships
  的顺序，本提案的等价性目标与测试策略均无需调整。
- **残留风险**：库侧若并行化走查（契约四允许），`record(_:)` 的锁会从"零竞争"变成真正的竞争点。
  单队列 append 仍然正确、顺序仍由契约五保证，只是那时值得重新评估累积策略的性能。
  不在本提案范围内。

## 替代方案考量

### 保留 handler 的条件安装，另外补一条无条件的关系 handler

**为什么否**：两个 handler 意味着两条事件订阅路径，而库只接受一个 `eventHandler`。真要做只能在
外层再包一层分发，比直接在单一 handler 内分流更绕，且把「关系必须无条件收集」这个契约藏得更深。

### 关系索引挂在工厂上，做成跨 image 的单一大表

**为什么否**：那等于把库刚删掉的聚合原样搬到应用侧。`RuntimeRelationshipsResolver` 现有的
「遍历 image、逐个查」结构已经能工作，且天然随 section 的移除而释放；单一大表会重新引入
`f41648a` 修过的那类生命周期问题。

### 等 0002（`MachOFile` 泛型化）一起做

**为什么否**：0002 在库侧尚是 Draft，且 0003 明确排在它之前落地。把下游适配压到 0002 之后，
意味着 main 长期停在旧 pin 上，与「库发版后同批次落地」的交付约定冲突。

## 落地步骤

每一步的验收都是单一确定的状态，按编号顺序执行即可。

0. **采集基线快照** —— 在动任何依赖之前，用现有实现 dump 目标序列落盘。见「测试策略」，
   这是一次性窗口。验收：快照文件存在且非空。
1. **升级依赖**：MachOObjCSection pin `0.8.102` → `0.8.103`。
   验收：编译**失败**（两个查询方法与 `ObjCClassReference` 已不存在），属预期。
2. **新增 `RuntimeObjCClassReference` 与 `RuntimeObjCRelationshipIndex`**，在
   `RuntimeObjCSection` 的两个 `init` 中构造并作为 handler 传入；handler **暂时保持**现有的
   条件安装（这是下一步要观察的失效条件）。同时切换 `RuntimeRelationshipsResolver` 的两处查询
   与 `materializeRelationshipReference(_:)` 的参数类型。
   验收：编译通过。
3. **写回归测试并跑出红色** —— 不带 `progressContinuation` 创建的 section，断言其关系查询非空。
   验收：该测试**失败**。红色本身就是这一步的验收标准；跑不出红说明测试没打中，先修测试。
4. **handler 解耦**：`makeEventHandler` 改为总是返回 handler，`.progress` 的转发才看
   continuation。验收：第 3 步的测试转绿。
5. **补齐等价性测试与 category fixture 测试**，比对第 0 步的快照。
   验收：全部通过。
6. **删除工厂聚合**：`objcInterfaceIndexer` 的声明、构造与两处 `addSubIndexer`。
   验收：编译通过，`swift test` 退出码为 0。
7. **写契约文档**：`RuntimeObjCRelationshipIndex` 的类文档写明「关系数据只经 `eventHandler`
   进入，未安装 handler 即放弃关系数据」以及事件重放的前提。**不允许留到最后补** —— 这是
   本改动唯一一处靠文档而非类型系统兜住的地方。
8. **收尾**：更新本篇状态；判断是否值得在 `Documentations/Internal/` 单独成篇
   （判据是它是否包含代码本身看不出来的决策，目前倾向值得 —— handler 必须无条件安装这一点
   从签名上完全看不出来）。

## 落地记录（2026-08-11）

代码已完成，**尚未提交，且暂时无法用远端 pin 构建**，见下方「阻塞」。

### 红绿两态都观察到了

- **红**：`RelationshipsWithoutProgressStreamTests` 在 handler 仍为条件安装时失败，
  失败形态正是预期的静默空集 —— `relationships.subclasses → []`，无任何报错。
  同一时刻等价性快照也红了。
- **绿**：handler 改为无条件安装后，两者同时转绿。

### 等价性：逐字一致

基线快照（升级依赖前用旧实现采集，`Snapshots/relationships-baseline.txt`）与迁移后输出
**完全相同**：`NSObject` 307 个子类、`NSCoding` 9 个遵守者、`NSCopying` 68 个遵守者，
顺序与 `imagePath` 均一致。

测试：`RuntimeViewerCore` 全量 392 tests / 78 suites 通过，`swift test` 退出码 0
（不看 xcsift 摘要）；`RuntimeViewerPackages` 编译通过。

### 与提案的差异

1. **聚合删除提前到第 2 步。** 提案排在第 6 步，但 `addSubIndexer` 的调用点在库升级后
   直接编译不过，不删就无法进入任何可运行状态。不影响 handler 解耦的红绿观察顺序。
2. **category 测试改为对索引的单元测试。** 提案原计划用测试 bundle 的
   `@objc extension NSString` fixture 走公开 API 断言。实际跑下来 fixture 协议能被索引到，
   但 `NSString` **不会**作为遵守者出现 —— 原因见下条发现。断言层次因此下移到
   `RuntimeObjCRelationshipIndex` 本身（`RuntimeObjCRelationshipIndexTests`，8 个用例），
   用合成事件精确钉住三条等价性 + category 的 `imagePath` 语义；真实二进制的端到端保真
   由等价性快照负责。
3. **`freeze()` 的替代实现多了一条路径。** 惰性建表后，若事件在建表**之后**到达，
   不能作废重建（待处理队列已在建表时释放，重建会丢掉先前全部事件），改为直接折进已建好的表。
   已加测试 `lateEventsStillRegister` 钉住。

### 落地中发现的既有缺陷（未修，不属本提案范围）

**目标类不在本镜像的 category 遵守关系，在物化阶段被静默丢弃。**

`RuntimeRelationshipsResolver.materializeRelationshipReference(_:)` 按 `reference.imagePath`
去定位类，而 category 记录的是**自己所在镜像**。于是「A 框架给 B 框架的类加 category 并声明
协议遵守」这种关系，索引里有、界面上没有 —— 物化时在 A 镜像里找不到那个类，返回 `nil` 丢弃。

这是既有行为，与本次迁移无关（物化逻辑和 `imagePath` 语义都未改动），等价性快照也证明
迁移前后完全一致。修它属于行为变更（会让 Relationships 出现此前从未出现过的条目），
应另开提案。

### 阻塞：远端 pin 暂时升不上去

`MachOSwiftSection` 0.15.0（含其当前 main）把 `MachOObjCSection` 钉在 `exact: "0.8.102"`，
而本改动需要 `0.8.103`。两者都用 `exact:`，因此 RuntimeViewer 无法同时满足：

```
'machoswiftsection' 0.15.0 depends on 'machoobjcsection' 0.8.102
and root depends on 'machoobjcsection' 0.8.103
```

**本分支因此暂时只能用 `USING_LOCAL_DEPENDENCIES=1` 走本地 checkout 构建与测试**
（上述全部验收均在该模式下完成）。合入 main 的前置条件是 MachOSwiftSection 把它的
`MachOObjCSection` pin 提到 `0.8.103` 或更高并发版。

`Package.swift` 已写成目标状态 `exact: "0.8.103"`，等上游发版后即可直接远端构建验证。

### 未采纳：直接升到 `0.8.104`

库侧建议 pin 直接指向 `0.8.104`（含一个 setter strip 的行为修复）。**未采纳** ——
那会让本次纯等价迁移夹带一个用户可见的输出变更，与提案「非目标」冲突。
`0.8.104` 应作为独立改动落地，并单独评估它对 ObjC 接口输出基线的影响。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-10 | Created as Draft | 用户定方向「把 ObjC 搬进来，Swift 不动」，库侧对应 MachOObjCSection 0003。本篇只做下游适配，方向论证不重复 |
| 2026-08-10 | handler 无条件安装 | 核实调用点后确认：7 处 section 创建只有 1 处传 `progressContinuation`，后台索引那条也不传。沿用条件安装会让绝大多数 image 静默失去关系数据。这是本提案的主要风险点，也是它值得单独成篇的理由 |
| 2026-08-10 | 关系索引 per-image，不做工厂级大表 | 沿用 `RuntimeRelationshipsResolver` 现有的「遍历 image 逐个查」结构。做成跨 image 大表等于把库刚删的聚合搬过来，并重新引入 `f41648a` 修过的生命周期问题 |
| 2026-08-10 | 工厂聚合一并删除 | 该聚合只写不读（四处引用全是声明/构造/注册）。0003 删掉库侧 `addSubIndexer` 后它也无法构造。附带解掉 `feature/node-store-adoption` 与 main 之间关于 `removeSubIndexer` 的合并冲突 |
| 2026-08-10 | 回归测试必须先观察到红 | 该失效是静默的（无报错、结果为空），只有先跑出红色才能证明测试抓住了它。因此落地步骤把测试排在依赖升级之后、handler 解耦之前 |
| 2026-08-10 | 建表改为惰性，不引入 `freeze()` 时序契约 | 原设计要求 `prepare()` 之后调用 `freeze()`。库侧评审指出这会新造两条静默失效路径 —— 忘了调、以及 `prepare()` 抛错跳过调用点（它是 `async throws`）—— 而这正是本提案动机第二条要消灭的病症。改为查询时惰性建表，`prewarm()` 降级为可选预热。少一条契约优于多一条文档 |
| 2026-08-10 | 单一累积队列是行为等价的前提，不只是性能选择 | 库侧先走完 class 列表（`:272`）再走 category 列表（`:350`），故同一协议的 conformer 中 inline 采纳整体排在 category 贡献之前。按 case 分成两张表再合并，无论怎么拼都无法还原该顺序 |
| 2026-08-10 | 不"顺手"修同类双 `isSwiftStable` 重复条目 | inline 与 category 两条路径的 `isSwiftStable` 来源不同（后者跨 image 解析、失败兜底 `false`），罕见组合下会产生 `className` 相同而标志不同的两条引用。这是现有行为；按 `className` 去重看似修 bug，实为行为变更 |
| 2026-08-10 | 基线快照必须在升级依赖前采集 | 库侧评审指出「改动前后各跑一次」做不到 —— 改动后旧查询方法已不存在，没有一次运行能同时拿到新旧序列。这是一次性窗口，错过需回退依赖重跑 |
| 2026-08-10 | 保留 `record(_:)` 的锁 | 原文写「锁只为满足 `@Sendable` 检查而非防竞争」，把当前实现当成了 API 契约。0003 契约四明确库不承诺 `eventHandler` 的执行上下文，`@Sendable` 正是为 0002 之后并行化走查留的余地。锁必需，理由改为「当前实现下竞争接近零，成本可忽略」 |
| 2026-08-10 | category fixture 用跨模块 extension，不用同模块 | 原建议在测试 bundle 内为自有 Swift 类写 `@objc extension`，库侧评审指出同模块 extension 通常被直接并进 class 的 method list、不产出 `__objc_catlist` 条目。改为对 `NSString` 这类跨模块 ObjC 类写 extension。附带收益：其 `imagePath` 是测试 bundle，正好把 category 的 imagePath 语义变成可执行断言 |
| 2026-08-10 | 反向要求库承诺发射顺序，0003 增补契约五 | 契约四只说不承诺执行上下文，但连带把发射顺序也放掉了 —— 而本提案的逐条等价正建立在顺序之上，并行化会静默改变 Relationships 列表顺序。库侧接受拆分，并给出更强的理由：顺序承诺**今天已经存在**（`OrderedSet` 插入序 + doc comment + README 白纸黑字），表一移出只是失去载体，不转移到事件上等于静默撤销一个已对外给出的保证。因此本提案的等价性目标得以保住 |
| 2026-08-10 | `RuntimeObjCClassReference` 不带 `Codable`、不设 `public` | 核实全仓库对原库类型的引用只有两处（一处 doc comment、一个 `private` 方法签名），关系引用从不跨进程 —— 越过 XPC 的是已物化的 `RuntimeObject` |
