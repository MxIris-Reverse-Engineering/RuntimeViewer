# RuntimeObject 身份语义改动的审查裁决 — 2026-09-23

审查对象：`next` 上的 `dc0b739c`（把 `RuntimeObject` 的 `==` / `hash` / `Identifiable.id` 改成只表达
身份）、`727720cc`（提案收尾），以及把两者合进 `next` 的 `2f224d81`——干净合并，内容与第二个父提交
一致，没有冲突解决。提案：[0021 RuntimeObject 的相等性只表达身份](../Evolutions/0021-runtime-object-identity.md)。

`/code-review xhigh` 报了 12 条，逐条读代码复核：3 条影响行为（2 条是这次引入的回归，1 条是旧问题
被这次放大），6 条是文档、测试与代码整洁问题，1 条误报，1 条早已由用户裁决不改，1 条是命名规则
问题——用户决定全仓一起改，在后续批次里完成。

**第二问的基线**：「这次引入」对照改动前的 `next`（`a721f1e7`），「main 上也有」对照 `main`
（`4aff02b7`）。`main` 上 `==` 仍比较全部字段，所以本批的两条回归在 `main` 上都不存在。

ID 为 `OBJID.<N>`，与审查报告的顺序一致。修复在 `feature/runtime-object-identity-review-fixes`。

## 已修（同批次）

| ID | 严重度 | 摘要 | 修复 | 复现测试 |
|---|---|---|---|---|
| OBJID.1 | **Major** | Specialization 页看不到新生成的特化。守卫改成按身份比较后：生成特化 → App 跳到特化类型（它没有 Specialization 页，面板留着生成前的泛型类型）→ 从 sidebar 点回泛型类型，传进来的是长出新子节点的同一类型，`update(for:)` 直接返回。**这次引入**。守卫来自 `ad5dba1d`（2026-08-05，修 Inspector 切换对象时列表闪空），当时 `!=` 比较全部字段，长出子节点天然会穿过；提案把它归成了「身份比较」，characterization 测试的数据又恰好没有长出子节点 | `c06817ab`：守卫改用 `hasSameContent(as:)` | `specializationPaneListsAnAddedSpecialization`（修前等 2 s 无新行） |
| OBJID.2 | Minor | 历史栈与活动标签页停在先到的那种形态。同一类型先以链接载荷、再以 sidebar 对象推入时，栈顶不替换、标签页不回写，而 `selectedRuntimeObject` 已是后者，违反 `DocumentTab` 注释里「活动标签页的 object 始终等于 `selectedRuntimeObject`」。标签页标题显示载荷的 `displayName`；切回标签页或后退时恢复载荷，泛型类型的 Specialization 页随之消失（载荷没有 `.isGeneric`）。**这次引入**，守卫来自 `60b04947`（2026-07-23，导航历史与标签页解耦）。「载荷缺 `properties`」本身是 `main` 上就有的旧问题，根治是让跳转推入权威对象（提案里「另案推进」的那条替代方案） | `c06817ab`：同一类型内容不同时替换栈顶；标签页同步改按内容比较 | `timelineEntryCarriesTheLatestForm`、`activeTabCarriesTheLatestForm`（修前分别得到 `["AppKit.NSView"]` 与 `"AppKit.NSView"`） |
| OBJID.3 | Minor | Relationships 按 `displayName` 查 Swift 协议的遵循者，而协议嵌套在类型里时，sidebar 用它自己的短名（`currentName`），跳转路径用限定名。**根源在 `main` 上就有**：从 sidebar 选嵌套协议永远查不到遵循者（查法来自 `c3eb2735`，短名来自 `24464ff5`）；这次的身份守卫又让先到的形态定格，跳到限定名形态也不再纠正。嵌套协议要 Swift 5.10 起才允许，实际很少见 | `d8751de1`：resolver 从 mangled `name` 经聚合索引的 `protocolName(forMangledName:)` 反查限定名，查不到才退回 `displayName` | `swiftProtocolConformersIgnoreDisplayName`（修前 `[]`，应为 `PersonNameComponents`）。Foundation 没有嵌套协议，短名形态是把一个根协议的 `displayName` 换成短名构造的 |
| OBJID.5 | Minor | 测试缺口：没有测「子节点变多」；标着「只差 properties」的 Specialization cell 测试两边还差 `children`；编解码往返的 `decoded == original` 只剩身份比较；`activeTabTracksTheSelection` 的注释称身份变化「观察不到」 | `c06817ab`（第一项与最后一项）、`630b37d3`（中间两项） | 第一项即 OBJID.1 的测试；其余是收紧既有断言 |
| OBJID.6 | Minor | `displayName` 的注释称「同一个 mangled name 必然印出同一个 `displayName`，只有链接载荷例外」，嵌套协议就是反例；提案「已验证的事实」第一条同样 | `b961449c`（注释改写，并写明判定类型身份的代码不得读 `displayName`）；提案按决策快照规则不改正文，更正追加在决策日志 | — |
| OBJID.7 | Minor | `RuntimeObjectKey` 与接口缓存键的注释仍说 `==` 会比较 `children`。全仓搜过，其余提到 `RuntimeObjectKey` 的注释仍然成立 | `b961449c` | — |
| OBJID.9 | Minor | 提案以 Implemented 合进 `next` 却没编号（0019、0020 都是在落到 `next` 的那次提交里编的号） | `735d94e4`：改名为 `0021-runtime-object-identity.md`，更新两个索引与「新提案从哪号起编」的提示，测试注释改引用短名 `runtime-object-identity`，决策日志里被插错位置的三行收尾记录挪回实际位置 | — |
| OBJID.10 | Minor | `==` / `hash(into:)` 把 `(imagePath, name, kind)` 又抄一遍，没委托给 `key`，「`a == b` 等价于 `a.key == b.key`」只靠手工同步 | `b961449c` | 既有 `RuntimeObjectIdentityTests` |
| OBJID.12 | Minor | sidebar cell 的 `fingerprint` / `StableID` 第三次手写同一组三元组（`039cd217` 起） | `b961449c`：两者改用 `RuntimeObjectKey`。`StableID` 不落盘，app target 也不读它的字段 | 既有 `SidebarRuntimeObjectCellViewModelTests` |

