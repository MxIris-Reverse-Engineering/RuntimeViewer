# 派生数据为什么是这个形状

改 `RuntimeViewerCore/Sources/RuntimeViewerCore/DerivedDataStorage/`、`RuntimeInterfaceCorpusSnapshot`，
或 `RuntimeInterfaceCorpusStore` 里的读取阶段之前先看这篇；新增一种派生数据之前必须看。下面每一条都是代码里
看不出来、而「显然做法」会出错的地方。

对应提案：[派生数据](Evolutions/0061-derived-data.md)。术语见[术语表](Glossary.md)的「派生数据」「系统身份」
「生产者身份」「读取标记」。

---

## 一、只有两个服务进程读写，App 进程从不打开这些文件

派生数据默认关闭。只有「My Mac」与「My Mac (Mac Catalyst)」两个 Engine 实际执行所在的服务进程，在入口处调
`RuntimeDerivedData.enableInThisProcess()`：`RuntimeViewerLocalRuntimeService/main.swift` 与
`AppKitPluginImpl.runService()`。语料住在拥有镜像的进程里，存盘与读回也就只能在那里做。

其余进程一律不开：

- **App 自己**：App 的 `.local` 与 Catalyst 引擎把工作都转发给这两个服务，App 进程里只剩 Bonjour server engine
  这类在本进程应答命令的引擎，提案把它们列为非目标。App 只统计占用、整体删除（`RuntimeDerivedDataMaintenance`，
  经 `RuntimeDerivedDataController`）。
- **CLI host 与它拉起的 Catalyst helper App**：命令行与 MCP 都不建语料，第一期不管。
- **注入的载荷、模拟器、远程设备**：读的是别的进程、别的机器上的镜像，非目标。
- **测试**：绝不调它，而是用 `RuntimeEngine.useDerivedDataStore(_:)` 给引擎一个临时目录里的存储
  （`RuntimeViewerCore/Tests/AGENTS.md`、`RuntimeViewerPackages/Tests/AGENTS.md`）。

**漏调不会出错**，那个进程只是没有派生数据。所以它不像命令扩展的 `install()` 那样是「链接了就必须调」的义务，
新进程不需要跟着加。

位置是 `~/Library/Caches/<App 的 bundle id>/DerivedData`。服务进程从自己的 bundle 往上找到外面那个 `.app`，再读
它的 bundle id（`RuntimeDerivedDataLocation.enclosingApplication(of:)`）。所以 App 与它内嵌的两个服务落在同一处；
Debug、Debug-arm64e、Release 的 bundle id 不同，各有一处。

## 二、生产者身份读的是内存里的映像，带名字不带路径

一份数据由哪份代码产出，靠的是**生产者身份**：含 RuntimeViewerCore 的那个映像（`#dsohandle` 所在的映像，可能是
服务的可执行文件，也可能是 Catalyst plugin），加上它直接或间接依赖、且不在共享缓存里的映像，各取 `LC_UUID`，
连同名字一起算 SHA-256。几条看起来更简单的路为什么走不通：

- **为什么不用版本号**：Debug 构建不改版本号，而打印方式的任何改动都必须作废旧数据。`LC_UUID` 随链接内容变，
  代码一变就是另一个生产者，旧代码的产物根本不会被读到。**所以改了编码格式不必另升版本号**。
- **为什么读内存而不读磁盘上的文件**：在原地重新构建 App 时，正在跑的服务仍在执行旧代码。读磁盘会拿到新代码的
  身份，旧代码就会以新代码的名义写盘，新代码下次启动读到的却是旧代码的输出。
- **为什么带名字不带完整路径**：系统可能每次都把被隔离的 App 搬到一个新的随机位置去运行（App Translocation）。
  带路径的话，每次启动都是新的生产者。名字取 install name，没有就取文件名。
- 经「Load Frameworks…」后来加载的映像不是依赖，不算进去。

后果：每次重新构建都换一个生产者目录。几个 worktree 用同一个 bundle id 构建时共用一处，按生产者各占一个目录。

## 三、清理按「最近使用」，而不是「不是我的就删」

同一配置的几份构建（几个 worktree，加上日常用的那一份）共用一处。如果「删掉别的生产者」，两份构建会轮流把对方
的数据清空，谁也用不上。所以由服务进程在第一次用到派生数据时，按下面的规则清理一次：

- **系统目录**：build 不同的整个删掉，系统更新以后它们永远用不上了。build 相同、共享缓存 UUID 或平台不同的保留：
  另一种架构的缓存，以及 Catalyst 服务那一份（它的平台在运行时按 `isMacCatalystApp` 判定，与 macOS 那份目录名
  不同）。名字解析不出来的目录也删。当前系统目录无论如何都不删。
