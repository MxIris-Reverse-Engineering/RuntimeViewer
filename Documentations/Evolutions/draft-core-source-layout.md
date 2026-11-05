# Draft - RuntimeViewerCore 包的源码按功能分目录，一个类型一个文件

- **状态**: In Progress
- **创建日期**: 2026-11-05
- **最后更新**: 2026-11-05
- **实现分支 / PR**: `feature/core-source-layout`（从 `next` 切，并回 `next`）

## 摘要

RuntimeViewerCore 包五个 Swift target 共 152 个源文件、241 个顶层类型，其中 39 个文件装了 153 个类型——最多的 `RuntimeCrossReferenceModels.swift` 有 17 个，`RuntimeInterfaceSearch.swift` 有 15 个。目录也分不清：`Common/` 的 25 个文件分属对象、接口、搜索、关系、书签、特化等功能；`Core/` 混着 section、镜像读取和 engine 共用的协议；engine 本体和另外 13 个文件散在 target 根目录；`Indexing/` 与 `BackgroundIndexing/` 名字相近，管的却不是一回事。本提案只搬文件、拆文件：按功能重新分目录，除 `private` / `fileprivate` 的辅助类型外一个顶层类型一个文件。不改类型名、行为和公开 API。

## 方案

### 一、规则

1. 一个顶层类型一个文件，文件名就是类型名。以下留在原文件，不单独成文件：
   - `private` / `fileprivate` 的类型和扩展，跟着用它的那个类型；
   - 嵌套类型，跟着外层类型或声明它的扩展（例如 `RuntimeEngine+Commands.swift` 里的 22 个命令结构体）；
   - 只为一个类型服务的 typealias、全局变量和函数，跟着那个类型；
   - `RuntimeRequests.swift`：八行给 helper 的请求与回包类型补的 `RuntimeRequest` / `RuntimeResponse` 遵循，拆成八个一行的文件没有意义。
2. 类型自己的扩展留在类型的文件里；扩展的内容属于另一个功能时，照现有写法放进那个功能的目录，命名为 `类型+功能.swift`（如 `RuntimeEngine+Search.swift`）。
3. 给别的类型（包括其他模块的类型）加的、不是 file-private 的扩展，单独成 `被扩展的类型+用途.swift`。
4. 目录按功能分：一个功能的模型、实现和 `RuntimeEngine+功能.swift` 放在一起；几个功能共用的模型放 `Objects/`、`Interfaces/`、`Images/`。
5. 访问级别只在拆文件不得不动时才动（见「三」）；import 按拆出来的文件实际用到的补齐。

### 二、目录

RuntimeViewerCore target（每个文件的去向见文末清单）：

| 目录 | 放什么 | 主要来自 |
|------|--------|----------|
| `Engine/` | `RuntimeEngine` 本体，以及几个功能都要用的部分：主机信息、数据变更事件、镜像路径规范化 | 根目录、`Common/` |
| `Engine/Commands/` | 命令机制：命令协议、命令名、注册器、进度信封、请求的取消与转发 | 根目录 |
| `Engine/Serving/` | 把 engine 提供给别的进程：连接服务器、代理服务器、远端 engine 描述 | 根目录 |
| `Images/` | 镜像从哪来、怎么读：读取方式、镜像目录（catalog）、镜像索引、镜像节点、dyld 工具 | `Core/`、`Catalog/`、`Common/`、`Utils/` |
| `Objects/` | 运行时对象：`RuntimeObject`、种类、对应面、成员地址、private 声明、加载进度 | `Common/` |
| `Interfaces/` | 接口文本：`RuntimeObjectInterface`、回包、注释结构、文本范围、Swift 生成选项 | `Common/`、`Core/RuntimeSwiftSection.swift` |
| `Sections/`、`Sections/ObjC/`、`Sections/Swift/` | 每个镜像的 ObjC / Swift section、factory、接口 indexer，以及它们的协议 | `Core/`、`Indexing/` |
| `Search/`、`Search/Corpus/`、`Search/Matching/` | Find：查询与结果模型；语料的构建、存放与快照；文本与成员匹配 | `Search/`、`Common/` |
| `Relationships/` | Inspector 的关系行与 Find 的关系树：resolver、协议、模型 | `Relationships/`、`Common/`、`Core/` |
| `Specialization/` | 泛型特化的请求、选择、校验与 engine 接口 | `Common/`、根目录 |
| `Bookmarks/` | 书签与书签作用域 | `Common/` |
| `BackgroundIndexing/`、`Export/`、`DerivedDataStorage/`、`Offline/` | 保留，收进各自的 `RuntimeEngine+功能.swift` 和拆出来的类型 | 原目录、根目录 |
| `LocalRuntimeService/`、`Transformer/` | 不动 | — |
| `Extensions/` | 标准库扩展（原 `Utils/`：dyld 工具搬去 `Images/` 后只剩这些） | `Utils/`、`Common/RuntimeImageNode.swift` |