第四问（以前修过吗）：除表中写明来历的几条外，其余是本次新代码，没有既往修复。

### 翻转的 characterization 断言

`specializationPaneDoesNotRebuildOnPropertiesDifference` 改为
`specializationPaneRebuildsTheSameRowsOnPropertiesDifference`。身份改动把它当作「修好」钉住，但
这个面板不取数据、没有加载占位，重建相同的行看不出来；它改按内容守卫后属性不同就会重建，断言因此
改成「重建前后的行一致」。理由也记在提案决策日志里。

## 误报

### OBJID.8 — Objective-C 链接载荷复制宿主的 `children`

**报告的说法**：载荷背着当前显示类型的子树，进入历史栈和标签页后让一棵无关子树常驻内存。

1. **误报，后果不成立。** 那行 `children: runtimeObjectName.children` 确实存在，但只有 Objective-C / C
   宿主会走这条分支，而 `RuntimeObjCSection` 构造的 Objective-C / C 对象一律是 `children: []`，复制的
   永远是空数组。
2. `main` 上是同一行。
3. 没有可观察的后果。仍在 `2e16f7ea` 顺手改成 `children: []`：与 Swift 载荷一致，也符合本提案「载荷
   型对象不该带显示属性」的原则。
4. 从 `a916d980`（2025-10-27，最初的链接载荷实现）起就这样写，没有改过。

## 不修

### OBJID.4 — `ComparableBuildable` 的 `<` 与新 `==` 不一致，协议扩展还自带一个 `==`

1. 不一致成立：排序比较 `imagePath` / `kind` / `displayName`，所以同身份、不同 `displayName` 的两个
   对象可能 `a == b` 且 `a < b`。协议扩展里的 `==` 只在以 `ComparableBuildable` 为约束的泛型上下文
   里才会被选中，本仓库与 FrameworkToolbox 都没有这样的上下文；按身份去重的 `Set` 测试通过，证明
   `Equatable` 实际用的是手写的身份 `==`。
2. `main` 上同样存在：`@Equatable` 生成的全字段 `==` 同样与协议扩展的 `==` 并存，`<` 与它也不一致。
3. 不修。提案决策日志里用户已明确「不动 `ComparableBuildable`，它只用于 sidebar 排序」，而排序只
   用 `<`。
4. `5acf5b2f`（2026-01-12）引入，从未改过。

