# 2026-10-14 一启动就崩：`helperServiceManager` 在主线程以外第一次被取

**调查日期：** 2026-10-14
**修复落地：** 本日，`next`（[0051](../Evolutions/0051-catalyst-xpc-service.md) 合进本地 `next` 后发现，修复随后合入；都未推送）
**Severity：** High —— App 一启动就崩，Debug 构建停在 `_dispatch_assert_queue_fail`
**触发场景：** 合入 0051 后启动 App。`RuntimeEngineManager.init` 起的启动任务在「重连已注入进程」这一步崩

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `EXC_BREAKPOINT`，线程是 cooperative 线程池上的 `Task 10`。栈自下而上：`RuntimeEngineManager.init` 的任务 → `reconnectInjectedEngines()` → `reconnectInjectedXPCEngines()` → `RuntimeInjectClient.fetchAllInjectedEndpoints()` → `@Dependency(\.helperServiceManager)` 的读 → `HelperServiceManagerKey.liveValue` → `MainActor.assumeIsolated` → `dispatch_assert_queue` 失败 |
| **影响范围** | `RuntimeInjectClient` 与 `RuntimeHelperClient` 的全部非隔离方法（取注入端点、装载荷、注入、拉起 Catalyst helper……）；任何让它们先于主线程取到 `\.helperServiceManager` 的启动顺序 |
| **根因** | `\.helperServiceManager` 的 live value 在 `MainActor.assumeIsolated` 里构造，只能在主线程第一次解析。两个客户端是非隔离类，用存储属性 `@Dependency` 持有它，又在非隔离的 async 方法里读——读在哪个线程，解析就在哪个线程。之前没崩，只因为 `RuntimeEngineManager.init` 在主线程同步调用 `observeDaemonAvailability()`，顺带先把这个键解析并缓存了 |
| **Status** | **Fixed** —— 两个客户端改用 `@MainActor` 计算属性，在 getter 里取依赖：每个读都先跳到主线程，编译器也会拦下新调用点 |

---

## 根因

- **这个键只能在主线程第一次解析。** `HelperServiceManager` 是 `@MainActor` 的 singleton，按 `AGENTS.md`「Singletons & Dependency Injection」的写法，
  `@DependencyEntry(liveValue: MainActor.assumeIsolated { HelperServiceManager.shared })`。swift-dependencies 在第一次读这个键时构造
  live value 并缓存，之后的读直接拿缓存；所以只有**第一次**读的线程要紧。
- **两个客户端在后台线程读它。** `RuntimeInjectClient` 与 `RuntimeHelperClient` 都是 `final class … : @unchecked Sendable`，方法不带隔离；
  包没有打开 `NonisolatedNonsendingByDefault`，非隔离的 async 方法就在 cooperative 线程池上跑。`try await helperServiceManager.ensureConnectedToTool()`
  里的 `await` 只让**调用**跳到主线程，属性包装器的读——也就是解析——发生在跳转之前，还在线程池上。
- **一直被启动顺序掩盖。** 管理器在 `init` 里同步调用 `observeDaemonAvailability()`，那里读 `helperServiceManager.daemonAvailabilityPublisher`，
  就在主线程上把这个键解析好了。0051 让走内嵌 Catalyst service 的 App 不再订阅 daemon 可用性（与 daemon 无关了），这次顺带的解析也就没了；
  两个客户端自己在 `init` 里也会排一个主线程任务去读 `status`，但那只是排队，和线程池上的读谁先到是竞态——这次线程池先到。

## 修复

两个客户端去掉存储属性，换成：

```swift
@MainActor
private var helperServiceManager: HelperServiceManager {
    @Dependency(\.helperServiceManager) var resolvedHelperServiceManager
    return resolvedHelperServiceManager
}
```

调用点一行没改：`try await helperServiceManager.ensureConnectedToTool()` 原本就有 `await`，现在它同时覆盖了对主线程属性的读。
依赖在 getter 里按调用时的任务上下文解析，跳到主线程不换任务，`withDependencies` 的覆盖照常生效（`15ed432a` 的说明里有同样的论证）。

没有把「在管理器 `init` 里先取一次」加回去：那只是把巧合写成代码，`RuntimeHelperClient.launchMacCatalystHelper()` 等别的入口仍然靠顺序活着。

## 验证

- **复现测试**：`RuntimeViewerHelperClientTests` 的 `HelperServiceManagerResolutionTests`，两个退出测试（exit test，每个用例在独立子进程里跑，
  只有全新进程才可能是第一次解析，中止也只能从外面看到）：live 依赖上下文里，从主线程以外分别调用
  `RuntimeInjectClient.fetchAllInjectedEndpoints()` 与 `RuntimeHelperClient.reconnect()`。修复前两个子进程都以 `.signal(SIGTRAP)` 结束，测试失败；
  修复后都正常退出。解析之后的 daemon 往返不在测试范围内，子进程里有 5 秒的看门狗，实测 0.07 秒就结束了。
- `RuntimeViewerHelperClientTests` 34 个、`RuntimeViewerEngineManagementTests` 50 个测试全过；App 的 Debug-arm64e 编译通过。

## 同类

- **同一形状修过一次**：`15ed432a fix(mcp): resolve the settings dependency on the main actor`，`MCPBridgeServer` 在自己的 actor 上第一次取 `\.settings`，
  当时的说明就写了「只是因为 AppDelegate 碰巧先在主线程取过」。那次只修了那一处。
- **这次横向查了全部 21 个用 `MainActor.assumeIsolated` 构造的键**（`settings`、`runtimeEngineManager`、`appRouter`、App 里的各个控制器……）和它们的每个
  `@Dependency` 使用点：除了这两个客户端，其余都在 `@MainActor` 类型或成员里、或在 `MainActor.run` 里读，没有第三处。
- 规则写进了 `AGENTS.md` 的「Singletons & Dependency Injection」：非隔离类型不要用存储属性 `@Dependency` 持有这类依赖。
