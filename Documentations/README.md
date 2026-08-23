# RuntimeViewer 文档索引

本目录收录 RuntimeViewer 的全部设计、演进与排障文档。**新增或重命名任何文档都必须同步更新这份索引。**

| 目录 | 用途 |
|------|------|
| [`Evolutions/`](Evolutions/) | **提案** —— 今后所有新功能与架构改动的唯一入口，一次改动一份文件，见 [提案索引](Evolutions/README.md) |
| [`Plans/`](Plans/) | 提案制确立前的设计与实现计划，同一件事常拆成 `-design` / `-plan` 两份。保留归档，不再新增 |
| [`ResolvedIssues/`](ResolvedIssues/) | 已定位并修复的疑难问题纪要，含根因与验证过程 |
| [`KnownIssues/`](KnownIssues/) | 代码审查发现但当时未修的问题快照，见 [子索引](KnownIssues/README.md) |
| [`Reviews/`](Reviews/) | 针对某项工作的多轮审查闭环记录 |

## 架构与运维

- [`CommunicationAndEngineArchitecture.md`](CommunicationAndEngineArchitecture.md) —— `RuntimeViewerCommunication` 的连接实现，以及 `RuntimeEngineManager` / `ProxyServer` 的整体架构。
- [`EngineMirroringWalkthrough.md`](EngineMirroringWalkthrough.md) —— 跨主机 RuntimeEngine 共享系统的只读走读：四类 engine 集合如何拼合、Bonjour 如何建立管理通道、runtime 数据如何流经 proxy 层。读 `RuntimeEngineManager.swift` 等源码前建议先看。
- [`SparkleRelease.md`](SparkleRelease.md) —— 发布流程、EdDSA 密钥管理与应急处理手册。

## 提案（Evolutions）

见 [`Evolutions/README.md`](Evolutions/README.md)。当前 10 篇：Bonjour 可靠性、IDA 兼容导出、后台索引、泛型类型特化、DifferentiableBox 渲染范式、MCP Transport 绑定失败回收、ObjC 关系索引归还应用侧、ObjC 与 Swift 索引层对称化、接入 UIFoundation Settings、支持注入 iOS Simulator 进程。

## 设计与实现计划（Plans，归档）

按时间倒序。同一主题的设计与计划并列给出。

- **Swift Jump to Definition**（2026-07-23）—— 让 Swift 类型 token 支持右键跳转定义与 ⌘-click，补齐与 ObjC token 的差距。
  [设计](Plans/2026-07-23-swift-jump-to-definition-design.md)
- **导航时间线与 Tab 解耦**（2026-07-23，已实施）—— 改为 Xcode 式全局历史。
  [设计](Plans/2026-07-23-navigation-timeline-tab-independence-design.md)
- **多 Tab 内容导航**（2026-07-20，待实现）—— 窗口内轻量 tab，复用 `UIFoundationAppKit.TabsControl`；含对私有 `NSTabBar` 与自绘方案的否决理由。
  [设计](Plans/2026-07-20-multi-tab-content-navigation-design.md)
- **sharingd 注入：mach_vm_remap**（2026-07-16）—— 复刻 Apple 的 `mach_vm_remap` 设计以注入 seatbelt 沙盒进程。
  [设计](Plans/2026-07-16-sharingd-injection-via-mach-vm-remap-design.md)
- **主题外观配置面板**（2026-06-23）—— 把此前硬编码的单一语法高亮主题改为可配置。
  [设计](Plans/2026-06-23-theme-settings-panel-design.md)
- **Helper Service 抽离**（2026-05-23）—— 把特权 helper 守护进程与客户端 XPC 通信三个 target 整合进 `swift-helper-service`，再以薄包装集成回来。
  [设计](Plans/2026-05-23-helper-service-extraction-design.md) · [计划](Plans/2026-05-23-helper-service-extraction-plan.md)
- **Inspector Relationships**（2026-05-19）—— Inspector 中的类型关系展示。
  [设计](Plans/2026-05-19-inspector-relationships-design.md) · [计划](Plans/2026-05-19-inspector-relationships-plan.md)
- **Content 文本 AttributedString 性能优化**（2026-05-17）—— `ContentTextViewController` 的富文本构建开销。
  [文档](Plans/2026-05-17-content-text-attributedstring-optimization.md)