**何时重新考虑**：出现以 `ComparableBuildable` 为约束、并在其中用 `==` 的泛型代码，或者
`RuntimeObject` 被用在依赖 `==` 与 `<` 一致的算法里（二分查找、拿排序结果与 `Set` 互查）。

### OBJID.9 的一部分 — 提案正文仍写着 `@EquatableIgnored` 方案

「提议方案」与「详细设计」描述的是 `@EquatableIgnored`，实现走的是手写 `==` / `hash`。不改正文：
落地后的提案是决策快照，偏差已记在决策日志「手写 `==` / `hash(into:)`，放弃 `@EquatableIgnored`」
一行与「已验证的事实」里，「详细设计」本身也写了手写的备选。

## 用户决定后修复

### OBJID.11 — 参数名 `lhs` / `rhs` 违反「不许缩写」规则

1. 成立。
2. 是新代码，但项目里另有 11 处 `static func ==` 用 `lhs` / `rhs`（`main` 上 9 处），FrameworkToolbox
   也这样写。
3. 新写的那处已在 `b961449c` 改为 `leftObject` / `rightObject`。用户决定其余一起改：`bb1b1b08` 把全仓
   12 个文件里的 11 处 `==`、1 处 `<`、4 个排序闭包和 1 段注释掉的旧代码改成描述性名字，
   `RuntimeSource.==` 里 `lId` / `rRole` / `lHost` 这类前缀缩写一并改掉。行为不变：Core 相关的 8 个
   套件 120 个测试、Packages 全量 302 个测试通过。
4. 无既往修复。

## 另行排查、确认无问题的点

审查没有提、复核时补查的：

- `@RxObserved` 每次赋值都会发出，不按 `==` 去重（`RxObservedSlot` 没有 `Equatable` 约束），身份相等的
  新值不会被吞掉。
- sidebar 对 `selectedRuntimeObject` 的 `distinctUntilChanged` 改成按身份去重反而正确：同一类型换一种
  形态到达时，sidebar 不需要重新高亮。
- sidebar 的两种绑定（`rx.sections`，以及不带 `.diffable` 的 `rx.nodes`）都是整表 `reloadData()`，不
  调用 `isContentEqual`，所以浅层的 `hasSameContent` 不会漏掉更新；`rebuildChildren()` 给回收的子 cell
  赋的是从 cell 树物化出来的对象，浅比较足够。
- 内容面板的重绑守卫（`ContentCoordinator`）：接口缓存按身份取值，而生成特化后必定 `.selectAtRoot`
  跳走，内容面板不会停在长出子节点的父类型上。
- Core / MCP / CLI 里没有其它 `RuntimeObject ==` 的使用点；以 `RuntimeObject` 为元素或键的容器只有
  resolver 的 `OrderedSet` 与 `RuntimeObjectBookmark`，提案已覆盖。

## 验证

- Packages 全量：302 个测试（原 299 个加 3 个新测试）通过，退出码 0；跑测试前后 Debug 设置文件的 SHA
  一致。
- Core：与改动相关的 5 个套件共 66 个测试通过。`RelationshipsEquivalenceSnapshotTests` 仍是提案记录的
  那 4 对 `__C.Decimal.FormatStyle` ↔ `__C.NSDecimal.FormatStyle` 差异，resolver 的改动没有改变它——
  快照锚点 `Foundation.FormatStyle` 是根协议，`displayName` 本来就是限定名。
- Core 全量并行跑时，socket、XPC service 重连、请求超时、批次取消这一类进程间通信与时序测试会成批
  超时失败（本分支两次分别 8 个、11 个；第一次跑到约 570 个测试后进程停在 0% CPU，由我手动结束）。
  把失败测试所在的套件单独跑（两次共 90 个测试，各自 2 秒内跑完）全部通过；改动前的基线 `2f224d81` 在同样的全量并行
  运行里也挂同一批（505 个测试中 7 个，外加上面那条快照）。它们不经过本批改动的任何代码，判为本机
  满载时的既有问题，不是回归。
- App 整包构建：修复这一批本身没有做（它没改 app target 的代码，改到的公开 API——`StableID` 的字段——
  在 app target 里没有使用者）。合进 `next` 之后、推送之前，用 `RunScript.sh`（Xcode 27、
  Debug-arm64e）整包构建了连同 OBJID.11 在内的最终状态：Catalyst helper、模拟器载荷、主 App 三段均
  成功，零 error。
