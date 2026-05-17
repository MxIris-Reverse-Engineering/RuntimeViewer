# ContentTextViewController AttributedString 性能优化

**Date**: 2026-05-17
**Status**: ⏳ Pending Approval
**Branch (proposed)**: 待人工指定
**Author**: ralplan 共识规划（Planner → Architect → Critic）

---

## 1. 问题陈述

`RuntimeViewerUsingAppKit/.../Content/ContentTextViewController.swift:89-92` 中 `output.attributedString.drive(...)` 每次回调都执行 `textStorage?.setAttributedString(...)`，触发 NSTextLayoutManager 全文档重排；而 `RuntimeViewerPackages/.../Theme/SemanticString+ThemeProfile.swift:13-100` 的 `attributedString(for:runtimeObjectName:)` 每次都在主线程上从零构造一个新的 `NSMutableAttributedString`。

**最常见的"无效重建"路径**：用户点击工具栏字号 ±1 按钮 → `appDefaults.themeProfile.fontSize ± 1` → `ContentTextViewModel.swift:59-72` 的 `combineLatest` 触发 `flatMapLatest`：

```swift
Observable.combineLatest($runtimeObject, options, themeProfile, transformer)
    .flatMapLatest { ... runtimeEngine.interface(for:...) ... }   // 跨 XPC 重抓接口（最贵）
    .observeOnMainScheduler()                                      // 在主线程之前切回
    .map { $0.map { $0.attributedString(for: $1, runtimeObjectName: $2) } }  // 主线程构造
    .bind(to: $attributedString)                                   // 触发 setAttributedString 全替换
```

---

## 2. RALPLAN-DR Summary

### Principles

1. **避免无效工作**：上游若未变化或与下游无关，不触发下游重建。
2. **Re-style ≠ Re-build**：换主题/字号只需重涂色，不需重拼字符串、更不需重抓接口。
3. **重活离开主线程**：CPU 密集的属性构建必须在后台调度器。
4. **可观测、可回退**：每步可独立度量与回滚。
5. **零行为变化**：最终渲染结果（文字、字体、颜色、`.link`）与现状逐字节等价。

### Decision Drivers

- **D1**：字号/主题调整时的主线程卡顿（首要痛点）。
- **D2**：大文档（数千行 SemanticString）首次构建本身耗时。
- **D3**：实施成本与可回退性。

### Alternatives Considered

| Option | 描述 | 否决/降级原因 |
|---|---|---|
| **B（原始）** "中性 AttributedString + 重涂色" | 把构造拆成"中性串 + 增量上色"两步 API | `.link` 同时携带样式无关数据（`kind/secondaryKind/imagePath/children`），无法做纯样式重涂；改动面大。**降级为 PR3 备选**。 |
| **C** `(SemanticString, themeFingerprint) → NSAttributedString` LRU 缓存 | 单纯记忆化 | fontSize 连续值（10/11/12...）让 cache key 不稳定；NSAttributedString 大对象内存代价高。 |
| **A''（仅 PR0）** | 单独 ship `MainViewModel` 字号 click 流的 80ms throttle | **保留为可单独 ship 的 PR0**；理论上能单独覆盖 D1 大部分症状，应先收 7 天度量再决定是否继续 PR1。 |

### Recommended Decision

**分阶段三步走（PR0 → PR1 → PR2，PR3 按度量启动）**。每个 PR 独立可 ship 与回退。

---

## 3. Execution Plan

### PR0 — Toolbar 字号 throttle（独立、最便宜止血）

**改动范围**：`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift`

**具体改动**：

```swift
// 在 transform(_:) 内，给字号 click 流加 throttle
input.fontSizeSmallerClick
    .throttle(.milliseconds(80), latest: true, scheduler: MainScheduler.instance)
    .emitOnNext { [weak self] in ... }

input.fontSizeLargerClick
    .throttle(.milliseconds(80), latest: true, scheduler: MainScheduler.instance)
    .emitOnNext { [weak self] in ... }
```

