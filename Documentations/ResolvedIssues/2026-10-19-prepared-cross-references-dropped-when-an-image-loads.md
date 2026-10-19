# 2026-10-19 第一次显示类型引用仍要等：服务进程加载了一个共享缓存外的镜像，准备好的引用表全被作废

**调查日期：** 2026-10-19
**修复落地：** 本日，`feature/cross-references`
**Severity：** Medium —— 功能正常但第一次慢：每次启动后第一次查交叉引用都要当场把镜像重新准备一遍（Debug 下 AppKit 约 6 秒），之后才秒出；后台已经准备好的表白做了
**触发场景：** 打开文档、常驻索引的镜像准备完之后，服务进程生成某个 Swift 类型的接口（Find 的语料构建或内容区），类型的元数据访问器触发了一个类的 `+initialize`，ObjC 运行时随之加载 `/usr/lib/libobjc-trampolines.dylib`

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 用户在「第一次显示也秒出」（[提案](../Evolutions/0056-cross-references.md)同名一节）落地后试用：「第一次显示类型引用依然要等很久，后面打开的就不用等待了」 |
| **影响范围** | 本地运行时服务与 Mac Catalyst 服务里的全部交叉引用查询：Inspector 的 References 标签、Find 的三种交叉引用模式。Find 跨已索引镜像的预筛表（Debug 下 3.4 秒）也一起丢掉。Release 同样受影响，只是重建快 20–50 倍 |
| **根因** | `CrossReferenceSession.currentAnalyzer()` 把「共享缓存外的镜像列表有任何变化」当作换代：换一个新分析器，准备好的引用表、读好的名字、扫描缓存全部作废。服务进程会在准备完之后自己加载缓存外的 trampolines 库；App 的 `CrossReferencePreparationCoordinator` 以为表还在，不会再请求，于是下一次查询当场重建 |
| **Status** | **Fixed** —— 只是多加载了镜像时保留分析器；查询真要用到新加载的镜像时才换分析器，换的时候带着准备好的表与扫描结果，名字和预筛表在新分析器里后台重读；分析器认识的镜像被卸载才整个重来 |

---

## 根因

### 分析器是进程镜像的快照，换代清空一切

分析器（MachOSwiftSection 的 `CrossReferenceAnalyzer`）建立时给每个镜像编号：共享缓存里的镜像排在前面，编号固定；缓存外已加载的镜像按 dyld 的顺序接在后面。会话（`CrossReferenceSession`）每次查询、每次准备先调 `currentAnalyzer()`，原先的判据是缓存外镜像的 header 地址列表与建分析器时**完全相同**，否则：

- 换一个新分析器，`generation` 加一；
- `preparedImages`、`scans` 清空——准备好的引用表按 `generation` 存放；
- 旧分析器连同它为准备好的镜像读好的名字一起丢掉。

### 服务进程自己会加载缓存外的镜像

`libobjc-trampolines.dylib` 不在共享缓存里，ObjC 运行时在进程第一次把 block 做成方法实现（`imp_implementationWithBlock`）时才 `dlopen` 它。本地运行时服务在准备完常驻镜像之后，后台建 Find 语料：生成 Swift 接口时 `FieldLayoutRenderer` 调用类型的元数据访问器算字段布局，其中 AppKit 的 `NSEnvironmentSceneExtension` 的访问器给类发消息，触发 FrontBoardServices 的 `+[FBSSceneExtension initialize]`，它经 `+[FBSSettingsExtension extensionForProtocol:]` 用 block 造类的方法，于是 trampolines 被加载。内容区生成同样的接口也会走到这里。

这一步每次启动都会发生，而且发生在准备完成之后、用户开始点之前。下一次查询的 `currentAnalyzer()` 看到列表多了一项，便换代、作废全部准备好的表；查询的 `preparedImage(…)` 找不到表，就把这个镜像提到队首当场重建（扫描加读名字）。建好的表存在新一代里，所以之后的查询秒出——正是用户描述的「第一次要等，后面不用」。

### 上一轮为什么没发现

「第一次显示也秒出」量的 21 ms 是在测试进程里、镜像列表钉死的会话上量的。交叉引用的测试会话一律传 `imagesOutsideSharedCache: { [] }`，`CrossReferenceQueryTests.makeSteadySession` 的注释写的正是「另一个测试可能让 ObjC 运行时加载 trampolines，这会开启新的一代、丢掉测试依赖的扫描」——当时把它当成测试要躲开的干扰，没有当成真实进程里一样会发生的事。

## 现场证据

不改代码，启动用户 10:25 从本 worktree 编的 Debug 包（HEAD `192e94b0`），lldb 挂在 `RuntimeViewerLocalRuntimeService` 上，断点打在 `CrossReferenceAnalyzer.init()`、`CrossReferenceSession.currentAnalyzer()`、`CrossReferenceQuery.prepareImage(at:with:shouldContinue:)` 与 `imp_implementationWithBlock`，另每 2 秒用 `lsof` 记录服务进程映射的缓存外文件。JHs-Mac-Studio（M1 Max 10 核），macOS 26.7。

