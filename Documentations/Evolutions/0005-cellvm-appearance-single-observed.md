# 0005 - 高基数 Cell ViewModel 的 Appearance 单流化

- **状态**: Implemented
- **作者**: JH
- **日期**: 2026-08-09
- **关联**: [0004](0004-differentiable-box-lazy-cellvm.md)（本提案与其互补：0004 处理「短命 static cellVM」，本提案处理「长寿命 stateful cellVM」）

## 摘要

把高基数（N >= ~1k）长寿命 cell ViewModel 上的多个分立 `@Observed` 外观属性（`primaryIcon` / `secondaryIcon` / `tertiaryIcon` / `title` / `subtitle`）合并为**单个** `@Observed appearance: RuntimeObjectCellAppearance` 结构体属性，`RuntimeObjectCellDisplayable` 协议相应从 4 个分立 driver 收敛为 1 个 `appearanceDriver`。每行的 Rx 固定成本从 5 套 subject + lock 降到 1 套，行为与渲染结果不变。

首批适用对象：`SidebarRuntimeObjectCellViewModel`（浏览路径，每镜像数千行）与 `SidebarRootCellViewModel`（镜像列表，常驻 ~13k 行）。

## 动机

三轮库侧内存优化（MachOSwiftSection 0001/0002/0003 + swift-demangling 0010/0011）落地后，五镜像稳态从 470-480 MB 降到 262 MB，库侧六个堆簇在全量浏览压力下全部横住。此时唯一仍随浏览量线性增长的成本只剩 RV 自己的 UI 管线，2026-08-09 实测（用户拖拽浏览 SwiftUI 全部 RuntimeObject 后）：

- `NSRecursiveLock`：**125,225 把 / 28.1 MiB**（干净基线 54k），全进程第一大 ObjC 类；
- UI/Rx 簇 46.7 MiB（基线 21.4），占浏览堆增量 ~60%；
- 增量来源：+6,895 个 `SidebarRuntimeObjectCellViewModel`，每个带 5 个 `@Observed`。

`@Observed`（RxSwiftPlus）的存储是 `BehaviorRelay`，每个实例内含 `BehaviorSubject` + `NSRecursiveLock`（224 B）+ 同步追踪器，单属性全套 ~450-500 B。5 个属性 × 每行 ≈ 2.2-2.5 KB 的纯管线开销，而这些属性**只在 filter 变化与 specialization splice 时才更新**——事件频率完全撑不起每属性一条流。

lazy 路线走不通：[0004](0004-differentiable-box-lazy-cellvm.md) 的「反模式案例 #1」已裁定 Sidebar cellVM 必须保持 eager（filter 感知 attributed name 的订阅身份、树结构、splice 复用）。本提案是与其正交的另一条路：**不动 eager 树、不动任何行为语义，只减每行的流数量**。

### 非目标

- **不**改 `@Observed` 本身或 RxSwiftPlus 的锁实现——那是上游改动，影响全项目每一个 `@Observed`，风险面完全不同（可作为后续独立提案）。
- **不**动 cellVM 的树结构、filter pipeline、splice 逻辑、`StableID` / `Differentiable` 身份——全部保持原样。
- **不**处理低基数 cellVM（Inspector 各 tab、popover 等 N < 数百的场景）——eager 多流在那些量级下无感，改了徒增 churn。
- **不**触碰 `SpecializationTypePickerCellViewModel`——它走 0004 的 lazy 短命路线，构造后即弃，无长寿命流成本。

## 提议方案

### 1. `RuntimeObjectCellAppearance` 结构体（RuntimeViewerApplication）

```swift
public struct RuntimeObjectCellAppearance: Equatable {
    public var primaryIcon: NSUIImage
    public var secondaryIcon: NSUIImage?
    public var tertiaryIcon: NSUIImage?
    public var title: NSAttributedString
    public var subtitle: NSAttributedString?
}
```

成员均为引用类型或 Optional 引用，struct 拷贝只是引用拷贝；`Equatable` 用于 `didSet` 去重（等值不发事件）。

### 2. cellVM 改造

```swift
@Observed
public private(set) var appearance: RuntimeObjectCellAppearance
```

`refreshAppearance()` / `rebuildTitleForFilterResult()` 改为组装完整 struct 后一次赋值——顺带把「一次刷新发 5 个事件」的既有冗余消掉，发布变为原子。

### 3. `RuntimeObjectCellDisplayable` 协议收敛

```swift
public protocol RuntimeObjectCellDisplayable {
    var appearanceDriver: Driver<RuntimeObjectCellAppearance> { get }
}
```

cell view 的 `bind(to:)` 单订阅、单闭包内更新全部 outlet。订阅数从每可视行 4 条降到 1 条（可视行仅 ~12 行，此处收益次要，主要收益在 cellVM 侧的存储）。

## 影响（App 型）

- **用户可见变化**：无。渲染结果要求逐字节一致（filter 高亮、图标、Open Quickly 均不变）。
- **可发现性**：不适用。
- **数据与配置兼容**：无持久化数据涉及。
- **平台与最低版本**：不变。
- **发布影响**：纯内部重构，无发布注意事项。

## 预期收益与验收标准

同款负载（五镜像索引 + SwiftUI 全量拖拽浏览）对照 2026-08-09 基线：