**预期**：连续点击字号按钮被合并；至少不再卡用户操作流。

**Gate（重要）**：PR0 ship 后**先收 7 天度量**，再决定 PR1 是否启动；可能 PR0 单独就够。

---

### PR1 — 调度 + 去抖 + 安全收尾（必做，PR0 度量未达标后启动）

#### 1.1 拆分 Rx 管线 + 后台构建

文件：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentTextViewModel.swift`

```swift
// 三个数据流分别 distinct，避免无谓重建
let runtimeObjectStream = $runtimeObject.distinctUntilChanged()
let optionsStream = appDefaults.$options.distinctUntilChanged()
let transformerStream = transformerObservable.distinctUntilChanged()

// theme 单独 distinct（protocol 未 Equatable,手写比较器）
let themeStream = appDefaults.$themeProfile.distinctUntilChanged { lhs, rhs in
    lhs.fontSize == rhs.fontSize
        && lhs.backgroundColor == rhs.backgroundColor
        && type(of: lhs) == type(of: rhs)
}

// 数据流(runtimeObject/options/transformer)合并 → fetch interface
let interfaceStream = Observable.combineLatest(runtimeObjectStream, optionsStream, transformerStream)
    .throttle(.milliseconds(50), latest: true, scheduler: MainScheduler.instance)  // 防 background map 并发跑
    .flatMapLatest { [unowned self] runtimeObject, options, transformer -> Observable<(SemanticString, RuntimeObject)?> in
        var merged = options; merged.transformer = transformer
        return Observable.async {
            try await self.documentState.runtimeEngine
                .interface(for: runtimeObject, options: merged)
                .map { ($0.interfaceString, runtimeObject) }
        }
        .trackActivity(_commonLoading)
    }
    .catchAndReturn(nil)
    .share(replay: 1)

// 渲染流(interfaceStream × theme) → 后台构建 → 回主线程 bind
Observable.combineLatest(interfaceStream, themeStream)
    .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
    .map { pair, theme -> NSAttributedString? in
        pair.map { $0.0.attributedString(for: theme, runtimeObjectName: $0.1) }
    }
    .observeOnMainScheduler()
    .bind(to: $attributedString)
    .disposed(by: rx.disposeBag)
```

#### 1.2 API 强制 immutable 出口

文件：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Theme/SemanticString+ThemeProfile.swift:99`

```swift
// 原始
return attributedString  // NSMutableAttributedString 向上转型为 NSAttributedString,但 runtime 类型仍可变

// 改为
return attributedString.copy() as! NSAttributedString  // 强制不可变出口
```

#### 1.3 删除静态无锁 `colorCache`

文件：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Theme/ThemeProfile.swift:47-85`

```swift
// 删除
private static var colorCache: [SemanticType: NSUIColor] = [:]

// 直接 switch 返回（颜色字面量,编译器折叠）；或
private static let colorTable: [SemanticType: NSUIColor] = {
    var t: [SemanticType: NSUIColor] = [:]
    // 一次性预计算所有已知 SemanticType
    return t
}()
```

#### 1.4 收窄 `NSAttributedString: Sendable` 全局承诺

文件：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentTextViewModel.swift:118`

```swift
// 删除
extension NSAttributedString: @unchecked @retroactive Sendable {}
```

**前置检查**：先确认 `SWIFT_STRICT_CONCURRENCY` 当前值。项目 `swiftLanguageModes: [.v5]` 默认 `minimal` 检查，预期仅 warning。若编译扇出大，改为独立 `LegacySendable.swift` 标 `@available(*, deprecated, message: "narrow to specific call sites")`。

---

### PR2 — `.semanticType` 自定义 key + NSCache + 主题增量重涂（按度量启动）

#### 2.1 自定义 attribute key 与 box

新文件：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Theme/SemanticAttributeKey.swift`

```swift
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import Semantic

extension NSAttributedString.Key {
    public static let semanticType = NSAttributedString.Key("com.runtimeviewer.semanticType")
}

