# PR #88（perf/pipeline-optimizations）审查发现裁决 — 2026-08-09

对 PR #88 的 xhigh 级 code review（15 条发现，逐条完成「四问」）经跨会话双向复核后的最终裁决。
审查基线：分叉点 `8e72b6c` vs 分支 `70733b9`。审查报告由发起会话持有；本文件是**留档的裁决结论**：
误报与暂不修的记录在此，已修的登记修复 commit。ID 形式 `PR88.<N>`，编号与原报告一致。

## 已修（本批次，2026-08-09）

| ID | 严重度 | 摘要 | 修复 commit |
|---|---|---|---|
| PR88.2 | Blocker | UIKit 侧 `.just(false)` 在引擎语义如实化后使 iOS 搜索区分大小写（本 PR 引入的回归） | `a2770de`（含引擎层语义契约测试 `FilterEngineCaseSensitivityTests`） |
| PR88.3 | Major | fetch/render 拆分后 render 半段不在 `trackActivity` 内：主题/字号变更全程无加载指示；缓存命中时用户全部等待落在无指示半段 | `30d6fef`（新测试修复前红、修复后绿） |
| PR88.4 | Major | 空查询快路径先建整棵 snapshot forest 再发现不需要（reload 后 haystack 缓存冷，O(N) 白做） | `dc5df85`（新增 snapshot-free `resetToUnfiltered`，等价性测试 `SidebarFilterFastPathTests`） |
| PR88.5 | Major | `FilterEngine.filter` 先跑 `match` 再被空查询 guard 丢弃结果 | `b7eea71` |
| PR88.6 | Major | render 半段每次发射在闭包内新建 `ConcurrentDispatchQueueScheduler`（= 每次一个新 DispatchQueue） | `30d6fef`（与 PR88.3 同 commit，同一代码区域） |
| PR88.8 | Minor | `SidebarRootFilterPipeline.verdicts` 空查询会清空整棵树，仅靠唯一调用方守约 | `337ccd9`（加契约 assert；行为不变） |
| PR88.11 | Minor | cellVM 上 `appDefaults` 自 `cbb589c` 起零引用（`@Dependency` 不触发未使用告警） | `337ccd9`（删除死属性） |

## False positive（误报，留档防止重查）

### PR88.1 — 「macOS 侧边栏过滤框在首次点击 Case Insensitive 按钮前完全不生效」

**裁决：误报，整条撤销**（发起会话已确认撤销）。运行时最小 probe + 源码双证：

- 原推演认为 `NSButton().rx.state` 落到 RxAppKit `HasTargeAction+Rx.swift` 的
  `@dynamicMemberLookup` 转发（该实现确实无订阅初值），于是
  `Driver.combineLatest(searchString, isSearchCaseInsensitive)` 被闸死。
- 实际决议：**RxCocoa 在 macOS 上自带具体成员 `NSButton.rx.state`**
  （`RxCocoa/macOS/NSButton+Rx.swift:21`），具体成员在 Swift 重载决议中永远压过
  `@dynamicMemberLookup`；RxCocoa 的 `controlProperty` 在 `Observable.create` 体内
  **先 `observer.on(.next(()))` 再装 `ControlTarget`**（`NSControl+Rx.swift:61`）——
  订阅瞬间即发一次当前值。
- 运行时验证（RxAppKit 0.5.4，与仓库 pin 同版）：订阅即得初值；程序赋值
  `state = .on` 不发射（这点原推演正确）；combineLatest 从未被闸。
  `searchCaseInsensitiveButton.state = .on` 在视图构造期执行、先于 `setupBindings`
  订阅，因此初值捕获 `.on` → 默认大小写不敏感在 macOS 上真实生效。

**连带撤销**：本仓其余 4 处 `rx.state` 调用点同样解析到 RxCocoa，无需排查。

**留档的真实陷阱（这是这条误报里值得记住的部分）**：RxAppKit 的
dynamicMemberLookup / 自有 ControlProperty **确实不发初值**（同文件
`click(with:isStartWithDefaultValue:)` 的显式开关反证这是既定设计）。分界反直觉：
**同一个 NSButton 上，`rx.state`（RxCocoa）有初值，`rx.isCheck` /
`rx.stateBoolValue`（RxAppKit 自有实现）没有。** 对没有 RxCocoa 具体成员兜底的属性，
`combineLatest` 闸死的风险是真实存在的。判此类问题的排查顺序：先查 RxCocoa `macOS/`
有没有该控件的具体成员，再查 RxAppKit `Components/`，都没有才轮到 dynamicMemberLookup。

## 暂不修（backlog，后续拾起）

| ID | 严重度 | 摘要 | 状态与理由 |
|---|---|---|---|
| PR88.7 | Minor | `SemanticString+ThemeProfile` 出口处 `.copy()` 对大接口多一次深拷贝 + 瞬时 2× 峰值 | 保留拷贝（跨线程不可变性契约，已有注释）；用现成 `content.attributedStringBuild` signpost 实测大接口占比后再裁决是否优化 |
| PR88.9 | Minor | `StatefulOutlineView` 展开状态合并持久化在窗口期内被 `beginFiltering` 打断时静默丢弃、不重排 | 后果限于「重启后恢复不到最新展开状态」；改失败重排属小改动，随下一轮 outline 工作拾起 |
| PR88.10 | Minor | `RuntimeInterfaceCache` 仅按条数封顶（16），无字节预算/内存压力驱逐 | 稳态基线已降至 239 MB，大接口常驻敏感度上升；建议补字节预算或改 `NSCache`，需要作者对 16 的窗口做实测后定 |
| PR88.12 | Minor | `SharedLocalEngineTestLock` 启动屏障无 deadline，沙盒环境下整个 target 静默挂死 | 补 deadline + `Issue.record`；测试基建项，随下一轮测试工作拾起 |
| PR88.13 | Minor | 测试直写进程级 `Settings` / `AppDefaults`（UserDefaults 支撑），跨 suite 可见且崩溃时污染真实偏好 | 正解是注入 `UserDefaults(suiteName:)`；改动面涉及 Settings 依赖注入，单独立项 |
| PR88.14 | Minor | 测试接缝进入生产类型（`expansionAutosavePersistCount`、为测试去 `final`） | 与「成员默认 private」约定相抵触；重构为注入回调的成本与收益需权衡，暂记 |
| PR88.15 | Minor | 4 份新文档落在已归档的 `Plans/`、两处索引未更新；AGENTS.md 规则 #8 链接指向 Plans | 分叉点早于归档规则确立，属时序问题而非违规；**rebase 到最新 main 后**按新约定归并成 Evolutions 提案 / Internal 说明并补索引，届时更新本行 |

> 修复后回填：某条 backlog 被修掉时，按本目录惯例在行内登记修复 commit，不删行。