| 时刻 | 事件 |
|---|---|
| 11:40:08 | 第一个分析器建成（generation 1），缓存外只有服务自己一个镜像 |
| 11:40:09 – 11:40:59 | 五个常驻镜像依次开始准备：libswiftCore、SwiftUICore、Foundation、SwiftUI、AppKit，全在 generation 1 |
| 11:41:07 | 后台开始建 SwiftUI 的 Find 语料 |
| 11:41:30 | 第一次 `imp_implementationWithBlock`，调用栈见下 |
| 11:41:31 | FrontBoard 日志 `Realizing settings extension __NSEnvironmentSceneSettings__ on FBSSceneSettings` |
| 11:41:33 | `lsof` 看到 `/usr/lib/libobjc-trampolines.dylib` 被映射进服务进程 |

```text
#0  libobjc.A.dylib`imp_implementationWithBlock
#1  FrontBoardServices`__45+[FBSSettingsExtension extensionForProtocol:]_block_invoke
#2  BaseBoard`BSObjCClassCreate
#3  FrontBoardServices`+[FBSSettingsExtension extensionForProtocol:]
#5  FrontBoardServices`+[FBSSceneExtension initialize]
#9  libobjc.A.dylib`lookUpImpOrForward
#11 AppKit`type metadata accessor for AppKit.NSEnvironmentSceneExtension
#15 static FieldLayoutRenderer.resolveAccessorMetadata(type:machO:)
#17 SwiftDeclarationPrinter.renderModelFields(typeDefinition:typeContext:level:)
```

用户自己 10:25 那次运行的系统日志里，同一条 FrontBoard 记录出现在 10:27:11，即启动后约两分钟，说明用户那次同样踩到了。之后的「查询必然换代」一段没有在界面上实测，依据是代码：每个查询的第一步就是 `currentAnalyzer()`。

## 修复

改在 `RuntimeViewerCrossReferences`，MachOSwiftSection 不变。

- **只加载不换代。** 分析器认识的缓存外镜像仍是当前列表的前缀，就继续用它。缓存镜像排在前面，dyld 又把新加载的镜像接在最后，所以分析器给每个镜像的编号都没变，准备好的表和扫描结果照样成立。
- **要用到新镜像才换，并把东西带过去。** 查询或准备要用的路径（已索引的镜像、查询对象所在的镜像）分析器找不到、而进程又加载过新镜像时，`analyzerIncludingImagesLoaded(since:)` 换一个也包含新镜像的分析器，`generation` 加一但编号不变。准备好的表、扫描结果、进行中的准备都留着；名字随旧分析器而去，新分析器在会话队列里按 high 优先级重读，预筛表在后面重读。会话新增 `numberingGeneration`，记录当前编号始于哪一代：表、扫描、准备都按编号作废，不再按代。
- **认识的镜像被卸载才重来。** 那时它的内存已经不在，后面的镜像编号也变了，只能像原来一样整个重来。
- 建分析器、换分析器、重来各记一条 info 日志，下次看日志就知道发生过什么。

一条路径不对应任何镜像时，进程每加载一批新镜像，它会让分析器换一次；换的时候准备好的表照样保留。

## 验证

`CrossReferencePreparationTests` 新增四个测试，会话的缓存外镜像列表由测试控制，模拟进程加载、卸载镜像：

| 测试 | 修复前 | 修复后 |
|---|---|---|
| `imagesLoadedLaterKeepThePreparedImages`：准备好 Foundation 后加载一个缓存外镜像，再查 `URL` 的类型引用 | 红：又准备了一遍、换了分析器，用时 13.6 秒 | 绿：5.8 秒 |
| `imagesAskedAboutRenewTheAnalyzer`：新加载的镜像被索引后，换分析器 | 红：又准备了一遍 | 绿：不再准备、新分析器在后台读好名字 |
| `imagesUnloadedStartOver`：分析器认识的镜像被卸载 | 绿 | 绿：仍然整个重来 |
| `preparationsOutliveARenewal`：AppKit 准备到一半时换分析器 | 红：准备的结果没留下 | 绿：留下，新分析器读好名字 |

运行命令：`swift test --package-path RuntimeViewerCore --filter 'CrossReferencePreparationTests/(imagesLoadedLater|imagesAskedAbout|imagesUnloaded|preparationsOutlive)'`（Xcode 27.0，`swift test` 退出码修复前 1、修复后 0）。

**真实 App**：用户当天用重新编过的 App 试过，常驻镜像准备完之后，第一次打开类型引用直接出结果（「现在准备好是秒开了」）。没有量具体耗时。

## 横向排查

Core 里注册了 dyld 的加载、卸载回调（`DyldUtilities.observeDyldRegisterEvents()`），发出的通知没有任何监听者；别处没有「一加载新镜像就作废缓存」的写法。`RuntimeFieldLayoutMemo.removeAll()` 在引擎主动加载镜像时清空字段布局的备忘，那是为了让新镜像里的类型能解析，代价也很小，不属于同类。