其余 target：

| Target | 怎么分 |
|--------|--------|
| RuntimeViewerCommunication | 根目录只留 `RuntimeSource`、`RuntimeDeviceMetadata`、`RuntimeCommunicator` 和它的错误类型。`Connections/` 根放连接协议与各种传输共用的类型，每种传输一个子目录：`DirectTCP/`、`LocalSocket/`、`Network/`（并入原 `Network/` 的 Bonjour 发现）、`Stdio/`、`XPCMachService/`、`XPCService/`。`Messaging/` 放消息通道。`HelperService/` 放发给 helper daemon 的请求协议、mach service 名和协议版本 |
| RuntimeViewerCrossReferences | 根目录留命令和 engine 接口；`Models/` 放 17 个线上类型（拆自 `RuntimeCrossReferenceModels.swift`）；`Analysis/` 放扫描与查询 |
| RuntimeViewerInjection | 保持平铺，只把 `RuntimeProcessInjectionResult` 拆出来 |
| RuntimeViewerUtilities | `LaunchServices+.swift` 拆成 `LSBundleProxy+Sandbox.swift` 与 `NSRunningApplication+ApplicationProxy.swift` |
| RuntimeViewerObjC | 不动（一个 `.m`、一个头文件） |

拆完共 295 个文件（原 152 个）。

### 三、拆开时必须处理的事

- **靠 `fileprivate` 成员互相访问的四组类型**：拆开，把这些成员放宽到 `internal`（仍只在模块内可见）。
  - `RuntimeXPCMachServiceConnection` 与客户端、服务端两个子类：基类的六个成员和 `@Loggable(.fileprivate)`。
  - `RuntimeXPCServiceConnection` 与客户端、监听端两个子类：`stateSubject`、`init()`、`sendFrame`、`installHandler`，以及两边都用的 `NSLock.locked(_:)`。
  - `RuntimeSwiftSection` 与 `RuntimeSwiftSectionFactory`：factory 调 section 的四个方法，外加 section 文件里几个 file-private 的辅助扩展。
  - `RuntimeDerivedData.processStore` 与读它的 `RuntimeEngine.processDerivedDataStore`。
- 按项目规矩必须 file-private 的留在原处：`CrossReferenceSession.shared`，以及用它的 `CrossReferenceQuery.init(engine:)`。
- `@Loggable` 生成的 logger 是 file-private 的。拆出去的代码用了 `#log`、所在类型又没有 `@Loggable` 时，给那个文件一个自己的 `private` 日志类型，照 `RuntimeEngineCommandRegistryLog` 的做法。
- 整个文件包在 `#if os(macOS)`、`#if canImport(Network)` 之类条件里的，拆出来的每个文件都带上同样的条件；`public import` 按新文件的公开签名补。
- `@_exported import`（`RuntimeObjCSection.swift` 的 `ObjCIndexing`，`Transformer.swift` 的三个）必须留在模块里，否则 App 一侧编不过。
- 同一模块里文件名不能重复，Swift 编译器会报 `filename used twice`。
- 仓库的 `.gitignore` 不带斜杠地忽略 `build`、`Products`、`DerivedData`、`Archives`，而 macOS 上 git 不分大小写：新目录不能叫这些名字，`DerivedDataStorage/` 因此保留原名。