- **生产者目录**：除了自己，`LastUsed` 超过 14 天没更新的删掉。`LastUsed` 在第一次使用、每次写盘、运行中每隔
  24 小时都会刷新；读取时离上次刷新超过一天，也刷新一次。所以连续运行的实例永远不会被当成没人用。
- **残留**：`DerivedData.deleting-*` 删掉；临时文件，以及进程已经不在的读取标记（连同它旁边的容器），超过一天
  的删掉。

规则只看名字与时间，且从不删自己的目录，所以几个进程同时清理也不会冲突。不设大小上限，占用大小显示在设置页里。

## 四、坏文件最多让服务崩一次

服务进程每次启动、每次重连都会读派生数据。一个能让读取代码崩溃的文件，会让「My Mac」反复崩溃，所以有三道关：

1. **容器校验**（`RuntimeDerivedDataContainer`）：头部校验和；每段一个 8 字节 SHA-256 校验和；记录的解压长度
   不超过 1 GiB（`maximumDecodedSectionByteCount`，AppKit 全部分段解压后才 31 MiB），LZFSE 解压时缓冲区限定在
   这个长度内——长度来自文件，分配之前必须先查，`Int.max` 曾让缓冲区大小溢出而崩溃；头部里的种类、变体、镜像
   路径、系统目录名与生产者摘要必须和期望的一致，所以放错地方的文件也会被拒。文件**整个读进内存，不做 mmap**：
   映射着的文件一旦被另一个进程截短，碰到下一页就是 SIGBUS。校验失败的文件当场删掉。
2. **快照校验**（`RuntimeInterfaceCorpusSnapshot.corpus(from:transformer:)`）：凡是读者会 trap 的条件，都在构造
   那个值之前先查：`FrozenSemanticString` 解码器的规则、区域与文本和 span 边界的关系、条件下标、选项名
   （`VisibilityCondition.Requirement.init` 带前置条件）、嵌套区间。
3. **读取标记**（`RuntimeDerivedDataReadingMarker`）：校验总有漏网的，读者的代码也会改。所以读之前在文件旁边
   写一个 `<文件名>.reading`，记下 PID 与进程启动时间，**等解码、逐 span 遍历、选项全开与全关两次投影都做完才删**。
   - 下次读时，标记里的进程已经不在：说明上次读到一半崩了，文件不读、直接删掉。
   - 进程还在：当作同一构建的另一个实例正在读，这次不读也不删。
   - 是本进程自己的旧标记：删掉标记，照常读。

   **为什么一定要等遍历完才删**：如果只在解码后删标记，坏区域要等到某次搜索做投影时才 trap，那时标记已经没了，
   每次启动都会崩。遍历与两次投影就是要让 trap 在标记还在的时候发生。记启动时间，是为了不把恰好拿到同一个 PID
   的新进程当成读者。

## 五、什么不存

- **只存共享缓存里的镜像**：系统身份只说明得了它们的内容。磁盘上的文件可以在系统不变的情况下换掉内容。
- **打印出本进程地址的语料不存**：demangler 认不出的不透明类型，会打印成它描述符的绝对地址
  （`opaque type symbolic reference 0x…`，见 `RuntimeInterfaceCorpusSnapshot.printsProcessAddresses`）。下次启动
  地址就变了。
- 改 Transformer 产生新的变体。新变体写盘时，同一镜像旧变体的文件被删掉，所以每个镜像只留一份语料。

## 六、语料仓库里，读取在哪一步

- 一次构建先进入**读取阶段**（`Build.Phase.reading`），在仓库的 actor 之外读；读不到才进打印队列。取消、淘汰或
  换 Transformer 都会作废这次构建，读回来的东西随之丢弃（靠构建标识判断）。
- 打印完的语料**先放进仓库**（从这一刻起就能搜），**再写盘，最后才结束构建**。顺序不能反过来：App 在等这次构建
  的回复时，服务进程继承 App 请求的优先级；回复一发出，剩下的工作就落回服务进程自己的后台优先级，写盘会被拖慢
  （根 `AGENTS.md` 的 *The service runs at the priority of the requests waiting on it*，以及
  `ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`）。
- `restore(imagePaths:transformer:)` 只读不打印，给还没索引的镜像用：Always Index 的镜像在批次派发时就读回，
  启动后马上可搜。构建请求对没建索引的镜像走不到读盘那一步，引擎直接回「没建索引」，所以协调器记下请它读回过的
  镜像（`FindCorpusCoordinator` 的 `requestedRestoreImagePaths`）：语料开关重新打开时把它们再读一次；改
  Transformer 后的重建照旧发构建请求，被拒的改为读回。