| 指标 | 基线 | 验收线 | 实测（2026-08-09 落地后） |
|---|---|---|---|
| `NSRecursiveLock` 实例数（全量浏览后） | 125,225 | **≤ 45,000** | **42,218** ✓（−66%；与 6,895 行 × 1 流的推算 ≈ 41k 吻合。稳态为 27,341） |
| UI/Rx 堆簇（全量浏览后） | 46.7 MiB | **≤ 32 MiB** | **17.7 MiB** ✓（−62%） |
| 五镜像稳态堆存活（含 13k 行镜像列表） | 210 MiB | **≤ 205 MiB** | **196.7 MiB** ✓（含 0006 的 NIO 回收；footprint 262 → 239 MB，索引峰值 613 → 546 MB） |
| 行为回归 | — | 现有测试全绿 + filter 高亮 / splice / Open Quickly 手测无回归 | 包内 14 测试全绿（filter 基线的精确发射计数 100/10000/10000 保持不变）；用户以同款负载全量拖拽浏览完成复测，无异常反馈 |

**稳态锁减半的构成**：镜像列表 13,159 行 × 每行 2 流（icon + name）→ 1 流，每流约 2 把锁（`BehaviorRelay` + `BehaviorSubject` 各一），恰好对应 54k → 27.3k。heap 中 `BehaviorSubject<SidebarRootCellViewModel.Appearance>` 计数 13,159，与行数一一对应。

## 风险与假设

1. **事件粒度变粗**：原来 title 单独变化只重设 title，现在整个 struct 重发、5 个 outlet 全重设。事件频率低（filter 键入节流后 / splice 一次性），单事件多 4 次赋值可忽略；`SidebarFilterPerformanceBaselineTests` 把关键路径（nil→nil 跳过）钉住，保持不动。
2. **`Equatable` 去重的比较成本**：`NSAttributedString` 的 `==` 在 title 确实变化时才走全比较；等值路径（占绝对多数）由既有 `oldValue == nil, filterResult == nil` 早退挡住，不经过 struct 比较。
3. **协议收敛波及面**：`RuntimeObjectCellDisplayable` 的全部 conformer 与消费 cell view 需同批改；grep 确认后列入落地清单。

## 替代方案考量

### A. Lazy cellVM（DifferentiableBox）

被 0004 明确列为反模式：filter 感知 attributed name 依赖订阅身份，lazy 重建即失效。不重议。

### B. 上游改 RxSwiftPlus：`@Observed` 换 `os_unfair_lock` / lock-free

收益量级相近（224 B 锁 → 8 B），且惠及全项目。但改动在上游仓库、影响所有 `@Observed` 调用点的并发语义（NSRecursiveLock 可重入，unfair lock 不可），需要独立评审与全量回归。作为后续候选提案，不与本提案捆绑。

### C. cellVM 不持有外观，cell 渲染时从模型现算

即「半 lazy」：外观退化为纯函数。filter 高亮需要 cellVM 持有 `filterResult` 并在变化时通知 cell——通知机制绕一圈还是一条流，复杂度不降反升，且打破 0004 划定的两范式边界。

## 测试策略

- 现有 `SidebarFilterPerformanceBaselineTests`、`OpenQuicklyLazyConstructionTests` 全绿（行为契约不变的机器证明）。
- 新增单测：appearance 原子性（一次 `refreshAppearance()` 恰好一个事件）、等值不发事件。
- 验收数字用与基线同款的 `heap -sortBySize` 流程复测（agent 侧已有成套脚本）。

## 落地步骤

1. `RuntimeObjectCellAppearance` + `RuntimeObjectCellDisplayable` 收敛 + 两个 Sidebar cellVM 改造 + cell view 适配，单 commit；
2. 回归测试 + heap 验收复测，数字回填本提案；
3. 状态 `Accepted` → `In Progress` → `Implemented` 随批次原地更新。

## 落地记录（2026-08-09）

改动清单（与提案方案一致，另含协议收敛的连带面）：

- 新增 `RuntimeViewerApplication/RuntimeObject/RuntimeObjectCellAppearance.swift`（跨平台，不带 `#if` gate；协议仍仅 AppKit）。
- `SidebarRuntimeObjectCellViewModel`：5 `@Observed` → 1；`refreshAppearance()` 原子组装（顺带消除旧实现「tertiaryIcon 不清零」的隐性残留）；`rebuildTitleForFilterResult()` 只换 title；新增 `publishAppearance(_:)` 等值去重。
- `SidebarRootCellViewModel`：2 `@Observed` → 1（嵌套 `Appearance` struct，形态与 5 字段共享结构体不同故单独建型）。
- 协议 conformer 连带单流化：`InspectorSwiftSpecializationCellViewModel`、`InspectorRelationshipsCellViewModel`、`SpecializationTypePickerCellViewModel`（均为 init 一次组装）。
- 消费面：`RuntimeObjectCellView`（单订阅 + `apply(_:)`）、`SidebarRootTableCellView`、两处 `typeSelectStringFor` 直读、UIKit 侧 3 处直读属性。
- 测试：`TitleRebuildCounter` 改观察 `$appearance`（去重语义下计数含义不变，精确计数全部保持）；新增 `SidebarCellAppearanceTests`（一次过渡恰一事件、等值重放零事件、display-neutral splice 零事件——最后一项还消除了旧实现的冗余重绘）。

**验收复测（2026-08-09，用户实例，同款负载：五镜像索引 + SwiftUI 全量拖拽浏览）**：浏览增量与基线完全同构（`SidebarRuntimeObjectCellViewModel` 恰为 6,895 个），两条浏览验收线全部达标——`NSRecursiveLock` 125,225 → **42,218**（9.5 MiB，验收线 ≤45k），UI/Rx 簇 46.7 → **17.7 MiB**（验收线 ≤32）。全量浏览后堆存活 242 MiB、footprint 346 MB（含 59 MB 待回收页）、索引峰值 789 MB。heap 中 `BehaviorSubject<SidebarRootCellViewModel.Appearance>` 13,189 / `BehaviorSubject<RuntimeObjectCellAppearance>` 6,896，与行数一一对应，单流化按设计生效。
