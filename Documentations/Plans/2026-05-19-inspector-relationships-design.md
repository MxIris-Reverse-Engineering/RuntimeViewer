# Inspector Relationships 设计文档

**日期:** 2026-05-19
**状态:** 已达成共识(RALPLAN-DR 流程于迭代 2 收敛,Architect + Critic 双重 APPROVE)
**配套文档:** `2026-05-19-inspector-relationships-plan.md`(实施步骤)

---

## 1. 用户需求

实现 Inspector Relationships 功能:

1. ObjC/Swift 协议可以看到被 conform 的类(OC/Swift 类)
2. ObjC/Swift 类可以看到继承自己的所有子类

具体实现在 `RuntimeViewerCore` 中。Swift 部分利用现有的 `SwiftInterfaceIndexer` 查找;ObjC 需要新建一个 Indexer。Relationships 功能依赖索引,只在被索引的 image 中查找。

---

## 2. 设计原则

1. **与现有模式对称。** ObjC indexer 镜像 `SwiftInterfaceIndexer` 的形态(per-image 实例 + factory 聚合)。Engine 方法镜像 `hierarchy(for:)` 的 throwing 契约。单一的 `RuntimeObject` 物化 helper 沿用引擎中已有的 `existingSection(for:)`-keyed 查找模式。

2. **信任现有 Mach-O 元数据;不构造合成名称桥接。** 每一个继承 ObjC 类的 Swift 类(如 `class Foo: NSObject`,无论是否标注 `@objc`)都会在 `__objc_classlist` 中发射一条 `class_t` 记录。ObjC indexer 在遍历 `__objc_classlist` 时自动捕获这些类。查询时不做字符串合成(无 `"objc:" + name`)、不做字符串前缀测试、不调用任何虚构的 `MetadataReader.demangleType`。

3. **确定性、可观察行为。** 在所有支持的 macOS 版本上行为一致。无环境分支、无 profile-gated fallback。跨语言去重采用结构化的 `ObjCClassProtocol.isSwiftStable` 标志位(每个 `ObjCClassReference` 携带)。

4. **索引边界查询,服务端 gate。** 服务端(engine)遍历 `loadedImagePaths`,应用 `isImageIndexed(path:)`,联合每个 image 的结果。调用方从不自行遍历 images。

5. **Eager 构建、可预测成本;actor 隔离写入、nonisolated 读取。** Swift 子类反向表和 ObjC indexer 都在 section 初始化时构建。Section 内的存储通过 actor 隔离串行化写入;indexer 实例本身声明为 `nonisolated let`,因为它是 `Sendable` 且内部 `@Mutex`-保护,与 `SwiftInterfaceIndexer` 跨 actor 边界引用的方式一致。

---

## 3. 决策驱动力(优先级排序)

1. **与 `SwiftInterfaceIndexer` 和 `hierarchy(for:)` 的对称性。** 降低执行者与未来读者的认知负担;复用现有的 progress、dedup、dispatch 机制。
2. **确定性 per-image scope 语义。** 索引感知查询配合显式 `isImageIndexed` gate,避免多 image 会话下出现不明确的部分结果。
3. **不修改 upstream 库。** 所有工作位于 `RuntimeViewerCore`。把 Swift 子类反向表推到 `MachOSwiftSection` 是 Follow-up(见第 6 节)。

---

## 4. 关键问题与决策(决策记录)