- **嵌套泛型特化**（2026-05-11）—— 把特化表单从 `NSGridView` 平铺升级为 `NSOutlineView` 树形，支持 `Box<Array<Int>>` 这类递归填充。
  [设计](Plans/2026-05-11-nested-generic-specialization-design.md) · [计划](Plans/2026-05-11-nested-generic-specialization-plan.md) · [性能补充](Plans/specialization-typepicker-perf-r2.md)
- **Debug arm64e RunScript**（2026-05-06）—— 新增 Debug workspace 与 `Debug-arm64e` 配置，用命令行 xcodebuild 绕开 Xcode GUI 在 arm64e 下的编译 bug。
  [设计](Plans/2026-05-06-debug-arm64e-runscript-design.md) · [计划](Plans/2026-05-06-debug-arm64e-runscript-plan.md)
- **CodeEditorView Gutter 与 Minimap 移植**（2026-05-05）—— 从 mchakravarty/CodeEditorView 移植行号栏与缩略图。
  [设计](Plans/2026-05-05-codeeditorview-gutter-minimap-port-design.md) · [计划](Plans/2026-05-05-codeeditorview-gutter-minimap-port-plan.md)
- **后台索引 — 历史区**（2026-04-29）—— 弹出框内新增 `HISTORY` 区，回看本次会话的每一批索引结果。
  [计划](Plans/2026-04-29-background-indexing-history-plan.md)
- **后台索引**（2026-04-24）—— 提案 [0002](Evolutions/0002-background-indexing.md) 的实现计划。
  [计划](Plans/2026-04-24-background-indexing-plan.md)
- **Sparkle 自动更新集成**（2026-04-21）—— 单 feed EdDSA 多通道，并用统一的 `ReleaseScript.sh` 取代 `ArchiveScript.sh` 与臃肿的 CI workflow。
  [设计](Plans/2026-04-21-sparkle-integration-design.md) · [计划](Plans/2026-04-21-sparkle-integration-plan.md) · [遗留事项](Plans/2026-04-21-sparkle-integration-followup.md)
- **Switch Source 改用 NSMenuToolbarItem**（2026-04-04）—— 解耦标题/图标与菜单内容，使断开的 engine 能显示「(Disconnected)」而不被菜单重建吞掉选中项。
  [设计](Plans/2026-04-04-switch-source-menu-toolbar-item-design.md) · [计划](Plans/2026-04-04-switch-source-menu-toolbar-item-plan.md)
- **Sidebar 加载进度条**（2026-04-03）—— 把不确定进度的转圈换成能报告 ObjC/Swift section 逐项进度的确定式进度条。
  [设计](Plans/2026-04-03-sidebar-loading-progress-design.md) · [计划](Plans/2026-04-03-sidebar-loading-progress-plan.md)
- **Socket 注入端点重连**（2026-03-31）—— 让沙盒（socket）注入的 App 在宿主重启后自动重连，对齐 XPC 路径的能力。
  [计划](Plans/2026-03-31-socket-injected-endpoint-reconnection-plan.md)
- **XPC 注入端点重连**（2026-03-26）—— 用 Mach Service 守护进程作为持久 XPC 端点注册表，使宿主重启后能重新发现已注入的非沙盒 App。
  [设计](Plans/2026-03-26-injected-endpoint-reconnection-design.md) · [计划](Plans/2026-03-26-injected-endpoint-reconnection-plan.md)
- **Engine 图标**（2026-03-22）—— 按机型标识符显示设备图标，附加进程显示 App 图标，远程镜像 engine 单独区分。
  [设计](Plans/2026-03-22-engine-icons-design.md)
- **远程 Engine 镜像**（2026-03-21 / 03-22）—— macOS 客户端镜像远程主机经 Bonjour 发现的全部 RuntimeEngine，支持传递共享、环检测与按主机分组。
  [设计](Plans/2026-03-21-remote-engine-mirroring-design.md) · [计划](Plans/2026-03-22-remote-engine-mirroring-plan.md)
- **MCP 工具栏状态指示**（2026-03-09）—— 工具栏彩色图标显示 MCP server 的 disabled/stopped/running 状态，弹出框提供详情与控制。
  [计划](Plans/2026-03-09-mcp-toolbar-status.md)