### 四、文档

- 改路径：根 `AGENTS.md`（XPC service 代码所在的位置、`Key Source Locations`）；`Documentations/` 下仍在维护的说明（`CommunicationAndEngineArchitecture.md`、`EngineMirroringWalkthrough.md`、`DevicePayloadReverseConnection.md`、`SparkleRelease.md`、`SwiftObjectTreeWalkthrough.md`、`DerivedData.md`）；源码注释里写到的文件名。
- 历史文档不改：`Plans/`、`Reviews/`、`KnownIssues/`、`ResolvedIssues/` 和已落地的提案记的是当时的代码。
- 新增 `RuntimeViewerCore/Sources/AGENTS.md`（旁边放 `CLAUDE.md` 符号链接），写下这套规则和目录表，以后加类型照它放；根 `AGENTS.md` 的规则表登记一行。`Sources/` 不是 target 目录，可以放。

### 五、做法与提交

- 整个文件换目录只用 `git mv`；拆文件按清单切行，不手抄代码。切分脚本写完先给用户看过再跑。
- 先一个只搬家的提交（git 能完整认出改名，`git log --follow` 不断），再每个 target 一个拆文件的提交。每个提交都能编过，文档改动跟着对应的提交走。
- 只搬家的提交里，要拆的文件先整个搬到它主类型所在的目录、名字不变；拆分提交再把其余类型切出去，文件名和主类型不一致的同时改名。

### 六、验证

- 重跑这次的盘点：每个文件只剩一个非 private 的顶层类型，多出来的只能是「一」里列的例外。
- Core 包：`swift build --build-tests` 加全量测试，结果与改动前的基线一致。
- Core 包在 iOS、Mac Catalyst、tvOS、watchOS、visionOS 的 generic 目标各编一次：拆文件最容易漏的是 `#if` 条件，macOS 构建看不出来。
- App 用 Debug workspace 构建（顺带编 Catalyst service、helper 和模拟器载荷）；RuntimeViewerPackages、RuntimeViewerCommandLine、RuntimeViewerMCP 各编一次。

### 落地步骤

1. 批准后从 `next` 切 `feature/core-source-layout`，worktree 为 `.worktrees/RuntimeViewer-CoreSourceLayout`；跑基线。（已完成）
2. 只搬家的提交，连同活文档里的路径。（已完成）
3. 拆文件：Core、Communication、CrossReferences 各一个提交，Injection 与 Utilities 合一个提交。（已完成）
4. `RuntimeViewerCore/Sources/AGENTS.md`，根 `AGENTS.md` 登记。（已完成）
5. 验证，收尾合回 `next`。

### 没问就采用的假设

- 范围是包里五个 Swift target 的 `Sources/`；测试目录不动。
- `LocalRuntimeService/` 和 `Offline/` 里 service、host 的文件原地不动：根 `AGENTS.md` 把它们列为 XPC service 代码的固定位置。
- `RuntimeEngine.swift` 自己的扩展不拆，它们用到 engine file-private 的 logger 和 private 成员。只搬走给 `RuntimeConnection` 的扩展（去 `Engine/Commands/`）和导出接口那段（去 `Export/`，已核对不碰 private 成员）。
- `RuntimeEngine+Commands.swift` 里的命令结构体不按功能重新分配。
- `Utils/` 改名 `Extensions/`。
- 不改类型名，不改格式，不顺手修别的。

### 附录：目标文件清单

`←` 后是来源；没写来源的是原目录里原样搬过来的文件。

RuntimeViewerCore target：