| # | 问题 | 决策 | 拒绝的备选 |
|---|------|------|----------|
| Q1 | ObjC indexer 放在哪里? | **A1.** 新建 `RuntimeObjCInterfaceIndexer<MachO>`,per-image + factory 聚合,镜像 `SwiftInterfaceIndexer`。 | (a) 在 `RuntimeObjCSection` 内联存储 — 拒绝:打破 Swift 侧已经编码的 per-image/factory-aggregate 划分,迫使所有消费者通过 section-level 锁。(b) 把 indexer 加到 `MachOObjCSection` upstream — 拒绝:跨库改动,违反原则 5 / 驱动力 3。 |
| Q2 | Swift 子类反向表的构建时机? | **A2.** 在 `RuntimeSwiftSection.init` 末尾、`try await indexer.prepare()` 之后即时构建(eager)。 | (a) 首次查询时 lazy — 拒绝:引入查询时不确定性,与 index-bounded 语义冲突,使 progress 上报复杂化。(b) 推到 upstream `SwiftInterfaceIndexer` — 拒绝:跨库改动。 |
| Q3 | 查询时如何进行跨语言识别? | **A3.** 信任 `__objc_classlist` 浮现 Swift 衍生子类;对任意 class 类型的查询去查 ObjC indexer;通过 `isSwiftStable` filter 物化为标准 Swift `RuntimeObject`。 | (a) 把合成的 `"objc:" + name` 字符串喂给 `MetadataReader.demangleType` — 拒绝:引用了不存在的 API,不是真实的元数据桥。(b) 在每个 indexer 上维护一份 ObjC-name → Swift-mangled-name 表 — 拒绝:与已经在 A3 v1 里提议的 `ObjCClassReference.isSwiftStable` 标志冗余。 |
| Q4 | 测试 fixture 策略? | **A4.** 对真实系统 framework(Foundation、SwiftUI、libobjc)进行测试,无 `Package.swift` 改动。 | (a) 构建专用的 mixed-language `RelationshipsTestsFixture` 静态库 target — 拒绝:对 `Package.swift` 改动大、跨平台构建脆弱、与真实二进制存在漂移风险。(b) Mock 两个 indexer — 拒绝:跳过该特性最重要的集成面。 |
| Q5 | 物化 `RuntimeObject` 的 engine helper? | **A5.** 单一 helper `makeRuntimeObject(name:imagePath:kind:)`,由调用方提供 kind。 | (a) 三个按 kind 特化的 helper — 拒绝:section-existence + lookup 样板代码会重复三次。(b) 返回原始 name 让调用方物化 — 拒绝:把 per-section schema 泄漏到 engine 方法里。 |

---

## 5. ADR(架构决策记录)

### Decision(决策)

实现 Inspector Relationships 如下:

- (Q1) 新建 `RuntimeObjCInterfaceIndexer<MachO>`,per-image + factory 聚合,在 `RuntimeObjCSection.prepare()` 的现有 Mach-O 遍历中喂数据;
- (Q2) 在 `RuntimeSwiftSection.init` 末尾、`indexer.prepare()` 之后立即构建 Swift 子类反向表;
- (Q3) 通过 `__objc_classlist` 枚举捕获 Swift 衍生的 ObjC 子类,查询时无任何合成 ObjC↔Swift 名称桥接,bridged 类通过 `isSwiftStable` 物化为 Swift `RuntimeObject`;
- (Q4) 测试对真实系统 framework 进行,无 `Package.swift` 改动;
- (Q5) Engine 上提供单一 helper `makeRuntimeObject(name:imagePath:kind:)`。

Engine 暴露单一 throwing 方法 `relationships(for:) async throws -> RuntimeRelationships`,返回携带两个数组的 `Codable` 结构。Tab 可见性按 kind 条件性显示,`relationshipsIndex` 用显式的索引数学。索引在服务端通过 `isImageIndexed(path:)` 进行 gate。Transitive 协议成员关系由元数据层语义自动排除。

### Drivers(驱动力,前 3)

1. 与 `SwiftInterfaceIndexer` 和 `hierarchy(for:)` 的对称性 — 降低认知负担。
2. 确定性 per-image scope 语义 — 索引感知查询配合显式 gating。
3. 不修改 upstream 库。

### Alternatives Considered(已考虑并拒绝的备选)

- 在 `RuntimeObjCSection` 内联存储(无专用 indexer 类型)— 拒绝:打破 per-image/factory-aggregate 划分。
- 把两个 indexer 上推到 `MachOObjCSection` / `MachOSwiftSection` — 拒绝:跨库改动。
- 首次查询时 lazy Swift 子类反向表 — 拒绝:引入查询时不确定性。
- 字符串前缀 superclass 分类(`_TtC…`)— 拒绝:脆弱。
- 把合成的 `"objc:" + name` mangled-name 字符串喂给 `MetadataReader.demangleType` — 拒绝:引用了不存在的 API,不是真实的元数据桥。该桥不需要存在,因为 `__objc_classlist` 已经包含了所有有 ObjC 祖先的 Swift 类的记录。
- 拆成两个 engine 方法(`subclasses(of:)` / `conformers(of:)`)— 拒绝:更大的 API 表面、相同的 payload,asymmetric 填充已经编码了 kind-conditional 语义。
- 三个按 kind 特化的 `makeRuntimeObject` helper — 拒绝:section-existence + lookup 样板代码三倍重复。单一 helper + 调用方提供 kind 是共识形态。
- Tab 总是显示(对不可能产生结果的 kind 显示「该 kind 不可用」空态)— 拒绝:对永远不可能产生结果的 kind 来说是噪声。
- 测试用专用的 mixed-language fixture target — 拒绝:`Package.swift` 改动大、漂移风险;真实系统 framework 已能覆盖全部 7 个测试。

