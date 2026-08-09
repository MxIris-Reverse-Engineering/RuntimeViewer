# 0006 - MCP Transport 绑定失败的资源回收与状态如实化

- **状态**: Implemented（RV 侧全部完成；残余 5.57 MiB 为上游 SwiftMCP 引用环，见「上游跟进项 2」）
- **作者**: JH
- **日期**: 2026-08-09

## 摘要

修正 `MCPService` 的启动失败路径：`HTTPSSETransport.run()` 绑定失败（典型场景：固定端口被另一 RuntimeViewer 实例占用）时，当前实现只打日志，随后照常写端口文件、把 `serverState` 置为 `.running`，且已构造的 transport 连带 NIO 线程池（`System.coreCount` = 28 个 EventLoop、56 条线程、堆 + 线程栈 ~21 MiB）永久驻留。本提案让失败路径回收 transport、如实置 `.stopped`、不写端口文件。

## 动机

2026-08-08/09 内存剖析期间的实测：agent 启动的第二实例因固定端口 14269 被用户实例占用而绑定失败，但——

1. **资源照付全款**：`malloc_history` 归属 NIO 簇 21.4 MiB（28 个 `SelectableEventLoop` + 56 条 pthread 线程栈），服务零功能。
2. **状态谎报**：`start(for:)` 的 `startTask` 与 `transport.run()` 的 detached task 之间没有错误传播——run() 抛错只落日志，主流程 `Task.sleep(500ms)` 后照常读 `transport.port`、写端口文件、置 `serverState = .running`。菜单栏 MCP 状态显示「运行中」，实际无监听。
3. **端口文件被失败实例覆盖**：本次碰巧写入同值（14269）未被察觉；若用户实例用动态端口，失败实例会把有效端口文件覆盖成无效值，外部 MCP client 连接静默失败。

`MCPService.swift` 现状（`start(for:)`，节选）：

```swift
self.transportTask = Task.detached {
    do {
        try await transport.run()
    } catch {
        #log(.error, "MCP transport run failed: \(error)")   // 错误止步于此
    }
}
try await Task.sleep(for: .milliseconds(500))                 // 与 bind 结果无因果
let boundPort = UInt16(transport.port)
writePortFile(port: boundPort)                                // 失败也写
self.serverState = .running(port: boundPort)                  // 失败也 running
```

## 提议方案

1. **错误传播**：`transportTask` 捕获 run() 错误后回 MainActor 收尾——`transport.stop()`（关闭 NIO EventLoopGroup，释放全部线程与堆）、`transport = nil`、`serverState = .stopped`、`removePortFile()`（仅当本实例已写过）。
2. **成功判定去 sleep 化**：将「sleep 500ms 后盲读 port」替换为显式成功信号——优先用 SwiftMCP 暴露的启动回调 / bound-port 异步接口；若 API 只有轮询面，则以「run() 未抛错且 `transport.port` 有效」为准，失败路径由第 1 条兜底。落地时以 SwiftMCP 实际 API 为准，选最小改法。
3. **端口文件写入前置条件**：仅在确认监听成功后写入。

### 上游跟进项（不在本提案范围内落地）

1. **线程数硬编码**：`SwiftMCP/NIOHTTPServerAdapter` 硬编码 `MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)`。对 127.0.0.1 单客户端桥接场景，1-2 条线程足够，28 条纯属浪费（成功路径每实例 ~21 MiB 常驻）。需向 SwiftMCP 上游提议暴露 `numberOfThreads` 配置；采纳后 RV 侧传 1-2。该项独立推进，不阻塞本提案。
2. **stop 后的引用环泄漏**（落地时用 `leaks` 实证发现）：`HTTPSSETransport.adapter`（强）与 `NIOHTTPServerAdapter.engine`（强，指回 transport）互持成环，且 `stop()` 不置 `adapter = nil`。外部释放 transport 后整个环（transport + adapter + EventLoopGroup 对象图，实测 403 对象 / 5.57 MiB，大头是每个 loop 预分配 4096 槽的 `UnderlyingTask` 容量数组 28 × 208 KB）成为不可达泄漏。两侧成员均为 `private`，RV 无法从外部破环；上游一行修复：`stop()` 末尾 `self.adapter = nil`（或将 `engine` 改 weak/unowned）。**该环在成功路径的每次 stop/restart 同样泄漏**，不止绑定失败场景。

## 影响（App 型）

- **用户可见变化**：MCP 状态 UI 在绑定失败时从「运行中」（错误）变为「已停止」（如实）；双实例场景下端口文件不再被失败实例覆盖。
- **可发现性**：状态弹出框行为更可信，无新增入口。
- **数据与配置兼容**：端口文件语义不变（仅修正写入时机）。
- **平台与最低版本**：不变。
- **发布影响**：无。

## 验收标准

双实例并跑（先启动者持有固定端口）：