```
Engine/
  RuntimeEngine.swift, RuntimeEngine+Commands.swift, RuntimeEngine+ImagePathCanonicalization.swift, RuntimeHostInfo.swift   ← 根目录
  RuntimeDataChange.swift                       ← Common/
  RuntimeEngineDyldRootPath.swift               ← 拆自 RuntimeEngine+ImagePathCanonicalization.swift
Engine/Commands/
  RuntimeEngineCommand.swift, RuntimeEngineCommandName.swift, RuntimeEngineCommandRegistrar.swift,
  RuntimeEngineRequestCancellation.swift        ← 根目录
  RuntimeEngineEmpty.swift, RuntimeEngineProgressCommand.swift, RuntimeEngineProgressEnvelope.swift,
  RuntimeEngineProgressPush.swift, RuntimeEngine+BuiltInHandlers.swift   ← 拆自 RuntimeEngineCommand.swift
  RuntimeEngine+CommandExtensions.swift         ← 拆自 RuntimeEngineCommandRegistrar.swift（带自己的 private 日志类型）
  RuntimeConnection+CommandName.swift           ← 拆自 RuntimeEngine.swift
  RuntimeEngineInboundRequests.swift, RuntimeEngineForwardedRequest.swift   ← 拆自 RuntimeEngineRequestCancellation.swift
Engine/Serving/
  RuntimeEngineConnectionServer.swift, RuntimeEngineProxyServer.swift, RuntimeRemoteEngineDescriptor.swift   ← 根目录
Images/
  RuntimeImageReading.swift, RuntimeFileImageReading.swift, RuntimeImageIndex.swift   ← Core/
  RuntimeLoadedImageReading.swift               ← 拆自 RuntimeImageReading.swift
  RuntimeImageCatalog.swift, RuntimeProcessImageCatalog.swift, RuntimeFileImageCatalog.swift   ← Catalog/
  RuntimeImageNode.swift, RuntimeImageLoadState.swift   ← Common/
  DyldUtilities.swift, DylibPathResolver.swift  ← Utils/
  DyldOpenError.swift                           ← 拆自 DyldUtilities.swift
Objects/
  RuntimeObject.swift, RuntimeObjectKind.swift, RuntimeObjectCounterpartKind.swift, RuntimeMemberAddress.swift,
  RuntimePrivateDeclaration.swift, RuntimePrivateDeclarationSourceFile.swift, RuntimeObjectsLoadingProgress.swift   ← Common/
  RuntimeObjectKey.swift                        ← 拆自 RuntimeObject.swift
  RuntimeObject+CounterpartKind.swift           ← 拆自 RuntimeObjectCounterpartKind.swift
  RuntimeObjectsLoadingEvent.swift              ← 拆自 RuntimeObjectsLoadingProgress.swift，带上 RuntimeObjCSection.swift 里的 LoadingEventContinuation
Interfaces/
  RuntimeObjectInterface.swift, RuntimeObjectInterface+GenerationOptions.swift, RuntimeObjectInterfaceResponse.swift,
  RuntimeInterfaceCommentStructure.swift, RuntimeInterfaceCommentStructure+AnnotationRegions.swift, RuntimeTextRange.swift   ← Common/
  RuntimeObjectInterface+AnnotationRegions.swift   ← 拆自 RuntimeInterfaceCommentStructure+AnnotationRegions.swift
  SwiftGenerationOptions.swift, SwiftDeclarationPrintConfiguration+GenerationOptions.swift   ← 拆自 Core/RuntimeSwiftSection.swift
Sections/
  RuntimeObjCSectioning.swift, RuntimeSwiftSectioning.swift, RuntimeObjCSectionProviding.swift,
  RuntimeSwiftSectionProviding.swift            ← 拆自 Core/RuntimeSectioning.swift
  RuntimeSectionBuild.swift                     ← Core/
Sections/ObjC/
  RuntimeObjCSection.swift, RuntimeObjCSection+Corpus.swift, ObjCIndexingEvent+LoadingProgress.swift   ← Core/
  RuntimeObjCSectionFactory.swift, RuntimeObjCName.swift, MachOImage+RuntimeObjCName.swift   ← 拆自 RuntimeObjCSection.swift
  RuntimeObjCInterfaceIndexer.swift             ← Indexing/
  RuntimeObjCClassReference.swift, RuntimeObjCProtocolReference.swift, RuntimeObjCRelationshipTables.swift   ← 拆自 RuntimeObjCInterfaceIndexer.swift
Sections/Swift/
  RuntimeSwiftSection.swift, SwiftDefinedObjCProtocols.swift   ← Core/
  RuntimeSwiftSectionFactory.swift, SwiftDeclaration+RuntimeObjectKind.swift, SwiftDeclaration+DefinitionBox.swift,
  Array+SemanticString.swift                    ← 拆自 RuntimeSwiftSection.swift（file-private 的辅助扩展留在原文件）
  RuntimeSwiftInterfaceIndexer.swift            ← Indexing/
  RuntimeSwiftTypeReference.swift, RuntimeSwiftProtocolReference.swift, RuntimeSwiftRefinedProtocol.swift   ← 拆自 RuntimeSwiftInterfaceIndexer.swift
BackgroundIndexing/
  原有 9 个文件
  RuntimeEngine+BackgroundIndexing.swift        ← 根目录
  RuntimeDependencyEntry.swift                  ← 拆自 RuntimeEngine+BackgroundIndexing.swift
Search/
  RuntimeEngine+Search.swift                    ← 根目录
  RuntimeSemanticKind.swift, RuntimeInterfaceSearchMatchMode.swift, RuntimeInterfaceSearchScope.swift,
  RuntimeInterfaceSearchQuery.swift, RuntimeInterfaceSearchMatch.swift, RuntimeInterfaceSearchSummary.swift,
  RuntimeInterfaceSearchStopReason.swift        ← 拆自 Common/RuntimeInterfaceSearch.swift
  RuntimeMemberKind.swift, RuntimeMemberDeclaration.swift, RuntimeMemberMatch.swift,
  RuntimeMemberSearchQuery.swift                ← 拆自 Common/RuntimeMemberDeclaration.swift
  RuntimeObjectIndexedBatch.swift               ← Common/（两个嵌套的 Hit 类型搬回各自的 Match 文件）
Search/Corpus/
  RuntimeInterfaceCorpusStore.swift, RuntimeInterfaceCorpusSnapshot.swift, RuntimeInterfaceCorpusAssembly.swift,
  RuntimeInterfaceCorpusNesting.swift, RuntimeInterfaceLineTable.swift, RuntimeInterfaceRepeatedProtocolCopies.swift,
  RuntimeInterfaceVisibility.swift, RuntimeInterfaceVisibilityConditionPool.swift   ← Search/
  RuntimeInterfaceCorpusEntry.swift, RuntimeInterfaceCorpusBuilding.swift   ← 拆自 RuntimeInterfaceCorpusStore.swift
  RuntimeInterfaceCorpusPrint.swift, RuntimeInterfaceCorpusPrintOutcome.swift   ← 拆自 RuntimeInterfaceCorpusAssembly.swift
  RuntimeObject+CorpusNesting.swift             ← 拆自 RuntimeInterfaceCorpusNesting.swift
  VisibilityRegionTable+HiddenRanges.swift      ← 拆自 RuntimeInterfaceVisibility.swift
  RuntimeInterfaceCorpusStore+SharedVisibilityConditions.swift   ← 拆自 RuntimeInterfaceVisibilityConditionPool.swift
  RuntimeInterfaceCorpusBuildProgress.swift, RuntimeInterfaceCorpusBuildSummary.swift, RuntimeInterfaceCorpusBuildOutcome.swift,
  RuntimeInterfaceCorpusBuildError.swift, RuntimeInterfaceCorpusBuildState.swift, RuntimeInterfaceCorpusCoverage.swift,
  RuntimeInterfaceCorpusRestoredImage.swift, RuntimeInterfaceCorpusRestoreResult.swift   ← 拆自 Common/RuntimeInterfaceSearch.swift
Search/Matching/
  RuntimeInterfaceTextMatcher.swift, RuntimeTextPattern.swift, RuntimeInterfaceSearchWorkLog.swift,
  RuntimeMemberDeclarationLocator.swift         ← Search/
  RuntimeDeclaredMember.swift, RuntimeObjectInterface+DeclaredMembers.swift   ← 拆自 RuntimeMemberDeclarationLocator.swift
Relationships/
  RuntimeRelationshipsResolver.swift, RuntimeTypeRelationshipsResolver.swift
  RuntimeRelationshipsResolving.swift, RuntimeTypeRelationshipsResolving.swift   ← 拆自 Core/RuntimeSectioning.swift
  RuntimeRelationships.swift                    ← Common/
  RuntimeTypeRelationship.swift, RuntimeTypeRelationshipsQuery.swift, RuntimeRelationshipNode.swift,
  RuntimeRelationshipTree.swift                 ← 拆自 Common/RuntimeTypeRelationships.swift
Specialization/
  RuntimeEngine+GenericSpecialization.swift     ← 根目录
  RuntimeSpecializationRequest.swift, RuntimeSpecializationSelection.swift,
  RuntimeSpecializationValidation.swift         ← 拆自 Common/RuntimeSpecialization.swift
Bookmarks/
  RuntimeImageBookmark.swift, RuntimeObjectBookmark.swift   ← 拆自 Common/RuntimeBookmark.swift
  RuntimeBookmarkScope.swift                    ← Common/（给 RuntimeSource.Role 的 file-private 辅助扩展留在原文件）
  RuntimeRemoteEngineDescriptor+BookmarkScope.swift   ← 拆自 RuntimeBookmarkScope.swift
Export/
  原有 6 个文件
  RuntimeInterfaceExportResult.swift            ← 拆自 RuntimeInterfaceExportEvent.swift
  RuntimeObject+Export.swift                    ← Common/
  RuntimeEngine+Export.swift                    ← 拆自 RuntimeEngine.swift
DerivedDataStorage/
  原有 10 个文件
  RuntimeDerivedDataKind.swift, RuntimeDerivedDataByteReader.swift, Data+LittleEndian.swift   ← 拆自 RuntimeDerivedDataContainer.swift
  RuntimeEngine+DerivedData.swift               ← 拆自 RuntimeDerivedData.swift
Offline/
  原有 5 个文件
  RuntimeOfflineFileError.swift                 ← 拆自 RuntimeOfflineFile.swift
  RuntimeHostInfo+Offline.swift                 ← 拆自 RuntimeEngine+Offline.swift
LocalRuntimeService/、Transformer/                不动
Extensions/
  Array+AllocatedByteCount.swift, String+AllocatedByteCount.swift   ← 拆自 Utils/AllocatedByteCount.swift
  Optional+OrEmpty.swift, Array+Removing.swift, String+LetterCase.swift, String+Parentheses.swift,
  Set+InsertContentsOf.swift                    ← 拆自 Utils/SwiftStdlib+.swift
  String+PathComponents.swift                   ← 拆自 Common/RuntimeImageNode.swift
```

