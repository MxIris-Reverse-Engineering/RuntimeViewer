# 2026-10-28 连接收到的每条消息都留在内存里，直到连接释放

**调查日期：** 2026-10-28
**修复落地：** 本日，分支 `fix/message-channel-retains-received-messages`（issue [#128](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/issues/128)）
**Severity：** Medium —— 不崩、不报错，内存随连接收到的流量只增不减，连接释放才还回去
**触发场景：** 任何经 `RuntimeMessageChannel` 收消息的连接：Bonjour 远程设备（`RuntimeNetworkConnection`）、本地 socket 与注入进程用的 TCP（`RuntimeLocalSocketConnection`）、直连 TCP（`RuntimeDirectTCPConnection`），以及 `RuntimeStdioConnection`。本机的 My Mac 与 Mac Catalyst 引擎走 XPC，不经过这个类

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 连接活着期间，它收到的每条消息（请求的回复、对方推来的状态与进度）都不释放。给一个 channel 喂 32 条 8 MB 的消息，malloc 的在用字节数涨 256 MB；活动监视器里进程的「内存」（physical footprint）却只涨 18 MB，见下文「footprint 看不出来」 |
| **影响范围** | 上面四种传输的每个连接，`next` 与 `main`（2.x）都有 |
| **根因** | `processReceivedData()` 除了把消息交给真正派发它的 dispatch 流，还 yield 进 `receivedDataStream`。这条流自 `2a0573b7` 起没有任何读者；它是默认无界缓冲的 `AsyncThrowingStream`，外面套着 Asynchrone 的 `shared()`，而 `shared()` 直到第一个迭代器创建才开始从上游拉，没有读者，上游就把每条消息存着，直到 channel 释放 |
| **Status** | **Fixed** —— 删掉这条流和读它的两个方法，连同只为它引入的 Asynchrone 依赖 |

---

## 根因

- **这条流原本有读者。** `receivedDataStream` 从 2026 年 1 月起就在（`9b48c942`、`2fdbe1f5`），四种传输都在自己的接收循环里遍历 `receivedMessages()`。
  后来分两步换成了别的读法，两次都没删掉往这条流里 yield 的那一行：
  - `f2b6324c`（2026-03-23）把 Bonjour 传输改成 `onMessageReceived` 回调（它引起的派发队列栈溢出，后来另加一条缓冲流修掉）。从这时起，Bonjour 连接的这条流就没人读了。
  - `2a0573b7`（2026-06-11，「harden message dispatch and request routing」）把其余三种传输的接收循环收进 `beginDispatch(rawWriter:)` 和它自己的 dispatch 流。
    从这时起，`receiveData()` 与 `receivedMessages()` 在整个仓库里（测试也算上）再没有调用方。
- **没有读者的 `shared()` 什么都不拉。** `SharedAsyncSequence` 把上游交给一个 `SubSequenceManager` actor，只有 `add(id:continuation:)`——也就是
  有人建了迭代器——才调用 `subscribeToBaseSequenceIfNeeded()` 去遍历上游。上游是 `AsyncThrowingStream<Data, Error>.makeStream()`，缓冲策略默认 `.unbounded`，
  于是每条 yield 进来的消息都留在流的缓冲区里。
- **`finishReceiving(throwing:)` 也救不回来。** 它 finish 了这条流，但流结束前缓冲的元素要留给读者读完，一直待到流的存储被释放，也就是 channel 释放时。

## footprint 看不出来

issue 里的测量是把同样的写法单独拿出来：一条套了 `shared()` 的流、不读、yield 32 条 8 MB 的消息，physical footprint 涨 248 MB。这里复现也是如此：
只有流涨 257 MB，套了 `shared()` 也是 257 MB。可是换成真的 channel，footprint 只涨 18 MB，而这时流里确实存着全部消息：
把流读出来，正好 32 条、268,435,456 字节；malloc 的在用字节数也正好多了 256 MB。把缓存的消息逐页各读一个字节，footprint 立刻变成 274 MB。

差别出在复制上。channel 把每条消息复制两次：追加进接收缓冲区，再用 `subdata(in:)` 取出来。Foundation 的 `Data` 复制按页对齐、至少 4 页的区间时用
`vm_copy`（swift-foundation 的 `__DataStorage.move` → `Platform.copyMemoryPages`），这样复制出来的页要等有人读写才记到进程的 footprint 上，
而没人读的消息正好永远没人碰。所以活动监视器低估了这个泄漏，内存其实一直被占着。也因此，issue 原计划「量 footprint、增长不超过 64 MB」的回归测试在修复前也是绿的
（18 MB），抓不住这个问题；回归测试改量 malloc 的在用字节数，见「验证」。

## 修复

- `RuntimeMessageChannel.swift`：删掉 `receivedDataStream`、`receivedDataContinuation`、`setupStreams()`、`receiveData()`、`receivedMessages()`，
  以及 `processReceivedData()` 里的 yield 和 `finishReceiving(throwing:)` 里的 finish。消息现在只交给 dispatch 流（`beginDispatch` 之后才有）和 `onMessageReceived`。
  两行调试日志原来报 `continuation=`，改报 `dispatching=`：有没有 dispatch 的读者，没有时消息只交给 `onMessageReceived`。`dispatchContinuation` 上提到
  `receivedDataStream` 的注释一并改掉。
- **去掉 Asynchrone。** 这是 RuntimeViewer 唯一用到它的地方。`RuntimeViewerCore/Package.swift` 删掉这个包和 `RuntimeViewerCommunication` 对它的依赖，六份提交的
  `Package.resolved` 删掉它的 pin，其余 pin 一个不动（没有用会移动所有 pin 的 `UpdatePackagesScript.sh`）：

  | 锁文件 | 做法 | diff |
  |---|---|---|
  | `RuntimeViewerCore` | `swift package resolve` | 删 asynchrone；`originHash` 变（清单变了） |
  | `RuntimeViewerPackages` | `swift package resolve` | 删 asynchrone；`originHash` 变——它原来的值已经对不上自己的清单，SwiftPM 因此整体重新解析，pin 照旧保留 |
  | `RuntimeViewerCommandLine` | `swift package resolve`，先临时改掉 `originHash` | 只删 asynchrone；`originHash` 由 SwiftPM 算回原值 |
  | `RuntimeViewer-Debug.xcworkspace`、`RuntimeViewer-Distribution.xcworkspace` | `xcodebuild -resolvePackageDependencies`，独立的 DerivedData | 只删 asynchrone（v2 格式，没有 `originHash`） |
  | `RuntimeViewerServer.xcodeproj` | 手工删掉那一条 | 只删 asynchrone |

  两处需要说明：
  - **CommandLine 的锁文件要先改掉 `originHash`。** SwiftPM 的 `originHash` 只是根清单内容的 hash（`computeResolvedFileOriginHash`）。CommandLine 的清单没变，
    hash 对得上，`swift package resolve` 就按锁文件直接用，不再用的 pin 也留着；hash 对不上时它才整体重新解析，保留现有 pin，只写回实际需要的依赖。
  - **Server 工程的锁文件只能手改。** 这个工程没有任何包引用，它的包产物全由所在的 workspace 提供，单独解析它得不到依赖；这份锁文件早已不跟着 `next` 走
    （`70dc6e17` 的说明里写过）。

## 验证

- **回归测试**：`RuntimeViewerCommunicationTests` 的 `RuntimeMessageChannelReceivedMessageRetentionTests`，一个退出测试（exit test，在独立子进程里跑，
  别的套件同时分配的内存不会干扰读数；子进程里失败的期望会连同测得的数值报回父进程）。给一个没有读者的 channel 喂 32 条各自独立缓冲区的 8 MB 消息，
  要求 malloc 的在用字节数增长不到一条消息。修复前增长 268,439,200 字节，失败；修复后 32 字节（连跑 3 次相同），通过。
- **锁文件**：六份的 diff 都只删了 asynchrone 那一条，另有 Core 与 Packages 的 `originHash` 变化，原因见上表。
- **Core 全量测试**（`--skip RuntimeBackgroundIndexingManagerTests` 跑全量，再单独跑它）：`RuntimeViewerCommunicationTests` 239 个（含全部传输层与连接回归测试）、
  `RuntimeViewerCoreTests` 565 个、`RuntimeViewerInjectionTests` 36 个、后台索引管理器 27 个全过。`RuntimeViewerCrossReferencesTests` 70 个里
  `CrossReferencePreparationTests` 有两个在全量时失败；它们用进程内的 `.local` 引擎、不经过任何连接，当时机器负载在 25–44 之间，单独重跑 15 个全过。
- **App**：`RuntimeViewer-Debug.xcworkspace`、scheme `RuntimeViewer macOS`、Debug 配置，连同作为 target 依赖的 Catalyst helper、service 与模拟器载荷编过（228 秒），
  构建日志里不再出现 Asynchrone，六份锁文件构建前后不变。

## 同类

- **横向查了源码里全部 11 处 `AsyncStream` / `AsyncThrowingStream` 的创建**（8 处 `makeStream`、3 处闭包初始化）：其余各处要么在创建时就配好了读者任务，
  要么交给调用方当场遍历，没有第二条「一直往里 yield、却可能没人读」的长寿命流。Asynchrone 的 `shared()` 只在这里用过。
- **以前没修过这条流。** 两次让它失去读者的改动（`f2b6324c`、`2a0573b7`）都只换了读法。同属「`AsyncStream` 的读者没想清楚」一类的还有
  [Find 搜不到任何结果](2026-09-29-find-corpus-never-built-indexing-events-split.md)：那次是一条流有两个读者、互相瓜分元素，这次是零个读者。
- **`main` 不修。** `main` 的 2.x 代码同样包含 `2a0573b7`，有同一个泄漏；按分支模型，`main` 只承载 Sparkle feed，不再接收代码改动。
  它仍依赖 Asynchrone，所以那个 fork 可以归档（归档后照样能拉取），但不能删除。