### Why Chosen(为什么这样选)

所选形态在同一个 package 内复用了两个现有、可工作的模式(`SwiftInterfaceIndexer` per-image + `RuntimeSwiftSectionFactory.indexer` 聚合;`hierarchy(for:)` throwing engine 方法 + proxy 注册),执行者可以照葫芦画瓢而不是新设计。

`isSwiftStable` 标志位是 bridged 类的规范结构信号源,已在 `RuntimeObjCSection.swift:322` 使用,从根本上消灭了所有字符串前缀类的 bug。基于 `__objc_classlist` 捕获 Swift 衍生 ObjC 子类的方案完全消除了构造跨语言名称桥接的需要。

单一 helper 合并了三次重复的 section-existence 样板代码。测试 fixture 锚定到几十年稳定的系统 framework API(`NSObject`、`NSArray`、`NSCoding`)和测试自身枚举出的运行时 anchor,使测试套件无需任何新构建产物即可保持确定性。

### Consequences(后果)

**Positive(正面):**
- 结果确定、可观察,两种查询 kind 之间对称。
- 实现复用现有的 progress、dedup、dispatch 机制。
- 不增加新的锁或 actor 隔离模式。
- 未来 MCP 暴露是机械包装。
- 无 `Package.swift` 改动。

**Negative(负面):** Eager 构建增加了可测量成本。
- **每个 image:** 对 `indexer.allTypeDefinitions` 一次 `O(N)` 扫描,在 `N = 10000` 个类型定义的 Apple Silicon 上约 10–30 ms(从项目 CI 中已运行的 indexing benchmark 外推)。
- **ObjC 侧:** 每个 class 一次 `objcClass.superclass(in:)` + 一次 `objcClass.protocols(in:)`,每个 category 一次 `category.protocols(in:)` — 均落在现有 extraction 循环的 `O(classes + protocols + categories)` 成本内,在每次 `RuntimeObjCSection.prepare()` 中本来就要付出。
- 成本只在 image-section 构建时付一次,与用户是否打开 Relationships tab 无关。
- Factory 聚合每次 section 构建多一次 `addSubIndexer` 调用(`O(1)`)。

### Follow-ups(后续工作)

- 把 Swift 子类反向表推到 `SwiftInterfaceIndexer` upstream,让 RuntimeViewer 之外的消费者也能受益。
- 当用户需求出现时,把 transitive 协议成员关系作为可选的查询参数加入(`includesTransitiveConformers: Bool = false`)。
- 在 `RuntimeViewerMCPBridge` 中暴露 `relationships` 作为 MCP tool。
- 当结果数超过可用性阈值时,考虑按 source image 在 Inspector 列表中分组/排序。

---

## 6. Out-of-Scope(非目标)