1. 后启动实例 `serverState == .stopped`，状态 UI 显示停止；
2. 后启动实例 heap 中 NIO 簇 ≈ 0（EventLoopGroup 已回收，无 `SelectableEventLoop` / `UnderlyingTask` 数组驻留）；
3. 端口文件内容保持先启动者写入的值；
4. 先启动实例行为不变（回归：正常启动、settings 切换端口触发 restart、退出清理端口文件）。

### 实测结果（2026-08-09，真实双实例场景：用户实例持有 14269，新构建实例后启动）

1. ✓ 单测断言 `.stopped`；真实实例绑定失败路径走通（日志 "Port in use" → 立即 teardown）。
2. **部分达成**：线程 56 → 0（进程线程总数 12，对照旧构建同场景实例 41）——线程栈与调度开销即原 ~21.4 MiB 簇的大头，已全部释放；堆上残余 5.57 MiB 不可达对象来自 SwiftMCP 的 adapter↔engine 引用环（见上游跟进项 2），RV 侧无法继续压缩。footprint 稳态 262 → 239 MB（与 0005 稳态收益合计）。
3. ✓ 端口文件全程保持 14269（用户实例所写），后启动实例失败、显式 `stop()`、进程退出三条路径均未触碰——退出路径靠新增的 `hasWrittenPortFile` 所有权守卫（旧代码在 `deinit → stop()` 时会无条件删除）。
4. ✓ 先启动实例行为不变；后启动实例正常提供除 MCP 外的全部功能。

## 风险与假设

1. **`transport.stop()` 对未成功 run 的 transport 是否安全**：需在落地时验证 SwiftMCP 该路径（未 bind 即 stop）的幂等性；若不安全则改为直接 `shutdownGracefully` 底层 group 或不复用 stop 而走专用清理。
2. **动态端口场景的竞态**：两实例同时动态起端口不会冲突，本提案不改变该路径；仅固定端口路径受影响。
3. 假设 SwiftMCP checkout 可在依赖解析中保持现版本（本提案不要求上游改动即可落地第 1、3 条）。

## 替代方案考量

### A. 按需启动（首个 MCP client 连接时才起 transport）

被搁置：MCP 的发现机制依赖端口文件先存在，「按需」需要一个先于 transport 的轻量监听器来感知连接意图，等于自建半个 server；复杂度远超收益。失败路径回收 + 上游线程数配置已覆盖绝大部分浪费。

### B. 失败时重试 / 端口冲突自动改用动态端口

有吸引力但改变了用户配置语义（用户明确指定固定端口时静默换端口，外部 client 按旧端口文件连接会更糊涂）。可作为后续 UX 提案单独讨论，本提案只做「如实 + 回收」。

## 测试策略

- 单测：模拟 run() 抛错，断言 `serverState == .stopped`、transport 已释放、端口文件未写（依赖注入文件路径已具备条件）。
- 手测：双实例固定端口并跑，对照验收标准四条。
- heap 验收沿用既有 `heap -sortBySize` 流程，确认 NIO 簇归零。

## 落地步骤

1. 失败路径错误传播 + 回收 + 状态如实 + 端口文件前置条件，单 commit（含单测）；
2. 双实例手测 + heap 复测，数字回填本提案；
3. 上游 `numberOfThreads` 提议另行推进，进展在本提案「上游跟进项」处追记。

## 落地记录（2026-08-09）

实际改法比提案方案 1 更简：SwiftMCP 的 `run()` 本就是 `start()`（bind，抛错）+ `waitUntilClosed()`（纯阻塞等待，对嵌入式使用无用），于是**直接改调 `try await transport.start()`**——返回即绑定成功，`transportTask` 与 500ms sleep 整个删除，无需任何错误回传管道（对应提案方案 2「选最小改法」）。要点：

- `startTransport(on:for:)` 从 `start(for:)` 拆出（internal 测试缝隙，不经 settings）；新增 `init(portFilePath:)` 注入端口文件路径。
- 失败路径：`transport === boundTransport` 身份守卫下置 nil → `try? await boundTransport.stop()`（释放 EventLoopGroup 线程）→ 非取消时置 `.stopped`。`Task.isCancelled` 守卫覆盖「stop/restart 竞态中旧 start 迟到」——旧实现同类竞态藏在 sleep 里，此处显式处理。
- `hasWrittenPortFile` 所有权守卫：`removePortFile()` → `removePortFileIfOwned()`，未写过文件的实例（disabled / 绑定失败）在 stop 与退出时不再删除他人文件——这是落地时发现并一并修掉的第四宗罪（提案动机只列了三宗）。
- 风险 1 验证通过：`stop()` 对未成功 bind 的 transport 幂等安全（keep-alive 未启动、sessions 为空、`adapter?.shutdown()` 可达且 bind 前已赋值）。
- 单测 `MCPServiceBindFailureTests`：winner 绑临时端口成功写文件 → loser 撞同端口失败 → 断言 `.stopped`、transport 释放、winner 文件三条路径（失败、stop、退出）均无恙。