- 读回中的镜像在仓库里也是一个构建，覆盖情况把它报成 `.pending`；协调器并入覆盖情况时跳过正在读回的镜像，
  否则 Report 会把它们列进排队中。

**最容易踩的一条：有语料不等于镜像已加载，更不等于已索引。** 读回语料的服务进程不一定加载了那个镜像，更没有建
它的 section。所以凡是要用 section 的地方，都必须先走 `RuntimeEngine.indexImageIfNeeded(at:)`：镜像没加载就
`loadImage`，加载了就只建索引。只调 `objectsWithProgress` 不够。目前有这几处：

- 内容区（`ContentTextViewModel.interface(of:fetchingWith:runtimeEngine:)`）：接口取到 `nil` 时先前台加载，
  再取一次接口。不论镜像是否已经建好都再取：后台索引可能恰好在第一次取与检查之间建完，而内容区不会自己再取。
- Inspector 的 Hierarchy、Relationships、References 三个页签：跟随 `imageIndexedLater(_:)`，镜像建好后重取；
  页签本身不主动建索引。
- Call Hierarchy、Callees 与 Type References：查询之前先加载根所在的镜像（`LoadRequest.imagePath`），摘要栏
  显示「Loading <镜像名>」。交叉引用只扫已建索引的镜像，不先加载就漏掉根所在镜像里的调用者或引用。

新加一个用到 section 的消费者，要照这几处之一处理。把它们集中到一处的办法评估过，行不通：放进引擎会推翻交叉
引用只扫已建索引镜像的性能规矩，在打开搜索结果时统一建索引，各处仍要在建好后重取（`KnownIssues` 里的
[PR126.11](KnownIssues/2026-10-26-pr126-review-findings.md)）。

一次读取也算进行中的工作：Report 页签显示活动标记，`BackgroundWorkProcessActivity` 让 App 不进 App Nap。

## 七、新增一种派生数据

1. 给 `RuntimeDerivedDataKind` 加一个静态常量。它的 raw value 是文件名的一部分，定了就不能改，而且只能用 ASCII
   字母和数字（`init(rawValue:)` 里有前置条件）：文件名是 `<种类>-<变体>.rvdd`，写一种数据时按「种类名-」前缀
   删掉这个种类的其他变体，而变体自己带连字符，种类名里要是也有，它的文件就会被当成别的种类的变体删掉。
2. 定一个**变体**字符串，写进系统与生产者以外、影响内容的一切输入。语料的变体是 Transformer 摘要
   （`Transformer.Configuration.derivedDataDigest`，按 pattern 排好的 C 类型替换另外追加，因为字典编码出来的
   顺序因进程而异）加上成员的排序方式。
3. 用 `RuntimeDerivedDataContainer.Builder` 编码，经 `RuntimeDerivedDataStore.read(_:variant:forImageAt:decode:)`
   读回。在 `decode` 里做完全部会 trap 的检查，并在返回之前把值完整用一遍，好让读取标记罩住它。
4. 只为共享缓存里的镜像存，内容里不得有本进程特有的值（地址、PID、时间）。
5. 某个库要放自己的缓存，从 `imageDirectory(forImageAt:)` 取目录。
6. 测试只用临时目录里的存储：Core 测试用 `DerivedDataTestIdentities.store(in:)`，Packages 测试用
   `DerivedDataFixture`。

## 量过的数字（2026-10-24，Release）

| 镜像 | 读回 | 文件 | 解压后 |
|---|---|---|---|
| Foundation | 0.155 秒 | 1.8 MiB | 15.2 MiB |
| SwiftUI | 0.319 秒 | 4.0 MiB | 31.4 MiB |
| AppKit | 0.284 秒 | 4.4 MiB | 31.1 MiB |

My Mac 的五个 Always Index 镜像（AppKit、SwiftUICore、libswiftCore、Foundation、SwiftUI）一起读回，共 0.411 秒，
最慢的单个镜像 0.411 秒（SwiftUICore），五个在盘上共 13 MiB。

成员段最初存成属性列表，光解码它就占了 AppKit 0.6 秒读取时间的一半，所以改成了定长列。量法是
`RuntimeInterfaceCorpusDerivedDataEngineTests` 里两个默认不跑的测试，要用 Release 配置并设环境变量打开：

```bash
cd RuntimeViewerCore
RUNTIMEVIEWER_DERIVED_DATA_TIMING=1 queued-build swift test -c release -Xswiftc -enable-testing \
    --scratch-path <自己的构建目录> --filter RuntimeInterfaceCorpusDerivedDataEngineTests
```