RuntimeViewerCommunication：

```
（根目录）
  RuntimeCommunicator.swift, RuntimeSource.swift, RuntimeDeviceMetadata.swift
  RuntimeCommunicatorError.swift                ← 拆自 RuntimeCommunicator.swift
Connections/
  RuntimeInterfaceAddresses.swift, RuntimeUnusedPort.swift   ← Connections/
  RuntimeConnection.swift, RuntimeConnectionState.swift, RuntimeConnectionError+LostConnection.swift,
  RuntimeConnectionCredential.swift, RuntimeForwardingConnection.swift, RuntimeUnderlyingConnection.swift   ← 根目录
  RuntimeConnectionInfo.swift, RuntimeLocalAddressReachability.swift   ← 拆自 RuntimeConnection.swift
  RuntimeConnectionError.swift                  ← 拆自 RuntimeConnectionState.swift
Connections/DirectTCP/
  RuntimeDirectTCPConnection.swift, RuntimeDirectTCPClientConnection.swift, RuntimeDirectTCPServerConnection.swift,
  RuntimeDirectTCPError.swift                   ← 拆自 Connections/RuntimeDirectTCPConnection.swift
Connections/LocalSocket/
  RuntimeLocalSocketConnection.swift, RuntimeLocalSocketError.swift, RuntimeLocalSocketAddress.swift,
  RuntimeLocalSocketPortDiscovery.swift, RuntimeLocalSocketClientConnection.swift,
  RuntimeLocalSocketServerConnection.swift      ← 拆自 Connections/RuntimeLocalSocketConnection.swift
Connections/Network/
  RuntimeNetworkConnection.swift, RuntimeNetworkClientConnection.swift,
  RuntimeNetworkServerConnection.swift          ← 拆自 Connections/RuntimeNetworkConnection.swift
  RuntimeNetworkBonjour.swift, RuntimeNetworkBonjour+LocalIdentity.swift, RuntimeNetworkBrowser.swift,
  RuntimeNetworkEndpoint.swift, RuntimeNetworkError.swift   ← Network/
  RuntimeNetworkRequestError.swift              ← 拆自 Network/RuntimeNetworkError.swift
Connections/Stdio/
  RuntimeStdioConnection.swift, RuntimeStdioError.swift, RuntimeStdioClientConnection.swift,
  RuntimeStdioServerConnection.swift            ← 拆自 Connections/RuntimeStdioConnection.swift
Connections/XPCMachService/
  RuntimeXPCMachServiceConnection.swift, RuntimeXPCMachServiceClientConnection.swift,
  RuntimeXPCMachServiceServerConnection.swift   ← 拆自 Connections/RuntimeXPCMachServiceConnection.swift
Connections/XPCService/
  RuntimeXPCServiceTarget.swift, RuntimeXPCServiceEndpoint.swift, RuntimeXPCServiceConnectionError.swift,
  RuntimeXPCServiceReplyFrame.swift, RuntimeXPCServiceMessaging.swift, RuntimeXPCServiceConnection.swift,
  RuntimeXPCServiceClientConnection.swift, RuntimeXPCServiceListenerConnection.swift, NSLock+Locked.swift   ← 拆自 Connections/RuntimeXPCServiceConnection.swift
Messaging/
  RuntimeMessageChannel.swift, RuntimeRequestData.swift   ← 根目录
  RuntimeMessageChannelError.swift, RuntimeMessageHandler.swift, RuntimeMessageNull.swift,
  RuntimeMessageProtocol.swift                  ← 拆自 RuntimeMessageChannel.swift
HelperService/
  RuntimeRequests.swift                         ← 根目录
  RuntimeRequest.swift, RuntimeResponse.swift, VoidResponse.swift, RuntimeViewerMachService.swift,
  RuntimeViewerVariantSelection.swift           ← 拆自 RuntimeRequestResponse.swift
```