public final class SemanticTypeBox: NSObject, NSCopying, @unchecked Sendable {
    public let value: SemanticType
    public init(_ value: SemanticType) { self.value = value }
    public func copy(with zone: NSZone? = nil) -> Any { self }  // immutable; return self
}
```

#### 2.2 在 build 时附加 `.semanticType`

文件：`SemanticString+ThemeProfile.swift` — 在 `cachedAttributes(for:)` 返回的字典里追加：

```swift
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
    .semanticType: SemanticTypeBox(type),  // 新增,供 PR2 重涂使用
]
```

#### 2.3 ViewModel 持有 NSCache 与重涂逻辑

文件：`ContentTextViewModel.swift`

```swift
private let styledCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 8
    return cache
}()

// 数据流(interface 来) → build → 写 cache → emit
// theme 流命中 cache → 后台重涂 → emit
private func restyle(_ cached: NSAttributedString, with theme: ThemeProfile) -> NSAttributedString {
    let mutable = cached.mutableCopy() as! NSMutableAttributedString
    mutable.enumerateAttributes(in: NSRange(location: 0, length: mutable.length), options: []) { attrs, range, _ in
        guard let typeBox = attrs[.semanticType] as? SemanticTypeBox else {
            assertionFailure("Expected .semanticType on all ranges of cached attributed string")
            return
        }
        mutable.addAttributes([
            .font: theme.font(for: typeBox.value),
            .foregroundColor: theme.color(for: typeBox.value),
        ], range: range)
    }
    return mutable.copy() as! NSAttributedString
}
```

**Key**：`runtimeObject.id as NSString`（已确认 `RuntimeObject: Identifiable`,见 `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObject.swift:8`）。

**不动 `.link`** — 避开 Architect 指出的 `.link` 紧耦合 tradeoff。

---

### PR3 — 中性串拆分 / 局部更新（仅在 PR2 后字号 tap 仍 >100ms 时启动）

候选方向：

1. 真正的 API 两阶段拆分（`neutralAttributedString` + `restyle`）。
2. 评估 `replaceCharacters(in:with:)` 局部更新避免 NSTextLayoutManager 全文档重排。

**触发阈值**：UIView.h 上 fontSize tap → setAttributedString → 首屏可见,主线程耗时 >100ms。

---

## 4. ADR

| 字段 | 内容 |
|---|---|
| **Decision** | 分三阶段：PR0（toolbar throttle）→ PR1（管线拆分 + 后台 + colorCache 删除 + Sendable 收窄）→ PR2（`.semanticType` + NSCache + 重涂）；PR3 按度量决定。 |
| **Drivers** | D1 字号调整卡顿；D2 大文档构建耗时；D3 实施成本与可回退性。 |
| **Alternatives considered** | 原 Option B 中性串（降级为 PR3 备选）；Option C LRU 缓存（命中率/内存不利）；A''仅 PR0（保留为度量门控可能跳过 PR1）。 |
| **Why chosen** | 三阶段全部正交、独立可 ship 与回退；PR0 最便宜止血；PR1 解决主线程响应 + 后台并发与 thread-safety；PR2 用 `.semanticType` + NSCache 在不改 `.link` 的前提下得到主题切换近 O(R) 收益。 |
| **Consequences** | 引入自定义 `.semanticType` attribute key 与 `SemanticTypeBox`；删除 colorCache 与 Sendable extension 需前置检查；后台构建对 NSAttributedString 不可变出口有强契约。 |
| **Follow-ups** | (1) PR0 ship 后**先收 7 天度量再决定 PR1**；(2) signpost + 大类基准（UIView.h / NSResponder.h）；(3) `.link` 持有 `runtimeObjectName.children` 内存评估（Architect 评估为非问题,验证）；(4) PR3 触发阈值监控自动化。 |

---

## 5. Verification / Test Plan

### 5.1 单元

- **Mock RuntimeEngine 计数**：theme-only 变化时 `runtimeEngine.interface(...)` 调用次数必须 = 0（验证 PR1 拆分有效）。
- **Byte-equivalent 测试（PR2 强制必过）**：`restyle(cached, theme)` 输出与重新 `attributedString(for: theme, runtimeObjectName:)` 输出 `isEqual(to:)` 必须 true（确保 Principle 5 零行为变化）。

### 5.2 集成 / 基准

- **绝对延迟目标**：fontSize tap → 文本可见,主线程耗时 <16ms（60Hz 一帧）。
  - **PR0 单独**：UIView.h 上至少不阻塞用户操作流（throttle 合并连续点击）。
  - **PR1 后**：大类（NSResponder.h、UIView.h ~50KB+）首次 fontSize tap 主线程 <16ms。
  - **PR2 后**：cached 类切字号稳定 <8ms。

### 5.3 平台 smoke

- **macOS**：加载 UIView.h,连续按字号按钮 10 次,记录每次主线程 CFAbsoluteTime。
- **iOS simulator**：加载 NSObject.h,连续切字号 5 次,无 crash 且文本正确（验证 PR1 调度切换对 `UITextView.attributedText` 主线程 setter 无副作用）。

### 5.4 并发安全

- **TSan run**：开 Thread Sanitizer 跑 macOS UI 测试集,至少 10 次主题/runtimeObject 快速切换,零数据竞争报告。

### 5.5 回归

- cmd+click 跳转、Jump to Definition 菜单、TextFinder 行为不变。
- 多 document 并发主题切换无 crash。
- PR2 命中 cache 后切换 runtimeObject、再切回原 runtimeObject、再切字号 — `.link` 行为仍正确。

---

## 6. Open Questions（PR1 启动前必须先回答）

- **Q1**：`@Observed` setter 是否 main-isolated？影响 PR1 bind 端是否需要 `observeOnMainScheduler` 收尾。
- **Q2**：`NSTextStorage.setAttributedString` 内部是否再 copy？决定 `.copy()` 是必要还是过度防御。
- **Q3**：`transformer` 在 fontSize 路径上是否被 `withObservationTracking` 误触发？若是,需要在数据流入口对 transformer 也做语义 distinctUntilChanged。

---

## 7. Pending Approval

本计划**等待人工批准**。批准后建议执行顺序：

1. PR0 单独 ship → 收 7 天度量。
2. 若 PR0 不达 D1 目标 → 启动 PR1（前置先答 Q1/Q2/Q3）。
3. PR1 ship + 收度量 → 若大文档下字号仍 >16ms → 启动 PR2。
4. PR2 ship + 收度量 → 若 fontSize tap 仍 >100ms → 启动 PR3。

**未经批准前**：不开始任何代码改动、不创建分支、不提交任何 PR。

---

## 8. 评审历程

- **Planner v1**：初稿 Option A/B/C/D（推荐 D）。
- **Architect**：steelman 反 D → 指出 A' 子集足够、B 的 `.link` 紧耦合、`setAttributedString` 全文档重排才是潜在真瓶颈、colorCache 后台化硬阻塞。
- **Planner v2**：采纳 → 改为 PR1（A' 强化）+ PR2（单槽缓存按 RuntimeObject）+ PR3（按度量启动）。
- **Critic**：ITERATE → 3 Critical（按 `.font` enumerate 漏段、API 必须强制 immutable 出口、单槽 + 递归 Hashable 让大类永远 miss）+ Major（background 并发、Sendable 扇出、iOS smoke、PR3 阈值）+ Skeptic alt（toolbar throttle 应独立 ship）。
- **Planner v3（本文档）**：全部吸纳 → 加 PR0 + `.semanticType` 自定义 key + NSCache + 绝对延迟目标 + TSan + 7 天度量门控。
- **Critic 复审**：**APPROVE-WITH-RESERVATIONS** — 3 项 non-blocking minor（`SemanticTypeBox: @unchecked Sendable`、`assertionFailure` 兜底、PR0 度量门控）已吸纳。