- **Transitive 协议成员关系。** 若 `class C: P` 且 `protocol P: Q`,`relationships(for: Q)` **不**包含 `C`。在计划阶段已验证:`SwiftInterfaceIndexer.indexConformances()`(`RuntimeViewerCore/.build/checkouts/MachOSwiftSection/Sources/SwiftInterface/SwiftInterfaceIndexer.swift:422-446`)逐条遍历 `currentStorage.protocolConformances`,Swift 编译器不会为传递性的 `: Q` 合成 record。与 Xcode symbol navigator 语义一致。
- **跨进程查询(XPC remote engine)。** `RuntimeEngineProxyServer.swift` 的 bridge dispatch 表加一条 handler(见实施计划 Step 5),v1 远程可用。但 v1 不包含高频 XPC round-trip 的性能优化(无 batching、无 caching)。
- **合成 fixture 二进制。** v1 测试针对真实系统 framework(Foundation、SwiftUI、libobjc)断言。专用 mixed-language fixture 推迟。
- **排序/分组/过滤 UI。** 行按 `displayName` 字母序排序。无多 section 分组(如「同 image」vs「其他 image」)。Relationships tab 无搜索框。
- **修改 upstream 的 `MachOSwiftSection` / `MachOObjCSection`。** 所有新类型都局限在 `RuntimeViewerCore`。
- **反向 selector / ivar-type 索引。** 不在范围内;v1 只覆盖类继承和协议遵守。
- **把 Swift 子类反向表推到 upstream。** v1 中 eager 构建只在 `RuntimeSwiftSection` 本地。后续版本可推到 `SwiftInterfaceIndexer.allClassDescriptorsBySuperclassMangledName`。
- **Tab 打开后索引完成的自动刷新。** Step 10 只对已经 section-built 的 image 显示 tab,主路径不会在未索引 image 上打开 tab。跨 image 二级路径(target 在 image A,conformer 在 image B 且 B 之后才被索引)在下一次 sidebar 选择时重新计算 union — Inspector 不订阅 indexing 完成事件。
- **MCP 集成 Relationships。** MCP bridge 在 v1 中不暴露 `runtime/relationships` tool。v2 候选。
- **合成 ObjC↔Swift 名称桥接。** 无 `"objc:" + name` 字符串合成。Swift 衍生的 ObjC 子类只通过 `__objc_classlist` 枚举浮现。

---

## 7. 验收标准

1. `engine.relationships(for: object)` 对任何不在 `{.objc(.type(.class)), .objc(.type(.protocol)), .swift(.type(.class)), .swift(.type(.protocol))}` 中的 `object.kind` 返回 `RuntimeRelationships(subclasses: [], conformingTypes: [])`,且不抛出。
2. 对在 image A 中已索引的 ObjC 根类,`relationships(for: rootClass).subclasses` 跨所有已索引 image 包含每一个直接 ObjC 子类和每一个直接 Swift 子类(通过 `__objc_classlist` 记录),无重复。
3. 对纯 Swift class(无 `__objc_classlist` 记录),若已索引 image 中至少有一个直接 Swift 子类,`relationships(for: swiftClass).subclasses` 包含该子类一次。(纯 Swift 查询只走 Swift 反向表。)
4. 对 ObjC 协议 P,`relationships(for: P).conformingTypes` 跨所有已索引 image 包含每个通过 `@interface … <P>` 内联 adopt 的类,以及每个通过 category adopt P 的类。
5. 对 Swift 协议 P,`relationships(for: P).conformingTypes` 严格等于已索引 image 范围内 `swiftSection.conformingTypes(of: P.name)` 的 union,转换为 `RuntimeObject`,无重复。
6. 当一个类被 bridged(`ObjCClassProtocol.isSwiftStable == true`),结果中只出现一次,且 `kind == .swift(.type(.class))`,绝不以 `.objc(.type(.class))` 出现。
7. 当第二个 image 已加载但未索引时,对一个属于已索引 image 的目标查询,结果排除第二个 image 的内容,调用不抛出。索引第二个 image 后再次查询,这些内容可以出现。
8. Inspector Relationships tab 仅在 `runtimeObject.kind` 属于(1)所列的四个 kind 时可见;对 struct、enum、typealias、extension、category、conformance、C struct/union kind 隐藏。
9. Inspector 中 tab 顺序为 `Class Hierarchy → Relationships → Specialization`。`TabConfiguration.relationshipsIndex` 在 `needsClassHierarchy == false` 时返回 0,否则返回 1。点击 Relationships 表格行触发 `router.trigger(.selectRuntimeObject(_))`,sidebar 选中状态更新。
10. `swift test --filter RelationshipsTests` 在 `RuntimeViewerCoreTests` 干净构建下,Step 12 列出的 7 个测试全部通过,无 `Package.swift` 改动,无新增 fixture target。

---

## 8. 共识流程记录(RALPLAN-DR)

| 阶段 | 输出 |
|------|------|
| Planner v1 → Architect v1 | APPROVE WITH AMENDMENTS(7 项强制修正:A1–A7) |
| Planner v2 → Critic v2 | ITERATE(3 BLOCKER + 3 MAJOR + 2 MINOR) |
| Planner v3 → Architect v3 → **Critic v3** | **APPROVE-WITH-RESERVATIONS**(3 项实施期 watch-out,无 blocker) |

**Iteration 2 收敛。** 实施期 watch-out 记录在实施计划 Section 6。