- **Bonjour 可靠性**（2026-03-03）—— 提案 [0000](Evolutions/0000-bonjour-reliability.md) 的实现计划。
  [计划](Plans/2026-03-03-bonjour-reliability.md)
- **MCP 多客户端**（2026-03-02）—— 用应用内 Streamable HTTP server 取代单客户端 stdio 架构，支持多个 LLM 客户端并发连接。
  [设计](Plans/2026-03-02-mcp-multi-client-design.md) · [计划](Plans/2026-03-02-mcp-multi-client-plan.md)
- **导出向导增强**（2026-02-17）—— 基于 `NSTabViewController` 的多步向导，支持选择性导出与 ObjC/Swift 分别配置格式。
  [设计](Plans/2026-02-17-export-wizard-enhancement-design.md) · [计划](Plans/2026-02-17-export-wizard-enhancement-plan.md)
- **Interface 导出 API**（2026-02-16）—— 在 `RuntimeViewerCore` 中提供统一的 ObjC/Swift 接口导出 API，经 `AsyncStream` 报告进度。
  [设计](Plans/2026-02-16-interface-export-design.md)

## 已解决的疑难问题（ResolvedIssues）

按时间倒序。

- [注入 iOS Simulator 进程：宿主的地址不能喂给目标](ResolvedIssues/2026-08-23-simulator-injection-host-address-fallacy.md)（2026-08-23）—— 打崩三个 SpringBoard 的根因、它的三个变体，以及三个会把排查带偏的诊断陷阱。
- [库校验拦住 dlopen 注入](ResolvedIssues/2026-08-06-library-validation-blocks-dlopen-injection.md)（2026-08-06）—— Music 一类 Apple App 附加不上的原因。
- [从 Inspector 跳转时 sidebar 选中高亮闪烁](ResolvedIssues/2026-08-05-sidebar-selection-highlight-flicker.md)（2026-08-05）
- [协议归属过滤导致整个 image 的 ObjC 协议全部消失](ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md)（2026-08-05）
- [切换 RuntimeObject 时 Inspector 闪烁](ResolvedIssues/2026-08-05-inspector-runtime-object-switch-flicker.md)（2026-08-05）
- [Strict-seatbelt payload runtime handoff 抽离到 MachInjector loader](ResolvedIssues/2026-07-18-strict-seatbelt-payload-runtime-handoff.md)（2026-07-18）
- [mach_vm_remap POC 实证纪要（M1–M3）](ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md)（2026-07-17）
- [sharingd 代码注入调查纪要](ResolvedIssues/2026-07-16-sharingd-sandbox-injection-investigation.md)（2026-07-16）
- [注入 seatbelt 守护进程后 XPC 回连被沙盒拒绝](ResolvedIssues/2026-07-14-seatbelt-daemon-injection-socket-fallback.md)（2026-07-14）—— 回退到 socket 的经过。
- [注入连接被拒后 engine 残留、无 UI 提示](ResolvedIssues/2026-07-14-attached-engine-handshake-confirmation.md)（2026-07-14）
- [注入场景下目标进程主二进制解析错误](ResolvedIssues/2026-05-24-injected-server-main-binary-resolution.md)（2026-05-24）

## 审查记录（Reviews）

后台索引（提案 0002）的完整审查闭环，五轮：

- [第一轮](Reviews/2026-04-24-background-indexing-review.md)（2026-04-24）
- [第二轮](Reviews/2026-04-25-background-indexing-review.md)（2026-04-25）
- [第三轮](Reviews/2026-04-26-background-indexing-review.md)（2026-04-26）
- [UltraReview 发现](Reviews/2026-04-26-background-indexing-ultrareview.md)（2026-04-26）
- [实现审查（最终轮）](Reviews/2026-04-26-background-indexing-implementation-review.md)（2026-04-26）

## 待办问题快照（KnownIssues）

见 [`KnownIssues/README.md`](KnownIssues/README.md)。四份审查发现记录：v2.0.0-RC.4 预发布审查（2026-04-10）、UltraReview（2026-04-17）、Engine 镜像路由（2026-04-30）、主题设置面板（2026-06-25）。
