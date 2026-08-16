# 2026-08-10 - Land the PR #88 Open Quickly perf fixes

- **日期**: 2026-08-10
- **任务**: Land the PR #88 Open Quickly perf fixes
- **作者**: Mx-Iris
- **仓库**: git@github.com:MxIris-Reverse-Engineering/RuntimeViewer.git

## 1. 问题 / 任务

接手另一会话卡住的工作：PR #88（`perf/pipeline-optimizations`）第二轮 review 的三条
Open Quickly 修复（F9 被作废趟丢弃 haystack 构建、F10 materialize 时主线程重建 haystack、
F11 宽查询无界 materialize）生产代码已写好、能编译，但三条依赖引擎的复现测试全部卡在
`loadState == .notLoaded` 超时。要求：排查卡点、每条完成「修复前红、修复后绿」验证、
全量测试在分支锁定 pin 下通过、按发现拆成独立 commit 推送，并补写第二轮 15 条发现的
裁决文档与 KnownIssues 索引。工作区限定在独立 worktree
`.claude/worktrees/pr88`，不碰主工作区。

## 2. 探索与调研

### 调研内容

- `SidebarRuntimeObjectViewModel.reloadData()` 的 `loadState` 状态机（`.notLoaded` 的唯一赋值来源）
- 卡住的 `OpenQuicklyMaterializationBoundsTests` 与能通过的对照 `OpenQuicklyLazyConstructionTests` 的 Harness 逐行对比
- `RuntimeEngine.local` / `imageList` / `isImageLoaded` / `dispatch` 语义；`pollUntil`、`SharedLocalEngineTestLock`、`withLiveDependencyContext` 实现
- `RuntimeImageNode` 的 `parent`（weak）、`absolutePath`（lazy）、`rootNode(for:name:)`、`removeFirstPathComponent()` 全文
- 对照实验：同一环境、同一编译产物下分别运行两个套件

### 关键发现

- `.notLoaded` 不是初始态（初始为 `.unknown`），是 `isImageLoaded(path:) == false` 的主动赋值——问题即「引擎不认这个 `imagePath`」，不是 reload 没跑、不是依赖上下文、不是 init 链差异（前会话排除清单里的方向全部无关）。
- **根因**：`RuntimeImageNode.parent` 是 weak 边、`absolutePath` 是 lazy 且靠 parent 链推导；`var imageNode = rootNode(...)` 原地下钻在第一次重赋值时丢掉 root 的唯一强引用，祖先链逐层释放，叶子 `path` 坍缩为 `"/"`。
- 对照测试同款逻辑靠一个 `let rootImageNode` 中间变量在 -Onone 下侥幸存活——依赖未承诺的 ARC 行为，本质同样脆弱。
- **F9 测试设计缺陷**（红态推演时发现）：`gate.release()` 同时放行两趟构建，未被作废的当前趟自己会装缓存，该测试在旧代码下也绿，抓不住回归。

### 候选方案

| 方案 | 优点 | 缺点 |
|------|------|------|
| Harness 持有 root 属性保活整棵树 | 直观 | 多一个字段，且叶子路径仍依赖树存活时序 |
| 下钻前锚定 root + `withExtendedLifetime` 内固化叶子 `absolutePath`（选定） | 路径值固化后与树生命周期解耦，改动最小 | 需要一段注释解释为什么这行不能删 |
| 改生产 `RuntimeImageNode`（parent 改强引用或 absolutePath 非 lazy） | 根治 | 超出授权范围（引用环风险、影响面大），不属于本次测试脚手架修复 |

## 3. 最终方案

三条生产修复方案维持前会话已获批准的原样（F11 按分数截断前 500 行、F10 seed 播种、
F9 版本号守卫下提前安装），仅修测试脚手架：`makeImageNode()` 锚定 root 并在
`withExtendedLifetime` 内固化叶子 `absolutePath`；F9 测试的 gate 增加 `releaseNext()`
只放行被作废那趟，断言后再全量 `release()` 清理。落地方式按既有批准执行：每条发现
独立 commit（代码 + 测试同 commit）推 `perf/pipeline-optimizations`，普通 push；
另补第二轮裁决文档与 KnownIssues 索引。用户在执行中途通过发起会话补充确认
「完成之后直接推送，不必回来等确认」。

## 4. 实际执行与改动

### 改动清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/OpenQuicklyMaterializationBoundsTests.swift` | 修改 | 修 `makeImageNode()` 生命周期陷阱；gate 加 `releaseNext()`；F9 测试改为只放行被作废趟；suite 注释 "two costs" 修为 "residual costs" |
| `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift` | 修改 | 前会话已写好的 F9/F10/F11 改动，按逆向中间态拆分入三个 commit |
| `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectCellViewModel.swift` | 修改 | 前会话已写好的 `seedCurrentAndChildrenNames(_:)`，归入 F10 commit |
| `Documentations/KnownIssues/2026-08-10-pr88-max-review-findings.md` | 新建 | 第二轮 15 条发现裁决（`PR88R2.<N>`）：6 已修含哈希、F5/F12 降级、F14 正确性段撤销、6 backlog、复核提级项与本次新发现 |
| `Documentations/KnownIssues/README.md` | 修改 | 补 2026-08-09 与 2026-08-10 两份裁决文件的索引行 |

落地 commit（推送区间 `9f32e85e..4a979469`）：

- `523d98dd` — F9 `perf(sidebar): install a superseded Open Quickly pass's haystack build`
- `b3c65095` — F10 `perf(sidebar): seed materialized Open Quickly cells with the pass's haystack`
- `11238751` — F11 `perf(sidebar): cap Open Quickly materialization at the top 500 matches`
- `4a979469` — `docs(known-issues): adjudicate the second PR #88 review pass`

### 关键命令

```
swift test --scratch-path /tmp/claude/SwiftPM/RuntimeViewerPackages-pinned \
  --disable-automatic-resolution [--filter <suite|test>]
# 成败一律以 ${pipestatus[1]} 原始退出码判定，未经 xcsift
git push origin perf/pipeline-optimizations   # 普通 push，fast-forward
```

### 验证

- 红/绿逐条：F9 还原安装位置 → 21.2s 超时红（exit 1）；F10 移除 seed → SeedMarker 断言 1.1s 红；F11 取消截断 → 两条 count==cap 断言红（1200≠500）；各自恢复后绿。
- 三个 commit 按逆向中间态构建（F9-only → +F10 → +F11），每个中间态独立编译并跑在场测试（1/3/4 条）全绿后才提交。
- 全量：101 tests in 18 suites 全部通过（exit 0），`Package.resolved` 全程无改动。

### 与原方案的差异

- **差异点**: F9 测试的 gate 从单一 `release()` 改为 `releaseNext()` + 末尾 `release()`。
  **原因**: 红态推演证明原设计在旧代码下也绿（未被作废的当前趟自己装缓存），测试无效。
  **影响**: 该测试现在能真实抓住回归（红态验证 21.2s 超时失败证实）。
- **差异点**: 测试文件 suite 注释 "the two costs" 改为 "the residual costs"。
  **原因**: 原文 "two" 与实际列出的三个 bullet 数目不符。
  **影响**: 仅措辞，无行为变化。
- 其余与最终方案一致；三条生产修复未做任何方案级改动。