RuntimeViewerCrossReferences：

```
（根目录）
  RuntimeCrossReferences.swift, RuntimeCrossReferences+CommandNames.swift, RuntimeCrossReferences+Commands.swift,
  RuntimeEngine+CrossReferences.swift
Models/
  17 个文件，一个线上类型一个    ← 拆自 RuntimeCrossReferenceModels.swift
Analysis/
  CrossReferenceSession.swift, CrossReferenceQuery.swift, CrossReferenceNaming.swift, ObjectiveCSendMatching.swift
  CrossReferencePreparedImage.swift, CrossReferenceScanKey.swift   ← 拆自 CrossReferenceSession.swift
  MemberAddressMatching.swift                   ← 拆自 CrossReferenceQuery.swift
  ObjectiveCMethodName.swift, FunctionReferenceBuilder.swift   ← 拆自 CrossReferenceNaming.swift
```

RuntimeViewerInjection：原有 8 个文件，加上拆自 `RuntimeProcess.swift` 的 `RuntimeProcessInjectionResult.swift`。

RuntimeViewerUtilities：`DeviceIdentifier.swift`、`SandboxProbe.swift`，加上拆自 `LaunchServices+.swift` 的 `LSBundleProxy+Sandbox.swift`、`NSRunningApplication+ApplicationProxy.swift`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-05 | Created as Draft | 用户提出 RuntimeViewerCore 包的源码太乱：多个类型挤在一个文件里，`Common/`、`Core/` 和 target 根目录看不出按什么分。整理成按功能分目录、除 file-private 类型外一个类型一个文件 |
| 2026-11-05 | 目录按功能分，不按层分 | 一个功能的模型、实现和 engine 接口放在一起，找一个功能只看一个目录；现有的 `BackgroundIndexing/`、`Export/`、`Offline/` 本来就是这样。按层分会把同一个功能散到 `Models/`、`Engine/`、`Services/` 几处 |
| 2026-11-05 | 靠 `fileprivate` 互访的四组类型拆开，相关成员放宽到 `internal` | 留在一个文件就得为它们开例外；放宽后这些成员仍只在模块内可见 |
| 2026-11-05 | 嵌套类型不拆 | 嵌套类型是外层类型的一部分；只拆顶层类型，`RuntimeEngine+Commands.swift` 这类按功能归组的命令结构体保持原样 |
| 2026-11-05 | 要拆的文件在只搬家的提交里先整个搬到主类型的目录 | 搬家和拆分分开提交，搬家那次 git 能完整认出改名；拆分时只切出其余类型 |
| 2026-11-05 | 用户批准，开始实现 | — |
| 2026-11-05 | 只搬家的提交：96 个文件换目录，`Common/`、`Core/`、`Catalog/`、`Indexing/`、`Utils/` 与 Communication 的 `Network/` 清空删除 | 落地步骤 2；文档里跟着变的路径同批改，`SparkleRelease.md` 找上次 helper 版本变更的命令改为比较前后值，免得把搬家的提交当成一次变更 |
| 2026-11-05 | 拆文件用脚本按大括号切出顶层声明，连同紧贴在上面的注释与属性逐字节复制；声明之间夹着 `#if` 的 `RuntimeRequestResponse.swift`、`LaunchServices+.swift` 按行号手工拆 | 不手抄代码；脚本先经用户过目，dry run 核对过每个声明的去向再写入 |
| 2026-11-05 | 新文件带上原文件的全部 import，编译器指出没用在公开声明里的 111 处 `public import` / `package import` 改为普通 `import`，其余不删 | 只消掉拆分带来的警告；Swift 不报多余的普通 import，逐个删要靠一次次编译试，收益不抵风险。基线里原有的 1 处同类警告（`RuntimeConnectionError+LostConnection.swift`）不在本次范围 |
| 2026-11-05 | 放宽到 `internal` 的除了起初列的四组，还有 XPC service 客户端与监听端共用的 `NSLock.locked(_:)` | 同样是拆开后跨文件使用。`RuntimeXPCMachServiceConnection` 的 `@Loggable` 改成 `.internal`：两个子类沿用它的 logger |
| 2026-11-05 | `RuntimeEngineCommandRegistryLog` 一分为二：注册器留着自己那条日志，搬到 `RuntimeEngine+CommandExtensions.swift` 的注册逻辑另配 `RuntimeEngineCommandExtensionLog` | `@Loggable` 的 logger 只在声明它的文件里可见 |
| 2026-11-05 | `// MARK:` 行不随声明搬；原文件里因此没东西可标的删掉；三个文件头注释改写成只描述留下的内容（`RuntimeObjCSectioning.swift`、`RuntimeBookmarkScope.swift`、`Models/RuntimeMemberReference.swift`） | 拆开后它们描述的是已经不在本文件的类型 |
