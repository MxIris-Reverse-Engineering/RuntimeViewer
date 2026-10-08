# PR #121 审查裁决与修复方案 — 2026-10-07

审查对象：PR #121（`feature/find-navigator` → `next`），即 Find navigator 与 Report navigator 两份提案的实现（`draft-find-navigator.md`、`draft-report-navigator.md`）。head `12e1227b`，分叉点 `9ca0d5a6`。

**经过**
1. `/code-review max`：从 16 个角度找问题，每条候选再由一个独立的验证者投票。确认 54 条缺陷，另有 8 条性能问题和约 15 条清理项。
2. 按模块逐条回到代码里核实，并起草修复方案。审查列出的问题全部成立，个别细节有修正，修正写在各条的「问题」里。这一步还发现了 4 条审查没列出的问题：PR121.70–73。

两步都是静态分析：没有构建，也没有运行。

**本文档的状态：方案待批，代码未改。**
- 每条的「拟修改」是基于 `12e1227b` 写的 diff 草案，**没有经过编译验证**。
- 「复现测试」是示例代码。落地时要先确认它在修复前确实失败，再做修复。
- 方案批准后，按文末的「落地顺序」分批实施。每修好一条，就把这条的 diff 换成修复提交的哈希，测试名保留。这与本目录其它文件的约定一致。

**约定**
- 四问里的「基线」指分叉点 `9ca0d5a6`（在 `next` 上），不是 `main`。
- ID 为 `PR121.<N>`。PR121.01–15 是审查认定最严重的 15 条，顺序与第一次汇报时一致。
- 每条的「审查编号」（例如 C38、F1）对应审查日志里的候选编号，只用于追溯。

## 需要拍板的决定

下面 10 项需要权衡，每项都给了推荐选项。

1. **PR121.03 序列化格式怎样兼容旧版本**
   - **A（推荐）**：请求方声明自己能读新格式；回复方默认仍回旧格式；解码两种格式都接受。
   - **B**：旧命令永远回旧格式，新格式走一条新命令，碰到「没有处理器」时退回旧命令。
   - **C**：接受这次破坏，在发版说明里写明。这违背了 `CommunicationAndEngineArchitecture.md` 里「双向兼容」的承诺，按提案制要走完整档。
2. **PR121.29 跨连接取消**
   - **推荐**：在引擎层按请求 id 取消，新增一个不等回复的 `cancelRequest` 命令，只对本 PR 新增的长命令开启。这样旧对端永远收不到它不认识的命令。
   - **备选**：只在 Find 的两个调用点各自处理。
   - 这一项改的是通信协议层的设计，可能属于完整档，请定档。
3. **PR121.05 FindSession 的修法**
   - **推荐**：每次搜索建一个「本次搜索」对象，所有异步回调回到主线程后，先核对自己是不是当前这次搜索。
   - **备选一**：按项目规则整体重写成 Rx 管线。
   - **备选二**：只加代次检查。
4. **PR121.12（回复屏障）与 PR121.31（迟到回复无限往返）放在哪里提交**：两者都只改通信模块，问题在基线上就已存在。
   - **推荐**：单独开一个小 PR 进 main，再合进 next 和 feature 分支。
   - **备选**：随本 PR 一起改。
5. **PR121.01 怎样防止再犯**
   - **推荐**：加一个源码检查测试。
   - **备选一**：在 PR 上加 iOS 构建。这属于工作流变更，要单独走完整提案。
   - **备选二**：不加。
6. **PR121.27 复制了上游打印器的私有规则**
   - **推荐**：在 MachOSwiftSection 上加一个公开属性，让打印器和 RuntimeViewer 共用同一条规则。代价是一次上游提交，加一次 pin 前移。
   - **备选**：在 RuntimeViewer 里把规则收拢成一个函数，再加一个护栏测试。
7. **PR121.58 多窗口重复 reload**
   - **推荐**：把「批次结束后 reload」挪进 Core 的后台索引 manager。
   - **备选**：接受现状，只改文档。
8. **PR121.06 正则超出时间预算时怎么办**
   - **推荐**：停止搜索，保留已经给出的结果，并提示结果不完整。
   - **备选**：整次搜索报错。
9. **PR121.46 挂起的高亮**
   - **推荐**：高亮随路由一起传递，删掉文档级的高亮邮箱。
   - **备选**：发生其它路由时，先清掉邮箱。
10. **判为「不修」、准备留在本文档的裁决**，同意吗？
    - PR121.20（镜像对端共享主机的语料存储）
    - PR121.66 里跨镜像一致性的那一半
    - PR121.68（Ancestor 树回退到 ObjC 面）
    - PR121.34 里「靠轮询得知别处构建」的设计本身
    - PR121.72 里 Swift 类 ObjC 面的那一半

下面这些选择都有明确的推荐，没有异议就照推荐做：
- **PR121.16**：删掉探针 target。
- **PR121.17**：验证脚本改成和真正的 bridge 协议一起编译。
- **PR121.18**：从根上隔离 `AppDefaults`，不只是补锁。
- **PR121.10**：只改定位器，不动上游的打印器；删掉跨种类回退。
- **PR121.11**：按结构列出成员。
- **PR121.04**：「镜像已索引」事件由客户端引擎发出，不新增推送命令。
- **PR121.33**：这一批就修。
- **PR121.37**：这一批一起处理。
- **PR121.05**：换引擎后，重新执行已提交的查询。
- **PR121.40**：从头重跑。
- **PR121.38**：补搜失败时只记日志。
- **PR121.39**：沿用当时解析出的范围。
- **PR121.42**：一行加固。
- **PR121.48**：关系模式的树不超过约 500 行时全部展开。
- **PR121.07**：键入跳转补上取行文本的回调，并加去抖；再次点击已选中的命中时不重新跳转。
- **PR121.55**：别处发起的构建照常显示，但不能取消。
- **PR121.62**：镜像显示名统一带扩展名。
- **PR121.63**：不写测试。
- **PR121.13**：只要有一个携带镜像在范围内，协议就算在范围内；没有指定范围时，按路径选取副本。
- **PR121.14**：Inspector 那一半随本 PR 一起修。

## 落地顺序

每一条都先写修复前会失败的测试，再做修复；文档与代码放在同一个提交里。

1. **依赖卫生**：PR121.70、PR121.71、PR121.18。
2. **阻断、崩溃与兼容**：PR121.01、PR121.02、PR121.03、PR121.15、PR121.19、PR121.16。
3. **传输小 PR**（可以进 main）：PR121.12、PR121.31，以及 PR121.30 里「socket 传回的远端错误可读」那一项。
4. **跨连接取消与协调器**：PR121.29、PR121.09、PR121.30、PR121.32、PR121.33、PR121.04（含 PR121.36）、PR121.34、PR121.35、PR121.37。同一批做 FindSession：PR121.05、PR121.38、PR121.39、PR121.40、PR121.41。
5. **语料存储**：先做 PR121.08、PR121.06，再做 PR121.21–26。其中 PR121.22 会改动本 PR 新增命令的传输格式，必须在发版前定稿。
6. **语料内容与类型关系**：PR121.10、PR121.11、PR121.27、PR121.28、PR121.72、PR121.13、PR121.14、PR121.66、PR121.69、PR121.67。
7. **界面**：PR121.07、PR121.43–52、PR121.53–65。
8. **不限批次**：PR121.17 随时可以做；PR121.73 先核实再决定。

同批要更新的文档：
- 两份提案的决策日志
- `CommunicationAndEngineArchitecture.md`：取消协议、回复屏障，以及改动已有命令格式时的兼容规则
- `AGENTS.md`：值类型树节点的判等约定

## 条目索引

| ID | 严重度 | 标题 |
|---|---|---|
| PR121.01 | Blocker | RuntimeViewerApplication 在 iOS / visionOS 上编不过 |
| PR121.02 | Major | FindSession 的 unowned documentState 在关窗后崩溃 |
| PR121.03 | Major | interfaceString 改成 FrozenSemanticString 破坏新旧版本互通 |
| PR121.04 | Major | 在侧栏打开的已加载镜像永远建不出语料 |
| PR121.05 | Major | 旧搜索的批次混进当前结果；换引擎后结果混杂 |
| PR121.06 | Major | 搜索在 store actor 上同步扫描，病态正则卡死 |
| PR121.07 | Major | Find 结果每批整树重载：折叠、选中丢失，误导航 |
| PR121.08 | Major | 被取消的构建仍接受新请求；组装期间的取消被无视 |
| PR121.09 | Major | Report 的取消到不了服务端 |
| PR121.10 | Major | 成员定位按名字抢行 |
| PR121.11 | Major | 顶层协议的默认实现进不了 Members 搜索 |
| PR121.12 | Major | socket 上回复先于进度推送被处理，丢掉最后几批结果 |
| PR121.13 | Major | ObjC 协议按携带镜像重复、归属取决于索引顺序 |
| PR121.14 | Major | 父类是绑定泛型的 Swift 类，Ancestor 树被截断 |
| PR121.15 | Minor | 正则的 ^ / $ 不按行匹配 |
| PR121.16 | Cleanup | CorpusBuildTimingProbe target 被合了进来 |
| PR121.17 | Minor | VerifyAcrossXcodes 没跟上 bridge 的接口 |
| PR121.18 | Minor | AppDefaults 的 UserDefaults 在测试之间共享 |
| PR121.19 | Minor | 无效正则的报错不可读 |
| PR121.20 | 建议不修 | 镜像对端共享主机的语料存储（建议不修） |
| PR121.21 | Minor（性能） | 搜索先投影每个条目再看有没有命中 |
| PR121.22 | Minor（性能），但要在发版前做 | 每条命中都带完整的 RuntimeObject |
| PR121.23 | Minor（性能） | 收满上限后仍为每个命中建 Layout |
| PR121.24 | Cleanup | 行表有两份实现 |
| PR121.25 | Minor | 语料内存预算少算了成员数据 |
| PR121.26 | Cleanup | coverage 的 indexedImagePaths 参数没有用 |
| PR121.27 | Minor | RuntimeViewer 复制了上游打印器的私有规则 |
| PR121.28 | Cleanup | 可见性映射复制了 Swift 打印配置 |
| PR121.29 | Major | 取消传不过连接（跨连接取消的整体设计） |
| PR121.30 | Minor | store 发起的取消跨过连接后被记成失败 |
| PR121.31 | Major（读代码推出，尚未复现） | socket 上迟到的回复在两端之间无限往返 |
| PR121.32 | Minor | 为没有索引的镜像请求语料 |
| PR121.33 | Minor | iOS 模拟器引擎上同一镜像按原始路径和规范路径各记一份 |
| PR121.34 | Minor | 被悄悄驱逐的语料仍显示已建好；历史满额时 Clear History 失效 |
| PR121.35 | Minor（性能） | 每个请求完成都单独刷新一次 coverage |
| PR121.36 | Cleanup（随 PR121.04 一起消失；单独看建议不修） | 语料事件泵跑在 main actor 上 |
| PR121.37 | Minor | 对端不支持语料命令时每个镜像记一条失败 |
| PR121.38 | Minor | 补搜失败后转圈不停 |
| PR121.39 | Minor | 选项重跑和点击高亮用了未提交的查询 |
| PR121.40 | Minor | 改 transformer 后屏上的搜索不重跑 |
| PR121.41 | Cleanup | TextMatchGroups 与 MemberMatchGroups 重复 |
| PR121.42 | Minor（加固，目前不出错） | 两页共用一个会话，输入靠重载决议碰巧是纯事件 |
| PR121.43 | Minor | FindResultNode.isContentEqual 只比较子节点个数 |
| PR121.44 | Minor | 右键菜单 Open in New Tab 在无效位置可点却不做事 |
| PR121.45 | Minor | Scope chooser 每约 16 ms 滚回第一个选中行 |
| PR121.46 | Minor | 挂起的高亮在之后不相干的访问时触发 |
| PR121.47 | Minor | 长行与成员命中的高亮定位错位 |
| PR121.48 | Minor | 每批重建整棵结果树 |
| PR121.49 | Minor | 过滤栏每敲一个键就重建所有匹配节点 |
| PR121.50 | Cleanup | navigationTarget.highlight 恒为 nil；matchCount 冗余 |
| PR121.51 | Cleanup | self?. / if let self 代替 guard let self |
| PR121.52 | Cleanup | Find 页直接用原生 AppKit 控件 |
| PR121.53 | Minor | ReportNode.isContentEqual 吞掉第二层以下的变化 |
| PR121.54 | Minor | Report 每次更新都重新展开用户折叠的行 |
| PR121.55 | Minor | 别处发起的构建行能点 Cancel 却不做事 |
| PR121.56 | Minor | 单镜像 Always Index 失败时看不到原因 |
| PR121.57 | Minor | A→B→A 切回原引擎后批次重复 |
| PR121.58 | Minor | N 个窗口时每个批次结束触发 N 次 reloadData |
| PR121.59 | Minor（性能） | Report 树每 16 ms 整树重建，隐藏页也重建 |
| PR121.60 | Cleanup | AggregateState.progress 已无人读却每次刷新都遍历 |
| PR121.61 | Cleanup | 手写的 withObservationTracking 循环 |
| PR121.62 | Cleanup | 镜像显示名有三份实现 |
| PR121.63 | Cleanup | BatchExportingProgressRowViewModel.State 不是 Equatable |
| PR121.64 | Cleanup | ReportViewController 手写 relay 与 @objc 双击 |
| PR121.65 | Cleanup | lhs / rhs 缩写 |
| PR121.66 | Minor | Swift 类的 Ancestors 漏掉采纳的 @objc 协议 |
| PR121.67 | Minor | 关系遍历不检查取消 |
| PR121.68 | 建议不修 | materializeObjCClass 回退到 ObjC 面（建议不修） |
| PR121.69 | Cleanup | 关系遍历代码重复、visited 键写法不统一 |
| PR121.70 | Major | 锁文件钉着被变基孤立的 MachOSwiftSection 修订 |
| PR121.71 | Minor（单独看不出错，但它决定 PR121.53 的修复和测试在哪个版本下成立） | RxAppKit 在 App 是 0.6.0、包测试与 CLI 锁文件是 0.5.4 |
| PR121.72 | Minor（协议副本部分）；建议不修（Swift 类 ObjC 面部分） | 语料为协议副本和 Swift 类的 ObjC 面各建一条，搜索重复命中 |
| PR121.73 | 待核实（若成立：Minor） | 旧版注入 payload 收到不认识的命令可能被标成断开 |

## 条目

### PR121.01 RuntimeViewerApplication 在 iOS / visionOS 上编不过

- **严重度**：Blocker
- **审查编号**：C35
- **状态**：已修复。复现测试：`CrossPlatformSourceGuardTests`（源码检查，修前红：报出 `ReportNode.swift:3 imports RxAppKit` 与 `ReportViewModel.swift:133 uses appRouter` 两处，四个 target 里没有别的命中）
- **落地与偏离**：护栏比下文的示例多做了三件事。一，它也查符号：收集这四个 target 只在 macOS 分支里声明的 `@DependencyEntry` 键（`appRouter`、`resolvedThemeStream`、`runtimeEngineIconProvider` 等），iOS 家族会编译到的代码里出现就报，所以 `appRouter` 那一半也挡得住。二，`#if` 按 iOS 与 visionOS 两个平台用三值逻辑求值（`!`、`&&`、`||`、括号、`os()`、`canImport()`、`targetEnvironment()`），不再按子串猜，`#if os(macOS) || os(iOS)` 这类条件不会被误当成守卫；求值器本身有 11 个用例钉住。三，macOS 专属模块表从 `Package.swift` 里 `.when(platforms: appkitPlatforms)` 的依赖读出，再加 AppKit / Cocoa，新增依赖不用改测试。仍然抓不到的：经再导出拿到的 AppKit 类型、别的模块只在 macOS 声明的成员，这些还得真编一次 iOS。

**问题**：iOS、visionOS 和越狱版 App 都会编译 `RuntimeViewerApplication`，但它在这三个平台上编译失败，原因有两处：
- `Reports/ReportNode.swift:3` 没加平台守卫就 `import RxAppKit`，而 RxAppKit 只在 macOS 上链接（`RuntimeViewerPackages/Package.swift:344`）。
- `Reports/ReportViewModel.swift:133` 调用了 `appRouter`，而它只在 `ViewModel.swift:16-19` 的 `#if os(macOS)` 里声明。

发版脚本先公证 macOS 包，再编 iOS Simulator 版，最后才打包上传。iOS 一失败，整次发版什么都发不出去；合进 next 后，越狱版的打包脚本也会一起失败。

**四问**：
- **复现**：编 `RuntimeViewer iOS` 或 `RuntimeViewer visionOS` scheme，必报 `no such module 'RxAppKit'` 和 `cannot find 'appRouter' in scope`。
- **基线**：本 PR 新引入。基线上这个 target 里所有 RxAppKit import 都有守卫，beta.6 也正常发布了 iOS Simulator 版。
- **影响**：阻断发版，必须修。
- **历史**：同类「macOS 专属代码漏进跨平台 target」已经修过三次：c69480a6 / d248015f（Settings UI 的 import，KnownIssues US.5）、5335d1af（selectionRouter）、99742c3c（VisualEffectView）。每次都要到发版时才暴露，因为只有发版任务会编 iOS。

**改法**：
- **ReportNode.swift**：import 改成 `RuntimeViewerArchitectures`，FindScopeImageCellViewModel 已经是这种写法。这个模块按平台转出不同的库：macOS 上是 RxAppKit（连带 `@_exported DifferenceKit`，所以 macOS 专属的 `Differentiable` 扩展照样能编），iOS 上是 RxUIKit。两个库声明的 `OutlineNodeType` 签名相同：RxAppKit 0.6.0 在 `Protocols/OutlineNodeType.swift:3`，RxUIKit 0.1.2 在 `UICollectionView+Rx.swift:7`。
- **ReportViewModel.swift**：把 `openSettings` 订阅整段包进 `#if os(macOS)`。`Input.openSettings` 字段保留，iOS 上没人会触发它。
- **排查范围**：会进入 iOS 家族构建的 target 都查过了，只有这两处：
  - RuntimeViewerApplication、Settings、UI、Architectures；
  - Core 的新代码；
  - UIKit 侧 switch 新路由 case 的地方——都有 `default`。

  审查里「FindSession 用到 FindResultNode」那半句是误报：这个类本身没有守卫，能编。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportNode.swift
@@ -1,6 +1,6 @@
 import Foundation
 import RuntimeViewerCore
-import RxAppKit
+import RuntimeViewerArchitectures
 
 /// The two kinds of work the Report navigator lists, each the first level of its outline — the
 /// part Xcode's own Report navigator gives to a scheme or a package.
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -127,12 +127,15 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         }
         .disposed(by: rx.disposeBag)
 
+        // `appRouter` and the Settings window it opens exist on macOS only.
+        #if os(macOS)
         // Resolved when the item is chosen, not while the page is bound.
         input.openSettings.emitOnNext { [weak self] in
             guard let self else { return }
             appRouter.trigger(.settings)
         }
         .disposed(by: rx.disposeBag)
+        #endif
 
         input.filterString.driveOnNext { [weak self] filterString in
             guard let self else { return }
```

**复现（构建验证）**：这是编译错误，红绿就看 iOS 家族的 scheme 能不能编过：修前失败，修后通过。下面的命令与发版用的那条（`ArchiveScript.sh:521-528`）相同，只换了 DerivedData。成败只认 `${pipestatus[1]}`，不认 xcsift 的摘要。
```sh
queued-build xcodebuild build \
    -workspace RuntimeViewer-Distribution.xcworkspace \
    -scheme "RuntimeViewer iOS" \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /Volumes/DerivedData/Agents.noindex/claude/DerivedData/RuntimeViewer-FindNavigator \
    -skipPackagePluginValidation -skipMacroValidation \
    -IDEEnableNewPackagePIFBuilder=NO \
    CODE_SIGNING_ALLOWED=NO 2>&1 | xcsift; echo "exit ${pipestatus[1]}"
# visionOS：-scheme "RuntimeViewer visionOS" -destination 'generic/platform=visionOS Simulator'
# 合进 next 之后再编一次 "RuntimeViewer iOS Jailbroken"（走 RuntimeViewer-Debug.xcworkspace）
```

**永久护栏（示例，待拍板）**：下面这条测试能长期挡住「无守卫 import」这一半问题：修前对 `ReportNode.swift:3` 必红，修后通过。它抓不到 `appRouter` 那样的「macOS 专属符号」，那一半只有真编一次 iOS 才能抓到。

其它选项：
- 在 PR 上加 iOS / visionOS 构建：两半都能抓，但这属于工作流变更，按规则要单独走完整提案。
- 不加护栏。
```diff
--- /dev/null
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/CrossPlatformImportGuardTests.swift
@@ -0,0 +1,76 @@
+import Foundation
+import Testing
+
+/// The targets the iOS, visionOS and jailbroken iOS apps compile may import a
+/// module that links on macOS only inside a macOS-only condition — otherwise
+/// those apps stop building, and only the release job builds them. A macOS
+/// test run cannot compile for iOS, so this reads the sources. It does not
+/// catch a macOS-only *symbol* used outside a condition; an iOS build does.
+@Suite("macOS-only imports in the cross-platform targets")
+struct CrossPlatformImportGuardTests {
+    private static let crossPlatformTargetNames = [
+        "RuntimeViewerApplication",
+        "RuntimeViewerArchitectures",
+        "RuntimeViewerSettings",
+        "RuntimeViewerUI",
+    ]
+
+    private static let macOSOnlyModuleNames: Set<String> = [
+        "AppKit", "Cocoa", "RxAppKit", "CocoaCoordinator", "RxCocoaCoordinator", "AppKitPlus",
+        "UIFoundationSettings", "UIFoundationSettingsUI", "RuntimeViewerSettingsUI",
+        "RuntimeViewerHelperClient", "RuntimeViewerEngineManagement", "RuntimeViewerCatalystExtensions",
+        "RunningApplicationKit", "KeyboardShortcuts",
+    ]
+
+    @Test("every macOS-only import sits inside a macOS-only condition", arguments: crossPlatformTargetNames)
+    func macOSOnlyImportsAreGuarded(targetName: String) throws {
+        let sourcesDirectoryURL = URL(fileURLWithPath: #filePath)
+            .deletingLastPathComponent() // RuntimeViewerApplicationTests
+            .deletingLastPathComponent() // Tests
+            .deletingLastPathComponent() // RuntimeViewerPackages
+            .appendingPathComponent("Sources/\(targetName)", isDirectory: true)
+        let enumerator = try #require(FileManager.default.enumerator(at: sourcesDirectoryURL, includingPropertiesForKeys: nil))
+        var unguardedImports: [String] = []
+        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
+            let source = try String(contentsOf: fileURL, encoding: .utf8)
+            unguardedImports += Self.unguardedMacOSOnlyImportLineNumbers(in: source).map { "\(fileURL.lastPathComponent):\($0)" }
+        }
+        #expect(unguardedImports.isEmpty, "these imports break the iOS-family builds: \(unguardedImports)")
+    }
+
+    /// Line numbers of macOS-only imports that no enclosing `#if` branch
+    /// restricts to macOS.
+    private static func unguardedMacOSOnlyImportLineNumbers(in source: String) -> [Int] {
+        // One entry per open `#if`: whether the branch in force requires macOS.
+        var branchRequiresMacOSStack: [Bool] = []
+        var unguardedLineNumbers: [Int] = []
+        for (lineIndex, line) in source.components(separatedBy: "\n").enumerated() {
+            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
+            if trimmedLine.hasPrefix("#if ") {
+                branchRequiresMacOSStack.append(requiresMacOS(trimmedLine))
+            } else if trimmedLine.hasPrefix("#elseif "), !branchRequiresMacOSStack.isEmpty {
+                branchRequiresMacOSStack[branchRequiresMacOSStack.count - 1] = requiresMacOS(trimmedLine)
+            } else if trimmedLine.hasPrefix("#else"), !branchRequiresMacOSStack.isEmpty {
+                branchRequiresMacOSStack[branchRequiresMacOSStack.count - 1] = false
+            } else if trimmedLine.hasPrefix("#endif"), !branchRequiresMacOSStack.isEmpty {
+                branchRequiresMacOSStack.removeLast()
+            } else if let moduleName = importedModuleName(trimmedLine),
+                      macOSOnlyModuleNames.contains(moduleName),
+                      !branchRequiresMacOSStack.contains(true) {
+                unguardedLineNumbers.append(lineIndex + 1)
+            }
+        }
+        return unguardedLineNumbers
+    }
+
+    private static func requiresMacOS(_ directive: String) -> Bool {
+        directive.contains("canImport(AppKit)") || (directive.contains("os(macOS)") && !directive.contains("!os(macOS)"))
+    }
+
+    private static func importedModuleName(_ line: String) -> String? {
+        guard !line.hasPrefix("//") else { return nil }
+        let words = line.split(separator: " ").map(String.init)
+        guard let importIndex = words.firstIndex(of: "import"), importIndex + 1 < words.count else { return nil }
+        return words[importIndex + 1].components(separatedBy: ".").first
+    }
+}
```
写方案时用同样的规则扫过 12e1227b，这四个 target 里只有 `ReportNode.swift:3` 这一处没守卫。其余 52 处 macOS 专属 import 都在 `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` 或 `#if os(macOS)` 里。

**同类**：整个 diff 只有这两处。Mac Catalyst 不受影响：Catalyst helper App 不链接任何包产品，它的插件是 macOS bundle。

**工作量**：S。它挡着发版，应排在所有条目之前；不依赖其它条目。


### PR121.02 FindSession 的 unowned documentState 在关窗后崩溃

- **严重度**：Major
- **审查编号**：C10
- **状态**：已修复。复现测试：`FindSessionLifecycleTests.sessionOutlivingItsDocumentIgnoresOptionsChange`（修前测试进程中止：`Fatal error: Attempted to read an unowned reference but object … was already destroyed`，signal 6）、`FindSessionLifecycleTests.closedSessionStartsNoSearch`（`documentWillClose()` 的契约）
- **落地与偏离**：`documentWillClose()` 比下文多一步，把 `isSearching` 置回 false：进行中的搜索被取消后按代数核对不会再清这个标志，不清就一直是 true。测试去掉了 `withSharedGenerationOptionsLock`（PR121.18 已撤下这把锁）。同类里 `InspectorRelationshipsViewModel` 的 `flatMapLatest { [unowned self] … }` 改成 `[weak self]` + `guard let self`，单独一个 refactor 提交：写不出修前失败的测试，因为这个闭包只由 ViewModel 自己的 `$runtimeObject` 驱动、订阅放在它自己的 `disposeBag` 里，deinit 时随之退订，之后不会再执行。`RuntimeViewerPackages/Sources` 与 `RuntimeViewerUsingAppKit` 里再没有别的 `[unowned self]`。

**问题**：`FindSession` 用 `unowned let documentState` 引用文档，但它可能活得比文档长。在 XPC 上，引擎调用取消不掉，搜索 Task 在等待期间强持有会话（`FindSession.swift:265` 的 `try await self?.perform(...)`）。会话又订阅着所有窗口共用的 Generation Options。关窗后，只要在别的窗口改一下选项，孤儿会话就会重跑搜索，读到已经释放的 `DocumentState`，整个 App 在 `swift_abortRetainUnowned` 处中止。

**四问**：
- **复现**：开两个窗口，在 A 里发起一次大范围文本搜索，搜索中关掉 A；趁它还没返回，在 B 里改任意一项 Generation Option。会话在 `:262`（`.currentImage` 范围时更早，在 `:222`）读 unowned 引用时中止。
- **基线**：本 PR 新引入（c3ad0839、4a0f1f5f）。
- **影响**：整个 App 崩溃。触发时机不常见，但可以刻意复现。建议修。
- **历史**：同类问题修过。6a8a60f3 在同样的崩溃之后把 content / inspector ViewModel 的 unowned 改成了 weak；本 PR 的 20383bf1 也给语料存储做了同样的修改。这里是漏掉的一处。

**改法**：
- 改成 `private weak var documentState: DocumentState?`。这个属性没有外部读者，顺带收窄访问级别。文档不在了，`startSearch` 就不再发请求，`.currentImage` 范围按「侧栏没有镜像」处理。
- 新增 `documentWillClose()`，由 `Document.close()` 调用，和 `backgroundIndexingCoordinator.documentWillClose()` 并列。它取消正在进行的搜索，并把 `disposeBag` 换成新的，从而退订选项和语料协调器的信号。这样一来，即使会话被某个引擎调用留住，也不会再自己启动任何搜索。
- 第三层是让搜索 Task 在等引擎期间不持有会话，这样文档一释放，会话就跟着释放。这一层改动在 PR121.05 里，与它的 `SearchRun` 一起落地。本条单独落地时，前两层已经足以消除崩溃。

**拟修改**（基准：`12e1227b`）：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -49,7 +49,11 @@ public final class FindSession {
     /// The most hits or members a search collects, across every image it
     /// reads; the count goes on past it.
     static let resultLimit = 1000
 
-    public unowned let documentState: DocumentState
+    /// Weak: the session can outlive its document. An engine call over a
+    /// connection runs to its answer even when cancelled, and until it does a
+    /// closed window's session is still alive — and still subscribed to the
+    /// Generation Options every window shares.
+    private weak var documentState: DocumentState?
 
     @RxObserved
@@ -101,6 +105,7 @@ public final class FindSession {
     @Dependency(\.appDefaults)
     private var appDefaults
 
-    private let disposeBag = DisposeBag()
+    /// Replaced when the document closes, which ends every subscription.
+    private var disposeBag = DisposeBag()
 
     public init(documentState: DocumentState) {
@@ -121,5 +126,15 @@ public final class FindSession {
     deinit {
         searchTask?.cancel()
     }
 
+    /// The document is closing. The search under way is cancelled, and nothing
+    /// starts another one: not a Generation Options change made in another
+    /// window, not a corpus the coordinator reports built.
+    public func documentWillClose() {
+        searchTask?.cancel()
+        searchTask = nil
+        searchGeneration += 1
+        disposeBag = DisposeBag()
+    }
+
     /// Hooks the session to the document's corpus coordinator, which calls
@@ -219,7 +234,7 @@ public final class FindSession {
         case .allIndexedImages:
             nil
         case .currentImage:
-            documentState.currentImageNode.map { [$0.path] } ?? []
+            (documentState?.currentImageNode).map { [$0.path] } ?? []
         case .images(let imagePaths):
             imagePaths
         }
@@ -258,6 +273,11 @@ public final class FindSession {
     private func startSearch(_ query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions, isWidening: Bool) {
+        // Closed while an engine call kept this session alive: there is no
+        // document to search for any more.
+        guard let engine = documentState?.runtimeEngine else {
+            isSearching = false
+            return
+        }
         isSearching = true
         searchGeneration += 1
         let generation = searchGeneration
-        let engine = documentState.runtimeEngine
         searchTask = Task { [weak self] in
```
```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift
@@ -28,4 +28,5 @@ final class Document: NSDocument {
     override func close() {
         documentState.backgroundIndexingCoordinator.documentWillClose()
+        documentState.findSession.documentWillClose()
         super.close()
     }
```

**复现测试（示例）**：放在新文件 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindSessionLifecycleTests.swift`。
- 第一条测试自己留住会话，模拟「引擎调用留住了会话」，然后释放文档、修改选项。修复前进程在读 unowned 引用处中止，和本 PR 的 `queuedBuildOutlivesBuilder` 一样，以崩溃作为红；修复后测试通过。
- 第二条是 `documentWillClose()` 的契约测试。

两条都不依赖引擎时序。PR121.05 和 PR121.38 会往同一个文件里继续加测试。
```swift
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The Find session against the life of its document and of the engine
/// calls it makes: a session may outlive its document while an engine call
/// holds it, and what a replaced or failed call brings back must not reach
/// the results on screen.
@Suite("FindSession lifecycle", .serialized)
@MainActor
struct FindSessionLifecycleTests {
    @Test("a session that outlives its document ignores a Generation Options change")
    func sessionOutlivingItsDocumentIgnoresOptionsChange() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment()

        try await withSharedGenerationOptionsLock {
            var documentState: DocumentState? = DocumentState(runtimeEngine: engine)
            weak var releasedDocumentState = documentState
            // Built inside `make` so the session's `@Dependency` takes the
            // isolated `AppDefaults`.
            let session = environment.make { documentState!.findSession }
            session.run(FindQuery(mode: .text, text: "NSObject"))
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
            #expect(session.results.summary != nil, "a search on screen is what a Generation Options change runs again")

            // The session stays alive the way an engine call that cannot be
            // cancelled keeps it alive; the document goes.
            documentState = nil
            #expect(releasedDocumentState == nil)

            let appDefaults = environment.appDefaults
            let originalOptions = appDefaults.options
            defer { appDefaults.options = originalOptions }
            var changedOptions = originalOptions
            changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
            appDefaults.options = changedOptions
            try await settleMainQueue()

            // Before the fix the rerun read the freed document through
            // `unowned` and the process aborted here.
            #expect(session.isSearching == false)
        }
    }

    @Test("after its document closes, a session starts no search on a Generation Options change")
    func closedSessionStartsNoSearch() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        try await withSharedGenerationOptionsLock {
            session.run(FindQuery(mode: .text, text: "NSObject"))
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
            let resultsBeforeClose = session.results

            session.documentWillClose()

            let appDefaults = environment.appDefaults
            let originalOptions = appDefaults.options
            defer { appDefaults.options = originalOptions }
            var changedOptions = originalOptions
            changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
            appDefaults.options = changedOptions

            let searchingStates = try await values(from: session.$isSearching.asDriver(), during: 1)
            #expect(!searchingStates.contains(true))
            #expect(session.results == resultsBeforeClose)
        }
    }

    static func imagePath(of node: FindResultNode) -> String? {
        if case .object(let object, _) = node.content {
            return object.imagePath
        }
        return nil
    }
}
```

**同类**：本 PR 新增的 `unowned` 只有两处。
- 本处。
- `FindCorpusCoordinator.swift:62`：只在 `init` 里读（`:132-138`，以及在 init 里建立的 `:419` 订阅），所以安全。建议干脆不保存这个属性；那个文件归 PR121.04 一组的协调器改动处理。

基线上已有的 `unowned`：
- `RuntimeBackgroundIndexingCoordinator.swift:33` 只在 init 里读，安全。
- `DocumentState.swift:264` 的 `SelectionRouter` 由 `DocumentState` 独占，没有闭包捕获它，安全。
- `InspectorRelationshipsViewModel.swift:67` 的 `flatMapLatest { [unowned self] … }`（af8961c5）字面上违反了 AGENTS.md「Rx 算子闭包不用 unowned」。但这个闭包由 ViewModel 自己的 relay 驱动，随 disposeBag 一起退订，deinit 之后不会执行。它不在本 PR 范围内，建议另开一个改动改成 `[weak self]`，或者记入 KnownIssues。

**工作量**：S。不依赖其他条目，建议最先单独提交；PR121.05 在它之上继续改。


### PR121.03 interfaceString 改成 FrozenSemanticString 破坏新旧版本互通

- **严重度**：Major
- **审查编号**：C36
- **状态**：方案待批，代码未改

**问题**：`RuntimeObjectInterface` 的 Codable 是编译器自动合成的。这个 PR 把 `interfaceString` 从 `SemanticString` 换成了 `FrozenSemanticString`，线上格式随之改变：
- **旧格式**：组件数组，每项是 `{string,type,identifier?}`。
- **新格式**：带键的列式对象 `{text,spanLengths,spanTypeCodes,spanIdentifierIndices,identifierTable}`（swift-semantic-string next@ef4bd309 的 `FrozenSemanticString+Codable.swift`）。

两种格式互相解码都会失败，而引擎连接上不交换协议版本（`RuntimeViewerServiceVersion` 只用于 helper daemon）。结果是：新版本的 Mac 连上 beta.6 的 iPhone、iPad、模拟器或旧版 Mac，点任何类型，内容面板都一片空白，也不报错；反方向同样失败。

**四问**：
- **复现**：新版 Mac 选中一个 beta.6 对端并点开任意类型，`FrozenSemanticString.init(from:)` 在数组上抛出 `DecodingError.typeMismatch`，`ContentTextViewModel` 的 `catchAndReturn(nil)` 把它吞掉，面板空白。经旧版中转的镜像、升级前就注入且仍在运行的旧 payload，也一样。
- **基线**：本 PR 新引入（99d85ea8）。beta.6 线上仍是数组形状。两个 pin（ff626b0f / ef4bd309）之间 `SemanticType` 没有变化，所以旧形状仍能被旧读端完整读出。
- **影响**：
  - 坏的是已有的内容面板，不只是 Find。
  - 项目文档承诺「双向兼容，不要求同版本」（`CommunicationAndEngineArchitecture.md:497`），PR106.10 也记着「iOS 端有外部用户，混版是常态」。
  - 建议修。
- **历史**：
  - 同类问题刚在 next 上修过：db700876，起因是新增的 `RuntimeSource` case 让旧版 Mac 解不开整个引擎列表。
  - 这次的改动是有意的：提案 §0 和注释只算了体积收益（XPC 载荷小一个数量级），没考虑混版。

**改法**：
- **请求带上声明**：`InterfaceRequest` 增加 `acceptsColumnarInterfaceString: Bool?`。旧服务端解码时会忽略这个多出的键；旧客户端不发它，解码得到 `nil`。
- **回复类型换成 `RuntimeObjectInterfaceResponse`**，线上形状仍是 `RuntimeObjectInterface?`：
  - 编码：服务端只在请求方声明读得懂时写列式，缺省一律写组件数组。组件数组由 `SemanticString(components: frozen.components)` 得到，与 beta.6 逐字段相同。
  - 解码：先按列式解，失败再按组件式解。两种都失败时，抛出列式那次的错误，因为它描述的是当前格式。
- **拿不准就给旧形状**，这样新旧任意组合都读得了。代理转发（`RuntimeEngineProxyServer` 经 `engine.dispatch` 转发）时，按收到的形状原样再写出去：它转发的就是自己请求方那条请求，所以这个形状请求方一定读得了。代价只是经过旧节点时退回组件数组的体积。
- **公开 API 不变**：`interface(for:options:)` 的签名不变，CLI、MCP、导出都不用改。
- **另外两个方案及取舍**：
  - 另开一个命令传列式（审查的原建议）：要多一轮回退往返，还要按引擎记住「对端没有这个命令」。2.1.0 之前的对端对未知命令不回复，只能等到超时。
  - 接受破坏：违背已写明的兼容承诺，属于破坏性改动，要走完整提案。
- **文档同步**：注释、架构文档（新增 §4.4，写下「改已有命令载荷形状」的规则）、提案 §0 和决策日志，同批更新。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Requests.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Requests.swift
@@ -112,8 +112,23 @@ extension RuntimeEngine {
     struct InterfaceRequest: RuntimeEngineRequest {
         let object: RuntimeObject
         let options: RuntimeObjectInterface.GenerationOptions
+        /// Sent as `true` by builds that read `interfaceString` in the
+        /// columnar `FrozenSemanticString` encoding. Builds before it send no
+        /// such key and decode it as `nil`; servers before it ignore it. Both
+        /// get the component array they were built for — see
+        /// `RuntimeObjectInterfaceResponse`.
+        let acceptsColumnarInterfaceString: Bool?
         static var commandName: String { CommandNames.runtimeInterfaceForRuntimeObjectInImageWithOptions.commandName }
-        func perform(on engine: RuntimeEngine) async throws -> RuntimeObjectInterface? {
-            try await engine._interface(for: object, options: options)
+        func perform(on engine: RuntimeEngine) async throws -> RuntimeObjectInterfaceResponse {
+            let interface = try await engine._interface(for: object, options: options)
+            return response(for: interface)
+        }
+
+        /// The reply, in the encoding the sender of this request reads.
+        func response(for interface: RuntimeObjectInterface?) -> RuntimeObjectInterfaceResponse {
+            RuntimeObjectInterfaceResponse(
+                interface: interface,
+                interfaceStringEncoding: acceptsColumnarInterfaceString == true ? .columnar : .components
+            )
         }
     }
```

```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterfaceResponse.swift
@@ -0,0 +1,87 @@
+import Foundation
+import Semantic
+
+/// `InterfaceRequest`'s reply. On the wire it is exactly a
+/// `RuntimeObjectInterface?`, with `interfaceString` in one of the two
+/// encodings peers have shipped with:
+///
+/// - `components`: `SemanticString`'s array of components, the only shape
+///   builds up to 3.0.0-beta.6 can read;
+/// - `columnar`: `FrozenSemanticString`'s own encoding, an order of magnitude
+///   smaller, sent only to a requester that says it reads it.
+///
+/// Engine connections exchange no protocol version, and peers of different
+/// builds are expected to talk to each other (`CommunicationAndEngineArchitecture.md`
+/// §4.4), so the request states what its sender reads and this type decodes
+/// either shape.
+struct RuntimeObjectInterfaceResponse: Sendable {
+    enum InterfaceStringEncoding: Sendable {
+        case components
+        case columnar
+    }
+
+    let interface: RuntimeObjectInterface?
+
+    /// Chosen from the request on the serving side; recorded from what
+    /// arrived on the receiving side. A proxy relaying the reply therefore
+    /// writes it on in the shape it got — which its own requester can read,
+    /// because the proxy forwarded that requester's request unchanged.
+    let interfaceStringEncoding: InterfaceStringEncoding
+}
+
+extension RuntimeObjectInterfaceResponse: Codable {
+    init(from decoder: any Decoder) throws {
+        let container = try decoder.singleValueContainer()
+        if container.decodeNil() {
+            interface = nil
+            interfaceStringEncoding = .components
+            return
+        }
+        do {
+            interface = try container.decode(RuntimeObjectInterface.self)
+            interfaceStringEncoding = .columnar
+        } catch let columnarDecodingError {
+            // Not the columnar shape: a peer that predates it. If it is not
+            // the component shape either, the columnar failure is the one that
+            // describes the current format.
+            guard let componentEncodedInterface = try? container.decode(ComponentEncodedRuntimeObjectInterface.self) else {
+                throw columnarDecodingError
+            }
+            interface = componentEncodedInterface.runtimeObjectInterface
+            interfaceStringEncoding = .components
+        }
+    }
+
+    func encode(to encoder: any Encoder) throws {
+        var container = encoder.singleValueContainer()
+        guard let interface else {
+            try container.encodeNil()
+            return
+        }
+        switch interfaceStringEncoding {
+        case .columnar:
+            try container.encode(interface)
+        case .components:
+            try container.encode(ComponentEncodedRuntimeObjectInterface(interface))
+        }
+    }
+}
+
+/// `RuntimeObjectInterface` as builds up to 3.0.0-beta.6 declare it. The
+/// synthesized `Codable` is the point: it has to stay byte for byte what
+/// those builds read and write.
+struct ComponentEncodedRuntimeObjectInterface: Codable, Sendable {
+    let object: RuntimeObject
+    let interfaceString: SemanticString
+
+    init(_ interface: RuntimeObjectInterface) {
+        object = interface.object
+        interfaceString = SemanticString(components: interface.interfaceString.components)
+    }
+
+    /// Frozen again on the way in: everything past the wire handles the
+    /// frozen form only.
+    var runtimeObjectInterface: RuntimeObjectInterface {
+        RuntimeObjectInterface(object: object, interfaceString: interfaceString)
+    }
+}
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
@@ -1013,5 +1013,5 @@
 
     public func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
-        try await dispatch(InterfaceRequest(object: object, options: options))
+        try await dispatch(InterfaceRequest(object: object, options: options, acceptsColumnarInterfaceString: true)).interface
     }
 
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterface.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterface.swift
@@ -7,9 +7,11 @@ public struct RuntimeObjectInterface: Codable, Sendable {
     /// The generated interface in its immutable terminal form. A stored
     /// interface is only rendered, encoded, exported, or searched from here
     /// on — never recomposed — so it is frozen at this boundary: one text
     /// string plus 8-byte spans instead of the printer's component
     /// representation (~40 B/token flat, ~144 B/token as a construction
-    /// tree). Freezing also switches the wire format to the columnar
-    /// `FrozenSemanticString` encoding, which is an order of magnitude
-    /// smaller over XPC/TCP.
+    /// tree). This type's own `Codable` is the columnar
+    /// `FrozenSemanticString` encoding, an order of magnitude smaller over
+    /// XPC/TCP; the interface request sends it only to a requester that says
+    /// it reads it, and the component array to everyone else — see
+    /// `RuntimeObjectInterfaceResponse`.
     public let interfaceString: FrozenSemanticString
```

```diff
--- a/Documentations/CommunicationAndEngineArchitecture.md
+++ b/Documentations/CommunicationAndEngineArchitecture.md
@@ -367,6 +367,16 @@
 - 非 macOS：`RuntimeRequest: Codable & Sendable`，带 `associatedtype Response: RuntimeResponse` 与 `static var identifier`。
 - macOS：`RuntimeRequest` **refine** `HelperCommunication.Request`，于是任何 daemon-bound 业务请求能直接挂到 `HelperService` / `HelperPeer` 上。
 - 同文件还定义了跨进程共享的 Mach 服务名 `RuntimeViewerMachServiceName`（Debug 下按 arm64e 变体切换）与协议版本 `RuntimeViewerServiceVersion`。
 
+### 4.4 改已有命令的载荷形状
+
+引擎之间的连接不交换协议版本（`RuntimeViewerServiceVersion` 只管 helper daemon），新旧版本的对端互连是常态（§8「双向兼容，不要求同版本」）。所以**已经发布的命令，请求与回复的形状只能这样改**：
+
+- **接收方容错**：新的解码同时接受旧形状；两种都解不出来时，抛新形状那次的错误。
+- **发送方保守**：只有请求方声明读得懂时才发新形状——请求里加一个可选字段，旧对端解码时会忽略它，旧请求解出 `nil`——其余一律发旧形状。经过旧节点转发时退回旧形状，代价只是体积。
+- **配冻结读端测试**：旧读端与旧请求在测试里手写，照发布时的形状冻结，不复用当前类型。用当前类型自编自解，只能证明它和自己一致。
+
+第一例是接口请求：`interfaceString` 的列式编码只发给带 `acceptsColumnarInterfaceString: true` 的请求方，回复类型 `RuntimeObjectInterfaceResponse` 两种形状都能解。新增**命令**不在此列，但旧对端会对它回「No handler registered」（2.1.0 起），调用方要把这当成「对端不支持」，而不是一次普通失败。
+
 ---
 
```

```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -35,6 +35,10 @@
 `FrozenSemanticString`、`388dd212` 应用侧改按 span 渲染）先单独 rebase 到 `next` 合入。理由有两条，都与本提案无关也
 成立：`RuntimeObjectInterface` 现在每一份都过 XPC（「My Mac」引擎已在 `RuntimeViewerLocalRuntimeService.xpc` 里），
 Frozen 的列式编码比逐 component 编码小一个数量级；语料条目本来就是 Frozen，不改边界就要在 store 里再冻一次、
 两种形态并存。
 
+**列式编码只发给声明读得懂的请求方。** 3.0.0-beta.6 及更早的对端只认逐 component 的数组，引擎连接上又不交换协议版本，
+所以接口请求带上 `acceptsColumnarInterfaceString`，没带的一律回旧形状，回复两种形状都能解（决策日志 2026-10-07；
+规则见 `CommunicationAndEngineArchitecture.md` §4.4）。
+
 `next` 上的消费点比分支当年多，rebase 时逐个改：`ContentTextViewModel`（`interfaceString` 类型与
@@ -756,1 +760,2 @@
 | 2026-10-04 | 一个都没选时 OK 置灰；表单列表覆写 `mouseDown(with:)`；菜单项不带图标 | Xcode 的 OK 此时能点却不改范围，置灰更直观。不覆写时 macOS 27 的列表点击不给焦点，选中的行一直是灰色，与 `StatefulOutlineView` 同一取舍。我们没有与 Xcode 那几个范围对应的图标。 |
+| 2026-10-07 | 接口请求的列式编码只发给声明读得懂的请求方，回复两种形状都能解 | PR #121 审查发现：`interfaceString` 改成 `FrozenSemanticString` 后，自动合成的编码从数组变成带键对象，与 3.0.0-beta.6 及更早的对端互相解不开，内容面板静默空白；而项目承诺新旧版本互通，iOS 端混版是常态。另开新命令要多一轮回退往返，2.1.0 之前的对端还会等到超时；接受破坏违背承诺。请求里加一个可选字段最小：旧端忽略它，新端缺省回旧形状。 |
```

**复现测试（示例）**：新建 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeObjectInterfaceWireCompatibilityTests.swift`，照 db700876 和 `RuntimeRemoteEngineDescriptorCompatibilityTests` 的写法冻结旧读端与旧请求。
- **为什么修前会红**：前两条要在修复前先跑一遍，写法是把 `RuntimeObjectInterfaceResponse` 换成当前的回复类型 `RuntimeObjectInterface?`，此时：
  - 第一条：在数组上抛 `DecodingError.typeMismatch`。
  - 第二条：新服务端写出的是带键对象，冻结读端解不开。
- **修后**：四条全绿。第三条守住新版本之间的体积收益，第四条守住 `nil` 的形状。
- **补充**：Mach service 连接走的是 SwiftyXPC 的 `XPCEncoder`，不是 JSON，可以照样用它把前两条再跑一遍。
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeObjectInterfaceWireCompatibilityTests.swift
@@ -0,0 +1,101 @@
+import Foundation
+import Semantic
+import Testing
+@testable import RuntimeViewerCore
+
+/// Mixed-version wire compatibility for the interface request, whose reply
+/// carries `RuntimeObjectInterface.interfaceString`.
+///
+/// Builds up to 3.0.0-beta.6 write `interfaceString` as a `SemanticString`
+/// component array and cannot read `FrozenSemanticString`'s columnar
+/// encoding. The old reader and the old request below are frozen copies of
+/// those shapes, never the current types — a type encoding and decoding its
+/// own output only proves it agrees with itself.
+@Suite("Interface request mixed-version compatibility")
+struct RuntimeObjectInterfaceWireCompatibilityTests {
+    /// `RuntimeObjectInterface` as 3.0.0-beta.6 declares it.
+    private struct ShippedRuntimeObjectInterface: Codable {
+        let object: RuntimeObject
+        let interfaceString: SemanticString
+    }
+
+    /// `InterfaceRequest` as 3.0.0-beta.6 declares it.
+    private struct ShippedInterfaceRequest: Codable {
+        let object: RuntimeObject
+        let options: RuntimeObjectInterface.GenerationOptions
+    }
+
+    private static let object = RuntimeObject(
+        name: "NSObject",
+        displayName: "NSObject",
+        kind: .objc(.type(.class)),
+        imagePath: "/usr/lib/libobjc.A.dylib",
+        children: []
+    )
+
+    /// Several semantic types and one span identity, so the type codes and
+    /// the identifier table both have something to carry.
+    private static let interfaceString = SemanticString(components: [
+        AtomicComponent(string: "@interface", type: .keyword),
+        AtomicComponent(string: " ", type: .standard),
+        AtomicComponent(string: "NSObject", type: .type(.class, .declaration)),
+        AtomicComponent(string: " <", type: .standard),
+        AtomicComponent(string: "NSObject", type: .type(.protocol, .name), identifier: "NSObjectProtocolIdentity"),
+        AtomicComponent(string: ">\n@end", type: .standard),
+    ])
+
+    @Test("a reply from a build that predates the columnar encoding decodes")
+    func replyFromShippedBuildDecodes() throws {
+        let shippedReply = ShippedRuntimeObjectInterface(object: Self.object, interfaceString: Self.interfaceString)
+        let data = try JSONEncoder().encode(Optional(shippedReply))
+
+        let response = try JSONDecoder().decode(RuntimeObjectInterfaceResponse.self, from: data)
+
+        let interface = try #require(response.interface)
+        #expect(interface.object == Self.object)
+        #expect(interface.interfaceString.string == Self.interfaceString.string)
+        #expect(interface.interfaceString.components == Self.interfaceString.components)
+        #expect(response.interfaceStringEncoding == .components)
+    }
+
+    @Test("a request from a build that predates the columnar encoding is answered in components")
+    func requestFromShippedBuildIsAnsweredInComponents() throws {
+        let shippedRequest = ShippedInterfaceRequest(object: Self.object, options: RuntimeObjectInterface.GenerationOptions())
+        let request = try JSONDecoder().decode(RuntimeEngine.InterfaceRequest.self, from: JSONEncoder().encode(shippedRequest))
+        let interface = RuntimeObjectInterface(object: Self.object, interfaceString: Self.interfaceString)
+
+        let data = try JSONEncoder().encode(request.response(for: interface))
+
+        let shippedReply = try #require(try JSONDecoder().decode(ShippedRuntimeObjectInterface?.self, from: data))
+        #expect(shippedReply.interfaceString.components == Self.interfaceString.components)
+    }
+
+    @Test("a request that reads the columnar encoding gets it")
+    func columnarRequestGetsColumnarReply() throws {
+        let request = RuntimeEngine.InterfaceRequest(object: Self.object, options: RuntimeObjectInterface.GenerationOptions(), acceptsColumnarInterfaceString: true)
+        let interface = RuntimeObjectInterface(object: Self.object, interfaceString: Self.interfaceString)
+
+        let data = try JSONEncoder().encode(request.response(for: interface))
+
+        let replyObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
+        let interfaceStringObject = try #require(replyObject["interfaceString"] as? [String: Any])
+        #expect(interfaceStringObject["spanLengths"] != nil)
+        let response = try JSONDecoder().decode(RuntimeObjectInterfaceResponse.self, from: data)
+        #expect(response.interface?.interfaceString == interface.interfaceString)
+        #expect(response.interfaceStringEncoding == .columnar)
+    }
+
+    @Test("no interface travels as null in either encoding", arguments: [false, true])
+    func missingInterfaceIsNull(acceptsColumnarInterfaceString: Bool) throws {
+        let request = RuntimeEngine.InterfaceRequest(
+            object: Self.object,
+            options: RuntimeObjectInterface.GenerationOptions(),
+            acceptsColumnarInterfaceString: acceptsColumnarInterfaceString
+        )
+
+        let data = try JSONEncoder().encode(request.response(for: nil))
+
+        #expect(String(decoding: data, as: UTF8.self) == "null")
+        #expect(try JSONDecoder().decode(ShippedRuntimeObjectInterface?.self, from: data) == nil)
+    }
+}
```

**同类**：本 PR 里改了形状的已有线上类型只有这一个，其余都核对过：
- `RuntimeEngineRequest` 只新增了九个命令。
- `GenerationOptions` 与 RuntimeViewerCommunication 都没动。
- `RuntimeInterfaceExportEvent` 不是 Codable，不上线。
- CLI 和 MCP 只把 `.string` 文本送出进程。

新命令对旧对端会回「No handler registered」，这条单列为 PR121.37。

**工作量**：M，可以和 PR121.01 并行。PR121.29 设计跨连接取消时若要给已有请求加字段，照这里写进 §4.4 的同一条规则做。


### PR121.04 在侧栏打开的已加载镜像永远建不出语料

- **严重度**：Major
- **审查编号**：C15（含 U2）（上次第 4 条）
- **状态**：方案待批，代码未改

**问题**：
- 语料协调器只认两种触发：后台索引的 `taskFinished` 和 `imageDidLoadPublisher`。
- 在侧栏打开一个早已加载的镜像时，走的是 `objectsWithProgress` → `_localObjectsWithProgress`。这条路径会把镜像索引好，却不发任何事件。
- 在默认设置下（后台索引关、语料开），用户最常打开的镜像（Foundation、AppKit、libobjc……）因此永远建不出语料。Text 和 Members 搜索一直报「not yet searchable」，等多久都不会好。附加到其他进程时，几乎所有镜像都是这种「已加载」状态。

**四问**：
- 复现：在 My Mac 上打开窗口，在侧栏点开 Foundation，然后在 Indexed Images 作用域里搜 `NSString`。结果是「0 results … · 1 image not yet searchable」，并且一直不变。只有再开一个窗口、换引擎、拨一下语料开关，或把作用域缩到这个镜像，才会恢复。
- 基线：本 PR 新引入。
- 影响：对这个功能影响很大。最常用的镜像搜不到，状态栏还暗示「再等等就好」。建议修。
- 历史：2026-09-29 那份关于事件拆分的 ResolvedIssue（3eb86d72）注意到，补建发生在任何镜像被索引之前，但没有检查侧栏这条路径。

**改法**：
- **新事件放在客户端引擎的 API 边界**，不新增推送命令。
  - 新增 `RuntimeEngine.imageDidIndexPublisher`。以下公开方法成功返回后，用调用方传入的路径发一次：`objects(in:)`、`objectsWithProgress(in:)`（两者共用 `foregroundObjects`）、`loadImage(at:)` 的两个重载、`loadImageForBackgroundIndexing(at:)`。这些方法的约定就是「返回时两个 section 都已建好」。
  - 转发引擎在本进程里发这个事件，所以远端引擎的客户端天然能收到。对端是旧版本也照样工作：事件完全由客户端自己产生。
- **协调器只订阅这一个发布者**，去掉后台索引事件泵和 `imageDidLoad` 订阅。
  - 后台索引的每次加载都经过 `loadImageForBackgroundIndexing`，所以不会漏。
  - 事件泵原本跑在主 actor 上、每个索引事件唤醒一次主线程（U2），随之消失，见 PR121.36。
  - 顺序与现在相同：先订阅，再补建已经索引过的镜像。
- **什么时候排到队首**：
  - 已有在途请求，或状态已是 `.built`，就跳过。
  - 只有当前侧栏打开的镜像才排到队首。协调器订阅 `documentState.$currentImageNode`，缓存它的路径。
  - 这样批量导出时的 `loadImage` 不再把每个导出的镜像都插到队首。
  - 路径的规范化见 PR121.33：模拟器引擎上比较之前要先规范化。
- **协调器不再保存 `documentState`**：它原本是 `unowned`，而且只在 `init` 里读。模块 D1 在 PR121.02 里也建议这样做。
- **不选的方案**：在服务端建 section 的地方发事件，再加一条推送命令。这样能知道别的进程触发的索引，但要新增命令，还要为旧对端另做兜底。别的进程索引的镜像，由开窗时的补建和 PR121.34 的「搜索后对账」覆盖。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
@@ -242,6 +242,24 @@ public actor RuntimeEngine {
 
     private nonisolated let imageDidLoadSubject = PassthroughSubject<String, Never>()
 
+    /// Publisher that emits an image's path each time this engine's API
+    /// returns with the image indexed: `objects(in:)`, `objectsWithProgress(in:)`,
+    /// both `loadImage(at:)` overloads and `loadImageForBackgroundIndexing(at:)`.
+    ///
+    /// Emitted by the engine the caller holds, so a client engine reports what
+    /// its own requests indexed without any message from the peer — and with a
+    /// peer that predates it. An image already indexed is reported again;
+    /// subscribers deduplicate. The path is the caller's, not the canonical one.
+    ///
+    /// `nonisolated` for the same reason as `imageDidLoadPublisher`.
+    public nonisolated var imageDidIndexPublisher: some Publisher<String, Never> {
+        imageDidIndexSubject
+    }
+
+    // Internal, not private: `loadImageForBackgroundIndexing` emits it from
+    // RuntimeEngine+BackgroundIndexing.swift.
+    nonisolated let imageDidIndexSubject = PassthroughSubject<String, Never>()
+
     /// In-flight progress routes keyed by the per-round-trip token minted in
     /// `dispatch(_:onProgress:)`. Inbound `progressEvent` pushes look up
     /// their token here and forward the decoded payload to the awaiting
@@ -957,6 +975,7 @@ public actor RuntimeEngine {
     public func loadImage(at path: String) async throws {
         try await performingForegroundLoad {
             _ = try await dispatch(LoadImageRequest(path: path))
         }
+        imageDidIndexSubject.send(path)
     }
 
@@ -975,5 +994,6 @@ public actor RuntimeEngine {
         try await performingForegroundLoad {
             _ = try await dispatch(LoadImageWithProgressRequest(path: path), onProgress: onProgress)
         }
+        imageDidIndexSubject.send(path)
     }
 
@@ -1042,8 +1062,10 @@ public actor RuntimeEngine {
     private func foregroundObjects(
         in image: String,
         onProgress: (@Sendable (RuntimeObjectsLoadingProgress) async -> Void)?
     ) async throws -> [RuntimeObject] {
-        try await performingForegroundLoad {
+        let objects = try await performingForegroundLoad {
             try await dispatch(ObjectsInImageRequest(image: image), onProgress: onProgress)
         }
+        imageDidIndexSubject.send(image)
+        return objects
     }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift
@@ -33,5 +33,8 @@ extension RuntimeEngine {
     /// `RuntimeBackgroundIndexingCoordinator`'s image-loaded pump and
     /// recursively spawn a fresh batch for every image we just indexed.
+    /// It does emit `imageDidIndexPublisher`, which nothing in background
+    /// indexing listens to.
     public func loadImageForBackgroundIndexing(at path: String) async throws {
         _ = try await dispatch(LoadImageForBackgroundIndexingRequest(path: path))
+        imageDidIndexSubject.send(path)
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -59,13 +59,15 @@ public final class FindCorpusCoordinator {
         let task: Task<Void, Never>
     }
 
-    private unowned let documentState: DocumentState
-
     private var engine: RuntimeEngine
 
-    private var eventPumpTask: Task<Void, Never>?
+    /// The engine's "image indexed" notifications, which queue each newly
+    /// indexed image for its corpus.
+    private var imageIndexedSubscription: AnyCancellable?
 
-    private var imageDidLoadSubscription: AnyCancellable?
+    /// The image the sidebar lists. One that becomes indexed while it is on
+    /// screen goes to the front of the queue.
+    private var currentImagePath: String?
 
     /// The build requests this document holds open, by image path.
     /// Cancelling one withdraws only this document's interest.
@@ -129,18 +131,17 @@ public final class FindCorpusCoordinator {
     }
 
     public init(documentState: DocumentState) {
-        self.documentState = documentState
         self.engine = documentState.runtimeEngine
         #if canImport(RuntimeViewerSettings)
         bootstrapSettingsObservation()
         #endif
-        bootstrapEngineObservation()
+        bootstrapEngineObservation(of: documentState)
+        bootstrapCurrentImageObservation(of: documentState)
         documentState.findSession.follow(self)
         startPumps()
     }
 
     deinit {
-        eventPumpTask?.cancel()
         transformerRebuildTask?.cancel()
         for request in buildRequests.values {
             request.task.cancel()
@@ -375,47 +376,47 @@ public final class FindCorpusCoordinator {
     private func startPumps() {
         let engine = engine
-        eventPumpTask = Task { [weak self] in
-            let stream = await engine.backgroundIndexingManager.events
-            // Subscribed before asking, so no image slips through in between:
-            // one that finishes from here on arrives below as an event, one
-            // that finished earlier is in the engine's indexed list.
-            if let self, self.engine === engine {
-                self.requestBuildOfIndexedImages()
-            }
-            for await event in stream {
-                guard let self, self.engine === engine else { return }
-                if case .taskFinished(_, let path, let result) = event, case .completed = result {
-                    self.requestBuild(of: path)
-                }
-            }
-        }
-        imageDidLoadSubscription = engine.imageDidLoadPublisher
+        // Subscribed before asking, so no image slips through in between: one
+        // indexed from here on arrives below, one indexed earlier is in the
+        // engine's indexed list. The engine reports every image its own API
+        // indexed — the background indexer's loads, an export's, an image the
+        // sidebar opened — so only images another process indexed are left to
+        // the catch-up a finished search runs.
+        imageIndexedSubscription = engine.imageDidIndexPublisher
             .receive(on: DispatchQueue.main)
             .sink { [weak self] imagePath in
                 MainActor.assumeIsolated {
                     guard let self, self.engine === engine else { return }
-                    // The user opened it, so it goes first.
-                    self.requestBuild(of: imagePath, isPrioritized: true)
+                    self.imageDidIndex(at: imagePath)
                 }
             }
+        requestBuildOfIndexedImages()
         // What other documents sharing the engine have built or are building.
         refreshCoverage()
         #if canImport(RuntimeViewerSettings)
         applyResidentByteLimit()
         #endif
     }
 
     private func stopPumps() {
-        eventPumpTask?.cancel()
-        eventPumpTask = nil
-        imageDidLoadSubscription = nil
+        imageIndexedSubscription = nil
         transformerRebuildTask?.cancel()
         transformerRebuildTask = nil
     }
 
+    /// An image the engine reports indexed. One with a request open or a
+    /// corpus built needs nothing; the image on screen goes first, every
+    /// other one — an export's, the background indexer's — waits its turn.
+    private func imageDidIndex(at imagePath: String) {
+        let isOnScreen = imagePath == currentImagePath
+        if buildRequests[imagePath] == nil, buildStatesByImagePath[imagePath]?.isBuilt == true {
+            return
+        }
+        requestBuild(of: imagePath, isPrioritized: isOnScreen)
+    }
+
     // MARK: - Engine swap
 
-    private func bootstrapEngineObservation() {
+    private func bootstrapEngineObservation(of documentState: DocumentState) {
         documentState.$runtimeEngine
             .skip(1)
             .subscribeOnNext { [weak self] newEngine in
@@ -425,6 +425,15 @@ public final class FindCorpusCoordinator {
             .disposed(by: disposeBag)
     }
 
+    private func bootstrapCurrentImageObservation(of documentState: DocumentState) {
+        documentState.$currentImageNode
+            .subscribeOnNext { [weak self] imageNode in
+                guard let self else { return }
+                self.currentImagePath = imageNode?.path
+            }
+            .disposed(by: disposeBag)
+    }
+
     /// The new engine has corpora of its own, so the states start over; the
     /// history stays — it reads as what this document built this session,
     /// like the indexing history.
```
类型顶部的说明注释（`FindCorpusCoordinator.swift:21-31`）中「1. an image the background indexer finished; 2. an image the user opened, moved to the front of the queue」两条，要同批改为「every image the engine's API indexed; the one on screen first」。

**复现测试（示例）**：
- 放在 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindCorpusCoordinatorTests.swift`。
- libobjc 在测试进程里已经加载，但这个新引擎还没索引它，正是「已加载、未索引」的情形。`objects(in:)` 走的就是侧栏那条路径。
- 修复前，协调器不会收到任何触发，60 秒后 `nextValue` 超时，测试失败。

```swift
@Test("an image the sidebar opens, already loaded, gets its corpus built")
func imageOpenedInTheSidebarBecomesSearchable() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.sidebarOpen")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }

    // The sidebar's path: list the objects of an image dyld already has.
    _ = try await engine.objects(in: TestImages.libobjc)

    let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) {
        $0[TestImages.libobjc]?.isBuilt == true
    }
    #expect(states[TestImages.libobjc]?.isBuilt == true)
    await engine.stop()
}
```
另在 `RuntimeViewerCore` 的测试里加一条引擎级测试：订阅 `imageDidIndexPublisher` 后调用 `objects(in:)`，断言收到的路径就是调用方传入的路径。这条测试对应发布者本身的约定。

**同类**：
- MCP 和 CLI host 在 App 进程里对同一个引擎调用 `objects(in:)` 时，也会触发语料构建。这是预期行为：被索引的镜像都应当能搜到。
- `RuntimeBackgroundIndexingCoordinator` 不订阅新的发布者。`loadImageForBackgroundIndexing` 那段注释说的「为每个镜像再开一批」的回环不会出现。

**工作量**：M。PR121.32 依赖本条在镜像被索引后重新请求；PR121.33 会对本条比较当前镜像的地方补上规范化；PR121.36 随本条一起解决。


### PR121.05 旧搜索的批次混进当前结果；换引擎后结果混杂

- **严重度**：Major
- **审查编号**：C05 + C09
- **状态**：方案待批，代码未改

**问题**：一次文本或成员搜索的结果分批送到，按镜像一批一批到达。追加这些批次的 `appendTextMatches` / `appendMemberMatches`（`FindSession.swift:337-345`）从不检查这批结果属于哪次搜索。在 App 的 XPC 引擎上，取消搜索的 Task 也停不下已经发出的请求：服务端会把剩下的每一批照样推回来。于是新查询的结果里会混进旧查询的命中，点了 Clear 的空列表又被填满，计数也和总数对不上。另外，会话从不观察 `documentState.$runtimeEngine`，换数据源以后旧行原样留着；新引擎每建好一个语料，还会在新引擎上补搜，再把结果并进旧引擎的结果里。

**四问**：
- **复现**：在 My Mac 上搜 `view`，没搜完就改搜 `window`，或者点 Clear；剩下的 `view` 批次照样进列表。也可以在有结果时切换数据源，旧行不会消失。
- **基线**：本 PR 新引入（c3ad0839、8ce77d36）；传输层不支持取消是原有问题。
- **影响**：凡是在搜索进行中又发起新搜索的用户都会遇到，结果是错的但不崩溃。建议修。
- **历史**：都是新代码。测试只用了进程内引擎，那里取消在每个镜像之间都会被检查，所以测试一直没暴露这个问题。

**改法**：
- **新增身份对象 `SearchRun`**：每次引擎调用（一次首搜，或一次补搜）对应一个。会话只保留一个 `currentRun`。每批结果、每个回复都带着自己的 run，回到主线程后先判断 `run === currentRun`，不是就丢弃。被替换的调用无论还送来什么，都碰不到屏上的结果，效果等同于 flatMapLatest。
- **比上一版方案收窄了一步**：累加的状态（分组、`shownSearch`、搜索期间建好的镜像）仍然留在会话上，在新一次运行开始时同步清空。旧调用已经不能写入，所以没必要把这些状态搬进 run。这样 diff 小得多，也不会和 PR121.41（合并两个分组类型）冲突。
- **搜索 Task 只持有 run，不持有会话**：引擎调用在等待期间不再把会话留住，补上 PR121.02 的第三层。
- **结束逻辑统一收进 `runDidEnd`**：无论成功、失败还是被取消，当前这次调用结束后都会清掉 `isSearching`，并处理搜索期间建好的镜像。PR121.38（补搜失败后转圈不停）因此一并修掉。
- **换引擎的处理**：订阅 `documentState.$runtimeEngine.skip(1)`，在新引擎上重跑屏上那次已提交的查询，范围保留，与提案「换引擎保留范围」一致。如果你选择改成清空结果，只需把 `engineDidChange()` 里的 `start(committedQuery)` 换成 `start(FindQuery())`。
- **为什么换引擎后要隔一个主线程回合再重跑**：App 里根侧栏的 `.initial` 先建 `FindViewModel`（`SidebarRootCoordinator.swift:29`），所以会话的订阅排在语料协调器之前。如果同步重跑，范围内镜像的置顶请求会发给还没切到新引擎的协调器，随即被它的 `withdrawEveryBuild()` 撤掉。
- **新增 `committedQuery`**：记录屏上结果对应的查询。`run(_:)` 拆成两层：`run` 设置页面在编辑的 `query`；`start` 只负责搜索。这样换引擎时的重跑不会改写用户正在编辑的模式和开关。
- **本条不包含的部分**：把 `isSearching` 并进 `Results`，让「只发布一个状态值」在字面上也成立，这一步不在这个 diff 里。它要机械替换约 20 处测试，而这里 `results` 和 `isSearching` 总在同一个主线程回合里修改，没有闪烁问题。如果你要求字面上也满足这条规则，可以另外单独做。

**拟修改**（基准：`12e1227b` 加上 PR121.02）：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -77,9 +77,11 @@ public final class FindSession {
     public let focusSearchFieldRelay = PublishRelay<Void>()
 
-    private var searchTask: Task<Void, Never>?
+    /// The engine call under way, if any; see `SearchRun`.
+    private var currentRun: SearchRun?
 
-    /// Bumped per search; a finishing search only clears `isSearching` when
-    /// it is still the current one.
-    private var searchGeneration = 0
+    /// The query whose results are on screen: the last one run, whatever the
+    /// mode path and the toggles show now. `nil` before the first search and
+    /// once the field is cleared.
+    private var committedQuery: FindQuery?
 
     private var textMatchGroups = TextMatchGroups()
@@ -121,8 +123,21 @@ public final class FindSession {
                 }
             }
             .disposed(by: disposeBag)
+        documentState.$runtimeEngine
+            .skip(1)
+            // One turn later. The page's view model brings this session into
+            // being before the corpus coordinator exists, so the coordinator
+            // hears of a new engine after this subscriber does; searching at
+            // once would put the scope's images at the front of the old
+            // engine's queue, to be withdrawn straight away.
+            .observe(on: MainScheduler.asyncInstance)
+            .subscribeOnNextMainActor { [weak self] _ in
+                guard let self else { return }
+                self.engineDidChange()
+            }
+            .disposed(by: disposeBag)
     }
 
     deinit {
-        searchTask?.cancel()
+        currentRun?.task?.cancel()
     }
@@ -133,6 +148,4 @@ public final class FindSession {
     public func documentWillClose() {
-        searchTask?.cancel()
-        searchTask = nil
-        searchGeneration += 1
+        cancelCurrentRun()
         disposeBag = DisposeBag()
     }
@@ -177,8 +190,15 @@ public final class FindSession {
     /// Runs `query` (Return in the search field). An empty query clears the
     /// results instead.
     public func run(_ query: FindQuery) {
         self.query = query
-        searchTask?.cancel()
-        searchTask = nil
+        start(query)
+    }
+
+    /// Runs `query` without touching the one the page edits, so a search run
+    /// again on another engine leaves the mode path and the toggles as the
+    /// user left them.
+    private func start(_ query: FindQuery) {
+        cancelCurrentRun()
+        committedQuery = query.isEmpty ? nil : query
         shownSearch = nil
         imagePathsBuiltDuringSearch = []
@@ -221,7 +241,15 @@ public final class FindSession {
     public func clear() {
         var cleared = query
         cleared.text = ""
         run(cleared)
     }
+
+    /// The document moved to another source, or onto the same engine again
+    /// after its service relaunched: nothing on screen belongs to the engine
+    /// now. The search on screen runs again on it, under the same scope.
+    private func engineDidChange() {
+        guard let committedQuery else { return }
+        start(committedQuery)
+    }
 
     // MARK: - Scope
@@ -265,101 +293,176 @@ public final class FindSession {
         var searchedImagePaths: Set<String> = []
         var totalMatchCount = 0
         var isTruncated = false
     }
 
+    /// One engine call: a search, or a widening of the one on screen. What it
+    /// brings back is applied only while it is `currentRun`. Cancelling its
+    /// task does not stop an engine across a connection — the call runs to
+    /// its answer and pushes every batch on the way — so whatever a replaced
+    /// call still delivers is dropped here, instead of landing in the results
+    /// of the search that replaced it.
+    @MainActor
+    private final class SearchRun {
+        let engine: RuntimeEngine
+        var task: Task<Void, Never>?
+
+        init(engine: RuntimeEngine) {
+            self.engine = engine
+        }
+    }
+
+    private enum SearchRequest {
+        case text(RuntimeInterfaceSearchQuery)
+        case members(RuntimeMemberSearchQuery)
+        case relationships(RuntimeTypeRelationshipsQuery)
+    }
+
+    private enum SearchResponse {
+        case text(RuntimeInterfaceSearchSummary)
+        case members(RuntimeInterfaceSearchSummary)
+        case relationships([RuntimeRelationshipTree])
+    }
+
     /// Runs `query` over `imagePaths` — every built image when `nil` — and
     /// folds what it finds into the results. A search that widens one already
     /// shown keeps the results it is merged into when it fails.
     private func startSearch(_ query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions, isWidening: Bool) {
         // Closed while an engine call kept this session alive: there is no
         // document to search for any more.
         guard let engine = documentState?.runtimeEngine else {
             isSearching = false
             return
         }
+        cancelCurrentRun()
+        let run = SearchRun(engine: engine)
+        currentRun = run
         isSearching = true
-        searchGeneration += 1
-        let generation = searchGeneration
-        searchTask = Task { [weak self] in
-            do {
-                try await self?.perform(query, imagePaths: imagePaths, generationOptions: generationOptions, isWidening: isWidening, on: engine)
-            } catch is CancellationError {
-                // Superseded; the newer search owns the results now.
-            } catch {
-                #log(.error, "Find failed: \(error, privacy: .public)")
-                guard let self, self.searchGeneration == generation, !isWidening else { return }
-                self.shownSearch = nil
-                var failed = Results()
-                failed.summary = "Search failed: \(error.localizedDescription)"
-                self.setResults(failed)
-            }
-            guard let self, self.searchGeneration == generation else { return }
-            self.isSearching = false
-            self.searchImagesBuiltDuringSearch()
+        let request = searchRequest(for: query, imagePaths: imagePaths, generationOptions: generationOptions)
+        // The task holds the run, never the session: an engine call over a
+        // connection runs to its answer even when cancelled, and must not
+        // keep a closed document's session alive until then.
+        run.task = Task { [weak self, run] in
+            let outcome: Result<SearchResponse, any Swift.Error>
+            do {
+                switch request {
+                case .text(let engineQuery):
+                    let summary = try await run.engine.searchInterfaces(engineQuery) { [weak self, weak run] batch in
+                        await self?.appendTextMatches(batch, from: run)
+                    }
+                    outcome = .success(.text(summary))
+                case .members(let engineQuery):
+                    let summary = try await run.engine.searchMembers(engineQuery) { [weak self, weak run] batch in
+                        await self?.appendMemberMatches(batch, from: run)
+                    }
+                    outcome = .success(.members(summary))
+                case .relationships(let engineQuery):
+                    outcome = .success(.relationships(try await run.engine.typeRelationships(engineQuery)))
+                }
+            } catch {
+                outcome = .failure(error)
+            }
+            self?.runDidEnd(run, with: outcome, isWidening: isWidening)
         }
     }
 
-    private func perform(_ query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions, isWidening: Bool, on engine: RuntimeEngine) async throws {
+    private func searchRequest(for query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions) -> SearchRequest {
         switch query.mode {
         case .text, .regularExpression:
-            let engineQuery = RuntimeInterfaceSearchQuery(
+            return .text(RuntimeInterfaceSearchQuery(
                 text: query.trimmedText,
                 matchMode: query.mode == .regularExpression ? .regularExpression : query.textMatchStyle.matchMode,
                 isCaseSensitive: query.isCaseSensitive,
                 scope: .all,
                 resultLimit: max(0, Self.resultLimit - textMatchGroups.matchCount),
                 generationOptions: generationOptions,
                 imagePaths: imagePaths
-            )
-            let summary = try await engine.searchInterfaces(engineQuery) { [weak self] batch in
-                await self?.appendTextMatches(batch)
-            }
-            try Task.checkCancellation()
-            finish(with: summary, nodes: textMatchGroups.nodes(), typeCount: textMatchGroups.typeCount, isWidening: isWidening)
+            ))
         case .members:
-            let engineQuery = RuntimeMemberSearchQuery(
+            return .members(RuntimeMemberSearchQuery(
                 text: query.trimmedText,
                 matchMode: query.memberMatchStyle.matchMode,
                 kinds: query.memberKindFilter.kinds,
                 isCaseSensitive: query.isCaseSensitive,
                 resultLimit: max(0, Self.resultLimit - memberMatchGroups.matchCount),
                 generationOptions: generationOptions,
                 imagePaths: imagePaths
-            )
-            let summary = try await engine.searchMembers(engineQuery) { [weak self] batch in
-                await self?.appendMemberMatches(batch)
-            }
-            try Task.checkCancellation()
-            finish(with: summary, nodes: memberMatchGroups.nodes(), typeCount: memberMatchGroups.typeCount, isWidening: isWidening)
+            ))
         case .ancestorTypes, .descendantTypes, .conformingTypes:
-            let relationship = query.mode.relationship ?? .ancestors
-            let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: query.trimmedText, matchMode: query.textMatchStyle.matchMode, relationship: relationship, isCaseSensitive: query.isCaseSensitive, imagePaths: imagePaths))
-            try Task.checkCancellation()
-            var nodes: [FindResultNode] = []
-            var relatedTypeCount = 0
-            for tree in trees {
-                let children = tree.nodes.enumerated().map { index, node in
-                    FindResultNode.relationship(node, path: "tree|\(tree.root.kind)|\(tree.root.name)|\(tree.root.imagePath)#\(index)")
-                }
-                relatedTypeCount += Self.count(children)
-                nodes.append(FindResultNode.object(tree.root, matchCount: children.count, children: children))
-            }
-            var relationshipResults = Results()
-            relationshipResults.nodes = nodes
-            relationshipResults.summary = nodes.isEmpty
-                ? "No matching types"
-                : "\(relatedTypeCount) \(relatedTypeCount == 1 ? "type" : "types") for \(nodes.count) \(nodes.count == 1 ? "match" : "matches")"
-            setResults(relationshipResults)
+            return .relationships(RuntimeTypeRelationshipsQuery(text: query.trimmedText, matchMode: query.textMatchStyle.matchMode, relationship: query.mode.relationship ?? .ancestors, isCaseSensitive: query.isCaseSensitive, imagePaths: imagePaths))
         }
     }
 
-    /// One image's batch, folded into the tree while the search goes on.
-    private func appendTextMatches(_ batch: [RuntimeInterfaceSearchMatch]) {
+    /// An engine call came to its end. One that is no longer `currentRun` was
+    /// replaced — by a newer search, a source switch, the document closing —
+    /// and the results are not its to touch. The current one, whatever its
+    /// outcome, leaves the session idle and reads the corpora built while it
+    /// ran.
+    private func runDidEnd(_ run: SearchRun, with outcome: Result<SearchResponse, any Swift.Error>, isWidening: Bool) {
+        guard run === currentRun else { return }
+        currentRun = nil
+        switch outcome {
+        case .success(.text(let summary)):
+            finish(with: summary, nodes: textMatchGroups.nodes(), typeCount: textMatchGroups.typeCount, isWidening: isWidening)
+        case .success(.members(let summary)):
+            finish(with: summary, nodes: memberMatchGroups.nodes(), typeCount: memberMatchGroups.typeCount, isWidening: isWidening)
+        case .success(.relationships(let trees)):
+            showRelationshipTrees(trees)
+        case .failure(is CancellationError):
+            // Cancelled on the engine's side: there is nothing to show.
+            break
+        case .failure(let error):
+            #log(.error, "Find failed: \(error, privacy: .public)")
+            // A widening search keeps the results it would have merged into;
+            // the images it was sent to read stay unsearched.
+            if !isWidening {
+                shownSearch = nil
+                var failed = Results()
+                failed.summary = "Search failed: \(error.localizedDescription)"
+                setResults(failed)
+            }
+        }
+        isSearching = false
+        searchImagesBuiltDuringSearch()
+    }
+
+    /// Stops listening to the engine call under way. Across a connection the
+    /// engine still runs it to its end; what it sends from here is dropped.
+    private func cancelCurrentRun() {
+        currentRun?.task?.cancel()
+        currentRun = nil
+    }
+
+    /// The trees a relationship search answered with, one per matching type.
+    private func showRelationshipTrees(_ trees: [RuntimeRelationshipTree]) {
+        var nodes: [FindResultNode] = []
+        var relatedTypeCount = 0
+        for tree in trees {
+            let children = tree.nodes.enumerated().map { index, node in
+                FindResultNode.relationship(node, path: "tree|\(tree.root.kind)|\(tree.root.name)|\(tree.root.imagePath)#\(index)")
+            }
+            relatedTypeCount += Self.count(children)
+            nodes.append(FindResultNode.object(tree.root, matchCount: children.count, children: children))
+        }
+        var relationshipResults = Results()
+        relationshipResults.nodes = nodes
+        relationshipResults.summary = nodes.isEmpty
+            ? "No matching types"
+            : "\(relatedTypeCount) \(relatedTypeCount == 1 ? "type" : "types") for \(nodes.count) \(nodes.count == 1 ? "match" : "matches")"
+        setResults(relationshipResults)
+    }
+
+    /// One image's batch, folded into the tree while the search goes on — if
+    /// the call that brought it is still the current one.
+    private func appendTextMatches(_ batch: [RuntimeInterfaceSearchMatch], from run: SearchRun?) {
+        guard let run, run === currentRun else { return }
         textMatchGroups.append(batch)
         setResults(results(from: textMatchGroups.nodes(), matchCount: (shownSearch?.totalMatchCount ?? 0) + textMatchGroups.matchCountSinceLastFinish, typeCount: textMatchGroups.typeCount))
     }
 
-    private func appendMemberMatches(_ batch: [RuntimeMemberMatch]) {
+    private func appendMemberMatches(_ batch: [RuntimeMemberMatch], from run: SearchRun?) {
+        guard let run, run === currentRun else { return }
         memberMatchGroups.append(batch)
         setResults(results(from: memberMatchGroups.nodes(), matchCount: (shownSearch?.totalMatchCount ?? 0) + memberMatchGroups.matchCountSinceLastFinish, typeCount: memberMatchGroups.typeCount))
     }
```

新的测试接缝：
- 这是一对真实的 XPC 引擎：一端是 `RuntimeLocalRuntimeServiceHost` 加匿名 listener，另一端是用 `.xpcService(.anonymousListener(…))` 连上去的 `.local` 引擎。两端都在测试进程里，但走的是 App 里「My Mac」的真实传输：请求取消不掉，进度以推送的形式回来。
- 用到的 API 都是 public 的；测试 target 已经依赖 `RuntimeViewerCommunication`（`RuntimeViewerPackages/Package.swift:518-526`）。
- 这样就不需要假引擎；进程内引擎替代不了这种传输。
```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Support/TestRuntimeEngine.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Support/TestRuntimeEngine.swift
@@ -1,5 +1,6 @@
 import Foundation
 import RuntimeViewerCore
+import RuntimeViewerCommunication
 
 /// Images every macOS test process already has mapped, so loading them is cheap
 /// and `isImageLoaded` is true from the start.
@@ -55,5 +56,41 @@ enum TestRuntimeEngine {
     }
 }
 
+#if os(macOS)
+struct ForwardingPairNotReady: Error, CustomStringConvertible {
+    let engineID: String
+
+    var description: String { "\(engineID) never received the service engine's image list" }
+}
+
+extension TestRuntimeEngine {
+    /// A `.local` engine that forwards every request over XPC to a second
+    /// engine, served the way the app's local-runtime service serves it —
+    /// both ends in this process. A request sent over it runs to its answer
+    /// whatever happens to the task that sent it, and its progress comes back
+    /// as pushes: the "My Mac" transport, which an in-process engine cannot
+    /// stand in for.
+    static func makeForwardingPair(engineID: String, loading imagePaths: [String] = []) async throws -> (host: RuntimeLocalRuntimeServiceHost, engine: RuntimeEngine) {
+        let serviceEngine = RuntimeEngine(source: .local, engineID: "\(engineID).host")
+        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
+        let host = RuntimeLocalRuntimeServiceHost(engine: serviceEngine, connection: listener)
+        try await host.start()
+        host.activate()
+        let engine = RuntimeEngine(source: .local, engineID: engineID)
+        try await engine.connect(credential: .xpcService(.anonymousListener(endpoint)))
+        let hostImageList = await host.engine.imageList
+        let isReady = await pollUntil(timeout: .seconds(30)) {
+            await engine.imageList == hostImageList
+        }
+        guard isReady else { throw ForwardingPairNotReady(engineID: engineID) }
+        for imagePath in imagePaths {
+            try await engine.loadImage(at: imagePath)
+        }
+        return (host, engine)
+    }
+}
+#endif
+
 extension RuntimeEngine {
     func runtimeObject(named name: String, kind: RuntimeObjectKind, in imagePath: String) async throws -> RuntimeObject {
```

**复现测试（示例）**：加在 PR121.02 新建的 `FindSessionLifecycleTests.swift` 里。
- **第一条，用转发对**：两次 `run` 写在同一个同步块里，第一次搜索的 Task 还没开始就已被取消，但链路上没有任何一层检查取消，请求照样发出。修复前，它在 libobjc 里的批次会并进第二次搜索的结果，或者填满已经清空的列表，测试变红。
- **第二条，用两个进程内引擎**：换引擎之前的行在修复前原样留在列表里，测试变红。
```swift
    enum SearchReplacement: CaseIterable, Sendable {
        case newSearch
        case clearedField
    }

    @Test("the batches a replaced search still delivers do not reach the results", arguments: SearchReplacement.allCases)
    func replacedSearchBatchesAreDropped(replacement: SearchReplacement) async throws {
        let (host, engine) = try await TestRuntimeEngine.makeForwardingPair(
            engineID: "FindSessionLifecycleTests.replaced.\(replacement)",
            loading: [TestImages.libobjc]
        )
        defer { Task { await engine.stop(); await host.stop() } }
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        try await withSharedGenerationOptionsLock {
            // One main-actor turn: the first search's task is cancelled before
            // it starts, and nothing between it and the service checks for that.
            session.run(FindQuery(mode: .text, text: "NSZone"))
            switch replacement {
            case .newSearch:
                session.run(FindQuery(mode: .text, text: "zzzNoSuchToken"))
            case .clearedField:
                session.clear()
            }
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

            // The first search runs to its end in the service whatever its task
            // says; give the batches it pushes time to come back.
            let emitted = try await values(from: session.$results.asDriver(), during: 2)
            #expect(emitted.allSatisfy(\.nodes.isEmpty), "a replaced search's hits reached the results")
            #expect(session.results.nodes.isEmpty)
        }
    }

    @Test("a source switch leaves nothing of the old engine on screen and searches the new one")
    func sourceSwitchDropsTheOldEnginesResults() async throws {
        let oldEngine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionLifecycleTests.switch.old", loading: [TestImages.libobjc])
        _ = try await oldEngine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let newEngine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionLifecycleTests.switch.new")
        let environment = ViewModelTestEnvironment(runtimeEngine: oldEngine)
        let session = environment.make { environment.documentState.findSession }

        try await withSharedGenerationOptionsLock {
            session.run(FindQuery(mode: .text, text: "NSObject"))
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

            environment.documentState.selectionRouter.trigger(.switchEngine(newEngine))
            try await settleMainQueue()
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

            #expect(!session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc }, "the old engine's rows stayed on screen")
            // Run again on the new engine, which has no corpus yet.
            #expect(session.results.summary?.hasPrefix("0 results") == true)
        }

        await oldEngine.stop()
        await newEngine.stop()
    }
```

**同类**：
- 会话里另外两个异步入口也走 `currentRun` 判定，不用另改：`follow(_:)` 收到的 `corpusBuilt` 最终调用 `startSearch`；选项变化引起的重跑最终调用 `run`。
- 协调器里的 Task 已经用 `engine ===` 判断，不用改。
- 还剩一个缺口，本条不修：XPC service 重启时，如果文档停在镜像列表根处、又没有选中任何对象，`.switchEngine` 会在 `DocumentState.swift:287` 提前返回，`$runtimeEngine` 不会发值，旧结果就留在屏上。建议由 `DocumentState` 在引擎重新就绪时另发一个「引擎已重置」信号，会话和语料协调器一起订阅，和协调器那组改动一并定。

**工作量**：M。
- 依赖 PR121.02。
- PR121.38 的修复已经包含在本条的 `runDidEnd` 里。
- PR121.39 和 PR121.40 以本条之后的代码为基准。


### PR121.06 搜索在 store actor 上同步扫描，病态正则卡死

- **严重度**：Major
- **审查编号**：C03（含 S3 的 store 一半）
- **状态**：方案待批，代码未改

**问题**：
- 文本搜索和成员搜索都是语料存储 actor 上的方法。它们在 actor 上同步扫完一整个镜像：条目循环里没有挂起点（`RuntimeInterfaceCorpusStore.swift:597-618`、:668-693），取消只在镜像与镜像之间检查一次（:593、:664），正则用 `regex.matches(in:)` 一口气跑完（`RuntimeInterfaceTextMatcher.swift:92`），没有任何上限。
- 用户只要写一个会灾难性回溯的正则，比如 `(\w+)+\(`，碰上一个很长、后面又不跟 `(` 的标识符，就要试约 2ⁿ 种拆法，实际上永远跑不完，并一直占着这个引擎上所有文档共用的 actor。所有语料构建、Report navigator 的覆盖查询、各个窗口之后的每次搜索都排在它后面，再按回车也停不下来，只能重启 App 和 service。
- 正常的大搜索也会把 actor 占满一整个镜像的扫描时间。
- 同一个 `Pattern` 还用于成员名，以及关系解析器（它也是一个 actor）的类型名匹配，两处同样会被卡死。

**四问**：复现——Find › Text › Regular Expression 输入 `(\w+)+\(`，在 SwiftUI 或 Foundation 的语料上搜，界面一直转圈，Report navigator 停止更新；基线——本 PR 新引入（8b4309b2），提案 §3.1 写的是「逐条目取消」，实现只做到逐镜像；影响——病态正则的后果很严重（整个引擎上的 Find 和语料构建都瘫痪），普通情况影响较小，建议修；历史——新代码。

**改法**：
- **扫描移出 actor。** actor 上只做两件事：一是取快照，即要搜的镜像路径加上各自的 `entries` 数组，数组是写时复制（copy-on-write）的值类型，取快照只多一次引用计数；二是更新 `lastSearchedAt`。然后调用一个静态扫描函数，它不受 actor 隔离，在全局执行器上跑；扫完再回到 actor 计算「未建好的镜像」。
  - 这个函数标 `@concurrent`。若 Swift 5 语言模式下编译器不接受，就去掉这个标注：Core 没开 `NonisolatedNonsendingByDefault`，不标也一样在 actor 外运行，现有的 `assemble` 就是这样。
  - 扫描期间被驱逐的语料由快照保留到扫描结束，内存会在这段时间内超出预算。
- **逐条目检查取消。** 每个条目开始前检查一次；每个镜像的结果批次发出前再检查一次，已取消的搜索不再交付结果；每扫完一个镜像让出一次，不长时间占住协作线程池里的线程。
- **正则预算。** 正则改用 `enumerateMatches(in:options: [.reportProgress], range:)`。
  - 带这个选项时，引擎在**单次**匹配的回溯过程中也会周期性地回调块。依据有三条：swift-corelibs-foundation 在 `CFRegularExpression.c:317` 给 ICU 装上 match callback；ICU 每 10,000 次状态保存调用一次这个回调（`rematch.cpp:59`、:2711-2722、:2775-2778），回调返回 false 时引擎以 `U_REGEX_STOPPED_BY_CALLER` 停下；Apple 文档对 Darwin 版也做了同样的承诺。
  - 块里每次检查 `Task.isCancelled`，每 256 次回调读一次时钟，超出预算就设 `stop`。时钟用 `DispatchTime`，因为部署目标是 macOS 10.15，`ContinuousClock` 要 macOS 13。
  - 预算是**一次搜索在正则引擎里累计花的时间**，默认 10 s，由每次搜索新建的 `RegularExpressionBudget` 记账往下传，`Pattern` 保持 `Sendable` 不变。
- **超出预算之后**：停止扫描，已交付的结果保留（它们都是对的）；摘要新增 `stopReason: .regularExpressionTooExpensive`，界面提示结果不完整（显示部分属于 PR121.05 / 模块 D1）。摘要是本 PR 新加的类型，现在加字段没有兼容负担。关系搜索没有「部分结果」的概念，超出预算时抛出可读的错误。
- **S3 的 store 一半**：文本搜索和成员搜索共用这个扫描驱动（镜像循环、计数、批次、摘要），各自只提供「对一个条目做什么」的闭包，原来两份约 35 行的重复一起消掉。
- **diff 中省略的部分**：
  - `RuntimeInterfaceTextMatcherTests` 和 `RuntimeInterfaceCorpusStoreTests` 里现有调用的签名跟着改（加 `try` 与预算参数）。单次调用可以用新增的不带预算的 `hits(in:pattern:)` 重载。这部分改动是机械的，未列出。
  - 开销实测（见测试 4）若超标，「只对含被量词修饰的分组的模式开 `.reportProgress`」这一退路也未写进 diff。

**拟修改**（关键部分）：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
@@ -76,25 +76,96 @@ enum RuntimeInterfaceTextMatcher {
     // MARK: - Hits
 
+    /// How long one search may spend inside the regular expression engine,
+    /// summed over every call it makes. A pattern that backtracks
+    /// catastrophically — `(\w+)+\(` over a long identifier — never finishes
+    /// a single match on its own; this is what stops it.
+    struct RegularExpressionBudget {
+        static let defaultTimeLimit: TimeInterval = 10
+
+        private(set) var remainingNanoseconds: UInt64
+
+        init(timeLimit: TimeInterval = Self.defaultTimeLimit) {
+            remainingNanoseconds = UInt64(max(0, timeLimit) * 1_000_000_000)
+        }
+
+        var isExhausted: Bool {
+            remainingNanoseconds == 0
+        }
+
+        mutating func spend(_ nanoseconds: UInt64) {
+            remainingNanoseconds -= min(nanoseconds, remainingNanoseconds)
+        }
+    }
+
+    /// Thrown once a search's `RegularExpressionBudget` is spent.
+    struct RegularExpressionTooExpensive: LocalizedError, CustomStringConvertible {
+        var errorDescription: String? {
+            "The regular expression backtracks too much to finish. Nested repetition such as (\\w+)+ is the usual cause."
+        }
+
+        /// The socket transports send `"\(error)"` across.
+        var description: String {
+            errorDescription ?? "The regular expression is too expensive."
+        }
+    }
+
+    /// How many progress reports pass between two readings of the clock.
+    private static let clockReadingInterval = 256
+
     /// Every hit of `pattern` in `text`, non-overlapping, in offset order.
     /// Word boundaries use the identifier character class `[A-Za-z0-9_$]`;
     /// any non-ASCII byte counts as an identifier character, so a boundary
     /// never falls inside a multi-byte scalar.
-    static func hits(in text: String, pattern: Pattern) -> [Hit] {
+    static func hits(in text: String, pattern: Pattern, budget: inout RegularExpressionBudget) throws -> [Hit] {
         if let regex = pattern.regex {
-            return regexHits(in: text, regex: regex)
+            return try regexHits(in: text, regex: regex, budget: &budget)
         }
         return literalHits(in: text, pattern: pattern)
     }
 
-    private static func regexHits(in text: String, regex: NSRegularExpression) -> [Hit] {
+    /// `hits(in:pattern:budget:)` for a single call that owns a whole budget.
+    static func hits(in text: String, pattern: Pattern) throws -> [Hit] {
+        var budget = RegularExpressionBudget()
+        return try hits(in: text, pattern: pattern, budget: &budget)
+    }
+
+    private static func regexHits(in text: String, regex: NSRegularExpression, budget: inout RegularExpressionBudget) throws -> [Hit] {
+        guard !budget.isExhausted else { throw RegularExpressionTooExpensive() }
         var result: [Hit] = []
         let wholeRange = NSRange(location: 0, length: text.utf16.count)
-        for match in regex.matches(in: text, options: [], range: wholeRange) {
-            guard match.range.length > 0, let range = Range(match.range, in: text) else { continue }
-            let offset = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
-            let length = text.utf8.distance(from: range.lowerBound, to: range.upperBound)
-            guard length > 0 else { continue }
-            result.append(Hit(utf8Offset: offset, utf8Length: length))
+        let startTime = DispatchTime.now().uptimeNanoseconds
+        let deadline = startTime + budget.remainingNanoseconds
+        var progressReportCount = 0
+        var isCancelled = false
+        var isOverBudget = false
+        // `.reportProgress` has the engine call back during one long match as
+        // well — every 10,000 backtracking steps in ICU — so `stop` ends a
+        // match that would otherwise never finish.
+        regex.enumerateMatches(in: text, options: [.reportProgress], range: wholeRange) { match, _, stop in
+            if let match, match.range.length > 0, let range = Range(match.range, in: text) {
+                let offset = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
+                let length = text.utf8.distance(from: range.lowerBound, to: range.upperBound)
+                if length > 0 {
+                    result.append(Hit(utf8Offset: offset, utf8Length: length))
+                }
+            }
+            if Task.isCancelled {
+                isCancelled = true
+                stop.pointee = true
+                return
+            }
+            progressReportCount += 1
+            if progressReportCount % Self.clockReadingInterval == 0, DispatchTime.now().uptimeNanoseconds >= deadline {
+                isOverBudget = true
+                stop.pointee = true
+            }
         }
+        budget.spend(DispatchTime.now().uptimeNanoseconds - startTime)
+        if isCancelled {
+            throw CancellationError()
+        }
+        if isOverBudget || budget.isExhausted {
+            throw RegularExpressionTooExpensive()
+        }
         return result
     }
@@ -174,9 +245,10 @@ enum RuntimeInterfaceTextMatcher {
     static func matches(
         in interface: FrozenSemanticString,
         object: RuntimeObject,
         pattern: Pattern,
+        budget: inout RegularExpressionBudget,
         excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>] = [],
         collect: (RuntimeInterfaceSearchMatch) -> Bool
-    ) -> Int {
-        let hits = hits(in: interface.text, pattern: pattern)
+    ) throws -> Int {
+        let hits = try hits(in: interface.text, pattern: pattern, budget: &budget)
         guard !hits.isEmpty else { return 0 }
@@ -349,2 +421,2 @@ enum RuntimeInterfaceTextMatcher {
-    static func memberNameMatchRange(in name: String, pattern: Pattern) -> RuntimeTextRange? {
-        guard let hit = hits(in: name, pattern: pattern).first else { return nil }
+    static func memberNameMatchRange(in name: String, pattern: Pattern, budget: inout RegularExpressionBudget) throws -> RuntimeTextRange? {
+        guard let hit = try hits(in: name, pattern: pattern, budget: &budget).first else { return nil }
@@ -376,5 +448,5 @@ enum RuntimeInterfaceTextMatcher {
-    static func typeNameMatches(_ qualifiedName: String, pattern: Pattern) -> Bool {
+    static func typeNameMatches(_ qualifiedName: String, pattern: Pattern, budget: inout RegularExpressionBudget) throws -> Bool {
         let matchesQualifiedName = pattern.regex != nil || pattern.needle.contains(UInt8(ascii: "."))
         let name = matchesQualifiedName ? qualifiedName : String(ownTypeName(of: qualifiedName))
-        return !hits(in: name, pattern: pattern).isEmpty
+        return try !hits(in: name, pattern: pattern, budget: &budget).isEmpty
     }
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeInterfaceSearch.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeInterfaceSearch.swift
@@ -156,14 +156,25 @@ public struct RuntimeInterfaceSearchSummary: Hashable, Codable, Sendable {
     public let unbuiltIndexedImagePaths: [String]
+    /// Set when the search stopped before reading everything it covers;
+    /// what it delivered until then is correct. `nil` for a full scan.
+    public let stopReason: RuntimeInterfaceSearchStopReason?
 
     public var scannedImageCount: Int {
         scannedImagePaths.count
     }
 
-    public init(totalMatchCount: Int, scannedImagePaths: [String], scannedObjectCount: Int, isTruncated: Bool, unbuiltIndexedImagePaths: [String]) {
+    public init(totalMatchCount: Int, scannedImagePaths: [String], scannedObjectCount: Int, isTruncated: Bool, unbuiltIndexedImagePaths: [String], stopReason: RuntimeInterfaceSearchStopReason? = nil) {
         self.totalMatchCount = totalMatchCount
         self.scannedImagePaths = scannedImagePaths
         self.scannedObjectCount = scannedObjectCount
         self.isTruncated = isTruncated
         self.unbuiltIndexedImagePaths = unbuiltIndexedImagePaths
+        self.stopReason = stopReason
     }
 }
+
+/// Why a search stopped before reading every corpus it covers.
+public enum RuntimeInterfaceSearchStopReason: String, Codable, Hashable, Sendable {
+    /// The regular expression used up the search's time budget backtracking:
+    /// `(\w+)+\(` over a long identifier never finishes on its own.
+    case regularExpressionTooExpensive
+}
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -261,11 +261,16 @@ actor RuntimeInterfaceCorpusStore {
     private var nextSubscriberIdentifier: UInt64 = 0
 
+    /// How long one search may spend in the regular expression engine.
+    private let regularExpressionTimeLimit: TimeInterval
+
     init(
         builder: any RuntimeInterfaceCorpusBuilding,
         residentByteLimit: Int = RuntimeInterfaceCorpusStore.defaultResidentByteLimit,
-        printingWidth: Int = RuntimeInterfaceCorpusStore.defaultPrintingWidth
+        printingWidth: Int = RuntimeInterfaceCorpusStore.defaultPrintingWidth,
+        regularExpressionTimeLimit: TimeInterval = RuntimeInterfaceTextMatcher.RegularExpressionBudget.defaultTimeLimit
     ) {
         self.builder = builder
         self.residentByteLimit = residentByteLimit
         self.printingWidth = max(1, printingWidth)
+        self.regularExpressionTimeLimit = regularExpressionTimeLimit
     }
@@ -577,55 +582,120 @@ actor RuntimeInterfaceCorpusStore {
-    /// Runs `query` over every built corpus, pushing matches to `onProgress`
-    /// one image at a time, and returns the summary. Matches are collected up
-    /// to `query.resultLimit`; the count goes on past it.
+    /// One corpus as a search reads it, taken on this actor so the scan can
+    /// run off it. Entries are values: a corpus evicted meanwhile stays
+    /// readable until the scan is done with it.
+    private struct SearchedCorpus: Sendable {
+        let imagePath: String
+        let entries: [RuntimeInterfaceCorpusEntry]
+    }
+
+    /// What the scan of one search came to.
+    private struct SearchScan: Sendable {
+        var totalMatchCount = 0
+        var collectedCount = 0
+        var scannedObjectCount = 0
+        var scannedImagePaths: [String] = []
+        var stopReason: RuntimeInterfaceSearchStopReason?
+    }
+
+    /// Runs `query` over every built corpus, pushing matches to `onProgress`
+    /// one image at a time, and returns the summary. Matches are collected up
+    /// to `query.resultLimit`; the count goes on past it. The scan runs off
+    /// this actor: whatever the pattern costs, the store keeps answering.
     func searchInterfaces(
         _ query: RuntimeInterfaceSearchQuery,
         indexedImagePaths: Set<String>,
         onProgress: @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
     ) async throws -> RuntimeInterfaceSearchSummary {
         let pattern = try RuntimeInterfaceTextMatcher.Pattern(query)
         let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
-        var totalMatchCount = 0
-        var collectedCount = 0
-        var scannedObjectCount = 0
-        var scannedImagePaths: [String] = []
-        let now = Date()
-        for imagePath in searchedImagePaths(within: query.imagePaths) {
-            try Task.checkCancellation()
-            guard let corpus = corpora[imagePath] else { continue }
-            scannedImagePaths.append(imagePath)
-            var batch: [RuntimeInterfaceSearchMatch] = []
-            for entry in corpus.entries {
-                scannedObjectCount += 1
-                // The text the content pane shows under the query's options,
-                // so every hit is visible and its line reads as displayed.
-                // Its nested types' blocks are skipped: they are entries of
-                // their own, which report those hits.
-                let interface: FrozenSemanticString
-                let nestedDefinitionRanges: [Range<Int>]
-                if let projection = visibility.flatMap({ entry.projection(under: $0) }) {
-                    interface = projection.text
-                    nestedDefinitionRanges = entry.nestedDefinitionRanges.isEmpty ? [] : entry.nestedDefinitionRanges(in: projection)
-                } else {
-                    interface = entry.interface
-                    nestedDefinitionRanges = entry.nestedDefinitionRanges
-                }
-                totalMatchCount += RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, excludingUTF8Ranges: nestedDefinitionRanges) { match in
-                    guard collectedCount < query.resultLimit else { return false }
-                    batch.append(match)
-                    collectedCount += 1
-                    return true
-                }
-            }
-            corpora[imagePath]?.lastSearchedAt = now
-            if !batch.isEmpty {
-                await onProgress(batch)
-            }
-        }
-        return RuntimeInterfaceSearchSummary(
-            totalMatchCount: totalMatchCount,
-            scannedImagePaths: scannedImagePaths,
-            scannedObjectCount: scannedObjectCount,
-            isTruncated: totalMatchCount > collectedCount,
-            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: query.imagePaths)
-        )
+        let scan = try await Self.scan(
+            corporaToSearch(within: query.imagePaths),
+            resultLimit: query.resultLimit,
+            regularExpressionTimeLimit: regularExpressionTimeLimit,
+            onProgress: onProgress
+        ) { entry, budget, collect in
+            // The text the content pane shows under the query's options,
+            // so every hit is visible and its line reads as displayed.
+            // Its nested types' blocks are skipped: they are entries of
+            // their own, which report those hits.
+            let interface: FrozenSemanticString
+            let nestedDefinitionRanges: [Range<Int>]
+            if let projection = visibility.flatMap({ entry.projection(under: $0) }) {
+                interface = projection.text
+                nestedDefinitionRanges = entry.nestedDefinitionRanges.isEmpty ? [] : entry.nestedDefinitionRanges(in: projection)
+            } else {
+                interface = entry.interface
+                nestedDefinitionRanges = entry.nestedDefinitionRanges
+            }
+            return try RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, budget: &budget, excludingUTF8Ranges: nestedDefinitionRanges, collect: collect)
+        }
+        return summary(of: scan, indexedImagePaths: indexedImagePaths, within: query.imagePaths)
+    }
+
+    /// The built corpora of `scope`, marked searched now.
+    private func corporaToSearch(within scope: Set<String>?) -> [SearchedCorpus] {
+        let now = Date()
+        return searchedImagePaths(within: scope).compactMap { imagePath in
+            guard let corpus = corpora[imagePath] else { return nil }
+            corpora[imagePath]?.lastSearchedAt = now
+            return SearchedCorpus(imagePath: imagePath, entries: corpus.entries)
+        }
+    }
+
+    /// Reads `corpora` entry by entry, off this actor. Checks for
+    /// cancellation before every entry and before each image's batch goes
+    /// out. `matchEntry` hands each match of an entry to its third argument,
+    /// which answers `false` once the limit is reached, and returns how many
+    /// matches it counted. A regular expression that spends the budget ends
+    /// the scan; what was delivered stands.
+    @concurrent
+    private static func scan<Match: Sendable>(
+        _ corpora: [SearchedCorpus],
+        resultLimit: Int,
+        regularExpressionTimeLimit: TimeInterval,
+        onProgress: @Sendable ([Match]) async -> Void,
+        matchEntry: @Sendable (RuntimeInterfaceCorpusEntry, inout RuntimeInterfaceTextMatcher.RegularExpressionBudget, (Match) -> Bool) throws -> Int
+    ) async throws -> SearchScan {
+        var scan = SearchScan()
+        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: regularExpressionTimeLimit)
+        for corpus in corpora {
+            scan.scannedImagePaths.append(corpus.imagePath)
+            var batch: [Match] = []
+            var collectedCount = scan.collectedCount
+            do {
+                for entry in corpus.entries {
+                    try Task.checkCancellation()
+                    scan.scannedObjectCount += 1
+                    let entryMatchCount = try matchEntry(entry, &budget) { match in
+                        guard collectedCount < resultLimit else { return false }
+                        batch.append(match)
+                        collectedCount += 1
+                        return true
+                    }
+                    scan.totalMatchCount += entryMatchCount
+                }
+            } catch is RuntimeInterfaceTextMatcher.RegularExpressionTooExpensive {
+                scan.stopReason = .regularExpressionTooExpensive
+            }
+            scan.collectedCount = collectedCount
+            try Task.checkCancellation()
+            if !batch.isEmpty {
+                await onProgress(batch)
+            }
+            if scan.stopReason != nil {
+                break
+            }
+            await Task.yield()
+        }
+        return scan
+    }
+
+    private func summary(of scan: SearchScan, indexedImagePaths: Set<String>, within scope: Set<String>?) -> RuntimeInterfaceSearchSummary {
+        RuntimeInterfaceSearchSummary(
+            totalMatchCount: scan.totalMatchCount,
+            scannedImagePaths: scan.scannedImagePaths,
+            scannedObjectCount: scan.scannedObjectCount,
+            isTruncated: scan.totalMatchCount > scan.collectedCount,
+            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: scope),
+            stopReason: scan.stopReason
+        )
     }
@@ -651,56 +721,39 @@ actor RuntimeInterfaceCorpusStore {
     func searchMembers(
         _ query: RuntimeMemberSearchQuery,
         indexedImagePaths: Set<String>,
         onProgress: @Sendable ([RuntimeMemberMatch]) async -> Void
     ) async throws -> RuntimeInterfaceSearchSummary {
         let pattern = query.text.isEmpty ? nil : try RuntimeInterfaceTextMatcher.Pattern(text: query.text, matchMode: query.matchMode, isCaseSensitive: query.isCaseSensitive)
         let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
-        var totalMatchCount = 0
-        var collectedCount = 0
-        var scannedObjectCount = 0
-        var scannedImagePaths: [String] = []
-        let now = Date()
-        for imagePath in searchedImagePaths(within: query.imagePaths) {
-            try Task.checkCancellation()
-            guard let corpus = corpora[imagePath] else { continue }
-            scannedImagePaths.append(imagePath)
-            var batch: [RuntimeMemberMatch] = []
-            for entry in corpus.entries {
-                scannedObjectCount += 1
-                guard let pattern else { continue }
-                // Projected only once a member of this entry matches: most
-                // entries have none, and they cost nothing.
-                var projection: (projection: VisibilityProjection, lineStartOffsets: [Int])??
-                for (memberIndex, member) in entry.members.enumerated() {
-                    if let kinds = query.kinds, !kinds.contains(member.kind) { continue }
-                    guard let range = RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern) else { continue }
-                    var shownMember = member
-                    if let visibility {
-                        if projection == nil {
-                            projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceCorpusEntry.lineStartOffsets(of: $0.text.text)) }
-                        }
-                        if let entryProjection = projection ?? nil {
-                            // Hidden under the query's options: not a match.
-                            guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineStartOffsets: entryProjection.lineStartOffsets) else { continue }
-                            shownMember = projectedMember
-                        }
-                    }
-                    totalMatchCount += 1
-                    guard collectedCount < query.resultLimit else { continue }
-                    batch.append(RuntimeMemberMatch(object: entry.object, member: shownMember, matchRangeInName: range))
-                    collectedCount += 1
-                }
-            }
-            corpora[imagePath]?.lastSearchedAt = now
-            if !batch.isEmpty {
-                await onProgress(batch)
-            }
-        }
-        return RuntimeInterfaceSearchSummary(
-            totalMatchCount: totalMatchCount,
-            scannedImagePaths: scannedImagePaths,
-            scannedObjectCount: scannedObjectCount,
-            isTruncated: totalMatchCount > collectedCount,
-            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: query.imagePaths)
-        )
+        let scan = try await Self.scan(
+            corporaToSearch(within: query.imagePaths),
+            resultLimit: query.resultLimit,
+            regularExpressionTimeLimit: regularExpressionTimeLimit,
+            onProgress: onProgress
+        ) { entry, budget, collect in
+            guard let pattern else { return 0 }
+            var matchCount = 0
+            // Projected only once a member of this entry matches: most
+            // entries have none, and they cost nothing.
+            var projection: (projection: VisibilityProjection, lineStartOffsets: [Int])??
+            for (memberIndex, member) in entry.members.enumerated() {
+                if let kinds = query.kinds, !kinds.contains(member.kind) { continue }
+                guard let range = try RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern, budget: &budget) else { continue }
+                var shownMember = member
+                if let visibility {
+                    if projection == nil {
+                        projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceCorpusEntry.lineStartOffsets(of: $0.text.text)) }
+                    }
+                    if let entryProjection = projection ?? nil {
+                        // Hidden under the query's options: not a match.
+                        guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineStartOffsets: entryProjection.lineStartOffsets) else { continue }
+                        shownMember = projectedMember
+                    }
+                }
+                matchCount += 1
+                _ = collect(RuntimeMemberMatch(object: entry.object, member: shownMember, matchRangeInName: range))
+            }
+            return matchCount
+        }
+        return summary(of: scan, indexedImagePaths: indexedImagePaths, within: query.imagePaths)
     }
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -108,6 +108,9 @@ actor RuntimeTypeRelationshipsResolver {
         var exactMatches: OrderedSet<RuntimeObject> = []
         var partialMatches: OrderedSet<RuntimeObject> = []
-        func consider(_ object: RuntimeObject) {
+        // One budget for the whole candidate scan: a regular expression that
+        // spends it ends the query with a readable error.
+        var regularExpressionBudget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
+        func consider(_ object: RuntimeObject) throws {
             guard Self.isRelationshipCandidate(object),
-                  RuntimeInterfaceTextMatcher.typeNameMatches(object.displayName, pattern: pattern)
+                  try RuntimeInterfaceTextMatcher.typeNameMatches(object.displayName, pattern: pattern, budget: &regularExpressionBudget)
             else { return }
@@ -121,19 +124,23 @@ actor RuntimeTypeRelationshipsResolver {
-        func considerTree(_ object: RuntimeObject) {
-            consider(object)
+        func considerTree(_ object: RuntimeObject) throws {
+            try consider(object)
             for child in object.children {
-                considerTree(child)
+                try considerTree(child)
             }
         }
 
         for imagePath in await objcSectionFactory.cachedImagePaths.sorted() {
             guard let section = await objcSectionFactory.existingSection(for: imagePath),
                   let objects = try? await section.allObjects()
             else { continue }
-            objects.forEach(considerTree)
+            for object in objects {
+                try considerTree(object)
+            }
         }
         for imagePath in await swiftSectionFactory.cachedImagePaths.sorted() {
             guard let section = await swiftSectionFactory.existingSection(for: imagePath),
                   let objects = try? await section.allObjects()
             else { continue }
-            objects.forEach(considerTree)
+            for object in objects {
+                try considerTree(object)
+            }
         }
```
```diff
--- a/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift
+++ b/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift
@@ -18,2 +18,4 @@ struct RuntimeInterfaceCorpusStoreTests {
         var delayNanosecondsByObjectName: [String: UInt64] = [:]
+        /// Replaces the scripted interface of the objects it names.
+        var interfaceTextByObjectName: [String: String] = [:]
         private(set) var printedObjectNames: [String] = []
@@ -60,2 +62,5 @@ struct RuntimeInterfaceCorpusStoreTests {
             lock.withLock { printedObjectNames.append(object.name) }
+            if let interfaceText = interfaceTextByObjectName[object.name] {
+                return RuntimeInterfaceCorpusPrint(object: object, interface: SemanticString { Standard(interfaceText) }.frozen(), visibilityRegions: .empty, members: [], nestedDefinitionRanges: [])
+            }
             let interface = SemanticString {
@@ -97,6 +102,10 @@ struct RuntimeInterfaceCorpusStoreTests {
-    private func makeStore(printingWidth: Int = 1, _ configure: (ScriptedBuilder) -> Void = { _ in }) -> Fixture {
+    private func makeStore(
+        printingWidth: Int = 1,
+        regularExpressionTimeLimit: TimeInterval = RuntimeInterfaceTextMatcher.RegularExpressionBudget.defaultTimeLimit,
+        _ configure: (ScriptedBuilder) -> Void = { _ in }
+    ) -> Fixture {
         let builder = ScriptedBuilder()
         builder.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
         configure(builder)
-        return Fixture(store: RuntimeInterfaceCorpusStore(builder: builder, printingWidth: printingWidth), builder: builder)
+        return Fixture(store: RuntimeInterfaceCorpusStore(builder: builder, printingWidth: printingWidth, regularExpressionTimeLimit: regularExpressionTimeLimit), builder: builder)
     }
```
```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -202,2 +202,5 @@
   （`text` 是现成 `String`，逐条目取消）。
+- 搜索不占用语料存储：store 只在自己的 actor 上取快照，扫描在 actor 外进行，每个条目前检查取消。正则带
+  `.reportProgress` 运行，在回调里检查取消，并受每次搜索 10 s 的正则累计时间预算约束；用完即停，已交付的结果保留，
+  摘要的 `stopReason` 说明原因。
 - 搜索域 → `SemanticType` 映射（闭合定义，单测按此断言）：
@@ -756,1 +759,2 @@
 | 2026-10-04 | 一个都没选时 OK 置灰；表单列表覆写 `mouseDown(with:)`；菜单项不带图标 | Xcode 的 OK 此时能点却不改范围，置灰更直观。不覆写时 macOS 27 的列表点击不给焦点，选中的行一直是灰色，与 `StatefulOutlineView` 同一取舍。我们没有与 Xcode 那几个范围对应的图标。 |
+| <落地日期> | 搜索的扫描移出 store actor，逐条目检查取消；正则带 10 s 累计时间预算，超出即停并在摘要里说明（不报错、保留已交付的结果） | 原实现在 actor 上同步扫完一个镜像，`(\w+)+\(` 这类灾难性回溯会永久占住整个引擎的语料存储。`.reportProgress` 的回调在单次匹配内部也会到来（ICU 每 10,000 次回溯点一次），`stop` 能中止它（corelibs `CFRegularExpression.c` 与 ICU `rematch.cpp` 源码，加 Apple 文档）。 |
```

**复现测试（示例）**：用例 1、2 放在 `RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift`，只用现有的 API，修复前在运行时就是红的。
- 用例 1：修复前，`coverage` 要排在整个扫描后面，它返回时搜索早已结束。
- 用例 2：修复前，单个镜像的扫描不检查取消，搜索会正常返回。

用例 3、4 用到新的预算参数和 `stopReason`。做法是先把这两样以「不生效」的形式加进去（参数被忽略、字段恒为 `nil`），确认测试是红的，再实现。`a` 的个数要调到修复前约 2–3 s 跑完：用例 1、2 需要扫描足够慢，又不能慢到修复前的测试挂起太久。
```swift
/// Long enough that `(a+)+\(` takes seconds to give up on it: every way of
/// splitting the run is tried before the missing `(` is accepted.
private static let slowEntryText = "var " + String(repeating: "a", count: 26) + ": Int"

private static let slowRegularExpressionQuery = RuntimeInterfaceSearchQuery(text: #"(a+)+\("#, matchMode: .regularExpression, isCaseSensitive: true)

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

@Test("the store answers other calls while a search scans")
func storeAnswersWhileSearching() async throws {
    let fixture = makeStore { builder in
        builder.objectNamesByImagePath[Self.imageC] = ["Slow"]
        builder.interfaceTextByObjectName["Slow"] = Self.slowEntryText
    }
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    _ = try await store.build(imagePath: Self.imageC, transformer: .default)
    let searchFinished = Flag()
    let search = Task {
        defer { searchFinished.set() }
        return try await store.searchInterfaces(Self.slowRegularExpressionQuery, indexedImagePaths: []) { _ in }
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    _ = await store.coverage(indexedImagePaths: [])

    #expect(!searchFinished.isSet, "coverage waited for the whole scan")
    search.cancel()
    _ = try? await search.value
}

@Test("a search stops inside an image once it is cancelled")
func searchStopsInsideAnImage() async throws {
    let fixture = makeStore { builder in
        builder.objectNamesByImagePath[Self.imageC] = ["Slow"]
        builder.interfaceTextByObjectName["Slow"] = Self.slowEntryText
    }
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    _ = try await store.build(imagePath: Self.imageC, transformer: .default)
    let search = Task {
        try await store.searchInterfaces(Self.slowRegularExpressionQuery, indexedImagePaths: []) { _ in }
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    search.cancel()

    await #expect(throws: CancellationError.self) { try await search.value }
}

@Test("a search whose regular expression spends its budget keeps what it found and says why it stopped")
func searchReportsWhyItStopped() async throws {
    let fixture = makeStore(regularExpressionTimeLimit: 0.05) { builder in
        builder.objectNamesByImagePath[Self.imageC] = ["Slow"]
        builder.interfaceTextByObjectName["Slow"] = Self.slowEntryText
    }
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    _ = try await store.build(imagePath: Self.imageA, transformer: .default)
    _ = try await store.build(imagePath: Self.imageC, transformer: .default)
    // A's `memberAlpha` matches at once; C's run of a's never settles.
    let query = RuntimeInterfaceSearchQuery(text: #"memberAlpha|(a+)+\("#, matchMode: .regularExpression, isCaseSensitive: true)
    var matches: [RuntimeInterfaceSearchMatch] = []

    let summary = try await store.searchInterfaces(query, indexedImagePaths: []) { batch in
        matches += batch
    }

    #expect(matches.map(\.object.name) == ["Alpha"])
    #expect(summary.stopReason == .regularExpressionTooExpensive)
}
```
用例 3 放在 `RuntimeViewerCoreTests/RuntimeInterfaceTextMatcherTests.swift`，直接验证预算在单次匹配内部生效，文本和成员名各一例：
```swift
@Test("a regular expression that spends its budget stops inside a single match")
func regularExpressionBudgetStopsOneMatch() throws {
    let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: #"(a+)+\("#, matchMode: .regularExpression, isCaseSensitive: true)
    let run = String(repeating: "a", count: 24)

    var textBudget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: 0.02)
    #expect(throws: RuntimeInterfaceTextMatcher.RegularExpressionTooExpensive.self) {
        try RuntimeInterfaceTextMatcher.hits(in: "var \(run): Int", pattern: pattern, budget: &textBudget)
    }
    var nameBudget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: 0.02)
    #expect(throws: RuntimeInterfaceTextMatcher.RegularExpressionTooExpensive.self) {
        try RuntimeInterfaceTextMatcher.memberNameMatchRange(in: run, pattern: pattern, budget: &nameBudget)
    }
}
```
**开销实测**（实现时手工做一次，不进测试套件）：开着 `.reportProgress` 时，正常扫描每前进一个字符也会回调一次块，因为 CF 同时装了 find-progress 回调（`CFRegularExpression.c:318`），ICU 在每次前进时调用它（`rematch.cpp:596`）。在 Foundation 加 SwiftUI 的语料上跑几个常见正则，比较开、关 `.reportProgress` 的耗时。开销超过约 20% 时，改为只对含「被量词修饰的分组」的模式开启：没有嵌套量词就不会指数回溯。这个取舍记进提案。

**同类**：
- 成员名匹配和关系解析器的类型名匹配共用同一个 `regexHits`，预算在一处生效。关系解析器的调用点已在 diff 里，与 PR121.67（关系遍历不检查取消，模块 F）改的是同一段，合并时一起看。
- CLI 的 `searchTypes` 用 Swift `Regex` 只匹配类型名，在客户端进程里运行，不会卡住任何 actor，不在本条范围。
- 跨连接取消（XPC、socket 把取消传到服务端处理请求的那个 Task）归 PR121.29。没有它，App 里的 My Mac 引擎仍收不到取消；但扫描已经不占 actor，病态正则也会被预算停下。

**工作量**：L；先于 PR121.21、PR121.23、PR121.24 做，它们都在本条的新结构上改。与 PR121.08 都给 store 的 init 加参数，合并时把两个参数都留下。提案里新加的这一条接在 §3.1 第一条之后；若 PR121.15 先落，那条的最后一行已改写，上下文跟着变。


### PR121.07 Find 结果每批整树重载：折叠、选中丢失，误导航

- **严重度**：Major
- **审查编号**：C38（含 C44、S5）
- **状态**：方案待批，代码未改

**问题**：Find 结果大纲用 `rx.nodes(options: [])` 绑定，而 `FindSession` 每来一批（以及每次补搜、过滤栏每敲一个键）都给所有行新建 `FindResultNode`。这些节点是按指针判等的 `NSObject`，AppKit 在 `reloadData()` 之后认不出旧行：用户折叠的类型被重新展开（`FindViewController.swift:387-391` 每次都 `expandItem(nil, expandChildren: true)`），选中只按行号保留，落到别的行上。导航挂在 `rx.modelSelected()`（`selectionDidChangeNotification`）上，所以 reload、程序化选中、⌘A 引起的选中变化也会导航，`pushOntoTimeline` 还会截掉「前进」历史。另外，提案承诺的「⌥-点击在新标签打开」没有实现（C44），`Output.expandAll` 一直没人用（S5）。

**四问**：
- 复现：跨多个镜像搜索，折叠一个类型、选中一条命中，下一批结果一到，类型重新展开、选中跳到别的行。
- 基线：本 PR 新引入。
- 影响：每个用 Find 的人都会碰到，而且肉眼可见，建议修。
- 历史：侧栏有过一模一样的 `modelSelected` 回环，b49969eb 改用 `proposedSelection()` 修掉了，Find 页把它带了回来。

**改法**：
- **身份判等 + 增量绑定。** `FindResultNode` 覆写 `isEqual(_:)` / `hash`，按 `identifier` 判等；大纲改用 `rx.nodes(options: .diffable)`。
  - 约定与 RxAppKit 自己测试里的 `TestNode` 相同：`==` 只看身份，内容由 `isContentEqual` 比较（递归版见 PR121.43）。
  - RxAppKit 的 `reloadModeSurfacesSubtreeChanges` 等测试证明，同身份的新实例在 `reloadData()` 之后仍保持展开。
  - 一批结果只会在末尾追加新类型，diff 的结果是纯插入，`insertItems` 不碰已有的行、选中和滚动位置；只有过滤改动了子树时，才退回 `reloadData()`。
  - 身份判等与 `.diffable` 必须同批上：单上 `.diffable`，adapter 提交的是新实例，AppKit 手里却还是旧指针。
- **前提：RxAppKit 0.6.0。** 0.5.4 的 reload 路径用 `oldArray != newArray` 判断有无变化，节点改成身份判等后，只改了内容的更新会被吞掉；包测试和 CLI 的锁文件目前还钉在 0.5.4，见 PR121.71，须先合。
- **展开策略移进 ViewModel：除了用户折叠的，全部展开。**
  - VC 把 `itemDidCollapse` / `itemDidExpand` 通知交给 VM，VM 记下用户折叠了哪些行。
  - 每次更新时，VM 给出要展开的行，先父后子，不进入已折叠行的子树。
  - 新搜索时清空记录。依据是现有契约：`run` / `clear` 一开始会先发一次空结果。
- **选中也移进 ViewModel。** VM 按 identifier 记下用户的选中；VC 在**一个**订阅里依次做三件事：把节点交给 adapter（经 relay 同步驱动绑定）→ 展开 → 恢复选中。恢复只选、不滚动。这样就不再依赖 `:385` 注释说的「订阅注册在绑定之后」这种先后顺序。
- **导航改用 `proposedSelection()`**（与侧栏 b49969eb 同法）。
  - 「单行 + 触发事件」抽成 `RuntimeViewerArchitectures` 里的 `Reactive<NSOutlineView>.userActivatedItem()`。放在这个包，是因为 `RuntimeViewerUI` 不依赖 RxAppKit。
  - 规则：提议恰好一行才导航；键入跳转按侧栏的写法去抖 800 ms；事件带 ⌥ 时走 `resultOpenedInNewTab`（C44）。
- **S5**：删掉 `expandAll`；占位符改为绑定 `output.searchFieldPlaceholder`，删去 `query` 订阅里重复的那段逻辑。
- **省略部分**：右键菜单的改动见 PR121.44，节点缓存见 PR121.48，过滤时复用节点见 PR121.49。这三条改的是同一组文件，合并时以几条的改动之和为准。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
@@ -81,6 +81,22 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         self.identifier = identifier
         self.appearance = Self.makeAppearance(for: content)
         super.init()
     }
 
+    // MARK: - Identity
+
+    /// Two nodes are the same row when they carry the same identifier, whichever instances
+    /// they are: `NSOutlineView` keeps a row expanded and finds its row only for an item equal
+    /// to the one it knows, and every batch of a search builds new nodes. What a row shows is
+    /// compared by `isContentEqual(to:)`, not here.
+    public override func isEqual(_ object: Any?) -> Bool {
+        guard let other = object as? FindResultNode else { return false }
+        return identifier == other.identifier
+    }
+
+    public override var hash: Int {
+        identifier.hashValue
+    }
+
     // MARK: - Construction
```

```diff
--- /dev/null
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerArchitectures/NSOutlineView+UserActivation.swift
@@ -0,0 +1,38 @@
+#if canImport(AppKit) && !targetEnvironment(macCatalyst)
+import AppKit
+import RxSwift
+import RxAppKit
+
+/// One row the user chose in an outline, with the event that chose it.
+public struct OutlineViewUserActivation<Item> {
+    public let item: Item
+    /// The click or keystroke that made the selection; `nil` when AppKit reports none.
+    public let triggeringEvent: NSEvent?
+}
+
+extension Reactive where Base: NSOutlineView {
+    /// The single row the user selects — by click, arrow key or type-select — with the event
+    /// that selected it.
+    ///
+    /// Backed by `proposedSelection()`, which AppKit consults for the user's own selection
+    /// changes only, so a reload, `selectRowIndexes(_:byExtendingSelection:)` and the selection
+    /// a list puts back after its rows change never emit. Neither does a selection of several
+    /// rows (⌘- or ⇧-click, ⌘A): there is no one row to act on.
+    public func userActivatedItem<Item>(_ itemType: Item.Type = Item.self) -> Observable<OutlineViewUserActivation<Item>> {
+        proposedSelection()
+            .asObservable()
+            .compactMap { [weak base] proposedSelection -> OutlineViewUserActivation<Item>? in
+                guard let base,
+                      proposedSelection.indexes.count == 1,
+                      let row = proposedSelection.indexes.first,
+                      let item = base.item(atRow: row) as? Item
+                else { return nil }
+                return OutlineViewUserActivation(item: item, triggeringEvent: proposedSelection.triggeringEvent)
+            }
+    }
+}
+#endif
```

```diff
--- /dev/null
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultActivation.swift
@@ -0,0 +1,13 @@
+#if canImport(AppKit) && !targetEnvironment(macCatalyst)
+import AppKit
+
+/// How a Find result the user chose is opened, read off the event that chose it: with ⌥ held
+/// it opens in a new tab — proposal `draft-find-navigator` §4 — otherwise in the current one.
+public enum FindResultActivation {
+    public static func opensInNewTab(for triggeringEvent: NSEvent?) -> Bool {
+        triggeringEvent?.modifierFlags.contains(.option) == true
+    }
+}
+#endif
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -4,6 +4,17 @@ import RuntimeViewerCore
 import RuntimeViewerArchitectures
 import MemberwiseInit
 
+/// What one update of the Find page's outline consists of: the rows, and what the page does
+/// to them once its data source has them.
+public struct FindResultsPresentation {
+    public let nodes: [FindResultNode]
+    /// Rows to show expanded, parents before children: every row with children except the
+    /// ones the user collapsed during the search on screen, and nothing beneath those.
+    public let nodesToExpand: [FindResultNode]
+    /// The rows the user selected, as nodes of this tree; empty when none of them is shown.
+    public let nodesToSelect: [FindResultNode]
+}
+
 /// One Find navigator page. Generic over the sidebar level's route because
 /// the page is a tab of both sidebar levels; the state lives in the
 /// document's `FindSession`, which both pages bind to, and the scope chooser
@@ -23,6 +34,12 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         public let filterString: Driver<String>
         public let resultClicked: Signal<FindResultNode>
         public let resultOpenedInNewTab: Signal<FindResultNode>
+        /// Rows collapsed or expanded in the outline.
+        public let resultCollapsed: Signal<FindResultNode>
+        public let resultExpanded: Signal<FindResultNode>
+        /// The rows the user selected — by click, arrow key or type-select — never a selection
+        /// the outline put back after its rows changed.
+        public let resultsSelected: Signal<[FindResultNode]>
     }
 
     public struct Output {
@@ -41,13 +58,12 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         public let scopeMenuItems: Driver<[FindScopeMenuItem]>
         public let searchFieldPlaceholder: Driver<String>
         public let nodes: Driver<[FindResultNode]>
+        /// The rows with what to expand and select after them; drives the outline.
+        public let presentation: Driver<FindResultsPresentation>
         /// `nil` hides the summary bar.
         public let summary: Driver<String?>
         public let isSearching: Driver<Bool>
         public let focusSearchField: Signal<Void>
-        /// Fired after a search delivers its first results, so the outline
-        /// expands them; matches are only useful expanded.
-        public let expandAll: Signal<Void>
     }
 
     private let session: FindSession
@@ -55,6 +71,15 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
     @RxObserved
     private var filterString: String = ""
 
+    /// Rows the user collapsed during the search on screen, by identifier. Every other row with
+    /// children is shown expanded: hits are only useful under an expanded type, as Xcode shows
+    /// them. Read when the rows change, never observed.
+    private var collapsedResultIdentifiers: Set<String> = []
+
+    /// The rows the user selected, by identifier, put back on the same hits when an update
+    /// moves rows. Read when the rows change, never observed.
+    private var selectedResultIdentifiers: Set<String> = []
+
     public override init(documentState: DocumentState, router: any Router<Route>) {
         self.session = documentState.findSession
         super.init(documentState: documentState, router: router)
@@ -104,16 +129,46 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         }
         .disposed(by: rx.disposeBag)
 
+        input.resultCollapsed.emitOnNext { [weak self] node in
+            guard let self else { return }
+            collapsedResultIdentifiers.insert(node.identifier)
+        }
+        .disposed(by: rx.disposeBag)
+
+        input.resultExpanded.emitOnNext { [weak self] node in
+            guard let self else { return }
+            collapsedResultIdentifiers.remove(node.identifier)
+        }
+        .disposed(by: rx.disposeBag)
+
+        input.resultsSelected.emitOnNext { [weak self] nodes in
+            guard let self else { return }
+            selectedResultIdentifiers = Set(nodes.map(\.identifier))
+        }
+        .disposed(by: rx.disposeBag)
+
+        // A new search starts with every row expanded and nothing selected: `FindSession.run`
+        // and `clear` publish empty results before anything else.
+        session.$results.asDriver()
+            .filter(\.nodes.isEmpty)
+            .driveOnNext { [weak self] _ in
+                guard let self else { return }
+                collapsedResultIdentifiers = []
+                selectedResultIdentifiers = []
+            }
+            .disposed(by: rx.disposeBag)
+
         let nodes = Driver.combineLatest(session.$results.asDriver(), $filterString.asDriver()) { results, filterString -> [FindResultNode] in
             Self.filtered(results.nodes, by: filterString)
         }
 
-        let expandAll = session.$results.asObservable()
-            .map { !$0.nodes.isEmpty }
-            .distinctUntilChanged()
-            .filter { $0 }
-            .map { _ in () }
-            .asSignal(onErrorSignalWith: .empty())
+        let presentation = nodes.map { [weak self] nodes -> FindResultsPresentation in
+            guard let self else { return FindResultsPresentation(nodes: nodes, nodesToExpand: [], nodesToSelect: []) }
+            return FindResultsPresentation(
+                nodes: nodes,
+                nodesToExpand: Self.expandableNodes(in: nodes, excluding: collapsedResultIdentifiers),
+                nodesToSelect: Self.matchingNodes(in: nodes, identifiedBy: selectedResultIdentifiers)
+            )
+        }
 
         let scope = session.$query.asDriver().map(\.scope).distinctUntilChanged()
         let currentImagePath = documentState.$currentImageNode.asDriver().map { $0?.path }
@@ -134,10 +189,10 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
             scopeMenuItems: scopeMenuItems,
             searchFieldPlaceholder: session.$query.asDriver().map(\.mode.searchFieldPlaceholder),
             nodes: nodes,
+            presentation: presentation,
             summary: session.$summary.asDriver(),
             isSearching: session.$isSearching.asDriver(),
-            focusSearchField: session.focusSearchFieldRelay.asSignal(),
-            expandAll: expandAll
+            focusSearchField: session.focusSearchFieldRelay.asSignal()
         )
     }
 
@@ -259,4 +314,36 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         guard matchesItself || !children.isEmpty else { return nil }
         return FindResultNode(content: node.content, children: children, identifier: node.identifier)
     }
+
+    // MARK: - Expansion and Selection
+
+    /// Every row with children, parents before their children, except the ones in
+    /// `collapsedIdentifiers` — and nothing beneath those, which AppKit shows as it last left
+    /// them once the user expands the row again.
+    static func expandableNodes(in nodes: [FindResultNode], excluding collapsedIdentifiers: Set<String>) -> [FindResultNode] {
+        var expandableNodes: [FindResultNode] = []
+        func collect(_ nodes: [FindResultNode]) {
+            for node in nodes where !node.children.isEmpty && !collapsedIdentifiers.contains(node.identifier) {
+                expandableNodes.append(node)
+                collect(node.children)
+            }
+        }
+        collect(nodes)
+        return expandableNodes
+    }
+
+    /// The rows of the tree whose identifier is among `identifiers`, in tree order.
+    static func matchingNodes(in nodes: [FindResultNode], identifiedBy identifiers: Set<String>) -> [FindResultNode] {
+        guard !identifiers.isEmpty else { return [] }
+        var matchingNodes: [FindResultNode] = []
+        func collect(_ nodes: [FindResultNode]) {
+            for node in nodes {
+                if identifiers.contains(node.identifier) {
+                    matchingNodes.append(node)
+                }
+                collect(node.children)
+            }
+        }
+        collect(nodes)
+        return matchingNodes
+    }
 }
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
@@ -20,6 +20,10 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
     private let openInNewTabRelay = PublishRelay<FindResultNode>()
 
+    /// What the outline shows. Bound to its data source with `bind(to:)`, so the presentation
+    /// subscriber hands nodes over synchronously and can expand and select rows right after.
+    private let displayedNodesRelay = PublishRelay<[FindResultNode]>()
+
     // MARK: - Query Parameters
 
     private let queryParametersView = NSView()
@@ -293,7 +297,47 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
     override func setupBindings(for viewModel: FindViewModel<Route>) {
         super.setupBindings(for: viewModel)
 
-        let resultClicked: Signal<FindResultNode> = outlineView.rx.modelSelected().asSignal()
+        // What the user chose: one row, by click, arrow key or type-select — never a reload,
+        // the selection the page puts back after one, or a selection of several rows.
+        // Type-select reports every keystroke, so that path waits for the typing to settle, as
+        // the sidebar's does; ⌥ opens the row in a new tab.
+        let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126] // Left, Right, Down, Up
+        let isTypeSelect: (NSEvent?) -> Bool = { event in
+            guard let event, event.type == .keyDown else { return false }
+            return !arrowKeyCodes.contains(event.keyCode)
+        }
+        let userActivation = outlineView.rx.userActivatedItem(FindResultNode.self)
+            .share(replay: 0, scope: .whileConnected)
+        let activation: Signal<OutlineViewUserActivation<FindResultNode>> = .merge(
+            userActivation.filter { !isTypeSelect($0.triggeringEvent) }.asSignal(onErrorSignalWith: .empty()),
+            userActivation.filter { isTypeSelect($0.triggeringEvent) }
+                .debounce(.milliseconds(800), scheduler: MainScheduler.instance)
+                .asSignal(onErrorSignalWith: .empty())
+        )
+        let resultClicked: Signal<FindResultNode> = activation
+            .filter { !FindResultActivation.opensInNewTab(for: $0.triggeringEvent) }
+            .map(\.item)
+        let resultOpenedWithOption: Signal<FindResultNode> = activation
+            .filter { FindResultActivation.opensInNewTab(for: $0.triggeringEvent) }
+            .map(\.item)
+
+        let resultsSelected: Signal<[FindResultNode]> = outlineView.rx.proposedSelection()
+            .asSignal()
+            .map { [weak outlineView] proposedSelection in
+                guard let outlineView else { return [] }
+                return proposedSelection.indexes.compactMap { outlineView.item(atRow: $0) as? FindResultNode }
+            }
+        let resultCollapsed: Signal<FindResultNode> = NotificationCenter.default.rx
+            .notification(NSOutlineView.itemDidCollapseNotification, object: outlineView)
+            .compactMap { $0.userInfo?["NSObject"] as? FindResultNode }
+            .asSignal(onErrorSignalWith: .empty())
+        let resultExpanded: Signal<FindResultNode> = NotificationCenter.default.rx
+            .notification(NSOutlineView.itemDidExpandNotification, object: outlineView)
+            .compactMap { $0.userInfo?["NSObject"] as? FindResultNode }
+            .asSignal(onErrorSignalWith: .empty())
 
         // Only what the user picks: the pop-up's own selection when it is bound would overwrite
         // a kind chosen on the other sidebar level's page.
@@ -322,7 +366,10 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
             searchCommitted: searchField.rx.controlEvent.asSignal().map { [searchField] in searchField.stringValue },
             filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
             resultClicked: resultClicked,
-            resultOpenedInNewTab: openInNewTabRelay.asSignal()
+            resultOpenedInNewTab: .merge(openInNewTabRelay.asSignal(), resultOpenedWithOption),
+            resultCollapsed: resultCollapsed,
+            resultExpanded: resultExpanded,
+            resultsSelected: resultsSelected
         )
         let output = viewModel.transform(input)
 
@@ -334,9 +381,6 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
         output.query.driveOnNext { [weak self] query in
             guard let self else { return }
-            if searchField.placeholderString != query.mode.searchFieldPlaceholder {
-                searchField.placeholderString = query.mode.searchFieldPlaceholder
-            }
             let caseState: NSControl.StateValue = query.isCaseSensitive ? .on : .off
             if caseSensitiveButton.state != caseState {
                 caseSensitiveButton.state = caseState
@@ -355,6 +399,12 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
         }
         .disposed(by: rx.disposeBag)
 
+        output.searchFieldPlaceholder.distinctUntilChanged().driveOnNext { [weak self] placeholder in
+            guard let self else { return }
+            searchField.placeholderString = placeholder
+        }
+        .disposed(by: rx.disposeBag)
+
         Driver.combineLatest(output.scopeTitle, output.isScopeAccented).driveOnNext { [weak self] title, isAccented in
             guard let self else { return }
             scopeButton.setScopeTitle(title, isAccented: isAccented)
@@ -369,7 +419,7 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
         }
         .disposed(by: rx.disposeBag)
 
-        output.nodes.drive(outlineView.rx.nodes(options: []))({ (outlineView: NSOutlineView, _: NSTableColumn?, node: FindResultNode) -> NSView? in
+        displayedNodesRelay.bind(to: outlineView.rx.nodes(options: .diffable))({ (outlineView: NSOutlineView, _: NSTableColumn?, node: FindResultNode) -> NSView? in
             let cellView = outlineView.box.makeView(ofClass: FindResultCellView.self)
             cellView.configure(with: node.appearance)
             return cellView
@@ -382,11 +432,22 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
         })
         .disposed(by: rx.disposeBag)
 
-        // Subscribed after the nodes binding, so the adapter has reloaded by the time this
-        // runs: hits are only useful with their type expanded, as Xcode shows them.
-        output.nodes.driveOnNext { [weak self] nodes in
-            guard let self, !nodes.isEmpty else { return }
-            outlineView.expandItem(nil, expandChildren: true)
+        // One pass per update, in this order: the data source takes the nodes — synchronously,
+        // through the relay — then rows are expanded, then the user's selection is put back on
+        // the same hits. A batch only appends types, which the diff inserts without touching the
+        // rows on screen; a filter change reloads, and AppKit keeps a reloaded selection by row
+        // number, not by item.
+        output.presentation.driveOnNext { [weak self] presentation in
+            guard let self else { return }
+            displayedNodesRelay.accept(presentation.nodes)
+            for node in presentation.nodesToExpand where !outlineView.isItemExpanded(node) {
+                outlineView.expandItem(node)
+            }
+            let selectedRowIndexes = IndexSet(presentation.nodesToSelect.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
+            if outlineView.selectedRowIndexes != selectedRowIndexes {
+                outlineView.selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
+            }
         }
         .disposed(by: rx.disposeBag)
 
```

`FindViewModelTests` 里的 `makeViewModel` 要跟着补上三个新输入：
```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindViewModelTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindViewModelTests.swift
@@ -25,6 +25,9 @@ struct FindViewModelTests {
     private let filterStringRelay = BehaviorRelay<String>(value: "")
     private let resultClickedRelay = PublishRelay<FindResultNode>()
     private let resultOpenedInNewTabRelay = PublishRelay<FindResultNode>()
+    private let resultCollapsedRelay = PublishRelay<FindResultNode>()
+    private let resultExpandedRelay = PublishRelay<FindResultNode>()
+    private let resultsSelectedRelay = PublishRelay<[FindResultNode]>()
 
     private static func makeEnvironmentWithCorpus() async throws -> ViewModelTestEnvironment {
         let engine = try await TestRuntimeEngine.shared()
@@ -626,7 +629,10 @@ struct FindViewModelTests {
             searchCommitted: searchCommittedRelay.asSignal(),
             filterString: filterStringRelay.asDriver(),
             resultClicked: resultClickedRelay.asSignal(),
-            resultOpenedInNewTab: resultOpenedInNewTabRelay.asSignal()
+            resultOpenedInNewTab: resultOpenedInNewTabRelay.asSignal(),
+            resultCollapsed: resultCollapsedRelay.asSignal(),
+            resultExpanded: resultExpandedRelay.asSignal(),
+            resultsSelected: resultsSelectedRelay.asSignal()
         ))
         return (viewModel, output)
     }
```

**复现测试（示例）**：

下面几份测试要用到一个手工搭结果树的夹具，PR121.43、PR121.44、PR121.48、PR121.49 的测试也用它：
```swift
// RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Support/FindResultFixtures.swift
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// Find result trees built by hand: a type row per name, with text hits under it. Every call
/// builds new instances, the way `FindSession` builds a tree per batch.
enum FindResultFixtures {
    static func object(named name: String) -> RuntimeObject {
        Fixtures.runtimeObject(name: name, kind: .objc(.type(.class)))
    }

    static func hit(in name: String, lineNumber: Int, lineText: String = "- (void)sample;") -> RuntimeInterfaceSearchMatch {
        RuntimeInterfaceSearchMatch(
            object: object(named: name),
            lineNumber: lineNumber,
            lineText: lineText,
            matchRangeInLine: RuntimeTextRange(location: 0, length: 1),
            semanticKind: .function
        )
    }

    /// A type row named `name` with `hitCount` hits, on lines 1 through `hitCount`.
    static func type(_ name: String, hitCount: Int) -> FindResultNode {
        let hits = (0 ..< hitCount).map { index in
            FindResultNode.textMatch(hit(in: name, lineNumber: index + 1), index: index)
        }
        return FindResultNode.object(object(named: name), matchCount: hitCount, children: hits)
    }
}
```

`FindResultsOutlineTests.swift`（新文件，AppKit 测试）。夹具照 `StatefulOutlineViewRowGeometryTests` 的写法，用离屏窗口，绑定方式与改后的 Find 页相同（`.diffable`）。第一个用例在现状下会红：现在节点按指针判等，第二批的新实例在 AppKit 眼里是没见过的行，Alpha 收起、选中丢失。如果直接按现行的 `options: []` 绑定跑，`reloadData()` 同样让全部行收起。
```swift
import AppKit
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
@testable import RuntimeViewerApplication

@Suite("Find results outline", .serialized)
@MainActor
struct FindResultsOutlineTests {
    @Test("a later batch keeps the type the user collapsed collapsed and the hit the user selected selected")
    func laterBatchKeepsCollapseAndSelection() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.publish([FindResultFixtures.type("Alpha", hitCount: 2), FindResultFixtures.type("Beta", hitCount: 1)])
        fixture.outlineView.expandItem(nil, expandChildren: true)
        fixture.outlineView.collapseItem(try #require(fixture.typeNode(named: "Beta")))
        let selectedHit = try #require(fixture.typeNode(named: "Alpha")?.children.last)
        fixture.outlineView.selectRowIndexes(IndexSet(integer: fixture.outlineView.row(forItem: selectedHit)), byExtendingSelection: false)

        // The next batch: new instances of every row on screen, and one more type.
        fixture.publish([
            FindResultFixtures.type("Alpha", hitCount: 2),
            FindResultFixtures.type("Beta", hitCount: 1),
            FindResultFixtures.type("Gamma", hitCount: 1),
        ])

        let alpha = try #require(fixture.typeNode(named: "Alpha"))
        #expect(fixture.outlineView.isItemExpanded(alpha))
        #expect(!fixture.outlineView.isItemExpanded(try #require(fixture.typeNode(named: "Beta"))))
        let selectedItem = fixture.outlineView.item(atRow: fixture.outlineView.selectedRow) as? FindResultNode
        #expect(selectedItem?.identifier == alpha.children.last?.identifier)
    }

    @Test("only a single row the user chose activates; reloads and selections the list makes do not")
    func onlyTheUsersChoiceActivates() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        var activatedIdentifiers: [String] = []
        var selectionChangeIdentifiers: [String] = []
        let activationSubscription = fixture.outlineView.rx.userActivatedItem(FindResultNode.self)
            .subscribeOnNext { activatedIdentifiers.append($0.item.identifier) }
        // The page's old navigation source, for contrast: it reports what the list does too.
        let selectionChangeSubscription = fixture.outlineView.rx.modelSelected()
            .subscribeOnNext { (node: FindResultNode) in selectionChangeIdentifiers.append(node.identifier) }
        defer {
            activationSubscription.dispose()
            selectionChangeSubscription.dispose()
        }

        fixture.publish([FindResultFixtures.type("Alpha", hitCount: 2)])
        fixture.outlineView.expandItem(nil, expandChildren: true)
        // What a reload and the page's own selection restore do.
        fixture.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        fixture.publish([FindResultFixtures.type("Alpha", hitCount: 1)])
        #expect(activatedIdentifiers.isEmpty)
        #expect(!selectionChangeIdentifiers.isEmpty)

        // What AppKit asks the delegate when the user clicks one row, then ⌘-clicks a second.
        let delegate = try #require(fixture.outlineView.delegate)
        _ = delegate.outlineView?(fixture.outlineView, selectionIndexesForProposedSelection: IndexSet(integer: 0))
        _ = delegate.outlineView?(fixture.outlineView, selectionIndexesForProposedSelection: IndexSet([0, 1]))
        #expect(activatedIdentifiers == [try #require(fixture.typeNode(named: "Alpha")).identifier])
    }
}

extension FindResultsOutlineTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let outlineView: StatefulOutlineView
        private(set) var displayedNodes: [FindResultNode] = []
        private let nodesRelay = PublishRelay<[FindResultNode]>()
        private let disposeBag = DisposeBag()

        init() {
            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.outlineView = outlineView
            outlineView.style = .sourceList
            outlineView.allowsMultipleSelection = true
            scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.orderFrontRegardless()
            // The Find page's binding: a diffing adapter over the nodes.
            nodesRelay.bind(to: outlineView.rx.nodes(options: .diffable)) { (_: NSOutlineView, _: NSTableColumn?, _: FindResultNode) -> NSView? in
                NSTableCellView()
            }
            .disposed(by: disposeBag)
        }

        func publish(_ nodes: [FindResultNode]) {
            displayedNodes = nodes
            nodesRelay.accept(nodes)
            outlineView.layoutSubtreeIfNeeded()
        }

        func typeNode(named name: String) -> FindResultNode? {
            displayedNodes.first { node in
                if case .object(let object, _) = node.content { return object.name == name }
                return false
            }
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }
}
```

`FindResultNodeTests.swift`（新文件，纯单元）：同一个 identifier 的两个实例应当相等，现状下为假。
```swift
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("FindResultNode")
@MainActor
struct FindResultNodeTests {
    @Test("two instances of the same row are equal and hash alike, as AppKit needs to keep it expanded")
    func sameRowIsEqual() {
        let first = FindResultFixtures.type("Alpha", hitCount: 1)
        let second = FindResultFixtures.type("Alpha", hitCount: 1)
        #expect(first !== second)
        #expect(first == second)
        #expect(first.hash == second.hash)
        #expect(first != FindResultFixtures.type("Beta", hitCount: 1))
    }
}
```

`FindResultActivationTests.swift`（C44）：
```swift
import AppKit
import Testing
@testable import RuntimeViewerApplication

@Suite("Find result activation")
@MainActor
struct FindResultActivationTests {
    private static func mouseUp(with modifierFlags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: modifierFlags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    @Test("⌥ opens the chosen result in a new tab; a plain click and no event do not")
    func optionOpensInNewTab() throws {
        #expect(FindResultActivation.opensInNewTab(for: try Self.mouseUp(with: .option)))
        #expect(!FindResultActivation.opensInNewTab(for: try Self.mouseUp(with: [])))
        #expect(!FindResultActivation.opensInNewTab(for: nil))
    }
}
```

`FindViewModelTests` 新增两条，验证展开和选中这两个新契约：
```swift
@Test("rows stay expanded except the ones the user collapsed, until a new search")
func expansionFollowsTheUsersCollapse() async throws {
    let environment = try await Self.makeEnvironmentWithCorpus()
    let (viewModel, output) = makeViewModel(in: environment)
    defer { withExtendedLifetime(viewModel) {} }

    searchCommittedRelay.accept("initWithFormat:")
    let first = try await nextValue(from: output.presentation, timeout: 60) { !$0.nodes.isEmpty }
    let collapsedType = try #require(first.nodes.first)
    #expect(first.nodesToExpand.contains(collapsedType))

    resultCollapsedRelay.accept(collapsedType)
    // Any update publishes the tree again; the filter bar is the simplest one to make.
    filterStringRelay.accept("init")
    let afterCollapse = try await nextValue(from: output.presentation) { $0.nodes.contains(collapsedType) }
    #expect(!afterCollapse.nodesToExpand.contains(collapsedType))

    filterStringRelay.accept("")
    searchCommittedRelay.accept("initWithFormat:")
    let afterNewSearch = try await nextValue(from: output.presentation, timeout: 60) { !$0.nodes.isEmpty }
    #expect(afterNewSearch.nodesToExpand.contains(collapsedType))
}

@Test("the hit the user selected is selected again after an update, and forgotten by a new search")
func selectionFollowsTheUsersChoice() async throws {
    let environment = try await Self.makeEnvironmentWithCorpus()
    let (viewModel, output) = makeViewModel(in: environment)
    defer { withExtendedLifetime(viewModel) {} }

    searchCommittedRelay.accept("initWithFormat:")
    let first = try await nextValue(from: output.presentation, timeout: 60) { !$0.nodes.isEmpty }
    let selectedHit = try #require(first.nodes.last?.children.first)
    resultsSelectedRelay.accept([selectedHit])

    filterStringRelay.accept("initWithFormat")
    let filtered = try await nextValue(from: output.presentation) { !$0.nodesToSelect.isEmpty }
    #expect(filtered.nodesToSelect.map(\.identifier) == [selectedHit.identifier])

    filterStringRelay.accept("")
    searchCommittedRelay.accept("NSMutableString")
    let afterNewSearch = try await nextValue(from: output.presentation, timeout: 60) { !$0.nodes.isEmpty }
    #expect(afterNewSearch.nodesToSelect.isEmpty)
}
```

**同类**：
- Report navigator 每约 16 ms 整树重建并重新展开（`ReportViewController.swift:201-211`，PR121.54），`ReportNode.isContentEqual` 只做浅比较（PR121.53）。两处建议沿用同一套身份判等和展开策略。
- 侧栏根列表的 `SidebarRootViewController.swift:87` 也用 `modelSelected`，但不算同类：那里选中本身就是状态，不触发导航。

**工作量**：L。依赖 PR121.71（RxAppKit 0.6.0）。与 PR121.43、PR121.44、PR121.48、PR121.49 改同一组文件，建议同批。另有两点待用户拍板：Find 大纲要不要补上 `typeSelectStringFor` 让键入跳转真正可用（现在没有实现，按 Apple 文档，未实现时取 prepared cell 的 `stringValue`，view-based 表格大概率是空串）；再次点击已选中的命中要不要重新跳转（`proposedSelection` 是否会为它触发，要在上面的 AppKit 测试里确认）。


### PR121.08 被取消的构建仍接受新请求；组装期间的取消被无视

- **严重度**：Major
- **审查编号**：C01（= S1）+ C02
- **状态**：方案待批，代码未改

**问题**：语料存储取消一个**正在运行**的构建时，只调用了 `task.cancel()`，构建仍留在 `builds` 里（`RuntimeInterfaceCorpusStore.swift:385-388`）。
- **C01**：之后同一镜像的新请求一看 `builds` 里有构建，就把自己挂上去（:342-343），即使它要的 transformer 不同也一样（:329-334 先取消，接着照样走到 :342）。被挂上的请求最后跟着旧构建一起以 `CancellationError` 结束（:539-540），也不会重新排队，这个镜像就一直搜不到。
- **C02**：唯一的取消检查在组装之前（:471）。组装期间到达的驱逐什么也拦不住，`finishBuild` 照样存成「已建好」（:531-535）：旧 transformer 的语料被当成新的交出去；用户关掉语料开关后，刚被驱逐的语料又常驻回来。

**四问**：复现——启动后几分钟、语料还在建时修改 Settings › Transformer：协调器先驱逐全部语料，再按新 transformer 重新请求，新请求挂到正被取消的旧构建上，最终失败；这个错误过了 XPC 后协调器认不出是取消，还会多记一条 Failed 历史（那一半见 PR121.30）。镜像对端换 transformer 时也必然走到这条路径。基线——本 PR 新引入（8b4309b2、1954a8a5）。影响——中等，启动后头几分钟很容易碰上，镜像会长期不可搜，建议修。历史——新代码；:330-332 的注释承诺「该镜像会按此刻生效的配置重建」，唯一的相关测试只覆盖「构建完成之后才改 transformer」。

**改法**：
- 每次构建分配一个身份号。把「接受订阅的构建」（`builds`）和「占着唯一构建槽的任务」（新的 `runningBuild`）分开存放。
- 取消运行中的构建时，**立刻**把它移出 `builds`，并以 `CancellationError` 结束它的全部订阅者。任务继续占着构建槽，直到在途的 family 打印返回（最多 `printingWidth` 个），之后它产出的一切都丢弃。
- 新请求只会加入 `builds` 里现存、且 transformer 相同的构建，否则新建一个排队。新构建等被放弃的那个让出槽位才开始，所以同一个镜像不会有两份打印并行。
- `run` → `publishProgress` / `finishBuild` 全程带着身份号。身份号对不上，就说明这次构建已被放弃：不发进度、不存语料，只释放槽位。这一步同时堵住了 C02 的窗口，而且不依赖 `Task.isCancelled` 的时机。组装前那次取消检查保留，只是为了省掉无用的组装。
- 一个订阅者的 continuation 只会在一处被恢复：放弃时已恢复过的，`finishBuild` 不会再恢复一次（重复 resume 会崩溃），这一点由身份号保证。
- 取舍：被放弃的任务占着构建槽期间，排队中的镜像显示 pending，没有任何镜像显示 building。这段时间最长等于在途的几个 family 打印完成所需的时间。
- 测试接缝：store 的 init 新增一个 internal 参数 `assembleEntries`，默认值就是 `RuntimeInterfaceCorpusAssembly.entries(from:)`。测试借它把构建停在组装阶段。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -224,7 +224,20 @@ actor RuntimeInterfaceCorpusStore {
     private struct Build {
+        /// Tells this build from a later one of the same image. A cancelled
+        /// build leaves `builds` at once; what its task still does after that
+        /// — progress, a finished corpus — is dropped.
+        let identifier: UInt64
         let transformer: Transformer.Configuration
         var subscribers: [Subscriber] = []
-        var task: Task<Void, Never>?
         var progress = RuntimeInterfaceCorpusBuildProgress(built: 0, total: 0)
     }
+
+    /// The build holding the single slot. It keeps the slot after it is
+    /// cancelled, until its task ends — a print in flight cannot be
+    /// interrupted — while its image may already hold a newer build, queued
+    /// behind it.
+    private struct RunningBuild {
+        let imagePath: String
+        let buildIdentifier: UInt64
+        let task: Task<Void, Never>
+    }
 
@@ -254,18 +267,26 @@ actor RuntimeInterfaceCorpusStore {
     /// Images waiting for the single build slot, in request order.
     private var pendingImagePaths: [String] = []
 
-    private var runningImagePath: String?
+    private var runningBuild: RunningBuild?
 
     private var failureMessages: [String: String] = [:]
 
     private var nextSubscriberIdentifier: UInt64 = 0
 
+    private var nextBuildIdentifier: UInt64 = 0
+
+    /// `RuntimeInterfaceCorpusAssembly.entries(from:)`, replaceable so a test
+    /// can hold a build in its assembly and cancel it there.
+    private let assembleEntries: @Sendable ([RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry]
+
     init(
         builder: any RuntimeInterfaceCorpusBuilding,
         residentByteLimit: Int = RuntimeInterfaceCorpusStore.defaultResidentByteLimit,
-        printingWidth: Int = RuntimeInterfaceCorpusStore.defaultPrintingWidth
+        printingWidth: Int = RuntimeInterfaceCorpusStore.defaultPrintingWidth,
+        assembleEntries: @escaping @Sendable ([RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry] = { RuntimeInterfaceCorpusAssembly.entries(from: $0) }
     ) {
         self.builder = builder
         self.residentByteLimit = residentByteLimit
         self.printingWidth = max(1, printingWidth)
+        self.assembleEntries = assembleEntries
     }
@@ -294,3 +315,3 @@ actor RuntimeInterfaceCorpusStore {
         for (imagePath, build) in builds {
-            states[imagePath] = runningImagePath == imagePath ? .building(build.progress) : .pending
+            states[imagePath] = runningBuild?.buildIdentifier == build.identifier ? .building(build.progress) : .pending
         }
@@ -340,8 +361,11 @@ actor RuntimeInterfaceCorpusStore {
             try await withCheckedThrowingContinuation { continuation in
                 let subscriber = Subscriber(identifier: identifier, onProgress: onProgress, continuation: continuation)
+                // `builds` never holds a cancelled build, so a subscriber that
+                // joins here cannot inherit someone else's cancellation.
                 if builds[imagePath] != nil {
                     builds[imagePath]!.subscribers.append(subscriber)
                 } else {
-                    builds[imagePath] = Build(transformer: transformer, subscribers: [subscriber])
+                    nextBuildIdentifier += 1
+                    builds[imagePath] = Build(identifier: nextBuildIdentifier, transformer: transformer, subscribers: [subscriber])
                     pendingImagePaths.append(imagePath)
                 }
@@ -381,33 +405,35 @@ actor RuntimeInterfaceCorpusStore {
-    /// Cancels the image's build whether it is queued or running, resuming
-    /// every remaining subscriber with `CancellationError`.
+    /// Cancels the image's build whether it is queued or running, resuming
+    /// every remaining subscriber with `CancellationError` at once. A running
+    /// build keeps the slot until its task ends, but it leaves `builds` now:
+    /// a request that comes after it starts a build of its own, queued behind
+    /// it, instead of joining one that is already lost.
     private func cancelBuild(imagePath: String) {
-        guard let build = builds[imagePath] else { return }
-        if runningImagePath == imagePath {
-            // `finishBuild(.cancelled)` runs when the task observes the
-            // cancellation; it resumes the subscribers and frees the slot.
-            build.task?.cancel()
+        guard let build = builds.removeValue(forKey: imagePath) else { return }
+        if let runningBuild, runningBuild.buildIdentifier == build.identifier {
+            // `finishBuild` frees the slot when the task ends, and drops what
+            // it produced: this build is no longer in `builds`.
+            runningBuild.task.cancel()
         } else {
             pendingImagePaths.removeAll { $0 == imagePath }
-            builds[imagePath] = nil
-            for subscriber in build.subscribers {
-                subscriber.continuation.resume(throwing: CancellationError())
-            }
+        }
+        for subscriber in build.subscribers {
+            subscriber.continuation.resume(throwing: CancellationError())
         }
     }
 
     private func pump() {
-        guard runningImagePath == nil, !pendingImagePaths.isEmpty else { return }
+        guard runningBuild == nil, !pendingImagePaths.isEmpty else { return }
         let imagePath = pendingImagePaths.removeFirst()
-        guard var build = builds[imagePath] else {
+        guard let build = builds[imagePath] else {
             pump()
             return
         }
-        runningImagePath = imagePath
+        let buildIdentifier = build.identifier
         let transformer = build.transformer
-        build.task = Task.detached(priority: .utility) { [weak self] in
+        let task = Task.detached(priority: .utility) { [weak self] in
             guard let self else { return }
-            await self.run(imagePath: imagePath, transformer: transformer)
+            await self.run(imagePath: imagePath, buildIdentifier: buildIdentifier, transformer: transformer)
         }
-        builds[imagePath] = build
+        runningBuild = RunningBuild(imagePath: imagePath, buildIdentifier: buildIdentifier, task: task)
         #log(.info, "Building corpus for \(imagePath, privacy: .public)")
     }
@@ -421,1 +447,1 @@ actor RuntimeInterfaceCorpusStore {
-    private func run(imagePath: String, transformer: Transformer.Configuration) async {
+    private func run(imagePath: String, buildIdentifier: UInt64, transformer: Transformer.Configuration) async {
@@ -429,1 +455,1 @@ actor RuntimeInterfaceCorpusStore {
-            await publishProgress(imagePath: imagePath, built: 0, total: total)
+            await publishProgress(imagePath: imagePath, buildIdentifier: buildIdentifier, built: 0, total: total)
@@ -463,1 +489,1 @@ actor RuntimeInterfaceCorpusStore {
-                        await publishProgress(imagePath: imagePath, built: built, total: total)
+                        await publishProgress(imagePath: imagePath, buildIdentifier: buildIdentifier, built: built, total: total)
@@ -484,1 +510,1 @@ actor RuntimeInterfaceCorpusStore {
-        finishBuild(imagePath: imagePath, outcome: outcome)
+        finishBuild(imagePath: imagePath, buildIdentifier: buildIdentifier, outcome: outcome)
@@ -511,33 +537,44 @@ actor RuntimeInterfaceCorpusStore {
     private nonisolated func assemble(_ prints: [RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry] {
-        RuntimeInterfaceCorpusAssembly.entries(from: prints)
+        await assembleEntries(prints)
     }
 
-    private func publishProgress(imagePath: String, built: Int, total: Int) async {
+    /// Reaches only the subscribers of build `buildIdentifier`: a cancelled
+    /// build's task may still report while a newer build of its image waits.
+    private func publishProgress(imagePath: String, buildIdentifier: UInt64, built: Int, total: Int) async {
+        guard var build = builds[imagePath], build.identifier == buildIdentifier else { return }
         let progress = RuntimeInterfaceCorpusBuildProgress(built: built, total: total)
-        guard builds[imagePath] != nil else { return }
-        builds[imagePath]!.progress = progress
-        let handlers = builds[imagePath]!.subscribers.map(\.onProgress)
+        build.progress = progress
+        builds[imagePath] = build
+        let handlers = build.subscribers.map(\.onProgress)
         for handler in handlers {
             await handler(progress)
         }
     }
 
-    private func finishBuild(imagePath: String, outcome: BuildOutcome) {
-        let build = builds.removeValue(forKey: imagePath)
-        if runningImagePath == imagePath {
-            runningImagePath = nil
+    private func finishBuild(imagePath: String, buildIdentifier: UInt64, outcome: BuildOutcome) {
+        if runningBuild?.buildIdentifier == buildIdentifier {
+            runningBuild = nil
         }
+        defer { pump() }
+        // Cancelled while it ran — evicted, superseded by another transformer
+        // or left by its last subscriber: its subscribers were told then, and
+        // whatever it produced, even a whole corpus, is stale.
+        guard let build = builds[imagePath], build.identifier == buildIdentifier else {
+            #log(.info, "Dropping what the cancelled corpus build of \(imagePath, privacy: .public) produced")
+            return
+        }
+        builds[imagePath] = nil
         switch outcome {
         case .built(let corpus):
             corpora[imagePath] = corpus
             failureMessages[imagePath] = nil
-            build?.subscribers.forEach { $0.continuation.resume(returning: corpus.summary) }
+            build.subscribers.forEach { $0.continuation.resume(returning: corpus.summary) }
             enforceResidentLimit(protecting: imagePath)
         case .failed(let error):
             failureMessages[imagePath] = "\(error)"
-            build?.subscribers.forEach { $0.continuation.resume(throwing: error) }
+            build.subscribers.forEach { $0.continuation.resume(throwing: error) }
         case .cancelled:
-            build?.subscribers.forEach { $0.continuation.resume(throwing: CancellationError()) }
+            // Still current yet cancelled: the builder went away.
+            build.subscribers.forEach { $0.continuation.resume(throwing: CancellationError()) }
         }
-        pump()
     }
```
```diff
--- a/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift
+++ b/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift
@@ -16,4 +16,6 @@ struct RuntimeInterfaceCorpusStoreTests {
         var delayPerObjectNanoseconds: UInt64 = 0
         /// Overrides `delayPerObjectNanoseconds` for the objects it names.
         var delayNanosecondsByObjectName: [String: UInt64] = [:]
+        /// Holds every print until the test opens it.
+        var printGate: Gate?
         private(set) var printedObjectNames: [String] = []
@@ -52,2 +54,5 @@ struct RuntimeInterfaceCorpusStoreTests {
             defer { lock.withLock { concurrentPrintCount -= 1 } }
+            if let printGate {
+                await printGate.wait()
+            }
             let delayNanoseconds = delayNanosecondsByObjectName[object.name] ?? delayPerObjectNanoseconds
@@ -83,4 +88,52 @@ struct RuntimeInterfaceCorpusStoreTests {
         case objectFailed(String)
     }
 
+    /// Holds whoever waits at it until the test opens it, and ignores
+    /// cancellation meanwhile — as MachOSwiftSection's printing does, which
+    /// has no cancellation point.
+    final class Gate: @unchecked Sendable {
+        private let lock = NSLock()
+        private var isOpen = false
+        private var waiters: [CheckedContinuation<Void, Never>] = []
+
+        var waiterCount: Int {
+            lock.withLock { waiters.count }
+        }
+
+        func wait() async {
+            await withCheckedContinuation { continuation in
+                let resumesNow = lock.withLock {
+                    if isOpen { return true }
+                    waiters.append(continuation)
+                    return false
+                }
+                if resumesNow {
+                    continuation.resume()
+                }
+            }
+        }
+
+        func open() {
+            let releasedWaiters = lock.withLock {
+                isOpen = true
+                defer { waiters.removeAll() }
+                return waiters
+            }
+            releasedWaiters.forEach { $0.resume() }
+        }
+
+        /// Returns once someone waits here, so a test acts while that work
+        /// is in flight.
+        func waitForWaiter(timeout: TimeInterval = 10) async throws {
+            let deadline = Date().addingTimeInterval(timeout)
+            while waiterCount == 0 {
+                guard Date() < deadline else {
+                    Issue.record("nothing ever waited at the gate")
+                    return
+                }
+                try await Task.sleep(nanoseconds: 5_000_000)
+            }
+        }
+    }
+
     private static let imageA = "/images/A"
```

**复现测试（示例）**：放在 `RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift`，用上面加的打印闸门和组装接缝。三个用例在修复前都红：前两个里，第二个请求挂到了已取消的构建上，`second.value` 抛 `CancellationError`；第三个里，组装期间的驱逐拦不住，`buildA` 返回 summary，语料也被存了下来。
```swift
@Test("a request after the running build of its image was cancelled starts a build of its own")
func requestAfterCancellingRunningBuildStartsAfresh() async throws {
    let gate = Gate()
    let fixture = makeStore { $0.printGate = gate }
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let first = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
    try await gate.waitForWaiter()

    await store.evict(imagePath: Self.imageA)
    let second = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
    // The first print stays held, so the second request reaches the store
    // while the cancelled build still runs.
    try await Task.sleep(nanoseconds: 50_000_000)
    gate.open()

    await #expect(throws: CancellationError.self) { try await first.value }
    let summary = try await second.value
    #expect(summary.objectCount == 2)
}

@Test("a different transformer asked for while the image prints gets a build of its own")
func transformerChangeWhilePrintingRebuilds() async throws {
    let gate = Gate()
    let fixture = makeStore { $0.printGate = gate }
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    var changed = Transformer.Configuration.default
    changed.objc.cType.isEnabled.toggle()
    let first = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
    try await gate.waitForWaiter()

    let second = Task { try await store.build(imagePath: Self.imageA, transformer: changed) }
    try await Task.sleep(nanoseconds: 50_000_000)
    gate.open()

    await #expect(throws: CancellationError.self) { try await first.value }
    _ = try await second.value
    #expect(await store.corpus(for: Self.imageA)?.transformer == changed)
}

@Test("a build evicted while its entries are assembled leaves nothing behind")
func evictionDuringAssemblyLeavesNothing() async throws {
    let assemblyGate = Gate()
    let builder = ScriptedBuilder()
    builder.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
    defer { withExtendedLifetime(builder) {} }
    let store = RuntimeInterfaceCorpusStore(builder: builder, printingWidth: 1) { prints in
        await assemblyGate.wait()
        return RuntimeInterfaceCorpusAssembly.entries(from: prints)
    }
    let buildA = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
    try await assemblyGate.waitForWaiter()

    await store.evict(imagePath: Self.imageA)
    assemblyGate.open()

    await #expect(throws: CancellationError.self) { try await buildA.value }
    // B starts only once A's task has handed the slot back, so by now A's
    // outcome has been handled.
    _ = try await store.build(imagePath: Self.imageB, transformer: .default)
    #expect(await store.corpus(for: Self.imageA) == nil)
    #expect(await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA] == nil)
}
```
`assembleEntries` 先按「原样转发」加进去，确认第三个用例是红的，再做修复。若 PR121.26 先落，最后一行改成 `store.coverage()`。

**同类**：
- `publishProgress` 原来按镜像路径找构建（:515-523）。同一镜像同时有一个被放弃的旧构建和一个排队的新构建时，旧任务的进度会发给新订阅者。随身份号一起修，已包含在 diff 里。
- `unsubscribe` 找不到订阅者时静默返回，这正是「已在取消时恢复过」的情况，行为正确，不用改。
- 全仓库没有别的「按镜像路径对应一个任务」的结构。后台索引管理器按批次 id 管理，不受影响。

**工作量**：M；不依赖其它条目。与 PR121.26 改到同一个 `coverage()`，与 PR121.30（取消跨连接后被记成失败）配合：本条让存储在正确的时机抛出取消，PR121.30 让这个取消在跨过连接后仍被认作取消。


### PR121.09 Report 的取消到不了服务端

- **严重度**：Major
- **审查编号**：C06（属于上次第 9 条）
- **状态**：方案待批，代码未改

**问题**：
- 撤回一次语料构建时，协调器只取消了本进程里的那个 `Task`。触发撤回的有：Report navigator 的 Cancel 和 Cancel All、换引擎、关文档。
- 对于转发引擎，这个取消到不了真正在构建的那个进程。转发引擎包括 App 里的 My Mac（转给 local runtime service）、socket 上的注入进程和 Bonjour 设备。
- 结果是服务端照常构建，最多占用 256 MB 常驻内存。下一次刷新 coverage 时，那一行又以「构建中」的状态回到 Report 里；再点 Cancel，`guard` 直接返回，什么也不做。

**四问**：
- **复现**：在 My Mac 上排队构建 Foundation 的语料，等那一行显示「Building」后点 Cancel。然后切走 Report 页再切回来，触发一次 `refreshCoverage`，那一行又回来了，转圈和标签上的活动标记一直亮着。
- **基线**：本 PR 新引入（8ce77d36、8f3cf1cf）。传输层不支持取消是基线就有的问题。
- **影响**：每个用 Report navigator 的人都会遇到，还会浪费服务端的 CPU 和内存。建议修。
- **历史**：新代码，没有修过。这部分是在 My Mac 搬进 XPC service（3d2ae6dc）之后设计的，但测试全部跑在进程内引擎上，所以没发现。

**改法**：
- 跨连接取消的机制由 PR121.29 提供。`cancelBuild`、`withdrawEveryBuild` 和 `deinit` 调用 `task.cancel()` 后，`dispatch` 的 `onCancel` 会发出 `cancelRequest`。服务端收到后注销这个订阅；如果没有别的订阅者，store 会立即以 `CancellationError` 结束它（`unsubscribe`，`RuntimeInterfaceCorpusStore.swift:363-373`）。因此协调器的取消路径本身不用改。
- 新增 `documentWillClose()`，一次撤回本文档的所有请求，并停掉事件泵；`Document.close()` 在调用索引协调器的同名方法旁边调用它。原因：协调器由 `DocumentState` 惰性持有，而 `DocumentState` 不一定随窗口一起释放，单靠 `deinit` 不可靠。模块 D1 也提出了这一点。
- 修改 `buildInterfaceCorpus` 的文档注释，写明「跨连接时撤回由 `cancelRequest` 送达服务进程」。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -225,10 +225,20 @@ public final class FindCorpusCoordinator {
     public func cancelBuild(of imagePath: String) {
         guard let request = buildRequests.removeValue(forKey: imagePath) else { return }
         request.task.cancel()
         buildStatesByImagePath[imagePath] = nil
         recordFinishedBuild(FindCorpusFinishedBuild(imagePath: imagePath, outcome: .cancelled, finishedAt: Date()))
     }
 
+    /// Withdraws every request this document holds and stops listening, for
+    /// a document that is closing. The coordinator can outlive the window —
+    /// `DocumentState` holds it — so `deinit` is too late to count on; over a
+    /// connection each withdrawal reaches the serving process as a
+    /// `cancelRequest`.
+    public func documentWillClose() {
+        stopPumps()
+        withdrawEveryBuild()
+    }
+
     /// Empties `finishedBuilds`. The corpora listed so far stay off it: a
     /// later coverage snapshot does not bring them back.
     public func clearFinishedBuilds() {
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift
@@ -28,4 +28,5 @@ final class Document: NSDocument {
     override func close() {
         documentState.backgroundIndexingCoordinator.documentWillClose()
+        documentState.findCorpusCoordinator.documentWillClose()
         super.close()
     }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
@@ -12,5 +12,7 @@ extension RuntimeEngine {
     /// Runs in the process that owns the image; over a connection only the
     /// progress and the summary travel. Cancelling the calling task withdraws
     /// this caller's subscription to the build, not the build itself, unless
-    /// no one else is waiting for it.
+    /// no one else is waiting for it. Over a connection the withdrawal reaches
+    /// the serving process as a `cancelRequest` (see
+    /// `RuntimeEngineProgressRequest.cancelsAcrossConnections`).
     ///
```

**复现测试（示例）**：
- 放在 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindCorpusCoordinatorTests.swift`。引擎换成 XPC 匿名 listener 装置，也就是 App 里 My Mac 的真实路径。
- 修复前，服务进程会继续构建 Foundation，`refreshCoverage` 之后那一行以 `.building` 状态回来，两条断言都失败。
- 现有的 `cancelRecordsCancellation` 用的是进程内引擎，测不到这条路径。

```swift
@Test("cancelling a build over the local runtime service stops it there, and the row stays gone")
func cancelReachesTheServingProcess() async throws {
    let serviceEngine = RuntimeEngine(source: .local, engineID: "FindCorpusCoordinatorTests.remoteCancel.host")
    let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
    let host = RuntimeLocalRuntimeServiceHost(engine: serviceEngine, connection: listener)
    try await host.start()
    host.activate()
    let client = RuntimeEngine(source: .local, engineID: "FindCorpusCoordinatorTests.remoteCancel.client")
    try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
    try await serviceEngine.loadImage(at: TestImages.foundation)

    let environment = ViewModelTestEnvironment(runtimeEngine: client)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.requestBuild(of: TestImages.foundation)
    _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { self.isBuilding($0[TestImages.foundation]) }

    coordinator.cancelBuild(of: TestImages.foundation)

    // The serving process gives the build up: this document was its only subscriber.
    let coverage = try await waitForCoverage(of: serviceEngine, timeout: 3) { $0.statesByImagePath[TestImages.foundation] == nil }
    #expect(coverage.statesByImagePath[TestImages.foundation] == nil, "the local runtime service kept building")

    // And a refresh does not bring the row back.
    coordinator.refreshCoverage()
    let states = try await values(from: coordinator.$buildStatesByImagePath.asDriver(), during: 1)
    #expect(states.allSatisfy { $0[TestImages.foundation] == nil }, "the cancelled row came back from the coverage")
    await client.stop()
    await host.stop()
}
```
`isBuilding(_:)` 和 `waitForCoverage(of:timeout:where:)` 是这个 suite 现成的辅助函数。

**同类**：换引擎（`handleEngineSwap` → `withdrawEveryBuild`）和 `deinit` 走同一个机制，修好后一并生效。transformer 重建和关掉语料开关走的是 `evict` 命令，本来就能停下。

**工作量**：S。依赖 PR121.29。只从 coverage 学到的行（别的文档发起的构建）能不能取消，由模块 E 的 PR121.55 处理。


### PR121.10 成员定位按名字抢行

- **严重度**：Major
- **审查编号**：C24、C25（含三处同类：静态性不分、一行登记两次、跨种类回退；另含选择子 `foo` / `foo:` 互抢）
- **状态**：方案待批，代码未改

**问题**：Members 搜索给每个成员记一个声明行号，定位器的做法是让成员认领「第一个带它名字、还没被认领的行」。可是不同种类的成员会同名：ObjC 的 property 和同名 ivar、匿名 struct 里的位域字段和读它的 property、类属性和实例属性、Swift 的 `init(degrees:)` 参数标签和 `static func degrees(_:)`。ObjC 先打印 ivar 块，Swift 先打印 init，于是 property 落到 ivar 行或位域行，`static func degrees` 落到 init 行。点开命中会跳到错的行；开着 Strip Synthesized Ivars 时，property 所在的那一行被隐藏，property 干脆从结果里消失。

**四问**：
- **复现**：本机 macOS 27.0 导出里同名 `@synthesize x` 的 property / ivar 对有 Foundation 33 对、AppKit 516 对（例如 `NSColorSlider.colorFromColorPanel`）；`UIViewController` 有十个属性落到 `_viewControllerFlags` 的位域行上；`SwiftUI.Angle` 的 `degrees` / `radians` 落到 init 行。下面的单元测试用手写夹具在任何机器上稳定复现。
- **基线**：本 PR 新引入（8b4309b2，定位器随语料一起加入）。
- **影响**：对 ObjC 类做 Members 搜索是核心用法，结果行错得很常见。建议修。
- **历史**：1954a8a5 修过同一家族的 `CodingKeys` 错位，但只排除了嵌套类型块，没动「按名字认领」本身。现有测试用的 `NSURLQueryItem` 的 ivar 叫 `_name` / `_value`，与属性不同名，所以没测到碰撞。

**改法**：只改定位器（`RuntimeMemberDeclarationLocator`），打印出的文本、成员列表、调用方都不变。
- **键从「名字」改为「种类 + 是否静态 + 名字」**，每种键只认一种 span，再加一条行上的上下文。依据是渲染器的真实输出：
  - **ObjC property**：取 `@property` 行上的 `.member(.declaration)`；同一行有 `class` 关键字就算类属性。property 名由 MOS 的 `MemberDeclaration(name)` 输出。
  - **ObjC ivar**：取 `@interface` 那组 ivar 花括号里、深度恰为 1 的 `.variable`。深度按非注释 span 里的 `{` / `}` 计数。内联展开的 struct 字段在深度 2 及以上；`@property` 行上内联 struct 的字段不在 ivar 块里。这两类都由 `ObjCField` 输出成 `Variable`，因此都不算 ivar。
  - **ObjC 方法**：取去掉缩进后以 `-` / `+` 开头的行，选择子按「片段 + 紧跟着的冒号」精确拼出，是否静态看首字符。旧代码对单片段行同时登记 `foo` 和 `foo:`，`- foo` 与 `- foo:` 会互抢，这一处顺带修掉。
  - **Swift 名字**（field、enum case、variable）：取 `.member(.declaration)` 或 `.variable`；同一行有 `static` / `class` 关键字就算静态。
  - **Swift 函数**：只取带 `func` 关键字的行上的第一个函数片段，也就是基本名。
  - **Swift 的 `init`、`subscript`**：只登记关键字。参数标签同样以 `.function(.declaration)` 输出（MSS `Node+.swift:34-35`），不再当函数名登记。
- **每个键在一行里只登记一次。** 语料在 ObjC 的两种推断结果不一致时，会把同一个 Swift 成员在一行里连印两遍（MSS `printUnderObjCVerdicts`）；按名字算两次，下一个同键成员就能再认领这一行。
- **删掉跨种类回退。** 旧代码里 property / variable 找不到名字行时会去找函数行，Swift 函数反过来也一样。改完后每个成员只查自己的键。为防删掉回退后定位不到的成员变多，下面的不变量测试会检查各种类的定位率。
- **两种语言的键都从每一行上读，不加语言参数。** 成员只查自己种类的键，ObjC 条目的行不会被 Swift 成员认领，所以 `RuntimeInterfaceCorpusAssembly` 的调用不用改。
- **真正的重载**（种类、静态性、名字都相同）仍按出现顺序认领：结果集合不变，用户看不出区别。
- **同步文档**：更新提案 §3.2 并记一条决策日志，见文档 diff。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeMemberDeclarationLocator.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeMemberDeclarationLocator.swift
@@ -6,34 +6,88 @@
 /// declared on.
 ///
 /// The structures and the text come from the same definitions, printed in
-/// the same pass, so they agree on names. The alignment is by name per line:
-/// one walk over the frozen spans records, for each line, the declaration
-/// names on it — property, field and variable names as `.member(.declaration)`
-/// or `.variable` spans, selector pieces (without their colons) and function
-/// names as `.function(.declaration)` spans, `subscript` / `init` as keywords — and each
-/// member then takes the first not-yet-claimed line carrying its name.
-/// Overloads share a name and are claimed in printed order, which matches the
-/// order the definitions list them. A member with no line stays unlocated;
-/// it is still searchable and still reaches its type.
+/// the same pass, so they agree on names — but a name alone does not say
+/// what a line declares. An Objective-C property and the ivar behind it, a
+/// bitfield of an anonymous struct and the property that reads it, a class
+/// member and an instance member, an initializer's argument label and a
+/// function all share names. So a member is matched by its declaration key —
+/// kind, whether it is static, and name — and each kind of key is read off
+/// one kind of span on one kind of line:
 ///
+/// - Objective-C property: a `.member(.declaration)` span on an `@property`
+///   line, static when the line carries the `class` attribute.
+/// - Objective-C ivar: a `.variable` span directly inside the ivar braces of
+///   an `@interface` — not inside a struct or union expanded inline there,
+///   and not in a struct a property's type expands to.
+/// - Objective-C method: the selector a line starting with `-` or `+`
+///   spells, each `.function(.declaration)` piece with the colon printed
+///   after it; static for `+`.
+/// - Swift field, enum case and variable: a `.member(.declaration)` or
+///   `.variable` span, static when the line carries `static` or `class`.
+/// - Swift function: the first `.function(.declaration)` span of a `func`
+///   line — the base name; the parameter labels after it are not names.
+/// - Swift initializer and subscript: the keyword alone. Their argument
+///   labels are `.function(.declaration)` spans too, and must not pass for
+///   the function of that name.
+///
+/// A line registers each key once: the corpus prints a Swift member twice
+/// on one line when the two Objective-C verdicts disagree. Each member then
+/// takes the first not-yet-claimed line carrying its key. Overloads share a
+/// key and are claimed in printed order, which matches the order the
+/// definitions list them. A member with no line stays unlocated; it is still
+/// searchable and still reaches its type.
+///
 /// The lines of the object's nested types are not the object's: a type
 /// prints its nested types above its own members, and their declarations
 /// share names with its own often enough — the cases of a `Codable` type's
 /// synthesized `CodingKeys` are named after its fields. The caller passes
 /// those blocks in, and no member is located inside them.
 enum RuntimeMemberDeclarationLocator {
+    /// What a member is declared as, the way a line spells it.
+    private struct DeclarationKey: Hashable {
+        enum Kind: Hashable {
+            case objcProperty
+            case objcIvar
+            case objcMethod
+            /// A Swift field, enum case or variable.
+            case swiftName
+            case swiftFunction
+            case swiftInitializer
+            case swiftSubscript
+        }
+
+        let kind: Kind
+        let isStatic: Bool
+        let name: String
+    }
+
     /// One printed line's declaration evidence.
     private struct Line {
         /// UTF-8 offset of the line's first byte in the interface.
         let utf8StartOffset: Int
         var text = ""
-        /// Names from `.member(.declaration)` and `.variable` spans.
-        var names: [String] = []
+        /// Names from `.member(.declaration)` spans.
+        var memberDeclarationNames: [String] = []
+        /// Names from `.variable` spans directly inside an `@interface`'s
+        /// ivar braces.
+        var ivarNames: [String] = []
+        /// Names from every other `.variable` span.
+        var variableNames: [String] = []
         /// Pieces from `.function(.declaration)` spans, in order: for an
         /// Objective-C method the selector segments, for a Swift function
         /// the base name followed by its parameter labels.
         var functionPieces: [String] = []
+        /// Whether the text right after each of `functionPieces` is a colon.
+        var functionPieceIsFollowedByColon: [Bool] = []
         var keywords: [String] = []
+
+        /// The Objective-C selector the line spells: each piece with the
+        /// colon the renderer prints after it as plain text.
+        var selector: String {
+            zip(functionPieces, functionPieceIsFollowedByColon).map { piece, isFollowedByColon in
+                isFollowedByColon ? piece + ":" : piece
+            }.joined()
+        }
     }
 
     /// `excludedUTF8Ranges` — ascending, non-overlapping — are the blocks of
@@ -44,14 +98,12 @@
         var lineNumbersByKey = lineNumbersByKey(from: lines, excludingUTF8Ranges: excludedUTF8Ranges)
 
         return members.map { member in
-            for key in keys(for: member) {
-                guard var lineNumbers = lineNumbersByKey[key], !lineNumbers.isEmpty else { continue }
-                let lineNumber = lineNumbers.removeFirst()
-                lineNumbersByKey[key] = lineNumbers
-                let declarationText = lines[lineNumber - 1].text.trimmingCharacters(in: .whitespaces)
-                return member.located(at: lineNumber, declarationText: declarationText)
-            }
-            return member
+            let key = declarationKey(for: member)
+            guard var lineNumbers = lineNumbersByKey[key], !lineNumbers.isEmpty else { return member }
+            let lineNumber = lineNumbers.removeFirst()
+            lineNumbersByKey[key] = lineNumbers
+            let declarationText = lines[lineNumber - 1].text.trimmingCharacters(in: .whitespaces)
+            return member.located(at: lineNumber, declarationText: declarationText)
         }
     }
 
@@ -60,6 +112,10 @@
     private static func lines(of interface: FrozenSemanticString) -> [Line] {
         var lines: [Line] = [Line(utf8StartOffset: 0)]
         var utf8Offset = 0
+        // Braces counted outside comments, and whether the innermost open
+        // brace is the one an `@interface` line opens its ivars with.
+        var braceDepth = 0
+        var isInsideIvarBraces = false
         interface.enumerateSpans { spanText, type, _ in
             // A span can carry line breaks — a multi-line comment, the
             // printer's paragraph separators — so it is split and its pieces
@@ -75,26 +131,56 @@
                 }
                 utf8Offset += piece.utf8.count
                 guard !piece.isEmpty else { continue }
-                lines[lines.count - 1].text += piece
+                let lineIndex = lines.count - 1
+                if let lastPieceIndex = lines[lineIndex].functionPieces.indices.last,
+                   lines[lineIndex].functionPieceIsFollowedByColon.count == lastPieceIndex {
+                    lines[lineIndex].functionPieceIsFollowedByColon.append(piece.hasPrefix(":"))
+                }
+                lines[lineIndex].text += piece
+                if type != .comment {
+                    for character in piece where character == "{" || character == "}" {
+                        if character == "{" {
+                            if braceDepth == 0, lines[lineIndex].keywords.contains("@interface") {
+                                isInsideIvarBraces = true
+                            }
+                            braceDepth += 1
+                        } else {
+                            braceDepth = max(0, braceDepth - 1)
+                            if braceDepth == 0 {
+                                isInsideIvarBraces = false
+                            }
+                        }
+                    }
+                }
                 guard pieces.count == 1 else { continue }
                 let token = String(piece)
                 switch type {
-                case .member(.declaration), .variable:
-                    lines[lines.count - 1].names.append(token)
+                case .member(.declaration):
+                    lines[lineIndex].memberDeclarationNames.append(token)
+                case .variable:
+                    if isInsideIvarBraces, braceDepth == 1 {
+                        lines[lineIndex].ivarNames.append(token)
+                    } else {
+                        lines[lineIndex].variableNames.append(token)
+                    }
                 case .function(.declaration):
-                    lines[lines.count - 1].functionPieces.append(token)
+                    lines[lineIndex].functionPieces.append(token)
                 case .keyword:
-                    lines[lines.count - 1].keywords.append(token)
+                    lines[lineIndex].keywords.append(token)
                 default:
                     break
                 }
             }
         }
+        // A selector piece that ends its line has no colon after it.
+        for lineIndex in lines.indices where lines[lineIndex].functionPieceIsFollowedByColon.count < lines[lineIndex].functionPieces.count {
+            lines[lineIndex].functionPieceIsFollowedByColon.append(false)
+        }
         return lines
     }
 
-    private static func lineNumbersByKey(from lines: [Line], excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>]) -> [String: [Int]] {
-        var result: [String: [Int]] = [:]
+    private static func lineNumbersByKey(from lines: [Line], excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>]) -> [DeclarationKey: [Int]] {
+        var result: [DeclarationKey: [Int]] = [:]
         var excludedRangeIndex = 0
         for (index, line) in lines.enumerated() {
             while excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].upperBound <= line.utf8StartOffset {
@@ -104,45 +190,68 @@
                 continue
             }
             let lineNumber = index + 1
-            for name in line.names {
-                result[nameKey(name), default: []].append(lineNumber)
+            for key in declarationKeys(on: line) {
+                result[key, default: []].append(lineNumber)
             }
-            if let firstPiece = line.functionPieces.first {
-                // A Swift function's base name is its first piece. An
-                // Objective-C selector is every piece joined with the colons
-                // the renderer prints as plain text between them — so a
-                // one-piece line registers both `name` (a method without
-                // arguments, or a Swift function) and `name:` (a method with
-                // one argument).
-                result[functionKey(firstPiece), default: []].append(lineNumber)
-                result[functionKey(line.functionPieces.joined(separator: ":") + ":"), default: []].append(lineNumber)
-            }
-            for keyword in line.keywords where keyword == "subscript" || keyword == "init" {
-                result[keywordKey(keyword), default: []].append(lineNumber)
-            }
         }
         return result
     }
 
     // MARK: - Keys
 
-    private static func nameKey(_ name: String) -> String { "n:" + name }
-    private static func functionKey(_ name: String) -> String { "f:" + name }
-    private static func keywordKey(_ keyword: String) -> String { "k:" + keyword }
+    /// Every key `line` declares, each once. Keys of both languages are
+    /// read off every line; a member only ever looks for the keys of its own
+    /// kind, so an Objective-C entry's lines never answer a Swift member.
+    private static func declarationKeys(on line: Line) -> Set<DeclarationKey> {
+        var keys: Set<DeclarationKey> = []
 
-    /// The keys a member may be declared under, most specific first.
-    private static func keys(for member: RuntimeMemberDeclaration) -> [String] {
+        if line.keywords.contains("@property") {
+            let isClassProperty = line.keywords.contains("class")
+            for name in line.memberDeclarationNames {
+                keys.insert(DeclarationKey(kind: .objcProperty, isStatic: isClassProperty, name: name))
+            }
+        }
+        for name in line.ivarNames {
+            keys.insert(DeclarationKey(kind: .objcIvar, isStatic: false, name: name))
+        }
+        if let firstCharacter = line.text.first(where: { !$0.isWhitespace }), firstCharacter == "-" || firstCharacter == "+", !line.functionPieces.isEmpty {
+            keys.insert(DeclarationKey(kind: .objcMethod, isStatic: firstCharacter == "+", name: line.selector))
+        }
+
+        let isStaticSwiftMember = line.keywords.contains("static") || line.keywords.contains("class")
+        for name in line.memberDeclarationNames + line.variableNames {
+            keys.insert(DeclarationKey(kind: .swiftName, isStatic: isStaticSwiftMember, name: name))
+        }
+        if line.keywords.contains("func"), let baseName = line.functionPieces.first {
+            keys.insert(DeclarationKey(kind: .swiftFunction, isStatic: isStaticSwiftMember, name: baseName))
+        }
+        if line.keywords.contains("init") {
+            keys.insert(DeclarationKey(kind: .swiftInitializer, isStatic: false, name: "init"))
+        }
+        if line.keywords.contains("subscript") {
+            keys.insert(DeclarationKey(kind: .swiftSubscript, isStatic: isStaticSwiftMember, name: "subscript"))
+        }
+        return keys
+    }
+
+    /// The one key a member is declared under. An initializer's static flag
+    /// says nothing about its line, so it is not part of its key.
+    private static func declarationKey(for member: RuntimeMemberDeclaration) -> DeclarationKey {
         switch member.kind {
+        case .objcProperty:
+            DeclarationKey(kind: .objcProperty, isStatic: member.isStatic, name: member.name)
+        case .objcIvar:
+            DeclarationKey(kind: .objcIvar, isStatic: false, name: member.name)
         case .objcMethod:
-            return [functionKey(member.name)]
-        case .objcProperty, .objcIvar, .swiftField, .swiftEnumCase, .swiftVariable:
-            return [nameKey(member.name), functionKey(member.name)]
+            DeclarationKey(kind: .objcMethod, isStatic: member.isStatic, name: member.name)
+        case .swiftField, .swiftEnumCase, .swiftVariable:
+            DeclarationKey(kind: .swiftName, isStatic: member.isStatic, name: member.name)
         case .swiftFunction:
-            return [functionKey(member.name), nameKey(member.name)]
-        case .swiftSubscript:
-            return [keywordKey("subscript")]
+            DeclarationKey(kind: .swiftFunction, isStatic: member.isStatic, name: member.name)
         case .swiftInitializer:
-            return [keywordKey("init"), functionKey("init")]
+            DeclarationKey(kind: .swiftInitializer, isStatic: false, name: "init")
+        case .swiftSubscript:
+            DeclarationKey(kind: .swiftSubscript, isStatic: member.isStatic, name: "subscript")
         }
     }
 }
```

```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -231,10 +231,11 @@
 - `RuntimeMemberDeclaration { name, kind, isStatic, declarationText, lineNumber? }`，`kind` 枚举：
   `objcProperty / objcMethod / objcIvar / swiftField / swiftEnumCase / swiftFunction / swiftVariable /
   swiftSubscript / swiftInitializer`。用户要的六类（ObjC Property、Methods、Swift Field、Function、Variable、
   Subscript）是面板上的过滤组，ivar / enum case / initializer 归入相邻组或单列，由 UI 定。
-- **行号来自同一趟打印的 span 序列**：打印完成后顺序遍历 Frozen 的 `.member(.declaration)` /
-  `.function(.declaration)` / `.variable` span，与结构成员按名字顺序对齐（ObjC 多段 selector 取第一段对齐）。对不上
-  的成员 `lineNumber` 为空，仍可搜、点击只跳到类型。
+- **行号来自同一趟打印的 span 序列**：打印完成后顺序遍历 Frozen 的 span，按「种类 + 是否静态 + 名字」对齐：
+  ObjC property 只认 `@property` 行的 `.member(.declaration)`，ivar 只认 ivar 花括号内深度 1 的 `.variable`，
+  方法认 `-` / `+` 行拼出的完整选择子；Swift 函数只认 `func` 行的基本名，`init` / `subscript` 只认关键字。
+  同一行同一个键只登记一次。对不上的成员 `lineNumber` 为空，仍可搜、点击只跳到类型。
 - 查询：名字按匹配方式匹配（Containing / Matching Word / Starting With / Ending With / 正则，规则与文本模式相同，
   见 §7；2026-10-03 之前只有子串），大小写可选，`kinds` 过滤；`RuntimeMemberMatch { object, member, matchRangeInName }`。
   `resultLimit` / truncated 语义与文本相同。
@@ -756 +757,2 @@
 | 2026-10-04 | 一个都没选时 OK 置灰；表单列表覆写 `mouseDown(with:)`；菜单项不带图标 | Xcode 的 OK 此时能点却不改范围，置灰更直观。不覆写时 macOS 27 的列表点击不给焦点，选中的行一直是灰色，与 `StatefulOutlineView` 同一取舍。我们没有与 Xcode 那几个范围对应的图标。 |
+| 2026-10-xx | 成员定位改按「种类 + 是否静态 + 名字」对齐，删掉跨种类回退 | PR #121 审查：按名字认领时，property 会抢同名 ivar 行和位域字段行，`static func degrees` 会抢 `init(degrees:)` 行（Foundation 27.0 有 33 对同名 property / ivar，AppKit 516 对）。打印器为每种成员用的 span 是固定的，按种类取证就不必猜。 |
```

（决策日志那一行的日期按落地当天填写。）

**复现测试（示例）**：前三个加在 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeMemberDeclarationLocatorTests.swift`。夹具按 MOS / MSS 渲染器的真实输出手写；成员故意不按打印顺序传入，用来证明定位与顺序无关。现有四个用例在新代码下预期结果不变。
```swift
@Test("Objective-C members that share a name each get their own line, whatever order they are listed in")
func objectiveCMembersSharingAName() {
    /// ```
    ///  1 @interface Fixture : NSObject {
    ///  2     BOOL colorFromColorPanel;
    ///  3     struct {
    ///  4         unsigned int hidesBottomBarWhenPushed : 1;
    ///  5     } _viewControllerFlags;
    ///  6 }
    ///  7 @property (class) NSInteger shared;
    ///  8 @property NSInteger shared;
    ///  9 @property BOOL colorFromColorPanel; // @synthesize colorFromColorPanel
    /// 10 @property BOOL hidesBottomBarWhenPushed;
    /// 11 + (id)make;
    /// 12 - (id)make;
    /// 13 - (void)make:(id)value;
    /// 14 @end
    /// ```
    let interface: FrozenSemanticString = SemanticString {
        Keyword("@interface")
        Standard(" ")
        TypeDeclaration(kind: .class, "Fixture")
        Standard(" : ")
        TypeName(kind: .class, "NSObject")
        Standard(" {\n    ")
        Keyword("BOOL")
        Standard(" ")
        Variable("colorFromColorPanel")
        Standard(";\n    ")
        Keyword("struct")
        Standard(" {\n        ")
        Keyword("unsigned")
        Standard(" ")
        Keyword("int")
        Standard(" ")
        // `ObjCField` prints a struct's fields, bitfields included, as variables.
        Variable("hidesBottomBarWhenPushed")
        Standard(" : ")
        Numeric(1)
        Standard(";\n    } ")
        Variable("_viewControllerFlags")
        Standard(";\n}\n")
        Keyword("@property")
        Standard(" (")
        Keyword("class")
        Standard(") ")
        TypeName(kind: .other, "NSInteger")
        Standard(" ")
        MemberDeclaration("shared")
        Standard(";\n")
        Keyword("@property")
        Standard(" ")
        TypeName(kind: .other, "NSInteger")
        Standard(" ")
        MemberDeclaration("shared")
        Standard(";\n")
        Keyword("@property")
        Standard(" ")
        Keyword("BOOL")
        Standard(" ")
        MemberDeclaration("colorFromColorPanel")
        Standard("; ")
        Comment("// @synthesize colorFromColorPanel")
        Standard("\n")
        Keyword("@property")
        Standard(" ")
        Keyword("BOOL")
        Standard(" ")
        MemberDeclaration("hidesBottomBarWhenPushed")
        Standard(";\n+ (id)")
        FunctionDeclaration("make")
        Standard(";\n- (id)")
        FunctionDeclaration("make")
        Standard(";\n- (void)")
        FunctionDeclaration("make")
        Standard(":(id)")
        Argument("value")
        Standard(";\n")
        Keyword("@end")
    }.frozen()

    let located = RuntimeMemberDeclarationLocator.locate([
        member("make:", .objcMethod),
        member("shared", .objcProperty),
        member("colorFromColorPanel", .objcProperty),
        member("hidesBottomBarWhenPushed", .objcProperty),
        member("shared", .objcProperty, isStatic: true),
        member("colorFromColorPanel", .objcIvar),
        member("_viewControllerFlags", .objcIvar),
        member("make", .objcMethod),
        member("make", .objcMethod, isStatic: true),
    ], in: interface)

    // Before the fix: [11, 7, 2, 4, 8, 9, 5, 11, 12] — eight of nine wrong.
    #expect(located.map(\.lineNumber) == [13, 8, 9, 10, 7, 2, 5, 12, 11])
}

@Test("initializer and subscript labels are not function names, and static members keep to static lines")
func swiftLabelsAndStaticMembers() {
    /// ```
    ///  1 struct Angle {
    ///  2     init(degrees: Double)
    ///  3     init(radians: Double)
    ///  4     var degrees: Double
    ///  5     subscript(degrees index: Int) -> Double
    ///  6     static var zero: Angle
    ///  7     var zero: Angle
    ///  8     static func degrees(_ value: Double) -> Angle
    ///  9     static func radians(_ value: Double) -> Angle
    /// 10 }
    /// ```
    let interface: FrozenSemanticString = SemanticString {
        Keyword("struct")
        Standard(" ")
        TypeDeclaration(kind: .struct, "Angle")
        Standard(" {\n    ")
        Keyword("init")
        Standard("(")
        FunctionDeclaration("degrees")
        Standard(": Double)\n    ")
        Keyword("init")
        Standard("(")
        FunctionDeclaration("radians")
        Standard(": Double)\n    ")
        Keyword("var")
        Standard(" ")
        Variable("degrees")
        Standard(": Double\n    ")
        Keyword("subscript")
        Standard("(")
        FunctionDeclaration("degrees")
        Standard(" index: Int) -> Double\n    ")
        Keyword("static")
        Standard(" ")
        Keyword("var")
        Standard(" ")
        Variable("zero")
        Standard(": Angle\n    ")
        Keyword("var")
        Standard(" ")
        Variable("zero")
        Standard(": Angle\n    ")
        Keyword("static")
        Standard(" ")
        Keyword("func")
        Standard(" ")
        FunctionDeclaration("degrees")
        Standard("(_ value: Double) -> Angle\n    ")
        Keyword("static")
        Standard(" ")
        Keyword("func")
        Standard(" ")
        FunctionDeclaration("radians")
        Standard("(_ value: Double) -> Angle\n}")
    }.frozen()

    let located = RuntimeMemberDeclarationLocator.locate([
        member("degrees", .swiftFunction, isStatic: true),
        member("radians", .swiftFunction, isStatic: true),
        member("zero", .swiftVariable),
        member("zero", .swiftVariable, isStatic: true),
        member("degrees", .swiftVariable),
        member("subscript", .swiftSubscript),
        member("init", .swiftInitializer, isStatic: true),
        member("init", .swiftInitializer, isStatic: true),
    ], in: interface)

    // Before the fix: [2, 3, 6, 7, 4, 5, 2, 3] — the static functions took
    // the initializers' lines and the two `zero`s swapped.
    #expect(located.map(\.lineNumber) == [8, 9, 7, 6, 4, 5, 2, 3])
}

@Test("a member printed twice on one line claims that line once")
func memberPrintedTwiceOnOneLine() {
    /// The corpus prints a member under both Objective-C verdicts when they
    /// disagree, one after the other on the same line.
    /// ```
    /// 1 protocol Describing {
    /// 2     @objc var summary: String { get }var summary: String { get }
    /// 3 }
    /// 4 extension Describing {
    /// 5     var summary: String { get }
    /// 6 }
    /// ```
    let interface: FrozenSemanticString = SemanticString {
        Keyword("protocol")
        Standard(" ")
        TypeDeclaration(kind: .protocol, "Describing")
        Standard(" {\n    ")
        Keyword("@objc")
        Standard(" ")
        Keyword("var")
        Standard(" ")
        Variable("summary")
        Standard(": String { get }")
        Keyword("var")
        Standard(" ")
        Variable("summary")
        Standard(": String { get }\n}\n")
        Keyword("extension")
        Standard(" ")
        TypeName(kind: .protocol, "Describing")
        Standard(" {\n    ")
        Keyword("var")
        Standard(" ")
        Variable("summary")
        Standard(": String { get }\n}")
    }.frozen()

    let located = RuntimeMemberDeclarationLocator.locate([
        member("summary", .swiftVariable),
        member("summary", .swiftVariable),
    ], in: interface)

    // Before the fix: [2, 2] — the requirement's line was registered twice.
    #expect(located.map(\.lineNumber) == [2, 5])
}
```

第四个是端到端的不变量，加在 `RuntimeInterfaceCorpusNestingTests`（复用套件里已经建好的 Foundation 语料）。它只用文本前缀和关键字判断，不复用定位器的 span 规则，以免自己证明自己。Foundation 27.0 有 33 对同名 property / ivar，所以修复前一定会红。定位率门槛先写 90%，首次跑出实际数字后再定；如果低于这个值，先查原因再调，不要直接降门槛。
```swift
@Test("every located member's line declares a member of its own kind")
func locatedLinesDeclareTheirMembers() async throws {
    let entries = try await Self.foundationEntries()
    var misplaced: [String] = []
    var listedCountByKind: [RuntimeMemberKind: Int] = [:]
    var locatedCountByKind: [RuntimeMemberKind: Int] = [:]
    for entry in entries {
        let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
        for member in entry.members {
            listedCountByKind[member.kind, default: 0] += 1
            guard let lineNumber = member.lineNumber else { continue }
            locatedCountByKind[member.kind, default: 0] += 1
            let line = lines[lineNumber - 1]
            if !Self.line(line, declares: member) {
                misplaced.append("\(entry.object.displayName) \(member.kind.rawValue)\(member.isStatic ? " static" : "") \(member.name) → line \(lineNumber): \(line)")
            }
        }
    }
    #expect(misplaced.isEmpty, "\(misplaced.count) members located on another declaration's line, e.g.\n\(misplaced.prefix(10).joined(separator: "\n"))")
    for kind in [RuntimeMemberKind.objcProperty, .objcIvar, .objcMethod] {
        let listedCount = listedCountByKind[kind, default: 0]
        let locatedCount = locatedCountByKind[kind, default: 0]
        #expect(listedCount > 0 && locatedCount * 10 >= listedCount * 9, "\(locatedCount) of \(listedCount) \(kind.rawValue) members located")
    }
}

/// What a line has to read like for `member` to be declared on it — words
/// only, so the check does not lean on the span rules the locator uses.
private static func line(_ line: Substring, declares member: RuntimeMemberDeclaration) -> Bool {
    let trimmedLine = line.drop(while: { $0 == " " })
    let words = Set(trimmedLine.split(whereSeparator: { !$0.isLetter && $0 != "@" }).map(String.init))
    let readsStatic = words.contains("static") || words.contains("class")
    switch member.kind {
    case .objcProperty:
        return trimmedLine.hasPrefix("@property") && words.contains("class") == member.isStatic
    case .objcIvar:
        // One level into the `@interface` braces; an expanded struct's fields sit deeper.
        let indentation = line.prefix(while: { $0 == " " }).count
        return indentation == 4 && !trimmedLine.hasPrefix("@property") && !trimmedLine.hasPrefix("-") && !trimmedLine.hasPrefix("+")
    case .objcMethod:
        return trimmedLine.hasPrefix(member.isStatic ? "+" : "-")
    case .swiftInitializer:
        return words.contains("init")
    case .swiftFunction:
        return words.contains("func") && readsStatic == member.isStatic
    case .swiftSubscript:
        return words.contains("subscript") && readsStatic == member.isStatic
    case .swiftVariable, .swiftField:
        return (words.contains("var") || words.contains("let")) && readsStatic == member.isStatic
    case .swiftEnumCase:
        return words.contains("case")
    }
}
```

**同类**：已在上面一并处理的有：类属性与实例属性同名、`+` 与 `-` 方法同名、Swift `static var` 与 `var` 同名、一行登记两次、跨种类回退、选择子 `foo` 与 `foo:` 互抢。全仓库没有其它「按名字找声明行」的定位器；其余 `enumerateSpans` 调用都是主题着色。另外，Swift 的函数类型参数标签和 enum payload 标签如果也以 `.function(.declaration)` 输出，新规则只认 `func` 行，同样不会误登记。这一点未逐一核实打印路径，由不变量测试兜底。

**工作量**：M。与 PR121.11 互不依赖；两者改的是同一组测试文件，建议放在同一批提交。


### PR121.11 顶层协议的默认实现进不了 Members 搜索

- **严重度**：Major
- **审查编号**：C27
- **状态**：方案待批，代码未改

**问题**：顶层 Swift 协议的语料条目只把协议要求列为成员。它的默认实现由 MachOSwiftSection（MSS）的打印器接在协议后面打印出来，所以 Text 搜索能找到，但这些成员从不进 `memberDeclarations(of:)`，Members 搜索因此找不到。

一整批 API 因此在 Members 搜索里静默缺失：SwiftUI 的 view modifier（`padding`、`fixedSize`、`disabled`……）、`Sequence` / `Collection` 的算法（`filter`……）。嵌套在类型里的协议反而是正常的，所以搜不搜得到取决于协议是否嵌套。

**四问**：
- **复现**：建好 SwiftUICore 的语料后，在 Members 里搜 `padding`，没有结果，而在 Text 里能搜到 `View` 条目中的同一行。Foundation 的 `LocalizedError` 同样能复现：Members 搜 `errorDescription`，该条目只命中协议要求，没有命中默认实现。
- **基线**：本 PR 内部引入的回归。8b4309b2 时 `printedDefinitions` 还把全部默认实现当作 `.extension` 返回，成员是全的；1954a8a5 为去掉重复的文本删掉了这份副本，成员也就跟着没了。
- **影响**：受影响的是整族的常用 API，用户会以为它们不存在。建议修。
- **历史**：1954a8a5 删副本是对的，否则同一段文本会印两三遍。问题在于成员列表和打印读的是同一个列表，删副本时没有给成员另找来源。本机另有一个分支 `fix/protocol-default-implementations-printed-once`（PR #117，目标 main）：它把「内容区只印一次」这一半单独送进 main，只改打印，不涉及成员，与本条没有代码重叠。

**改法**：改为按结构列成员，打印出的文本不变。
- `.protocol(def)`：列出协议要求，再列 `def.defaultImplementationExtensions` 里每个扩展的成员。
- `.extension(ext)`：如果它就是前面某个协议的默认实现扩展，就跳过，免得嵌套协议的默认实现被列两次（嵌套协议的默认实现由 `printedDefinitions` 追加在协议之后，会作为 `.extension` 出现）。
- 用对象身份判断，不只看 `isAttachedToProtocolDefinition`：一个协议如果没有可挂的符号扫描扩展块，MSS 会在 `index(in:)` 里合成一个默认实现扩展，而这个合成的扩展不带该标记（`ProtocolDefinition+Indexing.swift`）。
- 取舍：成员列表不再需要知道默认实现由谁打印，也就不必再照抄打印器的规则（那是 PR121.27 讲的耦合）。代价是在一种既有的边角情况下会多出没有行号的成员：嵌套协议只有合成的默认实现扩展时，`printedDefinitions` 在打印之前算好，那时扩展还不存在，文本里也就没有它。这些成员仍然能搜到，点击后跳到类型。
- 成员的顺序是「协议要求 → 默认实现 → 未挂接的扩展」，与打印顺序一致，PR121.10 的定位器能按顺序把它们放到各自的行上。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
@@ -1840,10 +1840,21 @@
     }
 
     /// The members `definitions` list, not yet located in any text. Reads
     /// whatever the definitions have indexed so far; after they are printed,
     /// that is everything.
+    ///
+    /// A protocol's default implementations are its members wherever they
+    /// end up printed: the printer trails a top-level protocol with them
+    /// itself, and `printedDefinitions(for:)` appends them after any other
+    /// protocol. So they are listed with the protocol, from its
+    /// `defaultImplementationExtensions`, and an extension that is one of
+    /// them is skipped when it comes up as a definition of its own. Identity
+    /// decides, not `isAttachedToProtocolDefinition`: MachOSwiftSection
+    /// synthesizes an unflagged default-implementation extension for a
+    /// protocol no symbol-scan extension block was attached to.
     static func memberDeclarations(of definitions: [PrintedDefinition]) -> [RuntimeMemberDeclaration] {
         var members: [RuntimeMemberDeclaration] = []
+        var listedDefaultImplementationExtensions: Set<ObjectIdentifier> = []
         for definition in definitions {
             switch definition {
             case .type(let typeDefinition):
@@ -1854,7 +1865,12 @@
                 members += Self.memberDeclarations(of: typeDefinition)
             case .protocol(let protocolDefinition):
                 members += Self.memberDeclarations(of: protocolDefinition)
+                for extensionDefinition in protocolDefinition.defaultImplementationExtensions {
+                    listedDefaultImplementationExtensions.insert(ObjectIdentifier(extensionDefinition))
+                    members += Self.memberDeclarations(of: extensionDefinition)
+                }
             case .extension(let extensionDefinition):
+                guard !listedDefaultImplementationExtensions.contains(ObjectIdentifier(extensionDefinition)) else { continue }
                 members += Self.memberDeclarations(of: extensionDefinition)
             }
         }
```

**复现测试（示例）**：加在 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusNestingTests.swift`，复用这个套件已经建好的 Foundation 语料。
- 第一个用例：`LocalizedError` 从 Swift 3 起就是公开 API；6befc62d 也确认过它的默认实现会被打印出来。修复前 Members 只命中 1 条（协议要求），修复后应命中 2 条。
- 第二个用例：在 Foundation 全部协议上检查同一件事。修复前，所有带挂接默认实现的顶层协议都会被列为缺失。只检查带挂接（`isAttachedToProtocolDefinition`）默认实现的协议，以排除上面提到的合成扩展那种边角情况。

```swift
@Test("a top-level protocol's default implementations are found by a member search")
func topLevelProtocolDefaultImplementationsAreMembers() async throws {
    let engine = try await Self.foundationEngine.value
    var matches: [RuntimeMemberMatch] = []
    _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "errorDescription", kinds: [.swiftVariable], isCaseSensitive: true)) { batch in
        matches += batch
    }
    let isLocalizedError: (RuntimeObject) -> Bool = { $0.kind == .swift(.type(.protocol)) && $0.displayName.hasSuffix("LocalizedError") }
    // The requirement and the default implementation the printer trails the protocol with.
    let protocolMatches = matches.filter { isLocalizedError($0.object) && $0.member.name == "errorDescription" }
    #expect(protocolMatches.count == 2, "\(protocolMatches.map(\.member.declarationText))")

    let entry = try #require(try await Self.foundationEntries().first { isLocalizedError($0.object) })
    let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
    let firstExtensionLineNumber = try #require(lines.firstIndex { $0.hasPrefix("extension ") }) + 1
    let lineNumbers = protocolMatches.compactMap(\.member.lineNumber)
    #expect(Set(lineNumbers).count == 2)
    #expect(lineNumbers.contains { $0 > firstExtensionLineNumber }, "no match inside the default implementations: \(lineNumbers)")
}

@Test("every protocol with default implementations has a member located among them")
func protocolDefaultImplementationsLocated() async throws {
    let engine = try await Self.foundationEngine.value
    let entries = try await Self.foundationEntries()
    let firstSwiftEntry = try #require(entries.first { $0.object.kind.isSwift })
    let section = try #require(await engine.swiftSectionFactory.existingSection(for: firstSwiftEntry.object.imagePath))
    var checkedCount = 0
    var missing: [String] = []
    for entry in entries where entry.object.kind == .swift(.type(.protocol)) {
        // Only symbol-scan extension blocks, which every placement prints:
        // a synthesized one is not printed for a nested protocol.
        guard case .protocol(let definition) = try? await section.printedDefinitions(for: entry.object).first,
              definition.defaultImplementationExtensions.contains(where: \.isAttachedToProtocolDefinition)
        else { continue }
        checkedCount += 1
        let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstExtensionLineIndex = lines.firstIndex(where: { $0.hasPrefix("extension ") }) else {
            missing.append("\(entry.object.displayName): prints no extension")
            continue
        }
        if !entry.members.contains(where: { ($0.lineNumber ?? 0) > firstExtensionLineIndex + 1 }) {
            missing.append("\(entry.object.displayName): no member located in its default implementations")
        }
    }
    #expect(checkedCount > 10)
    #expect(missing.isEmpty, "\(missing.count) of \(checkedCount) protocols, e.g.\n\(missing.prefix(10).joined(separator: "\n"))")
}
```

**同类**：
- 前面说的合成默认实现扩展那种边角情况：既有问题，影响很小，记一笔，不单独修。
- 本条之后，成员列表不再依赖打印规则；打印那一侧的规则拷贝由 PR121.27 处理。
- 成员列表里另有两处同样是对打印器的假设：「allocators 为空就列 constructors」，以及属性包装器合成的 `_x` / `$x`。这两处也记在 PR121.27 的「同类」里。

**工作量**：S；不依赖其它条目。建议与 PR121.10 同一批提交（同一组测试文件）。


### PR121.12 socket 上回复先于进度推送被处理，丢掉最后几批结果

- **严重度**：Major
- **审查编号**：C08（上次第 12 条，审查判为「疑似」）
- **状态**：方案待批，代码未改

**问题**：
- 在 socket 传输上（沙盒化的附加 App、iOS 模拟器 payload、Bonjour 设备、镜像引擎），服务端先按顺序发出全部进度推送，最后才写回复。
- 客户端处理方式不同：推送排进一条串行的处理链，回复却在接收循环里当场交付。
- 回复一到，`dispatch` 就返回，并用 `defer` 删掉进度路由，链上还没处理完的推送随即被丢弃。
- 搜索命中只靠进度推送送达，所以结果会缺掉最后几个镜像的命中；摘要里的「N results」却仍把它们计算在内，而且每次运行结果都不一样。

**四问**：
- **复现**：读代码确认了机制，待下面的测试转红后才算真正确认。
  - 服务端：`registerProgress` 依次 `await` 每条推送，之后才写回复（`RuntimeEngineRequest.swift:125-144`）。
  - 客户端：推送通过 `enqueueOrdered` 排队（`RuntimeMessageChannel.swift:568-576`），回复在 `dispatchReceived` 里当场交付（:552-555）。
  - 回复交付后，`dispatch` 的 `defer`（`RuntimeEngine.swift:930`）删掉路由，排在后面的推送在 `routeProgressPush`（:944-947）里被丢弃。
  - XPC 不受影响：XPC 上每条推送都是一次往返，服务端要等客户端处理完才继续。
- **基线**：机制在基线就有，来自 4c8cccd1（按 token 路由进度）和 2a0573b7（回复当场交付）。以前最多丢几条加载进度，本 PR 之后丢的是搜索结果。
- **影响**：凡是走 socket 的引擎上做 Find，结果都可能不全。建议修。
- **历史**：4c8cccd1 的注释明确接受丢弃「和自己的回复赛跑」的推送。对进度计数来说这个取舍合理，对结果则不成立。

**改法**：
- 采用「回复屏障」，不改线格式。
  - `deliverToPendingRequest` 交付回复时，同时带上当时的 `orderedHandlerTail`，也就是这条回复之前收到的全部推送的处理链。
  - `sendRequest` 拿到回复后先 `await` 这条链，再返回。
  - 效果：所有 socket 请求都得到和 XPC 一样的保证——回复之前推过来的东西，在调用方继续之前都已处理完。
  - 处理全部发生在接收端，对旧对端同样有效。
- 防止死锁：
  - 串行链上的处理器如果向同一连接发请求，它自己就在屏障里，等屏障会把自己锁死。
  - 因此 `enqueueOrdered` 用 `@TaskLocal` 标记「正运行在串行链上」，从链上发出的请求跳过屏障。
  - 链上处理器派生的非结构化 `Task` 会继承这个标记，也会跳过屏障。这只是少了顺序保证，行为与修改前相同，不会死锁。
  - 唯一的残留陷阱：链上的处理器 `await` 一个 `Task.detached`，而后者向同一连接发请求。`detached` 不继承标记，会死锁。在注释里写明，禁止这种写法。
- 不选的方案：
  - 所有回复都改走串行链：处理器内嵌往返会死锁，现有的 `testLocalSocketNestedRoundTripNoDeadlock` 守着这一点。
  - 推送改成需要确认的往返：旧客户端不回确认，会挂住新服务端。
  - 把命中放进最终回复：失去按镜像流式显示的效果。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift
@@ -98,7 +98,16 @@ protocol RuntimeMessageProtocol: Sendable {
 final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
     /// Unique identifier for this channel.
     let id = UUID()
 
+    /// Set while a fire-and-forget handler runs on `orderedHandlerTail`. A
+    /// request sent from there skips the reply barrier in `sendRequest`: the
+    /// barrier waits for the tail, and the sender is part of the tail. Tasks a
+    /// tail handler spawns inherit it, which only gives up the ordering
+    /// guarantee for them. Never `await` a `Task.detached` from a tail handler
+    /// that sends a request over this channel — it does not inherit the flag
+    /// and would wait for the handler awaiting it.
+    @TaskLocal static var isRunningOnOrderedHandlerTail = false
+
     /// Called when a complete message is received.
     /// - Note: This callback is called from a locked context; avoid long-running operations.
     var onMessageReceived: (@Sendable (Data) -> Void)?
@@ -203,9 +212,12 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
     func deliverToPendingRequest(routingKey: String, data: Data) -> Bool {
         guard let pending = pendingRequests.withLock({ $0.removeValue(forKey: routingKey) }) else {
             return false
         }
         #log(.debug, "Delivered response to pending request: \(routingKey, privacy: .public)")
         pending.cancelTimeoutTask()
-        pending.continuation.resume(returning: data)
+        // Every fire-and-forget message that arrived before this reply is on
+        // the tail by now; the requester waits for them before it continues.
+        let precedingHandlers = orderedHandlerTail.withLock { $0 }
+        pending.continuation.resume(returning: ReceivedReply(data: data, precedingHandlers: precedingHandlers))
         return true
     }
@@ -373,7 +385,7 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
         let dataToSend = data + Self.endMarkerData
 
         // Register pending request before sending
-        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
+        let reply: ReceivedReply = try await withCheckedThrowingContinuation { continuation in
             let pending = PendingRequest(continuation: continuation)
             pendingRequests.withLock { $0[nonce] = pending }
 
@@ -418,6 +430,15 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
             }
         }
 
+        // Pushes the peer sent before this reply — progress for this very
+        // request, the state syncs ahead of it — are applied before the caller
+        // continues, as they are over XPC, where each push is a round trip.
+        // Without this, a request that removes its progress route on return
+        // drops the pushes still queued on the tail.
+        if !Self.isRunningOnOrderedHandlerTail {
+            await reply.precedingHandlers.value
+        }
+        let responseData = reply.data
         #log(.debug, "Received response for: \(stamped.identifier, privacy: .public) [nonce \(nonce, privacy: .public)]")
         let response = try JSONDecoder().decode(RuntimeRequestData.self, from: responseData)
         // A peer that couldn't service the request (handler threw, or no handler
@@ -596,9 +617,11 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
     private func enqueueOrdered(_ work: @escaping @Sendable () async -> Void) {
         orderedHandlerTail.withLock { tail in
             let previous = tail
             tail = Task {
                 await previous.value
-                await work()
+                await Self.$isRunningOnOrderedHandlerTail.withValue(true) {
+                    await work()
+                }
             }
         }
     }
@@ -630,13 +653,20 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
 // MARK: - PendingRequest
 
+/// A reply as `sendRequest` receives it: the envelope, and the tail of
+/// fire-and-forget handlers that were queued when it arrived.
+private struct ReceivedReply: Sendable {
+    let data: Data
+    let precedingHandlers: Task<Void, Never>
+}
+
 /// Bookkeeping for a single in-flight request. Owns the continuation that `sendRequest`
 /// is awaiting and an optional timeout `Task` whose handle is held under a lock so the
 /// success and writer-error paths can cancel it before it has a chance to fire against a
 /// later request that registered under the same identifier.
 private final class PendingRequest: @unchecked Sendable {
-    let continuation: CheckedContinuation<Data, Error>
+    let continuation: CheckedContinuation<ReceivedReply, Error>
     private let timeoutTask = Mutex<Task<Void, Never>?>(nil)
 
-    init(continuation: CheckedContinuation<Data, Error>) {
+    init(continuation: CheckedContinuation<ReceivedReply, Error>) {
         self.continuation = continuation
     }
```
修改后，`PendingRequest` 的其余用法（超时、写入失败、`finishReceiving` 里的 `resume(throwing:)`）都不用动。超时只在等回复的阶段计时，回复交付时已经取消计时，之后等屏障不会触发超时。

**复现测试（示例）**：
- 在 `RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/ConnectionTransportRegressionTests.swift` 新增一个 suite，复用文件里现成的 `withTransportTimeout` 和 `waitUntilConnected`。
- 第一条测试修复前会红：每条推送要处理 20 ms，`sendMessage("work")` 返回时记录器里最多只有开头一两条。
- 第二条测试守住新引入的风险：如果没有 `@TaskLocal` 跳过，链上处理器发出的 `echo` 请求会等到它自己头上，从而死锁，被 watchdog 判为超时。

```swift
@Suite("Transport Regression: pushes sent before a reply", .serialized)
struct TransportReplyOrderingTests {

    private actor HandledValues {
        private(set) var values: [Int] = []
        func record(_ value: Int) { values.append(value) }
    }

    @Test("LocalSocket: pushes sent before a reply are handled before the request returns")
    func testPushesAreHandledBeforeTheReplyReturns() async throws {
        let identifier = "test-reply-barrier-\(UUID().uuidString)"
        let pushCount = 5

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.setMessageHandler(name: "work") { [weak server] (count: Int) -> Int in
            guard let server else { return 0 }
            for index in 0 ..< count {
                try await server.sendMessage(name: "tick", request: index)
            }
            return count
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let handledValues = HandledValues()
        client.setMessageHandler(name: "tick") { (value: Int) in
            // A consumer slower than the wire, like a Find window applying a batch.
            try await Task.sleep(nanoseconds: 20_000_000)
            await handledValues.record(value)
        }
        try await waitUntilConnected(server)

        let returned: Int = try await withTransportTimeout(5.0) {
            try await client.sendMessage(name: "work", request: pushCount)
        }
        let handled = await handledValues.values
        #expect(returned == pushCount)
        #expect(handled == Array(0 ..< pushCount), "the reply overtook the pushes sent before it; handled \(handled)")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    @Test("LocalSocket: a push handler that sends a request over the same connection still completes")
    func testPushHandlerRequestDoesNotDeadlockOnTheBarrier() async throws {
        let identifier = "test-reply-barrier-nested-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.setMessageHandler(name: "echo") { (value: Int) -> Int in value }
        server.setMessageHandler(name: "work") { [weak server] (value: Int) -> Int in
            try await server?.sendMessage(name: "tick", request: value)
            return value
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let handledValues = HandledValues()
        client.setMessageHandler(name: "tick") { [weak client] (value: Int) in
            guard let client else { return }
            let echoed: Int = try await client.sendMessage(name: "echo", request: value)
            await handledValues.record(echoed)
        }
        try await waitUntilConnected(server)

        let returned: Int = try await withTransportTimeout(4.0) {
            try await client.sendMessage(name: "work", request: 7)
        }
        #expect(returned == 7)
        #expect(await handledValues.values == [7])

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}
```
可选再加一条引擎级测试，用来钉住用户看得到的症状：
- 一对 `.localSocket` 引擎，服务端索引并建好 libobjc、libdispatch、libxpc 三个小镜像的语料。
- 客户端 `searchInterfaces(RuntimeInterfaceSearchQuery(text: "OS_"))`，`onProgress` 每批睡 20 ms 并累加命中数。
- 断言累加值等于 `min(summary.totalMatchCount, resultLimit)`。

**同类**：
- `objectsInImage`、`loadImageWithProgress`、语料构建的进度也会丢掉最后几条，同一改法一并解决。
- `imageList` / `imageNodes` 推送在某次请求回复之前到达的情况，也因此得到「先应用再返回」的保证。

**工作量**：S–M。只改 `RuntimeViewerCommunication`，能按已发布的依赖编译。建议和 PR121.31 一起单独开一个传输 PR 进 main，再合入 next 和 feature 分支。


### PR121.13 ObjC 协议按携带镜像重复、归属取决于索引顺序

- **严重度**：Major
- **审查编号**：C30、C33、C29，另含一处同类：Swift 类的 ObjC 面成为单独的候选
- **状态**：方案待批，代码未改

**问题**：每个按某个 ObjC 协议编译的镜像都会在自己的 `__objc_protolist` 里带一份完整副本。关系解析器在三处把这些副本当成不同的类型：
- **候选**：同名协议在每个携带镜像里各占一个名额，而 `/System/…` 按路径排在 `/usr/lib/libobjc.A.dylib` 之前。所以查 `NSObject` 时，50 个名额先被协议副本占满，真正的 NSObject 类可能被挤掉。
- **Descendant 的兄弟节点**：`visited` 只记录在子节点那一份里，所以同一层里同名协议每个携带镜像都出一个。
- **节点归属**：协议节点取的是最先建索引的那个镜像。范围剪枝按这个镜像判断，所以限定范围的结果取决于索引历史。

此外，Descendant 每一层的顺序来自字典键的顺序，每次启动都不一样。

**四问**：
- **复现**：只加载 libobjc、CoreFoundation、Foundation，查 `NSObject` 的 Descendants、候选上限设为 2，两个名额全被 CoreFoundation 和 Foundation 的协议副本占满，没有类树。按「CoreFoundation 先、Foundation 后」加载，查 `NSArray` 的 Ancestors 并限定在 Foundation，整棵树被剪光。
- **基线**：本 PR 新引入（8b4309b2）。每个镜像列出它携带的所有协议，是基线上有意保留的做法（1b5e7a33）。
- **影响**：最自然的两类关系查询（`NSObject` 的子类型、`NSView` 的祖先）结果重复或残缺，建议修。
- **历史**：8997bfea 曾在索引层把「从依赖导入的协议」过滤掉；1b5e7a33（2026-08-05）又撤掉了这个过滤，原因是 dyld 的 upward 依赖会形成环，过滤后 UIKitCore 和 Foundation 的协议一个不剩。当时的结论是：协议没有权威的定义镜像，去噪不该放在索引层。这次的去重只做在关系层、不丢任何数据，与那个结论一致。

**改法**：
- **索引层不动**。`RuntimeObjCInterfaceIndexer` 只新增一个查询 `protocolCarrierImagePaths(forName:)`，列出携带某协议的所有镜像。
- **新增静态函数 `preferredCarrierImagePath(among:referencedFrom:imagePaths:)` 决定节点代表哪一份副本**，按下面的顺序挑：
  1. 引用它的镜像（采纳它的类、或 refine 它的协议所在的镜像），前提是该镜像携带这份副本，且不在查询范围之外；
  2. 否则，取查询范围内路径排序最靠前的一份；
  3. 否则，取全部副本里路径排序最靠前的一份。

  已索引的镜像相同，结果就相同，与索引顺序无关。函数是纯函数，可以直接写单元测试。
- **范围语义改为：任一携带镜像在范围内，协议就算在范围内。** 这与侧栏照列 `__objc_protolist` 全部协议的做法一致。实现上，遍历时只使用上面的规则 1 和 3；在 `trees(for:)` 剪枝之前加一步 `movingObjCProtocolCopies(of:into:)`，把落在范围外、但范围内也有副本的节点挪到范围内的那一份上。这样范围不必在每个遍历函数之间层层传递。这个语义需要用户拍板；若选「只认引用它的镜像」，删掉这一步即可。
- **候选按名字归组**，一个协议只占一个名额，代表取规则 2、3 的结果，位置沿用第一份副本出现的位置。
- **同一处顺手修一个同类问题**：带 `.isSwiftClass` 的 ObjC 类（`_TtC…`）换成同一镜像里的 Swift 面再去重。提案 §3 本来写的就是「桥接类的去重沿用 isSwiftStable」，只是候选这一步没做到。找不到 Swift 面时保留 ObjC 面，与 `materializeObjCClass` 的回退一致（见 PR121.68）。
- **Descendant 的 refine 列表**：先按协议名归组，每个名字一个节点，副本按规则 1 选（引用镜像就是父节点所选副本的镜像）。每一层按 `displayName` 排序，与 Inspector 的子类列表一致，这同时修掉了每次启动顺序都变的问题（C29）。
- **取舍**：不在索引层去重，所以侧栏和语料照旧每个镜像列一份副本（语料里的重复命中见 PR121.72）。每次查询都要算一遍「哪些镜像携带它」，但这是对所有子 indexer 的同步字典查询，不跨 actor。
- **决策日志**：落地时记一行，见下方第三个 diff。
- **落地顺序**：本条 diff 以 12e1227b 为基准，与 PR121.66、PR121.67、PR121.69 改的是同一组函数，建议按 PR121.14 → 13 → 66 → 67 → 69 的顺序落。PR121.69 是纯重构，最后落时把本条加的 `referencedFrom:` 参数收进遍历上下文。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Indexing/RuntimeObjCInterfaceIndexer.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Indexing/RuntimeObjCInterfaceIndexer.swift
@@ -349,8 +349,25 @@ final class RuntimeObjCInterfaceIndexer: @unchecked Sendable {
             }
         }
         return nil
     }
 
+    /// Every image in this aggregate whose `__objc_protolist` carries a
+    /// protocol named `name`, this indexer's own image first. Each image that
+    /// compiled against a protocol carries a full copy and none of them owns
+    /// it (`Documentations/ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md`),
+    /// so the relationship walk chooses among these copies itself rather than
+    /// taking whichever image happened to be indexed first.
+    func protocolCarrierImagePaths(forName name: String) -> [String] {
+        var carrierImagePaths: [String] = []
+        if upstream.protocolGroup(forName: name) != nil {
+            carrierImagePaths.append(imagePath)
+        }
+        for subIndexer in subIndexers {
+            carrierImagePaths.append(contentsOf: subIndexer.protocolCarrierImagePaths(forName: name))
+        }
+        return carrierImagePaths
+    }
+
     // MARK: - Aggregation
 
     /// Register a per-image indexer with this aggregate, so the query methods
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -68,7 +68,10 @@ actor RuntimeTypeRelationshipsResolver {
                 nodes = await conformerNodes(of: candidate)
             }
             if let imagePaths = query.imagePaths {
-                let keptNodes = Self.nodes(nodes, leadingInto: imagePaths)
+                // A protocol copy outside the images moves onto a copy inside
+                // them before the tree is cut down to them.
+                let movedNodes = await movingObjCProtocolCopies(of: nodes, into: imagePaths)
+                let keptNodes = Self.nodes(movedNodes, leadingInto: imagePaths)
                 guard !keptNodes.isEmpty else { continue }
                 trees.append(RuntimeRelationshipTree(root: candidate, nodes: keptNodes))
             } else {
@@ -107,10 +110,19 @@ actor RuntimeTypeRelationshipsResolver {
 
         var exactMatches: OrderedSet<RuntimeObject> = []
         var partialMatches: OrderedSet<RuntimeObject> = []
+        // Every image compiled against an Objective-C protocol carries a copy
+        // of it. The first copy found holds the protocol's place; which copy
+        // the candidate stands for is decided once all of them are known.
+        var objcProtocolCopiesByName: [String: [RuntimeObject]] = [:]
         func consider(_ object: RuntimeObject) {
             guard Self.isRelationshipCandidate(object),
                   RuntimeInterfaceTextMatcher.typeNameMatches(object.displayName, pattern: pattern)
             else { return }
+            if object.kind == .objc(.type(.protocol)) {
+                let isFirstCopy = objcProtocolCopiesByName[object.name] == nil
+                objcProtocolCopiesByName[object.name, default: []].append(object)
+                guard isFirstCopy else { return }
+            }
             let ownName = RuntimeInterfaceTextMatcher.ownTypeName(of: object.displayName)
             if object.displayName.compare(text, options: options) == .orderedSame || ownName.compare(text, options: options) == .orderedSame {
                 exactMatches.append(object)
@@ -138,15 +150,29 @@ actor RuntimeTypeRelationshipsResolver {
             objects.forEach(considerTree)
         }
 
-        let sortedPartialMatches = partialMatches.sorted { left, right in
+        // One candidate per type: the preferred copy of a protocol, and the
+        // Swift face of a Swift class registered with the Objective-C runtime,
+        // which the Swift section lists already. An exact match wins.
+        var representedExactMatches: OrderedSet<RuntimeObject> = []
+        for object in exactMatches {
+            representedExactMatches.append(await representative(of: object, objcProtocolCopiesByName: objcProtocolCopiesByName, imagePaths: query.imagePaths))
+        }
+        var representedPartialMatches: OrderedSet<RuntimeObject> = []
+        for object in partialMatches {
+            let represented = await representative(of: object, objcProtocolCopiesByName: objcProtocolCopiesByName, imagePaths: query.imagePaths)
+            guard !representedExactMatches.contains(represented) else { continue }
+            representedPartialMatches.append(represented)
+        }
+
+        let sortedPartialMatches = representedPartialMatches.sorted { left, right in
             left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
         }
         let candidates: [RuntimeObject]
         if let imagePaths = query.imagePaths {
             func inImagesFirst(_ objects: [RuntimeObject]) -> [RuntimeObject] {
                 objects.filter { imagePaths.contains($0.imagePath) } + objects.filter { !imagePaths.contains($0.imagePath) }
             }
-            candidates = inImagesFirst(Array(exactMatches)) + inImagesFirst(sortedPartialMatches)
+            candidates = inImagesFirst(Array(representedExactMatches)) + inImagesFirst(sortedPartialMatches)
         } else {
-            candidates = Array(exactMatches) + sortedPartialMatches
+            candidates = Array(representedExactMatches) + sortedPartialMatches
         }
@@ -175,5 +201,5 @@ actor RuntimeTypeRelationshipsResolver {
         case .objc(.type(.class)):
             return await objcClassAncestorNodes(named: object.name, visited: visited, depth: depth)
         case .objc(.type(.protocol)):
-            return await objcProtocolAncestorNodes(named: object.name, visited: visited, depth: depth)
+            return await objcProtocolAncestorNodes(named: object.name, referencedFrom: object.imagePath, visited: visited, depth: depth)
         case .swift(.type(.protocol)):
@@ -189,41 +215,43 @@ actor RuntimeTypeRelationshipsResolver {
     /// An Objective-C class's ancestors: the protocols it adopts, then its
     /// superclass carrying the same for itself, recursively — the shape
     /// Xcode nests them in.
     private func objcClassAncestorNodes(named className: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard let (group, _) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className),
+        guard let (group, classImagePath) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className),
               let classInfo = group.info.first
         else { return [] }
-        var nodes = await objcProtocolNodes(named: classInfo.protocols.map(\.name), visited: visited, depth: depth + 1)
+        var nodes = await objcProtocolNodes(named: classInfo.protocols.map(\.name), referencedFrom: classImagePath, visited: visited, depth: depth + 1)
         if let superclassName = classInfo.superClassName, !superclassName.isEmpty {
             let key = "objc:" + superclassName
             if !visited.contains(key) {
                 var visited = visited
                 visited.insert(key)
                 let superclass = await materializeObjCClass(named: superclassName)
                 let children = await objcClassAncestorNodes(named: superclassName, visited: visited, depth: depth + 1)
                 nodes.append(RuntimeRelationshipNode(name: superclass?.displayName ?? superclassName, object: superclass, children: children))
             }
         }
         return nodes
     }
 
-    private func objcProtocolAncestorNodes(named protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        await objcProtocolNodes(named: objcSectionFactory.indexer.refinedProtocolNames(of: protocolName), visited: visited, depth: depth + 1)
+    private func objcProtocolAncestorNodes(named protocolName: String, referencedFrom referencingImagePath: String?, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+        await objcProtocolNodes(named: objcSectionFactory.indexer.refinedProtocolNames(of: protocolName), referencedFrom: referencingImagePath, visited: visited, depth: depth + 1)
     }
 
     /// Nodes for Objective-C protocols by name, each carrying the protocols
-    /// it adopts underneath.
-    private func objcProtocolNodes(named protocolNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+    /// it adopts underneath. `referencingImagePath` is the image whose
+    /// metadata named them — the adopting class's, or the refining
+    /// protocol's copy — and each node prefers that image's own copy.
+    private func objcProtocolNodes(named protocolNames: [String], referencedFrom referencingImagePath: String?, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
         guard depth < Self.maximumDepth else { return [] }
         var nodes: [RuntimeRelationshipNode] = []
         for protocolName in protocolNames {
             let key = "objcProtocol:" + protocolName
             guard !visited.contains(key) else { continue }
             var visited = visited
             visited.insert(key)
-            let object = await materializeObjCProtocol(named: protocolName)
-            let children = await objcProtocolAncestorNodes(named: protocolName, visited: visited, depth: depth)
+            let object = await materializeObjCProtocol(named: protocolName, referencedFrom: referencingImagePath)
+            let children = await objcProtocolAncestorNodes(named: protocolName, referencedFrom: object?.imagePath ?? referencingImagePath, visited: visited, depth: depth)
             nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? protocolName, object: object, children: children))
         }
         return nodes
     }
@@ -269,8 +297,9 @@ actor RuntimeTypeRelationshipsResolver {
     private func swiftProtocolAncestorNodes(qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
         guard depth < Self.maximumDepth else { return [] }
+        let declaringImagePath = swiftSectionFactory.indexer.protocolReference(forQualifiedName: qualifiedName)?.imagePath
         var nodes: [RuntimeRelationshipNode] = []
         for refined in swiftSectionFactory.indexer.refinedProtocols(ofQualifiedName: qualifiedName) {
             if refined.isObjC {
-                nodes += await objcProtocolNodes(named: [refined.qualifiedName], visited: visited, depth: depth + 1)
+                nodes += await objcProtocolNodes(named: [refined.qualifiedName], referencedFrom: declaringImagePath, visited: visited, depth: depth + 1)
             } else {
                 nodes += await swiftProtocolNodes(qualifiedNames: [refined.qualifiedName], visited: visited, depth: depth + 1)
@@ -314,3 +343,3 @@ actor RuntimeTypeRelationshipsResolver {
         case .objc(.type(.protocol)):
-            return await refiningProtocolNodes(ofObjCProtocolNamed: object.name, visited: visited, depth: depth)
+            return await refiningProtocolNodes(ofObjCProtocolNamed: object.name, referencedFrom: object.imagePath, visited: visited, depth: depth)
         case .swift(.type(.protocol)):
@@ -324,37 +353,45 @@ actor RuntimeTypeRelationshipsResolver {
     /// The protocols refining an Objective-C protocol: Objective-C ones from
     /// the ObjC tables, and Swift ones — a Swift protocol may refine an
     /// Objective-C protocol — from the Swift tables, which key them by the
-    /// same runtime name.
-    private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+    /// same runtime name. Every image carrying a refining protocol reports
+    /// it, so one node stands for all of its copies, and a level is listed
+    /// by name.
+    private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, referencedFrom referencingImagePath: String?, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+        var carrierImagePathsByProtocolName: OrderedDictionary<String, [String]> = [:]
+        for reference in objcSectionFactory.indexer.refiningProtocols(of: protocolName) {
+            carrierImagePathsByProtocolName[reference.protocolName, default: []].append(reference.imagePath)
+        }
         var nodes: [RuntimeRelationshipNode] = []
-        for reference in objcSectionFactory.indexer.refiningProtocols(of: protocolName) {
-            let key = "objcProtocol:" + reference.protocolName
-            guard !visited.contains(key) else { continue }
+        for (refiningProtocolName, carrierImagePaths) in carrierImagePathsByProtocolName {
+            let key = "objcProtocol:" + refiningProtocolName
+            guard !visited.contains(key),
+                  let carrierImagePath = Self.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: referencingImagePath, imagePaths: nil)
+            else { continue }
             var visited = visited
             visited.insert(key)
-            let object = await objcSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forProtocolName: reference.protocolName)
-            let children = await refiningProtocolNodes(ofObjCProtocolNamed: reference.protocolName, visited: visited, depth: depth + 1)
-            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.protocolName, object: object, children: children))
+            let object = await objcSectionFactory.existingSection(for: carrierImagePath)?.makeRuntimeObject(forProtocolName: refiningProtocolName)
+            let children = await refiningProtocolNodes(ofObjCProtocolNamed: refiningProtocolName, referencedFrom: carrierImagePath, visited: visited, depth: depth + 1)
+            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? refiningProtocolName, object: object, children: children))
         }
         nodes += await swiftRefiningProtocolNodes(of: protocolName, visited: visited, depth: depth)
-        return nodes
+        return Self.sortedByName(nodes)
     }
 
     private func refiningProtocolNodes(ofSwiftProtocolNamed qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
         await swiftRefiningProtocolNodes(of: qualifiedName, visited: visited, depth: depth)
     }
 
     private func swiftRefiningProtocolNodes(of name: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
         guard depth < Self.maximumDepth else { return [] }
         var nodes: [RuntimeRelationshipNode] = []
         for reference in swiftSectionFactory.indexer.refiningProtocols(ofQualifiedName: name) {
             let key = "swiftProtocol:" + reference.qualifiedName
             guard !visited.contains(key) else { continue }
             var visited = visited
             visited.insert(key)
             let object = await swiftSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forMangledProtocolName: reference.mangledName)
             let children = await swiftRefiningProtocolNodes(of: reference.qualifiedName, visited: visited, depth: depth + 1)
             nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.qualifiedName, object: object, children: children))
         }
-        return nodes
+        return Self.sortedByName(nodes)
     }
@@ -382,5 +419,8 @@ actor RuntimeTypeRelationshipsResolver {
 
-    private func materializeObjCProtocol(named protocolName: String) async -> RuntimeObject? {
-        guard let (_, imagePath) = objcSectionFactory.indexer.protocolGroupAcrossImages(forName: protocolName) else { return nil }
-        return await objcSectionFactory.existingSection(for: imagePath)?.makeRuntimeObject(forProtocolName: protocolName)
+    /// The `RuntimeObject` for the copy of an Objective-C protocol a node
+    /// stands for; see `preferredCarrierImagePath(among:referencedFrom:imagePaths:)`.
+    private func materializeObjCProtocol(named protocolName: String, referencedFrom referencingImagePath: String?) async -> RuntimeObject? {
+        let carrierImagePaths = objcSectionFactory.indexer.protocolCarrierImagePaths(forName: protocolName)
+        guard let carrierImagePath = Self.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: referencingImagePath, imagePaths: nil) else { return nil }
+        return await objcSectionFactory.existingSection(for: carrierImagePath)?.makeRuntimeObject(forProtocolName: protocolName)
     }
@@ -397,5 +437,84 @@ actor RuntimeTypeRelationshipsResolver {
 
     private func visitedKey(for object: RuntimeObject) -> String {
         "\(object.kind)|\(object.name)"
     }
+
+    // MARK: - Objective-C Protocol Copies
+
+    /// The copy of an Objective-C protocol a node stands for. Every image
+    /// compiled against a protocol carries a full copy and none of them owns
+    /// it, so the choice only has to be stable — the same indexed images give
+    /// the same copy whatever order they were indexed in: the copy of the
+    /// image whose metadata named the protocol, when it carries one and the
+    /// query's images do not leave it out; then the first copy by path among
+    /// the query's images; then the first copy by path.
+    static func preferredCarrierImagePath(among carrierImagePaths: [String], referencedFrom referencingImagePath: String?, imagePaths scopeImagePaths: Set<String>?) -> String? {
+        if let referencingImagePath,
+           carrierImagePaths.contains(referencingImagePath),
+           scopeImagePaths?.contains(referencingImagePath) ?? true {
+            return referencingImagePath
+        }
+        if let scopeImagePaths,
+           let firstCarrierInScope = carrierImagePaths.filter({ scopeImagePaths.contains($0) }).min() {
+            return firstCarrierInScope
+        }
+        return carrierImagePaths.min()
+    }
+
+    /// A query limited to some images counts an Objective-C protocol as
+    /// theirs when any of them carries a copy, the way their sidebar lists
+    /// it: a node standing for a copy outside them moves onto the first copy
+    /// inside them, so cutting the tree down to them keeps it.
+    private func movingObjCProtocolCopies(of nodes: [RuntimeRelationshipNode], into imagePaths: Set<String>) async -> [RuntimeRelationshipNode] {
+        var movedNodes: [RuntimeRelationshipNode] = []
+        movedNodes.reserveCapacity(nodes.count)
+        for node in nodes {
+            let children = await movingObjCProtocolCopies(of: node.children, into: imagePaths)
+            var object = node.object
+            if let protocolObject = object,
+               protocolObject.kind == .objc(.type(.protocol)),
+               !imagePaths.contains(protocolObject.imagePath),
+               let carrierImagePath = Self.preferredCarrierImagePath(
+                   among: objcSectionFactory.indexer.protocolCarrierImagePaths(forName: protocolObject.name),
+                   referencedFrom: nil,
+                   imagePaths: imagePaths
+               ),
+               imagePaths.contains(carrierImagePath),
+               let movedObject = await objcSectionFactory.existingSection(for: carrierImagePath)?.makeRuntimeObject(forProtocolName: protocolObject.name) {
+                object = movedObject
+            }
+            movedNodes.append(RuntimeRelationshipNode(name: node.name, object: object, children: children))
+        }
+        return movedNodes
+    }
+
+    /// The object a candidate stands for: the preferred copy of an
+    /// Objective-C protocol, and the Swift face of a Swift class registered
+    /// with the Objective-C runtime — the face the sidebar, the Inspector and
+    /// every node of the walk show. A class with no Swift face to pair it
+    /// with keeps its Objective-C one, as `materializeObjCClass(named:)` does.
+    private func representative(of object: RuntimeObject, objcProtocolCopiesByName: [String: [RuntimeObject]], imagePaths scopeImagePaths: Set<String>?) async -> RuntimeObject {
+        switch object.kind {
+        case .objc(.type(.protocol)):
+            let copies = objcProtocolCopiesByName[object.name] ?? [object]
+            let preferredImagePath = Self.preferredCarrierImagePath(among: copies.map(\.imagePath), referencedFrom: nil, imagePaths: scopeImagePaths)
+            return copies.first { $0.imagePath == preferredImagePath } ?? object
+        case .objc(.type(.class)) where object.properties.contains(.isSwiftClass):
+            return await swiftSectionFactory.existingSection(for: object.imagePath)?.makeRuntimeObject(forObjCRuntimeClassName: object.name) ?? object
+        default:
+            return object
+        }
+    }
+
+    /// A level of Descendant Types listed by name, the way the Inspector
+    /// lists subclasses. Left alone it would follow the dictionary order of
+    /// the library's protocol table, which changes with every launch, and
+    /// the order the images were indexed in.
+    private static func sortedByName(_ nodes: [RuntimeRelationshipNode]) -> [RuntimeRelationshipNode] {
+        nodes.sorted { left, right in
+            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
+            guard comparison == .orderedSame else { return comparison == .orderedAscending }
+            return String(describing: left.object?.kind) < String(describing: right.object?.kind)
+        }
+    }
 }
```
```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -756,0 +757,1 @@
+| <落地日期> | 关系树里一个 ObjC 协议只出一个节点：候选与 Descendant 的兄弟节点按名字归组；节点代表哪份副本按「引用它的镜像 → 范围内路径最小 → 全部路径最小」选，限定范围时任一携带镜像在范围内即算在内；Descendant 每层按名字排序；Swift 类的 ObjC 面换成 Swift 面后再参与候选 | 每个按某协议编译的镜像都带一份完整副本，没有权威的定义镜像（2026-08-05 的 ResolvedIssue）。按副本计数时，`NSObject` 的协议副本挤掉了 NSObject 类，兄弟节点重复，归属还跟着索引顺序变。去重放在关系层而不是索引层，侧栏照旧列全部副本，不丢数据。层内顺序原本来自字典键，每次启动都不同。 |
```

**复现测试（示例）**：
- **新建测试文件** `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeTypeRelationshipsProtocolCopyTests.swift`，只用 libobjc、CoreFoundation、Foundation 三个加载快的镜像，每个用例自建引擎并自己控制加载顺序。
  - 前提：macOS 27.0 导出里，`NSObject`、`NSSecureCoding` 等协议同时由 CoreFoundation 和 Foundation 携带。`requireCarried` 在系统不再这样时让测试明确失败，而不是什么也没测就通过。
  - 各用例修复前的结果：
    - 第一条：两个名额被协议副本占满，变红。
    - 第二条：`NSSecureCoding` 出现两次，变红。
    - 第三条：两个引擎把协议归到不同镜像，变红。
    - 第四条：整棵树被剪掉，`#require` 失败。
    - 第五条：层内顺序跟着字典键走，多于 5 个时恰好有序的概率可以忽略，变红。
    - 第六条：ObjC 面自成一棵树，变红。
- **补一条单元测试**：在 `RuntimeTypeRelationshipsImageScopeTests.swift`（已用 `@testable import`）里测选副本的纯函数。

```swift
import Foundation
import Testing
import RuntimeViewerCore

/// Every image compiled against an Objective-C protocol carries a full copy
/// of it. A relationship search shows one node per protocol, whichever images
/// carry it and whatever order they were indexed in.
@Suite("Relationship trees over Objective-C protocol copies", .serialized)
struct RuntimeTypeRelationshipsProtocolCopyTests {
    private enum Anchors {
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
        static let coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    private static func makeEngine(_ label: String, loading imagePaths: [String]) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-protocol-copies-" + label)
        try await engine.connect()
        for imagePath in imagePaths {
            try await engine.loadImage(at: imagePath)
        }
        return engine
    }

    /// Fails loudly when the system stops carrying the copies a test relies
    /// on, instead of letting it pass over nothing.
    private static func requireCarried(_ protocolName: String, by imagePaths: [String], in engine: RuntimeEngine) async throws {
        for imagePath in imagePaths {
            let objects = try await engine.objects(in: imagePath)
            try #require(objects.contains { $0.name == protocolName && $0.kind == .objc(.type(.protocol)) }, "\(imagePath) no longer carries \(protocolName)")
        }
    }

    private static func everyLevel(of nodes: [RuntimeRelationshipNode]) -> [[RuntimeRelationshipNode]] {
        [nodes] + nodes.flatMap { everyLevel(of: $0.children) }
    }

    @Test("an Objective-C protocol several images carry is one candidate")
    func protocolCopiesAreOneCandidate() async throws {
        let engine = try await Self.makeEngine("candidates", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        try await Self.requireCarried("NSObject", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true, candidateLimit: 2))

        // Before: both slots went to CoreFoundation's and Foundation's copies
        // of the protocol, which sort ahead of /usr/lib.
        #expect(trees.contains { $0.root.kind == .objc(.type(.class)) && $0.root.imagePath == Anchors.libobjcPath })
        #expect(trees.count { $0.root.kind == .objc(.type(.protocol)) } == 1)
    }

    @Test("a protocol refining another is one node however many images carry it")
    func refiningProtocolCopiesAreOneNode() async throws {
        let engine = try await Self.makeEngine("refining", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        try await Self.requireCarried("NSSecureCoding", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSCoding", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root.name == "NSCoding" })

        #expect(tree.nodes.count { $0.name == "NSSecureCoding" } == 1)
        for level in Self.everyLevel(of: tree.nodes) {
            let identities = level.map { "\(String(describing: $0.object?.kind))|\($0.name)" }
            #expect(Set(identities).count == identities.count, "\(identities)")
        }
    }

    @Test("which copy a node stands for does not depend on the order images were indexed in")
    func copiesDoNotFollowIndexingOrder() async throws {
        let coreFoundationFirst = try await Self.makeEngine("core-foundation-first", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        let foundationFirst = try await Self.makeEngine("foundation-first", loading: [Anchors.libobjcPath, Anchors.foundationPath, Anchors.coreFoundationPath])
        let query = RuntimeTypeRelationshipsQuery(text: "NSString", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true)

        let coreFoundationFirstTrees = try await coreFoundationFirst.typeRelationships(query)
        let foundationFirstTrees = try await foundationFirst.typeRelationships(query)
        let coreFoundationFirstTree = try #require(coreFoundationFirstTrees.first { $0.root.name == "NSString" })
        let foundationFirstTree = try #require(foundationFirstTrees.first { $0.root.name == "NSString" })

        // Before: NSSecureCoding and the rest went to whichever carrier was
        // indexed first — CoreFoundation in one engine, Foundation in the other.
        #expect(coreFoundationFirstTree == foundationFirstTree)
        let secureCoding = try #require(coreFoundationFirstTree.nodes.first { $0.name == "NSSecureCoding" })
        #expect(secureCoding.object?.imagePath == coreFoundationFirstTree.root.imagePath)
    }

    @Test("a search limited to some images keeps a protocol any of them carries")
    func limitedSearchKeepsProtocolsItsImagesCarry() async throws {
        let engine = try await Self.makeEngine("limited", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        try await Self.requireCarried("NSSecureCoding", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: engine)
        let foundationImagePath = try #require(try await engine.objects(in: Anchors.foundationPath).first?.imagePath)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSArray", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true, imagePaths: [Anchors.foundationPath]))

        // NSArray is CoreFoundation's; the protocols it adopts are carried by
        // both images. Before: every one went to CoreFoundation, indexed
        // first, and the whole tree was cut away.
        let tree = try #require(trees.first { $0.root.name == "NSArray" })
        let secureCoding = try #require(tree.nodes.first { $0.name == "NSSecureCoding" })
        #expect(secureCoding.object?.imagePath == foundationImagePath)
    }

    @Test("the protocols refining a protocol are listed by name")
    func refiningProtocolsAreListedByName() async throws {
        let engine = try await Self.makeEngine("order", loading: [Anchors.libobjcPath, Anchors.foundationPath])
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root.kind == .objc(.type(.protocol)) })
        try #require(tree.nodes.count >= 5)

        for level in Self.everyLevel(of: tree.nodes) {
            let names = level.map(\.name)
            let sortedNames = names.sorted { left, right in left.localizedCaseInsensitiveCompare(right) == .orderedAscending }
            #expect(names == sortedNames, "\(names)")
        }
    }

    @Test("a Swift class registered with the Objective-C runtime is one candidate, under its Swift face")
    func swiftClassObjCFaceIsNotACandidate() async throws {
        let engine = try await Self.makeEngine("objc-face", loading: [Anchors.libobjcPath, Anchors.foundationPath])
        let objcFaces = try await engine.objects(in: Anchors.foundationPath).filter { $0.kind == .objc(.type(.class)) && $0.properties.contains(.isSwiftClass) }
        let objcFace = try #require(objcFaces.first, "Foundation registers no Swift class with the Objective-C runtime")

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: objcFace.name, matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true))

        // Before: the Objective-C face was a candidate of its own, with a
        // tree that differs from its Swift face's.
        #expect(!trees.isEmpty)
        #expect(!trees.contains { $0.root.kind == .objc(.type(.class)) && $0.root.properties.contains(.isSwiftClass) })
    }
}
```
```swift
// RuntimeTypeRelationshipsImageScopeTests.swift — the rule on its own, no images.
@Test("the copy of an Objective-C protocol a node stands for")
func preferredCarrierImagePath() {
    let carriers = ["/images/B", "/images/A", "/images/C"]
    // The image that named the protocol, when it carries one.
    #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carriers, referencedFrom: "/images/C", imagePaths: nil) == "/images/C")
    // Otherwise the first carrier by path.
    #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carriers, referencedFrom: "/images/D", imagePaths: nil) == "/images/A")
    // A limited query never leaves its images for the referencing one.
    #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carriers, referencedFrom: "/images/C", imagePaths: ["/images/B"]) == "/images/B")
    // No carrier inside the images: the first carrier by path, cut later.
    #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carriers, referencedFrom: nil, imagePaths: ["/images/X"]) == "/images/A")
}
```

**同类**：
- **已并入本条**：
  - Swift 类的 ObjC 面成为单独候选（上面 diff 里的 `representative(of:…)`）；
  - Descendant 层内顺序（C29）。
- **查过、不需要改**：
  - Inspector 用的 `RuntimeRelationshipsResolver` 按名字查遵循者和子类，不受副本影响；
  - Ancestor 里类和协议的顺序来自元数据，本来就是确定的。
- **语料里的同类重复不在本条**：每个携带镜像的协议副本、每个 Swift 类的 ObjC 面都单独建一条语料，所以 Text 和 Members 搜索会重复命中。这部分见 PR121.72。

**工作量**：M。本条 diff 以 12e1227b 为基准，不依赖其它条目。它与 PR121.66、PR121.67、PR121.69 改的是同一组函数，后落的一条需要机械变基。


### PR121.14 父类是绑定泛型的 Swift 类，Ancestor 树被截断

- **严重度**：Major
- **审查编号**：C32
- **状态**：方案待批，代码未改

**问题**：`RuntimeSwiftInterfaceIndexer.prepare()` 把父类的类型名 demangle 后再 remangle，用结果作父类键（`RuntimeSwiftInterfaceIndexer.swift:280-285`）。如果父类绑定了泛型实参（例如 `NSHostingController<SettingsView>`），这个键是绑定后的名字，而类型表的键是泛型定义本身的名字（:269-270），两者永远对不上。

结果有两处：
- **Ancestor Types**：在父类这一层停住，只剩一个灰色、不可点的 `SwiftUI.NSHostingController`。
- **Descendant Types 和 Inspector 的 Relationships**：都列不出这个子类，因为子类表也是按绑定键存的。

**四问**：
- **复现**：只加载 AppKit，查 `UpdateMenuAction` 的 Ancestors，父类节点没有解析出来；它在 macOS 27 上声明为 `UpdateMenuAction: AppKit.IncrementalUpdateAction<AppKit.Menu, AppKit.MenuItem>`。查 `IncrementalUpdateAction` 的 Descendants，以及在 Inspector 里看它的 Relationships，都没有 `UpdateMenuAction`。
- **基线**：
  - Ancestor 这一半由本 PR 引入（8b4309b2）；
  - Descendant 和 Inspector 这一半来自 c3eb2735，当时加的是 Inspector 的关系 API，origin/main 和 origin/next 上都有。
- **影响**：受影响的是所有 `NSHostingController<…>` / `NSHostingView<…>` 的子类，以及大量 SwiftUI、AppKit 内部类型，建议修。
- **历史**：c3eb2735 做 remangle 往返，是为了让父类键和子类键落在同一个命名空间里，但没有考虑绑定泛型。提案只记了另一个缺口：ObjC 类的泛型 Swift 子类没有 `class_t`，因此列不出来。

**改法**：
- **父类键去掉泛型实参**：新增 `unspecializedNominalTypeNode(of:)`，剥掉外层 `boundGeneric…` 的包装，并把绑定了实参的外层类型（`Outer<Int>.Inner`）也还原成未绑定形式，再 mangle，得到的就是类型表用的键。
  - swift-demangling 已经有通用实现 `getUnspecialized`，但它是 internal 的；父类一定是名义类型，所以在本地写一个窄版本，不为此改上游。
- **子类表同时登记两个键**：未绑定键让泛型定义查得到子类；原来的绑定键保留，用户特化出来的类型（名字就是绑定后的名字）查子类的行为保持不变。两个键相同时只登记一次。
- **Ancestor 落到泛型定义上**：`superclassMangledNameByMangledName` 改存未绑定键。节点名仍是泛型类自己的显示名，不显示实参。
- **ObjC 回退改为按名查找，不再从显示名去猜**：
  - 现状是用打印出来的名字取最后一段，再去找同名的 ObjC 类。这种做法对泛型 Swift 父类一定找不到，还可能撞上一个无关的同名 ObjC 类。
  - 改为在 `prepare()` 里，父类属于 `__C` 模块时记下它的运行时类名，解析器只拿这个名字查找。
  - 顺手删掉一个永远为假的检查 `!visited.contains("unresolved:" + displayName)`：这个键从来没有被插入过。
- **Inspector 这一半同批修**：两半读的是同一张表，这次改动同时修好两边。如果 3.0 正式版要在 Find 合进 main 之前发布，可以从 main 单独切一个只改子类表的小分支。它只依赖已发布的版本，可以直接走 PR。
- **取舍**：`prepare()` 只对绑定了泛型的父类多做一次 mangle，非泛型父类的 helper 直接返回 `nil`，不增加开销。
- **提案同步**：表格里「父类链」一行补一句说明，决策日志记一行。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Indexing/RuntimeSwiftInterfaceIndexer.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Indexing/RuntimeSwiftInterfaceIndexer.swift
@@ -146,11 +146,20 @@ final class RuntimeSwiftInterfaceIndexer: @unchecked Sendable {
-    /// Mangled class name → mangled name of its superclass, for every class
-    /// with one, plus the superclass's printed name for the case where the
-    /// superclass is not a Swift type this aggregate knows (an Objective-C
-    /// class, or one in an unindexed image). Recorded by `prepare()` while
-    /// building the subclass table, which already resolves the superclass.
+    /// Mangled class name → mangled name of its superclass, for every class
+    /// with one — the generic type itself when the superclass is bound to
+    /// arguments, since that is the name the type tables know it by — plus
+    /// the superclass's printed name for the case where the superclass is
+    /// not a Swift type this aggregate knows (an Objective-C class, or one in
+    /// an unindexed image). Recorded by `prepare()` while building the
+    /// subclass table, which already resolves the superclass.
     @Mutex
     private var superclassMangledNameByMangledName: [String: String] = [:]
 
     @Mutex
     private var superclassDisplayNameByMangledName: [String: String] = [:]
 
+    /// The runtime name of that superclass when it is an imported
+    /// Objective-C class (`__C.NSView`), for the relationship walk to look it
+    /// up by. Never derived from the printed name, which names Swift classes
+    /// too — and a generic one without its arguments.
+    @Mutex
+    private var superclassObjCClassNameByMangledName: [String: String] = [:]
+
@@ -242,3 +251,4 @@ final class RuntimeSwiftInterfaceIndexer: @unchecked Sendable {
         var superclassMangledNameTable: [String: String] = [:]
         var superclassDisplayNameTable: [String: String] = [:]
+        var superclassObjCClassNameTable: [String: String] = [:]
         var refinedProtocolsTable: [String: OrderedSet<RuntimeSwiftRefinedProtocol>] = [:]
@@ -275,18 +285,34 @@ final class RuntimeSwiftInterfaceIndexer: @unchecked Sendable {
             // Round-trip through demangle + remangle so the superclass key
             // sits in the same canonical string space as the child key
             // (`mangleAsString(typeName.node)`), which is also how the
             // relationships pipeline derives the lookup key from a target
             // Swift class.
             guard let superclassNode = try? SymbolicDemangler.demangleType(for: superclassMangled, in: machO.context),
                   let superclassKey = try? await mangleAsString(superclassNode)
             else { continue }
+            // A superclass bound to generic arguments
+            // (`NSHostingController<SettingsView>`) is filed under the generic
+            // type as well: that is where the type tables, Descendant Types
+            // and the Inspector look for it. The bound key stays for a type
+            // the user specialized, whose name is the bound one.
+            var unspecializedSuperclassKey: String?
+            if let unspecializedSuperclassNode = Self.unspecializedNominalTypeNode(of: superclassNode) {
+                unspecializedSuperclassKey = try? await mangleAsString(unspecializedSuperclassNode)
+            }
             subclassTable[superclassKey, default: []].append(childKey)
-            superclassMangledNameTable[childKey] = superclassKey
+            if let unspecializedSuperclassKey, unspecializedSuperclassKey != superclassKey {
+                subclassTable[unspecializedSuperclassKey, default: []].append(childKey)
+            }
+            superclassMangledNameTable[childKey] = unspecializedSuperclassKey ?? superclassKey
             superclassDisplayNameTable[childKey] = await superclassNode.print(using: .interfaceTypeBuilderOnly)
+            if let objcClassName = Self.importedObjCClassName(of: superclassNode) {
+                superclassObjCClassNameTable[childKey] = objcClassName
+            }
         }
         subclassesBySuperclassMangledName = subclassTable
         typeNameByMangledName = typeNameTable
         protocolNameByMangledName = protocolNameTable
         superclassMangledNameByMangledName = superclassMangledNameTable
         superclassDisplayNameByMangledName = superclassDisplayNameTable
+        superclassObjCClassNameByMangledName = superclassObjCClassNameTable
         refinedProtocolsByQualifiedName = refinedProtocolsTable
@@ -329,4 +355,53 @@ final class RuntimeSwiftInterfaceIndexer: @unchecked Sendable {
         return result
     }
 
+    /// The nominal type a type node instantiates, with every generic argument
+    /// removed and spelled the way that type's own descriptor demangles —
+    /// `NSHostingController<SettingsView>` becomes `NSHostingController`, and
+    /// a bound enclosing type is unbound too (`Outer<Int>.Inner`). `nil` when
+    /// nothing in it is bound, which is the case for every non-generic
+    /// superclass. swift-demangling's `getUnspecialized` does this for every
+    /// node kind but is internal to that library; a superclass is always a
+    /// nominal type, so this covers what can occur here.
+    private static func unspecializedNominalTypeNode(of typeNode: Node) -> Node? {
+        guard let nominalNode = unspecializedNominalNode(of: typeNode) else { return nil }
+        return Node.create(kind: .type, children: [nominalNode])
+    }
+
+    /// `unspecializedNominalTypeNode(of:)` below the `type` wrapper.
+    private static func unspecializedNominalNode(of node: Node) -> Node? {
+        switch node.kind {
+        case .type:
+            return node.firstChild.flatMap(unspecializedNominalNode(of:))
+        case .boundGenericClass, .boundGenericStructure, .boundGenericEnum, .boundGenericOtherNominalType, .boundGenericTypeAlias:
+            guard let unboundTypeNode = node.firstChild,
+                  let nominalNode = unboundTypeNode.kind == .type ? unboundTypeNode.firstChild : unboundTypeNode
+            else { return nil }
+            return unspecializedNominalNode(of: nominalNode) ?? nominalNode
+        case .class, .structure, .enum, .otherNominalType, .typeAlias:
+            guard let contextNode = node.firstChild,
+                  let unspecializedContextNode = unspecializedNominalNode(of: contextNode)
+            else { return nil }
+            return Node.create(kind: node.kind, children: [unspecializedContextNode] + Array(node.children.dropFirst()))
+        default:
+            return nil
+        }
+    }
+
+    /// The runtime name of the Objective-C class a type node names — a class
+    /// of the Clang importer's `__C` module, such as the `NSView` a Swift view
+    /// subclasses — or `nil` for any other type.
+    private static func importedObjCClassName(of typeNode: Node) -> String? {
+        var node = typeNode
+        while node.kind == .type, let childNode = node.firstChild {
+            node = childNode
+        }
+        guard node.kind == .class,
+              let moduleNode = node.firstChild,
+              moduleNode.kind == .module,
+              moduleNode.text == "__C"
+        else { return nil }
+        return node[safeChild: 1]?.text
+    }
+
     // MARK: - Relationship Query
@@ -470,4 +545,18 @@ final class RuntimeSwiftInterfaceIndexer: @unchecked Sendable {
         return nil
     }
 
+    /// The runtime name of the superclass of the class with this mangled
+    /// name, when that superclass is an imported Objective-C class.
+    func superclassObjCClassName(forMangledTypeName mangledName: String) -> String? {
+        if let name = superclassObjCClassNameByMangledName[mangledName] {
+            return name
+        }
+        for subIndexer in subIndexers {
+            if let name = subIndexer.superclassObjCClassName(forMangledTypeName: mangledName) {
+                return name
+            }
+        }
+        return nil
+    }
+
     /// The protocols `qualifiedName` refines, from the image declaring it.
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -231,5 +231,7 @@ actor RuntimeTypeRelationshipsResolver {
     /// A Swift struct's, enum's, actor's or class's ancestors: the protocols
     /// it conforms to, then — for a class — its superclass with the same
-    /// underneath. A superclass no Swift image defines is looked up as an
-    /// Objective-C class by its printed name before it is given up on.
+    /// underneath. A superclass bound to generic arguments is the generic
+    /// class itself. One no Swift image defines is looked up as an
+    /// Objective-C class when it is an imported one, and left unresolved
+    /// otherwise.
     private func swiftTypeAncestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
@@ -254,13 +256,13 @@ actor RuntimeTypeRelationshipsResolver {
 
         let displayName = indexer.superclassDisplayName(forMangledTypeName: object.name) ?? superclassMangledName
-        let simpleName = displayName.components(separatedBy: ".").last ?? displayName
-        if let objcSuperclass = await materializeObjCClass(named: simpleName) {
+        if let objcClassName = indexer.superclassObjCClassName(forMangledTypeName: object.name),
+           let objcSuperclass = await materializeObjCClass(named: objcClassName) {
             guard !visited.contains(visitedKey(for: objcSuperclass)) else { return nodes }
             var visited = visited
             visited.insert(visitedKey(for: objcSuperclass))
             let children = await ancestorNodes(of: objcSuperclass, visited: visited, depth: depth + 1)
             nodes.append(RuntimeRelationshipNode(object: objcSuperclass, children: children))
-        } else if !visited.contains("unresolved:" + displayName) {
+        } else {
             nodes.append(RuntimeRelationshipNode(name: displayName, object: nil, children: []))
         }
         return nodes
```
```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -256,1 +256,1 @@
-  | 父类链 | `classGroup.info`（自身在前，父类逐级，跨镜像已解析） | `classDescriptor.superclassTypeMangledName(in:)` 逐级 demangle + remangle（与 `RuntimeSwiftInterfaceIndexer.prepare` 建子类表的钥匙同一空间） |
+  | 父类链 | `classGroup.info`（自身在前，父类逐级，跨镜像已解析） | `classDescriptor.superclassTypeMangledName(in:)` 逐级 demangle + remangle（与 `RuntimeSwiftInterfaceIndexer.prepare` 建子类表的钥匙同一空间）；绑定了泛型实参的父类按泛型类型本身登记，导入的 ObjC 父类另记运行时类名 |
@@ -756,0 +757,1 @@
+| <落地日期> | 父类绑定了泛型实参时，按去掉实参后的泛型类型登记父类与子类关系（子类表同时保留绑定键）；Swift 父类不在任何已索引镜像时，只在它是导入的 ObjC 类时按运行时名去 ObjC 那边找 | 原来的键是绑定后的名字，类型表里永远查不到：`NSHostingController<SettingsView>` 的子类在 Ancestor 里断在灰色叶子上，Descendant 和 Inspector 里也列不出来，后者在 main 上就有。按打印名取最后一段去猜 ObjC 类，对泛型父类一定落空，还可能撞上同名的无关 ObjC 类。 |
```

**复现测试（示例）**：新建测试文件 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeTypeRelationshipsGenericSuperclassTests.swift`，只加载 AppKit。
- **锚点**：`UpdateMenuAction` 是 AppKit 自己的 Swift 类，父类是 `IncrementalUpdateAction<Menu, MenuItem>`（来自 macOS 27.0 导出）。锚点属于 AppKit 内部实现，会随系统版本变化，所以先 `#require` 能找到它。
- **修复前**：第一条断言拿到的父类节点 `object == nil`，第二、三条找不到这个子类，全部变红；其中第三条在 main 上同样是红的。
- **没有覆盖的部分**：`Outer<Int>.Inner` 这类嵌套绑定在系统里没找到现成的例子。为 helper 单独写单元测试需要给测试 target 加 `Demangling` 依赖，也就是要改 manifest，本条不加，留作已知未覆盖。

```swift
import Testing
import RuntimeViewerCore

/// A Swift class whose superclass is a generic class bound to arguments
/// reaches that generic class in Ancestor Types, and is listed among its
/// subclasses in Descendant Types and in the Inspector.
@Suite("Relationships through a bound generic superclass", .serialized)
struct RuntimeTypeRelationshipsGenericSuperclassTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-generic-superclass-" + label)
        try await engine.connect()
        try await engine.loadImage(at: appKitPath)
        return engine
    }

    /// `UpdateMenuAction: IncrementalUpdateAction<Menu, MenuItem>`, both
    /// AppKit's own Swift classes on macOS 27. AppKit-internal, so they are
    /// required rather than assumed.
    private static func anchors(in engine: RuntimeEngine) async throws -> (subclass: RuntimeObject, genericSuperclass: RuntimeObject) {
        func everyObject(_ objects: [RuntimeObject]) -> [RuntimeObject] {
            objects.flatMap { [$0] + everyObject($0.children) }
        }
        func ownName(_ object: RuntimeObject) -> String {
            object.displayName.components(separatedBy: ".").last ?? object.displayName
        }
        let objects = everyObject(try await engine.objects(in: appKitPath)).filter { $0.kind == .swift(.type(.class)) }
        let subclass = try #require(objects.first { ownName($0) == "UpdateMenuAction" }, "AppKit no longer has UpdateMenuAction")
        let genericSuperclass = try #require(objects.first { ownName($0).hasPrefix("IncrementalUpdateAction") }, "AppKit no longer has IncrementalUpdateAction")
        return (subclass, genericSuperclass)
    }

    @Test("Ancestor Types reach the generic class a bound superclass instantiates")
    func ancestorsReachTheGenericSuperclass() async throws {
        let engine = try await Self.makeEngine("ancestors")
        let (subclass, genericSuperclass) = try await Self.anchors(in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "UpdateMenuAction", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root == subclass })

        // Before: an unresolved leaf named after the generic class, with
        // nothing above it.
        let superclassNode = try #require(tree.nodes.first { $0.name.contains("IncrementalUpdateAction") })
        #expect(superclassNode.object == genericSuperclass)
    }

    @Test("the generic class lists the subclass, in Descendant Types and in the Inspector")
    func genericSuperclassListsTheSubclass() async throws {
        let engine = try await Self.makeEngine("descendants")
        let (subclass, genericSuperclass) = try await Self.anchors(in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "IncrementalUpdateAction", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root == genericSuperclass })
        #expect(tree.nodes.contains { $0.object == subclass })

        // The Inspector reads the same table; before, it missed the subclass
        // on main as well.
        #expect(try await engine.relationships(for: genericSuperclass).subclasses.contains(subclass))
    }
}
```

**同类**：
- **一并修好**：Inspector 用的 `RuntimeRelationshipsResolver` 查 Swift 子类时读的就是同一张子类表。
- **没有别的同类**：全仓库搜过，没有别处拿绑定后的类型名当查找键。按打印名猜 ObjC 类的写法只有这一处。
- **现有快照不受影响**：`RelationshipsEquivalenceSnapshotTests` 只查 ObjC 子类和协议遵循者，结果不会变。

**工作量**：M。不依赖其它条目，建议第一个落。PR121.69 改的也是 `swiftTypeAncestorNodes` 的这几行；本条先落的话，PR121.69 变基时那几行以本条为准。


### PR121.15 正则的 ^ / $ 不按行匹配

- **严重度**：Minor
- **审查编号**：C23
- **状态**：方案待批，代码未改

**问题**：文本搜索把一个条目的整段多行接口交给正则，编译时却没加 `.anchorsMatchLines`（`RuntimeInterfaceTextMatcher.swift:49`），所以 `^` 和 `$` 只匹配整段接口的开头和结尾，而结果是按行报告的。`^@property`、`^\s*func\s`、`;$` 这类按「声明形状」找东西的写法全部返回 0 条结果，界面也不提示原因；只有 `^@interface` 因为碰巧是接口第一行而能用。
**四问**：复现——Find › Text › Regular Expression 搜 `^@property`，任何 Objective-C 语料都是 0 条；基线——本 PR 新引入（8b4309b2）；影响——用锚点按形状找声明是常见用法，Xcode 的 Find 也按行处理 `^` / `$`，改动只有一个选项，建议修；历史——新代码，现有带锚点的测试都只在单行的成员名或类型名上跑。

**改法**：
- 编译选项加 `.anchorsMatchLines`。同一个 `Pattern` 还用于成员名和类型名，它们都是单行文本，加了这个选项不会有任何变化。
- 提案 §3.1 现在仍写着用 Swift `Regex`，与实现不符，顺手改成实际做法，并在决策日志记一行。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
@@ -46,7 +46,10 @@ enum RuntimeInterfaceTextMatcher {
             guard !text.isEmpty else { throw PatternError.emptyQuery }
             if matchMode == .regularExpression {
                 do {
-                    self.regex = try NSRegularExpression(pattern: text, options: isCaseSensitive ? [] : [.caseInsensitive])
+                    // `^` and `$` anchor at line boundaries, as in Xcode's Find:
+                    // an entry is a whole multi-line interface while a hit is
+                    // reported on its line. Member and type names are one line.
+                    self.regex = try NSRegularExpression(pattern: text, options: isCaseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
                 } catch {
                     throw PatternError.invalidRegularExpression("\(error)")
                 }
```
```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -199,4 +199,4 @@
 - 匹配：对每个条目在 `frozen.text` 的 UTF-8 上做 ASCII case-folding 子串扫描（非 ASCII 字节精确匹配）；span 游标随扫描
   推进，命中时 O(1) 取语义类别做域过滤；行号 / 行文本由命中偏移向两侧找 `\n`。Starting With / Ending With 以标识符
-  字符类 `[A-Za-z0-9_$]` 判边界，Matching Word 两侧都判。Regular Expression 模式对每个条目的 `text` 跑 Swift `Regex`
-  （`text` 是现成 `String`，逐条目取消）。
+  字符类 `[A-Za-z0-9_$]` 判边界，Matching Word 两侧都判。Regular Expression 模式对每个条目的 `text` 跑
+  `NSRegularExpression`（引擎的部署目标早于 Swift `Regex`），`^` / `$` 按行锚定，与 Xcode 的 Find 一致。
@@ -756,0 +757,1 @@
+| <落地日期> | 正则的 `^` / `$` 按行锚定（`.anchorsMatchLines`） | 条目是整段多行接口，结果却按行报告；不按行时 `^@property`、`;$` 这类写法永远是 0 条。Xcode 的 Find 按行处理。成员名与类型名是单行，不受影响。 |
```

**复现测试（示例）**：放在 `RuntimeViewerCoreTests/RuntimeInterfaceTextMatcherTests.swift`，用文件里现成的五行样例接口和 `matches(_:)` 辅助函数（第 2 行是 `    var fooBar: Int`，第 4 行是 `    func barFoo()`）。修复前 `^` 只能匹配整段开头的 `class`，`$` 只能匹配结尾的 `}`，两个断言的计数都是 0，测试红。
```swift
@Test("^ and $ anchor at the lines of a multi-line interface")
func regularExpressionAnchorsMatchLines() throws {
    let variableLines = try matches(RuntimeInterfaceSearchQuery(text: #"^\s+var\s"#, matchMode: .regularExpression, isCaseSensitive: true))
    #expect(variableLines.count == 1)
    #expect(variableLines.matches.first?.lineNumber == 2)

    let functionLineEnds = try matches(RuntimeInterfaceSearchQuery(text: #"\(\)$"#, matchMode: .regularExpression, isCaseSensitive: true))
    #expect(functionLineEnds.count == 1)
    #expect(functionLineEnds.matches.first?.lineNumber == 4)
}
```
现有的成员名与类型名正则用例（`^member(Alpha|Gamma)$`、`load$`、`^load`、`^SwiftUI\\.V`）不需要改动，作为「单行名字不受影响」的回归保护。如果 PR121.06 先落地，`matches(_:)` 辅助函数会多一个预算参数，这里跟着改调用即可。

**同类**：全仓库搜过所有正则的创建点，用户输入的正则跑在多行文本上的只有这一处。其余三处都不受影响：`RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/SwiftStdlib+.swift:141` 和 `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/TransformerSettingsView.swift:407` 是不带锚点的固定模式；`RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Execution/CommandExecutor.swift:134` 的 Swift `Regex` 只匹配单行的类型名。
**工作量**：S；不依赖其它条目。与 PR121.06 改的是同一个文件的不同位置，合并时只有提案的决策日志相邻。


### PR121.16 CorpusBuildTimingProbe target 被合了进来

- **严重度**：Cleanup
- **审查编号**：C37
- **状态**：方案待批，代码未改

**问题**：`RuntimeViewerCore/Package.swift:261-268` 声明了可执行目标 `CorpusBuildTimingProbe`，源码在 `Sources/CorpusBuildTimingProbe/`，共 390 行，来自 d1c3cb57。这是为 Find 语料构建计时用的探针，提交说明里写着「Not to be merged: drop this commit when the branch is delivered」，提案 `draft-find-navigator.md:94` 也写了「不合入」。没有产品依赖它，App 不受影响；代价只是每次 `swift build` / `swift test` RuntimeViewerCore 都要多编它，Xcode 里也多出一个 scheme。

**四问**：
- **复现**：在 PR 分支上执行 `git grep -n CorpusBuildTimingProbe RuntimeViewerCore/Package.swift`，能命中这个 target。
- **基线**：本 PR 新引入。
- **影响**：只影响构建时间和 scheme 列表，建议修，因为这正是提交作者自己定的交付条件。
- **历史**：探针是刻意只留在分支上的；交付时漏了删除这一步。

**改法**：
- **用新提交删除**：用一个新提交删掉 target 声明和源码目录，不改写已推送的历史，所以 d1c3cb57 仍可取回。
- **改提案第 94 行**：写明已移除，以及源码在哪个提交。2026-09-30 那条决策用到的计量仍可复现，所以不动它。
- **可选做法**：把探针挪进一个不发布的开发用包，继续保留。本条建议直接删除，因为与提交说明一致，计量也只在优化期间用。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Package.swift
+++ b/RuntimeViewerCore/Package.swift
@@ -258,14 +258,6 @@ let package = Package(
                 .product(name: "LaunchServicesPrivate", package: "LaunchServicesPrivate"),
             ],
         ),
-        // Branch-only measurement tool for the Find corpus build
-        // (draft-find-navigator §1.1). Never merged.
-        .executableTarget(
-            name: "CorpusBuildTimingProbe",
-            dependencies: [
-                "RuntimeViewerCore",
-            ],
-        ),
         .testTarget(
             name: "RuntimeViewerCoreTests",
             dependencies: [
```

```diff
--- a/RuntimeViewerCore/Sources/CorpusBuildTimingProbe/CorpusBuildTimingProbe.swift
+++ /dev/null
@@ -1,390 +0,0 @@
-import Darwin
-import Foundation
-import RuntimeViewerCore
-
-/// Times the Find corpus build and the content pane's printing, per image and
-// … (lines 6–390 of the file are deleted the same way; the whole directory goes)
```

```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -94,4 +94,5 @@
-**计量先行**：分支专属的可执行目标 `CorpusBuildTimingProbe`（`RuntimeViewerCore/Sources/CorpusBuildTimingProbe/`，不合入）：
+**计量先行**：分支专属的可执行目标 `CorpusBuildTimingProbe`（`RuntimeViewerCore/Sources/CorpusBuildTimingProbe/`，交付时已移除；
+源码留在提交 `d1c3cb57`，`git show d1c3cb57` 可取回，用法见该提交说明）：
 `corpus` 模式计真实构建，`display <preset>` 模式按预设选项经内容区路径打印全部对象，预设两两相减得到每个选项的代价；
 `--top-level-only` 量出嵌套重复的份额。每个预设各起一个进程。Release 下对 Foundation / SwiftUI / libswiftCore 各测一遍，
 优化前后的数字记入决策日志。
```

**复现测试（示例）**：行为不变，无需新测试，由现有的 RuntimeViewerCoreTests 覆盖。只需确认两件事：
- RuntimeViewerCore 仍能编译；
- `git grep -n CorpusBuildTimingProbe` 只剩提案里的历史引用（第 94、716 行）。

改 manifest 会触发 SwiftPM 重新解析。依赖没有变化，所以锁文件也不该变；若变了，就回滚锁文件。
```sh
queued-build swift build --package-path RuntimeViewerCore \
    --scratch-path /Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerCore-FindNavigator 2>&1 | xcsift
echo "exit ${pipestatus[1]}"
git grep -n CorpusBuildTimingProbe
```

**同类**：无。PR 里没有其它标着「不合入」的 target 或文件。`git grep -n -i 'never merged\|not to be merged\|do not merge\|branch-only'` 只命中三处：这个 target 的注释、探针源码的文件注释，以及 AGENTS.md 里讲分支模型的两句。

**工作量**：S，无依赖。


### PR121.17 VerifyAcrossXcodes 没跟上 bridge 的接口

- **严重度**：Minor
- **审查编号**：B5
- **状态**：方案待批，代码未改

**问题**：`Stubs/VerifyAcrossXcodes.swift` 的职责，是在每个已安装的 Xcode 上加载 SourceEditor bridge 并跑完它的全部接口。可它手抄的协议里（第 41 行）还是已删除的 `scrollToCharacterIndex(_:)`。c3ad0839 把这个方法换成了 `revealCharacterRange(_:)`，后者第一次用到四个私有 API：
- `ScrollPlacement`，一个 resilient enum，case 序号由声明顺序决定；
- `positionFromInternalCharOffset(_:lineHint:)`；
- `selectTextRange(_:scrollPlacement:alwaysScroll:)`；
- `showCallout(for:)`。

脚本按名字匹配 Objective-C 协议，只调用自己抄的那些方法，所以照样全绿。这四个 API 在其它 Xcode 版本上调用起来是否正常，从没被验证过。

**四问**：
- **复现**：`grep -n scrollToCharacterIndex Stubs/VerifyAcrossXcodes.swift` 命中第 41 行；脚本里没有任何对 `revealCharacterRange` 的调用。
- **基线**：本 PR 新引入。c3ad0839 改了接口，没改脚本。
- **影响**：不影响用户，是验证覆盖的缺口，建议修。符号是否存在，加载时已经会检查（`Stubs/README.md:59-62`）；但 enum 的 case 序号对不对、排队的滚动和 callout 会不会出错，只有真正调用才会暴露。
- **历史**：脚本由 d7e9f67d（2026-09-16）建立，提案 0009 规定它要在每个已安装 Xcode 上跑完整功能面。那时 `scrollToCharacterIndex` 还是 TODO，新接口落地时没人同步这个脚本。

**改法**：
- **最小修法**：
  - 协议副本改成 `revealCharacterRange(_:)`。
  - 在 "layout + display" 之后加两步：一次正常范围，一次文本末尾的空范围（callout 会把空范围扩成整行，位置查找会落在最后一个字符之后）。
  - 每步之后让主 run loop 转 0.5 秒，让排队的滚动和 callout 动画真正执行。
- **流程上**：`Stubs/README.md` 写明「bridge 新调用的东西，同一次改动里也要在脚本里调用」。
- **可选的结构性修法**（推荐与最小修法一起做，工作量仍是 S）：脚本不再手抄协议，改为和真正的 `SourceEditorBridging.swift` 一起编译。这个文件只 import AppKit，自成一体。这样以后改名、删 requirement，脚本都会直接编译失败，不会再「静默全绿」。代价是每次运行先编一次，约十几秒。

**拟修改**：
```diff
--- a/Stubs/VerifyAcrossXcodes.swift
+++ b/Stubs/VerifyAcrossXcodes.swift
@@ -38,7 +38,7 @@ protocol SourceEditorBridging: NSObjectProtocol {
     )
     func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: NSFont)
     func applyTopContentInset(_ topInset: CGFloat)
-    func scrollToCharacterIndex(_ characterIndex: Int)
+    func revealCharacterRange(_ characterRange: NSRange)
 }
 
 func report(_ message: String) { print("OK   \(message)") }
@@ -167,5 +167,19 @@
 editorView.layoutSubtreeIfNeeded()
 editorView.display()
 report("layout + display")
 
+// The Find navigator's reveal: a position lookup, then a selection with a scroll placement and
+// the callout. `ScrollPlacement` is a resilient enum passed by case index, and both calls queue
+// work, so the run loop has to turn for the queued scroll and the callout to run at all.
+let revealedRange = NSRange(swiftSource.range(of: "probeValue")!, in: swiftSource)
+bridge.revealCharacterRange(revealedRange)
+RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
+report("revealCharacterRange")
+
+// An empty range at the very end of the text: the callout widens it to its line, and the
+// position lookup lands one past the last character.
+bridge.revealCharacterRange(NSRange(location: (swiftSource as NSString).length, length: 0))
+RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
+report("revealCharacterRange at the end of the text")
+
 print("DONE")
```

```diff
--- a/Stubs/README.md
+++ b/Stubs/README.md
@@ -160,5 +160,10 @@
 real class, `SourceEditorScrollView`, is Objective-C with no header here. The cost is that a
 selector missing from some Xcode fails when it is sent, not when the bridge loads — which is
 what `VerifyAcrossXcodes.sh` is for.
 
+**Whatever the bridge newly calls, `VerifyAcrossXcodes.swift` calls too, in the same change.**
+The script drives only what its protocol lists, so a requirement added or renamed without it stays
+green and is never exercised against another Xcode. `revealCharacterRange(_:)` went unexercised
+that way until the PR #121 review.
+
 ## When two Xcodes disagree on a requirement's signature
```

可选的结构性修法：脚本与真正的协议文件一起编译，并删掉脚本里那份协议副本。采用它时，上面第一个 hunk 里协议那一行就不用改了，因为整段副本会被删掉。
```diff
--- a/Stubs/VerifyAcrossXcodes.sh
+++ b/Stubs/VerifyAcrossXcodes.sh
@@ -54,4 +54,12 @@
 fi
 
+# Compiled once, together with the bridge's real protocol declaration rather than a copy of it, so
+# a renamed or removed requirement fails to compile here instead of leaving the probe green.
+verifier_directory="$(mktemp -d)"
+trap 'rm -rf "$verifier_directory"' EXIT
+cp VerifyAcrossXcodes.swift "$verifier_directory/main.swift"
+xcrun swiftc -o "$verifier_directory/VerifyAcrossXcodes" "$verifier_directory/main.swift" \
+    ../RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/SourceEditorBridging.swift
+
 failures=0
 for xcode_path in "${xcode_paths[@]}"; do
@@ -66,5 +74,3 @@
-    # `swift` rather than a compiled binary: the probe is 150 lines and runs three times, so the
-    # ~10s of compiling it each time is cheaper than a build product to keep track of.
-    if ! xcrun swift VerifyAcrossXcodes.swift "$xcode_path" "$bundle_path"; then
+    if ! "$verifier_directory/VerifyAcrossXcodes" "$xcode_path" "$bundle_path"; then
         failures=$((failures + 1))
     fi
```

```diff
--- a/Stubs/VerifyAcrossXcodes.swift
+++ b/Stubs/VerifyAcrossXcodes.swift
@@ -20,27 +20,6 @@
 let xcodeURL = URL(fileURLWithPath: CommandLine.arguments[1])
 let bundleURL = URL(fileURLWithPath: CommandLine.arguments[2])
 
-/// Declared here rather than imported: the app and the bundle meet through the Objective-C
-/// runtime, which matches this protocol to the bundle's conformance by name.
-@objc(RuntimeViewerSourceEditorBridging)
-protocol SourceEditorBridging: NSObjectProtocol {
-    var editorView: NSView { get }
-    func setSource(_ source: String, languageIdentifier: String, semanticRanges: [NSValue], semanticNodeTypeNames: [String])
-    func applyBackgroundColor(_ backgroundColor: NSColor)
-    func applyDisplayOptions(
-        showsLineNumbers: Bool,
-        showsFoldingRibbon: Bool,
-        showsStickyHeaders: Bool,
-        showsMinimap: Bool,
-        showsScopeGuides: Bool,
-        showsInvisibles: Bool,
-        showsMarkSeparators: Bool
-    )
-    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: NSFont)
-    func applyTopContentInset(_ topInset: CGFloat)
-    func scrollToCharacterIndex(_ characterIndex: Int)
-}
-
 func report(_ message: String) { print("OK   \(message)") }
 
 func fail(_ message: String) -> Never {
```

**复现（验证命令）**：这是覆盖缺口，修前不会变红，红绿体现在「修后每个 Xcode 都打出新的两行 OK」。
- 用本地构建出的 bridge bundle，对本机所有 Xcode 各跑一遍（上次是 26.6 / 27.0 / 27.1 / 27.2）。
- 每个版本都必须打出 `OK   revealCharacterRange` 和 `OK   revealCharacterRange at the end of the text`。
- 采用结构性修法后，「接口改名、脚本编译失败」本身就是长期护栏。

脚本会起 AppKit 窗口。按 Dock 残留图标的规则，收尾时先数终端登记的进程数，达到 5 个才运行 `killall Dock`。
```sh
cd Stubs
./VerifyAcrossXcodes.sh "<DerivedData>/Build/Products/<配置>/RuntimeViewerSourceEditorBridge.bundle"
echo "exit $?"
```

**同类**：
- 协议里还有两个属性，脚本的副本一直没有列，也从没设置过：`navigationDelegate` 和 `minimapLandmarkIconProvider`。这是基线就有的同类缺口。建议一并在脚本里各设一个空实现，让 ⌘-点击和 minimap 地标的路径在每个 Xcode 上也走一遍；采用结构性修法后，这两个属性自然就在协议里了。
- `RuntimeViewerSourceEditorBridgeTests` 只验证链接形态，而且只对一个 Xcode，覆盖不了跨版本，这正是脚本存在的原因。

**工作量**：S。若 PR121.47 改动 `revealCharacterRange` 的签名或语义，要同步改这里；采用结构性修法后，这种遗漏会直接编译失败。


### PR121.18 AppDefaults 的 UserDefaults 在测试之间共享

- **严重度**：Minor
- **审查编号**：AL3
- **状态**：已修复。复现测试：`AppDefaultsIsolationTests`（前三条修前红，后两条守住新机制不留残留）、`ContentTextPipelineTests.liveDependencyContextResolvesIsolatedAppDefaults`（修前红）
- **落地与偏离**：
  - **没有按下文给每个实例一个 suite**：实测 `removePersistentDomain(forName:)` 只清空域、不删文件，`~/Library/Preferences` 里已有 45 个其它测试这样留下的 42 字节空 plist；一次测试运行会建上百个隔离实例，就会再留上百个。2026-10-01 提案决策日志当初也是因为这个代价才没走 suite 方案而改用锁。落地做法：所有隔离实例共用一个 suite（`RuntimeViewer.AppDefaults.Isolated`），各自用带进程号和 UUID 的键前缀（`UserDefaultsNamespace`）；KVO 按键通知，互不可见；实例释放时删自己的键；从没释放的实例（`testFallback`、泄漏、崩溃）留下的键，由下一个进程在第一次用到这个 suite 时按「进程已结束」清掉，同时在跑的另一个测试进程不受影响。生产实例仍是 `.standard`、键名不变。
  - **`SidebarAutosaveKeyCleanup` 只对标准域执行**，而不是改为对隔离 suite 执行：它清的是 `StatefulOutlineView` 写在标准域里的条目，隔离命名空间里没有，执行只会多写一个标记。
  - **「另记」那条核实为不成立**：`ContentTextPipelineTests` 有自己的私有 `withLiveDependencyContext`，自 429476a0 起就把 `\.settings` 覆盖成内存里的 `SettingsAccess.preview`，`liveSettings()` 碰不到真实的 `settings.json`（本批每次跑测试前后该文件 SHA 均为 `d811d35e…` 未变）。**但反过来的问题是真的**：这个私有辅助函数遮蔽了全局的同名函数，却没有固定 `\.appDefaults`，所以这个套件里的 ViewModel 解析到的是生产实例 `AppDefaults.shared`（真实的 `Application Support/AppStorage` 书签目录和测试进程的标准域）。d42aff4c 只改了全局那个。已一并修：私有辅助函数也固定隔离实例，复现测试即上面的第二个名字。

**问题**：测试用 `AppDefaults.isolated()` 拿到「隔离」的实例，但它只隔离了书签文件。四个 `@UserDefault` 属性（`options`、`filterMode`、两个迁移标志）没有传 `suite`，全都落在 `UserDefaults.standard` 上，因为 RxDefaultsPlus 的 `UserDefault` 默认就是 `suite: .standard`。后果有三：
- **写入互相可见**：`$options` 是对 `generationOptions` 这一个键的 KVO（键值观察），一个测试写入，所有存活的 FindSession 都会以为用户改了选项，于是重跑搜索。
- **跨运行残留**：写入的值留在测试进程的默认域里，跨运行残留。
- **锁没覆盖全**：本 PR 为此加了 `withSharedGenerationOptionsLock`，但 FindViewModelTests:383-400 和 FindCorpusCoordinatorTests 的一条（:76 附近）都在等搜索结果，却没拿锁，因此会偶发失败。

**四问**：
- **复现**：
  - 偶发形式：上面两条测试与 FindGenerationOptionsTests 并行时，结果偶尔被重跑的搜索打乱。
  - 确定性形式：下面三条新测试，修前全红。
- **基线**：基线已有。共享从 21df7df8 引入 `isolated()` 时就存在，基线的 ContentTextPipelineTests 一直靠这个共享把选项写入传给 ViewModel。本 PR 新增的 FindSession 会订阅 `$options` 并重跑搜索，这让共享有了后果；锁是本 PR 的 8ce77d36 加的。
- **影响**：只影响测试稳定性和测试进程默认域的卫生，不影响用户，建议修。
- **历史**：8ce77d36 用锁绕开了这个问题，只修了表面。凡是新写的「等搜索结果」的测试都得记得拿锁，已经漏了两处。

**改法**：
- **根治隔离，不再补锁**：`AppDefaults` 的初始化方法增加 `userDefaultsSuiteName`，四个包装器统一建在这个 suite 上。
  - 生产实例不传，仍用 `.standard`，行为不变。
  - 命名 suite 在创建时清空，实例释放时删除。
  - 测试用的 `isolated()` 每次用一个带 UUID 的 suite 名。
  - `testFallback` 用固定名：它是静态实例，永不释放，用 UUID 会每次运行留下一个偏好文件；固定名在创建时清空即可。
- **同一处做法**：`SidebarAutosaveKeyCleanup.runIfNeeded` 改为对同一个 suite 执行，这样隔离实例也不再改测试进程的标准域。
- **测试侧随之改**：删掉 `SharedGenerationOptionsTestLock.swift` 和它的四处调用。
- **一个必须同批改的连带**：ContentTextPipelineTests 那条「失败后改选项能恢复」的测试，是通过另一个隔离实例写选项、借共享默认域传给 ViewModel 的。根治之后这条路断了，所以要改成让 ViewModel 与测试使用同一个实例。
- **测试代码里随之失效的两处**：
  - `originalOptions` 的保存与还原：每个实例的默认域已经独立，不必还原。
  - SidebarSearchCaseSensitivityTests 开头为防上次运行残留而重置 `filterMode` 的那段：残留已不可能，一并删除。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/AppDefaults.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/AppDefaults.swift
@@ -17,11 +17,16 @@ import OrderedCollections
 public final class AppDefaults: @unchecked Sendable {
     fileprivate static let shared = AppDefaults(storageDirectoryURL: applicationSupportStorageDirectoryURL)
 
     /// The store handed out when `\.appDefaults` is resolved from a test
     /// context without an explicit `withDependencies` override — typically a
     /// cell ViewModel that a sidebar pipeline builds on a GCD thread, where no
     /// task-local override can reach. Lives in a throwaway temporary directory
-    /// so a stray test access can never touch the user's files.
+    /// and a user defaults suite of its own, so a stray test access can never
+    /// touch the user's files or the standard defaults every other instance in
+    /// a test process would otherwise share. The suite name is fixed rather
+    /// than unique: this instance is never released, so a unique name would
+    /// leave a preferences file behind on every run. The initializer empties it.
     fileprivate static let testFallback = AppDefaults(
-        storageDirectoryURL: makeTemporaryStorageDirectoryURL(label: "test-fallback")
+        storageDirectoryURL: makeTemporaryStorageDirectoryURL(label: "test-fallback"),
+        userDefaultsSuiteName: "RuntimeViewer.AppDefaults.test-fallback"
     )
@@ -42,18 +47,48 @@ public final class AppDefaults: @unchecked Sendable {
     static func makeTemporaryStorageDirectoryURL(label: String) -> URL {
         FileManager.default.temporaryDirectory
             .appendingPathComponent("RuntimeViewer.AppDefaults.\(label).\(UUID().uuidString)", isDirectory: true)
     }
 
+    /// A fresh, unique user defaults suite name, for the same isolated
+    /// instances: their Generation Options, filter mode and migration flags
+    /// must not be the ones every other instance in the process reads.
+    static func makeTemporaryUserDefaultsSuiteName(label: String) -> String {
+        "RuntimeViewer.AppDefaults.\(label).\(UUID().uuidString)"
+    }
+
     /// Creates a defaults store whose bookmark files live under
-    /// `storageDirectoryURL`.
+    /// `storageDirectoryURL` and whose user defaults live in the suite named
+    /// `userDefaultsSuiteName` — the standard defaults when it is `nil`.
     ///
     /// Production only ever uses the single Application Support instance
     /// behind `DependencyValues.appDefaults`. The initializer is `internal` so
     /// the package's tests can build isolated instances that point at a
     /// directory the app never reads: the storage path is not scoped by bundle
     /// identifier and the app is not sandboxed, so a test that resolved the
     /// shared instance would read and overwrite the user's real bookmark
     /// files. The one-time migrations read their legacy files from the same
     /// directory, so an isolated instance migrates nothing.
-    init(storageDirectoryURL: URL?) {
+    ///
+    /// The suite matters as much as the directory: `$options` observes a
+    /// single user defaults key, so instances sharing the standard defaults
+    /// hear each other's writes — a Find session in one test reran its search
+    /// whenever another test changed the options. A named suite is emptied
+    /// here and removed again in `deinit`.
+    init(storageDirectoryURL: URL?, userDefaultsSuiteName: String? = nil) {
+        let userDefaults: UserDefaults
+        if let userDefaultsSuiteName {
+            guard let suite = UserDefaults(suiteName: userDefaultsSuiteName) else {
+                preconditionFailure("\(userDefaultsSuiteName) cannot name a user defaults suite")
+            }
+            suite.removePersistentDomain(forName: userDefaultsSuiteName)
+            userDefaults = suite
+        } else {
+            userDefaults = .standard
+        }
+        ownedUserDefaultsSuiteName = userDefaultsSuiteName
+        _options = UserDefault(key: "generationOptions", defaultValue: .init(), suite: userDefaults)
+        _filterMode = UserDefault(key: "filterMode", defaultValue: nil, suite: userDefaults)
+        _bookmarkMigrationCompleted = UserDefault(key: "bookmarkMigrationCompleted", defaultValue: false, suite: userDefaults)
+        _bookmarkScopeMigrationCompleted = UserDefault(key: "bookmarkScopeMigrationCompleted", defaultValue: false, suite: userDefaults)
+
         if let storageDirectoryURL {
@@ -70,21 +105,30 @@ public final class AppDefaults: @unchecked Sendable {
         // ViewModels reach for `@Dependency(\.appDefaults)` on the way up.
-        SidebarAutosaveKeyCleanup.runIfNeeded(flagKey: Self.sidebarAutosaveCleanupFlagKey)
+        SidebarAutosaveKeyCleanup.runIfNeeded(userDefaults: userDefaults, flagKey: Self.sidebarAutosaveCleanupFlagKey)
 
         guard let storageDirectoryURL else { return }
         migrateFlatBookmarkArraysIfNeeded(in: storageDirectoryURL)
         migrateBookmarksToScopeKeysIfNeeded(in: storageDirectoryURL)
     }
 
+    deinit {
+        guard let ownedUserDefaultsSuiteName else { return }
+        _options.suite.removePersistentDomain(forName: ownedUserDefaultsSuiteName)
+    }
+
     static let sidebarAutosaveCleanupFlagKey = "sidebarAutosaveKeyCleanupCompleted"
 
-    @UserDefault(key: "generationOptions", defaultValue: .init())
+    /// The suite this instance's user defaults live in when it is not the
+    /// standard one; removed again in `deinit`.
+    private let ownedUserDefaultsSuiteName: String?
+
+    @UserDefault
     public var options: RuntimeObjectInterface.GenerationOptions
 
-    @UserDefault(key: "filterMode", defaultValue: nil)
+    @UserDefault
     public var filterMode: FilterMode?
 
-    @UserDefault(key: "bookmarkMigrationCompleted", defaultValue: false)
+    @UserDefault
     private var bookmarkMigrationCompleted: Bool
 
-    @UserDefault(key: "bookmarkScopeMigrationCompleted", defaultValue: false)
+    @UserDefault
     private var bookmarkScopeMigrationCompleted: Bool
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Support/ViewModelTestEnvironment.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Support/ViewModelTestEnvironment.swift
@@ -52,8 +52,11 @@ struct ViewModelTestEnvironment {
 extension AppDefaults {
-    /// A store in a fresh temporary directory, so instances built by tests
-    /// running in parallel never see each other's files, and nothing from an
-    /// earlier run leaks in.
+    /// A store in a fresh temporary directory and a fresh user defaults
+    /// suite, so instances built by tests running in parallel never see each
+    /// other's files or options, and nothing from an earlier run leaks in.
     static func isolated() -> AppDefaults {
-        AppDefaults(storageDirectoryURL: makeTemporaryStorageDirectoryURL(label: "isolated"))
+        AppDefaults(
+            storageDirectoryURL: makeTemporaryStorageDirectoryURL(label: "isolated"),
+            userDefaultsSuiteName: makeTemporaryUserDefaultsSuiteName(label: "isolated")
+        )
     }
 }
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/SharedGenerationOptionsTestLock.swift
+++ /dev/null
@@ -1,27 +0,0 @@
-import Foundation
-
-/// Cross-suite mutual exclusion for the Generation Options every
-/// `AppDefaults` in the process shares.
-///
-/// `AppDefaults.options` is a `@UserDefault` on `UserDefaults.standard`,
-/// whatever directory an isolated instance keeps its files in, and its
-/// projected value is a key-value observation of that one key — so a write
-/// from any test reaches every live subscriber in every suite. A Find session
-/// takes such a write for the user changing the options and runs its search
-/// again, which turns "the results were merged into, not replaced" into a
-/// race with whichever suite toggled the options last.
-///
-/// Wrap both kinds of test in `withSharedGenerationOptionsLock`:
-/// - tests that WRITE `appDefaults.options`, and
-/// - tests whose assertions an options change would invalidate.
-private let sharedGenerationOptionsTestLock = CrossSuiteTestLock()
-
-func withSharedGenerationOptionsLock<Result>(_ body: () async throws -> Result) async rethrows -> Result {
-    await sharedGenerationOptionsTestLock.acquire()
-    defer {
-        Task {
-            await sharedGenerationOptionsTestLock.release()
-        }
-    }
-    return try await body()
-}
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindGenerationOptionsTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindGenerationOptionsTests.swift
@@ -36,44 +36,36 @@ struct FindGenerationOptionsTests {
 
-        // The options are shared by every test in the process; see
-        // `withSharedGenerationOptionsLock`.
-        try await withSharedGenerationOptionsLock {
-            // `appDefaults.options` is backed by the shared user defaults, so it
-            // is changed only around the searches and restored right after.
-            let appDefaults = environment.appDefaults
-            let originalOptions = appDefaults.options
-            defer { appDefaults.options = originalOptions }
-
-            var strippingOptions = RuntimeObjectInterface.GenerationOptions()
-            strippingOptions.objcHeaderOptions.stripSynthesizedIvars = true
-            strippingOptions.objcHeaderOptions.stripSynthesizedMethods = true
-            appDefaults.options = strippingOptions
-
-            let strippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
-            #expect(strippedIvarLines.isEmpty, "the stripped ivar is found: \(strippedIvarLines.map(\.lineText))")
-
-            let strippedMembers = Self.memberMatches(in: try await search(FindQuery(mode: .members, text: "value", isCaseSensitive: true), with: session))
-            #expect(!strippedMembers.contains { $0.member.kind == .objcIvar && $0.member.name == "_value" }, "the stripped ivar is a member match")
-            #expect(!strippedMembers.contains { $0.member.kind == .objcMethod && $0.member.name == "value" }, "the stripped getter is a member match")
-            #expect(strippedMembers.contains { $0.member.kind == .objcProperty && $0.member.name == "value" }, "the property itself is shown and should be found")
-
-            // Every line a search reports is a line the content pane shows.
-            var displayOptions = strippingOptions
-            displayOptions.transformer = environment.settings.transformer
-            let displayedInterface = try #require(try await engine.interface(for: queryItem, options: displayOptions))
-            let displayedLines = Set(displayedInterface.interfaceString.string.components(separatedBy: "\n"))
-            let valueLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "value", isCaseSensitive: true), with: session))
-            #expect(!valueLines.isEmpty)
-            for match in valueLines {
-                #expect(displayedLines.contains(match.lineText), "not a line the content pane shows: \(match.lineText)")
-            }
-
-            // Stop stripping: found at the next search, from the same corpus.
-            appDefaults.options = RuntimeObjectInterface.GenerationOptions()
-            let unstrippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
-            #expect(!unstrippedIvarLines.isEmpty, "the ivar is shown again but not found")
-            let unstrippedMembers = Self.memberMatches(in: try await search(FindQuery(mode: .members, text: "value", isCaseSensitive: true), with: session))
-            #expect(unstrippedMembers.contains { $0.member.kind == .objcIvar && $0.member.name == "_value" })
-            #expect(unstrippedMembers.contains { $0.member.kind == .objcMethod && $0.member.name == "value" })
-            #expect(try await engine.interfaceCorpusCoverage().statesByImagePath[TestImages.foundation] == builtState, "the corpus was built again")
-        }
+        // The environment's own store: no other test reads these options.
+        let appDefaults = environment.appDefaults
+        var strippingOptions = RuntimeObjectInterface.GenerationOptions()
+        strippingOptions.objcHeaderOptions.stripSynthesizedIvars = true
+        strippingOptions.objcHeaderOptions.stripSynthesizedMethods = true
+        appDefaults.options = strippingOptions
+
+        let strippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
+        #expect(strippedIvarLines.isEmpty, "the stripped ivar is found: \(strippedIvarLines.map(\.lineText))")
+
+        let strippedMembers = Self.memberMatches(in: try await search(FindQuery(mode: .members, text: "value", isCaseSensitive: true), with: session))
+        #expect(!strippedMembers.contains { $0.member.kind == .objcIvar && $0.member.name == "_value" }, "the stripped ivar is a member match")
+        #expect(!strippedMembers.contains { $0.member.kind == .objcMethod && $0.member.name == "value" }, "the stripped getter is a member match")
+        #expect(strippedMembers.contains { $0.member.kind == .objcProperty && $0.member.name == "value" }, "the property itself is shown and should be found")
+
+        // Every line a search reports is a line the content pane shows.
+        var displayOptions = strippingOptions
+        displayOptions.transformer = environment.settings.transformer
+        let displayedInterface = try #require(try await engine.interface(for: queryItem, options: displayOptions))
+        let displayedLines = Set(displayedInterface.interfaceString.string.components(separatedBy: "\n"))
+        let valueLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "value", isCaseSensitive: true), with: session))
+        #expect(!valueLines.isEmpty)
+        for match in valueLines {
+            #expect(displayedLines.contains(match.lineText), "not a line the content pane shows: \(match.lineText)")
+        }
+
+        // Stop stripping: found at the next search, from the same corpus.
+        appDefaults.options = RuntimeObjectInterface.GenerationOptions()
+        let unstrippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
+        #expect(!unstrippedIvarLines.isEmpty, "the ivar is shown again but not found")
+        let unstrippedMembers = Self.memberMatches(in: try await search(FindQuery(mode: .members, text: "value", isCaseSensitive: true), with: session))
+        #expect(unstrippedMembers.contains { $0.member.kind == .objcIvar && $0.member.name == "_value" })
+        #expect(unstrippedMembers.contains { $0.member.kind == .objcMethod && $0.member.name == "value" })
+        #expect(try await engine.interfaceCorpusCoverage().statesByImagePath[TestImages.foundation] == builtState, "the corpus was built again")
 
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindSessionCorpusTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindSessionCorpusTests.swift
@@ -21,33 +21,28 @@ struct FindSessionCorpusTests {
         _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }
 
-        // A write to the shared Generation Options from another suite would
-        // make the session search again from scratch, which is exactly what
-        // this test proves does not happen when a corpus arrives.
-        try await withSharedGenerationOptionsLock {
-            let session = documentState.findSession
-            session.run(FindQuery(mode: .text, text: "NSObject"))
-            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
-            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
-
-            var sawResultsCleared = false
-            let disposeBag = DisposeBag()
-            session.$results.asDriver()
-                .driveOnNext { results in
-                    if results.nodes.isEmpty { sawResultsCleared = true }
-                }
-                .disposed(by: disposeBag)
-
-            // Opening Foundation is what brings its corpus in after the search.
-            try await engine.loadImage(at: TestImages.foundation)
-
-            let widened = try await nextValue(from: session.$results.asDriver(), timeout: 180) { results in
-                results.nodes.contains { Self.imagePath(of: $0) == TestImages.foundation }
-            }
-            #expect(widened.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
-            #expect(!sawResultsCleared, "the results were emptied on the way instead of being merged into")
-            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
-            #expect(session.summary?.contains("results in") == true)
-            withExtendedLifetime(disposeBag) {}
-        }
+        let session = documentState.findSession
+        session.run(FindQuery(mode: .text, text: "NSObject"))
+        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
+        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
+
+        var sawResultsCleared = false
+        let disposeBag = DisposeBag()
+        session.$results.asDriver()
+            .driveOnNext { results in
+                if results.nodes.isEmpty { sawResultsCleared = true }
+            }
+            .disposed(by: disposeBag)
+
+        // Opening Foundation is what brings its corpus in after the search.
+        try await engine.loadImage(at: TestImages.foundation)
+
+        let widened = try await nextValue(from: session.$results.asDriver(), timeout: 180) { results in
+            results.nodes.contains { Self.imagePath(of: $0) == TestImages.foundation }
+        }
+        #expect(widened.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
+        #expect(!sawResultsCleared, "the results were emptied on the way instead of being merged into")
+        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
+        #expect(session.summary?.contains("results in") == true)
+        withExtendedLifetime(disposeBag) {}
 
         await engine.stop()
@@ -65,20 +60,18 @@ struct FindSessionCorpusTests {
 
-        try await withSharedGenerationOptionsLock {
-            let session = documentState.findSession
-            session.run(FindQuery(mode: .text, text: "NSObject", scope: .images([TestImages.libobjc])))
-            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
-
-            // Opening Foundation brings its corpus in after the search. The
-            // session hears of it one main-actor turn after the coordinator
-            // reports it, so that turn has to pass before a search it would
-            // start can be waited for.
-            try await engine.loadImage(at: TestImages.foundation)
-            _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 180) { $0[TestImages.foundation]?.isBuilt == true }
-            try await settleMainQueue()
-            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
-
-            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
-            #expect(!session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.foundation })
-        }
+        let session = documentState.findSession
+        session.run(FindQuery(mode: .text, text: "NSObject", scope: .images([TestImages.libobjc])))
+        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
+
+        // Opening Foundation brings its corpus in after the search. The
+        // session hears of it one main-actor turn after the coordinator
+        // reports it, so that turn has to pass before a search it would
+        // start can be waited for.
+        try await engine.loadImage(at: TestImages.foundation)
+        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 180) { $0[TestImages.foundation]?.isBuilt == true }
+        try await settleMainQueue()
+        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
+
+        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
+        #expect(!session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.foundation })
 
         await engine.stop()
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ContentTextPipelineTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ContentTextPipelineTests.swift
@@ -155,8 +155,10 @@ struct ContentTextPipelineTests {
     func failedFetchKeepsPipelineAlive() async throws {
         let fetchRecorder = InterfaceFetchRecorder(failingFirstFetches: 1)
         let fixtureRuntimeObject = makeRuntimeObject()
+        let appDefaults = AppDefaults.isolated()
         let (viewModel, mockRouter) = makeViewModel(
             runtimeObject: fixtureRuntimeObject,
+            appDefaults: appDefaults,
             interfaceProvider: { runtimeObject, _ in
                 if fetchRecorder.recordFetch() {
                     throw StubInterfaceFetchError()
@@ -174,17 +176,11 @@ struct ContentTextPipelineTests {
-        // The options are shared by every test in the process; see
-        // `withSharedGenerationOptionsLock`.
-        try await withSharedGenerationOptionsLock {
-            // Re-trigger the fetch half via a generation-option change; before
-            // the split this subscription was already dead (`catchAndReturn` on
-            // the outer chain completed it on the first error).
-            let appDefaults = liveAppDefaults()
-            let originalOptions = appDefaults.options
-            defer { appDefaults.options = originalOptions }
-            appDefaults.options.swiftInterfaceOptions.printFieldOffset.toggle()
-
-            let recovered = try await pollUntil(timeout: .seconds(10)) {
-                viewModel.attributedString != nil
-            }
-            #expect(recovered, "an options change after a failed fetch never recovered the pipeline")
-            #expect(fetchRecorder.fetchCount == 2)
-        }
+        // Re-trigger the fetch half via a generation-option change; before
+        // the split this subscription was already dead (`catchAndReturn` on
+        // the outer chain completed it on the first error). The store is the
+        // ViewModel's own, so no other test hears the change.
+        appDefaults.options.swiftInterfaceOptions.printFieldOffset.toggle()
+
+        let recovered = try await pollUntil(timeout: .seconds(10)) {
+            viewModel.attributedString != nil
+        }
+        #expect(recovered, "an options change after a failed fetch never recovered the pipeline")
+        #expect(fetchRecorder.fetchCount == 2)
@@ -285,16 +281,23 @@ struct ContentTextPipelineTests {
     private func makeViewModel(
         runtimeObject: RuntimeObject,
+        appDefaults: AppDefaults = .isolated(),
         interfaceProvider: @escaping ContentTextViewModel.InterfaceProvider
     ) -> (viewModel: ContentTextViewModel, router: MockRouter<ContentRoute>) {
         withLiveDependencyContext {
-            let documentState = DocumentState()
-            let mockRouter = MockRouter<ContentRoute>()
-            let viewModel = ContentTextViewModel(
-                runtimeObject: runtimeObject,
-                documentState: documentState,
-                router: mockRouter,
-                interfaceProvider: interfaceProvider
-            )
-            return (viewModel, mockRouter)
+            // Over the isolated store the live context pins, so a test can
+            // change the options of the very store this ViewModel reads.
+            withDependencies {
+                $0.appDefaults = appDefaults
+            } operation: {
+                let documentState = DocumentState()
+                let mockRouter = MockRouter<ContentRoute>()
+                let viewModel = ContentTextViewModel(
+                    runtimeObject: runtimeObject,
+                    documentState: documentState,
+                    router: mockRouter,
+                    interfaceProvider: interfaceProvider
+                )
+                return (viewModel, mockRouter)
+            }
         }
     }
@@ -383,12 +386,5 @@ struct ContentTextPipelineTests {
             return settings
         }
     }
 
-    private func liveAppDefaults() -> AppDefaults {
-        withLiveDependencyContext {
-            @Dependency(\.appDefaults) var appDefaults
-            return appDefaults
-        }
-    }
-
     // MARK: - Polling helper
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/SidebarSearchCaseSensitivityTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/SidebarSearchCaseSensitivityTests.swift
@@ -118,13 +118,4 @@
     private func makeLoadedViewModel(
         router: MockRouter<SidebarRuntimeObjectRoute>
     ) async throws -> CaseFixtureSidebarViewModel {
-        // Only the plain-contains mode (`filterMode == nil`, the sidebar's
-        // default) consults the flag at all — both fuzzy modes ignore it —
-        // so a mode persisted by an earlier run would turn this suite into
-        // a no-op that still passes in one direction.
-        withLiveDependencyContext {
-            @Dependency(\.appDefaults) var appDefaults
-            appDefaults.filterMode = nil
-        }
-
         let viewModel = CaseFixtureSidebarViewModel(
```

**复现测试（示例）**：新建 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/AppDefaultsIsolationTests.swift`。
- **为什么修前三条全红**：两个「隔离」实例读写的是同一个标准域。
  - 第一条：旁观实例读到了写入实例的值。
  - 第二条：旁观实例的 `$options` 同步收到了 KVO（同一个 `UserDefaults` 对象上的写入，在 setter 返回前就会通知观察者）。
  - 第三条：标准域被改了。
- **为什么不怕上次运行的残留**：每条都写一个「与当前值相反」的值，残留的值掩盖不了泄漏。
- 原来的竞态没法确定性复现，这三条就是它的确定性替身。
```diff
--- /dev/null
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/AppDefaultsIsolationTests.swift
@@ -0,0 +1,63 @@
+import Foundation
+import RuntimeViewerArchitectures
+import RuntimeViewerCore
+import Testing
+@testable import RuntimeViewerApplication
+
+/// What `AppDefaults.isolated()` promises the suites that build one: a write
+/// to one instance reaches no other, and none reaches the test process's
+/// standard defaults.
+@Suite("AppDefaults isolation")
+struct AppDefaultsIsolationTests {
+    @Test("a Generation Options write stays in the instance it was made on")
+    func optionsWriteStaysInItsInstance() {
+        let writer = AppDefaults.isolated()
+        let bystander = AppDefaults.isolated()
+        let bystanderOptionsBefore = bystander.options
+
+        writer.options = Self.toggled(writer.options)
+
+        #expect(bystander.options == bystanderOptionsBefore)
+    }
+
+    @Test("another instance's write is not observed")
+    func otherInstanceWriteIsNotObserved() {
+        let writer = AppDefaults.isolated()
+        let bystander = AppDefaults.isolated()
+        let writtenOptions = Self.toggled(writer.options)
+        var observedWrites: [RuntimeObjectInterface.GenerationOptions] = []
+        let disposeBag = DisposeBag()
+        bystander.$options
+            .filter { $0 == writtenOptions }
+            .subscribeOnNext { observedWrites.append($0) }
+            .disposed(by: disposeBag)
+
+        // Key-value observation of a defaults key is delivered on the writing
+        // thread, before the setter returns.
+        writer.options = writtenOptions
+
+        #expect(observedWrites.isEmpty)
+        withExtendedLifetime(disposeBag) {}
+    }
+
+    @Test("an isolated instance leaves the standard defaults alone")
+    func isolatedInstanceLeavesStandardDefaultsAlone() {
+        let standardOptionsBefore = UserDefaults.standard.data(forKey: "generationOptions")
+        let isolated = AppDefaults.isolated()
+
+        isolated.options = Self.toggled(isolated.options)
+
+        #expect(UserDefaults.standard.data(forKey: "generationOptions") == standardOptionsBefore)
+    }
+
+    /// Different from whatever `options` holds — including whatever an
+    /// earlier run left in a shared store — so a leak cannot hide behind an
+    /// equal value.
+    private static func toggled(
+        _ options: RuntimeObjectInterface.GenerationOptions
+    ) -> RuntimeObjectInterface.GenerationOptions {
+        var toggledOptions = options
+        toggledOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
+        return toggledOptions
+    }
+}
```
跑法：`queued-build swift test --package-path RuntimeViewerPackages --scratch-path /Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerPackages-FindNavigator --filter AppDefaultsIsolationTests`，成败看 `${pipestatus[1]}`，并确认输出里有三条具名的 passed。修完后再整组跑一次 FindViewModelTests、FindCorpusCoordinatorTests、FindSessionCorpusTests、FindGenerationOptionsTests 和 ContentTextPipelineTests，确认去掉锁之后仍然通过。

**同类**：
- **一起修的**：四个 `@UserDefault` 属性；`SidebarAutosaveKeyCleanup` 对标准域的写入；ContentTextPipelineTests 借共享默认域传值的写法；SidebarSearchCaseSensitivityTests 防残留的重置。
- **不算同类**：`StatefulOutlineView` 也写 `UserDefaults.standard`，但它的测试每条用独立的 key 并会清理。
- **另记，不在本条修**：同文件的 `liveSettings()` 解析的是真实的 live settings，因为 `withLiveDependencyContext` 只覆盖了 `appDefaults`。所以字号测试会改写开发者的 `RuntimeViewer-Debug/settings.json` 再还原（基线已有，30d6fefc）。这与曾经发生过的 Debug 设置被清空同源，建议另立一条，改用 `SettingsAccess.preview`。

**工作量**：S–M。一处生产代码的初始化方法、一个新测试文件、五个测试文件去锁或调整。不依赖其它条目；做完后，模块 D1 / D2 新写的测试不再需要拿锁。


### PR121.19 无效正则的报错不可读

- **严重度**：Minor
- **审查编号**：C26
- **状态**：方案待批，代码未改

**问题**：正则写错时，`Pattern` 抛出 `PatternError.invalidRegularExpression`，它只是普通的 `Swift.Error`（`RuntimeInterfaceTextMatcher.swift:22-25`），里面装的是整段 NSError 转储（:51）。Find 的摘要栏显示 `error.localizedDescription`（`FindSession.swift:273`），用户看到的是「Search failed: The operation couldn’t be completed. (RuntimeViewerCore.RuntimeInterfaceTextMatcher.PatternError error 1.)」，看不出是正则写错了。提案写明「正则写错时整次搜索失败、报在摘要栏」。
**四问**：复现——Text 或 Members 模式选 Regular Expression，输入 `(`，按回车；基线——本 PR 新引入；影响——只影响报错文字，不影响结果，改动很小，建议修；历史——新代码。

**改法**：
- `PatternError` 遵循 `LocalizedError`，报错只说「“…” is not a valid regular expression.」。Foundation 自己的说明（「The value “(” is invalid.」）放进关联值，留给日志用。
- `PatternError` 同时遵循 `CustomStringConvertible`，`description` 返回同一句话。原因是 socket 传输发送的是 `"\(error)"`（`RuntimeMessageChannel.swift:589`），而 XPC 传输发送的是 `error.localizedDescription`（`RuntimeXPCServiceConnection.swift:102`）。两条路都要可读。
- PR121.06 新增的「正则代价太高」错误采用同样的写法。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
@@ -20,8 +20,25 @@ enum RuntimeInterfaceTextMatcher {
     }
 
-    enum PatternError: Swift.Error {
+    enum PatternError: LocalizedError, CustomStringConvertible {
         case emptyQuery
-        case invalidRegularExpression(String)
+        /// `reason` is Foundation's own account of what is wrong, kept for
+        /// the log; the reader is shown the pattern instead.
+        case invalidRegularExpression(pattern: String, reason: String)
+
+        var errorDescription: String? {
+            switch self {
+            case .emptyQuery:
+                "Type something to search for."
+            case .invalidRegularExpression(let pattern, _):
+                "“\(pattern)” is not a valid regular expression."
+            }
+        }
+
+        /// The socket transports send `"\(error)"` across rather than the
+        /// localized description, so the readable text has to be both.
+        var description: String {
+            errorDescription ?? "The search pattern is not valid."
+        }
     }
 
     /// The query compiled once per search, not once per interface. Text and
@@ -48,6 +65,6 @@ enum RuntimeInterfaceTextMatcher {
                 do {
                     self.regex = try NSRegularExpression(pattern: text, options: isCaseSensitive ? [] : [.caseInsensitive])
                 } catch {
-                    throw PatternError.invalidRegularExpression("\(error)")
+                    throw PatternError.invalidRegularExpression(pattern: text, reason: error.localizedDescription)
                 }
                 self.needle = []
```

**复现测试（示例）**：第一例放在 `RuntimeViewerCoreTests/RuntimeInterfaceTextMatcherTests.swift`，第二例放在 `RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift`。修复前，`localizedDescription` 是那句通用的「The operation couldn’t be completed…」，`"\(error)"` 是 `invalidRegularExpression("Error Domain=NSCocoaErrorDomain Code=2048 …")`，两个断言都红。
```swift
@Test("an invalid regular expression is reported in words on every path an error travels")
func invalidRegularExpressionReadsAsText() {
    let error = #expect(throws: RuntimeInterfaceTextMatcher.PatternError.self) {
        try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "(", matchMode: .regularExpression))
    }
    // What FindSession shows, and what the XPC transport carries.
    #expect(error?.localizedDescription == "“(” is not a valid regular expression.")
    // What the socket transports carry.
    #expect(error.map { "\($0)" } == "“(” is not a valid regular expression.")
}
```
```swift
@Test("a search with an invalid regular expression fails with a readable reason")
func invalidRegularExpressionSearchFailsReadably() async throws {
    let fixture = makeStore()
    defer { withExtendedLifetime(fixture) {} }
    _ = try await fixture.store.build(imagePath: Self.imageA, transformer: .default)

    do {
        _ = try await fixture.store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "(", matchMode: .regularExpression), indexedImagePaths: []) { _ in }
        Issue.record("the search should have failed")
    } catch {
        #expect(error.localizedDescription == "“(” is not a valid regular expression.")
    }
}
```

**同类**：
- 传输层有同一类问题，交给模块 C：socket 客户端收到的是 `RuntimeNetworkRequestError`，它不是 `LocalizedError`（`RuntimeViewerCommunication/Network/RuntimeNetworkError.swift:9`）。所以任何远端错误经 socket 传回，都显示成「…RuntimeNetworkRequestError error 1.」，本条的 `description` 也救不了。本条只保证 XPC 和进程内两条路径可读。
- 关系搜索的引擎接口接受正则，并共用这个 `Pattern`，一并受益，不用另改。

**工作量**：S；不依赖其它条目。PR121.06 的新错误类型照此写。


### PR121.20 镜像对端共享主机的语料存储（建议不修）

- **严重度**：建议不修
- **审查编号**：C04（即 C1-6）
- **状态**：方案待批，代码未改

**问题**：每个引擎只有一个语料存储（`RuntimeEngine.swift:286`），每条连接的请求都由 `RuntimeEngine.registerSharedHandlers` 派到同一个引擎（`RuntimeEngineConnectionServer.swift:45-47`）。所以把引擎镜像给另一台 Mac 之后，对端的操作会直接作用在主机的语料上：
- 对端用另一个 transformer 请求同一镜像，主机上的那份语料会被驱逐并重建（`RuntimeInterfaceCorpusStore.swift:322-334`）。
- 对端关掉语料开关时发出的 `evictInterfaceCorpus(nil)`、改预算时发出的 `setResidentByteLimit`，同样作用在主机上。
- 搜索不核对 transformer，所以在主机自己重建之前，主机搜到的是按对端 transformer 打印的文字。

**四问**：复现——两台 Mac 镜像同一个引擎，两边都开 Find，其中一边改 Settings › Transformer，或在一边关掉语料开关；基线——本 PR 新引入（语料存储是新代码），而「一个引擎服务所有连接」是既有设计；影响——只有「镜像 + 两端都用 Find + transformer 或预算不同」才会触发，后果是来回重建、共享驱逐、短时间读到对方 transformer 的文字，不会崩溃也不会丢数据，建议不修；历史——新代码，审查时验证者已判为「有意暴露、低严重度」。

**裁决理由**（将来原样写进 KnownIssues）：
> 镜像对端与主机共用同一个引擎的语料存储：对端的 transformer、驱逐与预算设置会作用在主机上，主机在下次自己重建前可能读到对端 transformer 打印的文字。不修。要修，就得让存储认得请求来自哪个客户端（按连接隔离订阅、驱逐与预算），或者按「镜像 + transformer」各存一份并只驱逐发起方的那份，两者都是存储与命令集的设计改动。触发条件是镜像、两端都使用 Find，并且 transformer 或预算不同、或在对端关闭语料开关，三者同时满足；后果是重建抖动与共享驱逐，不崩溃、不丢数据。等真有人在镜像场景下使用 Find 时重新评估。

**改法**：不改代码。若想先做一点缓解，可以让镜像对端的协调器只发构建与搜索请求，不发 `evictInterfaceCorpus(nil)` 和 `setResidentByteLimit`。这样能避免对端关开关或改预算时清空主机的语料，但仍挡不住 transformer 不同引起的重建。这部分属于模块 C 的协调器，单独评估。

**拟修改**：无代码改动。

**复现测试（示例）**：不修，不写测试。

**同类**：无。
**工作量**：S（只写 KnownIssues 记录）。


### PR121.21 搜索先投影每个条目再看有没有命中

- **严重度**：Minor（性能）
- **审查编号**：F2
- **状态**：方案待批，代码未改

**问题**：文本搜索带上内容区的 Generation Options 时，只要这些选项隐藏了任何东西，store 就先给每个条目建投影，再在投影上匹配（`RuntimeInterfaceCorpusStore.swift:605`），不管这个条目有没有命中。建一次投影要做这些事：把文本复制成字节数组，建一张逐字节的「是否保留」表，再复制保留下来的字节和 span，最后新建一个 String（swift-semantic-string next 分支的 `VisibilityProjection.swift`）。总量约为条目大小的 3–4 倍。绝大多数条目对一个具体查询没有命中，这些开销都白花了。审查估计它是每次搜索最大的单项开销，在 27 MB 的语料上约 100 ms。成员搜索已经是有成员命中才投影，没有这个问题。
**四问**：复现——默认选项下（会隐藏偏移、地址等内容）搜任意词，用 signpost 统计投影次数，等于条目总数；基线——本 PR 新引入；影响——只影响耗时与内存抖动，不影响结果，建议在 PR121.06 之后做；历史——新代码。

**改法**：
- 字面量匹配（Containing / Matching Word / Starting With / Ending With）先不投影，问一个更便宜的问题：投影后可能有命中吗？没有就跳过这个条目。
- 判断方法要求**完全精确**，即不能漏掉投影后才出现的命中。投影后的命中只有两种来源：
  - 它在原文里本来就是命中；
  - 它碰到了一个「接缝」，也就是隐藏内容被删掉的位置：要么横跨接缝，要么紧挨接缝、它旁边那个决定词边界的字节变了。
- 所以先在原文上找命中；原文没有命中时，再在每个接缝两侧各取一个 needle 长度的保留字节拼成窗口来匹配。窗口两端按词边界处理，只会多报、不会漏报。两者都没有命中，投影里就一定没有命中。
- 正则可以匹配任意长度，没有窗口可言，照旧先投影再匹配。
- 要用的上游接口（`regions`、`conditions`、`isSatisfied(where:)`）都已公开，不用改 swift-semantic-string。
- 匹配器的字面量扫描拆出一个按字节缓冲区工作的版本，供窗口复用；按 String 调用的旧入口保留不变。
- 本条的 diff 基于 `12e1227b`。PR121.06 落地后，条目循环搬进扫描驱动，跳过的那几行跟着搬过去。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
@@ -102,39 +102,46 @@ enum RuntimeInterfaceTextMatcher {
     private static func literalHits(in text: String, pattern: Pattern) -> [Hit] {
+        var text = text
+        return text.withUTF8 { haystack in
+            literalHits(inUTF8: haystack, pattern: pattern)
+        }
+    }
+
+    /// `literalHits(in:pattern:)` over raw UTF-8 bytes, for a window of bytes
+    /// that is not a string of its own. Either end of the buffer counts as a
+    /// word boundary.
+    static func literalHits(inUTF8 haystack: UnsafeBufferPointer<UInt8>, pattern: Pattern) -> [Hit] {
         let needle = pattern.needle
         guard !needle.isEmpty else { return [] }
         let isCaseSensitive = pattern.isCaseSensitive
         let matchMode = pattern.matchMode
-        var text = text
-        return text.withUTF8 { haystack -> [Hit] in
-            var result: [Hit] = []
-            let haystackCount = haystack.count
-            let needleCount = needle.count
-            guard haystackCount >= needleCount else { return result }
-            let firstNeedleByte = needle[0]
-            var index = 0
-            let lastStart = haystackCount - needleCount
-            while index <= lastStart {
-                let candidate = isCaseSensitive ? haystack[index] : Pattern.asciiLowercased(haystack[index])
-                guard candidate == firstNeedleByte else {
-                    index += 1
-                    continue
-                }
-                var matchedCount = 1
-                while matchedCount < needleCount {
-                    let byte = haystack[index + matchedCount]
-                    let folded = isCaseSensitive ? byte : Pattern.asciiLowercased(byte)
-                    guard folded == needle[matchedCount] else { break }
-                    matchedCount += 1
-                }
-                guard matchedCount == needleCount,
-                      boundariesSatisfied(in: haystack, start: index, length: needleCount, matchMode: matchMode)
-                else {
-                    index += 1
-                    continue
-                }
-                result.append(Hit(utf8Offset: index, utf8Length: needleCount))
-                index += needleCount
-            }
-            return result
-        }
+        var result: [Hit] = []
+        let haystackCount = haystack.count
+        let needleCount = needle.count
+        guard haystackCount >= needleCount else { return result }
+        let firstNeedleByte = needle[0]
+        var index = 0
+        let lastStart = haystackCount - needleCount
+        while index <= lastStart {
+            let candidate = isCaseSensitive ? haystack[index] : Pattern.asciiLowercased(haystack[index])
+            guard candidate == firstNeedleByte else {
+                index += 1
+                continue
+            }
+            var matchedCount = 1
+            while matchedCount < needleCount {
+                let byte = haystack[index + matchedCount]
+                let folded = isCaseSensitive ? byte : Pattern.asciiLowercased(byte)
+                guard folded == needle[matchedCount] else { break }
+                matchedCount += 1
+            }
+            guard matchedCount == needleCount,
+                  boundariesSatisfied(in: haystack, start: index, length: needleCount, matchMode: matchMode)
+            else {
+                index += 1
+                continue
+            }
+            result.append(Hit(utf8Offset: index, utf8Length: needleCount))
+            index += needleCount
+        }
+        return result
     }
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceVisibility.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceVisibility.swift
@@ -43,4 +43,22 @@ struct RuntimeInterfaceVisibility: Sendable {
         objcOptions.isVisibilityOptionEnabled(optionName)
             || swiftConfiguration.isVisibilityOptionEnabled(optionName, resolvesOpaqueTypes: resolvesOpaqueTypes)
     }
 }
+
+extension VisibilityRegionTable {
+    /// The UTF-8 ranges a projection under `isOptionEnabled` takes out, in
+    /// text order, merged where two of them touch.
+    func hiddenUTF8Ranges(where isOptionEnabled: (String) -> Bool) -> [Range<Int>] {
+        let conditionHolds = conditions.map { $0.isSatisfied(where: isOptionEnabled) }
+        var hiddenRanges: [Range<Int>] = []
+        for region in regions where !conditionHolds[Int(region.conditionIndex)] {
+            let range = Int(region.utf8Offset) ..< Int(region.utf8Offset) + Int(region.utf8Length)
+            if let previousRange = hiddenRanges.last, previousRange.upperBound == range.lowerBound {
+                hiddenRanges[hiddenRanges.count - 1] = previousRange.lowerBound ..< range.upperBound
+            } else {
+                hiddenRanges.append(range)
+            }
+        }
+        return hiddenRanges
+    }
+}
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -67,6 +67,65 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
     func projection(under visibility: RuntimeInterfaceVisibility) -> VisibilityProjection? {
         guard !visibilityRegions.isEmpty else { return nil }
         return visibilityRegions.projection(of: interface, where: visibility.isOptionEnabled)
     }
 
+    /// Whether `pattern` can hit the interface as `visibility` shows it,
+    /// decided without building that projection, which copies the entry
+    /// several times over. Exact for the literal match styles: a hit of the
+    /// projection either is a hit of the full text, or touches a seam where
+    /// hidden text was taken out — it runs across it, or the byte beside it
+    /// changed — so the kept bytes within a needle's length of each seam are
+    /// matched too. A regular expression can match any length and always
+    /// gets the projection.
+    func mayHaveHits(of pattern: RuntimeInterfaceTextMatcher.Pattern, under visibility: RuntimeInterfaceVisibility) -> Bool {
+        guard pattern.regex == nil else { return true }
+        let hiddenRanges = visibilityRegions.hiddenUTF8Ranges(where: visibility.isOptionEnabled)
+        let reach = pattern.needle.count
+        var text = interface.text
+        return text.withUTF8 { bytes in
+            if !RuntimeInterfaceTextMatcher.literalHits(inUTF8: bytes, pattern: pattern).isEmpty {
+                return true
+            }
+            for (hiddenRangeIndex, hiddenRange) in hiddenRanges.enumerated() {
+                // The kept bytes on either side of this seam, skipping any
+                // other hidden range closer than a needle's length.
+                var keptBytesBefore: [UInt8] = []
+                var position = hiddenRange.lowerBound
+                var earlierRangeIndex = hiddenRangeIndex - 1
+                while keptBytesBefore.count < reach, position > 0 {
+                    position -= 1
+                    if earlierRangeIndex >= 0, hiddenRanges[earlierRangeIndex].contains(position) {
+                        position = hiddenRanges[earlierRangeIndex].lowerBound
+                        earlierRangeIndex -= 1
+                        continue
+                    }
+                    keptBytesBefore.append(bytes[position])
+                }
+                var keptBytesAfter: [UInt8] = []
+                position = hiddenRange.upperBound
+                var laterRangeIndex = hiddenRangeIndex + 1
+                while keptBytesAfter.count < reach, position < bytes.count {
+                    if laterRangeIndex < hiddenRanges.count, hiddenRanges[laterRangeIndex].contains(position) {
+                        position = hiddenRanges[laterRangeIndex].upperBound
+                        laterRangeIndex += 1
+                        continue
+                    }
+                    keptBytesAfter.append(bytes[position])
+                    position += 1
+                }
+                let seamOffset = keptBytesBefore.count
+                let window: [UInt8] = Array(keptBytesBefore.reversed()) + keptBytesAfter
+                let touchesSeam = window.withUnsafeBufferPointer { windowBytes in
+                    RuntimeInterfaceTextMatcher.literalHits(inUTF8: windowBytes, pattern: pattern).contains { hit in
+                        hit.utf8Offset <= seamOffset && hit.utf8Offset + hit.utf8Length >= seamOffset
+                    }
+                }
+                if touchesSeam {
+                    return true
+                }
+            }
+            return false
+        }
+    }
+
     /// `nestedDefinitionRanges` in `projection`'s text: each block from its
@@ -597,3 +656,8 @@ actor RuntimeInterfaceCorpusStore {
             for entry in corpus.entries {
                 scannedObjectCount += 1
+                // Most entries have no hit at all; under options that hide
+                // something, learn that before paying for the projection.
+                if let visibility, !entry.visibilityRegions.isEmpty, !entry.mayHaveHits(of: pattern, under: visibility) {
+                    continue
+                }
                 // The text the content pane shows under the query's options,
```

**复现测试（示例）**：性能项。正确性靠一个等价性用例保证：被跳过的条目在投影里一定没有命中，接缝两种情况都要覆盖。放在 `RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift`。隐藏条件用一个两个打印器都不认识的选项名，`RuntimeInterfaceVisibility` 对这种名字一律返回「关」，所以无论传什么选项，该区域都被隐藏。
```swift
private static func entry(_ interface: FrozenSemanticString, hidingUTF8Range hiddenRange: Range<Int>) -> RuntimeInterfaceCorpusEntry {
    RuntimeInterfaceCorpusEntry(
        object: RuntimeObject(name: "Fixture", displayName: "Fixture", kind: .swift(.type(.struct)), imagePath: imageA, children: []),
        interface: interface,
        visibilityRegions: VisibilityRegionTable(
            regions: [VisibilityRegionTable.Region(utf8Offset: UInt32(hiddenRange.lowerBound), utf8Length: UInt32(hiddenRange.count), conditionIndex: 0)],
            conditions: [.enabled("test.optionNoPrinterKnows")]
        ),
        members: []
    )
}

@Test("an entry skipped before projecting is one whose projection has no hit")
func projectionPrefilterKeepsEverySeamHit() throws {
    let visibility = RuntimeInterfaceVisibility(.mcp)
    // "let foo, bar, baz" reads "let foo, baz": the hit runs across the seam.
    let crossingEntry = Self.entry(SemanticString {
        Keyword("let")
        Standard(" ")
        Variable("foo")
        Standard(", ")
        Comment("bar, ")
        Variable("baz")
    }.frozen(), hidingUTF8Range: 9 ..< 14)
    // "fooBar = 1" reads "foo = 1": taking out "Bar" ends the word "foo".
    let boundaryEntry = Self.entry(SemanticString {
        Variable("foo")
        Comment("Bar")
        Standard(" = 1")
    }.frozen(), hidingUTF8Range: 3 ..< 6)

    for (entry, query) in [
        (crossingEntry, RuntimeInterfaceSearchQuery(text: "foo, baz")),
        (boundaryEntry, RuntimeInterfaceSearchQuery(text: "foo", matchMode: .matchingWord)),
    ] {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(query)
        let projection = try #require(entry.projection(under: visibility))
        // The projection has the hit while the full text does not...
        #expect(!RuntimeInterfaceTextMatcher.hits(in: projection.text.text, pattern: pattern).isEmpty)
        #expect(RuntimeInterfaceTextMatcher.hits(in: entry.interface.text, pattern: pattern).isEmpty)
        // ...so the entry must not be skipped.
        #expect(entry.mayHaveHits(of: pattern, under: visibility))
    }

    // A word on neither side of any seam is skipped, which is the point.
    let absentWordPattern = try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "qux"))
    #expect(!crossingEntry.mayHaveHits(of: absentWordPattern, under: visibility))
}
```
修复前没有这个方法，测试编不过；它守的是这次新加的跳过逻辑，作用是证明跳过从不丢结果，而不是证明旧代码有错。性能用 signpost 实测：在条目循环里统计「建投影」的次数，默认选项下搜一个常见词，次数应从条目总数降到有候选的条目数。修改前后的数字记进提案的决策日志。

**同类**：成员搜索已经是有成员命中才投影（store :671-681），不需要改。关系搜索不投影。
**工作量**：M；在 PR121.06 之后做，跳过逻辑放进它的扫描驱动。


### PR121.22 每条命中都带完整的 RuntimeObject

- **严重度**：Minor（性能），但要在发版前做
- **审查编号**：F5
- **状态**：方案待批，代码未改

**问题**：文本命中 `RuntimeInterfaceSearchMatch` 和成员命中 `RuntimeMemberMatch` 都直接带着完整的 `RuntimeObject`（`Common/RuntimeInterfaceSearch.swift:124-141`、`Common/RuntimeMemberDeclaration.swift:89-99`），其中包括递归的 `children`。进度推送按镜像成批发出，批里每条命中都要把它的对象连同整棵嵌套子树单独编码一遍。一个接口里常有几十条命中：在 SwiftUI 里搜 `View`、在 Foundation 里搜 `init`，同一个类型会在一批里重复几十次，每次带着它的整棵子树走一趟 XPC 或 socket。
**四问**：复现——对任何多命中的搜索，把一批进度的 JSON 打出来，同一个对象会重复出现；基线——本 PR 新引入（搜索命令是新的）；影响——只影响传输量和编解码耗时，结果正确。但**这两个线上类型是本 PR 新加的，现在改没有兼容负担，发版后再改就得兼容新旧两种格式**，所以建议在发版前修；历史——新代码。

**改法**：
- 线上格式改成「对象表 + 带对象下标的命中」：同一批里每个对象只出现一次，命中只带下标。文本、成员两种搜索共用一个泛型批次类型 `RuntimeObjectIndexedBatch<Payload>`，各自只定义「命中除了对象还带什么」。
- 只改线上格式，App 侧接口不变。服务端在请求的 `perform` 里把 store 给出的命中打包；客户端在 `RuntimeEngine.searchInterfaces` / `searchMembers` 里解包回现在的 `[RuntimeInterfaceSearchMatch]` / `[RuntimeMemberMatch]`。FindSession 和 store 都不用动。
- 不能干脆去掉 `children`：Find 点击后导航到的就是这个对象（`FindResultNode.swift:54-65`），Inspector 的 Specialization 页要读它的 `children`。
- 对象按 `RuntimeObjectKey` 去重。同一批里同一个 key 来自同一个语料条目，内容必然相同，去重不丢信息。对端发来的下标越界时，丢掉那一条命中，不让进程崩溃。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectIndexedBatch.swift
@@ -0,0 +1,100 @@
+import Foundation
+
+/// Search results as they cross a connection: each object once, every result
+/// pointing at it by index. A result's object carries its whole nested tree,
+/// and one interface often holds dozens of hits, so sending the object with
+/// each hit multiplied the payload by the hits per type.
+///
+/// Wire format only: `RuntimeEngine.searchInterfaces` / `searchMembers` hand
+/// their callers plain matches, objects included.
+struct RuntimeObjectIndexedBatch<Payload: Codable & Sendable>: Codable, Sendable {
+    struct Element: Codable, Sendable {
+        let objectIndex: Int
+        let payload: Payload
+    }
+
+    let objects: [RuntimeObject]
+
+    let elements: [Element]
+
+    /// Within one batch a key always comes from one corpus entry, so the
+    /// first object seen for it stands for every result that names it.
+    init(_ results: [(object: RuntimeObject, payload: Payload)]) {
+        var objects: [RuntimeObject] = []
+        var objectIndexByKey: [RuntimeObjectKey: Int] = [:]
+        var elements: [Element] = []
+        elements.reserveCapacity(results.count)
+        for result in results {
+            let objectIndex: Int
+            if let existingIndex = objectIndexByKey[result.object.key] {
+                objectIndex = existingIndex
+            } else {
+                objectIndex = objects.count
+                objects.append(result.object)
+                objectIndexByKey[result.object.key] = objectIndex
+            }
+            elements.append(Element(objectIndex: objectIndex, payload: result.payload))
+        }
+        self.objects = objects
+        self.elements = elements
+    }
+
+    /// Every result with its object again. An index outside `objects` — a
+    /// malformed batch from a peer — drops that result instead of trapping.
+    func results() -> [(object: RuntimeObject, payload: Payload)] {
+        elements.compactMap { element in
+            guard objects.indices.contains(element.objectIndex) else { return nil }
+            return (objects[element.objectIndex], element.payload)
+        }
+    }
+}
+
+typealias RuntimeInterfaceSearchBatch = RuntimeObjectIndexedBatch<RuntimeInterfaceSearchMatch.Hit>
+
+typealias RuntimeMemberSearchBatch = RuntimeObjectIndexedBatch<RuntimeMemberMatch.Hit>
+
+extension RuntimeInterfaceSearchMatch {
+    /// What a text match carries besides its object.
+    struct Hit: Codable, Sendable {
+        let lineNumber: Int
+        let lineText: String
+        let matchRangeInLine: RuntimeTextRange
+        let semanticKind: RuntimeSemanticKind
+    }
+}
+
+extension RuntimeMemberMatch {
+    /// What a member match carries besides its object.
+    struct Hit: Codable, Sendable {
+        let member: RuntimeMemberDeclaration
+        let matchRangeInName: RuntimeTextRange
+    }
+}
+
+extension RuntimeObjectIndexedBatch where Payload == RuntimeInterfaceSearchMatch.Hit {
+    init(_ matches: [RuntimeInterfaceSearchMatch]) {
+        self.init(matches.map { match in
+            (match.object, RuntimeInterfaceSearchMatch.Hit(lineNumber: match.lineNumber, lineText: match.lineText, matchRangeInLine: match.matchRangeInLine, semanticKind: match.semanticKind))
+        })
+    }
+
+    var matches: [RuntimeInterfaceSearchMatch] {
+        results().map { result in
+            RuntimeInterfaceSearchMatch(object: result.object, lineNumber: result.payload.lineNumber, lineText: result.payload.lineText, matchRangeInLine: result.payload.matchRangeInLine, semanticKind: result.payload.semanticKind)
+        }
+    }
+}
+
+extension RuntimeObjectIndexedBatch where Payload == RuntimeMemberMatch.Hit {
+    init(_ matches: [RuntimeMemberMatch]) {
+        self.init(matches.map { match in
+            (match.object, RuntimeMemberMatch.Hit(member: match.member, matchRangeInName: match.matchRangeInName))
+        })
+    }
+
+    var matches: [RuntimeMemberMatch] {
+        results().map { result in
+            RuntimeMemberMatch(object: result.object, member: result.payload.member, matchRangeInName: result.payload.matchRangeInName)
+        }
+    }
+}
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
@@ -40,15 +40,19 @@ extension RuntimeEngine {
     public func searchInterfaces(
         _ query: RuntimeInterfaceSearchQuery,
         onProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
     ) async throws -> RuntimeInterfaceSearchSummary {
-        try await dispatch(SearchInterfacesRequest(query: query), onProgress: onProgress)
+        try await dispatch(SearchInterfacesRequest(query: query)) { batch in
+            await onProgress(batch.matches)
+        }
     }
 
     /// Member-name search over every built corpus, same delivery as
     /// `searchInterfaces`.
     public func searchMembers(
         _ query: RuntimeMemberSearchQuery,
         onProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void
     ) async throws -> RuntimeInterfaceSearchSummary {
-        try await dispatch(SearchMembersRequest(query: query), onProgress: onProgress)
+        try await dispatch(SearchMembersRequest(query: query)) { batch in
+            await onProgress(batch.matches)
+        }
     }
@@ -222,19 +226,23 @@ extension RuntimeEngine {
     struct SearchInterfacesRequest: RuntimeEngineProgressRequest {
         typealias Response = RuntimeInterfaceSearchSummary
-        typealias Progress = [RuntimeInterfaceSearchMatch]
+        typealias Progress = RuntimeInterfaceSearchBatch
         let query: RuntimeInterfaceSearchQuery
         static var commandName: String { CommandNames.searchInterfaces.commandName }
-        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
-            try await engine._searchInterfaces(query, reportProgress: reportProgress)
+        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeInterfaceSearchBatch) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
+            try await engine._searchInterfaces(query) { matches in
+                await reportProgress(RuntimeInterfaceSearchBatch(matches))
+            }
         }
     }
 
     struct SearchMembersRequest: RuntimeEngineProgressRequest {
         typealias Response = RuntimeInterfaceSearchSummary
-        typealias Progress = [RuntimeMemberMatch]
+        typealias Progress = RuntimeMemberSearchBatch
         let query: RuntimeMemberSearchQuery
         static var commandName: String { CommandNames.searchMembers.commandName }
-        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
-            try await engine._searchMembers(query, reportProgress: reportProgress)
+        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeMemberSearchBatch) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
+            try await engine._searchMembers(query) { matches in
+                await reportProgress(RuntimeMemberSearchBatch(matches))
+            }
         }
     }
```

**复现测试（示例）**：性能项，测的是线上格式本身。放在 `RuntimeViewerCoreTests/RuntimeInterfaceSearchTests.swift`（或单开一个 `RuntimeObjectIndexedBatchTests.swift`）。前两个断言钉住「每个对象只发一次，解包后与原命中逐条相同」；第三个断言是可度量的检查：一批里同一个带子树的对象重复 20 次时，新格式的 JSON 不到旧格式的一半。旧格式就是现在的 `[RuntimeInterfaceSearchMatch]`，所以修复前后都能拿它当基准量。
```swift
@Test("a search batch sends each object once and gives every match back with its object")
func searchBatchSendsEachObjectOnce() throws {
    let child = RuntimeObject(name: "Child", displayName: "Parent.Child", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [])
    let parent = RuntimeObject(name: "Parent", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [child])
    let other = RuntimeObject(name: "Other", displayName: "Other", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [])
    let matches = (1 ... 30).map { lineNumber in
        RuntimeInterfaceSearchMatch(
            object: lineNumber.isMultiple(of: 3) ? other : parent,
            lineNumber: lineNumber,
            lineText: "line \(lineNumber)",
            matchRangeInLine: RuntimeTextRange(location: 0, length: 4),
            semanticKind: .standard
        )
    }

    let encodedBatch = try JSONEncoder().encode(RuntimeInterfaceSearchBatch(matches))
    let decodedBatch = try JSONDecoder().decode(RuntimeInterfaceSearchBatch.self, from: encodedBatch)

    #expect(decodedBatch.objects.count == 2)
    #expect(decodedBatch.matches == matches)
    #expect(zip(decodedBatch.matches, matches).allSatisfy { $0.object.hasSameContent(as: $1.object) })

    let encodedMatches = try JSONEncoder().encode(matches)
    #expect(encodedBatch.count * 2 < encodedMatches.count)
}
```
成员批次用同样的写法补一例（`RuntimeMemberSearchBatch`）。端到端的路径由现有的 `RuntimeInterfaceSearchTests.textSearch` / `memberSearch` 覆盖：它们走进程内引擎，会经过打包再解包，结果断言不变。另外在实现时实测一次真实搜索（Foundation 里搜 `init`，收满 1000 条）的批次字节数，修改前后的数字记进提案。

**同类**：关系搜索的结果是树（`[RuntimeRelationshipTree]`），每个节点本来就各是一个对象，没有「同一对象被多条命中重复携带」的问题，不在本条范围。
**工作量**：S–M；独立于其它条目。PR121.06 若给摘要加字段，与本条互不冲突。


### PR121.23 收满上限后仍为每个命中建 Layout

- **严重度**：Minor（性能）
- **审查编号**：F6
- **状态**：方案待批，代码未改

**问题**：搜索收满 `resultLimit`（默认 1000）之后仍会扫完全部语料，只为了把总数数准。但匹配器对每个有命中的条目都照样构建完整的 `Layout`（`RuntimeInterfaceTextMatcher.swift:184`）：扫一遍全文建行表，再遍历全部 span 建语义类别表；接着对每个命中都查一次语义类别（:195-198）。而这时行表根本用不上；搜索范围是 `.all` 时，语义类别也用不上。常见词（`View`、`init`）往往在前几个镜像里就收满了，剩下的所有条目都在白建这两张表。
**四问**：复现——在 SwiftUI 加 Foundation 的语料上搜 `init`，收满 1000 条后，用 signpost 看每个条目的耗时，`Layout.init` 占大头；基线——本 PR 新引入；影响——只影响搜索耗时，结果正确，改动小，建议修；历史——新代码。

**改法**：
- 把 `Layout` 里的 span 部分抽成 `SpanKindTable`。按范围过滤只需要它，不需要行表。
- `matches` 新增参数 `isCollecting`，由调用方告诉匹配器「是否已经收满」。只计数且范围是 `.all` 时，两张表都不建，只按排除区间计数。只计数但有范围限制时，只建 span 表。开始收集后，第一个被收集的命中才触发建 `Layout`，并复用已经建好的 span 表。
- 计数规则不变：排除区间的处理与原来一致，范围外的命中照旧不计。
- 与 PR121.24 的关系：本条的 diff 基于 `12e1227b`。如果 PR121.24 先落，`Layout` 里的行表已经换成 `RuntimeInterfaceLineTable`，本条只动 span 表与 `matches`，两边不冲突，只是上下文行要跟着变。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
@@ -167,73 +167,115 @@ enum RuntimeInterfaceTextMatcher {
     /// Runs `pattern` over `interface` and reports every hit inside the
     /// query's scope to `collect`, in offset order, until `collect` returns
     /// `false`. Hits are still counted after that, so the return value is the
     /// true number of in-scope hits whether or not they were all collected.
     /// A hit that starts inside one of `excludedUTF8Ranges` — ascending,
-    /// non-overlapping — is neither reported nor counted.
+    /// non-overlapping — is neither reported nor counted. `isCollecting`
+    /// false asks for the count alone, as a search past its result limit
+    /// does: that needs no line table, and over every kind no span table.
     @discardableResult
     static func matches(
         in interface: FrozenSemanticString,
         object: RuntimeObject,
         pattern: Pattern,
         excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>] = [],
+        isCollecting isCollectingAtStart: Bool = true,
         collect: (RuntimeInterfaceSearchMatch) -> Bool
     ) -> Int {
         let hits = hits(in: interface.text, pattern: pattern)
         guard !hits.isEmpty else { return 0 }
 
-        let layout = Layout(interface)
+        // Each built on first need: the span kinds for the first hit whose
+        // kind matters, the line table for the first hit collected.
+        var spanKindTable: SpanKindTable?
+        var layout: Layout?
         var count = 0
-        var isCollecting = true
+        var isCollecting = isCollectingAtStart
         var excludedRangeIndex = 0
         for hit in hits {
             while excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].upperBound <= hit.utf8Offset {
                 excludedRangeIndex += 1
             }
             if excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].contains(hit.utf8Offset) {
                 continue
             }
-            let kind = layout.semanticKind(atUTF8Offset: hit.utf8Offset)
+            let kind: RuntimeSemanticKind
+            if !isCollecting, pattern.scope == .all {
+                // Counted and never shown: its kind decides nothing.
+                kind = .other
+            } else {
+                let table = spanKindTable ?? SpanKindTable(interface)
+                spanKindTable = table
+                kind = table.semanticKind(atUTF8Offset: hit.utf8Offset)
+            }
             guard pattern.scope.includes(kind) else { continue }
             count += 1
             guard isCollecting else { continue }
-            let match = makeMatch(for: hit, kind: kind, in: layout, object: object)
+            let entryLayout = layout ?? Layout(interface, spanKindTable: spanKindTable)
+            layout = entryLayout
+            let match = makeMatch(for: hit, kind: kind, in: entryLayout, object: object)
             isCollecting = collect(match)
         }
         return count
     }
 
-    /// Line starts and span starts of one interface, built once per scan.
+    /// The semantic kind of every span of one interface, looked up by offset:
+    /// all a count over a scope needs.
+    struct SpanKindTable {
+        /// UTF-8 offset at which each span begins, plus a trailing sentinel.
+        let spanStartOffsets: [Int]
+        let spanKinds: [RuntimeSemanticKind]
+
+        init(_ interface: FrozenSemanticString) {
+            var spanStartOffsets: [Int] = []
+            spanStartOffsets.reserveCapacity(interface.spans.count + 1)
+            var spanKinds: [RuntimeSemanticKind] = []
+            spanKinds.reserveCapacity(interface.spans.count)
+            var offset = 0
+            for span in interface.spans {
+                spanStartOffsets.append(offset)
+                spanKinds.append(RuntimeSemanticKind(SemanticType(frozenTypeCode: span.typeCode) ?? .other))
+                offset += Int(span.length)
+            }
+            spanStartOffsets.append(offset)
+            self.spanStartOffsets = spanStartOffsets
+            self.spanKinds = spanKinds
+        }
+
+        func semanticKind(atUTF8Offset offset: Int) -> RuntimeSemanticKind {
+            guard !spanKinds.isEmpty else { return .other }
+            var low = 0
+            var high = spanKinds.count - 1
+            while low < high {
+                let middle = (low + high + 1) / 2
+                if spanStartOffsets[middle] <= offset {
+                    low = middle
+                } else {
+                    high = middle - 1
+                }
+            }
+            return spanKinds[low]
+        }
+    }
+
+    /// Line starts and span kinds of one interface, built for the first hit
+    /// of an entry that is collected.
     struct Layout {
         let text: String
         /// UTF-8 offsets at which lines begin; the first is always 0.
         let lineStartOffsets: [Int]
-        /// UTF-8 offset at which each span begins, plus a trailing sentinel.
-        let spanStartOffsets: [Int]
-        let spanKinds: [RuntimeSemanticKind]
+        let spanKindTable: SpanKindTable
 
-        init(_ interface: FrozenSemanticString) {
+        /// `spanKindTable` is the one the scan already built, if any.
+        init(_ interface: FrozenSemanticString, spanKindTable: SpanKindTable? = nil) {
             self.text = interface.text
             var lineStartOffsets = [0]
             var text = interface.text
             text.withUTF8 { bytes in
                 for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
                     lineStartOffsets.append(index + 1)
                 }
             }
             self.lineStartOffsets = lineStartOffsets
-
-            var spanStartOffsets: [Int] = []
-            spanStartOffsets.reserveCapacity(interface.spans.count + 1)
-            var spanKinds: [RuntimeSemanticKind] = []
-            spanKinds.reserveCapacity(interface.spans.count)
-            var offset = 0
-            for span in interface.spans {
-                spanStartOffsets.append(offset)
-                spanKinds.append(RuntimeSemanticKind(SemanticType(frozenTypeCode: span.typeCode) ?? .other))
-                offset += Int(span.length)
-            }
-            spanStartOffsets.append(offset)
-            self.spanStartOffsets = spanStartOffsets
-            self.spanKinds = spanKinds
+            self.spanKindTable = spanKindTable ?? SpanKindTable(interface)
         }
 
@@ -256,14 +298,3 @@ enum RuntimeInterfaceTextMatcher {
         func semanticKind(atUTF8Offset offset: Int) -> RuntimeSemanticKind {
-            guard !spanKinds.isEmpty else { return .other }
-            var low = 0
-            var high = spanKinds.count - 1
-            while low < high {
-                let middle = (low + high + 1) / 2
-                if spanStartOffsets[middle] <= offset {
-                    low = middle
-                } else {
-                    high = middle - 1
-                }
-            }
-            return spanKinds[low]
+            spanKindTable.semanticKind(atUTF8Offset: offset)
         }
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -612,1 +612,1 @@ actor RuntimeInterfaceCorpusStore {
-                totalMatchCount += RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, excludingUTF8Ranges: nestedDefinitionRanges) { match in
+                totalMatchCount += RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, excludingUTF8Ranges: nestedDefinitionRanges, isCollecting: collectedCount < query.resultLimit) { match in
```

**复现测试（示例）**：行为不变，由现有用例覆盖：`RuntimeInterfaceCorpusStoreTests.truncation`（收集在上限处停止，计数继续）和 `RuntimeInterfaceTextMatcherTests.countingPastCollection`。另外补一个等价性用例，钉住「只计数」这条新路径的计数与收集路径完全一致，放在 `RuntimeViewerCoreTests/RuntimeInterfaceTextMatcherTests.swift`，用文件里现成的样例接口：
```swift
@Test("counting alone gives the same count as collecting, in every scope", arguments: RuntimeInterfaceSearchScope.allCases)
func countingAloneMatchesCollecting(scope: RuntimeInterfaceSearchScope) throws {
    let pattern = try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "foo", scope: scope))
    let collectingCount = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern) { _ in true }
    let countingCount = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, isCollecting: false) { _ in
        Issue.record("nothing is collected past the limit")
        return false
    }
    // Excluding a block must still drop the hits that start inside it.
    let excludedRanges = [0 ..< 12]
    let collectingCountWithExclusion = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, excludingUTF8Ranges: excludedRanges) { _ in true }
    let countingCountWithExclusion = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, excludingUTF8Ranges: excludedRanges, isCollecting: false) { _ in false }

    #expect(countingCount == collectingCount)
    #expect(countingCountWithExclusion == collectingCountWithExclusion)
}
```
性能用 signpost 实测：在 store 的条目循环外包一个 `#signpostInterval`，在 SwiftUI 加 Foundation 的语料上搜 `init`，比较收满之后剩余扫描的耗时。修改前后各量一次，数字记进提案的决策日志。

**同类**：成员搜索收满之后只做名字匹配，不建任何表，没有这个问题。
**工作量**：S；建议在 PR121.24 之后做。PR121.06 把条目循环搬进扫描驱动后，`isCollecting:` 那一处改为由驱动传入「是否还在收集」。


### PR121.24 行表有两份实现

- **严重度**：Cleanup
- **审查编号**：R6
- **状态**：方案待批，代码未改

**问题**：「把文本按 `\n` 切成行起点数组」以及「按偏移找所在行」，在搜索代码里实现了两遍。一份在 `RuntimeInterfaceCorpusEntry`（`RuntimeInterfaceCorpusStore.swift:111-131`，用 `utf8.enumerated()` 扫描，二分查找写成上下界形式），另一份在匹配器的 `Layout`（`RuntimeInterfaceTextMatcher.swift:214-254`、:271-281，用 `withUTF8` 扫描，二分查找写成 `low` / `high` 形式）。两份目前行为一致，但「行尾不含换行符」「最后一行到文本末尾」这类约定得在两处分别维护。
**四问**：复现——读代码即可看到两份实现；基线——本 PR 新引入；影响——没有行为差异，属于清理，建议与 PR121.23 同批做；历史——新代码。

**改法**：
- 在 `Search/` 下新建 `RuntimeInterfaceLineTable`。它用 `withUTF8` 扫描（两种写法里更快的那种），提供 `lineIndex(containingUTF8Offset:)` 和 `lineUTF8Range(at:)`。
- `Layout`、条目的 `memberDeclarationLineRanges` 计算、成员投影 `member(at:in:…)` 都改用它，条目上的两个静态函数删掉。
- 成员定位器（`RuntimeMemberDeclarationLocator`，模块 B2）也有自己的切行，B2 改写定位器时可以换成这个类型，本条不动它。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceLineTable.swift
@@ -0,0 +1,49 @@
+/// Where each line of a UTF-8 text begins, and the two lookups the matcher
+/// and the corpus entries both need: the line a byte is on, and a line's
+/// range. Offsets are UTF-8 bytes, as everywhere in the search.
+struct RuntimeInterfaceLineTable: Sendable {
+    /// UTF-8 offsets at which lines begin; the first is always 0.
+    let lineStartOffsets: [Int]
+
+    /// The text's length in UTF-8 bytes, where its last line ends.
+    let utf8Count: Int
+
+    init(_ text: String) {
+        var lineStartOffsets = [0]
+        var text = text
+        utf8Count = text.withUTF8 { bytes in
+            for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
+                lineStartOffsets.append(index + 1)
+            }
+            return bytes.count
+        }
+        self.lineStartOffsets = lineStartOffsets
+    }
+
+    var lineCount: Int {
+        lineStartOffsets.count
+    }
+
+    /// 0-based index of the line containing the byte at `offset`: the last
+    /// line start at or before it.
+    func lineIndex(containingUTF8Offset offset: Int) -> Int {
+        var low = 0
+        var high = lineStartOffsets.count - 1
+        while low < high {
+            let middle = (low + high + 1) / 2
+            if lineStartOffsets[middle] <= offset {
+                low = middle
+            } else {
+                high = middle - 1
+            }
+        }
+        return low
+    }
+
+    /// UTF-8 range of line `lineIndex`, without its terminator.
+    func lineUTF8Range(at lineIndex: Int) -> Range<Int> {
+        let start = lineStartOffsets[lineIndex]
+        let end = lineIndex + 1 < lineStartOffsets.count ? lineStartOffsets[lineIndex + 1] - 1 : utf8Count
+        return start ..< max(start, end)
+    }
+}
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceTextMatcher.swift
@@ -205,21 +205,13 @@ enum RuntimeInterfaceTextMatcher {
     /// Line starts and span starts of one interface, built once per scan.
     struct Layout {
         let text: String
-        /// UTF-8 offsets at which lines begin; the first is always 0.
-        let lineStartOffsets: [Int]
+        let lineTable: RuntimeInterfaceLineTable
         /// UTF-8 offset at which each span begins, plus a trailing sentinel.
         let spanStartOffsets: [Int]
         let spanKinds: [RuntimeSemanticKind]
 
         init(_ interface: FrozenSemanticString) {
             self.text = interface.text
-            var lineStartOffsets = [0]
-            var text = interface.text
-            text.withUTF8 { bytes in
-                for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
-                    lineStartOffsets.append(index + 1)
-                }
-            }
-            self.lineStartOffsets = lineStartOffsets
+            self.lineTable = RuntimeInterfaceLineTable(interface.text)
 
             var spanStartOffsets: [Int] = []
@@ -240,16 +232,5 @@ enum RuntimeInterfaceTextMatcher {
         /// 0-based index of the line containing the byte at `offset`.
         func lineIndex(containingUTF8Offset offset: Int) -> Int {
-            // Last line start that is <= offset.
-            var low = 0
-            var high = lineStartOffsets.count - 1
-            while low < high {
-                let middle = (low + high + 1) / 2
-                if lineStartOffsets[middle] <= offset {
-                    low = middle
-                } else {
-                    high = middle - 1
-                }
-            }
-            return low
+            lineTable.lineIndex(containingUTF8Offset: offset)
         }
 
@@ -271,11 +252,4 @@ enum RuntimeInterfaceTextMatcher {
         /// UTF-8 range of line `lineIndex`, without its terminator.
         func lineUTF8Range(at lineIndex: Int) -> Range<Int> {
-            let start = lineStartOffsets[lineIndex]
-            let end: Int
-            if lineIndex + 1 < lineStartOffsets.count {
-                end = lineStartOffsets[lineIndex + 1] - 1
-            } else {
-                end = text.utf8.count
-            }
-            return start ..< max(start, end)
+            lineTable.lineUTF8Range(at: lineIndex)
         }
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -43,10 +43,7 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
         self.nestedDefinitionRanges = nestedDefinitionRanges
-        let lineStartOffsets = Self.lineStartOffsets(of: interface.text)
-        let textByteCount = interface.text.utf8.count
+        let lineTable = RuntimeInterfaceLineTable(interface.text)
         memberDeclarationLineRanges = members.map { member in
-            guard let lineNumber = member.lineNumber, lineNumber >= 1, lineNumber <= lineStartOffsets.count else { return nil }
-            let lineStart = lineStartOffsets[lineNumber - 1]
-            let lineEnd = lineNumber < lineStartOffsets.count ? lineStartOffsets[lineNumber] - 1 : textByteCount
-            return lineStart ..< lineEnd
+            guard let lineNumber = member.lineNumber, lineNumber >= 1, lineNumber <= lineTable.lineCount else { return nil }
+            return lineTable.lineUTF8Range(at: lineNumber - 1)
         }
     }
@@ -88,1 +85,1 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
-    func member(at memberIndex: Int, in projection: VisibilityProjection, projectedLineStartOffsets: [Int]) -> RuntimeMemberDeclaration? {
+    func member(at memberIndex: Int, in projection: VisibilityProjection, projectedLineTable: RuntimeInterfaceLineTable) -> RuntimeMemberDeclaration? {
@@ -102,31 +99,7 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
         guard let surviving else { return nil }
-        let lineIndex = Self.lineIndex(containing: surviving, lineStartOffsets: projectedLineStartOffsets)
-        let projectedText = projection.text.text.utf8
-        let lineStart = projectedLineStartOffsets[lineIndex]
-        let lineEnd = lineIndex + 1 < projectedLineStartOffsets.count ? projectedLineStartOffsets[lineIndex + 1] - 1 : projectedText.count
-        let lineText = String(decoding: projectedText.dropFirst(lineStart).prefix(lineEnd - lineStart), as: UTF8.self)
+        let lineIndex = projectedLineTable.lineIndex(containingUTF8Offset: surviving)
+        let lineRange = projectedLineTable.lineUTF8Range(at: lineIndex)
+        let lineText = String(decoding: projection.text.text.utf8.dropFirst(lineRange.lowerBound).prefix(lineRange.count), as: UTF8.self)
         return member.located(at: lineIndex + 1, declarationText: lineText.trimmingCharacters(in: .whitespaces))
     }
-
-    static func lineStartOffsets(of text: String) -> [Int] {
-        var offsets = [0]
-        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") {
-            offsets.append(offset + 1)
-        }
-        return offsets
-    }
-
-    private static func lineIndex(containing offset: Int, lineStartOffsets: [Int]) -> Int {
-        var lowerBound = 0
-        var upperBound = lineStartOffsets.count
-        while upperBound - lowerBound > 1 {
-            let middle = (lowerBound + upperBound) / 2
-            if lineStartOffsets[middle] <= offset {
-                lowerBound = middle
-            } else {
-                upperBound = middle
-            }
-        }
-        return lowerBound
-    }
 }
@@ -673,12 +646,12 @@ actor RuntimeInterfaceCorpusStore {
-                var projection: (projection: VisibilityProjection, lineStartOffsets: [Int])??
+                var projection: (projection: VisibilityProjection, lineTable: RuntimeInterfaceLineTable)??
                 for (memberIndex, member) in entry.members.enumerated() {
                     if let kinds = query.kinds, !kinds.contains(member.kind) { continue }
                     guard let range = RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern) else { continue }
                     var shownMember = member
                     if let visibility {
                         if projection == nil {
-                            projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceCorpusEntry.lineStartOffsets(of: $0.text.text)) }
+                            projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceLineTable($0.text.text)) }
                         }
                         if let entryProjection = projection ?? nil {
                             // Hidden under the query's options: not a match.
-                            guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineStartOffsets: entryProjection.lineStartOffsets) else { continue }
+                            guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineTable: entryProjection.lineTable) else { continue }
```

**复现测试（示例）**：行为不变，大部分由现有用例覆盖：`RuntimeInterfaceTextMatcherTests`（行号、命中范围、长行窗口）、`RuntimeInterfaceCorpusStoreTests.buildAndSearch`（成员落在第 2 行）、`RuntimeInterfaceSearchTests.memberSearch`（Foundation 上九成以上的方法能定位到行）。

只有一条路径没有覆盖：成员搜索带 Generation Options 时，经 `member(at:in:…)` 在投影后的文本里重新定位行号。没有任何测试走这条路，所以先补一个守护用例，放在 `RuntimeInterfaceCorpusStoreTests.swift`。它改动前后都应该是绿的。先按旧签名 `projectedLineStartOffsets: RuntimeInterfaceCorpusEntry.lineStartOffsets(of: projection.text.text)` 写好并确认通过，再随重构改成下面的写法。
```swift
@Test("a member under options is located on its line of the projected text")
func memberLocatedInProjection() {
    // Line 2 is hidden under the options, so `shown` moves from line 3 to line 2.
    let interface = SemanticString {
        Keyword("struct")
        Standard(" S {\n")
        Comment("    // hidden\n")
        Standard("    ")
        Keyword("var")
        Standard(" ")
        Variable("shown")
        Standard(": Int\n}")
    }.frozen()
    // "struct S {\n" is 11 bytes; the comment span, newline included, is 14.
    let regions = VisibilityRegionTable(
        regions: [VisibilityRegionTable.Region(utf8Offset: 11, utf8Length: 14, conditionIndex: 0)],
        conditions: [.enabled("test.showsComments")]
    )
    let entry = RuntimeInterfaceCorpusEntry(
        object: RuntimeObject(name: "S", displayName: "S", kind: .swift(.type(.struct)), imagePath: Self.imageA, children: []),
        interface: interface,
        visibilityRegions: regions,
        members: [RuntimeMemberDeclaration(name: "shown", kind: .swiftVariable, isStatic: false, declarationText: "shown", lineNumber: 3)]
    )
    let projection = regions.projection(of: interface) { _ in false }

    let shown = entry.member(at: 0, in: projection, projectedLineTable: RuntimeInterfaceLineTable(projection.text.text))

    #expect(shown?.lineNumber == 2)
    #expect(shown?.declarationText == "var shown: Int")
}
```

**同类**：`RuntimeMemberDeclarationLocator` 里的切行归模块 B2，见 PR121.10。全仓库没有其它地方调用条目上被删掉的两个静态函数。
**工作量**：S。与 PR121.23 改的是同一个 `Layout`：建议本条先落，PR121.23 再把 `lineTable` 改成按需构建。PR121.06 会把 `searchMembers` 的这段循环搬进新的扫描驱动，两条一起落时，以搬家后的位置为准做同样的三处替换。


### PR121.25 语料内存预算少算了成员数据

- **严重度**：Minor
- **审查编号**：U1（审查末尾未经验证的补充项，本步已在代码层面核实）
- **状态**：方案待批，代码未改

**问题**：语料的常驻预算（默认 256 MB）按 `RuntimeInterfaceCorpusEntry.byteCount` 计算，而它只算文本、span 表、标识符表和区域表（`RuntimeInterfaceCorpusStore.swift:54-63`），完全不算成员。偏偏成员里有一大块重复数据：定位器给每个找到行的成员都存了一份去掉缩进的整行文本 `declarationText`（`RuntimeMemberDeclarationLocator.swift:51-52`）。另外还有每个成员的名字字符串、`RuntimeMemberDeclaration` 结构体本身、`memberDeclarationLineRanges`、`nestedDefinitionRanges` 和条目上的 `object`，都没计入。对于成员密集的 Objective-C 类，接口几乎每一行都是一个成员，单是复制的行文本就接近接口文本本身的大小，所以实际占用可能接近设定上限的两倍。Report navigator 显示的语料大小同样偏小。
**四问**：复现——读代码可以确认漏算的部分；倍数还没实测，实测方法见下文；基线——本 PR 新引入；影响——预算本来就是为了限制内存，漏算一半就失去了意义，在内存紧张的机器上尤其明显，建议修；历史——新代码，`byteCount` 的注释说成员「比文本小，而且与 section 共享」，但存下来的 `declarationText` 是定位器新建的字符串，并不与 section 共享。

**改法**：
- 条目里的成员不再保存声明行的副本，`declarationText` 改存成员名，与名字共用同一块存储，不额外分配。命中时由新方法 `displayedMember(at:)` 用已有的 `memberDeclarationLineRanges` 从 `interface` 里取回这一行。只有收进结果的成员需要取，最多 `resultLimit` 条。
- 带 Generation Options 的成员搜索本来就从投影后的文本里重新取行（`member(at:in:…)`），不受影响。没找到行的成员仍以名字作为声明文本，和现在一样。
- `byteCount` 补上漏算的部分：成员与行范围的结构体大小、名字字符串、嵌套块范围、条目的对象。字符串按实际分配估算，15 个 UTF-8 字节以内 Swift 存在字符串内部，不分配。这是估算，目的是让预算与真实占用在同一个量级，不追求精确到字节。
- 显示的语料大小会随之变大，更接近真实占用，不需要另改界面。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -16,4 +16,8 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
     let visibilityRegions: VisibilityRegionTable
 
+    /// The members its structures list, located, but without their
+    /// declaration lines: `declarationText` holds the name, and
+    /// `displayedMember(at:)` reads the line back out of `interface`. A copy
+    /// of every line would cost about as much as the text itself.
     let members: [RuntimeMemberDeclaration]
 
@@ -39,5 +43,7 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
         self.object = object
         self.interface = interface
         self.visibilityRegions = visibilityRegions
-        self.members = members
+        self.members = members.map { member in
+            RuntimeMemberDeclaration(name: member.name, kind: member.kind, isStatic: member.isStatic, declarationText: member.name, lineNumber: member.lineNumber)
+        }
         self.nestedDefinitionRanges = nestedDefinitionRanges
@@ -54,11 +60,23 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
-    /// Resident bytes: the text once, the span table, the interned
-    /// identifiers, the region table. The `RuntimeObject` and member list are
-    /// not counted — they are small next to the text and shared with the
-    /// section anyway.
+    /// Resident bytes, estimated: the text once, the span table, the interned
+    /// identifiers, the region table, the members with their line ranges, the
+    /// nested blocks and the object. A string counts what it allocates.
     var byteCount: Int {
         interface.text.utf8.count
             + interface.spans.count * MemoryLayout<FrozenSemanticString.Span>.stride
             + interface.identifierTable.reduce(0) { $0 + $1.utf8.count }
             + visibilityRegions.regions.count * MemoryLayout<VisibilityRegionTable.Region>.stride
+            + members.count * (MemoryLayout<RuntimeMemberDeclaration>.stride + MemoryLayout<Range<Int>?>.stride)
+            + members.reduce(0) { $0 + Self.allocatedByteCount(of: $1.name) }
+            + nestedDefinitionRanges.count * MemoryLayout<Range<Int>>.stride
+            + MemoryLayout<RuntimeObject>.stride
+            + Self.allocatedByteCount(of: object.name)
+            + Self.allocatedByteCount(of: object.displayName)
+    }
+
+    /// What a string allocates: nothing up to 15 UTF-8 bytes, which Swift
+    /// stores inline; above that, its bytes plus the allocation's header.
+    private static func allocatedByteCount(of string: String) -> Int {
+        let utf8Count = string.utf8.count
+        return utf8Count <= 15 ? 0 : utf8Count + 32
     }
 
@@ -108,4 +126,14 @@ struct RuntimeInterfaceCorpusEntry: Sendable {
         return member.located(at: lineIndex + 1, declarationText: lineText.trimmingCharacters(in: .whitespaces))
     }
 
+    /// The member at `memberIndex` as the full interface shows it, its
+    /// declaration line read back out of `interface`; a member with no known
+    /// line keeps its name as its declaration.
+    func displayedMember(at memberIndex: Int) -> RuntimeMemberDeclaration {
+        let member = members[memberIndex]
+        guard let lineNumber = member.lineNumber, let lineRange = memberDeclarationLineRanges[memberIndex] else { return member }
+        let lineText = String(decoding: interface.text.utf8.dropFirst(lineRange.lowerBound).prefix(lineRange.count), as: UTF8.self)
+        return member.located(at: lineNumber, declarationText: lineText.trimmingCharacters(in: .whitespaces))
+    }
+
     static func lineStartOffsets(of text: String) -> [Int] {
@@ -676,16 +704,17 @@ actor RuntimeInterfaceCorpusStore {
                     guard let range = RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern) else { continue }
-                    var shownMember = member
+                    var projectedMember: RuntimeMemberDeclaration?
                     if let visibility {
                         if projection == nil {
                             projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceCorpusEntry.lineStartOffsets(of: $0.text.text)) }
                         }
                         if let entryProjection = projection ?? nil {
                             // Hidden under the query's options: not a match.
-                            guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineStartOffsets: entryProjection.lineStartOffsets) else { continue }
-                            shownMember = projectedMember
+                            guard let memberUnderOptions = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineStartOffsets: entryProjection.lineStartOffsets) else { continue }
+                            projectedMember = memberUnderOptions
                         }
                     }
                     totalMatchCount += 1
                     guard collectedCount < query.resultLimit else { continue }
-                    batch.append(RuntimeMemberMatch(object: entry.object, member: shownMember, matchRangeInName: range))
+                    // The line is read back out of the text only for what is collected.
+                    batch.append(RuntimeMemberMatch(object: entry.object, member: projectedMember ?? entry.displayedMember(at: memberIndex), matchRangeInName: range))
                     collectedCount += 1
```

**复现测试（示例）**：放在 `RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift`。修复前 `byteCount` 不含成员，第一个断言红；条目里存的是整行文本，第二个断言也红。
```swift
@Test("an entry counts its members and keeps no copy of their declaration lines")
func entryByteCountCoversMembers() {
    let memberNames = (1 ... 40).map { "memberNumber\($0)WithADescriptiveName" }
    let interface = SemanticString {
        Standard(memberNames.map { "    func \($0)(argument: Int) -> String" }.joined(separator: "\n"))
    }.frozen()
    let members = memberNames.enumerated().map { index, name in
        RuntimeMemberDeclaration(name: name, kind: .swiftFunction, isStatic: false, declarationText: "func \(name)(argument: Int) -> String", lineNumber: index + 1)
    }
    let entry = RuntimeInterfaceCorpusEntry(
        object: RuntimeObject(name: "Owner", displayName: "Owner", kind: .swift(.type(.class)), imagePath: Self.imageA, children: []),
        interface: interface,
        members: members
    )

    let textAndSpans = interface.text.utf8.count + interface.spans.count * MemoryLayout<FrozenSemanticString.Span>.stride
    #expect(entry.byteCount >= textAndSpans + members.count * MemoryLayout<RuntimeMemberDeclaration>.stride)
    #expect(entry.members.allSatisfy { $0.declarationText == $0.name })
}
```
命中时把行取回来的这条路径，再加一个守护断言，修改前后都应为绿：在现有的 `buildAndSearch` 用例里，`memberMatches.first?.member.lineNumber == 2` 之后补一行
```swift
#expect(memberMatches.first?.member.declarationText == "var memberBeta: Int")
```
引擎级的 `RuntimeInterfaceSearchTests.memberSearch` 已经断言 `declarationText.contains("initWithFormat:")`，在真实的 Foundation 语料上覆盖同一条路径。

**实测**（实现时手工做一次，不进测试套件）：建好 AppKit 的语料，比较 `residentByteCount` 与建语料前后进程 malloc 用量的增量（`malloc_zone_statistics`），两者误差应在 ±25% 以内。修改前后的数字记进提案的决策日志。

**同类**：`RuntimeInterfaceCorpusBuildSummary.byteCount` 与 Report navigator 显示的大小都来自这里，随之变准，不需要另改。定位器本身（PR121.10，模块 B2）仍会临时生成行文本，但只存在于组装阶段，条目建好后即释放，不计入常驻。
**工作量**：M；要和 PR121.10 协调，定位器改写后，这里的「去掉行文本」可以挪进定位器的输出。PR121.24 与 PR121.06 改到相邻的代码，按落地顺序调整上下文即可。


### PR121.26 coverage 的 indexedImagePaths 参数没有用

- **严重度**：Cleanup
- **审查编号**：S1 遗留（审查日志 S1 的后半句）
- **状态**：方案待批，代码未改

**问题**：`RuntimeInterfaceCorpusStore.coverage(indexedImagePaths:)` 根本不读它的参数（`RuntimeInterfaceCorpusStore.swift:300` 的 `_ = indexedImagePaths`），但引擎每次回答覆盖查询之前都会先算出这个参数（`RuntimeEngine+Search.swift:131`）。这一步要分别调用 ObjC、Swift 两个 section 工厂 actor 才能取到交集（:148-152），算完就丢。Report navigator 打开时以及每次构建结束都会查询覆盖情况，所以每次都白白多两跳。
**四问**：复现——读代码即可确认，参数从未被使用；基线——本 PR 新引入；影响——只浪费两次 actor 调用，不影响行为，顺手清理；历史——新代码。参数的文档注释说「已索引但存储里没有的镜像报告为缺席」，而实现里「缺席」就是不在表里，用不着这个集合。

**改法**：删掉参数和调用方的那次计算，文档注释改为描述实际行为。协调器那边也有「算出 indexedImagePaths 就扔」的同类浪费（F8，PR121.35），归模块 C 处理。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -287,4 +287,4 @@ actor RuntimeInterfaceCorpusStore {
-    /// `indexedImagePaths` are the images the engine has indexed; those the
-    /// store holds nothing for are reported as absent, not as pending.
-    func coverage(indexedImagePaths: Set<String>) -> RuntimeInterfaceCorpusCoverage {
+    /// Every image the store knows about. An image it holds nothing for is
+    /// absent from the map, not reported as pending.
+    func coverage() -> RuntimeInterfaceCorpusCoverage {
         var states: [String: RuntimeInterfaceCorpusBuildState] = [:]
@@ -297,5 +297,4 @@ actor RuntimeInterfaceCorpusStore {
         for (imagePath, message) in failureMessages where states[imagePath] == nil {
             states[imagePath] = .failed(message: message)
         }
-        _ = indexedImagePaths
         return RuntimeInterfaceCorpusCoverage(
```
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
@@ -130,3 +130,3 @@ extension RuntimeEngine {
     func _interfaceCorpusCoverage() async -> RuntimeInterfaceCorpusCoverage {
-        await interfaceCorpusStore.coverage(indexedImagePaths: await indexedImagePaths())
+        await interfaceCorpusStore.coverage()
     }
```
```diff
--- a/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift
+++ b/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusStoreTests.swift
@@ -192,1 +192,1 @@ struct RuntimeInterfaceCorpusStoreTests {
-            if predicate(await store.coverage(indexedImagePaths: [])) { return }
+            if predicate(await store.coverage()) { return }
@@ -362,1 +362,1 @@ struct RuntimeInterfaceCorpusStoreTests {
-        #expect(await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA]?.isBuilt == true)
+        #expect(await store.coverage().statesByImagePath[Self.imageA]?.isBuilt == true)
@@ -374,1 +374,1 @@ struct RuntimeInterfaceCorpusStoreTests {
-        guard case .failed = await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA] else {
+        guard case .failed = await store.coverage().statesByImagePath[Self.imageA] else {
@@ -431,1 +431,1 @@ struct RuntimeInterfaceCorpusStoreTests {
-        #expect(await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA] == nil)
+        #expect(await store.coverage().statesByImagePath[Self.imageA] == nil)
```

**复现测试（示例）**：行为不变，由现有的 `RuntimeInterfaceCorpusStoreTests`（`waitForCoverage` 用到的全部用例、`skippedObject`、`failedBuild`、`lastSubscriberCancels`）和 `RuntimeInterfaceSearchTests.textSearch` 里的 `interfaceCorpusCoverage()` 断言覆盖。

**同类**：全仓库只有上面这 6 处调用（定义 1 处、引擎 1 处、测试 4 处）。`indexedImagePaths()` 本身还被两个搜索的本地分支和 `IndexedImagePathsRequest` 使用，保留不动。
**工作量**：S；不依赖其它条目。PR121.08 改到同一个 `coverage()` 的函数体，两条一起落时把这里的签名改动先合进去。


### PR121.27 RuntimeViewer 复制了上游打印器的私有规则

- **严重度**：Minor
- **审查编号**：AL4
- **状态**：方案待批，代码未改

**问题**：MachOSwiftSection（MSS）的打印器只给顶层协议在声明后面接着打印默认实现，嵌套协议和声明在别的模块扩展里的协议不在此列。RuntimeViewer 的 `defaultImplementationExtensionsLeftToPrint` 用的是这条规则取反后的一份拷贝，靠它决定哪些协议要自己补印默认实现；内容区和 Find 语料都经过 `printedDefinitions`，所以拷贝错了两边会一起错。

这条规则已经变过一次。MSS 的 a93960d3（远端已变基为 bca9594d，目前只在 `feature/runtime-viewer/find-navigator` 上）给条件加了 `extensionContext == nil`，RuntimeViewer 只能在 74c349c7 里跟着改。连 MSS 内部也写了两份：打印器一份，整镜像的 `SwiftInterfaceBuilder` 一份。

**四问**：
- **复现**：目前三份拷贝一致，没有出错，属于结构性风险。
- **基线**：本 PR 新引入（1954a8a5 起依赖这条规则，74c349c7 跟着上游改过一次）。
- **影响**：上游下次再改规则，默认实现就会悄悄丢失或重复打印。main 上的 PR #117 已经埋了雷，见「同类」。建议修。
- **历史**：同一条规则已经因上游改动出过一次差错（a93960d3 → 74c349c7）。当初照抄是因为上游没有公开这个判断。

**改法（推荐：上游公开这条规则）**：
- 在 MSS 的 `ProtocolDefinition` 上加一个公开属性 `printsDefaultImplementationExtensionsAfterDeclaration`，并让打印器和 `SwiftInterfaceBuilder` 都改读它。这样规则在 MSS 内部只剩一处，RuntimeViewer 也只读不抄。
- 这个改动要落在已经带着 bca9594d 的分支上，也就是 `feature/runtime-viewer/find-navigator`，再随它合进 MSS `next`。MSS `next`（433f1421）上的打印器还是旧规则（只看 `parent == nil`）。
- 配合 PR121.11（成员列表改为按结构列出），RuntimeViewer 只剩 `printedDefinitions` 这一个地方需要这条规则。
- 代价：
  - 一次 MSS 提交。
  - 本 PR 对 MSS 分支的 pin 要前移；三个 workspace 的 `Package.resolved` 要用 `UpdatePackagesScript.sh` 重新解析。这件事要和 PR121.70（锁文件钉着已被变基孤立的 MSS 修订）一起处理。
- 备选（不动上游）：把这份拷贝收拢成 RuntimeViewer 里的一个函数，只靠下面的护栏测试在上游变化时报警。缺点是只能在漂移发生后发现，没法预防。

**拟修改**：

MachOSwiftSection。以 PR 锁定的 86f65341 为准；落到 `feature/runtime-viewer/find-navigator` 当前的提交时，按实际行号重新对一遍。
```diff
--- a/Sources/Declaration/SwiftDeclaration/Components/Definitions/ProtocolDefinition.swift
+++ b/Sources/Declaration/SwiftDeclaration/Components/Definitions/ProtocolDefinition.swift
@@ -28,5 +28,17 @@
     public package(set) var extensionContext: ExtensionContext? = nil
 
     public package(set) var defaultImplementationExtensions: [ExtensionDefinition] = []
 
+    /// Whether `SwiftDeclarationPrinter.printProtocolDefinition` prints the
+    /// default-implementation extensions right after the declaration. Only a
+    /// top-level protocol's are: one nested in a type, or declared in an
+    /// extension of another module's type (which leaves it an extension
+    /// context and no parent), prints inside that declaration's braces,
+    /// where an extension cannot go, so whoever prints it on its own appends
+    /// `defaultImplementationExtensions` itself. The printer, the interface
+    /// builder and hosts all read this one rule.
+    public var printsDefaultImplementationExtensionsAfterDeclaration: Bool {
+        parent == nil && extensionContext == nil
+    }
+
     public package(set) var associatedTypes: [String] = []
```

```diff
--- a/Sources/Output/SwiftPrinting/SwiftDeclarationPrinter.swift
+++ b/Sources/Output/SwiftPrinting/SwiftDeclarationPrinter.swift
@@ -379,13 +379,11 @@
             }
         }
 
-        // Only a top-level protocol trails its default-implementation
-        // extensions. One nested in a type, or declared in an extension of
-        // another module's type (which leaves it an extension context and no
-        // parent), prints inside that declaration's braces, where an
-        // extension cannot go — the interface prints its extensions in the
-        // top-level extensions block instead (`SwiftInterfaceBuilder`).
-        if protocolDefinition.parent == nil, protocolDefinition.extensionContext == nil {
+        // Which protocols trail their default-implementation extensions is
+        // `printsDefaultImplementationExtensionsAfterDeclaration`'s to say; the
+        // interface prints the others' in its top-level extensions block
+        // (`SwiftInterfaceBuilder`).
+        if protocolDefinition.printsDefaultImplementationExtensionsAfterDeclaration {
             // Per-extension catch: a default-implementation extension whose
             // printing throws drops only itself, not the protocol it trails.
             await BlockList {
```

```diff
--- a/Sources/Output/SwiftInterface/SwiftInterfaceBuilder.swift
+++ b/Sources/Output/SwiftInterface/SwiftInterfaceBuilder.swift
@@ -246,4 +246,4 @@
             // of a parent; its blocks used to print inside that extension's
             // braces (evolution proposal `nested-definition-regions`).
-            for protocolDefinition in indexer.allProtocolDefinitions.values where protocolDefinition.parent != nil || protocolDefinition.extensionContext != nil {
+            for protocolDefinition in indexer.allProtocolDefinitions.values where !protocolDefinition.printsDefaultImplementationExtensionsAfterDeclaration {
                 for extensionDefinition in protocolDefinition.defaultImplementationExtensions {
```

RuntimeViewer：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
@@ -435,10 +435,9 @@
 
     /// The protocol's default implementations, unless the printer prints them
-    /// itself — which it does after a protocol declared at the top level only.
-    /// A protocol nested in a type, or declared in an extension of a type from
-    /// another module, is printed without them, the same way its parent
-    /// prints it inline.
+    /// itself, which `printsDefaultImplementationExtensionsAfterDeclaration`
+    /// says it does. A protocol it prints without them is printed here the way
+    /// its parent prints it inline, and they follow it.
     private func defaultImplementationExtensionsLeftToPrint(of definition: ProtocolDefinition) -> [PrintedDefinition] {
-        guard definition.parent != nil || definition.extensionContext != nil else { return [] }
+        guard !definition.printsDefaultImplementationExtensionsAfterDeclaration else { return [] }
         return definition.defaultImplementationExtensions.map(PrintedDefinition.extension)
     }
```

**复现测试（示例）**：这是护栏，不是复现，修复前后都应该通过。它取代 `RuntimeInterfaceCorpusNestingTests` 里现有的 `extensionProtocolShowsDefaultImplementations`。原测试只检查「声明在别的模块扩展里的协议」，而且只要求块数不少于应有的数量；新测试覆盖三种位置，要求块数恰好相等，所以多印、少印都会失败。另一个测试 `noExtensionPrintedTwice`（同一个块不能出现两次）保留。走备选方案时，把测试里的 `definition.printsDefaultImplementationExtensionsAfterDeclaration` 换成 RuntimeViewer 自己收拢的那个函数。
```swift
/// Wherever a protocol is declared — at the top level, nested in a type, or
/// in an extension of another module's type — its interface prints each of
/// its default implementations exactly once: the printer trails a top-level
/// protocol with them, `printedDefinitions` appends them for the others.
/// Fails in either direction if the two ever disagree on which is which.
@Test("every protocol prints each of its default implementations exactly once")
func defaultImplementationsPrintedExactlyOnce() async throws {
    let engine = try await Self.foundationEngine.value
    let entries = try await Self.foundationEntries()
    let firstSwiftEntry = try #require(entries.first { $0.object.kind.isSwift })
    let section = try #require(await engine.swiftSectionFactory.existingSection(for: firstSwiftEntry.object.imagePath))
    var checkedCountByPlacement: [String: Int] = [:]
    var mismatched: [String] = []
    for entry in entries where entry.object.kind == .swift(.type(.protocol)) {
        guard let definitions = try? await section.printedDefinitions(for: entry.object),
              case .protocol(let definition) = definitions.first,
              definition.defaultImplementationExtensions.contains(where: \.isAttachedToProtocolDefinition)
        else { continue }
        let placement = definition.parent != nil ? "nested in a type" : definition.extensionContext != nil ? "in another module's extension" : "top level"
        checkedCountByPlacement[placement, default: 0] += 1
        // Extensions `printedDefinitions` appends, default implementations or not,
        // plus those the printer trails the declaration with.
        let appendedCount = definitions.dropFirst().count
        let trailedCount = definition.printsDefaultImplementationExtensionsAfterDeclaration ? definition.defaultImplementationExtensions.count : 0
        let printedCount = Self.extensionBlocks(of: entry.interface.text).count
        if printedCount != appendedCount + trailedCount {
            mismatched.append("\(entry.object.displayName) (\(placement)): \(printedCount) extension blocks, expected \(appendedCount) appended and \(trailedCount) trailed")
        }
    }
    #expect(checkedCountByPlacement["top level", default: 0] > 0)
    #expect(checkedCountByPlacement["in another module's extension", default: 0] > 0, "Foundation declares no protocol with default implementations in an extension any more")
    #expect(mismatched.isEmpty, "\(mismatched.joined(separator: "\n"))")
}
```

**同类**：
- **PR #117 在 main 上抄的是旧版规则**（只看 `parent != nil`），这和 main 目前锁定的 MSS 0.15.2 一致。但 main 的 MSS pin 一旦前移到包含 bca9594d 的版本，「声明在别的模块扩展里的协议」在 main 的内容区就会丢掉默认实现，而 #117 的 `SwiftProtocolInterfaceTests` 只检查重复，查不出缺失。建议：上游属性发版后，#117 改为读这个属性；在那之前，给 #117 的测试补上「缺失」方向，写法同上面的护栏。
- **MSS 内部的第二份拷贝**：`SwiftInterfaceBuilder.swift:248`。已并入上面的 diff。
- **成员列表里对打印器的另外两处假设**（只记录，不并入本条）：
  - `memberDeclarations(of definition:)`（`RuntimeSwiftSection.swift:1869`）在「allocators 为空」时改列 `constructors`。但 MSS 打印器只按 `MemberCategory` 打印，从不打印 `constructors`，所以这样列出的 init 永远没有行号。改法：用 MSS 公开的 `MemberCategory.allCases` 加 `definition.members(in:)` 列成员，类别就和打印器同源；PR121.10 之后定位与顺序无关，这样改是安全的。是否真有命中还没统计，需要先在 Foundation 语料里数出「列出了却没定位到的 init」，暂列为疑似。
  - 打印器会隐藏属性包装器合成的 `_x` / `$x`（私有的 `synthesizedPropertyWrapperMembers`），RuntimeViewer 却照样列出，结果是这些成员能搜到但没有行号。规则在 MSS 里是私有的；如果走上游方案，可以一并公开。

**工作量**：MSS 侧 S，外加一次 pin 前移；RuntimeViewer 侧 S；护栏测试 S。依赖 PR121.70（锁文件孤立修订）先理顺；与 PR121.11 无先后要求，但两者合起来，RuntimeViewer 才不再照抄这条规则。


### PR121.28 可见性映射复制了 Swift 打印配置

- **严重度**：Cleanup
- **审查编号**：S7（= R1 = AL7）
- **状态**：方案待批，代码未改

**问题**：Find 搜索是在语料文本上按用户的生成选项做投影的，投影规则必须和内容区打印时的规则完全一致。现在这套规则写了两份：
- 内容区：`RuntimeSwiftSection.buildPrintConfiguration` 把 `SwiftGenerationOptions` 的 9 个开关映射到 `SwiftDeclarationPrintConfiguration`。
- 搜索：`RuntimeInterfaceVisibility.init` 把这 9 个开关逐项又抄了一遍。

「打开 `synthesizeOpaqueType` 就注册 opaque type 解析器」这条规则也同样有两份。今天两边一致，但以后新增或改名一个 Swift 选项时，只要漏改一处，搜索读到的文本就会和内容区对不上，用户点开命中会跳到对不上的位置。

**四问**：
- **复现**：目前没有不一致，属于漂移风险，构造不出现在就出错的场景。
- **基线**：本 PR 新引入（4a0f1f5f 加入 `RuntimeInterfaceVisibility`）。
- **影响**：没有实际错误，属于防止回归的清理，建议顺手做。
- **历史**：这份拷贝是加入时就有的；同类的上游规则拷贝已经出过一次问题（见 PR121.27）。

**改法**：
- 新增 `SwiftDeclarationPrintConfiguration.applySwitches(of:)`，作为 9 个开关唯一的一份映射；内容区和搜索都调用它。
- 新增 `SwiftGenerationOptions.resolvesOpaqueTypes`，`updateConfiguration` 注册解析器、搜索判断可见性都读它。
- `buildPrintConfiguration` 原来的语义不变：新建一份配置、沿用旧配置的 transformer，只是把开关的赋值换成调用 `applySwitches`。上游的 memberwise 初始化器每个参数都有默认值，省掉开关参数后，剩下的实参顺序仍与声明顺序一致。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
@@ -1297,7 +1297,7 @@
         )
         printer.updateConfiguration(newPrintConfiguration)
 
-        if options.synthesizeOpaqueType {
+        if options.resolvesOpaqueTypes {
             printer.addTypeNameResolver(SwiftInterfaceBuilderOpaqueTypeProvider(machO: machO))
         } else {
             printer.removeAllTypeNameResolvers()
@@ -1322,23 +1322,15 @@
         case .byOffset: .byOffset
         }
 
         var newConfiguration = SwiftDeclarationPrintConfiguration(
-            printStrippedSymbolicItem: options.printStrippedSymbolicItem,
-            printFieldOffset: options.printFieldOffset,
-            printExpandedFieldOffsets: options.printExpandedFieldOffset,
-            printMemberAddress: options.printMemberAddress,
-            printVTableOffset: options.printVTableOffset,
-            printPWTOffset: options.printPWTOffset,
-            infersObjCOverridesFromSelectorNames: options.infersObjCOverridesFromSelectorNames,
             memberSortOrder: swiftInterfaceMemberSortOrder,
-            printTypeLayout: options.printTypeLayout,
-            printEnumLayout: options.printEnumLayout,
             memberAddressTransformer: oldConfiguration.memberAddressTransformer,
             vtableOffsetTransformer: oldConfiguration.vtableOffsetTransformer,
             fieldOffsetTransformer: oldConfiguration.fieldOffsetTransformer,
             typeLayoutTransformer: oldConfiguration.typeLayoutTransformer,
             enumLayoutTransformer: oldConfiguration.enumLayoutTransformer,
             enumLayoutCaseTransformer: oldConfiguration.enumLayoutCaseTransformer,
         )
+        newConfiguration.applySwitches(of: options)
 
         // The transformer templates render library-side
@@ -1353,5 +1345,33 @@
         return newConfiguration
     }
 }
+
+extension SwiftDeclarationPrintConfiguration {
+    /// Sets the switches RuntimeViewer's Swift Generation Options decide.
+    /// The one mapping from those options to the printer's: the content
+    /// pane's printer is configured with it, and a Find search reads the
+    /// corpus under it (`RuntimeInterfaceVisibility`), so the two can never
+    /// disagree on what an option shows.
+    mutating func applySwitches(of options: SwiftGenerationOptions) {
+        printStrippedSymbolicItem = options.printStrippedSymbolicItem
+        printFieldOffset = options.printFieldOffset
+        printExpandedFieldOffsets = options.printExpandedFieldOffset
+        printMemberAddress = options.printMemberAddress
+        printVTableOffset = options.printVTableOffset
+        printPWTOffset = options.printPWTOffset
+        printTypeLayout = options.printTypeLayout
+        printEnumLayout = options.printEnumLayout
+        infersObjCOverridesFromSelectorNames = options.infersObjCOverridesFromSelectorNames
+    }
+}
+
+extension SwiftGenerationOptions {
+    /// Whether the printer resolves opaque types: the content pane registers
+    /// the opaque type resolver exactly when this is on, and a search's
+    /// visibility predicate reads the corpus's resolved constraints under it.
+    var resolvesOpaqueTypes: Bool {
+        synthesizeOpaqueType
+    }
+}
 
 extension RuntimeSwiftSection {
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceVisibility.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceVisibility.swift
@@ -20,21 +20,11 @@
 
     init(_ options: RuntimeObjectInterface.GenerationOptions) {
         objcOptions = options.objcHeaderOptions
-        let swiftOptions = options.swiftInterfaceOptions
+        // The same mapping the content pane's printer is configured with.
         var swiftConfiguration = SwiftDeclarationPrintConfiguration()
-        swiftConfiguration.printStrippedSymbolicItem = swiftOptions.printStrippedSymbolicItem
-        swiftConfiguration.printFieldOffset = swiftOptions.printFieldOffset
-        swiftConfiguration.printExpandedFieldOffsets = swiftOptions.printExpandedFieldOffset
-        swiftConfiguration.printMemberAddress = swiftOptions.printMemberAddress
-        swiftConfiguration.printVTableOffset = swiftOptions.printVTableOffset
-        swiftConfiguration.printPWTOffset = swiftOptions.printPWTOffset
-        swiftConfiguration.printTypeLayout = swiftOptions.printTypeLayout
-        swiftConfiguration.printEnumLayout = swiftOptions.printEnumLayout
-        swiftConfiguration.infersObjCOverridesFromSelectorNames = swiftOptions.infersObjCOverridesFromSelectorNames
+        swiftConfiguration.applySwitches(of: options.swiftInterfaceOptions)
         self.swiftConfiguration = swiftConfiguration
-        // The display path registers the opaque type resolver exactly when
-        // this is on (`RuntimeSwiftSection.updateConfiguration`).
-        resolvesOpaqueTypes = swiftOptions.synthesizeOpaqueType
+        resolvesOpaqueTypes = options.swiftInterfaceOptions.resolvesOpaqueTypes
     }
 
     /// Whether the option a region is conditioned on is on. The two
```

**复现测试（示例）**：行为不变，不需要新测试。由现有的 `RuntimeInterfaceCorpusVisibilityTests` 覆盖：它在四组选项下逐条比较投影后的语料与内容区打印出的接口，要求文本和 span 都相等。

**同类**：无。ObjC 一侧直接用 `options.objcHeaderOptions`，没有自己的映射。语料打印器 `corpusPrinter(for:)` 也经过 `buildPrintConfiguration`，自动用上同一份映射。

**工作量**：S；不依赖其它条目。


### PR121.29 取消传不过连接（跨连接取消的整体设计）

- **严重度**：Major
- **审查编号**：A1-2（PR121.05、PR121.06、PR121.09、PR121.30 都以它为前提）
- **状态**：方案待批，代码未改

**问题**：调用方取消一个转发出去的请求时，取消既到不了服务端，也不会让调用方提前返回。在 XPC 上，SwiftyXPC 的 `sendMessage` 是一个不响应取消的 continuation，服务端为每条消息开一个没有句柄的 `Task`。在 socket 上，`RuntimeMessageChannel.sendRequest` 也一样不响应取消。引擎层的 `dispatch(_:onProgress:)` 也没有 `withTaskCancellationHandler`。后果有三：Find 换了查询后，旧搜索的批次照样送达；Report navigator 点 Cancel 后，服务端照样在构建；关窗口、换引擎后，服务进程或被注入的进程还在为没人要的结果干活。

**四问**：
- 复现：App 里的 My Mac 引擎转发给 local runtime service。对它构建 Foundation 的语料，收到第一条进度后取消调用方的 Task：调用方一直等到整个构建结束（几十秒）才返回，服务端的 coverage 也一直显示 `.building`。
- 基线：基线就有，属于传输层缺口。本 PR 是第一个让它产生错误结果的功能。
- 影响：Find 和 Report navigator 的取消语义全部依赖它，建议修。
- 历史：4c8cccd1 引入按 token 路由进度时，明确只处理「推送晚于回复」的情况。取消从来没有跨过连接。

**改法**：
- **只在引擎层做**。按请求 id 取消，不改 SwiftyXPC、HelperPeer 或 socket 的帧格式。
- **线格式**：`RuntimeEngineProgressEnvelope` 加可选的 `requestIdentifier`。旧端解码时忽略未知键，旧客户端不发这个字段则为 `nil`，两个方向都兼容。
- **新命令 `cancelRequest`**：不需要回复，载荷是 `RuntimeEngineRequestCancellation(requestIdentifier:)`。在 `registerSharedHandlers` 里注册后，引擎的 server 角色和 `RuntimeEngineConnectionServer` 都会自动获得它。
- **服务端**：
  - `registerSharedHandlers` 为每条连接新建一个 `RuntimeEngineInboundRequests` actor。
  - `registerProgress` 收到带 id 的信封时，把 `engine.dispatch` 放进一个它握有句柄的子 `Task`，按 id 登记。
  - 取消命令按 id 取消对应的 Task。
  - 取消可能比请求先到：两者是独立的消息，传输层可能以任意顺序执行它们的处理器。这时先记一条「提前取消」，请求登记时立即取消。这类记录最多保留 256 条。
- **客户端**：
  - 转发时生成 id，发送前先 `try Task.checkCancellation()`，再用 `withTaskCancellationHandler` 包住发送。
  - `onCancel` 先同步置位一个取消标志，再异步发出 `cancelRequest`。
  - 进度路由先检查这个标志：取消之后到达的推送一律丢弃，不管对端是什么版本。
  - 调用方已取消时，对端的任何失败回复都按 `CancellationError` 上报（这一条也是 PR121.30 的一部分）。
- **只对新命令开启**：`RuntimeEngineProgressRequest` 加 `static var cancelsAcrossConnections: Bool`，默认 `false`。只有语料构建和两种搜索返回 `true`。这三条命令只存在于包含本修复的服务端，所以 `cancelRequest` 永远不会发给不认识它的对端；按 PR121.73 的分析，经 mach service 发给旧版注入 payload 的未知命令会让对端把连接标成断开。
- **镜像链路自然组合**：中间那台机器的处理 Task 被取消后，它自己转发时注册的 `onCancel` 会继续向上游发取消。
- **不选的方案**：
  - 传输层通用取消：要改 SwiftyXPC 和 HelperPeer 的帧，XPC 上新旧版本混用会出问题。
  - 命令级撤回（构建按订阅 id 撤回、搜索按搜索 id 取消）：两套逻辑，同样需要新命令。
- **diff 的省略**：
  - `registerSharedHandlers` 里四个 `registerProgress` 调用改法相同，diff 只写出了其中一个，其余三个用一行省略注释代替。
  - `SearchMembersRequest` 的开启方式与 `SearchInterfacesRequest` 相同，同样只写了一个。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineRequestCancellation.swift
@@ -0,0 +1,69 @@
+import Foundation
+
+/// Payload of `RuntimeEngine.CommandNames.cancelRequest`: the identifier the
+/// requesting peer minted for the request it no longer wants.
+struct RuntimeEngineRequestCancellation: Codable, Sendable {
+    let requestIdentifier: String
+}
+
+/// The cancellable requests one connection is serving, keyed by the
+/// identifier the requesting peer put in `RuntimeEngineProgressEnvelope`.
+///
+/// A `cancelRequest` and the request it names are separate messages, and a
+/// transport may run their handlers in either order. A cancellation for an
+/// identifier that is not registered yet is therefore remembered and applied
+/// the moment the request registers. The memory is bounded: a cancellation
+/// whose request already finished leaves an entry that only ages out.
+actor RuntimeEngineInboundRequests {
+    static let maximumEarlyCancellationCount = 256
+
+    private var cancellationsByRequestIdentifier: [String: @Sendable () -> Void] = [:]
+
+    private var earlyCancellationIdentifiers: [String] = []
+
+    func register(_ requestIdentifier: String, cancellation: @escaping @Sendable () -> Void) {
+        if let index = earlyCancellationIdentifiers.firstIndex(of: requestIdentifier) {
+            earlyCancellationIdentifiers.remove(at: index)
+            cancellation()
+            return
+        }
+        cancellationsByRequestIdentifier[requestIdentifier] = cancellation
+    }
+
+    func unregister(_ requestIdentifier: String) {
+        cancellationsByRequestIdentifier[requestIdentifier] = nil
+    }
+
+    func cancel(_ requestIdentifier: String) {
+        if let cancellation = cancellationsByRequestIdentifier.removeValue(forKey: requestIdentifier) {
+            cancellation()
+            return
+        }
+        earlyCancellationIdentifiers.append(requestIdentifier)
+        let overflow = earlyCancellationIdentifiers.count - Self.maximumEarlyCancellationCount
+        if overflow > 0 {
+            earlyCancellationIdentifiers.removeFirst(overflow)
+        }
+    }
+}
+
+/// Set, synchronously, the moment the caller of a forwarded request is
+/// cancelled, so the request's progress route can drop pushes that arrive
+/// after that moment. `NSLock` instead of `withLock`, which needs macOS 13.
+final class RuntimeEngineRequestCancellationFlag: @unchecked Sendable {
+    private let lock = NSLock()
+
+    private var isSet = false
+
+    var isCancelled: Bool {
+        lock.lock()
+        defer { lock.unlock() }
+        return isSet
+    }
+
+    func cancel() {
+        lock.lock()
+        defer { lock.unlock() }
+        isSet = true
+    }
+}
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineRequest.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineRequest.swift
@@ -51,16 +51,27 @@ public protocol RuntimeEngineProgressRequest: RuntimeEngineRequest {
 public protocol RuntimeEngineProgressRequest: RuntimeEngineRequest {
     associatedtype Progress: Codable & Sendable
 
+    /// Whether cancelling the caller of a forwarded request withdraws it in
+    /// the serving process too. Opt in only for commands every peer that
+    /// answers them also understands `cancelRequest` — commands added in the
+    /// same release, or later — because an older peer cannot ignore an
+    /// unknown message on every transport.
+    static var cancelsAcrossConnections: Bool { get }
+
     /// Local implementation reporting incremental progress. Implementations
     /// must `await` `reportProgress` at each report site so events stay
     /// ordered end-to-end (the wire layer serializes on that await).
     func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (Progress) async -> Void) async throws -> Response
 }
 
 extension RuntimeEngineProgressRequest {
+    public static var cancelsAcrossConnections: Bool {
+        false
+    }
+
     /// Plain execution defaults to the progress-bearing variant with a no-op
     /// listener, so conformers implement a single method.
     public func perform(on engine: RuntimeEngine) async throws -> Response {
         try await perform(on: engine) { _ in }
     }
 }
@@ -70,6 +81,10 @@ extension RuntimeEngineProgressRequest {
 struct RuntimeEngineProgressEnvelope<Request: Codable & Sendable>: Codable, Sendable {
     /// Routing key the serving peer must echo on every progress push for this
     /// round trip; `nil` disables progress reporting.
     let progressToken: String?
     let request: Request
+    /// Names this round trip for `cancelRequest`. `nil` for requests that do
+    /// not cancel across connections, and from peers that predate it; a peer
+    /// that predates it ignores the key.
+    var requestIdentifier: String? = nil
 }
@@ -122,22 +137,43 @@ extension RuntimeEngine {
     /// The progress push is best-effort (`try?`) — a dropped push must not
     /// fail the request itself, matching the pre-existing behavior of the
     /// hand-rolled `objectsLoadingProgress` channel this replaces.
+    ///
+    /// A request whose envelope names itself runs in a task registered in
+    /// `inboundRequests`, so a `cancelRequest` from the peer can reach it:
+    /// the transport runs this handler in a task nobody holds a handle to.
     static func registerProgress<R: RuntimeEngineProgressRequest>(
         _ requestType: R.Type,
         on connection: any RuntimeConnection,
-        engine: RuntimeEngine
+        engine: RuntimeEngine,
+        inboundRequests: RuntimeEngineInboundRequests
     ) {
         connection.setMessageHandler(name: R.commandName) { (envelope: RuntimeEngineProgressEnvelope<R>) -> R.Response in
-            guard let token = envelope.progressToken else {
-                return try await engine.dispatch(envelope.request, onProgress: nil)
-            }
-            return try await engine.dispatch(envelope.request) { progress in
-                guard let payload = try? JSONEncoder().encode(progress) else { return }
-                try? await connection.sendMessage(
-                    name: RuntimeEngine.CommandNames.progressEvent.commandName,
-                    request: RuntimeEngineProgressPush(token: token, payload: payload)
-                )
-            }
+            let onProgress: (@Sendable (R.Progress) async -> Void)?
+            if let token = envelope.progressToken {
+                onProgress = { progress in
+                    guard let payload = try? JSONEncoder().encode(progress) else { return }
+                    try? await connection.sendMessage(
+                        name: RuntimeEngine.CommandNames.progressEvent.commandName,
+                        request: RuntimeEngineProgressPush(token: token, payload: payload)
+                    )
+                }
+            } else {
+                onProgress = nil
+            }
+            guard let requestIdentifier = envelope.requestIdentifier else {
+                return try await engine.dispatch(envelope.request, onProgress: onProgress)
+            }
+            let work = Task {
+                try await engine.dispatch(envelope.request, onProgress: onProgress)
+            }
+            await inboundRequests.register(requestIdentifier) { work.cancel() }
+            let result = await withTaskCancellationHandler {
+                await work.result
+            } onCancel: {
+                work.cancel()
+            }
+            await inboundRequests.unregister(requestIdentifier)
+            return try result.get()
         }
     }
 
@@ -147,8 +179,18 @@ extension RuntimeEngine {
     /// matching Request struct in `RuntimeEngine+Requests.swift` /
     /// `RuntimeEngine+GenericSpecialization.swift`.
     static func registerSharedHandlers(on connection: any RuntimeConnection, engine: RuntimeEngine) {
+        // One registry per connection: an identifier is meaningful only to
+        // the peer that minted it.
+        let inboundRequests = RuntimeEngineInboundRequests()
+        connection.setMessageHandler(name: CommandNames.cancelRequest.commandName) { (cancellation: RuntimeEngineRequestCancellation) in
+            await inboundRequests.cancel(cancellation.requestIdentifier)
+        }
         register(IsImageLoadedRequest.self, on: connection, engine: engine)
         register(IsImageIndexedRequest.self, on: connection, engine: engine)
         register(MainExecutablePathRequest.self, on: connection, engine: engine)
         register(LoadImageRequest.self, on: connection, engine: engine)
-        registerProgress(LoadImageWithProgressRequest.self, on: connection, engine: engine)
+        registerProgress(LoadImageWithProgressRequest.self, on: connection, engine: engine, inboundRequests: inboundRequests)
+        // … (the same `inboundRequests:` argument added to the other three
+        //    registerProgress calls: ObjectsInImageRequest,
+        //    BuildInterfaceCorpusRequest, SearchInterfacesRequest,
+        //    SearchMembersRequest)
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
@@ -82,5 +82,9 @@ public actor RuntimeEngine {
         /// Shared side channel for `RuntimeEngineProgressRequest` pushes.
         /// Carries `RuntimeEngineProgressPush` frames routed by token, so a
         /// single command name serves every progress-bearing request type.
         case progressEvent
+        /// Withdraws one request the peer is serving for this engine, named by
+        /// the `requestIdentifier` its envelope carried. Sent only for request
+        /// types that opt in through `cancelsAcrossConnections`.
+        case cancelRequest
         case specializationRequest
@@ -913,25 +917,55 @@ public actor RuntimeEngine {
     func dispatch<R: RuntimeEngineProgressRequest>(
         _ request: R,
         onProgress: (@Sendable (R.Progress) async -> Void)?
     ) async throws -> R.Response {
         if forwardsRequests {
             guard let connection else { throw RequestError.senderConnectionIsLose }
-            guard let onProgress else {
-                return try await connection.sendMessage(
-                    name: R.commandName,
-                    request: RuntimeEngineProgressEnvelope(progressToken: nil, request: request)
-                )
-            }
-            let token = UUID().uuidString
-            progressRoutes[token] = { payload in
-                guard let progress = try? JSONDecoder().decode(R.Progress.self, from: payload) else { return }
-                await onProgress(progress)
-            }
-            defer { progressRoutes.removeValue(forKey: token) }
-            return try await connection.sendMessage(
-                name: R.commandName,
-                request: RuntimeEngineProgressEnvelope(progressToken: token, request: request)
-            )
+            let cancellation = RuntimeEngineRequestCancellationFlag()
+            var progressToken: String?
+            if let onProgress {
+                let token = UUID().uuidString
+                progressRoutes[token] = { payload in
+                    // A push that lands after the caller gave up belongs to
+                    // work nobody is waiting for any more.
+                    guard !cancellation.isCancelled,
+                          let progress = try? JSONDecoder().decode(R.Progress.self, from: payload)
+                    else { return }
+                    await onProgress(progress)
+                }
+                progressToken = token
+            }
+            defer {
+                if let progressToken {
+                    progressRoutes.removeValue(forKey: progressToken)
+                }
+            }
+            guard R.cancelsAcrossConnections else {
+                return try await connection.sendMessage(
+                    name: R.commandName,
+                    request: RuntimeEngineProgressEnvelope(progressToken: progressToken, request: request)
+                )
+            }
+            let requestIdentifier = UUID().uuidString
+            let envelope = RuntimeEngineProgressEnvelope(progressToken: progressToken, request: request, requestIdentifier: requestIdentifier)
+            try Task.checkCancellation()
+            do {
+                return try await withTaskCancellationHandler {
+                    try await connection.sendMessage(name: R.commandName, request: envelope)
+                } onCancel: {
+                    cancellation.cancel()
+                    Task {
+                        try? await connection.sendMessage(
+                            name: CommandNames.cancelRequest.commandName,
+                            request: RuntimeEngineRequestCancellation(requestIdentifier: requestIdentifier)
+                        )
+                    }
+                }
+            } catch _ where cancellation.isCancelled {
+                // Whatever the peer answered after the caller gave up — its
+                // own CancellationError folded into a transport failure, or a
+                // failure of the work being torn down — is the cancellation.
+                throw CancellationError()
+            }
         }
         return try await request.perform(on: self, reportProgress: onProgress ?? { _ in })
     }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
@@ -205,6 +205,7 @@ extension RuntimeEngine {
         let transformer: Transformer.Configuration
         let isPrioritized: Bool
         static var commandName: String { CommandNames.buildInterfaceCorpus.commandName }
+        static var cancelsAcrossConnections: Bool { true }
         func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void) async throws -> RuntimeInterfaceCorpusBuildSummary {
             try await engine._buildInterfaceCorpus(for: imagePath, transformer: transformer, isPrioritized: isPrioritized, reportProgress: reportProgress)
         }
@@ -224,6 +225,8 @@ extension RuntimeEngine {
         typealias Progress = [RuntimeInterfaceSearchMatch]
         let query: RuntimeInterfaceSearchQuery
         static var commandName: String { CommandNames.searchInterfaces.commandName }
+        static var cancelsAcrossConnections: Bool { true }
         func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
             try await engine._searchInterfaces(query, reportProgress: reportProgress)
         }
+    // … (SearchMembersRequest gets the same `cancelsAcrossConnections` line)
```

文档注释同批修改：`RuntimeEngine+Search.swift:11-14` 的「Cancelling the calling task withdraws this caller's subscription」要补一句：对转发引擎而言，撤回通过 `cancelRequest` 送达服务进程。`Documentations/CommunicationAndEngineArchitecture.md` 的进度请求一节，同步写明信封新增的字段、`cancelRequest` 命令和「提前取消」的登记表。

**复现测试（示例）**：新建 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RemoteRequestCancellationTests.swift`，复用 `RuntimeLocalRuntimeServiceHostTests` 的匿名 listener 装置。修复前，客户端要等 Foundation 整个构建完才返回（几十秒），所以 3 秒内返回的断言失败；同时服务端 coverage 一直是 `.building`，第二条断言也失败。
```swift
#if os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

@Suite("Remote request cancellation", .serialized)
struct RemoteRequestCancellationTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private static func makeHost() async throws -> (host: RuntimeLocalRuntimeServiceHost, endpoint: RuntimeXPCServiceEndpoint) {
        let serviceEngine = RuntimeEngine(source: .local, engineID: "remote-request-cancellation.host")
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeLocalRuntimeServiceHost(engine: serviceEngine, connection: listener)
        try await host.start()
        host.activate()
        return (host, endpoint)
    }

    private static func makeClient(for endpoint: RuntimeXPCServiceEndpoint, engineID: String) async throws -> RuntimeEngine {
        let client = RuntimeEngine(source: .local, engineID: engineID)
        try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
        return client
    }

    @Test("Cancelling a forwarded corpus build stops it in the serving process")
    func cancellingForwardedBuildStopsTheServer() async throws {
        let (host, endpoint) = try await Self.makeHost()
        let client = try await Self.makeClient(for: endpoint, engineID: "remote-request-cancellation.build")
        defer { Task { await client.stop(); await host.stop() } }
        try await host.engine.loadImage(at: Self.foundationPath)

        let progressCount = Counter()
        let build = Task {
            try await client.buildInterfaceCorpus(for: Self.foundationPath, transformer: .default) { _ in
                await progressCount.increment()
            }
        }
        let didStart = await pollUntil(timeout: .seconds(60)) { await progressCount.value > 0 }
        #expect(didStart)

        build.cancel()
        let cancelledAt = ContinuousClock.now
        let result = await build.result
        #expect(ContinuousClock.now - cancelledAt < .seconds(3), "the client waited for the whole build")
        #expect(throws: CancellationError.self) { try result.get() }

        let stoppedOnServer = await pollUntil(timeout: .seconds(3)) {
            let coverage = try? await host.engine.interfaceCorpusCoverage()
            return coverage?.statesByImagePath[Self.foundationPath] == nil
        }
        #expect(stoppedOnServer, "the serving process kept building after the client cancelled")
    }

    @Test("No progress reaches the caller after it cancels")
    func noProgressAfterCancellation() async throws {
        let (host, endpoint) = try await Self.makeHost()
        let client = try await Self.makeClient(for: endpoint, engineID: "remote-request-cancellation.progress")
        defer { Task { await client.stop(); await host.stop() } }
        try await host.engine.loadImage(at: Self.foundationPath)

        let isCancelled = RuntimeEngineRequestCancellationFlag()
        let progressAfterCancellation = Counter()
        let build = Task {
            try await client.buildInterfaceCorpus(for: Self.foundationPath, transformer: .default) { _ in
                if isCancelled.isCancelled { await progressAfterCancellation.increment() }
                // A slow consumer, so pushes are still queued when the caller cancels.
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try await Task.sleep(for: .seconds(2))
        isCancelled.cancel()
        build.cancel()
        _ = await build.result
        try await Task.sleep(for: .milliseconds(500))
        #expect(await progressAfterCancellation.value == 0)
    }
}

private func pollUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

#endif
```
socket 版本按同样的两条断言再写一遍，把装置换成一对 `.localSocket(name:identifier:role:)` 引擎：server 端照 `RuntimeViewerServer.swift:62` 的写法创建，`connect()` 放在单独的 `Task` 里跑。还要补一条「对端不响应取消」：把服务端的 `cancelRequest` 处理器换成空实现，断言客户端不会挂住，也不再收到进度。

**同类**：
- `TypeRelationshipsRequest` 目前是普通请求，同样取消不过连接（PR121.67）。办法是改成 `Progress = RuntimeEngineEmpty` 的进度请求（不发推送），并开启 `cancelsAcrossConnections`。它是本 PR 新增的命令，改形状没有兼容负担。
- 其余进度请求（`objectsInImage`、`loadImageWithProgress`）保持不开启：`dlopen` 撤不回来，而且旧对端不认识 `cancelRequest`。

**工作量**：L。PR121.09、PR121.30 以及 PR121.05 的服务端那一半都依赖它。


### PR121.30 store 发起的取消跨过连接后被记成失败

- **严重度**：Minor
- **审查编号**：C07（属于上次第 8 条的一部分）
- **状态**：方案待批，代码未改

**问题**：store 有时会替所有订阅者取消一次构建，例如另一个窗口改了 transformer 后清掉全部语料，或者语料开关被关掉。订阅者此时收到 `CancellationError`，但这个错误跨不过连接：
- XPC 只传 `localizedDescription`，客户端收到的是 `RuntimeXPCServiceConnectionError.remoteFailure("…Swift.CancellationError error 1.")`。
- socket 传的是 `"\(error)"`，客户端收到的是 `RuntimeNetworkRequestError`。

所以协调器 `finishBuildRequest` 里的 `.failure(is CancellationError)` 分支永远匹配不上，Report navigator 的历史里会多出一条假的 Failed。

**四问**：
- **复现**：开两个窗口，都用 My Mac 引擎（实际走 local runtime service）。A 窗口有语料在构建时修改 Settings › Transformer。两秒后，B 窗口的重建流程会清掉全部语料，A 的那次构建随之被取消，A 的 Report 里出现一条「Failed: The operation couldn't be completed. (Swift.CancellationError error 1.)」。
- **基线**：本 PR 新引入。语料命令是新的，错误抹平的问题以前不会造成可见后果。
- **影响**：只是误导性的历史记录，不影响功能。建议修，改动小。
- **历史**：新代码，没有修过。

**改法**：
- 采纳模块 B1 的建议，不改传输层，而是把「取消」变成构建命令的**结果值**。
  - `BuildInterfaceCorpusRequest` 在线上的响应改为内部枚举 `RuntimeInterfaceCorpusBuildOutcome`，取值为 `built(summary)` / `cancelled` / `imageNotIndexed`（第三种供 PR121.32 使用）。
  - 服务端的 `_buildInterfaceCorpus` 接住 `CancellationError`，返回 `.cancelled`。结果值能原样穿过任何传输和任意长的镜像链路。
  - 公开的 `buildInterfaceCorpus` 仍返回 summary：遇到 `.cancelled` 时在本进程抛出 `CancellationError`，遇到 `.imageNotIndexed` 时抛出新的公开错误 `RuntimeInterfaceCorpusBuildError.imageNotIndexed`。
  - 协调器现有的 `.failure(is CancellationError)` 分支因此不用改，又能匹配上了。
  - 构建命令是本 PR 新增的，改它的响应形状没有兼容负担。
- 调用方**自己**发起的取消（搜索也一样）由 PR121.29 处理：`dispatch` 里规定，调用方已取消时，对端回来的任何失败都当作 `CancellationError`。所以这里不需要给每种传输的错误加类型。
- 同批处理一个同类问题：`RuntimeNetworkRequestError` 没有遵循 `LocalizedError`，任何经 socket 传回的远端错误都显示成「…RuntimeNetworkRequestError error 1.」（模块 B1 转来）。让它遵循 `LocalizedError`，`errorDescription` 直接返回 `message`。
- 还有一个同类问题，本条**只给方向，没有 diff**：连接中断时，每个在途构建都会被记一条 Failed（XPC service 被重启时是 `serviceExited`，socket 断开时是 `notConnected`）。这类失败应当归为「中断」，清空状态、不写历史，然后在 PR121.05 提出的「引擎已重置」信号到来时重新请求。各传输的断连错误类型目前有一部分是 internal 的，要先在 `RuntimeViewerCommunication` 加一个公开的判定函数才能在协调器里识别，所以和那个信号一起做。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeInterfaceSearch.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeInterfaceSearch.swift
@@ -197,8 +197,35 @@ public struct RuntimeInterfaceCorpusBuildSummary: Hashable, Codable, Sendable {
         self.skippedCount = skippedCount
         self.byteCount = byteCount
     }
 }
 
+/// How a corpus build request ended, as it travels between engines.
+///
+/// The ends that are not a summary are values rather than thrown errors so
+/// they survive every transport: a thrown error crosses a connection as its
+/// description only, and a `CancellationError` that arrives as a description
+/// is a failure to the caller.
+enum RuntimeInterfaceCorpusBuildOutcome: Hashable, Codable, Sendable {
+    case built(RuntimeInterfaceCorpusBuildSummary)
+    /// The store gave the build up for every subscriber — an eviction, a
+    /// transformer change elsewhere — or this caller withdrew.
+    case cancelled
+    /// The image does not have both sections built, so there is nothing to
+    /// print; it is asked for again once it is indexed.
+    case imageNotIndexed
+}
+
+public enum RuntimeInterfaceCorpusBuildError: Error, Hashable, Sendable, LocalizedError {
+    case imageNotIndexed(imagePath: String)
+
+    public var errorDescription: String? {
+        switch self {
+        case .imageNotIndexed(let imagePath):
+            "\(imagePath) is not indexed yet, so its interfaces cannot be searched."
+        }
+    }
+}
+
 /// Where one image's corpus stands.
 ///
 /// There is no "unbuilt" case: an image absent from the coverage map is one
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
@@ -20,9 +20,17 @@ extension RuntimeEngine {
     public func buildInterfaceCorpus(
         for imagePath: String,
         transformer: Transformer.Configuration,
         isPrioritized: Bool = false,
         onProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void = { _ in }
     ) async throws -> RuntimeInterfaceCorpusBuildSummary {
-        try await dispatch(BuildInterfaceCorpusRequest(imagePath: imagePath, transformer: transformer, isPrioritized: isPrioritized), onProgress: onProgress)
+        let outcome = try await dispatch(BuildInterfaceCorpusRequest(imagePath: imagePath, transformer: transformer, isPrioritized: isPrioritized), onProgress: onProgress)
+        switch outcome {
+        case .built(let summary):
+            return summary
+        case .cancelled:
+            throw CancellationError()
+        case .imageNotIndexed:
+            throw RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: imagePath)
+        }
     }
 
@@ -92,10 +101,15 @@ extension RuntimeEngine {
     func _buildInterfaceCorpus(
         for imagePath: String,
         transformer: Transformer.Configuration,
         isPrioritized: Bool,
         reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void
-    ) async throws -> RuntimeInterfaceCorpusBuildSummary {
+    ) async throws -> RuntimeInterfaceCorpusBuildOutcome {
         let canonical = DyldUtilities.patchImagePathForDyld(imagePath)
-        return try await interfaceCorpusStore.build(imagePath: canonical, transformer: transformer, isPrioritized: isPrioritized, onProgress: reportProgress)
+        do {
+            let summary = try await interfaceCorpusStore.build(imagePath: canonical, transformer: transformer, isPrioritized: isPrioritized, onProgress: reportProgress)
+            return .built(summary)
+        } catch is CancellationError {
+            return .cancelled
+        }
     }
 
@@ -201,10 +216,10 @@ extension RuntimeEngine {
     struct BuildInterfaceCorpusRequest: RuntimeEngineProgressRequest {
-        typealias Response = RuntimeInterfaceCorpusBuildSummary
+        typealias Response = RuntimeInterfaceCorpusBuildOutcome
         typealias Progress = RuntimeInterfaceCorpusBuildProgress
         let imagePath: String
         let transformer: Transformer.Configuration
         let isPrioritized: Bool
         static var commandName: String { CommandNames.buildInterfaceCorpus.commandName }
-        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void) async throws -> RuntimeInterfaceCorpusBuildSummary {
+        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void) async throws -> RuntimeInterfaceCorpusBuildOutcome {
             try await engine._buildInterfaceCorpus(for: imagePath, transformer: transformer, isPrioritized: isPrioritized, reportProgress: reportProgress)
         }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCommunication/Network/RuntimeNetworkError.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCommunication/Network/RuntimeNetworkError.swift
@@ -6,6 +6,11 @@ public enum RuntimeNetworkError: Error {
     case receiveFailed
 }
 
-public struct RuntimeNetworkRequestError: Error, Codable {
+/// A handler failure as it crosses a socket: the description the serving
+/// peer wrote. `LocalizedError`, so it reads as that description rather than
+/// as "RuntimeNetworkRequestError error 1." wherever it is shown.
+public struct RuntimeNetworkRequestError: Error, Codable, LocalizedError {
     public let message: String
+
+    public var errorDescription: String? { message }
 }
```

注：PR121.29 的进度请求测试里，构建被取消时断言的是抛出 `CancellationError`。本条改完后这条断言照样成立，因为公开 API 会把 `.cancelled` 还原成 `CancellationError`。

**复现测试（示例）**：
- 加进 PR121.29 新建的 `RemoteRequestCancellationTests.swift`，复用其中的 XPC 装置。修复前客户端收到的是 `RuntimeXPCServiceConnectionError.remoteFailure`，`#expect(throws:)` 失败。

```swift
@Test("A build the store gives up arrives at a forwarding caller as a cancellation")
func storeCancellationCrossesTheConnection() async throws {
    let (host, endpoint) = try await Self.makeHost()
    let client = try await Self.makeClient(for: endpoint, engineID: "remote-request-cancellation.store")
    defer { Task { await client.stop(); await host.stop() } }
    try await host.engine.loadImage(at: Self.foundationPath)

    let progressCount = Counter()
    let build = Task {
        try await client.buildInterfaceCorpus(for: Self.foundationPath, transformer: .default) { _ in
            await progressCount.increment()
        }
    }
    _ = await pollUntil(timeout: .seconds(60)) { await progressCount.value > 0 }

    // What a transformer change in another window does: the store cancels
    // the build for every subscriber.
    try await host.engine.evictInterfaceCorpus(for: nil)

    let result = await build.result
    #expect(throws: CancellationError.self) { try result.get() }
}
```

- 协调器级的测试放进 `FindCorpusCoordinatorTests`，同样用 XPC 装置（`RuntimeLocalRuntimeServiceHost` 和 `RuntimeXPCServiceListenerConnection.anonymous()` 都是 public）。修复前，`finishedBuilds` 里会出现一条 `.failed`。

```swift
@Test("a build the store cancels leaves no failed entry in the history")
func storeCancellationIsNotAFailure() async throws {
    let serviceEngine = RuntimeEngine(source: .local, engineID: "FindCorpusCoordinatorTests.storeCancellation.host")
    let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
    let host = RuntimeLocalRuntimeServiceHost(engine: serviceEngine, connection: listener)
    try await host.start()
    host.activate()
    let client = RuntimeEngine(source: .local, engineID: "FindCorpusCoordinatorTests.storeCancellation.client")
    try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
    try await serviceEngine.loadImage(at: TestImages.foundation)

    let environment = ViewModelTestEnvironment(runtimeEngine: client)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.requestBuild(of: TestImages.foundation)
    _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) {
        if case .building = $0[TestImages.foundation] { return true }
        return false
    }

    try await serviceEngine.evictInterfaceCorpus(for: nil)

    _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 10) { $0[TestImages.foundation] == nil }
    let recordedFailure = coordinator.finishedBuilds.contains { finishedBuild in
        guard finishedBuild.imagePath == TestImages.foundation else { return false }
        if case .failed = finishedBuild.outcome { return true }
        return false
    }
    #expect(!recordedFailure, "a store cancellation was recorded as a failed build")
    await client.stop()
    await host.stop()
}
```

**同类**：
- `RuntimeNetworkRequestError` 的 `LocalizedError`：已在上面的 diff 中。
- 连接中断时记 Failed：见「改法」最后一条，和「引擎已重置」信号一起做。
- 搜索与关系查询的「调用方已取消」：由 PR121.29 的 `catch _ where` 统一处理。

**工作量**：S–M。依赖 PR121.29（`dispatch` 的改动）。PR121.32 依赖本条新增的 `.imageNotIndexed`。


### PR121.31 socket 上迟到的回复在两端之间无限往返

- **严重度**：Major（读代码推出，尚未复现）
- **审查编号**：新发现（模块 C 在起草跨连接取消时发现，不在审查清单里）
- **状态**：方案待批，代码未改

**问题**：在 socket 传输上，请求超时后，待处理表里就删掉了它。如果回复之后才到，接收端找不到等着它的请求，就把它当成一条新请求去找处理器。发起方通常没有这条命令的处理器，于是回一个带同一 nonce 的错误信封。对端也没有这个 nonce 的待处理项，却**有**这条命令的处理器，于是把错误信封当成请求再执行一遍，然后回复，回复又被当成请求……两端就这样无限循环，持续占用 CPU 和网络，直到连接断开。如果处理器的请求类型从错误 JSON 解码失败，循环照样进行，只是两端变成互相回错误信封。

**四问**：
- **复现**：读代码推出，下面的测试用来确认。
  - 目前唯一带超时的请求是 Bonjour 心跳 `requestEngineList(timeout:)`（`RuntimeEngineManager.swift:442`）。
  - 超时后待处理项被删（`RuntimeMessageChannel.swift:389-392`）。迟到的回复走到处理器查找（:557-565），客户端没有 `engineList` 处理器，就回错误信封（:610-623）。
  - 服务端的 `engineList` 处理器以 `RuntimeMessageNull` 解码请求，错误 JSON 能解码成功，于是再执行一次 `engineList` 并回复，循环就此形成。
- **基线**：基线就有，本 PR 没有改这部分代码。
- **影响**：只要 AWDL 之类的慢链路让一次心跳超时，就可能触发。一旦触发，两台设备都持续空转、浪费流量。建议修，改动很小。
- **历史**：
  - 1d9becf4（2026-06-05）修过同类的往返：错误信封改为按 nonce 送回对方的待处理项，前提是对方还留着这一项。
  - 超时功能 6063be30（2026-04-30）早已让这个前提可能不成立。
  - 2a0573b7（2026-06-11）加了「找不到处理器就回错误信封」，循环由此闭合。
  - 所以这不是修法被冲掉，而是两次各自正确的改动叠加出了新的路径。

**改法**：
- 发起方放弃等待时（目前只有超时，将来任何提前返回的路径都一样），把 nonce 记进一个有上限的「已放弃」列表（最多 256 条）。之后收到同 nonce 的帧直接丢弃。
- `isError == true` 的帧一律当作回复处理，绝不交给处理器。错误信封只可能是回复。
- 两条规则都只作用于接收端，不改线格式。旧对端仍会发出那一条多余的错误信封，但新端不再回应，循环在第一圈就断开。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift
@@ -113,6 +113,15 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
     /// a *different* request that happened to be registered under the same identifier.
     private let pendingRequests = Mutex<[String: PendingRequest]>([:])
 
+    /// Nonces of requests this side stopped waiting for (timed out), newest
+    /// last. Their replies can still arrive; one that is not recognised as a
+    /// reply is taken for a request of the same command and answered, and the
+    /// two peers echo each other forever. Bounded: a reply that never comes
+    /// leaves an entry that only ages out.
+    private let abandonedRequestNonces = Mutex<[String]>([])
+
+    private static let maximumAbandonedRequestNonceCount = 256
+
     /// Buffer for incoming data, plus how far it has already been scanned for an
     /// end-marker. Persisting the scan offset across appends keeps a large
     /// message that arrives in many chunks at O(n) total instead of O(n²) — the
@@ -387,7 +396,8 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
                     try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                     if Task.isCancelled { return }
                     if let pending = self.pendingRequests.withLock({ $0.removeValue(forKey: nonce) }) {
                         #log(.error, "Request \(identifier, privacy: .public) [nonce \(nonce, privacy: .public)] timed out after \(timeout, privacy: .public)s")
+                        self.rememberAbandonedRequest(nonce: nonce)
                         pending.continuation.resume(throwing: RuntimeMessageChannelError.requestTimeout)
                     }
                 }
@@ -553,7 +563,15 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
         if deliverToPendingRequest(routingKey: routingKey, data: data) {
             return
         }
 
+        // A reply nobody waits for any more must not be taken for a request:
+        // answering it sends the peer an envelope of its own command, which it
+        // runs and answers again. An error envelope is always a reply.
+        if requestData.isError == true || takeAbandonedRequest(nonce: requestData.nonce) {
+            #log(.debug, "Dropped a reply to an abandoned request: \(requestData.identifier, privacy: .public)")
+            return
+        }
+
         guard let handler = handler(for: requestData.identifier) else {
             if requestData.nonce != nil {
                 #log(.error, "No handler for: \(requestData.identifier, privacy: .public); replying with error so the caller doesn't hang")
@@ -592,6 +611,26 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
         }
     }
 
+    private func rememberAbandonedRequest(nonce: String) {
+        abandonedRequestNonces.withLock { nonces in
+            nonces.append(nonce)
+            let overflow = nonces.count - Self.maximumAbandonedRequestNonceCount
+            if overflow > 0 {
+                nonces.removeFirst(overflow)
+            }
+        }
+    }
+
+    /// Whether `nonce` names a request this side abandoned, forgetting it.
+    private func takeAbandonedRequest(nonce: String?) -> Bool {
+        guard let nonce else { return false }
+        return abandonedRequestNonces.withLock { nonces in
+            guard let index = nonces.firstIndex(of: nonce) else { return false }
+            nonces.remove(at: index)
+            return true
+        }
+    }
+
     /// Appends `work` to the serial fire-and-forget tail, preserving order.
     private func enqueueOrdered(_ work: @escaping @Sendable () async -> Void) {
         orderedHandlerTail.withLock { tail in
```

**复现测试（示例）**：
- 放在 `RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/ConnectionTransportRegressionTests.swift`。
- 处理器的请求类型是空结构体，所以错误 JSON 也能解码成功，处理器会被一遍遍重新调用，情形和 `engineList` 一样。
- 修复前，等待的 1 秒里调用计数会持续增长（每圈 300 ms），断言失败。修复后计数停在 1。

```swift
@Suite("Transport Regression: reply after timeout", .serialized)
struct TransportLateReplyTests {

    private struct EmptyRequest: Codable {}

    private actor InvocationCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    @Test("LocalSocket: a reply that arrives after its request timed out is dropped, not answered")
    func testLateReplyIsNotAnswered() async throws {
        let identifier = "test-late-reply-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let invocations = InvocationCounter()
        server.setMessageHandler(name: "slow") { (_: EmptyRequest) -> Int in
            await invocations.increment()
            try await Task.sleep(nanoseconds: 300_000_000)
            return 1
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        try await waitUntilConnected(server)

        await #expect(throws: RuntimeMessageChannelError.requestTimeout) {
            let _: Int = try await client.sendMessage(name: "slow", request: EmptyRequest(), timeout: 0.1)
        }
        // Long enough for the late reply to arrive and for several rounds of an echo loop.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(await invocations.count == 1, "the late reply was answered, and the server ran the handler again")

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}
```

**同类**：
- PR121.29 的取消方案**不会**让客户端提前放弃等待：服务端会以「已取消」及时回复，所以不会产生新的迟到回复。
- 将来若给其他请求加超时，或加任何「提前返回」的路径，都要调用 `rememberAbandonedRequest`。在 `rememberAbandonedRequest` 的注释里写明这一点。

**工作量**：S。建议和 PR121.12 放在同一个只改 `RuntimeViewerCommunication` 的传输 PR 里，先进 main。


### PR121.32 为没有索引的镜像请求语料

- **严重度**：Minor
- **审查编号**：C13
- **状态**：方案待批，代码未改

**问题**：语料构建器 `corpusObjects(in:)` 调用的是会创建 section 的 `_objects(in:)`，但协调器会把作用域里任意镜像都送去构建，包括没有索引的镜像。后果分三种：
- 镜像没有加载：报 `invalidMachOImage`，Report 里每次搜索都多一条 Failed。
- 镜像已加载但没有索引：在前后台索引调度之外，以 utility 优先级做一次完整索引，Cancel 也停不下来。
- 路径对不上：`machOImage(forPath:)` 会按文件名回退，把另一个同名镜像索引到请求的路径下，coverage 和 section 缓存里从此多一个错误的条目。macOS 27 的 cache 里有 267 个重名的文件名，例如 MetalKit 和它在 iOSSupport 下的副本。

**四问**：
- **复现**：对一个不存在的路径 `/tmp/NoSuchFramework.framework/Foundation` 请求构建。`RuntimeObjCSection(imagePath:)`（`RuntimeObjCSection.swift:73`）按文件名回退找到真正的 Foundation，于是 coverage 里出现这个假路径，并且显示 `.built`。在 App 里，常见的触发方式是换了引擎但保留了作用域，或在 Current Image 作用域下选中一个还没索引的镜像。
- **基线**：本 PR 新引入。
- **影响**：多数情况下只是失败行和白做的工作，按文件名回退那一支会写坏状态。建议修。
- **历史**：9a3716b5（#72）因为同一个原因，给导出元数据改用 `exactMachOImage`：按文件名回退会选中宿主里的同名框架。这次在语料路径上做得更彻底，干脆不去解析镜像。section 工厂自身的回退不能动，模拟器上的路径匹配要靠它。

**改法**：
- 引擎本地分支 `_buildInterfaceCorpus` 先检查镜像是否已索引（`_isImageIndexed(path:)`，即两个 section 都在）。没有索引时直接返回 PR121.30 引入的 `.imageNotIndexed`，不碰 store。
- `corpusObjects` 改为只读已有的 section。缺了就抛 `RuntimeInterfaceCorpusBuildError.imageNotIndexed`，作为第二道防线：正常情况走不到这里，只在构建期间引擎被停止、section 被释放时才会发生。语料路径从此不会创建 section，也就碰不到按文件名回退。
- 协调器收到 `.imageNotIndexed` 时清空状态、不写历史。这个镜像等真被索引后，由 PR121.04 的「已索引」事件重新请求。
- 下面 `_buildInterfaceCorpus` 那一段 diff 已包含 PR121.30 对同一函数的改动（返回结果值、接住取消），两条可以一起落地。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+Search.swift
@@ -92,10 +92,21 @@ extension RuntimeEngine {
     func _buildInterfaceCorpus(
         for imagePath: String,
         transformer: Transformer.Configuration,
         isPrioritized: Bool,
         reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void
-    ) async throws -> RuntimeInterfaceCorpusBuildSummary {
+    ) async throws -> RuntimeInterfaceCorpusBuildOutcome {
         let canonical = DyldUtilities.patchImagePathForDyld(imagePath)
-        return try await interfaceCorpusStore.build(imagePath: canonical, transformer: transformer, isPrioritized: isPrioritized, onProgress: reportProgress)
+        // A corpus is printed from sections the engine already built; it
+        // never indexes an image itself. Indexing here would bypass both the
+        // foreground and the background schedulers, and for a path dyld does
+        // not know, the section factories' basename fallback would index a
+        // same-named image under this path.
+        guard await _isImageIndexed(path: canonical) else { return .imageNotIndexed }
+        do {
+            let summary = try await interfaceCorpusStore.build(imagePath: canonical, transformer: transformer, isPrioritized: isPrioritized, onProgress: reportProgress)
+            return .built(summary)
+        } catch is CancellationError {
+            return .cancelled
+        }
     }
 
@@ -157,5 +168,14 @@ extension RuntimeEngine {
 extension RuntimeEngine: RuntimeInterfaceCorpusBuilding {
     func corpusObjects(in imagePath: String) async throws -> [RuntimeObject] {
-        try await _objects(in: imagePath).flatMap(\.corpusFamily)
+        // Existing sections only — see `_buildInterfaceCorpus`. Missing ones
+        // mean the engine released them while this build waited (it stopped).
+        guard let objcSection = await objcSectionFactory.existingSection(for: imagePath),
+              let swiftSection = await swiftSectionFactory.existingSection(for: imagePath)
+        else {
+            throw RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: imagePath)
+        }
+        let objcObjects = try await objcSection.allObjects()
+        let swiftObjects = try await swiftSection.allObjects()
+        return (objcObjects + swiftObjects).flatMap(\.corpusFamily)
     }
 
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -311,7 +311,11 @@ public final class FindCorpusCoordinator {
         case .failure(is CancellationError):
             // The store cancelled the build for everyone: another document
             // asked for it under a different transformer, or evicted it.
             buildStatesByImagePath[imagePath] = nil
+        case .failure(is RuntimeInterfaceCorpusBuildError):
+            // Not indexed yet: nothing to print, and nothing went wrong. The
+            // image is asked for again once the engine reports it indexed.
+            buildStatesByImagePath[imagePath] = nil
         case .failure(let error):
             #log(.error, "Corpus build of \(imagePath, privacy: .public) failed: \(error, privacy: .public)")
             let message = "\(error)"
```

**复现测试（示例）**：
- 放在新文件 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceCorpusEligibilityTests.swift`，用进程内引擎即可：问题出在引擎本地分支，与传输无关。
- 修复前三条测试都会失败：
  - 第一条：会把真正的 Foundation 建到假路径下，构建成功，没有抛错。
  - 第二条：会顺手把 libobjc 索引掉。
  - 第三条：会抛 `invalidMachOImage`，coverage 里留下 `.failed`。

```swift
import Testing
import Foundation
@testable import RuntimeViewerCore

@Suite("Corpus builds only for indexed images", .serialized)
struct RuntimeInterfaceCorpusEligibilityTests {
    private static func makeEngine(_ engineID: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        try await engine.connect()
        return engine
    }

    @Test("A path dyld does not know is not indexed under a same-named image")
    func unknownPathIsNotIndexedByBasename() async throws {
        let engine = try await Self.makeEngine("corpus-eligibility.basename")
        defer { Task { await engine.stop() } }
        let bogusPath = "/tmp/NoSuchFramework.framework/Foundation"

        await #expect(throws: RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: bogusPath)) {
            _ = try await engine.buildInterfaceCorpus(for: bogusPath, transformer: .default)
        }
        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[bogusPath] == nil)
        #expect(try await engine.isImageIndexed(path: bogusPath) == false)
    }

    @Test("A loaded image that is not indexed stays unindexed")
    func loadedButUnindexedImageIsNotIndexedByTheCorpus() async throws {
        let engine = try await Self.makeEngine("corpus-eligibility.loaded")
        defer { Task { await engine.stop() } }
        let libobjcPath = "/usr/lib/libobjc.A.dylib"

        await #expect(throws: RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: libobjcPath)) {
            _ = try await engine.buildInterfaceCorpus(for: libobjcPath, transformer: .default)
        }
        #expect(try await engine.isImageIndexed(path: libobjcPath) == false)
    }

    @Test("An image that is not loaded leaves no failed state behind")
    func unloadedImageLeavesNoFailure() async throws {
        let engine = try await Self.makeEngine("corpus-eligibility.unloaded")
        defer { Task { await engine.stop() } }
        let unloadedPath = "/System/Library/Frameworks/GameController.framework/GameController"

        await #expect(throws: RuntimeInterfaceCorpusBuildError.self) {
            _ = try await engine.buildInterfaceCorpus(for: unloadedPath, transformer: .default)
        }
        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[unloadedPath] == nil)
    }
}
```
`GameController` 用作「测试进程没有加载」的框架，落地前先在测试进程里确认它确实没被加载；如果已加载，换一个同样没被加载的框架。

**同类**：
- 本 PR 新代码里只有 `corpusObjects` 会隐式创建 section：搜索读的是已建好的语料（`indexedImagePaths()`），关系表读的是已有的 section。
- 作用域里没有索引的镜像，在摘要里怎么说明（目前说的是「not yet searchable」），由 PR121.05 所属的模块 D1 决定。

**工作量**：S–M。依赖 PR121.30（结果值和错误类型）。PR121.04 负责在镜像真被索引后重新请求。


### PR121.33 iOS 模拟器引擎上同一镜像按原始路径和规范路径各记一份

- **严重度**：Minor
- **审查编号**：C14
- **状态**：方案待批，代码未改

**问题**：
- 引擎遵循「服务端存规范路径、线上传原始路径」的约定（a60155af）。规范路径是在模拟器进程里补上 `DYLD_ROOT_PATH` 前缀后的路径。
- 本 PR 的新命令却把规范路径带回了客户端：coverage 的键、`indexedImagePathList`、搜索摘要里的 `unbuiltIndexedImagePaths`，以及 `imageDidLoad` 推送。
- 后台索引的任务路径（依赖的 install name）、侧栏节点和作用域用的仍是原始路径。
- 协调器直接拿收到的路径当键。在 iOS 模拟器引擎上，同一个镜像于是出现两行，`corpusBuilt` 也会按两种形式各发一次。后果是同一次搜索在会话里被补搜两次，命中翻倍、总数翻倍，Report 和作用域选择器里出现重复行。

**四问**：
- **复现**：附加到一个 iOS 模拟器里的进程，在侧栏选一个共享缓存镜像，用 Current Image 作用域连搜两次。第二次的每条命中都出现两遍，总数翻倍。
- **基线**：本 PR 新引入。
- **影响**：只影响模拟器引擎，结果错误但不会崩溃。建议修，也可以先记为已知问题（见拍板）。
- **历史**：同一类问题在后台索引上修过一次（964e9813、a033d3dd、a60155af）。那次只统一了引擎内部的读写；新命令让规范路径重新回到了客户端。

**改法**：
- **客户端用服务端的根路径来规范化**。客户端自己算不出规范路径，因为根路径属于服务端。
  - 新增 Core 请求 `DyldRootPathRequest`，返回服务进程的 `DYLD_ROOT_PATH`。
  - 客户端只对 socket 类来源取这个值（bonjour、localSocket、directTCP），在建立连接时取一次，重连后再取一次。XPC 类来源和 `.local` 都是 macOS 进程，根路径一定为 `nil`，不需要取。旧对端会回「没有处理器」，按 `nil` 处理。
  - 新增 `RuntimeEngine.canonicalImagePath(_:)`，标为 `nonisolated`，内部用已有的纯函数 `patchImagePathForDyld(_:rootPath:)`。这个函数幂等（a033d3dd），所以对已经规范过的路径再调一次也安全。
- **协调器在入口处统一规范化**。
  - `requestBuild` 和 `cancelBuild` 一进入就先规范化，之后状态、请求和 `corpusBuilt` 都只用规范路径。
  - 发给引擎的也是规范路径。服务端会再规范化一次，因为幂等，结果不变，所以不违反「接收方用自己的根路径来规范化」的约定。
  - 对外提供 `buildState(forImagePath:)`，供 FindSession 查询时使用。
- **删掉 `CommandNames` 里一个早已没人处理的 `patchImagePathForDyld`**。它的处理器在 773b575d（2025-11）里已经删除。
- **一并修一处基线上就有的同类问题**：`DocumentState.isSelectedRuntimeObjectInCurrentImage` 拿规范的 `RuntimeObject.imagePath` 和原始的节点路径比较，导致模拟器上的共享缓存镜像点不了「Reveal in Sidebar」。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+ImagePathCanonicalization.swift
@@ -0,0 +1,59 @@
+import Foundation
+import RuntimeViewerCommunication
+
+/// The `DYLD_ROOT_PATH` of the process that owns an engine's images: what
+/// turns a path as a client spells it into the key the serving process stores
+/// it under. `NSLock` instead of `withLock`, which needs macOS 13.
+final class RuntimeEngineDyldRootPath: @unchecked Sendable {
+    private let lock = NSLock()
+
+    private var rootPath: String?
+
+    init(_ rootPath: String?) {
+        self.rootPath = rootPath
+    }
+
+    var value: String? {
+        lock.lock()
+        defer { lock.unlock() }
+        return rootPath
+    }
+
+    func update(_ rootPath: String?) {
+        lock.lock()
+        defer { lock.unlock() }
+        self.rootPath = rootPath
+    }
+}
+
+extension RuntimeEngine {
+    /// `imagePath` as the process that owns this engine's images keys it —
+    /// the form corpus coverage, the indexed image list and search summaries
+    /// report. Identity on macOS; on an iOS Simulator process it applies that
+    /// process's `DYLD_ROOT_PATH`. Idempotent.
+    public nonisolated func canonicalImagePath(_ imagePath: String) -> String {
+        DyldUtilities.patchImagePathForDyld(imagePath, rootPath: servingDyldRootPath.value)
+    }
+
+    /// Learns the serving process's `DYLD_ROOT_PATH`. Only a socket source can
+    /// lead to an iOS Simulator process; an XPC source is a Mac process, whose
+    /// root is `nil`, and is never sent a command it might not know. A peer
+    /// that predates the command answers with an error, read as `nil`.
+    func refreshServingDyldRootPath() async {
+        guard forwardsRequests, source != .local, !source.isXPC else { return }
+        let rootPath = (try? await dispatch(DyldRootPathRequest())) ?? nil
+        servingDyldRootPath.update(rootPath)
+    }
+
+    /// Test seam: what `canonicalImagePath(_:)` applies, without a simulator.
+    nonisolated func setDyldRootPathForTesting(_ rootPath: String?) {
+        servingDyldRootPath.update(rootPath)
+    }
+
+    struct DyldRootPathRequest: RuntimeEngineRequest {
+        static var commandName: String { CommandNames.dyldRootPath.commandName }
+        func perform(on engine: RuntimeEngine) async throws -> String? {
+            ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
+        }
+    }
+}
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
@@ -64,7 +64,6 @@ public actor RuntimeEngine {
         case canOpenImage
         case rpathsForImage
         case dependenciesForImage
-        case patchImagePathForDyld
         case runtimeObjectHierarchy
         case runtimeRelationshipsForObject
         case runtimeCounterpartForObject
@@ -100,7 +99,10 @@ public actor RuntimeEngine {
         case interfaceCorpusCoverage
         case indexedImagePaths
         case evictInterfaceCorpus
         case setInterfaceCorpusResidentByteLimit
+        /// The serving process's `DYLD_ROOT_PATH`; see
+        /// `RuntimeEngine+ImagePathCanonicalization.swift`.
+        case dyldRootPath
 
         var commandName: String {
             "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.\(rawValue)"
@@ -252,5 +254,9 @@ public actor RuntimeEngine {
     private var progressRoutes: [String: @Sendable (Data) async -> Void] = [:]
 
+    /// The root `canonicalImagePath(_:)` applies: this process's own until a
+    /// client connection learns the serving process's.
+    nonisolated let servingDyldRootPath = RuntimeEngineDyldRootPath(ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"])
+
     let objcSectionFactory: RuntimeObjCSectionFactory
 
     let swiftSectionFactory: RuntimeSwiftSectionFactory
@@ -379,6 +386,9 @@ public actor RuntimeEngine {
             self.setupMessageHandlerForClient()
             self.observeConnectionState(connection)
         }
+        // Before `.connected` goes out, so nothing keys a path while the
+        // serving process's root is still unknown.
+        await refreshServingDyldRootPath()
         #log(.info, "Client connected successfully to \(String(describing: self.source), privacy: .public)")
         stateSubject.send(.connected)
     }
@@ -412,6 +422,10 @@ public actor RuntimeEngine {
         case .connected:
             #log(.info, "Connection state -> connected (source: \(String(describing: self.source), privacy: .public))")
             stateSubject.send(.connected)
+            // A reconnect may reach another process — a relaunched simulator app.
+            if forwardsRequests {
+                Task { await self.refreshServingDyldRootPath() }
+            }
             // Re-register handlers and push data when server reconnects to a new client
             if needsReregistrationOnConnect, source.remoteRole == .server {
                 needsReregistrationOnConnect = false
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineRequest.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineRequest.swift
@@ -178,4 +178,5 @@ extension RuntimeEngine {
         register(IndexedImagePathsRequest.self, on: connection, engine: engine)
         register(EvictInterfaceCorpusRequest.self, on: connection, engine: engine)
         register(SetInterfaceCorpusResidentByteLimitRequest.self, on: connection, engine: engine)
+        register(DyldRootPathRequest.self, on: connection, engine: engine)
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -167,11 +167,25 @@ public final class FindCorpusCoordinator {
 
     // MARK: - Triggers
 
+    /// `imagePath` as the engine keys it. Every path this coordinator stores
+    /// or reports is in this form: on an iOS Simulator engine the sidebar, the
+    /// background indexer and a search scope spell paths without the
+    /// simulator's root, while coverage and search summaries spell them with it.
+    public func canonicalImagePath(_ imagePath: String) -> String {
+        engine.canonicalImagePath(imagePath)
+    }
+
+    /// `imagePath`'s state, however the caller spells the path.
+    public func buildState(forImagePath imagePath: String) -> RuntimeInterfaceCorpusBuildState? {
+        buildStatesByImagePath[canonicalImagePath(imagePath)]
+    }
+
     /// Asks the engine to build `imagePath`'s corpus. A request already open
     /// for the image is not repeated; with `isPrioritized` it is moved to the
     /// front of the engine's queue instead.
-    public func requestBuild(of imagePath: String, isPrioritized: Bool = false) {
+    public func requestBuild(of requestedImagePath: String, isPrioritized: Bool = false) {
         guard isEnabled else { return }
+        let imagePath = canonicalImagePath(requestedImagePath)
         if buildRequests[imagePath] != nil {
             if isPrioritized {
                 let engine = engine
@@ -222,7 +237,8 @@ public final class FindCorpusCoordinator {
     /// navigator's Cancel. Another document asking for the image keeps its
     /// build going, and the withdrawal is not sticky: the next trigger for the
     /// image asks again.
-    public func cancelBuild(of imagePath: String) {
+    public func cancelBuild(of requestedImagePath: String) {
+        let imagePath = canonicalImagePath(requestedImagePath)
         guard let request = buildRequests.removeValue(forKey: imagePath) else { return }
         request.task.cancel()
         buildStatesByImagePath[imagePath] = nil
```
若 PR121.04 先落地：它的 `imageDidIndex(at:)` 和 `currentImagePath` 也要改成先规范化再比较（`currentImagePath = imageNode.map { canonicalImagePath($0.path) }`）。

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
@@ -164,4 +164,6 @@ public final class DocumentState {
     public var isSelectedRuntimeObjectInCurrentImage: Bool {
         guard let selectedRuntimeObject, let currentImageNode else { return false }
-        return selectedRuntimeObject.imagePath == currentImageNode.path
+        // An object's image path is the engine's key; a sidebar node's is not,
+        // on an iOS Simulator engine.
+        return selectedRuntimeObject.imagePath == runtimeEngine.canonicalImagePath(currentImageNode.path)
     }
```

**复现测试（示例）**：
- 放在 `FindCorpusCoordinatorTests.swift`。测试用接缝 `setDyldRootPathForTesting` 模拟模拟器的根路径，只影响客户端的规范化，不影响引擎在本进程里的处理。
- 断言是同步做的：`requestBuild` 和 `mergeCoverage` 之间没有 `await`，请求的 Task 来不及运行，结果是确定的。
- 先只加接缝、不改协调器，测试应当失败：原始路径记一行 `.pending`，规范路径再记一行 `.building`，一共两行。

```swift
@Test("a raw path and its canonical form are one image")
func rawAndCanonicalPathsAreOneImage() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.canonicalPaths")
    engine.setDyldRootPathForTesting("/sim_root")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }
    let rawPath = "/usr/lib/libobjc.A.dylib"
    let canonicalPath = "/sim_root/usr/lib/libobjc.A.dylib"

    coordinator.requestBuild(of: rawPath)
    coordinator.mergeCoverage(RuntimeInterfaceCorpusCoverage(
        statesByImagePath: [canonicalPath: .building(RuntimeInterfaceCorpusBuildProgress(built: 1, total: 10))],
        residentByteCount: 0,
        residentByteLimit: 0
    ))

    #expect(Set(coordinator.buildStatesByImagePath.keys) == [canonicalPath])
    #expect(coordinator.buildState(forImagePath: rawPath) != nil)
    await engine.stop()
}
```

`setDyldRootPathForTesting` 是 Core 的 internal 接缝。`FindCorpusCoordinatorTests.swift` 要把 `import RuntimeViewerCore` 改成 `@testable import RuntimeViewerCore`，SwiftPM 的 Debug 构建默认开启 testing，可以这样导入。

`RuntimeViewerCore` 里再加一条纯函数测试：根路径为 `/sim_root` 时，`canonicalImagePath("/usr/lib/x")` 等于 `/sim_root/usr/lib/x`，对结果再调一次值不变；根路径为 `nil` 时原样返回。

**同类**（都是原始路径对规范路径）：
- `FindSession.swift:234` 的 `corpusBuildStates[imagePath]`，以及 `:384-387` 的三处比较（`corpusBuilt` 给的路径、`scannedImagePaths`、作用域路径）。改成用 `buildState(forImagePath:)` 和 `canonicalImagePath`，由模块 D1 处理（PR121.05）。
- `FindScopeChooserViewModel.swift:76`：用原始的当前镜像路径去对 `indexedImagePathList` 返回的规范路径，由模块 D2 处理（PR121.45）。
- `DocumentState.isSelectedRuntimeObjectInCurrentImage`：基线就有（2857bbb5），已在上面的 diff 中一并修。

**拍板**：只影响模拟器引擎，可以先作为已知问题记下。推荐修，因为同一次改动还修好了基线上的「Reveal in Sidebar」问题。

**工作量**：M。PR121.04 和 PR121.34 的比较都要用到这里的规范化。


### PR121.34 被悄悄驱逐的语料仍显示已建好；历史满额时 Clear History 失效

- **严重度**：Minor
- **审查编号**：C16 + AL5
- **状态**：方案待批，代码未改

**问题**：本条包含两个独立的问题。

**(a) 语料被驱逐后仍显示「已建好」，导致镜像再也不被重新请求。**
- store 按预算驱逐语料时不通知任何人。
- 协调器只在三个时机刷新 coverage：启动时、本文档的构建完成时、Report navigator 出现时。在这三个时机之间，被驱逐的镜像状态一直停在 `.built`。
- `FindSession.prioritizeCorpora` 看到 `.built` 就跳过这个镜像，于是 Current Image 搜索一直报告它「not yet searchable」，而且再也不会去重新请求。

**(b) 历史满额时，Clear History 会把旧条目带回来。**
- 历史已满 100 条时，`mergeCoverage` 在把新学到的语料记入「已列过」之前就提前返回了。这些语料既没有显示，也没有被记住。
- 用户点 Clear History 后，下一次刷新会把它们全部列出来。这等于在满额时撤销了 e7186ae1 的效果——那次提交的目的正是「清空后保持清空」。

**四问**：
- **复现**：
  - (a) 在 Settings 里调低语料内存预算，让 Foundation 的语料被挤出去，然后在 Foundation 的 Current Image 作用域里搜索。摘要一直显示「1 image not yet searchable」，它不会被重新请求，直到 Report navigator 出现或本文档有别的构建完成。
  - (b) 让历史攒满 100 条，再让另一个窗口建出几份语料。点 Clear History 后切到 Report 页，那几条又出现了。
- **基线**：都是本 PR 新引入的。
- **影响**：
  - (a) 默认 256 MB 的预算下很少碰到，用户调低预算后一定会碰到，建议修。
  - (b) 只影响显示，但它让 e7186ae1 在满额时失效，建议顺手修。
- **历史**：
  - e7186ae1 加上了「已列过」的记录，但当时没有考虑满额的情况。
  - 「历史靠轮询 coverage 学习」是提案认可的设计，见 `draft-find-navigator.md` 决策日志 2026-10-01。

**改法**：
- **(a) 新增 `reconcile(unbuiltIndexedImagePaths:scopeImagePaths:)`**，由 FindSession 在每次搜索结束时调用。搜索结束正是要紧的时刻：搜索刚刚把「哪些镜像没看到」告诉了用户。
  - 本地记为 `.built`、但摘要说没建、又没有在途请求的镜像：先清掉这个过期状态。
  - 作用域里的镜像：按优先级重新请求。
  - 作用域是「全部镜像」时：只请求本文档从未请求过的镜像。这样能兜住 PR121.04 漏掉的情况（别的进程索引的镜像），又不会在预算偏小时每搜一次就把刚被驱逐的镜像重建一遍，陷入「建一个、挤掉一个」的循环。
- **(b) 把 `imagePathsListedInHistory.formUnion(learned)` 移到满额判断之前。**学到但放不下的语料，按「最旧的被挤出」的语义也算列过。
- **AL5 的其余部分建议不修**，裁决理由如下（写入 KnownIssues）：
  - 用轮询 coverage 学习其他文档的构建是提案认可的设计。改成由 store 主动推送事件需要一条新命令，收益抵不过成本；需要准确的时刻（搜索结束、Report 出现、本文档的构建完成）都已经有刷新或对账。
  - 「部分放得下时全部记为已列过」与「最旧的被挤出」一致，不改。
- **与 PR121.33 的关系**：如果 PR121.33 先落地，`scopeImagePaths` 要先经 `canonicalImagePath` 规范化，因为摘要里的路径是规范形式。下面的 diff 按 12e1227b 写，没有包含这一步。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -248,6 +248,30 @@ public final class FindCorpusCoordinator {
         }
     }
 
+    /// Squares this document's states with a finished search's unbuilt
+    /// images. An image this document believed built was evicted since — the
+    /// store evicts without telling anyone — so its state goes. The images of
+    /// the search's scope are asked for first. With every indexed image in
+    /// scope only images this document never asked for are: those are the
+    /// ones it was never told about, while asking again for every evicted
+    /// one would, with a budget too small for them all, rebuild on every
+    /// search what the budget just evicted.
+    public func reconcile(unbuiltIndexedImagePaths: [String], scopeImagePaths: Set<String>?) {
+        guard isEnabled else { return }
+        for imagePath in unbuiltIndexedImagePaths where buildRequests[imagePath] == nil {
+            if buildStatesByImagePath[imagePath]?.isBuilt == true {
+                buildStatesByImagePath[imagePath] = nil
+            }
+            if let scopeImagePaths {
+                if scopeImagePaths.contains(imagePath) {
+                    requestBuild(of: imagePath, isPrioritized: true)
+                }
+            } else if !requestedImagePaths.contains(imagePath) {
+                requestBuild(of: imagePath)
+            }
+        }
+    }
+
     /// Withdraws every request this document holds, leaving the images they
     /// were following unbuilt as far as it is concerned.
     private func withdrawEveryBuild() {
@@ -365,7 +389,10 @@ public final class FindCorpusCoordinator {
                     nil
                 }
             }
-        guard !learnedBuilds.isEmpty, finishedBuilds.count < Self.maximumFinishedBuildCount else { return }
+        // Remembered whether or not they fit: one that does not is older than
+        // everything listed, so it is the one a full history drops — and one
+        // never remembered comes back after Clear History.
         imagePathsListedInHistory.formUnion(learnedBuilds.map(\.imagePath))
+        guard !learnedBuilds.isEmpty, finishedBuilds.count < Self.maximumFinishedBuildCount else { return }
         finishedBuilds = Array((finishedBuilds + learnedBuilds).prefix(Self.maximumFinishedBuildCount))
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -360,9 +360,12 @@ public final class FindSession {
         var finished = results(from: nodes, matchCount: shownSearch.totalMatchCount, typeCount: typeCount)
         if isWidening {
             let scannedImagePaths = Set(summary.scannedImagePaths)
             finished.unbuiltImagePaths = results.unbuiltImagePaths.filter { !scannedImagePaths.contains($0) }
         } else {
             finished.unbuiltImagePaths = summary.unbuiltIndexedImagePaths
         }
         setResults(finished)
+        // What the search could not see is asked for now — the image the
+        // store evicted behind the coordinator's back included.
+        corpusCoordinator?.reconcile(unbuiltIndexedImagePaths: summary.unbuiltIndexedImagePaths, scopeImagePaths: shownSearch.scopeImagePaths)
     }
```
（FindSession 属于模块 D1，这一行调用要和 PR121.05 的改动一起落地。）

**复现测试（示例）**：放在 `FindCorpusCoordinatorTests.swift`。

- **(a) 从会话出发测**：修复前，过期的 `.built` 让 `prioritizeCorpora` 跳过 libobjc，搜索结束后也没有任何代码去重新请求它，所以 engine 的 coverage 一直没有 libobjc，等待超时，测试变红。断言放在 engine 的 coverage 上，而不是协调器的状态上：修复前协调器的状态始终是那条过期的 `.built`，断言它会「假绿」。

```swift
@Test("a corpus the store evicted silently is rebuilt once a search in its scope says it is unbuilt")
func silentlyEvictedCorpusIsRebuiltAfterASearch() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.silentEviction", loading: [TestImages.libobjc])
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let documentState = environment.documentState
    let coordinator = environment.make { documentState.findCorpusCoordinator }
    defer { withExtendedLifetime(coordinator) {} }
    _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }

    // What the resident budget does: no event, no notice.
    try await engine.evictInterfaceCorpus(for: TestImages.libobjc)

    var query = documentState.findSession.query
    query.text = "NSObject"
    query.scope = .images([TestImages.libobjc])
    documentState.findSession.run(query)

    let coverage = try await waitForCoverage(of: engine, timeout: 60) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }
    #expect(coverage.statesByImagePath[TestImages.libobjc]?.isBuilt == true, "the evicted corpus was never asked for again")
    await engine.stop()
}
```

- **(b) 历史满额**：只用 internal 的 `mergeCoverage` 和公开的 `clearFinishedBuilds`，三次合并之间没有 `await`，结果是确定的。修复前，第三次合并会把那 3 条带回来，测试变红。

```swift
@Test("a cleared history stays cleared when corpora were learned while it was full")
func clearedHistoryStaysClearedAtCapacity() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.historyCapacity")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }
    let summary = RuntimeInterfaceCorpusBuildSummary(objectCount: 1, skippedCount: 0, byteCount: 1)
    func coverage(_ imageCount: Int) -> RuntimeInterfaceCorpusCoverage {
        let states = Dictionary(uniqueKeysWithValues: (0 ..< imageCount).map { imageIndex in
            ("/learned/Image\(imageIndex).dylib", RuntimeInterfaceCorpusBuildState.built(summary))
        })
        return RuntimeInterfaceCorpusCoverage(statesByImagePath: states, residentByteCount: 0, residentByteLimit: 0)
    }

    coordinator.mergeCoverage(coverage(FindCorpusCoordinator.maximumFinishedBuildCount))
    #expect(coordinator.finishedBuilds.count == FindCorpusCoordinator.maximumFinishedBuildCount)
    // Three more corpora appear while the history is full.
    coordinator.mergeCoverage(coverage(FindCorpusCoordinator.maximumFinishedBuildCount + 3))
    coordinator.clearFinishedBuilds()
    coordinator.mergeCoverage(coverage(FindCorpusCoordinator.maximumFinishedBuildCount + 3))

    #expect(coordinator.finishedBuilds.isEmpty, "corpora learned while the history was full came back after Clear History")
    await engine.stop()
}
```

**同类**：`FindSession.prioritizeCorpora` 也读 `corpusBuildStates[imagePath]?.isBuilt`。对账之后过期状态会被清掉，它不需要另改。路径形式的问题由 PR121.33 处理。

**工作量**：S。用到 FindSession 的那一处要和模块 D1 协调（PR121.05）；路径比较依赖 PR121.33。


### PR121.35 每个请求完成都单独刷新一次 coverage

- **严重度**：Minor（性能）
- **审查编号**：F8
- **状态**：方案待批，代码未改

**问题**：
- 本文档的每个构建请求成功后，`finishBuildRequest` 都调用一次 `refreshCoverage()`。
- 第二个窗口打开时，`requestBuildOfIndexedImages` 会为每个已索引镜像发一个请求。这些镜像的语料早已建好，所有请求几乎同时立即返回。
- 结果是 N 次 coverage 往返，每次往返带回 N 个状态，每次合并又是 O(N)，加起来是 O(N²) 的主线程工作。

**四问**：
- **复现**：在 My Mac 上建好几百个镜像的语料，再开第二个窗口。新窗口的协调器会发出与镜像数相同次数的 `interfaceCorpusCoverage` 请求。
- **基线**：本 PR 新引入。
- **影响**：镜像越多越明显，开窗时会卡一下。修起来简单，建议修。
- **历史**：新代码，没有修过。

**改法**：
- `refreshCoverage` 改成「最多一个在途，外加一个排在后面」：
  - 有刷新在途时，新的调用只置一个标志，不发请求。
  - 在途的那次完成后，如果标志被置过，就再刷一次，保证最后一次调用之后的状态总能拿到。
  - 换引擎时丢掉在途的刷新。旧引擎的结果回来时，按引擎身份判断后丢弃，不碰新状态。
- 模块 E 在 PR121.55 里要求「存在别处发起的活跃行时，每 2 秒刷新一次」。那个定时刷新也走这个入口，合并规则同样适用。
- 加一个 internal 的 `coverageFetchCount`，供测试计数。它只在发出请求时递增，不影响行为。
- coverage 的 `indexedImagePaths` 参数没有被使用（引擎为它白白跨两个 section 工厂 actor 取了一次数据），由模块 B1 的 PR121.26 删除，本条不重复。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -80,5 +80,15 @@ public final class FindCorpusCoordinator {
     private var requestedImagePaths: Set<String> = []
 
+    /// The coverage refresh in flight, if any. One at a time: a call made
+    /// while it runs only sets `isCoverageRefreshPending`.
+    private var coverageRefreshTask: Task<Void, Never>?
+
+    /// A refresh was asked for while one ran; it runs once that one is done.
+    private var isCoverageRefreshPending = false
+
+    /// Round trips `refreshCoverage()` made. Test seam.
+    private(set) var coverageFetchCount = 0
+
     private let progressStaging = ProgressStaging()
 
     private let corpusBuiltRelay = PublishRelay<String>()
@@ -238,13 +248,31 @@ public final class FindCorpusCoordinator {
     /// Asks the engine where every corpus stands and folds the answer in —
     /// see `mergeCoverage(_:)`. Runs on start and after every build; the
     /// Report navigator calls it when it appears, because the store evicts
     /// without telling anyone.
+    ///
+    /// Calls made while a refresh is in flight coalesce into one more after
+    /// it: requests that end together — every corpus already built when a
+    /// second window opens — cost two round trips, not one each.
     public func refreshCoverage() {
+        guard coverageRefreshTask == nil else {
+            isCoverageRefreshPending = true
+            return
+        }
         let engine = engine
-        Task { [weak self] in
-            guard let coverage = try? await engine.interfaceCorpusCoverage() else { return }
-            guard let self, self.engine === engine else { return }
-            self.mergeCoverage(coverage)
+        coverageFetchCount += 1
+        coverageRefreshTask = Task { [weak self] in
+            let coverage = try? await engine.interfaceCorpusCoverage()
+            // A refresh of an engine swapped out since belongs to nobody; the
+            // swap already let go of it.
+            guard let self, self.engine === engine else { return }
+            self.coverageRefreshTask = nil
+            if let coverage {
+                self.mergeCoverage(coverage)
+            }
+            if self.isCoverageRefreshPending {
+                self.isCoverageRefreshPending = false
+                self.refreshCoverage()
+            }
         }
     }
 
@@ -431,6 +460,8 @@ public final class FindCorpusCoordinator {
     private func handleEngineSwap(to newEngine: RuntimeEngine) {
         stopPumps()
         withdrawEveryBuild()
+        coverageRefreshTask = nil
+        isCoverageRefreshPending = false
         _ = progressStaging.drain()
         buildStatesByImagePath = [:]
         requestedImagePaths.removeAll()
```

**复现测试（示例）**：放在 `FindCorpusCoordinatorTests.swift`。先只加上 `coverageFetchCount` 这个计数接缝、不改合并逻辑，测试会失败：启动时 1 次，加上 10 次调用各发 1 次，共 11 次。修复后最多 2 次：启动时那一次在途，10 次调用合并成它后面的 1 次。
```swift
@Test("a burst of coverage refreshes costs at most two round trips")
func coverageRefreshesCoalesce() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.coalescedRefresh")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }

    // `init` started one; ten more arrive while it is in flight, as ten
    // requests ending together would.
    for _ in 0 ..< 10 {
        coordinator.refreshCoverage()
    }
    _ = try await values(from: coordinator.$buildStatesByImagePath.asDriver(), during: 1)

    #expect(coordinator.coverageFetchCount <= 2, "\(coordinator.coverageFetchCount) coverage round trips for one burst")
    await engine.stop()
}
```

**同类**：
- `requestBuildOfIndexedImages` 每次调用都发一次 `indexedImagePathList`，但它只在开窗、换引擎、打开语料开关时触发，不会成批出现，不用改。
- 模块 E 在 PR121.55 加的定时刷新会复用这个入口。

**工作量**：S。


### PR121.36 语料事件泵跑在 main actor 上

- **严重度**：Cleanup（随 PR121.04 一起消失；单独看建议不修）
- **审查编号**：U2（审查扫尾阶段发现，未经投票核实）
- **状态**：方案待批，代码未改

**问题**：
- 语料协调器在 `startPumps` 里创建事件泵（`eventPumpTask = Task { … }`，`FindCorpusCoordinator.swift:377-391`）。协调器是 `@MainActor` 类，这个 `Task` 继承了主 actor，于是后台索引的每个事件都要唤醒一次主线程，包括 `taskStarted`、`taskFinished`、批次开始和结束。
- 每个窗口有自己的协调器，开 N 个窗口就是 N 倍。
- 每次唤醒只做一次 `case` 匹配，真正要处理的只有 `taskFinished(.completed)`。

**四问**：
- 复现：读代码即可确认，成立。在 `for await event in stream` 循环里加一个 `MainActor.assertIsolated()` 就能验证它在主线程上跑。
- 基线：本 PR 新引入。
- 影响：很小。每个镜像约两次唤醒，每次微秒级；与每批结束时侧栏的整表刷新相比可以忽略。
- 历史：新代码，没有修过。

**改法**：
- 随 PR121.04 一并解决：协调器不再消费后台索引事件流，改为订阅引擎的 `imageDidIndexPublisher`。它只在镜像真正被索引时发一次，经 `.receive(on: DispatchQueue.main)` 回到主线程。唤醒次数降到每个镜像一次，`taskStarted` 和批次事件不再唤醒主线程。
- 如果 PR121.04 不采纳，本条建议不修。裁决理由如下，原样写进 KnownIssues：

  > 语料协调器的后台索引事件泵在主 actor 上消费事件，每个事件唤醒主线程一次，其中只有 `taskFinished(.completed)` 有实际工作。单次唤醒是微秒级，一个镜像约两次，N 个窗口乘以 N；与每个批次结束时各窗口侧栏的整表刷新相比可以忽略。把循环挪出主 actor 需要另一个隔离域来持有事件流，复杂度高于收益。若将来后台索引改为逐对象上报进度事件，重新评估。

**拟修改**：没有独立的 diff。删除 `eventPumpTask` 和改用新发布者的改动见 PR121.04 中 `FindCorpusCoordinator.swift` 的 diff（`startPumps`、`stopPumps`、`deinit` 三处）。

**复现测试（示例）**：主线程唤醒次数在单元测试里没有可靠的度量手段，本条不加测试。PR121.04 的测试覆盖了替代触发源：侧栏打开的镜像能建出语料。若要人工确认改后的效果，可以在 Instruments 的 Points of Interest 里看 PR121.04 之后主线程上已不再出现事件泵的回调。

**同类**：`RuntimeBackgroundIndexingCoordinator` 也在主 actor 上消费同一个事件流，但它要用每一种事件更新界面（批次列表、进度），在主线程上处理是正确的，不属于此类。

**工作量**：随 PR121.04 一起完成，无额外工作量。


### PR121.37 对端不支持语料命令时每个镜像记一条失败

- **严重度**：Minor
- **审查编号**：新发现（模块 C 起草方案时发现，不在审查清单里）
- **状态**：方案待批，代码未改

**问题**：
- 对端是不认识语料命令的旧版本时，例如还在跑 v3.0.0-beta.6 的 iPhone、iPad 或模拟器 App，或经镜像链路转发到这样的对端，每个构建请求都会以「No handler registered for com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.buildInterfaceCorpus」失败。
- 协调器把每次失败都当成一次构建失败：后台索引完成的每个镜像、加载的每个镜像，都会在 Report 里各记一条 Failed，并写进历史。
- 用户看不出真正的原因是「对端版本太旧」。

**四问**：
- **复现**：
  - Mac 上运行本 PR 的构建，连接一台运行 v3.0.0-beta.6 的 iOS 设备（Bonjour），打开一个镜像并让后台索引跑完。Report 里会出现与已索引镜像数量相同的 Failed 行，每行的说明都是上面那句话。
  - 这句话来自 `RuntimeMessageChannel.swift:560`。自 2a0573b7 起，v2.1.0 之后的每个版本收到不认识的命令都会这样回复。
- **基线**：本 PR 新引入。语料命令是新的；项目文档写明支持新旧版本混用（`CommunicationAndEngineArchitecture.md`「双向兼容，不要求同版本」）。
- **影响**：只在新旧版本混用时出现，但一出现就是一大片误导性的失败行。建议修，工作量小。
- **历史**：新代码，没有修过。

**改法**：
- **识别「对端不认识这条命令」**：
  - 旧对端发来的只有一条文字消息，回复里没有别的字段可用（2a0573b7 起的每个版本，文字都是「No handler registered for <命令名>」）。所以识别只能靠这段文字的前缀。
  - 把前缀定义成 `RuntimeNetworkRequestError` 上的公开常量，发送错误的 `RuntimeMessageChannel` 也改用它拼接消息，让「发」和「认」用同一个来源。
  - 新增 `isUnknownCommand` 判定。
  - 不另加类型字段：那个字段只有新对端才会填，而要识别的恰恰是旧对端。
- **协调器的处理**：
  - 构建请求以「不认识的命令」失败时，把 `isCorpusUnsupportedByEngine` 置为真。
  - 撤回本文档对该引擎的所有请求，清空状态，不写历史。
  - 之后对这个引擎不再发构建请求。
  - 换引擎时复位。
  - 这个标志对外发布，供 Report 显示一条说明（模块 E，PR121.55 一带），也供 Find 的摘要改用「此设备上的 RuntimeViewer 版本不支持 Find」这类文字（模块 D1）。
- **识别不到的情况**：经 mach service 连接的旧版注入 payload 收到不认识的命令时根本不回复，所以靠错误识别不到。见 PR121.73。

**拟修改**（`RuntimeNetworkError.swift` 与 PR121.30 改的是同一个类型，两条一起落地时合并）：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCommunication/Network/RuntimeNetworkError.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCommunication/Network/RuntimeNetworkError.swift
@@ -9,3 +9,15 @@ public enum RuntimeNetworkError: Error {
 public struct RuntimeNetworkRequestError: Error, Codable {
     public let message: String
 }
+
+extension RuntimeNetworkRequestError {
+    /// How a peer words its reply to a command it has no handler for. Every
+    /// release since v2.1.0 replies with exactly this prefix and the command
+    /// name; matching the text is the only way to recognise an older peer,
+    /// which sends nothing else.
+    public static let unknownCommandMessagePrefix = "No handler registered for "
+
+    /// The peer does not know the command — it predates it.
+    public var isUnknownCommand: Bool {
+        message.hasPrefix(Self.unknownCommandMessagePrefix)
+    }
+}
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeMessageChannel.swift
@@ -557,5 +557,5 @@ final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
         guard let handler = handler(for: requestData.identifier) else {
             if requestData.nonce != nil {
                 #log(.error, "No handler for: \(requestData.identifier, privacy: .public); replying with error so the caller doesn't hang")
-                sendErrorReply(for: requestData, message: "No handler registered for \(requestData.identifier)", rawWriter: rawWriter)
+                sendErrorReply(for: requestData, message: RuntimeNetworkRequestError.unknownCommandMessagePrefix + requestData.identifier, rawWriter: rawWriter)
             } else {
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -1,5 +1,6 @@
 import Combine
 import Foundation
 import FoundationToolbox
 import RuntimeViewerCore
+import RuntimeViewerCommunication
 import RuntimeViewerArchitectures
@@ -102,6 +103,13 @@ public final class FindCorpusCoordinator {
     @RxObserved
     public private(set) var buildStatesByImagePath: [String: RuntimeInterfaceCorpusBuildState] = [:]
 
+    /// The engine's process does not know the corpus commands: a peer older
+    /// than the Find navigator. Nothing is asked of it until the engine is
+    /// swapped; the Report navigator and the Find summary say why instead of
+    /// listing one failure per image.
+    @RxObserved
+    public private(set) var isCorpusUnsupportedByEngine = false
+
     /// Builds that ended, newest first, at most `maximumFinishedBuildCount`
     /// of them. Corpora other documents built come after the ones this
     /// document saw end: the engine does not say when they were built.
@@ -171,7 +179,7 @@ public final class FindCorpusCoordinator {
     /// for the image is not repeated; with `isPrioritized` it is moved to the
     /// front of the engine's queue instead.
     public func requestBuild(of imagePath: String, isPrioritized: Bool = false) {
-        guard isEnabled else { return }
+        guard isEnabled, !isCorpusUnsupportedByEngine else { return }
         if buildRequests[imagePath] != nil {
             if isPrioritized {
                 let engine = engine
@@ -312,6 +320,14 @@ public final class FindCorpusCoordinator {
             // The store cancelled the build for everyone: another document
             // asked for it under a different transformer, or evicted it.
             buildStatesByImagePath[imagePath] = nil
+        case .failure(let error as RuntimeNetworkRequestError) where error.isUnknownCommand:
+            // Not a failed build: the peer predates corpora. Every request
+            // would fail the same way, so none is kept, and none is made again.
+            #log(.info, "The engine's process does not know the corpus commands; corpora are off for it")
+            buildStatesByImagePath[imagePath] = nil
+            withdrawEveryBuild()
+            buildStatesByImagePath = [:]
+            isCorpusUnsupportedByEngine = true
         case .failure(let error):
             #log(.error, "Corpus build of \(imagePath, privacy: .public) failed: \(error, privacy: .public)")
             let message = "\(error)"
@@ -431,6 +447,7 @@ public final class FindCorpusCoordinator {
     private func handleEngineSwap(to newEngine: RuntimeEngine) {
         stopPumps()
         withdrawEveryBuild()
+        isCorpusUnsupportedByEngine = false
         _ = progressStaging.drain()
         buildStatesByImagePath = [:]
         requestedImagePaths.removeAll()
```

**复现测试（示例）**：
- 放在 `FindCorpusCoordinatorTests.swift`。
- 服务端是一条没有注册任何处理器的 `RuntimeLocalSocketServerConnection`，代表比语料命令更早的对端：它对每条请求都回复「No handler registered for …」。
- 修复前，`finishedBuilds` 会出现 `.failed`，`isCorpusUnsupportedByEngine` 这个属性也还不存在。为了让测试先变红，可以先只断言「历史里没有 `.failed`」。

```swift
@Test("a peer that predates the corpus commands turns corpora off instead of failing every image")
func peerWithoutCorpusCommandsTurnsCorporaOff() async throws {
    let identifier = "FindCorpusCoordinatorTests.oldPeer.\(UUID().uuidString)"
    // Answers every request with "No handler registered for …", as a release
    // older than the Find navigator does.
    let oldPeer = RuntimeLocalSocketServerConnection(identifier: identifier)
    let oldPeerTask = Task { try await oldPeer.start() }
    defer {
        oldPeerTask.cancel()
        oldPeer.stop()
    }
    try await Task.sleep(for: .milliseconds(200))
    let engine = RuntimeEngine(source: .localSocket(name: "Old peer", identifier: .init(rawValue: identifier), role: .client))
    try await engine.connect()

    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
    defer { withExtendedLifetime(coordinator) {} }

    coordinator.requestBuild(of: TestImages.libobjc)
    coordinator.requestBuild(of: TestImages.foundation)

    _ = try await nextValue(from: coordinator.$isCorpusUnsupportedByEngine.asDriver(), timeout: 10) { $0 }
    let recordedFailure = coordinator.finishedBuilds.contains { finishedBuild in
        if case .failed = finishedBuild.outcome { return true }
        return false
    }
    #expect(!recordedFailure, "a peer without corpus commands was reported as failed builds")
    #expect(coordinator.buildStatesByImagePath.isEmpty)
    await engine.stop()
}
```

**同类**：
- 搜索命令遇到旧对端时，现在显示「Search failed: No handler registered for …」。FindSession 可以用同一个 `isUnknownCommand` 判定换一句说明，归模块 D1。
- `typeRelationships`、`interfaceCorpusCoverage`、`indexedImagePathList` 失败时都被 `try?` 吞掉了，不产生失败行，不用改。
- 经 mach service 连接的旧版注入 payload 不回复，这里的识别对它无效，见 PR121.73。

**工作量**：S。Report 和 Find 摘要里那一句说明的显示，由模块 E 和 D1 各自加上。


### PR121.38 补搜失败后转圈不停

- **严重度**：Minor
- **审查编号**：C11
- **状态**：方案待批，代码未改

**问题**：屏上的搜索在新语料建好后会再读一次（补搜）。补搜如果因为取消以外的原因失败，`FindSession.swift:270` 的 `guard …, !isWidening else { return }` 会直接从 Task 闭包返回，跳过 `:277` 的 `isSearching = false`。之后转圈一直不停；`corpusDidBuild` 也一直卡在 `guard !isSearching`（`:376`），后来建好的语料全都不再补搜，直到用户再按一次回车。

**四问**：
- **复现**：结果在屏上时连接断开，例如 XPC service 退出、或附加的进程被杀掉；随后一个语料建好，触发补搜。补搜失败后，转圈不再停止。
- **基线**：本 PR 新引入（8ce77d36）。
- **影响**：不常见，但一旦发生，补搜机制会对这次搜索彻底失效，界面也一直显示「正在搜」。修复只需几行，建议修。
- **历史**：新代码，没有修过。现有测试从没让补搜失败过。

**改法**：
- 补搜失败时不再提前返回，只是不改结果：已有的结果保留，失败的那几个镜像不计入已搜过的集合。之后照常清掉 `isSearching`，并读取搜索期间建好的镜像。
- 不自动重试失败的镜像：连接断了的话，自动重试会变成死循环。
- 摘要里先不提示「N images could not be searched」，只记日志。这是一个待拍板的取舍。
- 如果 PR121.05 先落地，它的 `runDidEnd` 已经按同样的规则处理了所有结局，第一个 diff 块就不需要了。只保留第二个块：把 `corpusDidBuild` 放宽为 internal，供测试代替协调器调用。

**拟修改**（基准：`12e1227b`；与 PR121.05 一起落地时只取第二块）：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -268,11 +268,17 @@ public final class FindSession {
             } catch {
                 #log(.error, "Find failed: \(error, privacy: .public)")
-                guard let self, self.searchGeneration == generation, !isWidening else { return }
-                self.shownSearch = nil
-                var failed = Results()
-                failed.summary = "Search failed: \(error.localizedDescription)"
-                self.setResults(failed)
+                // A widening search keeps the results it would have merged
+                // into, and the images it was sent to read stay unsearched.
+                // Either way the session goes idle below: returning here left
+                // `isSearching` set for good, and every corpus built later
+                // waited on it.
+                if let self, self.searchGeneration == generation, !isWidening {
+                    self.shownSearch = nil
+                    var failed = Results()
+                    failed.summary = "Search failed: \(error.localizedDescription)"
+                    self.setResults(failed)
+                }
             }
             guard let self, self.searchGeneration == generation else { return }
             self.isSearching = false
             self.searchImagesBuiltDuringSearch()
@@ -370,4 +376,6 @@ public final class FindSession {
     /// A corpus the coordinator reports built is read by the search on
     /// screen, unless it already was; a search still running reads it once
     /// it ends.
-    private func corpusDidBuild(at imagePath: String) {
+    ///
+    /// Internal so a test can stand in for the coordinator.
+    func corpusDidBuild(at imagePath: String) {
```

**复现测试（示例）**：加在 `FindSessionLifecycleTests.swift`（PR121.02 新建）里，用 PR121.05 加的 `TestRuntimeEngine.makeForwardingPair`。
- 先在客户端停掉转发引擎，此后每个请求都会抛出 `connectionInvalid`，而不是取消错误。然后直接调用 `corpusDidBuild` 触发补搜。
- 修复前 `isSearching` 永远停在 true，`nextValue` 超时抛错，测试变红。
```swift
    @Test("a widening search that fails leaves the session idle and keeps its results")
    func failedWideningSearchEndsTheSearch() async throws {
        let (host, engine) = try await TestRuntimeEngine.makeForwardingPair(
            engineID: "FindSessionLifecycleTests.failedWidening",
            loading: [TestImages.libobjc]
        )
        defer { Task { await host.stop() } }
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        try await withSharedGenerationOptionsLock {
            session.run(FindQuery(mode: .text, text: "NSObject"))
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

            // From here every request fails, and not with a cancellation.
            await engine.stop()
            session.corpusDidBuild(at: TestImages.foundation)
            #expect(session.isSearching, "the corpus built after the search was not read")

            // Before the fix the failure returned before clearing the flag,
            // and this wait timed out.
            let isSearching = try await nextValue(from: session.$isSearching.asDriver(), timeout: 10) { !$0 }
            #expect(!isSearching)
            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc }, "the failed widening emptied the results")
        }
    }
```

**同类**：关系搜索失败也走同一个 catch，改后一并覆盖。另一处类似的问题在协调器：引擎发起的取消跨过 XPC 后被记成失败，见 PR121.30，不在本条范围。

**工作量**：S。单独落地不依赖其他条目；与 PR121.05 一起落地时，第一块由 PR121.05 取代。


### PR121.39 选项重跑和点击高亮用了未提交的查询

- **严重度**：Minor
- **审查编号**：C12
- **状态**：方案待批，代码未改

**问题**：用户改模式、大小写或范围时，`update(_:)` 只修改正在编辑的查询，不会触发搜索；要按回车才会搜。可是 Generation Options 一变，`rerunAfterGenerationOptionsChange`（`FindSession.swift:201-204`）重跑的却是这个编辑中的查询：
- 模式已改成 Members 但没按回车时，选项一变就跑成一次成员搜索，结果整体换了类型。
- 模式改成关系模式时，条件不成立，干脆不重跑，屏上的文本结果停留在旧选项下。

点击结果时，`FindViewModel.swift:204` 也用编辑中查询的大小写和模式来构造高亮请求。

**四问**：
- **复现**：搜一次 Text，再把模式改成 Members（不按回车），然后改任意一项 Generation Option，列表会变成成员结果。改成 Ancestor Types 再改选项，文本结果不会更新。
- **基线**：本 PR 新引入（4a0f1f5f）。
- **影响**：要先「编辑但不提交」再改选项才会触发，频率低，但结果与提案描述相反。建议修。
- **历史**：新代码。提案写的是「重跑正在显示的文本 / 成员搜索」（`draft-find-navigator.md:486`，决策日志在 `:708`），实现偏离了提案；现有测试没有覆盖「编辑后不提交」这种状态。

**改法**：
- **重跑对象改成屏上的搜索**：重跑用 `shownSearch` 里那次搜索的查询，以及它当时解析好的范围；`.currentImage` 不按此刻的侧栏重新解析，免得改个选项就悄悄换了被搜索的镜像。重跑时不改写 `self.query`，所以编辑中的模式、大小写和范围保持原样。
- **判断条件随之变化**：「有 `shownSearch`」就等于「屏上有一次读语料的搜索」，与原先 `relationship == nil` 加 `summary != nil || isSearching` 的判断等价，但不再看编辑中的查询。
- **方法改名**：重跑方法改名为 `rerunShownSearch()`，PR121.40 也会调用它。与 `start(_:)` 共用的清空逻辑提取成 `resetResults()`。
- **高亮信息**：`Results` 增加 `query` 字段，在 `setResults` 里统一填入 PR121.05 的 `committedQuery`，`navigate` 用它构造高亮请求。另一种做法是把高亮信息直接放进 `FindResultNode.navigationTarget`（PR121.50），两种做法只采用一种；采用 PR121.50 时，删掉本条的 `Results.query` 和 `FindViewModel` 的改动。

**拟修改**（基准：`12e1227b` + PR121.02 + PR121.05）：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -41,7 +41,11 @@ public final class FindSession {
         public var summary: String?
         /// Images the search did not see because their corpus is not built.
         public var unbuiltImagePaths: [String] = []
         public var isTruncated = false
+        /// The query these results answer: the one last run, not the one the
+        /// mode path and the toggles may show by now. A click highlights with
+        /// its mode and case. `nil` with nothing searched.
+        public internal(set) var query: FindQuery?
 
         public init() {}
     }
@@ -119,7 +123,7 @@ public final class FindSession {
             .subscribeOnNext { [weak self] _ in
                 guard let self else { return }
                 MainActor.assumeIsolated {
-                    self.rerunAfterGenerationOptionsChange()
+                    self.rerunShownSearch()
                 }
             }
             .disposed(by: disposeBag)
@@ -200,9 +204,5 @@ public final class FindSession {
     private func start(_ query: FindQuery) {
         cancelCurrentRun()
         committedQuery = query.isEmpty ? nil : query
-        shownSearch = nil
-        imagePathsBuiltDuringSearch = []
-        textMatchGroups = TextMatchGroups()
-        memberMatchGroups = MemberMatchGroups()
-        setResults(Results())
+        resetResults()
         guard !query.isEmpty else {
@@ -233,7 +233,24 @@ public final class FindSession {
-    /// A text or member search already shown answers for the options it ran
-    /// under; run it again so it answers for the ones the content pane now
-    /// displays with. Relationship searches do not depend on them.
-    private func rerunAfterGenerationOptionsChange() {
-        guard !query.isEmpty, query.mode.relationship == nil, results.summary != nil || isSearching else { return }
-        run(query)
+    /// A text or member search on screen answers for the options it ran
+    /// under; run it again so it answers for the ones the content pane now
+    /// displays with. It is the search on screen that runs again, over the
+    /// images its scope stood for then — not the query the mode path and the
+    /// toggles are being edited into, which stays as it is. Relationship
+    /// searches do not depend on the options.
+    private func rerunShownSearch() {
+        guard let shownSearch else { return }
+        let generationOptions = appDefaults.options
+        cancelCurrentRun()
+        resetResults()
+        self.shownSearch = ShownSearch(query: shownSearch.query, generationOptions: generationOptions, scopeImagePaths: shownSearch.scopeImagePaths)
+        prioritizeCorpora(of: shownSearch.scopeImagePaths)
+        startSearch(shownSearch.query, imagePaths: shownSearch.scopeImagePaths, generationOptions: generationOptions, isWidening: false)
+    }
+
+    /// Empties the results and everything the search on screen gathered.
+    private func resetResults() {
+        shownSearch = nil
+        imagePathsBuiltDuringSearch = []
+        textMatchGroups = TextMatchGroups()
+        memberMatchGroups = MemberMatchGroups()
+        setResults(Results())
     }
@@ -536,4 +553,6 @@ public final class FindSession {
     private func setResults(_ newResults: Results) {
-        results = newResults
+        var stampedResults = newResults
+        stampedResults.query = committedQuery
+        results = stampedResults
         updateSummary()
     }
```
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -202,5 +202,7 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route> {
     private func navigate(to node: FindResultNode, inNewTab: Bool) {
         guard let (object, _) = node.navigationTarget else { return }
-        let highlight = Self.highlight(for: node, query: session.query)
+        // The query the rows answer, not the one the mode path and the
+        // toggles may have been edited into since.
+        let highlight = Self.highlight(for: node, query: session.results.query ?? session.query)
         switch (inNewTab, highlight) {
         case (false, nil):
```

**复现测试（示例）**：共三条，修复前都会红。
- 前两条加在 `FindGenerationOptionsTests` 里。它们沿用该套件的 `NSURLQueryItem` 锚点和 `search(_:with:)`、`textMatches(in:)`、`memberMatches(in:)` 辅助函数。为了不再建一次 Foundation 的语料，它们用共享引擎。
  - 第一条：修复前，模式被编辑成关系模式后不会重跑，屏上仍然找不到 `_value` 的 ivar 行。
  - 第二条：修复前会重跑成成员搜索，结果里出现成员命中、文本命中消失。
- 第三条加在 `FindViewModelTests` 里：修复前，高亮请求带着编辑中的大小写 `true`。
```swift
    // FindGenerationOptionsTests

    @Test("a Generation Options change runs the text search on screen again while the mode path is edited to a relationship mode")
    func optionsChangeRerunsTheShownSearchWhileARelationshipModeIsEdited() async throws {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.buildInterfaceCorpus(for: TestImages.foundation, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        try await withSharedGenerationOptionsLock {
            let appDefaults = environment.appDefaults
            let originalOptions = appDefaults.options
            defer { appDefaults.options = originalOptions }
            var strippingOptions = RuntimeObjectInterface.GenerationOptions()
            strippingOptions.objcHeaderOptions.stripSynthesizedIvars = true
            appDefaults.options = strippingOptions

            let strippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
            #expect(strippedIvarLines.isEmpty)

            // Edited, not run: Return was never pressed.
            session.update { $0.mode = .ancestorTypes }
            appDefaults.options = RuntimeObjectInterface.GenerationOptions()
            try await settleMainQueue()
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

            #expect(!Self.textMatches(in: session.results).isEmpty, "the text search on screen was not run again under the new options")
            #expect(session.query.mode == .ancestorTypes, "the edit in progress was overwritten")
        }
    }

    @Test("a Generation Options change keeps a text search on screen a text search while Members is only being edited")
    func optionsChangeKeepsTheShownSearchesMode() async throws {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.buildInterfaceCorpus(for: TestImages.foundation, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        try await withSharedGenerationOptionsLock {
            let appDefaults = environment.appDefaults
            let originalOptions = appDefaults.options
            defer { appDefaults.options = originalOptions }

            _ = try await search(FindQuery(mode: .text, text: "value", isCaseSensitive: true), with: session)
            #expect(!Self.textMatches(in: session.results).isEmpty)

            session.update { $0.mode = .members }
            var changedOptions = originalOptions
            changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
            appDefaults.options = changedOptions
            try await settleMainQueue()
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

            #expect(!Self.textMatches(in: session.results).isEmpty, "the rerun dropped the text search on screen")
            #expect(Self.memberMatches(in: session.results).isEmpty, "the rerun ran the edited Members query instead")
        }
    }

    // FindViewModelTests

    @Test("a click highlights with the case sensitivity of the search on screen, not the toggle being edited")
    func clickHighlightsWithTheShownSearchesQuery() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        searchCommittedRelay.accept("initwithformat:")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
        let hit = try #require(nodes.first?.children.first)
        guard case .textMatch(let match) = hit.content else {
            Issue.record("expected a text hit")
            return
        }

        // Toggled, not run.
        caseSensitiveToggledRelay.accept(true)
        resultClickedRelay.accept(hit)
        try await settleMainQueue()

        let highlight = try #require(environment.documentState.takeContentHighlight(for: match.object))
        #expect(highlight.isCaseSensitive == false)
    }
```

**同类**：
- 会话里还有一处会重跑搜索：换引擎（PR121.05 的 `engineDidChange`）。它已经用 `committedQuery` 而不是编辑中的查询，不需要再改。
- transformer 重建后的重跑（PR121.40）直接调用本条的 `rerunShownSearch()`，自然一致。

**工作量**：S。依赖 PR121.05：要用到它的 `start(_:)`、`cancelCurrentRun()` 和 `committedQuery`。


### PR121.40 改 transformer 后屏上的搜索不重跑

- **严重度**：Minor
- **审查编号**：U3
- **状态**：方案待批，代码未改

**问题**：改了 transformer 设置后，`scheduleTransformerRebuild`（`FindCorpusCoordinator.swift:499-513`）会驱逐全部语料、再逐个重建，每建好一个就经 `corpusBuilt` 通知会话。但会话补搜前会先减去已经搜过的镜像（`FindSession.swift:384`），而重建的恰恰都是搜过的镜像，于是全部被跳过。屏上的结果一直是旧 transformer 打印出的行，而内容区已经按新 transformer 显示，点击时两边的行对不上，高亮只能退到降级匹配。

**四问**：
- **复现**：搜索结果在屏时，在 Settings › Transformer 里打开任一模块（例如 ObjC 的 ivar offset），等两秒去抖和重建完成：结果不会变，摘要里的「being made searchable」出现后又消失。
- **基线**：本 PR 新引入。
- **影响**：只有改 transformer 设置时才会遇到，频率低；但一旦遇到，屏上每一行都可能是过期的。建议修。
- **历史**：新代码，没有修过。审查时这条列为「未核实」，起草方案时读代码确认属实。

**改法**：
- 协调器在 transformer 重建、重新请求构建之后，发出 `corporaRebuilt` 信号。会话在 `follow(_:)` 里订阅它，收到后用 PR121.39 的 `rerunShownSearch()` 重跑屏上那次读语料的搜索，查询和范围保持不变。
- 重跑时语料多半还没建好，结果会先变成「0 results · N images being made searchable」，再随重建逐个补回来，体验与启动时一致。
- 不采用另一种做法：保留旧结果、重建一个镜像就替换该镜像的命中。那需要按镜像记录总数，复杂得多。
- 关闭语料开关不发这个信号：结果留在屏上、之后不再补搜，这是预期行为。

**拟修改**（`FindCorpusCoordinator.swift` 基准为 `12e1227b`；`FindSession.swift` 的上下文与 `12e1227b` 及 PR121.02 / 05 / 39 之后相同，行号按 `12e1227b`，所调用的 `rerunShownSearch()` 由 PR121.39 引入）：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -84,3 +84,5 @@ public final class FindCorpusCoordinator {
     private let corpusBuiltRelay = PublishRelay<String>()
 
+    private let corporaRebuiltRelay = PublishRelay<Void>()
+
     private let disposeBag = DisposeBag()
@@ -118,7 +120,15 @@ public final class FindCorpusCoordinator {
     /// An image's path, each time a request of this document ends with the
     /// image's corpus built.
     public var corpusBuilt: Signal<String> {
         corpusBuiltRelay.asSignal()
     }
 
+    /// Every corpus was dropped to be printed again under a new transformer,
+    /// and the rebuilds are requested. A search on screen read the old prints,
+    /// and the images now being rebuilt are ones it has already searched, so
+    /// it has to run again rather than widen.
+    var corporaRebuilt: Signal<Void> {
+        corporaRebuiltRelay.asSignal()
+    }
+
     /// Whether an image is waiting for its corpus or being printed.
@@ -508,7 +518,9 @@ public final class FindCorpusCoordinator {
             guard self.engine === engine else { return }
             self.buildStatesByImagePath = [:]
             for imagePath in imagePaths {
                 self.requestBuild(of: imagePath)
             }
+            // After the requests: a search run again at once finds its images queued.
+            self.corporaRebuiltRelay.accept(())
         }
     }
```
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -124,6 +124,8 @@ public final class FindSession {
     /// Hooks the session to the document's corpus coordinator, which calls
     /// this once it exists: its build states feed the summary bar, and each
-    /// corpus it reports built is read by the search in force.
+    /// corpus it reports built is read by the search in force. Once every
+    /// corpus is dropped to be printed with a new transformer, that search
+    /// runs again: the images rebuilt are ones it has already read.
     func follow(_ corpusCoordinator: FindCorpusCoordinator) {
         self.corpusCoordinator = corpusCoordinator
         corpusCoordinator.$buildStatesByImagePath.asDriver()
@@ -137,7 +139,13 @@ public final class FindSession {
         corpusCoordinator.corpusBuilt
             .emitOnNextMainActor { [weak self] imagePath in
                 guard let self else { return }
                 self.corpusDidBuild(at: imagePath)
             }
             .disposed(by: disposeBag)
+        corpusCoordinator.corporaRebuilt
+            .emitOnNextMainActor { [weak self] _ in
+                guard let self else { return }
+                self.rerunShownSearch()
+            }
+            .disposed(by: disposeBag)
     }
```

**复现测试（示例）**：加在 `FindSessionCorpusTests` 里，沿用该套件的 `imagePath(of:)` 辅助函数。修复前，transformer 变化后会话不会再搜索，等待 `isSearching == true` 会在 30 秒后超时，测试变红。
```swift
    @Test("a transformer change runs the search on screen again once the corpora are dropped for rebuilding")
    func transformerChangeRerunsTheSearchOnScreen() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.transformer", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime(coordinator) {} }
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }

        try await withSharedGenerationOptionsLock {
            let session = documentState.findSession
            session.run(FindQuery(mode: .text, text: "NSObject"))
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

            var transformer = environment.settings.transformer
            transformer.objc.ivarOffset.isEnabled = true
            environment.settings.transformer = transformer

            // Two seconds for the edit to settle, then the drop: the search
            // on screen starts over.
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 30) { $0 }
            _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 120) { $0[TestImages.libobjc]?.isBuilt == true }
            try await settleMainQueue()
            _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
            #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc }, "the rebuilt corpus was not read again")
        }

        await engine.stop()
    }
```

**同类**：
- 会话只在两种情况下需要整体重跑：Generation Options 变化（PR121.39）和 transformer 重建（本条），现在都走 `rerunShownSearch()`。
- 换引擎走 PR121.05 的 `engineDidChange()`。
- 没有别的地方会让已经搜过的镜像整体失效。

**工作量**：S。依赖 PR121.39（`rerunShownSearch()`），PR121.39 又依赖 PR121.05。协调器部分可以先行落地。


### PR121.41 TextMatchGroups 与 MemberMatchGroups 重复

- **严重度**：Cleanup
- **审查编号**：S3（会话一半）
- **状态**：方案待批，代码未改

**问题**：`FindSession` 里的 `TextMatchGroups` 和 `MemberMatchGroups`（`FindSession.swift:465-530`）逐行相同，只有两处不同：元素类型，以及建子节点时调用 `.textMatch` 还是 `.member`。以后改分组规则（例如按类型缓存节点）就得两边同步改。store 里两个搜索函数的重复归 PR121.06 处理。

**四问**：
- **复现**：不是缺陷，是代码重复。
- **基线**：本 PR 新引入。
- **影响**：只影响维护成本；顺手可以修。
- **历史**：新代码，没有修过。

**改法**：
- 合并成一个泛型 `MatchGroups<Match: FindGroupedMatch>`。`FindGroupedMatch` 是本文件私有的协议，只要求 `object` 和一个建节点的静态方法。`RuntimeInterfaceSearchMatch` 和 `RuntimeMemberMatch` 在同一文件里遵循它。
- 这个协议是本模块私有的，所以不属于 AGENTS.md 警告的那种跨模块 retroactive conformance，不会和其他模块的同名遵循冲突。
- 按类型缓存 `FindResultNode`、每批只重建涉及的类型，属于 PR121.48 的性能改动，不放在这里；合并之后那项改动只需要改一处。
- 与 PR121.05 / PR121.39 一起落地时，那两条里出现的 `TextMatchGroups()` / `MemberMatchGroups()` 也照下面一样改成 `MatchGroups<…>()`。

**拟修改**（基准：`12e1227b`）：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -81,3 +81,3 @@ public final class FindSession {
-    private var textMatchGroups = TextMatchGroups()
+    private var textMatchGroups = MatchGroups<RuntimeInterfaceSearchMatch>()
 
-    private var memberMatchGroups = MemberMatchGroups()
+    private var memberMatchGroups = MatchGroups<RuntimeMemberMatch>()
@@ -169,4 +169,4 @@ public final class FindSession {
         imagePathsBuiltDuringSearch = []
-        textMatchGroups = TextMatchGroups()
-        memberMatchGroups = MemberMatchGroups()
+        textMatchGroups = MatchGroups<RuntimeInterfaceSearchMatch>()
+        memberMatchGroups = MatchGroups<RuntimeMemberMatch>()
         setResults(Results())
@@ -463,69 +463,57 @@ public final class FindSession {
     // MARK: - Grouping
 
-    /// Hits grouped by the type they are in, in the order types first
-    /// appeared; batches arrive per image, so a type's hits are contiguous.
-    private struct TextMatchGroups {
-        private var matchesByObject: [RuntimeObjectKey: [RuntimeInterfaceSearchMatch]] = [:]
+    /// Hits or members grouped by the type they are in, in the order types
+    /// first appeared; batches arrive per image, so a type's matches are
+    /// contiguous.
+    private struct MatchGroups<Match: FindGroupedMatch> {
+        private var matchesByObject: [RuntimeObjectKey: [Match]] = [:]
         private var order: [RuntimeObject] = []
         private(set) var matchCount = 0
-        /// Hits collected by the search under way, for its interim count.
+        /// Matches collected by the search under way, for its interim count.
         private(set) var matchCountSinceLastFinish = 0
 
         var typeCount: Int { order.count }
 
-        mutating func append(_ batch: [RuntimeInterfaceSearchMatch]) {
+        mutating func append(_ batch: [Match]) {
             for match in batch {
                 if matchesByObject[match.object.key] == nil {
                     order.append(match.object)
                 }
                 matchesByObject[match.object.key, default: []].append(match)
                 matchCount += 1
                 matchCountSinceLastFinish += 1
             }
         }
 
         mutating func markFinished() {
             matchCountSinceLastFinish = 0
         }
 
         func nodes() -> [FindResultNode] {
             order.map { object in
                 let matches = matchesByObject[object.key] ?? []
-                let children = matches.enumerated().map { index, match in FindResultNode.textMatch(match, index: index) }
-                return FindResultNode.object(object, matchCount: matches.count, children: children)
-            }
-        }
-    }
-
-    private struct MemberMatchGroups {
-        private var matchesByObject: [RuntimeObjectKey: [RuntimeMemberMatch]] = [:]
-        private var order: [RuntimeObject] = []
-        private(set) var matchCount = 0
-        private(set) var matchCountSinceLastFinish = 0
-
-        var typeCount: Int { order.count }
-
-        mutating func append(_ batch: [RuntimeMemberMatch]) {
-            for match in batch {
-                if matchesByObject[match.object.key] == nil {
-                    order.append(match.object)
-                }
-                matchesByObject[match.object.key, default: []].append(match)
-                matchCount += 1
-                matchCountSinceLastFinish += 1
-            }
-        }
-
-        mutating func markFinished() {
-            matchCountSinceLastFinish = 0
-        }
-
-        func nodes() -> [FindResultNode] {
-            order.map { object in
-                let matches = matchesByObject[object.key] ?? []
-                let children = matches.enumerated().map { index, match in FindResultNode.member(match, index: index) }
+                let children = matches.enumerated().map { index, match in Match.resultNode(for: match, index: index) }
                 return FindResultNode.object(object, matchCount: matches.count, children: children)
             }
         }
     }
 }
+
+/// A text hit or a member match, as the results tree groups it under the type
+/// it is in.
+private protocol FindGroupedMatch {
+    var object: RuntimeObject { get }
+    static func resultNode(for match: Self, index: Int) -> FindResultNode
+}
+
+extension RuntimeInterfaceSearchMatch: FindGroupedMatch {
+    fileprivate static func resultNode(for match: Self, index: Int) -> FindResultNode {
+        .textMatch(match, index: index)
+    }
+}
+
+extension RuntimeMemberMatch: FindGroupedMatch {
+    fileprivate static func resultNode(for match: Self, index: Int) -> FindResultNode {
+        .member(match, index: index)
+    }
+}
```

**复现测试（示例）**：行为不变，不需要新测试。现有的 `FindSessionCorpusTests`、`FindViewModelTests`（文本与成员搜索的分组、摘要）和 `FindGenerationOptionsTests` 已经覆盖，修改前后都应通过。

**同类**：store 那一半——`searchInterfaces` 和 `searchMembers` 的重复——见 PR121.06。会话里没有别的重复分组代码。

**工作量**：S。不依赖其他条目；与 PR121.05 / PR121.39 一起落地时，需要按上面的说明同步改类型名。


### PR121.42 两页共用一个会话，输入靠重载决议碰巧是纯事件

- **严重度**：Minor（加固，目前不出错）
- **审查编号**：AL8
- **状态**：方案待批，代码未改

**问题**：两层侧栏各有一个 Find 页，共用文档的同一个 `FindSession`。所以每一页写进会话的输入都必须是纯事件：页面绑定时如果重放一个初值（控件的默认状态），就会覆盖另一页已经设好的查询。现在大小写开关的输入是 `caseSensitiveButton.rx.state.asSignal()`（`FindViewController.swift:320`），只是碰巧解析到了 RxAppKit 那个不带初值的重载。换一种写法，例如 `.asSignal(onErrorJustReturn:)`，就会解析到 RxCocoa 带初值的 `ControlProperty`。那样一来，后创建的那一页一绑定，就会把默认的 `.off` 写进会话，冲掉另一页设好的「区分大小写」。

**四问**：
- **复现**：目前复现不了，现有写法恰好落在无初值的重载上；只有将来改写这个表达式才会出错。
- **基线**：本 PR 新引入。
- **影响**：现在没有用户可见的问题；属于埋着的脆弱点，改动只有一行，建议顺手加固。
- **历史**：新代码。同类的重载陷阱在项目里出现过：`rx.state` 有没有初值，取决于整条表达式最终选中 RxCocoa 还是 RxAppKit 的重载，此前判断 `combineLatest` 是否被卡住时就踩过一次。

**改法**：
- 改成与相邻几个输入一致的 `rx.click(with:)`。RxAppKit 的 `click(with:isStartWithDefaultValue:)` 默认 `isStartWithDefaultValue` 为 false，从构造上就只在点击时发值，并在那一刻读按钮状态，不再依赖重载怎么解析。
- 在 `FindViewModel.Input` 的文档注释里写明这条约束，免得以后有人加一个带初值的输入。
- 页面私有的 `filterString` 是带初值的 Driver，但它只写进本页 ViewModel 自己的属性，不写进会话，不受影响。

**拟修改**（基准：`12e1227b`）：
```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
@@ -317,5 +317,8 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewController<FindViewModel<Route>> {
         let input = FindViewModel<Route>.Input(
             modePathChoiceSelected: modePathChoiceSelected,
             memberKindFilterSelected: memberKindFilterSelected,
-            caseSensitiveToggled: caseSensitiveButton.rx.state.asSignal().map { $0 == .on },
+            // A click, read when it happens. `rx.state` carries an initial value
+            // under some overloads, and the page bound second would write its
+            // default into the session both pages share.
+            caseSensitiveToggled: caseSensitiveButton.rx.click(with: \.state).asSignal().map { $0 == .on },
             scopeMenuChoiceSelected: scopeMenuChoiceSelected,
```
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -11,4 +11,8 @@
 public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route> {
+    /// Every input is an event, never a state with an initial value. Both
+    /// sidebar levels have a page bound to the document's one `FindSession`,
+    /// and a value a page replays as it binds — its controls' defaults —
+    /// would overwrite the query the other page set.
     @MemberwiseInit(.public)
     public struct Input {
         /// A choice made in one of the mode path's menus.
```

**复现测试（示例）**：写不出修复前会变红的测试，原因有两个：现状不出错；而问题本身在 App target 的绑定表达式里，App target 没有单元测试 target。按「加固、无法复现」在 KnownIssues 里登记一条，原文如下：

> AL8（PR #121 审查）：Find 页的输入必须是纯事件，因为两层侧栏的页面共用一个 `FindSession`。大小写开关原先用 `rx.state.asSignal()`，靠重载决议才落在无初值的版本上；已改为 `rx.click(with: \.state)`，并在 `FindViewModel.Input` 的文档里写明约束。这是加固，原写法当时不出错，因此没有回归测试。

**同类**：`FindViewController` 写进会话的其他输入——模式路径、成员种类、范围菜单、回车提交——已经都是 `rx.click(with:)` 或 `rx.controlEvent`，属于纯事件。范围选择器 sheet 只在点 OK 时写一次会话，同一时刻也只有一个实例，不受影响。

**工作量**：S。不依赖其他条目。


### PR121.43 FindResultNode.isContentEqual 只比较子节点个数

- **严重度**：Minor
- **审查编号**：C39
- **状态**：方案待批，代码未改

**问题**：`FindResultNode.isContentEqual`（`FindResultNode.swift:230`）只比 `content` 和子节点**个数**。RxAppKit 靠它判断一行「有没有变」。过滤栏把同一类型下显示的命中换成另外几条、个数却不变时，adapter 判定没变，跳过刷新，大纲留着旧命中；点下去，打开的是旧节点。

**四问**：复现——关系模式最容易：一棵树里两个子节点各有一个孙节点，过滤词从命中其中一个换成命中另一个，第二层的变化永远到不了大纲；文本模式下，同一类型的两组命中只要个数相同，同样会被吞掉；基线——本 PR 新引入；影响——列表显示的内容与过滤结果不一致，点击会打开错误的命中，属中低；建议修，改动很小；历史——新代码，没有先例；Report navigator 的 `ReportNode` 有同样的浅比较（PR121.53）。

**改法**：
- 改成递归比较：先走 `self === source` 的快路径；否则要求 `content` 相等、标题相等、子节点的 identifier 序列逐个相等，再对每个子节点递归调用 `isContentEqual`。
- 标题也要比较。原因是 `content` 里的 `RuntimeObject` 的 `==` 只看身份 `(imagePath, name, kind)`，而类型行显示的是 `displayName`；按 AGENTS.md 关于 `hasSameContent(as:)` 的说明，换 Generation Options 重跑后，同一身份可能换一个名字显示。
- 有了 PR121.48 的节点缓存，没变的类型是同一个实例，绝大多数比较在 `===` 处就返回，递归的成本落不到实处。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
@@ -227,8 +227,22 @@ extension FindResultNode: OutlineNodeType {}
 extension FindResultNode: Differentiable {
     public var differenceIdentifier: String { identifier }
 
+    /// Whether the row and everything beneath it shows the same as `source`. The outline's
+    /// adapter skips a row this calls unchanged, so it has to look at the whole subtree: the
+    /// filter bar can swap which hits a type shows without changing how many.
     public func isContentEqual(to source: FindResultNode) -> Bool {
-        content == source.content && children.count == source.children.count
+        if self === source {
+            return true
+        }
+        // `content` compares a type by identity alone; the row also shows its display name,
+        // which a rerun under other Generation Options can change.
+        guard content == source.content,
+              appearance.title.isEqual(to: source.appearance.title),
+              children.count == source.children.count
+        else { return false }
+        return zip(children, source.children).allSatisfy { child, sourceChild in
+            child.identifier == sourceChild.identifier && child.isContentEqual(to: sourceChild)
+        }
     }
 }
 
```

**复现测试（示例）**：加在 PR121.07 新建的 `FindResultNodeTests.swift` 里。两条用例在现状下都会红：第一条两棵树的子节点个数相同；第二条的 `content` 按身份判定相等。
```swift
@Test("a type whose hits changed is different content, even with as many hits")
func contentComparesTheHits() {
    let object = FindResultFixtures.object(named: "Alpha")
    let before = FindResultNode.object(object, matchCount: 1, children: [
        FindResultNode.textMatch(FindResultFixtures.hit(in: "Alpha", lineNumber: 1), index: 0),
    ])
    let after = FindResultNode.object(object, matchCount: 1, children: [
        FindResultNode.textMatch(FindResultFixtures.hit(in: "Alpha", lineNumber: 7), index: 0),
    ])
    #expect(!after.isContentEqual(to: before))
}

@Test("a type shown under another display name is different content")
func contentComparesTheTitle() {
    let shortName = Fixtures.runtimeObject(name: "Outer.Inner", displayName: "Inner", kind: .swift(.type(.protocol)))
    let qualifiedName = Fixtures.runtimeObject(name: "Outer.Inner", displayName: "Outer.Inner", kind: .swift(.type(.protocol)))
    let before = FindResultNode.object(shortName, matchCount: 0, children: [])
    let after = FindResultNode.object(qualifiedName, matchCount: 0, children: [])
    #expect(!after.isContentEqual(to: before))
}

@Test("a rebuilt tree that shows the same is the same content")
func sameTreeIsSameContent() {
    #expect(FindResultFixtures.type("Alpha", hitCount: 3).isContentEqual(to: FindResultFixtures.type("Alpha", hitCount: 3)))
}
```

**同类**：`ReportNode.isContentEqual`（`ReportNode.swift:69`），见 PR121.53。
**工作量**：S；与 PR121.07 同批，因为 `.diffable` 依赖这里的递归比较才能发现子树变化。


### PR121.44 右键菜单 Open in New Tab 在无效位置可点却不做事

- **严重度**：Minor
- **审查编号**：C41
- **状态**：方案待批，代码未改

**问题**：Find 结果大纲挂的是一份静态菜单（`FindViewController.swift:272`），只有一项「Open in New Tab」，永远可用。在空白处右键，或者右键一个没有解析出类型的关系节点（灰色、不可跳转的那种），菜单照样弹出。点下去，`openInNewTabMenuItemAction`（`:425`）的守卫、或者 `FindViewModel.navigate` 里的 `navigationTarget == nil` 会悄悄返回，什么也不发生。

**四问**：复现——在 Find 结果的空白区域右键，选「Open in New Tab」，或者对关系模式里的灰色节点这样做，都没有任何反应；基线——本 PR 新引入；影响——不会坏数据，但点了没反应像是坏了，属低，建议顺手修；历史——侧栏早就按点中的行动态构建菜单（`SidebarRuntimeObjectViewController.swift:162-176`，空白处给空列表），Find 页没有沿用。

**改法**：
- 照侧栏的写法，菜单每次弹出前（`contextMenu.rx.needsUpdate`）都按 `clickedRow` 重建：点在空白处，或者该行不能跳转时，给空列表，AppKit 就不会弹出空菜单。
- 能否在新标签打开由 `FindResultNode.canOpenInNewTab` 决定，这样判定可以单独测试。
- 选中菜单项后，经 `contextMenu.rx.itemSelected` 拿到节点，直接送进 `resultOpenedInNewTab`，去掉 `openInNewTabRelay` 和 `@objc` action（AGENTS.md：单个已知控件用 rx 访问器，不手写 relay 加 target/action）。
- 菜单项类型声明在泛型 VC 之外，原因与本文件里的 `FindScopeButton` 相同：嵌在泛型类里的类型本身也是泛型。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
@@ -66,6 +66,12 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         }
     }
 
+    /// Whether the row goes somewhere, so its context menu offers Open in New Tab: an
+    /// unresolved relationship node does not.
+    public var canOpenInNewTab: Bool {
+        navigationTarget != nil
+    }
+
     /// The text the bottom filter bar matches against.
     public var filterableText: String {
         switch content {
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
@@ -16,10 +16,6 @@ import SnapKit
 /// presented by whichever level the page is on.
 final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewController<FindViewModel<Route>> {
-    // MARK: - Relays
-
-    private let openInNewTabRelay = PublishRelay<FindResultNode>()
-
     // MARK: - Query Parameters
 
     private let queryParametersView = NSView()
@@ -50,6 +46,11 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
     private let resultsTopSeparatorView = NSBox()
 
+    /// The rows' context menu, rebuilt from the clicked row each time it opens. A click on
+    /// empty space, or on a row that goes nowhere, gets no items, so AppKit shows no menu at
+    /// all.
+    private let contextMenu = NSMenu()
+
     // MARK: - Filter Bar
 
     private let filterSeparatorView = NSBox()
@@ -269,12 +270,7 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
             $0.allowsTypeSelect = true
             $0.headerView = nil
             $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
-            $0.menu = NSMenu().then {
-                $0.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTabMenuItemAction(_:)), keyEquivalent: "").then {
-                    $0.image = SFSymbols(systemName: .plusSquareOnSquare).nsImage
-                    $0.target = self
-                }
-            }
+            $0.menu = contextMenu
         }
 
         filterSearchField.do {
@@ -295,6 +291,21 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
         let resultClicked: Signal<FindResultNode> = outlineView.rx.modelSelected().asSignal()
 
+        let contextMenuItems: Observable<[FindResultMenuItem]> = contextMenu.rx.needsUpdate
+            .asObservable()
+            .map { [weak outlineView] _ -> [FindResultMenuItem] in
+                guard let outlineView,
+                      outlineView.clickedRow >= 0,
+                      let node = outlineView.item(atRow: outlineView.clickedRow) as? FindResultNode,
+                      node.canOpenInNewTab
+                else { return [] }
+                return [FindResultMenuItem(title: "Open in New Tab", image: SFSymbols(systemName: .plusSquareOnSquare).nsImage, node: node)]
+            }
+        contextMenu.rx.items(source: contextMenuItems)({ menuItem, entry in menuItem.image = entry.image }).disposed(by: rx.disposeBag)
+        let resultOpenedFromMenu: Signal<FindResultNode> = contextMenu.rx.itemSelected(FindResultMenuItem.self)
+            .map(\.item.node)
+            .asSignal(onErrorSignalWith: .empty())
+
         // Only what the user picks: the pop-up's own selection when it is bound would overwrite
         // a kind chosen on the other sidebar level's page.
         let memberKindFilterSelected: Signal<FindMemberKindFilter> = memberKindPopUpButton.rx
@@ -322,7 +333,7 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
             searchCommitted: searchField.rx.controlEvent.asSignal().map { [searchField] in searchField.stringValue },
             filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
             resultClicked: resultClicked,
-            resultOpenedInNewTab: openInNewTabRelay.asSignal()
+            resultOpenedInNewTab: resultOpenedFromMenu
         )
         let output = viewModel.transform(input)
 
@@ -419,15 +430,20 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
         summaryView.isHidden = summary == nil
         summaryHeightConstraint?.update(offset: summary == nil ? 0 : 22)
     }
-
-    // MARK: - Context Menu
-
-    @objc private func openInNewTabMenuItemAction(_ sender: NSMenuItem) {
-        guard outlineView.hasValidClickedRow, let node = outlineView.itemAtClickedRow as? FindResultNode else { return }
-        openInNewTabRelay.accept(node)
-    }
 }
 
+// MARK: - Context Menu Item
+
+/// One entry of the results' context menu, carrying the row it acts on.
+///
+/// Declared outside the generic view controller: a type nested in a generic class is generic
+/// itself.
+private struct FindResultMenuItem: RxMenuItemRepresentable {
+    let title: String
+    let image: NSImage?
+    let node: FindResultNode
+}
+
 // MARK: - Scope Button
```

与 PR121.07 合并时，`resultOpenedInNewTab` 取两者之和：`.merge(resultOpenedFromMenu, resultOpenedWithOption)`。

**复现测试（示例）**：加在 `FindResultNodeTests.swift`（PR121.07 新建）里。
```swift
@Test("a row opens in a new tab only when it goes somewhere")
func onlyRowsThatGoSomewhereOpenInNewTab() throws {
    let type = FindResultFixtures.type("Alpha", hitCount: 1)
    #expect(type.canOpenInNewTab)
    #expect(try #require(type.children.first).canOpenInNewTab)
    let unresolved = FindResultNode(content: .relationship(name: "MissingType", object: nil), identifier: "tree|missing")
    #expect(!unresolved.canOpenInNewTab)
}
```
这是新契约，修复前不存在会红的形态。真正的问题出在菜单的接线上，而菜单在 App target 里，App 没有单元测试 target，包内测试够不着。修复前的现象只能手工确认：在空白处右键会弹出菜单，修复后不再弹出。

**同类**：无。侧栏菜单本来就是按行动态构建的；内容区的菜单（`ContentTextViewController.swift` 的 `textView(_:menu:for:at:)`）只在点中链接时才加这一项。
**工作量**：S；与 PR121.07 改同一段 Input 构造，建议同批。


### PR121.45 Scope chooser 每约 16 ms 滚回第一个选中行

- **严重度**：Minor
- **审查编号**：C40 + F7
- **状态**：方案待批，代码未改

**问题**：
- `FindScopeChooserViewModel` 每收到一次 `buildStatesByImagePath`（语料构建期间约每 16 ms 一次），就重算整个列表、用 `localizedCaseInsensitiveCompare` 全量重排（F7），再重新给 `allRows` 赋值（`FindScopeChooserViewModel.swift:84-95`）。`rows` 随之重发。
- VC 里 `combineLatest(rows, selectedImagePaths)` 的订阅（`FindScopeChooserViewController.swift:169-178`），只要 `isRevealingSelection` 还为真，每次都会 `scrollRowToVisible`；而这个标志要等用户选中之后才清掉。结果是用户在构建期间滚动列表，列表不停被拽回第一个选中的镜像。
- 用户第一次选中时还会跳一下：清标志的订阅（`:181`）注册在 `transform` 订阅 `selectionChanged` 之后，所以选中先触发了一次滚动，标志才被清掉。
- 那里的顺序也是先选中、再滚动（`:173` → `:176`），违反 AGENTS.md「先滚动再选中」的规则。

**四问**：复现——构建期间打开 Custom Scopes…，把列表往下滚，滚动位置每帧被拉回；基线——本 PR 新引入；影响——构建期间表单基本没法滚动浏览，属中低，建议修；历史——新代码。表单「按 ViewModel 里的选择重新选行」的设计见提案 §9，这次不改它，只改「何时滚动」和「何时重发列表」。

**改法**：
- 列表只在**列出的镜像变了**的时候才重排、才重新发布。只有状态变化时，`makeRows` 里的 `update(status:)` 已经通过 cell 的绑定原地刷新了那一行，不必重发列表。
- 「把范围内的第一个镜像滚进视野」改成 ViewModel 的一次性输出 `revealedImagePath`：只在引擎第一次答复索引列表时发一次，因为这时列表才完整；用户改过选择之后就不再发。
- VC 去掉 `isRevealingSelection` 和选中路径里的滚动。收到 `revealedImagePath` 时，先滚动并强制布局（顺序与 `selectRowBringingIntoView` 一致），选中仍由原来那条订阅负责，这条订阅从此不再滚动。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindScopeChooserViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindScopeChooserViewModel.swift
@@ -41,6 +41,9 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
         public let selectedImagePaths: Driver<Set<String>>
         /// OK cannot be clicked while nothing is selected.
         public let isOKEnabled: Driver<Bool>
+        /// The image to scroll into view, once, when the list is first complete: the first
+        /// image the scope holds, in display order.
+        public let revealedImagePath: Signal<String>
     }
 
     private let session: FindSession
@@ -53,6 +56,22 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
     /// cell and updates in place. Images that leave the list are dropped.
     private var cellViewModelsByImagePath: [String: FindScopeImageCellViewModel] = [:]
 
+    /// The listed images in display order, and the same images as a set. Sorted again only
+    /// when the images listed change — not on every build state change, which comes about every
+    /// 16 ms while corpora build.
+    private var sortedImagePaths: [String] = []
+
+    private var sortedImagePathSet: Set<String> = []
+
+    /// Whether the scope's first image has been brought into view, which happens once.
+    private var hasRevealedSelection = false
+
+    /// Whether the user has changed the selection; after that nothing is revealed.
+    private var hasUserChangedSelection = false
+
+    private let revealedImagePathRelay = PublishRelay<String>()
+
     /// The engine's indexed images; `nil` until it answers.
     @RxObserved
     private var indexedImagePaths: [String]? = nil
@@ -89,7 +108,7 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
         .subscribeOnNext { [weak self] indexedImagePaths, buildStates in
             guard let self else { return }
             MainActor.assumeIsolated {
-                self.allRows = self.makeRows(indexedImagePaths: indexedImagePaths, buildStates: buildStates)
+                self.applyListing(indexedImagePaths: indexedImagePaths, buildStates: buildStates)
             }
         }
         .disposed(by: rx.disposeBag)
@@ -102,6 +131,7 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
 
         input.selectionChanged.emitOnNext { [weak self] imagePaths in
             guard let self else { return }
+            hasUserChangedSelection = true
             selectedImagePaths = imagePaths
         }
         .disposed(by: rx.disposeBag)
@@ -127,7 +157,8 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
         return Output(
             rows: rows,
             selectedImagePaths: $selectedImagePaths.asDriver(),
-            isOKEnabled: $selectedImagePaths.asDriver().map { !$0.isEmpty }.distinctUntilChanged()
+            isOKEnabled: $selectedImagePaths.asDriver().map { !$0.isEmpty }.distinctUntilChanged(),
+            revealedImagePath: revealedImagePathRelay.asSignal()
         )
     }
 
@@ -168,11 +199,14 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
     private func makeRows(indexedImagePaths: [String]?, buildStates: [String: RuntimeInterfaceCorpusBuildState]) -> [FindScopeImageCellViewModel] {
         let knownImagePaths = Set(indexedImagePaths ?? []).union(buildStates.keys)
         let listedImagePaths = knownImagePaths.union(scopeImagePaths)
-        let sortedImagePaths = listedImagePaths.sorted { leftImagePath, rightImagePath in
-            let order = FindScope.imageName(of: leftImagePath).localizedCaseInsensitiveCompare(FindScope.imageName(of: rightImagePath))
-            return order == .orderedSame ? leftImagePath < rightImagePath : order == .orderedAscending
+        if listedImagePaths != sortedImagePathSet {
+            sortedImagePaths = listedImagePaths.sorted { leftImagePath, rightImagePath in
+                let order = FindScope.imageName(of: leftImagePath).localizedCaseInsensitiveCompare(FindScope.imageName(of: rightImagePath))
+                return order == .orderedSame ? leftImagePath < rightImagePath : order == .orderedAscending
+            }
+            sortedImagePathSet = listedImagePaths
         }
         let rows = sortedImagePaths.map { imagePath in
             let cellViewModel = cellViewModelsByImagePath[imagePath] ?? FindScopeImageCellViewModel(imagePath: imagePath)
             cellViewModelsByImagePath[imagePath] = cellViewModel
@@ -185,6 +219,17 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
         return rows
     }
 
+    /// The engine's images and their build states, as they change: rows for them, published
+    /// again only when the images listed change — a status alone has already reached its row
+    /// through the cell's binding — and the scope revealed once the list is complete.
+    func applyListing(indexedImagePaths: [String]?, buildStates: [String: RuntimeInterfaceCorpusBuildState]) {
+        let rows = makeRows(indexedImagePaths: indexedImagePaths, buildStates: buildStates)
+        if rows.map(\.imagePath) != allRows.map(\.imagePath) {
+            allRows = rows
+        }
+        // The list is complete once the engine has listed its images.
+        if indexedImagePaths != nil {
+            revealSelectionOnce(in: rows)
+        }
+    }
+
+    /// Brings the scope's first image into view, once: when the engine has listed its images,
+    /// for only then is the list complete — as Xcode's chooser reveals the scope's items when
+    /// it opens. Nothing is revealed after the user has changed the selection.
+    private func revealSelectionOnce(in rows: [FindScopeImageCellViewModel]) {
+        guard !hasRevealedSelection, !hasUserChangedSelection else { return }
+        hasRevealedSelection = true
+        guard let firstSelectedRow = rows.first(where: { selectedImagePaths.contains($0.imagePath) }) else { return }
+        revealedImagePathRelay.accept(firstSelectedRow.imagePath)
+    }
+
     /// What a row says about its image's corpus.
     static func status(of buildState: RuntimeInterfaceCorpusBuildState?, isIndexed: Bool) -> String {
         switch buildState {
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindScopeChooserViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindScopeChooserViewController.swift
@@ -25,10 +25,6 @@ final class FindScopeChooserViewController<Route: FindNavigatorRoutable>: BaseVi
 
     private let okButton = PushButton(title: "OK", titleFont: .systemFont(ofSize: 13))
 
-    /// Whether the list still brings the first selected row into view as its rows change, as
-    /// Xcode's chooser reveals the scope's items when it opens. It stops once the user selects.
-    private var isRevealingSelection = true
-
     override var contentInsets: NSDirectionalEdgeInsets { .init(top: 20, leading: 20, bottom: 20, trailing: 20) }
 
     // MARK: - Lifecycle
@@ -166,23 +162,29 @@ final class FindScopeChooserViewController<Route: FindNavigatorRoutable>: BaseVi
         // Subscribed after the rows binding, so the list has reloaded by the time this runs. A
         // reload keeps the selection by row number, which a row inserted above — an image indexed
         // while the sheet is open — would move onto another image.
-        Driver.combineLatest(output.rows, output.selectedImagePaths).driveOnNext { [weak self] rows, selectedImagePaths in
-            guard let self else { return }
+        Driver.combineLatest(output.rows, output.selectedImagePaths).driveOnNext { rows, selectedImagePaths in
             let selectedRowIndexes = IndexSet(rows.indices.filter { selectedImagePaths.contains(rows[$0].imagePath) })
             if tableView.selectedRowIndexes != selectedRowIndexes {
                 tableView.selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
             }
-            if isRevealingSelection, let firstSelectedRow = selectedRowIndexes.first {
-                tableView.scrollRowToVisible(firstSelectedRow)
-            }
         }
         .disposed(by: rx.disposeBag)
 
-        tableView.proposedSelection().asSignal().emitOnNext { [weak self] _ in
-            guard let self else { return }
-            isRevealingSelection = false
+        // Once, when the list is first complete: the scope's first image scrolled into view.
+        // The layout is forced so the row view exists before anything selects it again.
+        output.revealedImagePath.emitOnNext { imagePath in
+            let row = (0 ..< tableView.numberOfRows).first { row in
+                (try? tableView.rx.model(at: row) as FindScopeImageCellViewModel)?.imagePath == imagePath
+            }
+            guard let row else { return }
+            tableView.scrollRowToVisible(row)
+            tableView.layoutSubtreeIfNeeded()
         }
         .disposed(by: rx.disposeBag)
 
```

（`tableView` 是 `setupBindings` 开头取出的局部常量，两个闭包本来就只用它，不必再捕获 `self`。）

**复现测试（示例）**：加在 `FindScopeChooserViewModelTests.swift`。

第一条直接调用上面的 `applyListing`。用真实构建去推状态不稳定：协调器一出现就会补建所有已索引的镜像，测试赶不上状态变化。它模拟两次只改状态、不改成员的进度刷新。现状下等价的代码每次都给 `allRows` 重新赋值，`rows` 发两次，所以会红；而 VC 正是在每次重发时滚动的。

第二条验证新契约。
```swift
@Test("a build state change updates its row's status without publishing the rows again")
func buildProgressLeavesTheRowsAlone() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.progress", loading: [TestImages.libobjc])
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    let (viewModel, output) = makeViewModel(in: environment)
    defer { withExtendedLifetime(viewModel) {} }
    let rows = try await nextValue(from: output.rows, timeout: 30) { rows in rows.contains { $0.imagePath == TestImages.libobjc } }
    let libobjcRow = try #require(rows.first { $0.imagePath == TestImages.libobjc })
    let listedImagePaths = rows.map(\.imagePath)

    var publishedRowCount = 0
    let subscription = output.rows.driveOnNext { _ in publishedRowCount += 1 }
    defer { subscription.dispose() }
    try await settleMainQueue()
    let publishedBeforeProgress = publishedRowCount

    // Two progress flushes: the same images, other states.
    viewModel.applyListing(indexedImagePaths: listedImagePaths, buildStates: [TestImages.libobjc: .pending])
    #expect(libobjcRow.status == "waiting")
    viewModel.applyListing(indexedImagePaths: listedImagePaths, buildStates: [TestImages.libobjc: .failed(message: "fixture")])
    #expect(libobjcRow.status == "failed")
    try await settleMainQueue()

    #expect(publishedRowCount == publishedBeforeProgress)
    await engine.stop()
}

@Test("the scope's first image is revealed once the engine lists its images, and never again")
func revealsTheScopeOnce() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.reveal", loading: [TestImages.libobjc])
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.make { environment.documentState.findSession }.update { $0.scope = .images([TestImages.libobjc]) }
    let (viewModel, output) = makeViewModel(in: environment)
    defer { withExtendedLifetime(viewModel) {} }

    #expect(try await nextValue(from: output.revealedImagePath, timeout: 30) == TestImages.libobjc)

    var laterReveals: [String] = []
    let subscription = output.revealedImagePath.emitOnNext { laterReveals.append($0) }
    defer { subscription.dispose() }
    let listedImagePaths = try await nextValue(from: output.rows).map(\.imagePath)
    viewModel.applyListing(indexedImagePaths: listedImagePaths, buildStates: [TestImages.libobjc: .pending])
    selectionChangedRelay.accept([TestImages.libobjc])
    viewModel.applyListing(indexedImagePaths: listedImagePaths, buildStates: [:])
    try await settleMainQueue()
    #expect(laterReveals.isEmpty)
    await engine.stop()
}
```

**同类**：
- Find 页恢复选中也要守「先滚动再选中」，在 PR121.07 里那条路径只选、不滚动，不会触发这个问题。
- 「先滚动再选中」现在有两份实现（侧栏的 `selectRowBringingIntoView` 和 `StatefulOutlineView.restoreSelectedItem`），这里是第三处用到的地方，可以另收拢成一个 helper，不强求。
- `makeRows` 每个 tick 都对每个镜像调 `FindScope.imageName(of:)`，排序缓存之后剩下的开销很小，不另改。

**工作量**：S–M；无依赖。


### PR121.46 挂起的高亮在之后不相干的访问时触发

- **严重度**：Minor
- **审查编号**：C42 + AL6
- **状态**：方案待批，代码未改

**问题**：点 Find 结果时，高亮请求放在文档级的一个「邮箱」里，即 `DocumentState.pendingContentHighlight`（`DocumentState.swift:235`）。它只在**同一对象**渲染完成时，才由内容区的 ViewModel 用 `takeContentHighlight(for:)` 取走（`ContentTextViewModel.swift:220`）。

以下两种情况，请求会一直留在邮箱里：
- 点了 A 的命中，A 还没渲染完就去了 B；
- A 的接口取不回来。`catchAndReturn(nil)` 让渲染根本不会发生，请求也就没人取。

之后不管从侧栏还是历史回到 A，新建的 ViewModel 一渲染完就把这条旧请求取走，旧命中被闪一下，滚动位置也跳过去。

**四问**：
- **复现**：点 SwiftUI 某个大类型的一条命中，渲染完成前立刻在侧栏点另一个类型；之后再从侧栏回到前一个类型，内容区会跳到那条旧命中并闪一下。换引擎后同样会残留。
- **基线**：本 PR 新引入（c3ad0839）。
- **影响**：偶发、无害，但看起来莫名其妙。程度低，建议修，方案同时去掉一个全局可变状态。
- **历史**：邮箱是提案 §4「落地形态」里定的实现方式，并非用户的决定。提案的决策日志没有讨论过它的生命周期。

**改法**（推荐：请求跟着路由走，即 AL6）：
- `ContentRoute` 加 `.rootHighlighting` / `.nextHighlighting` 两个 case，与 `SelectionRoute` 已有的两个 case 对称。
- `MainCoordinator.fanOut` 把 `.pushHighlighting` / `.openInNewTabHighlighting` 携带的请求转给这两个新 case。
- `ContentCoordinator` 把请求传进 `ContentTextViewModel` 的构造器；ViewModel 在**自己的**第一次渲染时用掉它。
- 删除 `pendingContentHighlight`、`takeContentHighlight(for:)` 和 `PendingContentHighlight`；`SelectionRouter` 的两个 highlighting case 从此只管导航。
- 这样请求的生命期就等于那个 ViewModel：被替换、取失败、换引擎，请求都随它一起消失，不会再有残留。
- 内容区本来就为每个对象新建 ViewModel（`ContentCoordinator.rebindTextViewController` 里的 `forceRebind: true`），所以同一对象上再点一条命中，也照样会重新定位。
- **最小替代方案**：在 `SelectionRouter.trigger` 里，碰到其它路由（含 `.switchEngine` 和 `.switchImage`）先清空邮箱。只要几行，但全局邮箱和「渲染时按对象来取」的结构都还在。
- 落地时同步修改提案 §4 的「落地形态」，并在决策日志里记一条。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentRoute.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentRoute.swift
@@ -9,6 +9,11 @@ import RuntimeViewerArchitectures
 public enum ContentRoute: Routable {
     case placeholder
     case root(RuntimeObject)
+    /// `root`, with where in the interface to scroll and flash once it is first on screen —
+    /// a Find navigator hit opened in a new tab.
+    case rootHighlighting(RuntimeObject, ContentHighlightRequest)
     case next(RuntimeObject)
+    /// `next`, with the same; a Find navigator hit.
+    case nextHighlighting(RuntimeObject, ContentHighlightRequest)
     case back
 }
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
@@ -163,10 +163,14 @@ final class MainCoordinator: …
             // `SidebarRuntimeObjectListViewModel` by observing
             // `documentState.$selectedRuntimeObject` directly — no
             // coordinator routing is needed for a pure UI
             // scroll-and-highlight.
-        case .push(let object), .pushHighlighting(let object, _):
-            // The highlight rides on `DocumentState.pendingContentHighlight`;
-            // the panes are told the same thing either way.
+        case .push(let object):
             contentCoordinator.contextTrigger(.next(object))
             inspectorCoordinator.contextTrigger(.next(.object(object)))
+        case .pushHighlighting(let object, let highlightRequest):
+            // The highlight travels with the content route, so it lives exactly as long as the
+            // content ViewModel built for this navigation.
+            contentCoordinator.contextTrigger(.nextHighlighting(object, highlightRequest))
+            inspectorCoordinator.contextTrigger(.next(.object(object)))
         case .pop:
             if documentState.selectionStack.isEmpty {
                 contentCoordinator.contextTrigger(.placeholder)
@@ -204,11 +208,15 @@ final class MainCoordinator: …
             contentCoordinator.contextTrigger(.placeholder)
             inspectorCoordinator.contextTrigger(.placeholder)
-        case .openInNewTab(let object), .openInNewTabHighlighting(let object, _):
+        case .openInNewTab(let object):
             // New tab already showing `object`, which was also recorded on the
             // timeline; bind both panes to it.
             contentCoordinator.contextTrigger(.root(object))
             inspectorCoordinator.contextTrigger(.root(.object(object)))
+        case .openInNewTabHighlighting(let object, let highlightRequest):
+            contentCoordinator.contextTrigger(.rootHighlighting(object, highlightRequest))
+            inspectorCoordinator.contextTrigger(.root(.object(object)))
         case .switchTab, .closeTab:
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift
@@ -86,8 +86,12 @@ final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition>
             return enterPlaceholderScene()
         case .root(let runtimeObject):
             return enterTextScene(for: runtimeObject, forceRebind: true)
+        case .rootHighlighting(let runtimeObject, let highlightRequest):
+            return enterTextScene(for: runtimeObject, highlightRequest: highlightRequest, forceRebind: true)
         case .next(let runtimeObject):
             return enterTextScene(for: runtimeObject, forceRebind: true)
+        case .nextHighlighting(let runtimeObject, let highlightRequest):
+            return enterTextScene(for: runtimeObject, highlightRequest: highlightRequest, forceRebind: true)
         case .back:
             if let selected = documentState.selectedRuntimeObject {
                 return enterTextScene(for: selected, forceRebind: false)
@@ -106,8 +110,8 @@ final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition>
     }
 
-    private func enterTextScene(for runtimeObject: RuntimeObject, forceRebind: Bool) -> ContentTransition {
-        let didReplaceViewController = rebindTextViewController(for: runtimeObject, forceRebind: forceRebind)
+    private func enterTextScene(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, forceRebind: Bool) -> ContentTransition {
+        let didReplaceViewController = rebindTextViewController(for: runtimeObject, highlightRequest: highlightRequest, forceRebind: forceRebind)
         // A replacement has to be installed even when the text scene is already showing:
         // otherwise the freshly built view controller is bound but never displayed.
         guard !isCurrentTextScene || didReplaceViewController else { return .none() }
@@ -117,7 +121,7 @@ final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition>
 
     /// - Returns: whether the view controller itself was replaced.
     @discardableResult
-    private func rebindTextViewController(for runtimeObject: RuntimeObject, forceRebind: Bool) -> Bool {
+    private func rebindTextViewController(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest?, forceRebind: Bool) -> Bool {
         let desiredKind = desiredEditorKind()
         var didReplaceViewController = false
         if !isCurrentTextScene || currentEditorKind != desiredKind {
@@ -128,7 +132,7 @@ final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition>
         }
         guard forceRebind || boundRuntimeObject != runtimeObject else { return didReplaceViewController }
         boundRuntimeObject = runtimeObject
-        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
+        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, highlightRequest: highlightRequest, documentState: documentState, router: self)
         textViewController.setupBindings(for: viewModel)
         textViewController.loadViewIfNeeded()
         return didReplaceViewController
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentTextViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentTextViewModel.swift
@@ -72,16 +72,25 @@ public final class ContentTextViewModel: ViewModel<ContentRoute> {
     /// on screen — the Find navigator's hit, once the interface is rendered.
     private let highlightRangeRelay = PublishRelay<NSRange>()
 
-    public convenience init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<ContentRoute>) {
-        self.init(runtimeObject: runtimeObject, documentState: documentState, router: router, interfaceProvider: nil)
+    /// The Find navigator hit this ViewModel was built to show, until its first render uses it.
+    /// Owned here, not by the document, so it goes away with the navigation that brought it.
+    private var pendingHighlightRequest: ContentHighlightRequest?
+
+    /// - Parameter highlightRequest: where the Find navigator's hit sits, to reveal once the
+    ///   interface is first on screen; `nil` for every other way of showing an object.
+    public convenience init(runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, documentState: DocumentState, router: any Router<ContentRoute>) {
+        self.init(runtimeObject: runtimeObject, highlightRequest: highlightRequest, documentState: documentState, router: router, interfaceProvider: nil)
     }
 
     init(
         runtimeObject: RuntimeObject,
+        highlightRequest: ContentHighlightRequest? = nil,
         documentState: DocumentState,
         router: any Router<ContentRoute>,
         interfaceProvider: InterfaceProvider?
     ) {
         self.runtimeObject = runtimeObject
+        self.pendingHighlightRequest = highlightRequest
         self.theme = ResolvedTheme.fallback
         let interfaceCache = documentState.interfaceCache
         let contentLoadingDelay = Self.contentLoadingDelay()
@@ -211,14 +220,15 @@ public final class ContentTextViewModel: ViewModel<ContentRoute> {
             .bind(to: $attributedString)
             .disposed(by: rx.disposeBag)
 
-        // A Find navigator hit arrives as a pending highlight on the document;
-        // once this object's text is rendered, locate it in that text (off
-        // main — the text can be megabytes) and hand the range to the view.
-        // Taken, not observed: the request belongs to exactly one render.
+        // A Find navigator hit arrives with the route that built this ViewModel;
+        // once the object's text is first rendered, locate it in that text (off
+        // main — the text can be megabytes) and hand the range to the view.
+        // Used once: later renders (theme, options) leave the scroll position alone.
         $renderedInterface
             .compactMap { $0 }
             .flatMapLatest { [weak self] rendered -> Observable<NSRange?> in
-                guard let self, let request = self.documentState.takeContentHighlight(for: self.runtimeObject) else { return .empty() }
+                guard let self, let request = self.pendingHighlightRequest else { return .empty() }
+                self.pendingHighlightRequest = nil
                 let displayedText = rendered.attributedString.string
                 return Observable.just(())
                     .observe(on: renderScheduler)
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
@@ -226,32 +226,8 @@ public final class DocumentState …
         }
         .distinctUntilChanged()
     }
-
-    /// Where the content pane should scroll once it shows `object`, set by
-    /// the highlighting selection routes and taken by the pane's ViewModel
-    /// through `takeContentHighlight(for:)` — a one-shot handshake, not
-    /// state the panes render.
-    @RxObserved
-    public fileprivate(set) var pendingContentHighlight: PendingContentHighlight? = nil
-
-    /// The pending highlight for `object`, cleared on the way out; `nil`
-    /// when there is none or it was meant for another object.
-    public func takeContentHighlight(for object: RuntimeObject) -> ContentHighlightRequest? {
-        guard let pendingContentHighlight, pendingContentHighlight.object == object else { return nil }
-        self.pendingContentHighlight = nil
-        return pendingContentHighlight.request
-    }
 }
 
-/// A `ContentHighlightRequest` bound to the object it belongs to.
-public struct PendingContentHighlight: Hashable, Sendable {
-    public let object: RuntimeObject
-    public let request: ContentHighlightRequest
-
-    public init(object: RuntimeObject, request: ContentHighlightRequest) {
-        self.object = object
-        self.request = request
-    }
-}
-
 private final class SelectionRouter: Router {
@@ -362,11 +338,11 @@ private final class SelectionRouter: Router {
             documentState.activeTabIndex = documentState.tabs.count - 1
             pushOntoTimeline(object)
-        case .pushHighlighting(let object, let highlight):
-            documentState.pendingContentHighlight = PendingContentHighlight(object: object, request: highlight)
+        case .pushHighlighting(let object, _):
+            // The highlight rides on the route itself, to the content pane.
             pushOntoTimeline(object)
-        case .openInNewTabHighlighting(let object, let highlight):
-            documentState.pendingContentHighlight = PendingContentHighlight(object: object, request: highlight)
+        case .openInNewTabHighlighting(let object, _):
             documentState.tabs.append(DocumentTab(object: object))
             documentState.activeTabIndex = documentState.tabs.count - 1
             pushOntoTimeline(object)
```

**复现测试（示例）**：放在 `ContentTextHighlightTests.swift`。

新增的第一条在现状下会红：被放弃的请求留在邮箱里，之后为 Foo 新建的 ViewModel 一渲染完就把它取走，于是发出一个范围。原有那条 `foreignHighlightIsLeftAlone` 测的正是邮箱，邮箱删掉之后改由这一条取代。`highlightIsLocatedAndTaken` 改为在构造 ViewModel 时传入请求。
```swift
private func makeViewModel(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, in environment: ViewModelTestEnvironment) -> (ContentTextViewModel, ContentTextViewModel.Output) {
    let viewModel = environment.make {
        ContentTextViewModel(
            runtimeObject: runtimeObject,
            highlightRequest: highlightRequest,
            documentState: environment.documentState,
            router: router,
            interfaceProvider: { runtimeObject, _ in
                RuntimeObjectInterface(object: runtimeObject, interfaceString: SemanticString(stringLiteral: Self.interfaceText))
            }
        )
    }
    let output = viewModel.transform(.init(runtimeObjectClicked: .empty(), runtimeObjectOpenedInNewTab: .empty()))
    return (viewModel, output)
}

@Test("a highlight left behind by a navigation that moved on never reaches a later visit")
func abandonedHighlightNeverReachesALaterVisit() async throws {
    let environment = ViewModelTestEnvironment()
    let abandoned = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))
    let request = ContentHighlightRequest(lineNumber: 3, lineText: "- (id)initWithFormat:(id)format;", matchRangeInLine: nil, query: "initWithFormat:", isCaseSensitive: true)
    // A hit in Foo clicked, then Bar before Foo's interface ever rendered.
    environment.documentState.selectionRouter.trigger(.pushHighlighting(abandoned, request))
    environment.documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "Bar", kind: .objc(.type(.class)))))

    // Foo again later, from the sidebar: a plain visit.
    let (viewModel, output) = makeViewModel(for: abandoned, in: environment)
    defer { withExtendedLifetime(viewModel) {} }
    var highlightRanges: [NSRange] = []
    let subscription = output.highlightRange.emitOnNext { highlightRanges.append($0) }
    defer { subscription.dispose() }

    _ = try await nextValue(from: output.attributedString, timeout: 20) { $0 != nil }
    try await Task.sleep(for: .milliseconds(500))
    #expect(highlightRanges.isEmpty)
}

@Test("the request a ViewModel is built with is located once, on the first render")
func requestIsLocatedOnTheFirstRender() async throws {
    let environment = ViewModelTestEnvironment()
    let object = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))
    let request = ContentHighlightRequest(
        lineNumber: 3,
        lineText: "- (id)initWithFormat:(id)format; // IMP: 0x1000",
        matchRangeInLine: nil,
        query: "initWithFormat:",
        isCaseSensitive: true
    )
    let (viewModel, output) = makeViewModel(for: object, highlightRequest: request, in: environment)
    defer { withExtendedLifetime(viewModel) {} }

    let range = try await nextValue(from: output.highlightRange, timeout: 20)
    let expectedLocation = Self.interfaceText.utf16.distance(from: Self.interfaceText.startIndex, to: Self.interfaceText.range(of: "initWithFormat:")!.lowerBound)
    #expect(range == NSRange(location: expectedLocation, length: "initWithFormat:".utf16.count))
}
```

`FindViewModelTests` 里有两处直接读邮箱，改为订阅 `routeSignal`：`clickingHitPushesAndHighlights` 和 `memberSearch` 的 `takeContentHighlight`，以及 `clickingTypeRow` 的 `pendingContentHighlight == nil`。下面以第一处为例：
```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindViewModelTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindViewModelTests.swift
@@ -193,17 +193,19 @@ struct FindViewModelTests {
             return
         }
 
+        var routes: [SelectionRoute] = []
+        let routeSubscription = environment.documentState.routeSignal.emitOnNext { routes.append($0) }
+        defer { routeSubscription.dispose() }
         resultClickedRelay.accept(hit)
         try await settleMainQueue()
 
         #expect(environment.documentState.selectedRuntimeObject == match.object)
-        let highlight = try #require(environment.documentState.takeContentHighlight(for: match.object))
+        guard case .pushHighlighting(let object, let highlight)? = routes.last else {
+            Issue.record("expected a highlighting push, got \(routes)")
+            return
+        }
+        #expect(object == match.object)
         #expect(highlight.lineNumber == match.lineNumber)
         #expect(highlight.lineText == match.lineText)
         #expect(highlight.matchRangeInLine == match.matchRangeInLine)
         #expect(highlight.query == "initWithFormat:")
-        // Taken once: the second ask finds nothing.
-        #expect(environment.documentState.takeContentHighlight(for: match.object) == nil)
         #expect(router.triggeredRoutes.isEmpty)
     }
```

**同类**：`DocumentState` 上没有别的一次性邮箱字段（搜过 `pending` 和 `func take`）。
**工作量**：M；无依赖。这条要用户拍板：用推荐方案（6 个源文件加测试），还是用最小替代方案。


### PR121.47 长行与成员命中的高亮定位错位

- **严重度**：Minor
- **审查编号**：C43
- **状态**：方案待批，代码未改

**问题**：点 Find 结果后，内容区用 `ContentHighlightRequest.locate(in:)` 在屏上的文本里找回那处命中。有三种情况会定位错，或者根本定位不到。

1. **长行**：超过 320 个 UTF-16 单位的行，Core 会在命中周围截出一个窗口，两端加「…」（`RuntimeInterfaceTextMatcher.windowed`）。`locate` 的第一步要求整行相等，而窗口永远等不了整行。
   - **正则模式**：`FindViewModel.highlight` 传过来的 `query` 是空串，第二步也被关掉，所以**长行上的正则命中一律定位不到**，点了只跳到类型顶部。
   - **其他模式**：第二步用 Foundation 的 `range(of:options:)`，做的是 Unicode 大小写折叠，也不认匹配方式，只取行内第一处，常常落在更早出现的子串上。
2. **成员**：成员请求的 `matchRangeInLine` 传的是 `nil`。即使第一步找对了行，`rangeInsideLine` 也会退回「行内第一处子串」，于是 `@property (copy) NSURL *URL;` 高亮的是 `NSURL` 里面的 `URL`。
3. **同类**：Find 结果行里的强调也错。`FindResultNode.nameRange(of:)`（`FindResultNode.swift:175`）用 `range(of: name)` 取第一处，同一行加粗的也是 `NSURL` 里的 `URL`。

**四问**：
- **复现**：搜 SwiftUI 里某个长签名中靠后的类型名，或者用正则搜任意一处长行，点结果后要么不高亮，要么闪在前面的同名子串上；对 Foundation 做 Members 搜索 `URL`，点 `NSURLRequest.URL`，行内加粗和内容区高亮都落在 `NSURL` 上。
- **基线**：本 PR 新引入（c3ad0839）。
- **影响**：审查统计 SwiftUI 约 5% 的类型（4329 个里有 223 个）含这种长行，成员命中则很常见。程度中低，建议修。
- **历史**：新代码。「完全找不到时只跳到对象」是决策日志 2026-09-29 定的，本条不改。

**改法**：
- **请求带上「怎么找」**：新增 `matchMode`；正则请求传真实的 pattern，不再传空串。成员请求的 `matchRangeInLine` 用名字在声明里的范围，也就是行内强调用的那个范围，修好后两处一致。
- **窗口行改成「包含」比较**：窗口以「…」识别，这是 `windowed` 文档里写明的约定：截断的每一边都打标记。找**包含**窗口正文的那一行，命中位置 = 正文在该行中的偏移 + 命中在窗口内的偏移。原测试里「两端带…的整行」也走这条路，结果不变。
- **第二步用与搜索相同的语义**：匹配方式、ASCII 大小写折叠、标识符边界、正则，统统一致。为此 Core 新增一个公开的 `RuntimeTextPattern`，内部直接复用 `RuntimeInterfaceTextMatcher.Pattern` 与 `hits(in:pattern:)`，App 不另写一份。这与模块 B1 有交集：若 B1 的条目已经公开了同类 API，以那份为准。
- **名字按标识符边界查找**：`nameRange` 找整个名字时改成前后都不能紧挨标识符字符（以冒号结尾的选择子片段只检查前一个字符），并移出 AppKit 守卫，让不依赖 AppKit 的 `FindViewModel.highlight` 也能调用。
- **不修**：「成员按 By Offset 排序后行号变了，内容完全相同的行取错」沿用决策日志 2026-09-29「`memberSortOrder` 不处理」，理由仍然成立。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeTextPattern.swift
@@ -0,0 +1,28 @@
+import Foundation
+
+/// A Find query compiled the way the engine's searches compile theirs — the same match
+/// styles, the same ASCII case folding, the same identifier boundaries, the same regular
+/// expressions — for the app to find a hit again in text it has on screen.
+public struct RuntimeTextPattern: Sendable {
+    private let pattern: RuntimeInterfaceTextMatcher.Pattern
+
+    /// Throws for an empty query and for a regular expression that does not compile.
+    public init(text: String, matchMode: RuntimeInterfaceSearchMatchMode, isCaseSensitive: Bool) throws {
+        self.pattern = try RuntimeInterfaceTextMatcher.Pattern(text: text, matchMode: matchMode, isCaseSensitive: isCaseSensitive)
+    }
+
+    /// Every match in `text`, in order, as UTF-16 ranges.
+    public func ranges(in text: String) -> [NSRange] {
+        RuntimeInterfaceTextMatcher.hits(in: text, pattern: pattern).map { hit in
+            let utf8 = text.utf8
+            let start = utf8.index(utf8.startIndex, offsetBy: hit.utf8Offset)
+            let end = utf8.index(start, offsetBy: hit.utf8Length)
+            return NSRange(start ..< end, in: text)
+        }
+    }
+}
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentHighlightRequest.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentHighlightRequest.swift
@@ -10,10 +10,13 @@ import RuntimeViewerCore
 /// options, so the line number alone is not enough. The pane locates the hit
 /// in its own text in this order (proposal `draft-find-navigator` §4):
 ///
-/// 1. a line equal to `lineText`, the one nearest `lineNumber` when several
-///    are, with `matchRangeInLine` applied inside it;
-/// 2. failing that, `query` searched the same way the navigator did, the
-///    hit nearest `lineNumber`;
+/// 1. a line equal to `lineText`, the one nearest `lineNumber` when several
+///    are, with `matchRangeInLine` applied inside it — or, when `lineText` is
+///    a window the engine cut out of a long line, a line containing it;
+/// 2. failing that, `query` matched the way the search matched it — its
+///    `matchMode`, ASCII case folding, identifier boundaries — the hit
+///    nearest `lineNumber`;
 /// 3. failing that, nothing — the pane stays at the top of the object.
 public struct ContentHighlightRequest: Hashable, Sendable {
     /// 1-based line in the corpus interface.
@@ -24,16 +27,21 @@ public struct ContentHighlightRequest: Hashable, Sendable {
     /// Where the hit sits inside `lineText`, when the request comes from a
     /// text search.
     public let matchRangeInLine: RuntimeTextRange?
     /// The text to fall back to when `lineText` is not on screen: the query
-    /// of a text search, the member name of a member search.
+    /// of a text search — the pattern itself for a regular expression — or
+    /// the member name of a member search.
     public let query: String
+    /// How `query` matches, as the search that found the hit matched it.
+    public let matchMode: RuntimeInterfaceSearchMatchMode
     public let isCaseSensitive: Bool
 
-    public init(lineNumber: Int, lineText: String, matchRangeInLine: RuntimeTextRange?, query: String, isCaseSensitive: Bool) {
+    public init(lineNumber: Int, lineText: String, matchRangeInLine: RuntimeTextRange?, query: String, matchMode: RuntimeInterfaceSearchMatchMode = .containing, isCaseSensitive: Bool) {
         self.lineNumber = lineNumber
         self.lineText = lineText
         self.matchRangeInLine = matchRangeInLine
         self.query = query
+        self.matchMode = matchMode
         self.isCaseSensitive = isCaseSensitive
     }
 
@@ -44,37 +52,49 @@ public struct ContentHighlightRequest: Hashable, Sendable {
     public func locate(in displayedText: String) -> NSRange? {
         let lines = Self.lines(of: displayedText)
         guard !lines.isEmpty else { return nil }
         let targetLineIndex = max(0, lineNumber - 1)
-        let normalizedLineText = Self.normalized(lineText)
+        let pattern = query.isEmpty ? nil : try? RuntimeTextPattern(text: query, matchMode: matchMode, isCaseSensitive: isCaseSensitive)
 
-        // 1. Whole-line match, nearest to the corpus line number.
-        if !normalizedLineText.isEmpty {
-            var bestLine: Line?
-            for line in lines where Self.normalized(line.text) == normalizedLineText {
-                if bestLine == nil || abs(line.index - targetLineIndex) < abs(bestLine!.index - targetLineIndex) {
-                    bestLine = line
-                }
-            }
-            if let bestLine {
-                return rangeInsideLine(bestLine, of: displayedText)
+        // 1. The corpus line, nearest to the corpus line number.
+        if let window = Self.window(of: lineText) {
+            // A long line reached the navigator as a window cut around the hit; the line on
+            // screen contains the window, and the hit sits at the same place inside it.
+            if let range = locateWindow(window, in: lines, nearLineIndex: targetLineIndex) {
+                return range
+            }
+        } else {
+            let normalizedLineText = Self.normalized(lineText)
+            if !normalizedLineText.isEmpty {
+                var bestLine: Line?
+                for line in lines where Self.normalized(line.text) == normalizedLineText {
+                    if bestLine == nil || abs(line.index - targetLineIndex) < abs(bestLine!.index - targetLineIndex) {
+                        bestLine = line
+                    }
+                }
+                if let bestLine {
+                    return rangeInsideLine(bestLine, of: displayedText, pattern: pattern)
+                }
             }
         }
 
-        // 2. The query itself, nearest to the corpus line number.
-        guard !query.isEmpty else { return nil }
-        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
+        // 2. The query, matched as the search matched it, nearest to the corpus line number.
+        guard let pattern else { return nil }
         var bestRange: NSRange?
         var bestDistance = Int.max
         for line in lines {
-            guard let found = line.text.range(of: query, options: options) else { continue }
+            guard let found = pattern.ranges(in: line.text).first else { continue }
             let distance = abs(line.index - targetLineIndex)
             guard distance < bestDistance else { continue }
             bestDistance = distance
-            let location = line.utf16Offset + line.text.utf16.distance(from: line.text.startIndex, to: found.lowerBound)
-            let length = line.text.utf16.distance(from: found.lowerBound, to: found.upperBound)
-            bestRange = NSRange(location: location, length: length)
+            bestRange = NSRange(location: line.utf16Offset + found.location, length: found.length)
         }
         return bestRange
     }
 
+    /// The hit inside the line on screen that contains `window`, the line nearest
+    /// `targetLineIndex` when several do; `nil` when no line contains it.
+    private func locateWindow(_ window: (text: String, leadingMarkerLength: Int), in lines: [Line], nearLineIndex targetLineIndex: Int) -> NSRange? {
+        guard !window.text.isEmpty, let matchRangeInLine else { return nil }
+        let locationInWindow = matchRangeInLine.location - window.leadingMarkerLength
+        guard locationInWindow >= 0, locationInWindow + matchRangeInLine.length <= window.text.utf16.count else { return nil }
+        var bestRange: NSRange?
+        var bestDistance = Int.max
+        for line in lines {
+            let windowRange = (line.text as NSString).range(of: window.text)
+            guard windowRange.location != NSNotFound else { continue }
+            let distance = abs(line.index - targetLineIndex)
+            guard distance < bestDistance else { continue }
+            bestDistance = distance
+            bestRange = NSRange(location: line.utf16Offset + windowRange.location + locationInWindow, length: matchRangeInLine.length)
+        }
+        return bestRange
+    }
+
+    /// The text of a window the engine cut out of a long line, without the ellipsis that marks
+    /// each cut edge, and the UTF-16 length of the leading mark; `nil` for a whole line.
+    /// `RuntimeInterfaceTextMatcher.windowed` marks every edge it cuts, so a line with no mark
+    /// at either end is whole.
+    private static func window(of lineText: String) -> (text: String, leadingMarkerLength: Int)? {
+        let marker = "…"
+        let hasLeadingMarker = lineText.hasPrefix(marker)
+        let hasTrailingMarker = lineText.hasSuffix(marker)
+        guard hasLeadingMarker || hasTrailingMarker else { return nil }
+        var text = Substring(lineText)
+        if hasLeadingMarker {
+            text = text.dropFirst()
+        }
+        if hasTrailingMarker, !text.isEmpty {
+            text = text.dropLast()
+        }
+        return (String(text), hasLeadingMarker ? marker.utf16.count : 0)
+    }
+
     private struct Line {
         let index: Int
         let text: String
@@ -106,7 +126,7 @@ public struct ContentHighlightRequest: Hashable, Sendable {
         return trimmed
     }
 
-    private func rangeInsideLine(_ line: Line, of displayedText: String) -> NSRange {
+    private func rangeInsideLine(_ line: Line, of displayedText: String, pattern: RuntimeTextPattern?) -> NSRange {
         let leadingWhitespaceCount = line.text.utf16.distance(
             from: line.text.startIndex,
             to: line.text.firstIndex { !$0.isWhitespace } ?? line.text.endIndex
@@ -125,11 +145,8 @@ public struct ContentHighlightRequest: Hashable, Sendable {
                 return NSRange(location: lineStart + location, length: matchRangeInLine.length)
             }
         }
-        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
-        if !query.isEmpty, let found = line.text.range(of: query, options: options) {
-            let location = line.text.utf16.distance(from: line.text.startIndex, to: found.lowerBound)
-            let length = line.text.utf16.distance(from: found.lowerBound, to: found.upperBound)
-            return NSRange(location: line.utf16Offset + location, length: length)
+        if let found = pattern?.ranges(in: line.text).first {
+            return NSRange(location: line.utf16Offset + found.location, length: found.length)
         }
         return NSRange(location: lineStart, length: lineContentLength)
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -222,8 +222,9 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
             return ContentHighlightRequest(
                 lineNumber: match.lineNumber,
                 lineText: match.lineText,
                 matchRangeInLine: match.matchRangeInLine,
-                query: query.mode == .regularExpression ? "" : query.trimmedText,
+                query: query.trimmedText,
+                matchMode: query.mode == .regularExpression ? .regularExpression : query.textMatchStyle.matchMode,
                 isCaseSensitive: query.isCaseSensitive
             )
         case .member(let match):
             guard let lineNumber = match.member.lineNumber else { return nil }
             return ContentHighlightRequest(
                 lineNumber: lineNumber,
                 lineText: match.member.declarationText,
-                matchRangeInLine: nil,
+                // The part of the name the row sets apart, so the pane flashes the same span.
+                matchRangeInLine: FindResultNode.nameRange(of: match).map { RuntimeTextRange(location: $0.location, length: $0.length) },
                 query: match.member.name,
+                matchMode: .matchingWord,
                 isCaseSensitive: true
             )
         case .object, .relationship:
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
@@ -163,22 +163,25 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         }
         return result
     }
+    #endif
 
-    /// Where the query matched the member's name, inside its declaration. A
-    /// name the declaration spells whole is found as is; a multi-part
-    /// selector is spelled piece by piece with its parameters in between, so
-    /// the piece the match starts in is found instead, keyword and colon.
-    private static func nameRange(of match: RuntimeMemberMatch) -> NSRange? {
+    /// Where the query matched the member's name, inside its declaration. A
+    /// name the declaration spells whole is found where it stands on its own —
+    /// `URL` in `NSURL *URL` is the last one, not the one inside `NSURL`; a
+    /// multi-part selector is spelled piece by piece with its parameters in
+    /// between, so the piece the match starts in is found instead, keyword and
+    /// colon. The row sets this range apart, and the content pane flashes it.
+    static func nameRange(of match: RuntimeMemberMatch) -> NSRange? {
         let declarationText = match.member.declarationText as NSString
         let name = match.member.name as NSString
         let matchRange = match.matchRangeInName.nsRange
-        let wholeNameRange = declarationText.range(of: name as String)
-        if wholeNameRange.location != NSNotFound {
+        if let wholeNameRange = identifierRange(of: name as String, in: declarationText) {
             return NSRange(location: wholeNameRange.location + matchRange.location, length: matchRange.length)
                 .clamped(toLengthOf: wholeNameRange)
         }
         guard let pieceRange = selectorPieceRange(in: name, containing: matchRange.location),
-              let pieceRangeInDeclaration = keywordRange(of: name.substring(with: pieceRange), in: declarationText)
+              let pieceRangeInDeclaration = identifierRange(of: name.substring(with: pieceRange), in: declarationText)
         else { return nil }
         return NSRange(location: pieceRangeInDeclaration.location + matchRange.location - pieceRange.location, length: matchRange.length)
             .clamped(toLengthOf: pieceRangeInDeclaration)
@@ -199,15 +202,21 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         return nil
     }
 
-    /// The first place `keyword` starts a word in `declarationText`, so a
-    /// keyword is never found at the end of a longer one.
-    private static func keywordRange(of keyword: String, in declarationText: NSString) -> NSRange? {
+    /// The first place `identifier` stands on its own in `declarationText`: not preceded by an
+    /// identifier character, and — unless it ends in a selector's colon — not followed by one.
+    /// So a name is never found inside a longer one, at either end.
+    private static func identifierRange(of identifier: String, in declarationText: NSString) -> NSRange? {
+        let identifierText = identifier as NSString
+        let checksTrailingBoundary = identifierText.length > 0 && isIdentifierCharacter(identifierText.character(at: identifierText.length - 1))
         var searchStart = 0
         while searchStart < declarationText.length {
-            let found = declarationText.range(of: keyword, range: NSRange(location: searchStart, length: declarationText.length - searchStart))
+            let found = declarationText.range(of: identifier, range: NSRange(location: searchStart, length: declarationText.length - searchStart))
             guard found.location != NSNotFound else { return nil }
-            if found.location == 0 || !isIdentifierCharacter(declarationText.character(at: found.location - 1)) {
+            let startsOnItsOwn = found.location == 0 || !isIdentifierCharacter(declarationText.character(at: found.location - 1))
+            let endsOnItsOwn = !checksTrailingBoundary || NSMaxRange(found) == declarationText.length || !isIdentifierCharacter(declarationText.character(at: NSMaxRange(found)))
+            if startsOnItsOwn, endsOnItsOwn {
                 return found
             }
             searchStart = found.location + 1
@@ -219,7 +228,6 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         guard let scalar = Unicode.Scalar(character) else { return true }
         return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
     }
-    #endif
 }
 
 #if canImport(AppKit) && !targetEnvironment(macCatalyst)
@@ -231,6 +239,7 @@ extension FindResultNode: Differentiable {
         content == source.content && children.count == source.children.count
     }
 }
+#endif
 
 extension NSRange {
     /// `self` cut down to lie inside `bounds`; an empty range at `bounds.location`
@@ -242,4 +251,3 @@ extension NSRange {
         return NSRange(location: lower, length: upper - lower)
     }
 }
-#endif
```

（`nameRange` 及其辅助函数、`NSRange.clamped` 只用到 Foundation，移出 AppKit 守卫后 iOS 构建同样能编译。）

**复现测试（示例）**：

`ContentHighlightRequestTests.swift` 新增三条。前两条按 Find 页**现在**构造请求的方式来写：正则模式传空 `query`，其它模式传字面 `query`。现状下，第一条返回 `nil`，第二条落在 `_BackgroundViewHoverEffect` 里的 `View` 上，所以都会红。第三条是新契约。
```swift
/// A line longer than the navigator keeps whole: `SwiftUI.View` sits past column 320, after
/// an earlier `View` inside another type's name.
private static let longLine = "public func makeBody(effect: _BackgroundViewHoverEffect, "
    + String(repeating: "parameter: Swift.Int, ", count: 14)
    + "content: SwiftUI.View) -> some SwiftUI.View"
private static let longLinePrefix = "struct Sample {\n    "
private static let longLineText = longLinePrefix + longLine + "\n}"
/// The hit: `View` in `content: SwiftUI.View`.
private static let longLineHitRange = NSRange(location: (longLine as NSString).range(of: "content: SwiftUI.View").location + "content: SwiftUI.".utf16.count, length: 4)

/// The window `RuntimeInterfaceTextMatcher.windowed` cuts around a hit in a line longer than
/// 320 UTF-16 units: from 100 units ahead of the hit, 320 in all, each cut edge marked `…`.
private static func window(of line: String, around hitRange: NSRange) -> (text: String, rangeInWindow: RuntimeTextRange) {
    let utf16 = Array(line.utf16)
    let windowStart = max(0, min(hitRange.location - 100, utf16.count - 320))
    let windowEnd = min(utf16.count, windowStart + 320)
    var text = String(decoding: utf16[windowStart ..< windowEnd], as: UTF16.self)
    var location = hitRange.location - windowStart
    if windowStart > 0 {
        text = "…" + text
        location += 1
    }
    if windowEnd < utf16.count {
        text += "…"
    }
    return (text, RuntimeTextRange(location: location, length: hitRange.length))
}

@Test("a regular-expression hit on a long line is found inside the window the navigator kept")
func regularExpressionHitOnALongLine() {
    let window = Self.window(of: Self.longLine, around: Self.longLineHitRange)
    // How the Find page builds a regular-expression request today: no query to fall back to.
    let request = ContentHighlightRequest(lineNumber: 2, lineText: window.text, matchRangeInLine: window.rangeInWindow, query: "", isCaseSensitive: true)
    let expected = NSRange(location: Self.longLinePrefix.utf16.count + Self.longLineHitRange.location, length: 4)
    #expect(request.locate(in: Self.longLineText) == expected)
}

@Test("a literal hit on a long line is not taken by an earlier occurrence of the same text")
func literalHitOnALongLine() {
    let window = Self.window(of: Self.longLine, around: Self.longLineHitRange)
    let request = ContentHighlightRequest(lineNumber: 2, lineText: window.text, matchRangeInLine: window.rangeInWindow, query: "View", isCaseSensitive: true)
    let expected = NSRange(location: Self.longLinePrefix.utf16.count + Self.longLineHitRange.location, length: 4)
    #expect(request.locate(in: Self.longLineText) == expected)
}

@Test("the fallback matches as the search did: a whole word is not found inside a longer one")
func fallbackHonoursTheMatchStyle() {
    let text = "@interface Sample : NSObject\n@property (readonly) NSView *view;\n- (void)View;\n@end"
    let request = ContentHighlightRequest(lineNumber: 2, lineText: "a line the pane no longer shows", matchRangeInLine: nil, query: "View", matchMode: .matchingWord, isCaseSensitive: true)
    #expect(request.locate(in: text) == utf16Range(of: "View", in: text, occurrence: 1))
}
```

`FindResultMemberEmphasisTests.swift` 新增一条（现状下加粗的是 `NSURL` 里的 `URL`，会红）：
```swift
private static func emphasizedRanges(ofMember name: String, declaredAs declarationText: String, matchRangeInName: RuntimeTextRange) -> [NSRange] {
    let member = RuntimeMemberDeclaration(name: name, kind: .objcProperty, isStatic: false, declarationText: declarationText, lineNumber: 1)
    let match = RuntimeMemberMatch(object: object, member: member, matchRangeInName: matchRangeInName)
    let title = FindResultNode.member(match, index: 0).appearance.title
    var emphasizedRanges: [NSRange] = []
    title.enumerateAttribute(.font, in: NSRange(location: 0, length: title.length)) { font, range, _ in
        if (font as? NSFont) == FindResultCellStyle.emphasisFont {
            emphasizedRanges.append(range)
        }
    }
    return emphasizedRanges
}

@Test("a name that also occurs inside a type name is set apart where it stands on its own")
func nameThatAlsoOccursInsideATypeName() {
    let declarationText = "@property (readonly, copy) NSURL *URL;"
    let emphasizedRanges = Self.emphasizedRanges(ofMember: "URL", declaredAs: declarationText, matchRangeInName: RuntimeTextRange(location: 0, length: 3))
    #expect(emphasizedRanges == [NSRange(location: (declarationText as NSString).range(of: "*URL").location + 1, length: 3)])
}
```

`FindViewModelTests.swift` 新增一条，端到端验证成员请求（现状下请求不带范围，定位退回第一处子串，会红）：
```swift
@Test("a member hit's highlight lands on the member's name, not inside a type name before it")
func memberHighlightLandsOnTheName() async throws {
    let environment = try await Self.makeEnvironmentWithCorpus()
    let (viewModel, output) = makeViewModel(in: environment)
    defer { withExtendedLifetime(viewModel) {} }

    modePathChoiceSelectedRelay.accept(.mode(.members))
    memberKindFilterSelectedRelay.accept(.kind(.objcProperty))
    caseSensitiveToggledRelay.accept(true)
    searchCommittedRelay.accept("URL")
    let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
    let member = try #require(nodes.flatMap(\.children).first { node in
        guard case .member(let match) = node.content else { return false }
        return match.member.name == "URL" && match.member.lineNumber != nil && match.member.declarationText.contains("NSURL *URL")
    })
    guard case .member(let match) = member.content else { return }

    var routes: [SelectionRoute] = []
    let routeSubscription = environment.documentState.routeSignal.emitOnNext { routes.append($0) }
    defer { routeSubscription.dispose() }
    resultClickedRelay.accept(member)
    try await settleMainQueue()

    guard case .pushHighlighting(_, let highlight)? = routes.last else {
        Issue.record("expected a highlighting push, got \(routes)")
        return
    }
    let declarationText = match.member.declarationText as NSString
    #expect(highlight.locate(in: match.member.declarationText) == NSRange(location: declarationText.range(of: "*URL").location + 1, length: 3))
}
```

**同类**：
- `ContentHighlightRequest.swift:69` 和 `:129` 两处 `range(of:options:)`，上面已一并改掉。
- `FindResultNode.swift:175` 的名字查找，上面已一并改掉。
- 过滤栏（`FindViewModel.filtered`、表单过滤、Report 过滤）用的也是 Unicode 不区分大小写的「包含」，但那是 UI 过滤，与 Xcode 的过滤栏一致，不属同类。

**工作量**：M。`RuntimeTextPattern` 与模块 B1 协调。PR121.15（正则加 `.anchorsMatchLines`）合入后，这里的回退匹配自动随之改变，两者无冲突。


### PR121.48 每批重建整棵结果树

- **严重度**：Minor
- **审查编号**：F1
- **状态**：方案待批，代码未改

**问题**：文本 / 成员搜索的结果是一批一批（每个镜像一批）送到 `FindSession` 的。每来一批，`TextMatchGroups.nodes()` 和 `MemberMatchGroups.nodes()`（`FindSession.swift:491`、`:523`）都会把**所有**类型、**所有**命中重新 `init` 一遍。`FindResultNode` 在 `init` 里就构建带属性的标题，所以命中越多、批次越多，重复的工作就越多。两层侧栏各有一个 `FindViewModel` 绑着同一个 session，所以每一批都要处理两份；看不见的那一层也逃不掉。

**四问**：复现——对 Foundation 加 AppKit 搜一个常见词（比如 `init`），上限 1000 条命中、几十个镜像批次；每一批都为前面所有批次的命中重建节点和属性串，两份大纲各做一遍；基线——本 PR 新引入；影响——属性能问题，结果越多越慢，而且全在主线程上；它还让 PR121.07 的增量 diff 每次都要逐个比较内容；建议修，改动很小；历史——新代码。

**改法**：
- 分组结构按 `RuntimeObjectKey` 缓存每个类型的行：`append` 只让收到新命中的类型失效，`nodes()` 只补建失效的那几个。由于一个镜像一批，一个类型的命中只会在一批里出现，所以实际只为新类型建行。没变的类型交出的还是同一个实例，PR121.07 的 diff 在 `===` 处就能判定它没变，PR121.43 的递归比较也落不到这些行上。
- `nodes()` 变成 `mutating`。`FindSession` 里三个调用点都是对 `var` 存储属性调用，参数按顺序求值，不存在访问冲突。
- 两个分组结构从 `private` 放宽到 `internal`，好让测试直接驱动它们。模块 D1 的 PR121.41 要把这两份重复代码合成一份，合并时把缓存一起带过去。
- 关系模式的自动展开范围（整棵大树全部展开的代价）是另一回事，归 PR121.07 的展开策略管，作为待拍板项单列。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -464,8 +464,14 @@ public final class FindSession {
 
     /// Hits grouped by the type they are in, in the order types first
     /// appeared; batches arrive per image, so a type's hits are contiguous.
-    private struct TextMatchGroups {
+    struct TextMatchGroups {
         private var matchesByObject: [RuntimeObjectKey: [RuntimeInterfaceSearchMatch]] = [:]
         private var order: [RuntimeObject] = []
+        /// Each type's row, built once and kept until the type receives more hits: a batch
+        /// builds rows for its own types only, and every other row stays the instance the
+        /// outline already has, which its diff takes as unchanged without comparing it.
+        private var nodesByObject: [RuntimeObjectKey: FindResultNode] = [:]
         private(set) var matchCount = 0
         /// Hits collected by the search under way, for its interim count.
         private(set) var matchCountSinceLastFinish = 0
@@ -479,6 +485,7 @@ public final class FindSession {
                     order.append(match.object)
                 }
                 matchesByObject[match.object.key, default: []].append(match)
+                nodesByObject[match.object.key] = nil
                 matchCount += 1
                 matchCountSinceLastFinish += 1
             }
@@ -488,19 +495,29 @@ public final class FindSession {
             matchCountSinceLastFinish = 0
         }
 
-        func nodes() -> [FindResultNode] {
-            order.map { object in
-                let matches = matchesByObject[object.key] ?? []
-                let children = matches.enumerated().map { index, match in FindResultNode.textMatch(match, index: index) }
-                return FindResultNode.object(object, matchCount: matches.count, children: children)
+        mutating func nodes() -> [FindResultNode] {
+            var nodes: [FindResultNode] = []
+            nodes.reserveCapacity(order.count)
+            for object in order {
+                if let node = nodesByObject[object.key] {
+                    nodes.append(node)
+                    continue
+                }
+                let matches = matchesByObject[object.key] ?? []
+                let children = matches.enumerated().map { index, match in FindResultNode.textMatch(match, index: index) }
+                let node = FindResultNode.object(object, matchCount: matches.count, children: children)
+                nodesByObject[object.key] = node
+                nodes.append(node)
             }
+            return nodes
         }
     }
 
-    private struct MemberMatchGroups {
+    struct MemberMatchGroups {
         private var matchesByObject: [RuntimeObjectKey: [RuntimeMemberMatch]] = [:]
         private var order: [RuntimeObject] = []
+        /// As `TextMatchGroups.nodesByObject`.
+        private var nodesByObject: [RuntimeObjectKey: FindResultNode] = [:]
         private(set) var matchCount = 0
         private(set) var matchCountSinceLastFinish = 0
 
@@ -511,6 +528,7 @@ public final class FindSession {
                     order.append(match.object)
                 }
                 matchesByObject[match.object.key, default: []].append(match)
+                nodesByObject[match.object.key] = nil
                 matchCount += 1
                 matchCountSinceLastFinish += 1
             }
@@ -520,11 +538,21 @@ public final class FindSession {
             matchCountSinceLastFinish = 0
         }
 
-        func nodes() -> [FindResultNode] {
-            order.map { object in
-                let matches = matchesByObject[object.key] ?? []
-                let children = matches.enumerated().map { index, match in FindResultNode.member(match, index: index) }
-                return FindResultNode.object(object, matchCount: matches.count, children: children)
+        mutating func nodes() -> [FindResultNode] {
+            var nodes: [FindResultNode] = []
+            nodes.reserveCapacity(order.count)
+            for object in order {
+                if let node = nodesByObject[object.key] {
+                    nodes.append(node)
+                    continue
+                }
+                let matches = matchesByObject[object.key] ?? []
+                let children = matches.enumerated().map { index, match in FindResultNode.member(match, index: index) }
+                let node = FindResultNode.object(object, matchCount: matches.count, children: children)
+                nodesByObject[object.key] = node
+                nodes.append(node)
             }
+            return nodes
         }
     }
 }
```

**复现测试（示例）**：新建 `FindSessionGroupingTests.swift`，用 PR121.07 加的 `FindResultFixtures`。第一条在现状下会红：每次调用 `nodes()` 都会新建实例。
```swift
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("FindSession result grouping")
@MainActor
struct FindSessionGroupingTests {
    @Test("a later batch leaves the rows of earlier types the same instances")
    func laterBatchKeepsEarlierRows() throws {
        var groups = FindSession.TextMatchGroups()
        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 1), FindResultFixtures.hit(in: "Alpha", lineNumber: 2)])
        let alphaAfterFirstBatch = try #require(groups.nodes().first)

        groups.append([FindResultFixtures.hit(in: "Beta", lineNumber: 1)])
        let nodesAfterSecondBatch = groups.nodes()

        #expect(nodesAfterSecondBatch.count == 2)
        #expect(nodesAfterSecondBatch[0] === alphaAfterFirstBatch)
        #expect(nodesAfterSecondBatch[0].children.count == 2)
    }

    @Test("a type that receives more hits gets a new row that holds all of them")
    func moreHitsRebuildTheirType() throws {
        var groups = FindSession.TextMatchGroups()
        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 1)])
        let alphaBefore = try #require(groups.nodes().first)

        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 9)])
        let alphaAfter = try #require(groups.nodes().first)

        #expect(alphaAfter !== alphaBefore)
        #expect(alphaAfter.children.count == 2)
    }
}
```

**同类**：`MemberMatchGroups` 上面已一并改。关系模式一次只给一整棵树，没有批次，不涉及缓存。
**工作量**：S。代码在 `FindSession.swift`（模块 D1 的文件），与 PR121.41 的合并协调。


### PR121.49 过滤栏每敲一个键就重建所有匹配节点

- **严重度**：Minor
- **审查编号**：F4
- **状态**：方案待批，代码未改

**问题**：底部过滤栏每敲一个键，`FindViewModel.filtered(_:by:)`（`FindViewModel.swift:253`）都会把保留下来的行全部新建一遍：
- 子节点全部保留的类型也会新建；
- 更费的是，**每条匹配上的命中叶子也会新建**——叶子没有子节点，进不了第一个「原样返回」的分支，只能走到末尾的 `FindResultNode(content:children:identifier:)`，而这个初始化器会重新构建标题的属性串。

文本模式最多有 1000 条命中，等于每敲一个键就重建上千个属性串，然后整表 reload，再全部展开（全部展开的部分见 PR121.07）。

**四问**：复现——在有几百条命中的结果上往过滤栏里逐字输入；每个键都重建所有匹配行，主线程上的耗时随命中数线性增长；基线——本 PR 新引入；影响——属性能问题，结果多时打字会卡，建议修，改动很小；历史——新代码。

**改法**：
- 匹配上的叶子，以及子节点全部原样保留的类型，直接返回原节点：内容没变，实例也不变，PR121.07 的 diff 在 `===` 处就判定它没变。
- 只保留了部分子节点的类型，用新增的 `init(copying:children:)` 建副本，复用原节点的 `appearance`（它只取决于 `content`），不重建属性串。
- `FindResultNode` 的初始化器要稍微重排：类的指定初始化器之间不能互相委托，所以「带 appearance 的那一个」做成 `private` 的指定初始化器，原有的公开初始化器和新增的复制初始化器都改成 `convenience`。类是 `final`，调用方不受影响。
- 展开状态由 PR121.07 的身份判等保持，不再每次全部展开。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
@@ -75,11 +75,23 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         }
     }
 
-    public init(content: Content, children: [FindResultNode] = [], identifier: String) {
+    public convenience init(content: Content, children: [FindResultNode] = [], identifier: String) {
+        self.init(content: content, children: children, identifier: identifier, appearance: Self.makeAppearance(for: content))
+    }
+
+    /// `node` with other children — what the filter bar keeps of a type — sharing its
+    /// appearance, which depends on the content alone, instead of building it again.
+    public convenience init(copying node: FindResultNode, children: [FindResultNode]) {
+        self.init(content: node.content, children: children, identifier: node.identifier, appearance: node.appearance)
+    }
+
+    private init(content: Content, children: [FindResultNode], identifier: String, appearance: FindResultCellAppearance) {
         self.content = content
         self.children = children
         self.identifier = identifier
-        self.appearance = Self.makeAppearance(for: content)
+        self.appearance = appearance
         super.init()
     }
 
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -250,13 +250,24 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         return nodes.compactMap { filtered($0, by: needle) }
     }
 
+    /// Rows the filter does not change are returned as they are — the same instances, which
+    /// the outline's diff takes as unchanged — and a type it keeps in part is copied with the
+    /// appearance it already has. A keystroke builds nothing it does not have to.
     private static func filtered(_ node: FindResultNode, by needle: String) -> FindResultNode? {
         let matchesItself = node.filterableText.range(of: needle, options: [.caseInsensitive]) != nil
+        if matchesItself, node.children.isEmpty {
+            return node
+        }
         let children = node.children.compactMap { filtered($0, by: needle) }
         if matchesItself, children.isEmpty, !node.children.isEmpty {
             return node
         }
         guard matchesItself || !children.isEmpty else { return nil }
-        return FindResultNode(content: node.content, children: children, identifier: node.identifier)
+        if children.count == node.children.count, zip(children, node.children).allSatisfy({ $0 === $1 }) {
+            return node
+        }
+        return FindResultNode(copying: node, children: children)
     }
 }
```

**复现测试（示例）**：加在 `FindResultNodeTests.swift`（PR121.07 新建）里。两条在现状下都会红：现状下保留的行全是新实例，标题属性串也是重新构建的。
```swift
@Test("the filter returns the rows it does not change: matching hits, and a type it keeps whole")
func filterKeepsUnchangedRows() throws {
    let alpha = FindResultFixtures.type("Alpha", hitCount: 2)   // both hits read "- (void)sample;"
    let filtered = FindViewModel<SidebarRootRoute>.filtered([alpha], by: "sample")
    let kept = try #require(filtered.first)
    #expect(kept === alpha)
    #expect(kept.children.first === alpha.children.first)
}

@Test("a type the filter keeps in part shares its row's appearance and keeps its matching hits")
func partialFilterSharesTheAppearance() throws {
    let object = FindResultFixtures.object(named: "Alpha")
    let type = FindResultNode.object(object, matchCount: 2, children: [
        FindResultNode.textMatch(FindResultFixtures.hit(in: "Alpha", lineNumber: 1, lineText: "- (void)first;"), index: 0),
        FindResultNode.textMatch(FindResultFixtures.hit(in: "Alpha", lineNumber: 2, lineText: "- (void)second;"), index: 1),
    ])
    let filtered = FindViewModel<SidebarRootRoute>.filtered([type], by: "second")
    let copy = try #require(filtered.first)
    #expect(copy !== type)
    #expect(copy.children.count == 1)
    #expect(copy.children.first === type.children.last)
    #expect(copy.appearance.title === type.appearance.title)
}
```

**同类**：Report navigator 的过滤（`ReportViewModel.swift:359` 附近）也在每次过滤时重建节点，这一处属于 PR121.59 那一条的整树重建问题，归模块 E 处理。
**工作量**：S。与 PR121.07 改同一个 `filtered` 函数和同一个文件，合并时取两者之和。


### PR121.50 navigationTarget.highlight 恒为 nil；matchCount 冗余

- **严重度**：Cleanup
- **审查编号**：S6
- **状态**：方案待批，代码未改

**问题**：
- `FindResultNode.navigationTarget`（`FindResultNode.swift:55`）返回 `(object, highlight)`，但每个分支的 `highlight` 都写死成 `nil`。真正的高亮由 `FindViewModel.highlight(for:query:)` 另外计算，所以元组的第二位只是个永远为空的占位。
- `Content.object(RuntimeObject, matchCount: Int)` 里的 `matchCount` 只参与判等，界面上从没显示过。在过滤栏造出的副本里，它还和子节点数对不上：副本沿用原来的 `matchCount`，子节点却已经少了。

**四问**：复现——读代码即可确认：`navigationTarget` 的四个分支都返回 `nil` 高亮，全仓库没有任何地方读 `matchCount`（搜过 `matchCount:` 与 `.object(`）；基线——本 PR 新引入；影响——不改变行为，属误导读者的死字段，建议清理；历史——新代码。

**改法**：
- `navigationTarget` 改为只返回 `RuntimeObject?`，`navigate` 与 `imagePaths(in:)` 跟着改。
- `Content.object` 去掉 `matchCount`，`object(_:matchCount:children:)` 工厂随之去掉这个参数。
- 另一种做法是把高亮**填上**：在构建节点时，用产生这条结果的那次查询生成高亮请求。这牵涉 `FindSession` 要把查询带进分组，与模块 D1 的 PR121.39（高亮用了未提交的查询）是同一处改动。如果 PR121.39 选这条路，就在那一条里把高亮作为节点的存储属性加回来，而不是恢复这个恒为空的元组位。
- 与其它条目的交叠：PR121.44 新增的 `canOpenInNewTab`（`navigationTarget != nil`）不受影响；PR121.07、PR121.43、PR121.48、PR121.49 测试夹具里的 `matchCount:` 实参要随这一条一起删掉。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindResultNode.swift
@@ -33,8 +33,8 @@ public struct FindResultCellAppearance: Equatable {
 public final class FindResultNode: NSObject, @unchecked Sendable {
     public enum Content: Hashable {
-        /// A type grouping the hits or members found in it.
-        case object(RuntimeObject, matchCount: Int)
+        /// A type grouping the hits or members found in it, which are its children.
+        case object(RuntimeObject)
         case textMatch(RuntimeInterfaceSearchMatch)
         case member(RuntimeMemberMatch)
         /// A node of a relationship tree. `object` is `nil` for a type no
@@ -50,26 +50,26 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
 
     public let appearance: FindResultCellAppearance
 
-    /// The type a click navigates to, and where in it, or `nil` for an
-    /// unresolved relationship node.
-    public var navigationTarget: (object: RuntimeObject, highlight: ContentHighlightRequest?)? {
+    /// The type a click navigates to, or `nil` for an unresolved relationship
+    /// node. Where in the type a hit sits is `FindViewModel`'s to work out.
+    public var navigationTarget: RuntimeObject? {
         switch content {
-        case .object(let object, _):
-            return (object, nil)
+        case .object(let object):
+            return object
         case .textMatch(let match):
-            return (match.object, nil)
+            return match.object
         case .member(let match):
-            return (match.object, nil)
+            return match.object
         case .relationship(_, let object):
-            return object.map { ($0, nil) }
+            return object
         }
     }
 
     /// The text the bottom filter bar matches against.
     public var filterableText: String {
         switch content {
-        case .object(let object, _): object.displayName
+        case .object(let object): object.displayName
         case .textMatch(let match): match.lineText
         case .member(let match): match.member.declarationText
         case .relationship(let name, _): name
@@ -85,8 +85,8 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
 
     // MARK: - Construction
 
-    public static func object(_ object: RuntimeObject, matchCount: Int, children: [FindResultNode]) -> FindResultNode {
-        FindResultNode(content: .object(object, matchCount: matchCount), children: children, identifier: "object|\(object.kind)|\(object.name)|\(object.imagePath)")
+    public static func object(_ object: RuntimeObject, children: [FindResultNode]) -> FindResultNode {
+        FindResultNode(content: .object(object), children: children, identifier: "object|\(object.kind)|\(object.name)|\(object.imagePath)")
     }
 
     public static func textMatch(_ match: RuntimeInterfaceSearchMatch, index: Int) -> FindResultNode {
@@ -112,7 +112,7 @@ public final class FindResultNode: NSObject, @unchecked Sendable {
         var appearance = FindResultCellAppearance()
         #if canImport(AppKit) && !targetEnvironment(macCatalyst)
         switch content {
-        case .object(let object, _):
+        case .object(let object):
             appearance.icon = RuntimeObjectIcon.icon(for: object.kind, size: FindResultCellStyle.iconSize)
             appearance.title = titleWithSubtitle(object.displayName, subtitle: object.imageName)
         case .textMatch(let match):
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -322,7 +322,7 @@ public final class FindSession {
                     FindResultNode.relationship(node, path: "tree|\(tree.root.kind)|\(tree.root.name)|\(tree.root.imagePath)#\(index)")
                 }
                 relatedTypeCount += Self.count(children)
-                nodes.append(FindResultNode.object(tree.root, matchCount: children.count, children: children))
+                nodes.append(FindResultNode.object(tree.root, children: children))
             }
             var relationshipResults = Results()
             relationshipResults.nodes = nodes
@@ -492,7 +492,7 @@ public final class FindSession {
             order.map { object in
                 let matches = matchesByObject[object.key] ?? []
                 let children = matches.enumerated().map { index, match in FindResultNode.textMatch(match, index: index) }
-                return FindResultNode.object(object, matchCount: matches.count, children: children)
+                return FindResultNode.object(object, children: children)
             }
         }
     }
@@ -524,7 +524,7 @@ public final class FindSession {
             order.map { object in
                 let matches = matchesByObject[object.key] ?? []
                 let children = matches.enumerated().map { index, match in FindResultNode.member(match, index: index) }
-                return FindResultNode.object(object, matchCount: matches.count, children: children)
+                return FindResultNode.object(object, children: children)
             }
         }
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -170,7 +170,7 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         var imagePaths: Set<String> = []
         func collect(_ nodes: [FindResultNode]) {
             for node in nodes {
-                if let imagePath = node.navigationTarget?.object.imagePath {
+                if let imagePath = node.navigationTarget?.imagePath {
                     imagePaths.insert(imagePath)
                 }
                 collect(node.children)
@@ -200,7 +200,7 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
     // MARK: - Navigation
 
     private func navigate(to node: FindResultNode, inNewTab: Bool) {
-        guard let (object, _) = node.navigationTarget else { return }
+        guard let object = node.navigationTarget else { return }
         let highlight = Self.highlight(for: node, query: session.query)
         switch (inNewTab, highlight) {
         case (false, nil):
```

测试里的模式匹配跟着改，一共 8 处：`FindSessionCorpusTests.swift:125`，以及 `FindViewModelTests.swift` 的 `:160`、`:165`、`:219`、`:294`、`:321`、`:587`、`:604`。下面以一处为例：
```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindViewModelTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/FindViewModelTests.swift
@@ -216,7 +216,7 @@ struct FindViewModelTests {
         searchCommittedRelay.accept("NSMutableString")
         let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
         let typeNode = try #require(nodes.first)
-        guard case .object(let object, _) = typeNode.content else {
+        guard case .object(let object) = typeNode.content else {
             Issue.record("expected a type row")
             return
         }
```

**复现测试（示例）**：纯清理，行为不变，由现有的 `FindViewModelTests`（点击类型行、点击命中、关系搜索、范围菜单里的 Current Find Results）覆盖。
**同类**：无。
**工作量**：S；PR121.48 也改到 `FindSession` 里同样的三行，合并时取两者之和。


### PR121.51 self?. / if let self 代替 guard let self

- **严重度**：Cleanup
- **审查编号**：CV5
- **状态**：方案待批，代码未改

**问题**：本 PR 新增的 16 处闭包没按项目约定写：AGENTS.md「Closures & Self Capture」要求一律 `guard let self else { return }`，这些地方却用了 `self?.` 或 `if let self`。

**四问**：复现——逐处读代码可见，16 处都是本 PR 的 diff 新增的（`git diff 9ca0d5a6..12e1227b` 里以 `+` 开头的行）；基线——本 PR 新引入；影响——只是风格问题，行为不变，建议顺手统一；历史——无。

**改法**：
- 同步的 Rx 闭包，一律在开头 `guard let self else { return }`。
- 异步闭包只在 `await` **之后**才 `guard`。在 `await` 之前，或在长循环外层绑定强引用，会让对象在整个等待期间被钉住释放不掉。
- `FindCorpusCoordinator.swift:382` 的 `if let self` **保留**：它后面紧跟一个 `for await` 长循环，改成 `guard let self` 会让协调器的生命期跟事件流一样长。循环体里已有逐次的 `guard let self`，作用域是对的。
- `FindSession.swift:265`、`:295`、`:310` 三处不在这里改，留给模块 D1 的 PR121.02（unowned 崩溃）一起处理。那三处的生命期恰恰是 PR121.02 要解决的问题：`try await self?.perform(...)` 在整个 await 期间都强引用着会话。
- 其余 12 处的 diff 如下。其中 `ReportViewController` 归模块 E，`FindCorpusCoordinator` 归模块 C，三方改同一文件时注意合并。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindViewModel.swift
@@ -90,17 +90,20 @@ public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route>
         .disposed(by: rx.disposeBag)
 
         input.filterString.driveOnNext { [weak self] filterString in
-            self?.filterString = filterString
+            guard let self else { return }
+            self.filterString = filterString
         }
         .disposed(by: rx.disposeBag)
 
         input.resultClicked.emitOnNext { [weak self] node in
-            self?.navigate(to: node, inNewTab: false)
+            guard let self else { return }
+            navigate(to: node, inNewTab: false)
         }
         .disposed(by: rx.disposeBag)
 
         input.resultOpenedInNewTab.emitOnNext { [weak self] node in
-            self?.navigate(to: node, inNewTab: true)
+            guard let self else { return }
+            navigate(to: node, inNewTab: true)
         }
         .disposed(by: rx.disposeBag)
 
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
@@ -391,7 +391,8 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
         .disposed(by: rx.disposeBag)
 
         output.summary.driveOnNext { [weak self] summary in
-            self?.setSummary(summary)
+            guard let self else { return }
+            setSummary(summary)
         }
         .disposed(by: rx.disposeBag)
 
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentSourceEditorViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentSourceEditorViewController.swift
@@ -136,7 +136,8 @@ final class ContentSourceEditorViewController: …
         .disposed(by: rx.disposeBag)
 
         output.highlightRange.emitOnNextMainActor { [weak self] range in
-            self?.bridge?.revealCharacterRange(range)
+            guard let self else { return }
+            bridge?.revealCharacterRange(range)
         }
         .disposed(by: rx.disposeBag)
 
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindScopeChooserViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindScopeChooserViewModel.swift
@@ -161,7 +161,9 @@ public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: View
         let engine = documentState.runtimeEngine
         Task { [weak self] in
             guard let imagePaths = try? await engine.indexedImagePathList() else { return }
-            self?.indexedImagePaths = imagePaths
+            // After the await: the ViewModel is not kept alive while the engine answers.
+            guard let self else { return }
+            indexedImagePaths = imagePaths
         }
     }
 
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
@@ -221,12 +221,14 @@ final class ReportViewController<Route: …>: …
         .disposed(by: rx.disposeBag)
 
         output.hasWorkInProgress.driveOnNext { [weak self] hasWorkInProgress in
-            self?.hasWorkInProgress = hasWorkInProgress
+            guard let self else { return }
+            self.hasWorkInProgress = hasWorkInProgress
         }
         .disposed(by: rx.disposeBag)
 
         output.hasHistory.driveOnNext { [weak self] hasHistory in
-            self?.hasHistory = hasHistory
+            guard let self else { return }
+            self.hasHistory = hasHistory
         }
         .disposed(by: rx.disposeBag)
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -193,13 +193,16 @@ public final class FindCorpusCoordinator {
             let result: Result<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>
             do {
                 let summary = try await engine.buildInterfaceCorpus(for: imagePath, transformer: transformer, isPrioritized: isPrioritized) { [weak self] progress in
-                    self?.stageProgress(progress, for: imagePath, requestIdentifier: identifier)
+                    guard let self else { return }
+                    stageProgress(progress, for: imagePath, requestIdentifier: identifier)
                 }
                 result = .success(summary)
             } catch {
                 result = .failure(error)
             }
-            self?.finishBuildRequest(identifier, of: imagePath, with: result)
+            // After the await: the coordinator is not kept alive while the corpus builds.
+            guard let self else { return }
+            finishBuildRequest(identifier, of: imagePath, with: result)
         }
         buildRequests[imagePath] = BuildRequest(identifier: identifier, task: task)
     }
@@ -278,7 +281,8 @@ public final class FindCorpusCoordinator {
         guard progressStaging.record(progress, for: imagePath, requestIdentifier: requestIdentifier) else { return }
         Task { @MainActor [weak self] in
             try? await Task.sleep(nanoseconds: Self.progressCoalescingWindowNanoseconds)
-            self?.flushProgress()
+            guard let self else { return }
+            flushProgress()
         }
     }
 
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/PopUpPathControlTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/PopUpPathControlTests.swift
@@ -325,7 +325,8 @@ extension PopUpPathControlTests {
             pathControl.controlSize = .small
             contentView.addSubview(pathControl)
             pathControl.menuPresenter = { [weak self] menu, positioningItem, location, _ in
-                self?.presentedMenus.append((menu, positioningItem, location))
+                guard let self else { return }
+                presentedMenus.append((menu, positioningItem, location))
             }
             pathControl.target = actionRecorder
             pathControl.action = #selector(ActionRecorder.recordAction(_:))
```

（赋值给与闭包参数同名的属性时，写成 `self.hasWorkInProgress = hasWorkInProgress` 这种显式的 `self.`，否则左边会被当成参数。）

**复现测试（示例）**：纯风格，行为不变，由现有测试覆盖：`FindViewModelTests`、`FindScopeChooserViewModelTests`、`FindCorpusCoordinatorTests`、`PopUpPathControlTests`。`ReportViewController` 和 `ContentSourceEditorViewController` 在 App target 里，没有单元测试，用 App 的编译验证即可（命令见 PR121.52）。

**同类**：
- 本 PR 之前就存在的同类写法，不在这一条里改：`ContentTextViewController.swift:93-94`、`SidebarRuntimeObjectCoordinator.swift:81`、`RuntimeEngine.swift:401`。
- 其中 `RuntimeEngine.swift:401` 本 PR 碰过附近的代码，但那一行不是本 PR 加的。

**工作量**：S；`FindCorpusCoordinator` 部分随模块 C 的改动一起提交，`ReportViewController` 部分随模块 E 的改动一起提交，免得同一文件三方冲突。


### PR121.52 Find 页直接用原生 AppKit 控件

- **严重度**：Cleanup
- **审查编号**：CV6
- **状态**：方案待批，代码未改

**问题**：AGENTS.md 的「UI Component Selection」要求先用项目的封装类型，只有封装做不到时才回退到原生 AppKit 类。`FindViewController.swift` 里有五处可以用封装却用了原生类：`:31` 的 `NSSearchField`、`:37` 的 `NSPopUpButton`，以及 `:45`、`:53`、`:57` 的三个 `NSBox`。UIFoundation 有对应的 `SearchField`、`PopUpButton`、`Box`；同一个 PR 里的 Scope chooser 已经在用 `SearchField`。

**四问**：复现——直接看代码即可；基线——本 PR 新引入；影响——风格不一致，行为不变，建议顺手统一；历史——无。

**改法**：
- 上面五处换成对应的封装类型。这三个封装都只是加了一个 `setup()` 钩子，行为与原生类相同。
- `FindScopeButton` 改为继承 `PopUpButton`，原来手写的 `commonInit()` 挪进 `setup()`，省掉两个初始化器的重写和一个无参的便利初始化器（`PopUpButton` 已经提供）。`titleItem` 是带初值的存储属性，在 `super.init` 之前就已经初始化好，所以 `setup()` 里可以直接用。
- 有两处保留原生类：
  - `caseSensitiveButton` 保留 `NSButton`。它需要 `.smallSquare` 的边框样式和 `.pushOnPushOff` 的按钮类型，而 `PushButton` 的样式固定为 `.push`，这正是 AGENTS.md 举例认可的回退情形。
  - `searchProgressIndicator` 保留 `NSProgressIndicator`。UIFoundation 的 `ProgressIndicator` 定义在 FilterUI 的 `FilterSearchField.swift` 里，只是给过滤框用的，算不上通用封装。
- 两个承载布局的 `NSView` 也保留：它们不需要图层效果，AGENTS.md 只要求有图层效果的视图继承 `LayerBackedView`。

**拟修改**：
```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Find/FindViewController.swift
@@ -28,13 +28,13 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
     private let caseSensitiveButton = NSButton()
 
-    private let searchField = NSSearchField()
+    private let searchField = SearchField()
 
     private let searchProgressIndicator = NSProgressIndicator()
 
     private let scopeButton = FindScopeButton()
 
-    private let memberKindPopUpButton = NSPopUpButton()
+    private let memberKindPopUpButton = PopUpButton()
 
     // MARK: - Summary Bar
 
@@ -42,7 +42,7 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
     private let summaryLabel = Label()
 
-    private let summarySeparatorView = NSBox()
+    private let summarySeparatorView = Box()
 
     private var summaryHeightConstraint: Constraint?
 
@@ -50,11 +50,11 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 
     private let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
 
-    private let resultsTopSeparatorView = NSBox()
+    private let resultsTopSeparatorView = Box()
 
     // MARK: - Filter Bar
 
-    private let filterSeparatorView = NSBox()
+    private let filterSeparatorView = Box()
 
     private let filterSearchField = FilterSearchField()
 
@@ -440,28 +440,15 @@ final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewCont
 /// Declared outside the generic view controller: a view nested in a generic class is generic
 /// itself.
-private final class FindScopeButton: NSPopUpButton {
+private final class FindScopeButton: PopUpButton {
     /// The menu to show the next time it opens.
     var menuItems: [FindScopeMenuItem] = []
 
     private let titleItem = NSMenuItem()
 
-    convenience init() {
-        self.init(frame: .zero, pullsDown: false)
-    }
-
-    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
-        super.init(frame: buttonFrame, pullsDown: flag)
-        commonInit()
-    }
-
-    required init?(coder: NSCoder) {
-        super.init(coder: coder)
-        commonInit()
-    }
-
-    private func commonInit() {
+    override func setup() {
+        super.setup()
         (cell as? NSPopUpButtonCell)?.do {
             $0.usesItemFromMenu = false
             $0.menuItem = titleItem
```

**复现测试（示例）**：纯替换，行为不变。App target 没有单元测试，用编译验证代替：
```bash
queued-build ./RunScript.sh --no-launch --derived-data /Volumes/DerivedData/Agents.noindex/claude/DerivedData/RuntimeViewer 2>&1 | xcsift
```
运行时需要人工看一眼的只有一处：Find 页的模式路径、范围按钮、成员种类弹出菜单和三条分隔线，外观应当与改动前一致。

**同类**：
- `ReportViewController.swift:39` 的 `NSBox`、`:41` 的 `NSButton`，以及 `ReportCellView.swift:19` 的 `NSProgressIndicator`，都在模块 E 的文件里，由 PR121.64 那一组一并判断。其中 `NSButton` 与 `NSProgressIndicator` 大概率与这里一样属于可以保留的回退情形。
- Find 的其它文件里没有类似写法。

**工作量**：S；无依赖。


### PR121.53 ReportNode.isContentEqual 吞掉第二层以下的变化

- **严重度**：Minor
- **审查编号**：C17（A4-2、A5-5）
- **状态**：方案待批，代码未改

**问题**：Report 大纲用 `rx.nodes(options: [])`（每次更新整表 `reloadData`）。App 链接的 RxAppKit 0.6.0 只在根层判断「树变了没有」：比较 `differenceIdentifier`，再问根节点的 `isContentEqual`。`ReportNode.isContentEqual` 只比较直接子节点的标识。根节点是两个类别，所以批次里的镜像行一变——过滤框打字、时钟开关只留进行中的工作——判断都说「没变」，大纲不重载，留着被过滤掉的行。另外，`ReportNode` 的 `==` 是合成的整树相等：一棵子树一变，节点就不等于旧的自己，`reloadData` 之后这一行回来就是折叠的。PR121.54 那段「每次更新都展开」正是在补这个缺口，同时也把用户的折叠撤销了。

**四问**：复现——在一个有镜像行的批次下，过滤框输入只匹配其中一个镜像的文字，其余镜像行不消失，直到第一层有别的变化（例如一个语料构建结束）才一起刷新；基线——本 PR 新引入，`ReportNode` 是本 PR 新增的类型；影响——过滤与时钟在批次一级以下失效，展开状态每次重载都丢，常见但不致命，建议修；历史——这套写法是照 RxAppKit 0.5.4 设计的（提案原文「相等性比较整棵子树（大纲适配器只在树变了时 reloadData）」，0.5.4 的 reload 路径确实用 `oldArray != newArray`）。三个 workspace 在分叉点之前就已解析到 0.6.0，其中 RxAppKit 8e48b25（2026-09-20）把判断改成「根层的 `differenceIdentifier` + `isContentEqual`」，并在注释里写明节点的 `==` 应该只比身份。包级的 `Package.resolved` 仍钉 0.5.4，所以包里的测试跑的是与 App 相反的行为，见 PR121.71。

**改法**：
- `ReportNode` 改用 RxAppKit 0.6.0 的节点约定，与 RxAppKit 自己测试里的 `DiffNode` 一致：`==` 只比 `identifier`（哈希本来就只取标识），`isContentEqual` 递归比较整棵子树的形状。身份相等也是 NSOutlineView 在 `reloadData` 之后保住同一行展开状态的前提；`StatefulOutlineView.swift:63-69` 的注释记过反面现象：不相等的项回来时是折叠的。
- 不改用 `.diffable`。diffable 也只对根层出 changeset，类别一有内容变化就是 `elementUpdated`；而 `isOutlineViewSafe` 要求没有 `elementUpdated`，照样退回 `reloadData`（RxAppKit `NSOutlineView+StagedChangeset.swift:123-125`）。这棵树换 diffable 得不到任何增量收益。
- 选中按项保持：`reloadData` 按行号保留选中，最新的批次插在最上面时，高亮会落到别的行上。给 `StatefulOutlineView` 加一个默认关闭的开关 `preservesSelectedItemAcrossReloads`：重载前记下选中的项，重载后用 `row(forItem:)` 选回。身份 `==` 让「同一标识的新节点」能找到它的行。开关默认关，侧栏的行为不受影响；Report 页打开它。先只做第一条（身份 `==`）跑一次测试 3：若 AppKit 已经按项保住了选中，这一块就不加。
- 前提是包级解析到 RxAppKit 0.6.0（PR121.71）。身份 `==` 在 0.5.4 下会让所有同标识的树都被判为「没变」，修好的代码在 0.5.4 上反而全坏。
- 文档同批改：提案里「相等性比较整棵子树」那一句；AGENTS.md「Differentiable conformance」一节补上值类型树节点的约定，免得下一棵树照旧写法写。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportNode.swift
@@ -51,23 +51,33 @@ public struct ReportNode: Hashable, OutlineNodeType {
         self.children = children
     }
 
-    /// Equality stays the synthesized, whole-subtree one — the outline adapter reloads only when
-    /// the new tree differs from the old — but the hash is the identifier's alone. The outline
-    /// hashes its items for every lookup, and a category's subtree is up to a hundred batches of
-    /// images.
+    /// Equality and the hash are the identifier's alone — RxAppKit's contract for outline nodes
+    /// since 0.6.0. `NSOutlineView` keeps a row expanded across `reloadData()` only when the new
+    /// item is equal to the old one, so a batch whose images changed must still equal itself.
+    /// Whether anything changed is `isContentEqual(to:)`'s question, asked of the whole subtree.
+    public static func == (leftNode: ReportNode, rightNode: ReportNode) -> Bool {
+        leftNode.identifier == rightNode.identifier
+    }
+
     public func hash(into hasher: inout Hasher) {
         hasher.combine(identifier)
     }
 }
 
 #if canImport(AppKit) && !targetEnvironment(macCatalyst)
 extension ReportNode: Differentiable {
     public var differenceIdentifier: ReportNodeIdentifier { identifier }
 
-    /// A row's own content changes through its cell ViewModel, never through the node, so only
-    /// its children can make a node differ from the one it replaces.
+    /// A row's own content changes through its cell ViewModel, never through the node, so a node
+    /// differs from the one it replaces only in the shape of its subtree. The reload adapter asks
+    /// this of the first level alone and trusts the answer for every level below, so it walks
+    /// them all.
     public func isContentEqual(to source: ReportNode) -> Bool {
-        children.map(\.identifier) == source.children.map(\.identifier)
+        identifier == source.identifier
+            && children.count == source.children.count
+            && zip(children, source.children).allSatisfy { child, sourceChild in
+                child.isContentEqual(to: sourceChild)
+            }
     }
 }
 #endif
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/StatefulOutlineView.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/StatefulOutlineView.swift
@@ -15,5 +15,11 @@ open class StatefulOutlineView: OutlineView {
 
     private var filteringState: FilteringState = .idle
     private var isReloadingData = false
 
+    /// Keeps the selected row on the same item across `reloadData()`. AppKit keeps the selected
+    /// row *index*, so a reload that inserts rows above the selection moves the highlight onto
+    /// another item. Needs items whose `==` is their identity, so the item that replaces the
+    /// selected one finds its row. Off by default: the sidebar restores its selection itself.
+    open var preservesSelectedItemAcrossReloads = false
+
     // MARK: - Expansion Autosave Configuration
@@ -246,9 +252,15 @@ open class StatefulOutlineView: OutlineView {
     open override func reloadData() {
         guard !isReloadingData else { return }
         isReloadingData = true
         defer { isReloadingData = false }
 
+        let selectedItemBeforeReload: AnyHashable? = if preservesSelectedItemAcrossReloads, filteringState == .idle, selectedRow >= 0 {
+            item(atRow: selectedRow) as? AnyHashable
+        } else {
+            nil
+        }
+
         dataStructureVersion &+= 1
         super.reloadData()
 
         switch filteringState {
@@ -261,4 +273,13 @@ open class StatefulOutlineView: OutlineView {
             restoreSelectedItem()
             filteringState = .idle
         }
+
+        if let selectedItemBeforeReload {
+            let rowAfterReload = row(forItem: selectedItemBeforeReload)
+            if rowAfterReload < 0 {
+                deselectAll(nil)
+            } else if rowAfterReload != selectedRow {
+                selectRowIndexes(IndexSet(integer: rowAfterReload), byExtendingSelection: false)
+            }
+        }
     }
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
@@ -133,6 +133,8 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
             $0.allowsMultipleSelection = false
             $0.allowsEmptySelection = true
             $0.allowsTypeSelect = true
+            // The newest work is inserted at the top; the highlight stays on the row it was on.
+            $0.preservesSelectedItemAcrossReloads = true
             $0.headerView = nil
             $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
             $0.target = self
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportViewModelTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportViewModelTests.swift
@@ -104,7 +104,8 @@ struct ReportViewModelTests {
 
         let laterNodes = try await nextValue(from: page.output.nodes)
         #expect(Self.node(buildIdentifier, in: laterNodes)?.cellViewModel === row.cellViewModel)
-        #expect(laterNodes == nodes, "the outline would reload for a change only the row's own cell shows")
+        // `==` on nodes is identity only; whether the outline would reload is `isContentEqual`.
+        #expect(laterNodes.elementsEqual(nodes) { $0.isContentEqual(to: $1) }, "the outline would reload for a change only the row's own cell shows")
         await engine.stop()
     }
```

```diff
--- a/Documentations/Evolutions/draft-report-navigator.md
+++ b/Documentations/Evolutions/draft-report-navigator.md
@@ -38,6 +38,7 @@
   复用。图标、标题、说明、状态与 tooltip 合成一个 `Appearance`，只挂一个 `@RxObserved`（规矩见
   [0005](0005-cellvm-appearance-single-observed.md)）；cell 在 `bind(to:)` 里绑这一条流，只重设变了的部分——进度直接落到
   屏幕上的行，不需要大纲重载。
-  树本身是值类型 `ReportNode`，相等性比较整棵子树（大纲适配器只在树变了时 `reloadData`），哈希只取标识（大纲每次查找都要哈希
-  一个 item，而一类下面可以有上百个批次）。原计划的三种 CellViewModel 合成了一种：Xcode 每一行的构成都一样。
+  树本身是值类型 `ReportNode`，按 RxAppKit 0.6.0 的节点约定：`==` 与哈希只取标识（NSOutlineView 只为相等的项保住展开状态），
+  `isContentEqual` 递归比较整棵子树（适配器只在根层问它，再据此决定要不要 `reloadData`）。大纲开着
+  `preservesSelectedItemAcrossReloads`，重载后选中留在原来的项上。原计划的三种 CellViewModel 合成了一种：Xcode 每一行的构成都一样。
   大纲用 `StatefulOutlineView`：带分组行的 source list，正是 2026-09-27 那份已解决问题描述的行高估算风险形状。
```

```diff
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -1164,5 +1164,7 @@ extension XxxCellViewModel: Differentiable {
 #endif
 ```
 For cell ViewModels that own no extra state beyond the underlying `Hashable` domain object, an empty `extension XxxCellViewModel: Differentiable {}` is acceptable — DifferenceKit synthesizes `differenceIdentifier = self` / `isContentEqual = ==` from `Hashable + Equatable`.
+
+**Value-type outline trees** (a `struct` node that carries its `children`, such as `ReportNode`) follow RxAppKit's contract since 0.6.0: `==` and `hash(into:)` use the identifier alone, and `isContentEqual(to:)` compares the whole subtree recursively. The reload adapter asks `isContentEqual` of the first level only, so a shallow answer swallows every change below it; and `NSOutlineView` keeps a row expanded across `reloadData()` only when the new item is `==` to the old one, so a synthesized whole-subtree `==` collapses every row whose subtree changed.
 
 **7. Click / selection events** — derive from `tableView.rx.itemClicked()` / `tableView.rx.modelSelected()` / `outlineView.rx.modelDoubleClicked()` instead of `target` + `@objc` plumbing:
```

**复现测试（示例）**：新文件 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportOutlineBindingTests.swift`，照 `StatefulOutlineViewRowGeometryTests` 的方式在屏幕外的窗口里放一个真实的 `StatefulOutlineView`，用与 Report 页相同的绑定，cell ViewModel 也像 `ReportViewModel` 那样按标识复用。在 RxAppKit 0.6.0 下（PR121.71 之后），修复前三条都红：测试 1 还是 5 行；测试 2 中类别重载后被折叠；测试 3 中选中落到了新插入的批次上。
```swift
import AppKit
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
import Testing
@testable import RuntimeViewerApplication

/// The Report navigator's tree bound to a real outline the way its page binds it — a
/// `StatefulOutlineView` in the source list style, `rx.nodes(options: [])` — with the cell
/// ViewModels kept across rebuilds as `ReportViewModel` keeps them. A change below the first level
/// reaches the screen, and a reload leaves expansion and selection on their items.
@Suite("ReportOutlineBinding", .serialized)
@MainActor
struct ReportOutlineBindingTests {
    @Test("a filter that drops images under a batch removes their rows")
    func changeBelowFirstLevelReachesTheOutline() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let batchIdentifier = RuntimeIndexingBatchID()
        fixture.publish(batches: [(batchIdentifier, ["/A", "/B", "/C"])])
        fixture.expandEveryRow()
        #expect(fixture.outlineView.numberOfRows == 5)

        fixture.publish(batches: [(batchIdentifier, ["/B"])])

        #expect(fixture.outlineView.numberOfRows == 3)
    }

    @Test("a reload keeps open the rows whose identity it kept")
    func reloadKeepsExpansion() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let runningBatch = RuntimeIndexingBatchID()
        fixture.publish(batches: [(runningBatch, ["/A", "/B"])])
        fixture.expandEveryRow()

        fixture.publish(batches: [(RuntimeIndexingBatchID(), ["/C"]), (runningBatch, ["/A", "/B"])])

        #expect(fixture.isExpanded(.category(.backgroundIndexing)))
        #expect(fixture.isExpanded(.indexingBatch(runningBatch)))
    }

    @Test("a row inserted above the selected one leaves the selection on its item")
    func reloadKeepsSelectionOnItsItem() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let selectedBatch = RuntimeIndexingBatchID()
        fixture.publish(batches: [(selectedBatch, ["/A"])])
        fixture.expandEveryRow()
        let selectedRow = try #require(fixture.row(of: .indexingBatch(selectedBatch)))
        fixture.outlineView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)

        fixture.publish(batches: [(RuntimeIndexingBatchID(), ["/C"]), (selectedBatch, ["/A"])])

        let selectedNode = fixture.outlineView.item(atRow: fixture.outlineView.selectedRow) as? ReportNode
        #expect(selectedNode?.identifier == .indexingBatch(selectedBatch))
    }
}

extension ReportOutlineBindingTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let outlineView: StatefulOutlineView

        private let nodesRelay = BehaviorRelay<[ReportNode]>(value: [])
        private var cellViewModelsByIdentifier: [ReportNodeIdentifier: ReportCellViewModel] = [:]
        private let disposeBag = DisposeBag()

        init() {
            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.outlineView = outlineView
            outlineView.style = .sourceList
            outlineView.rowHeight = 24
            // What the Report page sets.
            outlineView.preservesSelectedItemAcrossReloads = true
            scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.orderFrontRegardless()

            outlineView.rx.nodes(source: nodesRelay.asObservable(), options: [])({ (_: NSOutlineView, _: NSTableColumn?, _: ReportNode) -> NSView? in
                NSTableCellView()
            }, nil)
            .disposed(by: disposeBag)
        }

        func tearDown() {
            window.orderOut(nil)
        }

        /// Publishes a Background Indexing category holding `batches`, newest first, one row per
        /// image path under each — the shape `ReportViewModel` builds.
        func publish(batches: [(identifier: RuntimeIndexingBatchID, imagePaths: [String])]) {
            let batchNodes = batches.map { batch in
                node(.indexingBatch(batch.identifier), children: batch.imagePaths.map { imagePath in
                    node(.indexingItem(batchID: batch.identifier, imagePath: imagePath))
                })
            }
            nodesRelay.accept([node(.category(.backgroundIndexing), children: batchNodes)])
            outlineView.layoutSubtreeIfNeeded()
        }

        func expandEveryRow() {
            outlineView.expandItem(nil, expandChildren: true)
        }

        func row(of identifier: ReportNodeIdentifier) -> Int? {
            (0 ..< outlineView.numberOfRows).first { row in
                (outlineView.item(atRow: row) as? ReportNode)?.identifier == identifier
            }
        }

        func isExpanded(_ identifier: ReportNodeIdentifier) -> Bool {
            guard let row = row(of: identifier) else { return false }
            return outlineView.isItemExpanded(outlineView.item(atRow: row))
        }

        private func node(_ identifier: ReportNodeIdentifier, children: [ReportNode] = []) -> ReportNode {
            let cellViewModel = cellViewModelsByIdentifier[identifier] ?? ReportCellViewModel(identifier: identifier)
            cellViewModelsByIdentifier[identifier] = cellViewModel
            return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
        }
    }
}
```

**同类**：
- `FindResultNode`（PR121.43）也是浅层的 `isContentEqual`，同一原因，归那一条修。
- 其余用 `rx.nodes` 的地方（侧栏两列、Specialization）都是 PR 之前就有的引用型 cell ViewModel，子节点变化各自用 `reloadItem` 处理，不属于这个模式。
- 文档的同类防线就是上面 AGENTS.md 加的那一段。

**工作量**：M（改动本身是 S，AppKit 测试占大头）。依赖 PR121.71；PR121.54 与 PR121.59 依赖本条。


### PR121.54 Report 每次更新都重新展开用户折叠的行

- **严重度**：Minor
- **审查编号**：C19（A4-4，属于上次的第 7 条）
- **状态**：方案待批，代码未改

**问题**：`ReportViewController` 的展开逻辑（ReportViewController.swift:198-214）在 `nodes` 每次发射后都执行一遍：把所有类别、以及所有「进行中且有子行」的批次逐个展开。工作进行期间，索引事件和语料进度大约每 16 ms 合并成一次发射，所以用户刚折叠的类别或批次，下一帧就被重新打开，根本收不起来。这段代码原本是在补 PR121.53 里「整树 `==` 让重载后的行回来全是折叠的」那个缺口。

**四问**：复现——在后台索引或语料构建进行时，折叠 Background Indexing 类别，它会立刻重新展开；基线——本 PR 新引入（旧弹窗只对 ACTIVE 组这样做，现在侧栏常驻、语料也进来了，范围更大）；影响——用户无法自己管理 Report 页的展开状态，常见、看得见，建议修；历史——新代码。Find 页（PR121.07）是同一写法，两边必须用同一套策略。

**改法**：
- 策略与 Find 页一致：**首次出现时展开一次，之后不再用代码改任何行的展开状态**。类别第一次出现时展开；批次第一次出现时，如果还在进行并且有子行，就展开。出现过的标识，不论当时有没有展开，都不再处理。
- 判定写成 `ReportOutline.nodesToExpand(in:seenIdentifiers:)` 纯函数，可以单测。「已见过的标识」由 ViewModel 持有（每个页面一个 ViewModel）。ViewModel 输出 `nodesToExpand`，VC 在 nodes 绑定之后订阅：共享的 Driver 按订阅顺序派发，所以适配器先 reload，再展开。
- 依赖 PR121.53 的身份 `==`。有了它，已经出现过的行在 `reloadData` 之后会自己保住展开状态，不需要再补。
- 过滤时改用 `StatefulOutlineView.beginFiltering()` / `endFiltering()`，侧栏根列表也是这么做的。过滤期间每次重载都全部展开，清空过滤后恢复用户原来的展开状态。没有这一步，用户折叠过的批次会把匹配的镜像藏起来。ViewModel 在修改过滤状态**之前**先发出 `filteringChanged`，这样 VC 在被过滤的树到达之前就已经进入或退出过滤模式，不依赖订阅顺序。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -35,4 +35,11 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
     public struct Output {
         public let nodes: Driver<[ReportNode]>
+        /// Rows to open once the outline shows `nodes`: each kind of work, and each batch still
+        /// running, the first time it appears. Nothing is opened or closed after that.
+        public let nodesToExpand: Driver<[ReportNode]>
+        /// The filter bar starts (`true`) or stops narrowing the outline. Sent before the narrowed
+        /// tree, so the outline knows which reload opens every row and which puts the user's own
+        /// expansion back.
+        public let filteringChanged: Signal<Bool>
         /// Nothing at all to report — no batch, no build, no feature turned off.
         public let isEmpty: Driver<Bool>
@@ -63,4 +70,9 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
     @RxObserved
     private var showsOnlyInProgress: Bool = false
 
+    /// Every row `ReportOutline.nodesToExpand(in:seenIdentifiers:)` has seen on this page.
+    private var seenNodeIdentifiers: Set<ReportNodeIdentifier> = []
+
+    private let filteringChangedRelay = PublishRelay<Bool>()
+
     public override init(documentState: DocumentState, router: any Router<Route>) {
@@ -136,29 +148,48 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
 
         input.filterString.driveOnNext { [weak self] filterString in
             guard let self else { return }
+            announceFilteringChange(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
             self.filterString = filterString
         }
         .disposed(by: rx.disposeBag)
 
         input.showsOnlyInProgress.driveOnNext { [weak self] showsOnlyInProgress in
             guard let self else { return }
+            announceFilteringChange(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
             self.showsOnlyInProgress = showsOnlyInProgress
         }
         .disposed(by: rx.disposeBag)
 
         let nodes = Driver.combineLatest($allNodes.asDriver(), $filterString.asDriver(), $showsOnlyInProgress.asDriver()) { nodes, filterString, showsOnlyInProgress in
             ReportOutline.filtered(nodes, by: filterString, showsOnlyInProgress: showsOnlyInProgress)
         }
+        let nodesToExpand = nodes.map { [weak self] nodes -> [ReportNode] in
+            guard let self else { return [] }
+            return ReportOutline.nodesToExpand(in: nodes, seenIdentifiers: &self.seenNodeIdentifiers)
+        }
 
         return Output(
             nodes: nodes,
+            nodesToExpand: nodesToExpand,
+            filteringChanged: filteringChangedRelay.asSignal(),
             isEmpty: $allNodes.asDriver().map(\.isEmpty).distinctUntilChanged(),
             hasWorkInProgress: $allNodes.asDriver().map { nodes in nodes.contains(where: ReportOutline.isInProgress) }.distinctUntilChanged(),
             hasHistory: Driver.combineLatest(indexingCoordinator.historyObservable.asDriver(onErrorJustReturn: []), corpusCoordinator.$finishedBuilds.asDriver()) { history, finishedBuilds in
                 !history.isEmpty || !finishedBuilds.isEmpty
             }
             .distinctUntilChanged()
         )
     }
 
+    /// Tells the page the filter bar starts or stops narrowing the outline, before the narrowed
+    /// tree reaches it.
+    private func announceFilteringChange(filterString newFilterString: String, showsOnlyInProgress newShowsOnlyInProgress: Bool) {
+        let wasFiltering = ReportOutline.isFiltering(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
+        let isFiltering = ReportOutline.isFiltering(filterString: newFilterString, showsOnlyInProgress: newShowsOnlyInProgress)
+        if isFiltering != wasFiltering {
+            filteringChangedRelay.accept(isFiltering)
+        }
+    }
+
     // MARK: - Building the outline
@@ -352,8 +384,8 @@ enum ReportOutline {
     /// The filter bar: a row stays when its title contains the filter string, or when one of its
     /// descendants does; the clock toggle keeps only the work in progress the same way.
     static func filtered(_ nodes: [ReportNode], by filterString: String, showsOnlyInProgress: Bool) -> [ReportNode] {
+        guard isFiltering(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress) else { return nodes }
         let needle = filterString.trimmingCharacters(in: .whitespaces)
-        guard !needle.isEmpty || showsOnlyInProgress else { return nodes }
         func keep(_ node: ReportNode) -> ReportNode? {
             let children = node.children.compactMap(keep)
             let matchesText = needle.isEmpty || node.cellViewModel.appearance.title.range(of: needle, options: .caseInsensitive) != nil
@@ -366,6 +398,33 @@ enum ReportOutline {
         return nodes.compactMap(keep)
     }
 
+    /// Whether the filter bar narrows the outline at all.
+    static func isFiltering(filterString: String, showsOnlyInProgress: Bool) -> Bool {
+        !filterString.trimmingCharacters(in: .whitespaces).isEmpty || showsOnlyInProgress
+    }
+
+    /// The rows to open: each kind of work, and each batch still running with images under it,
+    /// the first time it appears — as Xcode opens its newest builds. A row seen once is never
+    /// opened or closed again, so what the user collapses stays collapsed. `seenIdentifiers`
+    /// carries what has been seen from one call to the next.
+    static func nodesToExpand(in nodes: [ReportNode], seenIdentifiers: inout Set<ReportNodeIdentifier>) -> [ReportNode] {
+        var nodesToExpand: [ReportNode] = []
+        for categoryNode in nodes {
+            if seenIdentifiers.insert(categoryNode.identifier).inserted {
+                nodesToExpand.append(categoryNode)
+            }
+            for node in categoryNode.children {
+                guard seenIdentifiers.insert(node.identifier).inserted else { continue }
+                if node.cellViewModel.isInProgress, !node.children.isEmpty {
+                    nodesToExpand.append(node)
+                }
+            }
+        }
+        return nodesToExpand
+    }
+
     static func isCategory(_ node: ReportNode) -> Bool {
         if case .category = node.identifier { return true }
         return false
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
@@ -195,20 +195,24 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         })
         .disposed(by: rx.disposeBag)
 
-        // Subscribed after the nodes binding, so the adapter has reloaded by the time this runs:
-        // each kind of work, and whatever runs under it, is shown open, as Xcode opens the
-        // newest builds; what the user collapses or opens otherwise stays as it is.
-        output.nodes.driveOnNext { [weak self] nodes in
+        // Subscribed after the nodes binding, so the adapter has reloaded by the time this runs.
+        // Each row is opened at most once, the first time it appears; what the user collapses
+        // stays collapsed.
+        output.nodesToExpand.driveOnNext { [weak self] nodes in
             guard let self else { return }
-            for categoryNode in nodes {
-                if !outlineView.isItemExpanded(categoryNode) {
-                    outlineView.expandItem(categoryNode)
-                }
-                for node in categoryNode.children where node.cellViewModel.isInProgress && !node.children.isEmpty {
-                    if !outlineView.isItemExpanded(node) {
-                        outlineView.expandItem(node)
-                    }
-                }
+            for node in nodes {
+                outlineView.expandItem(node)
+            }
+        }
+        .disposed(by: rx.disposeBag)
+
+        // Every row opens while the filter bar narrows the outline, and the user's own expansion
+        // comes back when it stops — the sidebar's behaviour.
+        output.filteringChanged.emitOnNext { [weak self] isFiltering in
+            guard let self else { return }
+            if isFiltering {
+                outlineView.beginFiltering()
+            } else {
+                outlineView.endFiltering()
             }
         }
         .disposed(by: rx.disposeBag)
```

**复现测试（示例）**：放在 `ReportViewModelTests`。被修的「每次都展开」写在 App target 的 VC 里，App target 没有单元测试 target，所以测试锁定的是新策略本身，修前无法写成红灯。展开状态在真实大纲里能否保住，由 PR121.53 的测试 2 负责，那一条在修前是红的。
```swift
@Test("each kind of work and each running batch open the first time they appear, and never again")
func rowsOpenOnlyOnFirstSight() {
    let runningBatchID = RuntimeIndexingBatchID()
    let runningBatch = Self.row(.indexingBatch(runningBatchID), title: "Manual Indexing", isInProgress: true, children: [
        Self.row(.indexingItem(batchID: runningBatchID, imagePath: "/A"), title: "A", isInProgress: true),
    ])
    let finishedBatchID = RuntimeIndexingBatchID()
    let finishedBatch = Self.row(.indexingBatch(finishedBatchID), title: "App Launch Indexing", children: [
        Self.row(.indexingItem(batchID: finishedBatchID, imagePath: "/B"), title: "B"),
    ])
    var seenIdentifiers: Set<ReportNodeIdentifier> = []

    let category = Self.row(.category(.backgroundIndexing), title: "Background Indexing", children: [runningBatch, finishedBatch])
    #expect(ReportOutline.nodesToExpand(in: [category], seenIdentifiers: &seenIdentifiers).map(\.identifier) == [category.identifier, runningBatch.identifier])
    // The next update, after the user collapsed both.
    #expect(ReportOutline.nodesToExpand(in: [category], seenIdentifiers: &seenIdentifiers).isEmpty)

    let newBatchID = RuntimeIndexingBatchID()
    let newBatch = Self.row(.indexingBatch(newBatchID), title: "Manual Indexing", isInProgress: true, children: [
        Self.row(.indexingItem(batchID: newBatchID, imagePath: "/C"), title: "C", isInProgress: true),
    ])
    let grownCategory = Self.row(.category(.backgroundIndexing), title: "Background Indexing", children: [newBatch, runningBatch, finishedBatch])
    #expect(ReportOutline.nodesToExpand(in: [grownCategory], seenIdentifiers: &seenIdentifiers).map(\.identifier) == [newBatch.identifier])
}

@Test("the filter bar announces it starts narrowing before the narrowed rows arrive")
func filteringIsAnnouncedBeforeTheNarrowedTree() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.filteringAnnounced")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    // Both turned off, so the outline has its two rows at once.
    environment.settings.indexing.isEnabled = false
    environment.settings.search.isCorpusEnabled = false
    let filterRelay = BehaviorRelay<String>(value: "")
    let page = environment.make { Page(documentState: environment.documentState, filterString: filterRelay.asDriver()) }
    defer { withExtendedLifetime(page) {} }
    _ = try await nextValue(from: page.output.nodes) { !$0.isEmpty }

    var events: [String] = []
    let disposeBag = DisposeBag()
    page.output.filteringChanged.emitOnNext { isFiltering in events.append("filtering \(isFiltering)") }.disposed(by: disposeBag)
    page.output.nodes.skip(1).driveOnNext { _ in events.append("nodes") }.disposed(by: disposeBag)

    filterRelay.accept("Turned")
    try await settleMainQueue()

    #expect(events.first == "filtering true")
    #expect(events.contains("nodes"))
    await engine.stop()
}
```

**同类**：Find 页的 C38（PR121.07）。它的展开策略必须与本条用同一个规则（首次出现时展开一次），由那一条落实。

**工作量**：S。依赖 PR121.53。


### PR121.55 别处发起的构建行能点 Cancel 却不做事

- **严重度**：Minor
- **审查编号**：C18（A4-3、A3-6 的显示一半，属于上次第 9 条的一部分）
- **状态**：方案待批，代码未改

**问题**：
- `FindCorpusCoordinator.mergeCoverage` 会把引擎快照里「本文档没请求过」的镜像也写进 `buildStatesByImagePath`（FindCorpusCoordinator.swift:340-347），也就是别的窗口、或镜像对端正在建的语料。
- Report 页给所有活跃行都设了 `isCancellable: true`（ReportViewModel.swift:324）。可这些行收不到进度，因为 `flushProgress` 只认本文档的请求；点 Cancel 也会在 `cancelBuild` 的 `guard`（:226）处直接返回。
- coverage 只在 Report 页出现、或本文档有构建成功时才会刷新。所以别处的构建结束后，这一行和分页上的活动标记可能一直亮着。

**四问**：
- **复现**：两个窗口开同一个 My Mac 引擎，窗口 A 打开一个没建过语料的大镜像。窗口 B 的 Report 页会出现这一行，带转圈、百分比不动；右键 Cancel 没有反应。A 的构建结束后，B 的这一行和分页标记在 B 再次打开 Report 页之前一直不消失。
- **基线**：本 PR 新引入。
- **影响**：误导用户，并且有一个无效的操作入口；多窗口时才会碰到。不严重，建议修。
- **历史**：新代码。提案写的取消语义是「取消只撤回本文档的订阅」，但界面没有区分哪些行是本文档的订阅。

**改法**：
- `FindCorpusCoordinator` 发布 `followedImagePaths`，即本文档持有构建请求的镜像集合，在 `buildRequests` 的 `didSet` 里同步。`ReportViewModel` 把它并入输入。
- `configure(_:forCorpusOf:state:isFollowed:)` 新增参数：
  - `isCancellable` 改为等于 `isFollowed`。
  - 不跟踪的行不显示百分比（快照里的数字不会动），说明只写 "Building"，tooltip 补一句 "Requested by another window"（文案可再定）。
- Cancel All 只撤回本文档跟踪的构建；它是否可用，改看「有没有可取消的行」（`hasCancellableWork`），不再看「有没有进行中的行」。
- 只要还有不跟踪的活跃行，协调器每 2 秒刷新一次 coverage。同一时间只挂一个刷新任务；换引擎（`stopPumps`）或这类行没了就停。这样别处的构建结束后，这一行和活动标记都会自己消失。
- 取舍：别处的构建仍然计入活动标记（推荐方案 A）。语料是整个引擎共用的，别人建好的语料本窗口也搜得到；用户打开 Report 页想知道的是「还有什么在跑」。如果改为只计本文档自己的构建（方案 B），活动标记那一路要改成只看 `followedImagePaths`。
- 与 PR121.09 的关系：本文档自己的行点 Cancel 之后，服务端是否真的停，由 PR121.09 和 PR121.29 解决。本条只保证「撤不回的行不给 Cancel」。如果以后改为由 store 主动推送 coverage，第 2 秒一次的刷新可以删掉。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift
@@ -50,6 +50,11 @@ public final class FindCorpusCoordinator {
     /// How long transformer edits are left to settle before every corpus is
     /// rebuilt.
     static let transformerRebuildDelayNanoseconds: UInt64 = 2_000_000_000
 
+    /// How often the engine is asked again while builds this document did not
+    /// ask for are under way: nothing else tells this document how they go or
+    /// that they ended.
+    static let unfollowedBuildCoverageRefreshIntervalNanoseconds: UInt64 = 2_000_000_000
+
     /// A build request this document holds open — one subscription on the
@@ -69,12 +74,22 @@ public final class FindCorpusCoordinator {
 
     /// The build requests this document holds open, by image path.
     /// Cancelling one withdraws only this document's interest.
-    private var buildRequests: [String: BuildRequest] = [:]
+    private var buildRequests: [String: BuildRequest] = [:] {
+        didSet {
+            let imagePaths = Set(buildRequests.keys)
+            if imagePaths != followedImagePaths {
+                followedImagePaths = imagePaths
+            }
+        }
+    }
 
     private var nextBuildRequestIdentifier: UInt64 = 0
 
     private var transformerRebuildTask: Task<Void, Never>?
+
+    /// The pending refresh `scheduleCoverageRefreshWhileOthersBuild()` asked for.
+    private var coverageRefreshTask: Task<Void, Never>?
 
@@ -108,6 +123,13 @@ public final class FindCorpusCoordinator {
     @RxObserved
     public private(set) var finishedBuilds: [FindCorpusFinishedBuild] = []
 
+    /// The images this document holds a build request for: the corpus rows the
+    /// Report navigator can cancel. Every other active state came from a
+    /// coverage snapshot — another document's build, or one the engine runs for
+    /// a peer — and this document can neither follow nor withdraw it.
+    @RxObserved
+    public private(set) var followedImagePaths: Set<String> = []
+
     /// Every image that has had a place in `finishedBuilds`, kept through
@@ -142,6 +164,7 @@ public final class FindCorpusCoordinator {
     deinit {
         eventPumpTask?.cancel()
         transformerRebuildTask?.cancel()
+        coverageRefreshTask?.cancel()
         for request in buildRequests.values {
             request.task.cancel()
         }
@@ -247,6 +270,24 @@ public final class FindCorpusCoordinator {
             self.mergeCoverage(coverage)
         }
     }
 
+    /// While a build this document does not follow is under way, its row and
+    /// the Report navigator's activity mark show the engine's last word on it,
+    /// which nothing else refreshes. Asks again every two seconds until no such
+    /// build is left.
+    private func scheduleCoverageRefreshWhileOthersBuild() {
+        let hasUnfollowedActiveBuild = buildStatesByImagePath.contains { imagePath, state in
+            state.isActive && buildRequests[imagePath] == nil
+        }
+        guard hasUnfollowedActiveBuild, coverageRefreshTask == nil else { return }
+        coverageRefreshTask = Task { [weak self] in
+            try? await Task.sleep(nanoseconds: Self.unfollowedBuildCoverageRefreshIntervalNanoseconds)
+            guard let self, !Task.isCancelled else { return }
+            self.coverageRefreshTask = nil
+            self.refreshCoverage()
+        }
+    }
+
     /// Withdraws every request this document holds, leaving the images they
@@ -345,6 +386,7 @@ public final class FindCorpusCoordinator {
         if states != buildStatesByImagePath {
             buildStatesByImagePath = states
         }
+        scheduleCoverageRefreshWhileOthersBuild()
 
         imagePathsListedInHistory.formIntersection(coverage.statesByImagePath.keys)
@@ -411,4 +452,6 @@ public final class FindCorpusCoordinator {
         imageDidLoadSubscription = nil
         transformerRebuildTask?.cancel()
         transformerRebuildTask = nil
+        coverageRefreshTask?.cancel()
+        coverageRefreshTask = nil
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -36,7 +36,8 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         public let nodes: Driver<[ReportNode]>
         /// Nothing at all to report — no batch, no build, no feature turned off.
         public let isEmpty: Driver<Bool>
-        /// Some work has not ended yet, so Cancel All has something to cancel.
-        public let hasWorkInProgress: Driver<Bool>
+        /// Some row can be withdrawn from this page, so Cancel All has something to cancel. A
+        /// corpus build another window asked for is in progress, but not this page's to cancel.
+        public let hasCancellableWork: Driver<Bool>
         public let hasHistory: Driver<Bool>
     }
@@ -75,22 +77,24 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         Observable.combineLatest(
             indexingCoordinator.batchesObservable,
             indexingCoordinator.historyObservable,
             corpusCoordinator.$buildStatesByImagePath.asObservable(),
+            corpusCoordinator.$followedImagePaths.asObservable(),
             corpusCoordinator.$finishedBuilds.asObservable(),
             $isIndexingEnabled.asObservable(),
             $isCorpusEnabled.asObservable()
         )
         .observe(on: MainScheduler.instance)
-        .subscribeOnNext { [weak self] batches, history, corpusStates, finishedBuilds, isIndexingEnabled, isCorpusEnabled in
+        .subscribeOnNext { [weak self] batches, history, corpusStates, followedImagePaths, finishedBuilds, isIndexingEnabled, isCorpusEnabled in
             guard let self else { return }
             MainActor.assumeIsolated {
                 self.allNodes = self.makeNodes(
                     batches: batches,
                     history: history,
                     corpusStates: corpusStates,
+                    followedImagePaths: followedImagePaths,
                     finishedBuilds: finishedBuilds,
                     isIndexingEnabled: isIndexingEnabled,
                     isCorpusEnabled: isCorpusEnabled
                 )
             }
         }
@@ -115,8 +119,9 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
 
         input.cancelAll.emitOnNext {
             indexingCoordinator.cancelAllBatches()
-            for (imagePath, state) in corpusCoordinator.buildStatesByImagePath where state.isActive {
+            // Only what this document asked for; another window's build is not this page's to stop.
+            for imagePath in corpusCoordinator.followedImagePaths {
                 corpusCoordinator.cancelBuild(of: imagePath)
             }
         }
@@ -153,7 +158,7 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         return Output(
             nodes: nodes,
             isEmpty: $allNodes.asDriver().map(\.isEmpty).distinctUntilChanged(),
-            hasWorkInProgress: $allNodes.asDriver().map { nodes in nodes.contains(where: ReportOutline.isInProgress) }.distinctUntilChanged(),
+            hasCancellableWork: $allNodes.asDriver().map { nodes in nodes.contains(where: ReportOutline.isCancellable) }.distinctUntilChanged(),
             hasHistory: Driver.combineLatest(indexingCoordinator.historyObservable.asDriver(onErrorJustReturn: []), corpusCoordinator.$finishedBuilds.asDriver()) { history, finishedBuilds in
@@ -167,6 +172,7 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         batches: [RuntimeIndexingBatch],
         history: [RuntimeIndexingBatch],
         corpusStates: [String: RuntimeInterfaceCorpusBuildState],
+        followedImagePaths: Set<String>,
         finishedBuilds: [FindCorpusFinishedBuild],
         isIndexingEnabled: Bool,
         isCorpusEnabled: Bool
@@ -207,7 +213,9 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
             return ReportOutline.imageName(of: lhs.key) < ReportOutline.imageName(of: rhs.key)
         }
         for (imagePath, state) in activeBuilds {
-            corpusChildren.append(node(.corpusBuild(imagePath: imagePath)) { ReportOutline.configure($0, forCorpusOf: imagePath, state: state) })
+            corpusChildren.append(node(.corpusBuild(imagePath: imagePath)) {
+                ReportOutline.configure($0, forCorpusOf: imagePath, state: state, isFollowed: followedImagePaths.contains(imagePath))
+            })
         }
         for finishedBuild in finishedBuilds {
@@ -310,18 +318,26 @@ enum ReportOutline {
         cellViewModel.update(icon: icon(forImagePath: item.id), title: imageName(of: item.id), detail: detail, status: status, toolTip: item.id, isInProgress: !item.state.isTerminal)
     }
 
-    static func configure(_ cellViewModel: ReportCellViewModel, forCorpusOf imagePath: String, state: RuntimeInterfaceCorpusBuildState) {
+    /// `isFollowed`: this document asked for the build, so its progress reaches the row and Cancel
+    /// withdraws it. Any other build is the engine's last snapshot, for a window or a peer this
+    /// page cannot speak for.
+    static func configure(_ cellViewModel: ReportCellViewModel, forCorpusOf imagePath: String, state: RuntimeInterfaceCorpusBuildState, isFollowed: Bool) {
         let detail: String
         let status: ReportRowStatus
         switch state {
         case .building(let progress):
-            detail = progress.total > 0 ? "\(progress.built * 100 / progress.total)% · \(progress.built) of \(progress.total)" : "Starting"
+            if isFollowed {
+                detail = progress.total > 0 ? "\(progress.built * 100 / progress.total)% · \(progress.built) of \(progress.total)" : "Starting"
+            } else {
+                detail = "Building"
+            }
             status = .running
         case .pending, .built, .failed:
             detail = "Waiting"
             status = .none
         }
-        cellViewModel.update(icon: icon(forImagePath: imagePath), title: imageName(of: imagePath), detail: detail, status: status, toolTip: imagePath, isCancellable: true, isInProgress: true)
+        let toolTip = isFollowed ? imagePath : "\(imagePath)\nRequested by another window"
+        cellViewModel.update(icon: icon(forImagePath: imagePath), title: imageName(of: imagePath), detail: detail, status: status, toolTip: toolTip, isCancellable: isFollowed, isInProgress: true)
     }
@@ -375,6 +391,10 @@ enum ReportOutline {
         node.cellViewModel.isInProgress || node.children.contains(where: isInProgress)
     }
 
+    static func isCancellable(_ node: ReportNode) -> Bool {
+        node.cellViewModel.isCancellable || node.children.contains(where: isCancellable)
+    }
+
     static func isBuilding(_ state: RuntimeInterfaceCorpusBuildState) -> Bool {
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
@@ -49,7 +49,7 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         filterSearchField
     }
 
-    private var hasWorkInProgress = false
+    private var hasCancellableWork = false
 
     private var hasHistory = false
@@ -220,8 +220,8 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         }
         .disposed(by: rx.disposeBag)
 
-        output.hasWorkInProgress.driveOnNext { [weak self] hasWorkInProgress in
-            self?.hasWorkInProgress = hasWorkInProgress
+        output.hasCancellableWork.driveOnNext { [weak self] hasCancellableWork in
+            self?.hasCancellableWork = hasCancellableWork
         }
         .disposed(by: rx.disposeBag)
@@ -236,5 +236,5 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
     @objc private func actionsButtonClicked(_ sender: NSButton) {
         let menu = NSMenu().then { menu in
-            menu.addItem(withTitle: "Cancel All", action: hasWorkInProgress ? #selector(cancelAllMenuItemAction(_:)) : nil, keyEquivalent: "").then {
+            menu.addItem(withTitle: "Cancel All", action: hasCancellableWork ? #selector(cancelAllMenuItemAction(_:)) : nil, keyEquivalent: "").then {
                 $0.target = self
                 $0.image = SFSymbols(systemName: .xmarkCircle).nsImage
```
（`self?.hasCancellableWork = …` 这种写法沿用原代码；PR121.64 会把这两处一并改成 `guard let self`。）

**复现测试（示例）**：放在 `ReportViewModelTests`。用 `@testable` 直接调用 `mergeCoverage`，注入一份「别处正在建」的快照，不需要第二个窗口。修前会红在两处：该行 `isCancellable` 为 true；以及测试引擎里并没有这个构建，可修前不会再刷新 coverage，这一行和 `reportActivity` 永远不消失，后两个 `nextValue` 会超时。
```swift
@Test("a corpus build this window did not ask for shows without Cancel, and goes once the engine stops reporting it")
func unfollowedBuildIsNotCancellable() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.unfollowedBuild")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.search.isCorpusEnabled = true
    let page = environment.make { Page(documentState: environment.documentState) }
    defer { withExtendedLifetime(page) {} }
    let imagePath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    let buildIdentifier = ReportNodeIdentifier.corpusBuild(imagePath: imagePath)

    // What a coverage snapshot says while another window's build of the image runs.
    environment.documentState.findCorpusCoordinator.mergeCoverage(RuntimeInterfaceCorpusCoverage(
        statesByImagePath: [imagePath: .building(RuntimeInterfaceCorpusBuildProgress(built: 10, total: 100))],
        residentByteCount: 0,
        residentByteLimit: 0
    ))

    let nodes = try await nextValue(from: page.output.nodes) { Self.node(buildIdentifier, in: $0) != nil }
    let row = try #require(Self.node(buildIdentifier, in: nodes))
    #expect(!row.cellViewModel.isCancellable)
    #expect(row.cellViewModel.appearance.detail == "Building")
    #expect(try await nextValue(from: page.output.hasCancellableWork) == false)

    // The test engine runs no such build, so the next refresh clears the row, and the tab's mark.
    _ = try await nextValue(from: page.output.nodes, timeout: 5) { Self.node(buildIdentifier, in: $0) == nil }
    _ = try await nextValue(from: environment.documentState.reportActivity, timeout: 5) { !$0 }
    await engine.stop()
}
```

**同类**：
- 活动标记 `DocumentState.reportActivity` 的语料那一路来自 `hasActiveBuild`，靠上面的定时刷新来保证别处的构建结束后能熄灭，不另改。
- 索引那一路的「别的窗口的批次」本来就可以从本窗口取消（`cancelBatch` 作用于引擎上的 manager），不属于这个问题。

**工作量**：M。改的是 PR121.09 / PR121.29 所在模块的文件，需要同批协调；PR121.59 会把这里对 `makeNodes` 的改动一起搬进 builder。


### PR121.56 单镜像 Always Index 失败时看不到原因

- **严重度**：Minor
- **审查编号**：C20（A4-5、B4）
- **状态**：方案待批，代码未改

**问题**：Report 页把只含一个镜像的 Always Index 批次压平，不再给镜像单独一行（ReportViewModel.swift:189）。这样一来，那个镜像的 `.failed(message:)` 就没有地方显示。批次行本身只写一句通用的 "1 of 1 images failed to index"（:275），用户看不出失败的原因，比如镜像不存在、加载报错。

**四问**：
- 复现：在 Settings 的 Always Index 里加一个不存在或打不开的镜像名，等它的批次结束。Report 页那一行只有红色标记和通用文案。
- 基线：本 PR 引入的回退。旧弹窗把 Always Index 的镜像直接列出来，失败时显示 `id — message`（9ca0d5a6 的 BackgroundIndexingPopoverViewController.swift:571-572）。
- 影响：只在 Always Index 条目失败时出现，但这正是用户最需要原因的时候（多半是条目写错了）。改动小，建议修。
- 历史：压平是旧弹窗留下的设计（提案「Always Index 只有一个镜像的批次不再挂子行」），丢掉失败原因是搬过来时漏掉的。

**改法**：
- 「是否压平」的判断挪进 `ReportOutline.showsItems(of:)`，让 `makeNodes` 和 `configure` 用同一个答案。
- 压平的批次如果它唯一的镜像失败了，批次行直接用这个镜像的状态：说明写 "Failed"，状态带上原始失败信息，tooltip 是镜像路径加原因。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -186,7 +186,7 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         }
         // The manager appends batches as they start, and history is newest first already.
         for batch in batches.reversed() + history {
-            let showsItems = !(batch.reason.category == .alwaysIndex && batch.items.count <= 1)
+            let showsItems = ReportOutline.showsItems(of: batch)
             let items = showsItems ? batch.items.map { item in
                 node(.indexingItem(batchID: batch.id, imagePath: item.id)) { ReportOutline.configure($0, for: item) }
             } : []
@@ -256,7 +256,19 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
 /// How the Report navigator's rows read and how its filter bar narrows them — kept apart from the
 /// generic `ReportViewModel`, which can hold no static stored values, and tested on its own.
 enum ReportOutline {
+    /// Whether a batch shows a row per image. An Always Index entry names one image, so a batch of
+    /// one shows none: the batch's own row stands for the image.
+    static func showsItems(of batch: RuntimeIndexingBatch) -> Bool {
+        !(batch.reason.category == .alwaysIndex && batch.items.count <= 1)
+    }
+
     static func configure(_ cellViewModel: ReportCellViewModel, for batch: RuntimeIndexingBatch) {
+        // The batch's row stands for its only image, which has no row of its own to say why it
+        // failed — what the popover showed as `path — message`.
+        if !showsItems(of: batch), let item = batch.items.first, case .failed(let message) = item.state {
+            cellViewModel.update(icon: indexingIcon, title: title(for: batch.reason), detail: "Failed", status: .failed(message: message), toolTip: "\(item.id)\n\(message)")
+            return
+        }
         let isRunning = !batch.isFinished
         var detail: String
         if isRunning {
```

**复现测试（示例）**：放在 `ReportViewModelTests`，是纯函数测试，不需要引擎。修前状态里的信息是 "1 of 1 images failed to index"、说明是 "1 image · 1 failed"，两条断言都红。
```swift
@Test("a single-image Always Index batch that failed says why on its own row")
func flattenedAlwaysIndexFailureShowsItsReason() {
    let imagePath = "/usr/lib/libMissing.dylib"
    let batch = RuntimeIndexingBatch(
        id: RuntimeIndexingBatchID(),
        rootImagePath: imagePath,
        depth: 0,
        reason: .alwaysIndex(identifier: "libMissing.dylib"),
        items: [RuntimeIndexingTaskItem(id: imagePath, resolvedPath: imagePath, state: .failed(message: "image not found"), hasPriorityBoost: false)],
        isCancelled: false,
        isFinished: true
    )
    let cellViewModel = ReportCellViewModel(identifier: .indexingBatch(batch.id))

    ReportOutline.configure(cellViewModel, for: batch)

    #expect(!ReportOutline.showsItems(of: batch))
    #expect(cellViewModel.appearance.status == .failed(message: "image not found"))
    #expect(cellViewModel.appearance.detail == "Failed")
}
```

**同类**：无。其它批次都会给每个镜像一行，镜像行本身会显示失败原因（`configure(_:for item:)` 的 `.failed` 分支）。

**工作量**：S。PR121.59 会把 `makeNodes` 里那一行一起搬进 builder。


### PR121.57 A→B→A 切回原引擎后批次重复

- **严重度**：Minor
- **审查编号**：C21（B3）
- **状态**：方案待批，代码未改

**问题**：文档从引擎 A 切到 B 时，`handleEngineSwap` 先给 A 发一个即发即弃的 `cancelAllBatches`，再把 A 上还在跑的批次 X 合成一份「已取消」快照放进历史（RuntimeBackgroundIndexingCoordinator.swift:292-317）。如果用户在 A 真正结束 X 之前又切回 A，就会出两次重复：
- 新订阅会先补发一个 `.batchStarted(X)`（RuntimeBackgroundIndexingManager.swift:82-84）。`applyEvent` 不加判断就把它放回进行中（:741-745），于是 X 同时出现在进行中和历史里。
- A 随后发来的 `.batchCancelled(X)` 又被无条件追加进历史（:776-781），历史里出现两个 X。

`ReportNode` 树里于是有两个相同标识的节点，NSOutlineView 和 cell ViewModel 缓存都不支持重复项；协调器自己的注释（:197-202）也写明这种状态下 DifferenceKit 的行为未定义。

**四问**：
- **复现**：在 My Mac 上开着一个正在索引的批次（主程序的依赖闭包要跑好几秒），切到另一个数据源，再立刻切回来。Report 页的这个批次会同时出现在顶部（进行中）和历史里；批次结束后，历史里有两条。
- **基线**：本 PR 新引入。补发 `.batchStarted` 是本 PR 的 3eb86d72 为了让晚到的订阅者看见进行中的批次而加的。
- **影响**：窗口很窄，要在几秒内切走又切回；后果是重复行和未定义的大纲行为。严重度低，改动小，建议修。
- **历史**：新代码。3eb86d72 只考虑了「第一次订阅时批次已经开始」，没考虑「同一个文档切回一个它刚取消过批次的引擎」。

**改法**：
- `StagingStore` 记下「因换引擎而归档、但 manager 还没给出终态」的批次标识（`swapArchivedBatchIDs`，在 `drainForEngineSwap` 时登记）。
- 这些标识的补发 `.batchStarted` 一律忽略：切走时已经取消了它，它不会再跑。
- 这些标识的终态事件**替换**历史里那份合成快照：按标识就地替换、保留位置；如果用户已经 Clear History、条目不在了，就什么也不做。然后把标识移出集合。
- 顺带让 `appendToHistory` 按标识幂等。历史里一个批次只留一条，不管它的终态从哪条路来。
- 为了能确定性地测试，`StagingStore` 及它返回的两个类型从 `fileprivate` 改为 `internal`。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
@@ -215,10 +215,16 @@ public final class RuntimeBackgroundIndexingCoordinator {
         for batch in snapshot.historyAdditions {
             appendToHistory(batch)
         }
+        for batch in snapshot.historyReplacements {
+            replaceInHistory(batch)
+        }
     }
 
     private func appendToHistory(_ batch: RuntimeIndexingBatch) {
         var updatedHistory = historyRelay.value
+        // One entry per batch, whichever route its end took to get here.
+        updatedHistory.removeAll { $0.id == batch.id }
         updatedHistory.insert(batch, at: 0)
         if updatedHistory.count > Self.maxHistoryEntries {
             updatedHistory.removeLast(updatedHistory.count - Self.maxHistoryEntries)
@@ -226,6 +232,16 @@ public final class RuntimeBackgroundIndexingCoordinator {
         historyRelay.accept(updatedHistory)
     }
 
+    /// Puts a batch's real end in place of the cancelled snapshot an engine swap archived for it.
+    /// Gone already — the user cleared the history — leaves nothing to replace.
+    private func replaceInHistory(_ batch: RuntimeIndexingBatch) {
+        var updatedHistory = historyRelay.value
+        guard let historyIndex = updatedHistory.firstIndex(where: { $0.id == batch.id }) else { return }
+        updatedHistory[historyIndex] = batch
+        historyRelay.accept(updatedHistory)
+    }
+
     private func refreshAggregate(batches: [RuntimeIndexingBatch]) {
@@ -687,7 +703,7 @@ extension RuntimeBackgroundIndexingCoordinator {
     /// Outcome of `StagingStore.applyEvent` — tells the coordinator what main-
     /// actor work the event triggered. Computed under the staging lock so the
     /// "did I just take ownership of the in-flight flush?" decision is atomic.
-    fileprivate struct ApplyOutcome {
+    struct ApplyOutcome {
         var requiresImmediateFlush: Bool = false
         var didScheduleCoalescedFlush: Bool = false
         var shouldReloadEngineImages: Bool = false
@@ -696,23 +712,31 @@ extension RuntimeBackgroundIndexingCoordinator {
     /// Snapshot taken at the start of a flush. The lock is released before the
     /// coordinator publishes to the relays, so subscribers run unblocked while
     /// the next batch of events keeps mutating the staging store.
-    fileprivate struct FlushSnapshot {
+    struct FlushSnapshot {
         let activeChanged: Bool
         let aggregateChanged: Bool
         let batches: [RuntimeIndexingBatch]
         let historyAdditions: [RuntimeIndexingBatch]
+        /// Real ends of batches an engine swap archived, each to take its archive's place.
+        let historyReplacements: [RuntimeIndexingBatch]
 
-        var hasWork: Bool { activeChanged || aggregateChanged || !historyAdditions.isEmpty }
+        var hasWork: Bool { activeChanged || aggregateChanged || !historyAdditions.isEmpty || !historyReplacements.isEmpty }
     }
 
     /// Lock-protected staging for `RuntimeBackgroundIndexingCoordinator`.
     /// Holds everything the off-main event pump touches; the coordinator's
     /// main-actor methods only see snapshots produced under the same lock.
     /// `@unchecked Sendable` because synchronization is via `NSLock` rather
-    /// than the data-race detector.
-    fileprivate final class StagingStore: @unchecked Sendable {
+    /// than the data-race detector. Internal so its tests can drive it event
+    /// by event (`RuntimeBackgroundIndexingStagingTests`).
+    final class StagingStore: @unchecked Sendable {
         private let lock = NSLock()
 
         // All fields below are touched only under `lock`.
         private var stagedBatches: [RuntimeIndexingBatch] = []
         private var pendingHistoryAdditions: [RuntimeIndexingBatch] = []
+        private var pendingHistoryReplacements: [RuntimeIndexingBatch] = []
+        /// Batches an engine swap archived as cancelled while their engine was
+        /// still ending them. Their replayed start is ignored and their end
+        /// replaces the archive.
+        private var swapArchivedBatchIDs: Set<RuntimeIndexingBatchID> = []
         private var hasPendingActiveChange = false
         private var pendingAggregateRefresh = false
@@ -739,6 +763,10 @@ extension RuntimeBackgroundIndexingCoordinator {
 
             switch event {
             case .batchStarted(let batch):
+                // An engine swap archived this batch as cancelled and asked its engine to stop
+                // it; a subscription made after swapping back replays it as still under way. It
+                // is not running again — its end is what comes next.
+                guard !swapArchivedBatchIDs.contains(batch.id) else { break }
                 stagedBatches.append(batch)
                 hasPendingActiveChange = true
                 pendingAggregateRefresh = true
@@ -766,6 +794,12 @@ extension RuntimeBackgroundIndexingCoordinator {
                     hasPendingActiveChange = true
                 }
             case .batchFinished(let finished):
+                if swapArchivedBatchIDs.remove(finished.id) != nil {
+                    pendingHistoryReplacements.append(finished)
+                    outcome.requiresImmediateFlush = true
+                    outcome.shouldReloadEngineImages = true
+                    break
+                }
                 stagedBatches.removeAll { $0.id == finished.id }
                 documentBatchIDs.remove(finished.id)
                 pendingHistoryAdditions.append(finished)
@@ -776,6 +810,12 @@ extension RuntimeBackgroundIndexingCoordinator {
             case .batchCancelled(let cancelled):
                 // Cancellation always removes from active. Lands in history
                 // too so the user can review what got cancelled.
+                if swapArchivedBatchIDs.remove(cancelled.id) != nil {
+                    pendingHistoryReplacements.append(cancelled)
+                    outcome.requiresImmediateFlush = true
+                    outcome.shouldReloadEngineImages = true
+                    break
+                }
                 stagedBatches.removeAll { $0.id == cancelled.id }
                 documentBatchIDs.remove(cancelled.id)
                 pendingHistoryAdditions.append(cancelled)
@@ -823,10 +863,12 @@ extension RuntimeBackgroundIndexingCoordinator {
             let activeChanged = hasPendingActiveChange
             let aggregateChanged = pendingAggregateRefresh
             let historyAdditions = pendingHistoryAdditions
+            let historyReplacements = pendingHistoryReplacements
 
             hasPendingActiveChange = false
             pendingAggregateRefresh = false
             pendingHistoryAdditions = []
+            pendingHistoryReplacements = []
             hasScheduledFlush = false
 
             // Snapshot batches only when the flush will actually publish them
@@ -837,7 +879,8 @@ extension RuntimeBackgroundIndexingCoordinator {
                 activeChanged: activeChanged,
                 aggregateChanged: aggregateChanged,
                 batches: batches,
-                historyAdditions: historyAdditions
+                historyAdditions: historyAdditions,
+                historyReplacements: historyReplacements
             )
         }
@@ -850,6 +893,9 @@ extension RuntimeBackgroundIndexingCoordinator {
             lock.lock()
             defer { lock.unlock() }
             let drained = (activeBatches: stagedBatches, pendingHistory: pendingHistoryAdditions)
+            // The caller archives these as cancelled while their engine may still be ending
+            // them; see `applyEvent`.
+            swapArchivedBatchIDs.formUnion(stagedBatches.map(\.id))
             stagedBatches.removeAll()
             pendingHistoryAdditions.removeAll()
             hasPendingActiveChange = false
```

**复现测试（示例）**：新文件 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/RuntimeBackgroundIndexingStagingTests.swift`，直接按顺序把事件喂给 `StagingStore`，结果确定，不依赖切引擎的时机。修前，第一条断言会红，因为补发的 X 回到了进行中；第二条的 `historyAdditions.isEmpty` 也会红，因为历史又被追加了一次。`historyReplacements` 是新 API，要在修前单独验证红灯时，先去掉那一行断言。
```swift
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The indexing coordinator's staging across an engine swap and back: a batch the swap archived
/// is not brought back by the new subscription's replay, and its real end replaces the archive.
@Suite("RuntimeBackgroundIndexingStaging")
struct RuntimeBackgroundIndexingStagingTests {
    @Test("a batch archived by a swap and replayed after swapping back stays out of the active batches")
    func replayedArchivedBatchStaysInactive() {
        let staging = RuntimeBackgroundIndexingCoordinator.StagingStore()
        let batch = Self.runningBatch()
        _ = staging.applyEvent(.batchStarted(batch))
        _ = staging.snapshotForFlush()
        #expect(staging.drainForEngineSwap().activeBatches.map(\.id) == [batch.id])

        var replayed = batch
        replayed.isCancelled = true
        _ = staging.applyEvent(.batchStarted(replayed))

        #expect(!staging.snapshotForFlush().batches.contains { $0.id == batch.id })
    }

    @Test("the real end of an archived batch replaces the archive instead of adding a second entry")
    func endOfArchivedBatchReplacesArchive() {
        let staging = RuntimeBackgroundIndexingCoordinator.StagingStore()
        let batch = Self.runningBatch()
        _ = staging.applyEvent(.batchStarted(batch))
        _ = staging.snapshotForFlush()
        _ = staging.drainForEngineSwap()
        var replayed = batch
        replayed.isCancelled = true
        _ = staging.applyEvent(.batchStarted(replayed))
        _ = staging.snapshotForFlush()

        var ended = replayed
        ended.isFinished = true
        ended.items = ended.items.map { item in
            var cancelledItem = item
            cancelledItem.state = .cancelled
            return cancelledItem
        }
        _ = staging.applyEvent(.batchCancelled(ended))

        let snapshot = staging.snapshotForFlush()
        #expect(snapshot.historyAdditions.isEmpty)
        #expect(snapshot.historyReplacements.map(\.id) == [batch.id])
    }

    private static func runningBatch() -> RuntimeIndexingBatch {
        RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: "/Applications/Sample.app/Contents/MacOS/Sample",
            depth: 1,
            reason: .appLaunch,
            items: [
                RuntimeIndexingTaskItem(id: "/usr/lib/libobjc.A.dylib", resolvedPath: "/usr/lib/libobjc.A.dylib", state: .completed, hasPriorityBoost: false),
                RuntimeIndexingTaskItem(id: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", resolvedPath: nil, state: .running, hasPriorityBoost: false),
            ],
            isCancelled: false,
            isFinished: false
        )
    }
}
```

**同类**：`FindCorpusCoordinator` 也订阅同一条事件流，也会收到补发，但它只处理 `taskFinished`，不受影响。其余读这条流的地方只有 manager 自己的测试。

**工作量**：S。PR121.58 会删掉 `shouldReloadEngineImages`，两条一起落地时，以 PR121.58 为准去掉这里新增的那两行 `outcome.shouldReloadEngineImages = true`。


### PR121.58 N 个窗口时每个批次结束触发 N 次 reloadData

- **严重度**：Minor
- **审查编号**：C22 / AL2（C1-7）
- **状态**：方案待批，代码未改

**问题**：本 PR 把后台索引事件改成广播：每个订阅者都收到全部事件。于是共用同一个引擎的 N 个文档，每个文档的索引协调器都会收到同一个批次结束事件，并各自调用一次 `engine.reloadData(isReloadImageNodes: false)`（RuntimeBackgroundIndexingCoordinator.swift:173-180）。每次 reload 又会广播一次 `.fullReload`（RuntimeEngine.swift:614-622），落到全部 N 个窗口上：侧栏对象列表重载、`RuntimeInterfaceCache` 清空、always-index 重试泵各跑一遍。所以 N 个窗口时，一个批次结束会引起 N² 次侧栏重载和缓存清空。

**四问**：
- **复现**：开 3 个 My Mac 窗口，在 Settings 里打开后台索引（或加一条 Always Index）。每个批次结束时，每个窗口的侧栏会连续重载 3 次；在 `RuntimeEngine.reloadLocalData` 的日志里，一个批次结束能数到 3 条 "Reloading data"。
- **基线**：广播是本 PR 引入的。之前事件被多个读者瓜分，每个批次结束只触发一次 reload，同时也带来了别的问题。
- **影响**：只在多窗口共用一个引擎时出现，批次结束本身不频繁。启动时有多条 Always Index 时会集中出现，可能带来侧栏和内容区的反复刷新。严重度低，建议修。
- **历史**：
  - 广播本身是**有意为之**：find 提案决策日志 2026-09-29，以及 `Documentations/ResolvedIssues/2026-09-29-find-corpus-never-built-indexing-events-split.md`。
  - 那份 ResolvedIssue 的「行为变化」一节明确接受了「每个批次结束时各文档各发一次 reloadData」，但没有分析每次 reload 还会扇出到所有窗口。N² 这一层从来没有被记录或接受过。
  - 修它不改变文档化的意图：每个窗口仍然看到引擎上的全部批次。只是把那段文字改成新的事实。

**改法**：
- 把「批次结束后让引擎重读数据」从各文档的协调器挪到 Core 的 `RuntimeBackgroundIndexingManager.finalize`：
  - `RuntimeBackgroundIndexingEngineRepresenting` 加一个要求 `reloadDataAfterBackgroundIndexing()`，`RuntimeEngine` 的实现就是 `reloadData(isReloadImageNodes: false)`。
  - 每个引擎每个批次只 reload 一次，与窗口数无关，也与有没有订阅者无关：窗口关掉以后批次结束，也照样刷新一次。
  - 协调器删掉 `shouldReloadEngineImages` 这条路径，`handleEvent` 不再需要 `engine` 参数。
- 不采用的做法：
  - 只让 `documentBatchIDs` 里有这个批次的协调器去 reload——不够。manager 按根路径去重，Always Index 和主程序批次会把**同一个** id 返回给每个窗口，它们都算「拥有者」。
  - 在 `RuntimeEngine.reloadData` 里合并并发请求——影响所有调用方，面太大。
- 同批改两处文档：协调器里关于历史的注释（现在写的是「本文档索引过什么」，实际是本文档在它连过的引擎上看到的全部批次），以及上面那份 ResolvedIssue 的「行为变化」段。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingEngineRepresenting.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingEngineRepresenting.swift
@@ -45,4 +45,9 @@ protocol RuntimeBackgroundIndexingEngineRepresenting: AnyObject, Sendable {
                       ancestorRpaths: [String],
                       mainExecutablePath: String)
         async throws -> [(installName: String, resolvedPath: String?)]
+    /// Re-reads the engine's image data once a batch has ended: the images it
+    /// indexed change what the sidebar and the interface caches show. The
+    /// manager calls it once per batch, so every document watching the engine
+    /// hears one `.fullReload`, however many documents there are.
+    func reloadDataAfterBackgroundIndexing() async
 }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift
@@ -105,4 +105,8 @@ extension RuntimeEngine: RuntimeBackgroundIndexingEngineRepresenting {
         // Codable). Repack here.
         return entries.map { ($0.installName, $0.resolvedPath) }
     }
+
+    func reloadDataAfterBackgroundIndexing() async {
+        await reloadData(isReloadImageNodes: false)
+    }
 }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift
@@ -497,6 +497,14 @@ public actor RuntimeBackgroundIndexingManager {
         } else {
             emit(.batchFinished(state.batch))
         }
         activeBatches[id] = nil
+        // Once per batch, here rather than in each subscriber: every document on
+        // the engine hears every event, and each asking for its own reload made
+        // N windows reload N times each. The driving task is still running, so
+        // the engine is alive to be captured.
+        let engine = self.engine
+        Task {
+            await engine.reloadDataAfterBackgroundIndexing()
+        }
     }
 }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
@@ -158,25 +158,17 @@ public final class RuntimeBackgroundIndexingCoordinator {
             let stream = await engine.backgroundIndexingManager.events
             for await event in stream {
                 guard let self else { return }
-                self.handleEvent(event, on: engine)
+                self.handleEvent(event)
             }
         }
     }
 
     /// Off-main event entry point. Mutates the lock-protected staging state
     /// inline, then dispatches the minimal main-actor work the outcome
     /// requires (immediate flush for lifecycle events, scheduled flush for
-    /// task events, `engine.reloadData` for batch terminations).
-    nonisolated private func handleEvent(_ event: RuntimeIndexingEvent, on engine: RuntimeEngine) {
+    /// task events). The engine's reload after a batch ends is the manager's
+    /// own, once per batch for every document on the engine.
+    nonisolated private func handleEvent(_ event: RuntimeIndexingEvent) {
         let outcome = staging.applyEvent(event)
 
-        if outcome.shouldReloadEngineImages {
-            // Fire-and-forget: each finished/cancelled batch nudges the engine
-            // to reload its non-image-node data. Detached + capture so the
-            // dispatch isn't tied to coordinator isolation.
-            Task { [engine] in
-                await engine.reloadData(isReloadImageNodes: false)
-            }
-        }
-
         if outcome.requiresImmediateFlush {
@@ -300,7 +292,8 @@ public final class RuntimeBackgroundIndexingCoordinator {
         //    `finalize` would have emitted and land it in history. Finalized
         //    batches whose history hop was still waiting on the coalesce
         //    window are archived as-is. History itself survives the swap:
         //    entries are pure value snapshots with session-unique UUID ids,
-        //    and the popover history reads as "what this document indexed
-        //    this session", not as engine-scoped state. Only the user's
+        //    and the history reads as "what this document saw indexed this
+        //    session" — every batch on the engines it was on, its own and other
+        //    documents' alike — not as engine-scoped state. Only the user's
         //    Clear History empties it. Active batches must leave
@@ -690,5 +682,4 @@ extension RuntimeBackgroundIndexingCoordinator {
     fileprivate struct ApplyOutcome {
         var requiresImmediateFlush: Bool = false
         var didScheduleCoalescedFlush: Bool = false
-        var shouldReloadEngineImages: Bool = false
     }
@@ -772,7 +763,6 @@ extension RuntimeBackgroundIndexingCoordinator {
                 hasPendingActiveChange = true
                 pendingAggregateRefresh = true
                 outcome.requiresImmediateFlush = true
-                outcome.shouldReloadEngineImages = true
             case .batchCancelled(let cancelled):
                 // Cancellation always removes from active. Lands in history
                 // too so the user can review what got cancelled.
@@ -782,5 +772,4 @@ extension RuntimeBackgroundIndexingCoordinator {
                 hasPendingActiveChange = true
                 pendingAggregateRefresh = true
                 outcome.requiresImmediateFlush = true
-                outcome.shouldReloadEngineImages = true
             }
```

```diff
--- a/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/MockBackgroundIndexingEngine.swift
+++ b/RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/MockBackgroundIndexingEngine.swift
@@ -23,5 +23,6 @@ final class MockBackgroundIndexingEngine: RuntimeBackgroundIndexingEngineRepresenting,
     private var paths: [String: ProgrammedPath] = [:]
     private var loadOrder: [String] = []
     private var dependenciesCallLog: [DependenciesCall] = []
+    private var reloadCount = 0
     var mainExecutable: String = "/fake/MainApp"
 
@@ -40,4 +41,14 @@ final class MockBackgroundIndexingEngine: RuntimeBackgroundIndexingEngineRepresenting,
         return dependenciesCallLog
     }
 
+    func reloadDataCount() -> Int {
+        lock.lock(); defer { lock.unlock() }
+        return reloadCount
+    }
+
+    func reloadDataAfterBackgroundIndexing() async {
+        lock.lock(); defer { lock.unlock() }
+        reloadCount += 1
+    }
+
     func isImageIndexed(path: String) async -> Bool {
```

```diff
--- a/Documentations/ResolvedIssues/2026-09-29-find-corpus-never-built-indexing-events-split.md
+++ b/Documentations/ResolvedIssues/2026-09-29-find-corpus-never-built-indexing-events-split.md
@@ -74,4 +74,8 @@
 ### 行为变化
 
 多个文档共用一个引擎（My Mac）时，每个文档的索引弹窗都会看到这个引擎上的全部批次，每个批次结束时各文档各发一次
 `reloadData`。以前是各自只看到一部分，状态错乱。
+
+**2026-10 补记**：「各文档各发一次」实际是 N² 次——每次 `reloadData` 都广播 `.fullReload` 给全部 N 个窗口，侧栏重载与
+接口缓存清空各跑 N×N 次（PR #121 审查 C22）。批次结束后的那次 reload 已挪进 `RuntimeBackgroundIndexingManager.finalize`，
+每个引擎每个批次一次，与窗口数无关；每个窗口照旧看到全部批次。
```

**复现测试（示例）**：
- Application 层放在新文件 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/RuntimeBackgroundIndexingReloadTests.swift`。两个文档共用一个真实引擎，数一个批次结束后引擎广播了几次 `.fullReload`：修前是 2（两个协调器各发一次），修后是 1。
- Core 层在 `RuntimeBackgroundIndexingManagerTests` 里加一条，验证新约定：两个订阅者、一个批次，只 reload 一次。
```swift
import Combine
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What a batch's end costs the documents sharing its engine: one reload of the engine's data,
/// however many documents listen.
@Suite("RuntimeBackgroundIndexingReload", .serialized)
@MainActor
struct RuntimeBackgroundIndexingReloadTests {
    @Test("a batch's end reloads the engine once with two documents on it")
    func batchEndReloadsOnceForTwoDocuments() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeBackgroundIndexingReloadTests.twoDocuments")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let firstCoordinator = firstEnvironment.make { firstEnvironment.documentState.backgroundIndexingCoordinator }
        let secondCoordinator = secondEnvironment.make { secondEnvironment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((firstCoordinator, secondCoordinator)) {} }
        let reloadCounter = ReloadCounter()
        let subscription = engine.reloadDataPublisher.sink { _ in reloadCounter.increment() }
        defer { subscription.cancel() }

        // Foundation takes long enough to index that both coordinators hear the batch start.
        let batchID = await engine.backgroundIndexingManager.startBatch(rootImagePath: TestImages.foundation, depth: 0, maxConcurrency: 1, reason: .manual)
        _ = try await nextValue(from: firstCoordinator.historyObservable, timeout: 60) { $0.contains { $0.id == batchID } }
        _ = try await nextValue(from: secondCoordinator.historyObservable, timeout: 60) { $0.contains { $0.id == batchID } }
        try await Task.sleep(for: .milliseconds(500))

        #expect(reloadCounter.count == 1)
        await engine.stop()
    }
}

private final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reloadCount = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return reloadCount
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        reloadCount += 1
    }
}
```
```swift
// RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/RuntimeBackgroundIndexingManagerTests.swift
/// A batch's end makes the engine re-read its data once, however many subscribers listen —
/// each document on the engine used to ask for its own.
@Test func batchEndReloadsEngineDataOnce() async {
    let engine = keep(MockBackgroundIndexingEngine())
    engine.program(path: "/A", .init())
    let manager = RuntimeBackgroundIndexingManager(engine: engine)
    let firstRecorder = EventRecorder()
    let secondRecorder = EventRecorder()
    let firstRecording = firstRecorder.startRecording(await manager.events)
    let secondRecording = secondRecorder.startRecording(await manager.events)
    defer {
        firstRecording.cancel()
        secondRecording.cancel()
    }

    _ = await manager.startBatch(rootImagePath: "/A", depth: 0, maxConcurrency: 1, reason: .manual)

    #expect(await waitUntil { engine.reloadDataCount() >= 1 })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(engine.reloadDataCount() == 1)
}
```

**同类**：`RuntimeBackgroundIndexingEngineRepresenting` 只有 `RuntimeEngine` 和测试用的 Mock 两个实现，两处都在上面的 diff 里。`FindCorpusCoordinator` 收到批次事件后不会调 reload，不受影响。

**工作量**：M。与 PR121.57 改同一个 `applyEvent`：两条一起落地时，PR121.57 新增的 `shouldReloadEngineImages` 那两行以本条为准删掉。


### PR121.59 Report 树每 16 ms 整树重建，隐藏页也重建

- **严重度**：Minor（性能）
- **审查编号**：F3
- **状态**：方案待批，代码未改

**问题**：`ReportViewModel.transform` 用 `combineLatest` 把六路输入接到 `makeNodes`（ReportViewModel.swift:75-97）。任何一路一动——索引事件或语料进度，各自按 16 ms 合并——都会把整棵树重建一遍，并对每个节点重新 `configure`：100 条索引历史连同其下全部镜像行（一个主程序批次就有几百个镜像），再加 100 条语料历史。两层侧栏在建好时就各自创建并绑定了一个 Report 页（SidebarRootCoordinator.swift:32-34、SidebarRuntimeObjectCoordinator.swift:39-40），不管这一页看不看得见，所以后台索引期间两页都在每秒约 60 次地整树重建。

**四问**：
- **复现**：开着后台索引，让 Report 页不可见（选别的分页）。用 Instruments 的 Time Profiler 能看到 `makeNodes` 与 `ReportCellViewModel.update` 持续出现在主线程上，两个 ViewModel 实例各占一份。
- **基线**：本 PR 新引入（Report 页是本 PR 新加的）。
- **影响**：后台索引和语料构建进行时，主线程上有持续的无用功，历史越长越重；不影响正确性。建议修。
- **历史**：新代码。旧弹窗只在弹出时绑定，没有这个问题。

**改法**：
1. **按可见性门控**：
   - `Input` 用 `isVisible: Driver<Bool>` 替换 `appeared`。VC 由 `rx.viewWillAppear` 发 true、`rx.viewWillDisappear` 发 false，初值 false。
   - ViewModel 用 `flatMapLatest` 只在可见时订阅上游。变为可见时，`combineLatest` 会回放各路的最新值，立刻重建一次；这发生在 viewWillAppear，页面画出来之前就已经是最新的。
   - 可见的上升沿顺带做原来 `appeared` 做的 `refreshCoverage()`。
   - 分页上的活动标记来自 `DocumentState.reportActivity`，不经过这棵树，不受影响。
2. **按类别拆开**：索引类只由批次、历史和索引开关重建；语料类只由状态、跟踪集合、已结束构建和语料开关重建。cell ViewModel 的「本次没用到就丢」也按类别分开做，否则只重建一类时，会把另一类的 cell ViewModel 一起扔掉。
3. **历史子树记忆化**：历史条目是不变的快照，按批次标识或结束记录的标识缓存它的子树，只在第一次出现时构建和 `configure`。索引历史在复用前会比较快照是否相等，因为 PR121.57 的替换会让同一标识换成新快照。这一比较是值比较，不分配内存。代价是结束时间里的 "Today" 过了午夜不会自动变成 "Yesterday"；现在也只有别的东西触发重建时才会变。
4. 建树逻辑从泛型的 `ReportViewModel` 挪进非泛型的 `ReportTreeBuilder`，便于单测。`builtNodeCount` 是测试接缝，与 `StatefulOutlineView.expansionAutosavePersistCount` 同一做法。

下面的 diff 写在 PR121.55（`followedImagePaths`、`isFollowed`）、PR121.56（`showsItems(of:)`）、PR121.62（`FindScope.imageName`）、PR121.65（完整命名）之后：本条把这几条对 `makeNodes` 的改动一起搬进了 builder。ViewModel 里被删除的 `makeNodes` 按分叉点的原文列出。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportTreeBuilder.swift
@@ -0,0 +1,148 @@
+import Foundation
+import RuntimeViewerCore
+
+/// Builds the Report navigator's tree one kind of work at a time, and keeps what does not change.
+///
+/// The page used to rebuild the whole tree whenever any input moved, so a corpus build's progress
+/// — sixty times a second — rebuilt and reconfigured a hundred indexing batches with every image
+/// under them. Each kind is now rebuilt from its own inputs only, and finished work — a batch in
+/// the indexing history, an ended corpus build — is a snapshot whose subtree is built once and
+/// reused while the entry stays. A row that is rebuilt keeps its cell ViewModel, so a row on
+/// screen still updates in place.
+///
+/// Main thread only, like the `ReportViewModel` that owns it.
+final class ReportTreeBuilder {
+    /// The cell ViewModels of the rows rebuilt last time, by what they stand for.
+    private var cellViewModelsByIdentifier: [ReportNodeIdentifier: ReportCellViewModel] = [:]
+
+    /// The indexing history's subtrees by batch, with the snapshot each was built from: an engine
+    /// swap can put a batch's real end in place of the snapshot it archived.
+    private var historyBatchNodes: [RuntimeIndexingBatchID: (batch: RuntimeIndexingBatch, node: ReportNode)] = [:]
+
+    /// Ended corpus builds' rows by entry. An entry never changes once recorded.
+    private var finishedCorpusBuildNodes: [UUID: ReportNode] = [:]
+
+    /// Nodes built since the builder was made — a regression seam for the reuse above, as
+    /// `StatefulOutlineView.expansionAutosavePersistCount` is one for its coalescing.
+    package private(set) var builtNodeCount = 0
+
+    func indexingCategory(batches: [RuntimeIndexingBatch], history: [RuntimeIndexingBatch], isEnabled: Bool) -> ReportNode? {
+        var usedIdentifiers: Set<ReportNodeIdentifier> = []
+        var children: [ReportNode] = []
+        if !isEnabled {
+            children.append(makeNode(.turnedOff(.backgroundIndexing), usedIdentifiers: &usedIdentifiers) {
+                $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings")
+            })
+        }
+        // The manager appends batches as they start, and history is newest first already.
+        for batch in batches.reversed() {
+            children.append(makeBatchNode(batch, usedIdentifiers: &usedIdentifiers))
+        }
+        var historyBatchIdentifiers: Set<RuntimeIndexingBatchID> = []
+        for batch in history {
+            historyBatchIdentifiers.insert(batch.id)
+            if let cachedEntry = historyBatchNodes[batch.id], cachedEntry.batch == batch {
+                children.append(cachedEntry.node)
+            } else {
+                let node = makeBatchNode(batch, usedIdentifiers: &usedIdentifiers)
+                historyBatchNodes[batch.id] = (batch, node)
+                children.append(node)
+            }
+        }
+        historyBatchNodes = historyBatchNodes.filter { historyBatchIdentifiers.contains($0.key) }
+
+        var categoryNode: ReportNode?
+        if !children.isEmpty {
+            categoryNode = makeNode(.category(.backgroundIndexing), children: children, usedIdentifiers: &usedIdentifiers) {
+                $0.update(icon: ReportOutline.indexingIcon, title: "Background Indexing")
+            }
+        }
+        dropCellViewModels(of: .backgroundIndexing, except: usedIdentifiers)
+        return categoryNode
+    }
+
+    func corpusCategory(
+        states: [String: RuntimeInterfaceCorpusBuildState],
+        followedImagePaths: Set<String>,
+        finishedBuilds: [FindCorpusFinishedBuild],
+        isEnabled: Bool
+    ) -> ReportNode? {
+        var usedIdentifiers: Set<ReportNodeIdentifier> = []
+        var children: [ReportNode] = []
+        if !isEnabled {
+            children.append(makeNode(.turnedOff(.searchableInterfaces), usedIdentifiers: &usedIdentifiers) {
+                $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings")
+            })
+        }
+        // The image being printed first, then the waiting ones by name.
+        let activeBuilds = states.filter(\.value.isActive).sorted { leftEntry, rightEntry in
+            let leftIsBuilding = ReportOutline.isBuilding(leftEntry.value)
+            let rightIsBuilding = ReportOutline.isBuilding(rightEntry.value)
+            if leftIsBuilding != rightIsBuilding {
+                return leftIsBuilding
+            }
+            return FindScope.imageName(of: leftEntry.key) < FindScope.imageName(of: rightEntry.key)
+        }
+        for (imagePath, state) in activeBuilds {
+            children.append(makeNode(.corpusBuild(imagePath: imagePath), usedIdentifiers: &usedIdentifiers) {
+                ReportOutline.configure($0, forCorpusOf: imagePath, state: state, isFollowed: followedImagePaths.contains(imagePath))
+            })
+        }
+        var finishedBuildIdentifiers: Set<UUID> = []
+        for finishedBuild in finishedBuilds {
+            finishedBuildIdentifiers.insert(finishedBuild.id)
+            if let cachedNode = finishedCorpusBuildNodes[finishedBuild.id] {
+                children.append(cachedNode)
+            } else {
+                let node = makeNode(.finishedCorpusBuild(finishedBuild.id), usedIdentifiers: &usedIdentifiers) {
+                    ReportOutline.configure($0, for: finishedBuild)
+                }
+                finishedCorpusBuildNodes[finishedBuild.id] = node
+                children.append(node)
+            }
+        }
+        finishedCorpusBuildNodes = finishedCorpusBuildNodes.filter { finishedBuildIdentifiers.contains($0.key) }
+
+        var categoryNode: ReportNode?
+        if !children.isEmpty {
+            categoryNode = makeNode(.category(.searchableInterfaces), children: children, usedIdentifiers: &usedIdentifiers) {
+                $0.update(icon: ReportOutline.corpusIcon, title: "Searchable Interfaces")
+            }
+        }
+        dropCellViewModels(of: .searchableInterfaces, except: usedIdentifiers)
+        return categoryNode
+    }
+
+    private func makeBatchNode(_ batch: RuntimeIndexingBatch, usedIdentifiers: inout Set<ReportNodeIdentifier>) -> ReportNode {
+        var items: [ReportNode] = []
+        if ReportOutline.showsItems(of: batch) {
+            for item in batch.items {
+                items.append(makeNode(.indexingItem(batchID: batch.id, imagePath: item.id), usedIdentifiers: &usedIdentifiers) {
+                    ReportOutline.configure($0, for: item)
+                })
+            }
+        }
+        return makeNode(.indexingBatch(batch.id), children: items, usedIdentifiers: &usedIdentifiers) {
+            ReportOutline.configure($0, for: batch)
+        }
+    }
+
+    private func makeNode(
+        _ identifier: ReportNodeIdentifier,
+        children: [ReportNode] = [],
+        usedIdentifiers: inout Set<ReportNodeIdentifier>,
+        configure: (ReportCellViewModel) -> Void
+    ) -> ReportNode {
+        let cellViewModel = cellViewModelsByIdentifier[identifier] ?? ReportCellViewModel(identifier: identifier)
+        cellViewModelsByIdentifier[identifier] = cellViewModel
+        usedIdentifiers.insert(identifier)
+        configure(cellViewModel)
+        builtNodeCount += 1
+        return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
+    }
+
+    /// Drops the cell ViewModels of `category`'s rows that this rebuild did not use. The other
+    /// kind was not rebuilt, so its rows keep theirs; a reused finished row holds its own.
+    private func dropCellViewModels(of category: ReportCategory, except usedIdentifiers: Set<ReportNodeIdentifier>) {
+        cellViewModelsByIdentifier = cellViewModelsByIdentifier.filter { identifier, _ in
+            identifier.category != category || usedIdentifiers.contains(identifier)
+        }
+    }
+}
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportNode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportNode.swift
@@ -25,6 +25,17 @@ public enum ReportNodeIdentifier: Hashable, Sendable {
     case finishedCorpusBuild(UUID)
 }
 
+extension ReportNodeIdentifier {
+    /// The kind of work the row belongs to.
+    var category: ReportCategory {
+        switch self {
+        case .category(let category), .turnedOff(let category): category
+        case .indexingBatch, .indexingItem: .backgroundIndexing
+        case .corpusBuild, .finishedCorpusBuild: .searchableInterfaces
+        }
+    }
+}
+
 /// The trailing status of a row: the small spinner while its work runs, an issue mark once it went
 /// wrong — Xcode's `IDELogNavigatorStatusView`.
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -18,9 +18,10 @@ import RuntimeViewerSettings
 public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
     @MemberwiseInit(.public)
     public struct Input {
-        /// The page came on screen. The corpus store evicts without telling anyone, so the corpus
-        /// states are asked for again.
-        public let appeared: Signal<Void>
+        /// Whether the page is on screen. A page nobody sees builds no tree; coming on screen
+        /// builds it from the latest of every input, and asks for the corpus states again — the
+        /// store evicts without telling anyone.
+        public let isVisible: Driver<Bool>
         public let cancel: Signal<ReportNode>
         public let cancelAll: Signal<Void>
@@ -41,9 +42,8 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         public let hasHistory: Driver<Bool>
     }
 
-    /// The rows' cell ViewModels by what they stand for, kept across rebuilds so a row on screen
-    /// keeps its cell and updates in place. Rows that disappear are dropped on the next rebuild.
-    private var cellViewModelsByIdentifier: [ReportNodeIdentifier: ReportCellViewModel] = [:]
+    /// Builds the tree, one kind of work at a time, keeping cell ViewModels and finished rows.
+    private let treeBuilder = ReportTreeBuilder()
 
     @RxObserved
     private var allNodes: [ReportNode] = []
@@ -71,33 +71,55 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
     public func transform(_ input: Input) -> Output {
         let indexingCoordinator = documentState.backgroundIndexingCoordinator
         let corpusCoordinator = documentState.findCorpusCoordinator
+        let treeBuilder = treeBuilder
+        let isIndexingEnabled = $isIndexingEnabled.asObservable()
+        let isCorpusEnabled = $isCorpusEnabled.asObservable()
+        let isVisible = input.isVisible.asObservable().distinctUntilChanged()
 
-        Observable.combineLatest(
-            indexingCoordinator.batchesObservable,
-            indexingCoordinator.historyObservable,
-            corpusCoordinator.$buildStatesByImagePath.asObservable(),
-            corpusCoordinator.$finishedBuilds.asObservable(),
-            $isIndexingEnabled.asObservable(),
-            $isCorpusEnabled.asObservable()
-        )
-        .observe(on: MainScheduler.instance)
-        .subscribeOnNext { [weak self] batches, history, corpusStates, finishedBuilds, isIndexingEnabled, isCorpusEnabled in
-            guard let self else { return }
-            MainActor.assumeIsolated {
-                self.allNodes = self.makeNodes(
-                    batches: batches,
-                    history: history,
-                    corpusStates: corpusStates,
-                    finishedBuilds: finishedBuilds,
-                    isIndexingEnabled: isIndexingEnabled,
-                    isCorpusEnabled: isCorpusEnabled
-                )
+        isVisible
+            .flatMapLatest { isVisible -> Observable<[ReportNode]> in
+                // A page nobody sees builds nothing. Coming on screen replays the latest of every
+                // input, so the tree is current before the page is drawn.
+                guard isVisible else { return .empty() }
+                // Each kind is rebuilt from its own inputs only: a corpus build's progress leaves
+                // the indexing rows alone.
+                let indexingCategory = Observable.combineLatest(
+                    indexingCoordinator.batchesObservable,
+                    indexingCoordinator.historyObservable,
+                    isIndexingEnabled
+                )
+                .observe(on: MainScheduler.instance)
+                .map { batches, history, isIndexingEnabled in
+                    treeBuilder.indexingCategory(batches: batches, history: history, isEnabled: isIndexingEnabled)
+                }
+                let corpusCategory = Observable.combineLatest(
+                    corpusCoordinator.$buildStatesByImagePath.asObservable(),
+                    corpusCoordinator.$followedImagePaths.asObservable(),
+                    corpusCoordinator.$finishedBuilds.asObservable(),
+                    isCorpusEnabled
+                )
+                .observe(on: MainScheduler.instance)
+                .map { states, followedImagePaths, finishedBuilds, isCorpusEnabled in
+                    treeBuilder.corpusCategory(states: states, followedImagePaths: followedImagePaths, finishedBuilds: finishedBuilds, isEnabled: isCorpusEnabled)
+                }
+                return Observable.combineLatest(indexingCategory, corpusCategory) { indexingCategory, corpusCategory in
+                    [indexingCategory, corpusCategory].compactMap(\.self)
+                }
             }
-        }
-        .disposed(by: rx.disposeBag)
+            .bind(to: $allNodes)
+            .disposed(by: rx.disposeBag)
 
-        input.appeared.emitOnNext {
-            corpusCoordinator.refreshCoverage()
-        }
-        .disposed(by: rx.disposeBag)
+        isVisible
+            .filter(\.self)
+            .subscribeOnNext { _ in
+                corpusCoordinator.refreshCoverage()
+            }
+            .disposed(by: rx.disposeBag)
 
         input.cancel.emitOnNext { node in
@@ -161,68 +183,6 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         )
     }
 
-    // MARK: - Building the outline
-
-    private func makeNodes(
-        batches: [RuntimeIndexingBatch],
-        history: [RuntimeIndexingBatch],
-        corpusStates: [String: RuntimeInterfaceCorpusBuildState],
-        finishedBuilds: [FindCorpusFinishedBuild],
-        isIndexingEnabled: Bool,
-        isCorpusEnabled: Bool
-    ) -> [ReportNode] {
-        var usedIdentifiers: Set<ReportNodeIdentifier> = []
-        func node(_ identifier: ReportNodeIdentifier, children: [ReportNode] = [], configure: (ReportCellViewModel) -> Void) -> ReportNode {
-            let cellViewModel = cellViewModelsByIdentifier[identifier] ?? ReportCellViewModel(identifier: identifier)
-            cellViewModelsByIdentifier[identifier] = cellViewModel
-            usedIdentifiers.insert(identifier)
-            configure(cellViewModel)
-            return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
-        }
-
-        var indexingChildren: [ReportNode] = []
-        if !isIndexingEnabled {
-            indexingChildren.append(node(.turnedOff(.backgroundIndexing)) { $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings") })
-        }
-        // The manager appends batches as they start, and history is newest first already.
-        for batch in batches.reversed() + history {
-            let showsItems = !(batch.reason.category == .alwaysIndex && batch.items.count <= 1)
-            let items = showsItems ? batch.items.map { item in
-                node(.indexingItem(batchID: batch.id, imagePath: item.id)) { ReportOutline.configure($0, for: item) }
-            } : []
-            indexingChildren.append(node(.indexingBatch(batch.id), children: items) { ReportOutline.configure($0, for: batch) })
-        }
-
-        var corpusChildren: [ReportNode] = []
-        if !isCorpusEnabled {
-            corpusChildren.append(node(.turnedOff(.searchableInterfaces)) { $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings") })
-        }
-        // The image being printed first, then the waiting ones by name.
-        let activeBuilds = corpusStates.filter(\.value.isActive).sorted { lhs, rhs in
-            let lhsIsBuilding = ReportOutline.isBuilding(lhs.value)
-            let rhsIsBuilding = ReportOutline.isBuilding(rhs.value)
-            if lhsIsBuilding != rhsIsBuilding {
-                return lhsIsBuilding
-            }
-            return ReportOutline.imageName(of: lhs.key) < ReportOutline.imageName(of: rhs.key)
-        }
-        for (imagePath, state) in activeBuilds {
-            corpusChildren.append(node(.corpusBuild(imagePath: imagePath)) { ReportOutline.configure($0, forCorpusOf: imagePath, state: state) })
-        }
-        for finishedBuild in finishedBuilds {
-            corpusChildren.append(node(.finishedCorpusBuild(finishedBuild.id)) { ReportOutline.configure($0, for: finishedBuild) })
-        }
-
-        var nodes: [ReportNode] = []
-        if !indexingChildren.isEmpty {
-            nodes.append(node(.category(.backgroundIndexing), children: indexingChildren) { $0.update(icon: ReportOutline.indexingIcon, title: "Background Indexing") })
-        }
-        if !corpusChildren.isEmpty {
-            nodes.append(node(.category(.searchableInterfaces), children: corpusChildren) { $0.update(icon: ReportOutline.corpusIcon, title: "Searchable Interfaces") })
-        }
-        cellViewModelsByIdentifier = cellViewModelsByIdentifier.filter { usedIdentifiers.contains($0.key) }
-        return nodes
-    }
-
     // MARK: - Settings
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
@@ -16,9 +16,6 @@ import SnapKit
 final class ReportViewController<Route: Routable>: BaseEffectViewController<ReportViewModel<Route>>, NSMenuDelegate {
     // MARK: - Relays
 
-    /// The page has no control whose accessor says "came on screen".
-    private let appearedRelay = PublishRelay<Void>()
-
     /// The actions menu and the context menu are built on demand, so their items report here.
     private let cancelRelay = PublishRelay<ReportNode>()
@@ -161,18 +158,17 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         }
     }
 
-    override func viewDidAppear() {
-        super.viewDidAppear()
-        appearedRelay.accept(())
-    }
-
     // MARK: - Bindings
 
     override func setupBindings(for viewModel: ReportViewModel<Route>) {
         super.setupBindings(for: viewModel)
 
         let input = ReportViewModel<Route>.Input(
-            appeared: appearedRelay.asSignal(),
+            // Before the page is drawn, so the tree it shows is already current.
+            isVisible: Observable.merge(rx.viewWillAppear.map { true }, rx.viewWillDisappear.map { false })
+                .asDriver(onErrorJustReturn: false)
+                .startWith(false),
             cancel: cancelRelay.asSignal(),
             cancelAll: cancelAllRelay.asSignal(),
             clearHistory: clearHistoryRelay.asSignal(),
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportViewModelTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportViewModelTests.swift
@@ -26,10 +26,10 @@ struct ReportViewModelTests {
         let viewModel: ReportViewModel<SidebarRootRoute>
         let output: ReportViewModel<SidebarRootRoute>.Output
 
-        init(documentState: DocumentState, filterString: Driver<String> = .just(""), showsOnlyInProgress: Driver<Bool> = .just(false)) {
+        init(documentState: DocumentState, isVisible: Driver<Bool> = .just(true), filterString: Driver<String> = .just(""), showsOnlyInProgress: Driver<Bool> = .just(false)) {
             viewModel = ReportViewModel(documentState: documentState, router: router)
             output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
-                appeared: .empty(),
+                isVisible: isVisible,
                 cancel: cancelRelay.asSignal(),
                 cancelAll: cancelAllRelay.asSignal(),
                 clearHistory: clearHistoryRelay.asSignal(),
```

**复现测试（示例）**：这是性能项，用计数来验证。
- 测试 1 放在 `ReportViewModelTests`：页面不可见时不建树，变为可见后立刻建。
- 测试 2 放在新文件 `ReportTreeBuilderTests.swift`：用 builder 的新建节点计数证明，语料进度只重建运行中的那一行和类别行，历史一行都不重建。
- 两条测试依赖新的输入和新的 builder，修前无法编译，所以它们是防回退的护栏，不是修前的红灯。
- 修前与修后的差别用 signpost 量：给 `indexingCategory` / `corpusCategory` 包 `#signpostInterval`（ViewModel 是泛型类型，按全局规则可以直接贴 `@Signpostable`），后台索引时录一次 Instruments 的 os_signpost。修前是两页各约每秒 60 次整树重建，修后隐藏时为 0。
```swift
// ReportViewModelTests.swift
@Test("a page nobody sees builds no tree, and builds it as soon as it comes on screen")
func hiddenPageBuildsNoTree() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.hiddenPage")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    // Both turned off: a visible page shows their two rows at once.
    environment.settings.indexing.isEnabled = false
    environment.settings.search.isCorpusEnabled = false
    let visibility = BehaviorRelay<Bool>(value: false)
    let page = environment.make { Page(documentState: environment.documentState, isVisible: visibility.asDriver()) }
    defer { withExtendedLifetime(page) {} }

    #expect(try await values(from: page.output.nodes, during: 0.5).allSatisfy(\.isEmpty))

    visibility.accept(true)

    let nodes = try await nextValue(from: page.output.nodes) { !$0.isEmpty }
    #expect(nodes.map(\.identifier) == [.category(.backgroundIndexing), .category(.searchableInterfaces)])
    await engine.stop()
}
```
```swift
// RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportTreeBuilderTests.swift
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What a rebuild of the Report tree builds: only what changed. A finished batch or corpus build
/// is built once, and one kind of work's update leaves the other kind alone.
@Suite("ReportTreeBuilder")
@MainActor
struct ReportTreeBuilderTests {
    @Test("a corpus build's progress rebuilds its own row and its category, nothing else")
    func progressRebuildsOnlyTheRunningBuild() {
        let builder = ReportTreeBuilder()
        let imagePath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        let finishedBuilds = (0 ..< 100).map { _ in
            FindCorpusFinishedBuild(imagePath: "/usr/lib/libobjc.A.dylib", outcome: .cancelled, finishedAt: Date())
        }
        _ = builder.indexingCategory(batches: [], history: (0 ..< 100).map { _ in Self.finishedBatch(imageCount: 50) }, isEnabled: true)
        _ = builder.corpusCategory(states: [imagePath: .building(.init(built: 0, total: 100))], followedImagePaths: [imagePath], finishedBuilds: finishedBuilds, isEnabled: true)
        let builtNodeCountAfterFirstBuild = builder.builtNodeCount

        for builtCount in 1 ... 60 {
            _ = builder.corpusCategory(states: [imagePath: .building(.init(built: builtCount, total: 100))], followedImagePaths: [imagePath], finishedBuilds: finishedBuilds, isEnabled: true)
        }

        #expect(builder.builtNodeCount - builtNodeCountAfterFirstBuild == 60 * 2)
    }

    @Test("an unchanged indexing history is not rebuilt")
    func unchangedHistoryIsReused() {
        let builder = ReportTreeBuilder()
        let history = (0 ..< 100).map { _ in Self.finishedBatch(imageCount: 50) }
        _ = builder.indexingCategory(batches: [], history: history, isEnabled: true)
        let builtNodeCountAfterFirstBuild = builder.builtNodeCount

        let category = builder.indexingCategory(batches: [], history: history, isEnabled: true)

        #expect(builder.builtNodeCount - builtNodeCountAfterFirstBuild == 1)
        #expect(category?.children.count == 100)
    }

    private static func finishedBatch(imageCount: Int) -> RuntimeIndexingBatch {
        RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: "/Applications/Sample.app/Contents/MacOS/Sample",
            depth: 1,
            reason: .appLaunch,
            items: (0 ..< imageCount).map { imageIndex in
                RuntimeIndexingTaskItem(id: "/usr/lib/libSample\(imageIndex).dylib", resolvedPath: nil, state: .completed, hasPriorityBoost: false)
            },
            isCancelled: false,
            isFinished: true
        )
    }
}
```

**同类**：Find 页也是两层各建一份、始终绑定，每来一批结果就整树重建，由 PR121.48 / PR121.49 处理。如果两边都采用「可见才订阅」，`isVisible` 的取法（`rx.viewWillAppear` / `rx.viewWillDisappear`）最好统一。`rx.viewWillAppear` 依靠 `methodInvoked` 拦截，仓库里还没有泛型 VC 用过它，改完需要实际跑一次，确认会触发。

**工作量**：M。最后做：依赖 PR121.53、PR121.55、PR121.56、PR121.62、PR121.65，并取代 PR121.64 里关于 `appeared` 的那一半。


### PR121.60 AggregateState.progress 已无人读却每次刷新都遍历

- **严重度**：Cleanup
- **审查编号**：S8
- **状态**：方案待批，代码未改

**问题**：`RuntimeBackgroundIndexingCoordinator.AggregateState` 里的 `progress` 和 `hasAnyFailure` 原本给 toolbar 弹窗用（显示「37% complete」和失败标记）。本 PR 删掉弹窗后，只剩 `DocumentState.reportActivity` 还在读 `hasActiveBatch`（DocumentState.swift:222）。但 `refreshAggregate` 仍然在每次 16 ms 的刷新里遍历所有进行中批次的全部镜像，去算失败数和进度（RuntimeBackgroundIndexingCoordinator.swift:229-245）。任务级事件（某个镜像开始或结束）也都会触发这次遍历。

**四问**：
- **复现**：读代码即可确认，`progress` 和 `hasAnyFailure` 在仓库里没有任何读取方。
- **基线**：字段本身是基线就有的，变成死代码是本 PR 删掉弹窗造成的。
- **影响**：每次刷新做一遍 O(镜像数) 的无用遍历，量不大。属于清理，建议顺手改。
- **历史**：弹窗删除时没有一起收拾它。

**改法**：
- `AggregateState` 换成一个布尔值 `hasActiveBatch`，等价于「进行中的批次不为空」，计算是 O(1)。
- 任务级事件不再标记 aggregate 需要刷新；只有批次开始、结束和取消才会改变这个值。
- `DocumentState` 改为读 `hasActiveBatchObservable`。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
@@ -18,17 +18,6 @@ public final class RuntimeBackgroundIndexingCoordinator {
     /// can still manually clear via `clearHistory()`.
     private static let maxHistoryEntries = 100
 
-    public struct AggregateState: Equatable, Sendable {
-        public var hasActiveBatch: Bool
-        public var hasAnyFailure: Bool
-        public var progress: Double?   // 0...1, nil when idle
-
-        public init(hasActiveBatch: Bool, hasAnyFailure: Bool, progress: Double?) {
-            self.hasActiveBatch = hasActiveBatch
-            self.hasAnyFailure = hasAnyFailure
-            self.progress = progress
-        }
-    }
-
     private unowned let documentState: DocumentState
@@ -41,9 +30,9 @@ public final class RuntimeBackgroundIndexingCoordinator {
 
     private let batchesRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
     private let historyRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
-    private let aggregateRelay = BehaviorRelay<AggregateState>(
-        value: .init(hasActiveBatch: false, hasAnyFailure: false, progress: nil)
-    )
+    /// Whether a batch is under way — what the Report navigator's tab marks. The rest of what the
+    /// toolbar popover used to show (progress, failures) went with it.
+    private let hasActiveBatchRelay = BehaviorRelay<Bool>(value: false)
 
     /// Authoritative staging state for in-flight batches plus the dirty flags
@@ -108,8 +97,8 @@ public final class RuntimeBackgroundIndexingCoordinator {
         batchesRelay.asObservable()
     }
 
-    public var aggregateStateObservable: Observable<AggregateState> {
-        aggregateRelay.asObservable()
+    public var hasActiveBatchObservable: Observable<Bool> {
+        hasActiveBatchRelay.asObservable()
     }
 
     public var historyObservable: Observable<[RuntimeIndexingBatch]> {
@@ -208,7 +197,7 @@ public final class RuntimeBackgroundIndexingCoordinator {
             batchesRelay.accept(snapshot.batches)
         }
         if snapshot.aggregateChanged {
-            refreshAggregate(batches: snapshot.batches)
+            refreshHasActiveBatch(batches: snapshot.batches)
         }
         // Now safe to push history: subscribers see (new batches without
         // finished, new history with finished) — a fully consistent state.
@@ -226,23 +215,11 @@ public final class RuntimeBackgroundIndexingCoordinator {
         historyRelay.accept(updatedHistory)
     }
 
-    private func refreshAggregate(batches: [RuntimeIndexingBatch]) {
-        let hasActive = !batches.isEmpty
-        let hasFailure = batches.contains { batch in
-            batch.items.contains { item in
-                if case .failed = item.state { return true }
-                return false
-            }
-        }
-        let totalItems = batches.reduce(0) { $0 + $1.totalCount }
-        let doneItems = batches.reduce(0) { $0 + $1.finishedCount }
-        let progress: Double? = totalItems > 0
-            ? Double(doneItems) / Double(totalItems)
-            : nil
-        aggregateRelay.accept(
-            .init(hasActiveBatch: hasActive, hasAnyFailure: hasFailure,
-                  progress: progress))
+    private func refreshHasActiveBatch(batches: [RuntimeIndexingBatch]) {
+        let hasActiveBatch = !batches.isEmpty
+        if hasActiveBatchRelay.value != hasActiveBatch {
+            hasActiveBatchRelay.accept(hasActiveBatch)
+        }
     }
 
     // MARK: - Engine swap (source switch)
@@ -308,7 +285,7 @@ public final class RuntimeBackgroundIndexingCoordinator {
         //    see the ordering note on `flushPendingUpdates`.
         let drained = staging.drainForEngineSwap()
         batchesRelay.accept([])
-        refreshAggregate(batches: [])
+        refreshHasActiveBatch(batches: [])
         for batch in drained.pendingHistory {
             appendToHistory(batch)
         }
@@ -747,15 +724,13 @@ extension RuntimeBackgroundIndexingCoordinator {
                 if mutateTaskItemLocked(batchID: id, path: path, { item in
                     item.state = .running
                 }) {
                     hasPendingActiveChange = true
-                    pendingAggregateRefresh = true
                 }
             case .taskFinished(let id, let path, let result):
                 if mutateTaskItemLocked(batchID: id, path: path, { item in
                     item.state = result
                 }) {
                     hasPendingActiveChange = true
-                    pendingAggregateRefresh = true
                 }
             case .taskPrioritized(let id, let path):
-                // Priority boost doesn't change progress / hasFailure /
-                // hasActive, so we skip the aggregate refresh.
+                // Only a batch starting or ending changes whether one is
+                // active; task events skip that refresh.
                 if mutateTaskItemLocked(batchID: id, path: path, { item in
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
@@ -219,7 +219,7 @@ public final class DocumentState {
     /// from the same answer.
     public var reportActivity: Driver<Bool> {
         Driver.combineLatest(
-            backgroundIndexingCoordinator.aggregateStateObservable.map(\.hasActiveBatch).asDriver(onErrorJustReturn: false),
+            backgroundIndexingCoordinator.hasActiveBatchObservable.asDriver(onErrorJustReturn: false),
             findCorpusCoordinator.hasActiveBuild
         ) { hasActiveBatch, hasActiveBuild in
             hasActiveBatch || hasActiveBuild
```

**复现测试（示例）**：行为不变，不需要新测试。现有的 `ReportViewModelTests.activityFollowsWorkInProgress` 覆盖了 `reportActivity` 随批次出现和消失的行为。`pendingAggregateRefresh` 与 `aggregateChanged` 两个名字仍然保留，只是任务级事件不再置位它们。

**同类**：仓库里没有别的读取方（`grep -rn 'aggregateStateObservable\|hasAnyFailure'` 只有这两处）。

**工作量**：S。和 PR121.57、PR121.58 改的是同一个文件，按编号顺序落地时注意合并。


### PR121.61 手写的 withObservationTracking 循环

- **严重度**：Cleanup
- **审查编号**：R4
- **状态**：方案待批，代码未改

**问题**：`ReportViewModel.registerSettingsObservation`（ReportViewModel.swift:237-252）手写了一个「`withObservationTracking` 触发后再注册自己」的循环来跟踪两个开关。项目里已有现成的 `Observable.tracking`（RuntimeViewerArchitectures/Observable+Tracking.swift），它把同样的事包成一个可以随 dispose bag 释放的 Rx 序列，`ContentTextViewModel` 和 `ResolvedThemeStream` 都在用。手写版本没有释放点，只靠 `[weak self]` 在 ViewModel 释放后才停下。

**四问**：
- **复现**：读代码即可确认，没有行为缺陷。
- **基线**：本 PR 新代码。
- **影响**：只是重复造轮子；属于清理，建议顺手改。
- **历史**：`Observable.tracking` 的文档专门写了两个坑——「依赖要在外面解析一次」「首次读要包 `MainActor.assumeIsolated`」。手写版本恰好绕开了这两个坑，但代价是要自己维护一个重注册循环。

**改法**：
- 改用 `Observable.tracking` 读出两个开关，合成一个小结构体，`distinctUntilChanged` 后写回两个 `@RxObserved` 状态，订阅挂在 `rx.disposeBag` 上。
- 写法照 `ContentTextViewModel`：依赖先在外面取一次（ViewModel 自己的 `settings`）；读值包在 `MainActor.assumeIsolated` 里，因为首次读是同步的。
- 首个值在订阅时同步到达，原来 `bootstrapSettingsObservation` 里那两行初值赋值可以一并删掉。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -226,29 +226,34 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
 
     // MARK: - Settings
 
+    /// The two switches the outline shows a "Turned off in Settings" row for.
+    private struct FeatureSwitches: Equatable {
+        let isIndexingEnabled: Bool
+        let isCorpusEnabled: Bool
+    }
+
     private func bootstrapSettingsObservation() {
         #if canImport(RuntimeViewerSettings)
-        isIndexingEnabled = settings.indexing.isEnabled
-        isCorpusEnabled = settings.search.isCorpusEnabled
-        registerSettingsObservation()
-        #endif
-    }
-
-    #if canImport(RuntimeViewerSettings)
-    /// `withObservationTracking` fires once, so the observation registers itself again on every
-    /// change.
-    private func registerSettingsObservation() {
-        withObservationTracking {
-            _ = settings.indexing.isEnabled
-            _ = settings.search.isCorpusEnabled
-        } onChange: { [weak self] in
-            Task { @MainActor [weak self] in
-                guard let self else { return }
-                self.isIndexingEnabled = self.settings.indexing.isEnabled
-                self.isCorpusEnabled = self.settings.search.isCorpusEnabled
-                self.registerSettingsObservation()
+        // Resolved once: `Observable.tracking` re-arms on a main-queue hop where the dependency
+        // context is gone. This is `ViewModel`'s own `settings`, resolved by `super.init`.
+        let trackedSettings = settings
+        Observable<FeatureSwitches>
+            .tracking {
+                // Main-actor state read from `tracking`'s synchronous first access, as
+                // `ContentTextViewModel` reads the transformer.
+                MainActor.assumeIsolated {
+                    FeatureSwitches(isIndexingEnabled: trackedSettings.indexing.isEnabled, isCorpusEnabled: trackedSettings.search.isCorpusEnabled)
+                }
+            }
+            .distinctUntilChanged()
+            .subscribeOnNext { [weak self] featureSwitches in
+                guard let self else { return }
+                isIndexingEnabled = featureSwitches.isIndexingEnabled
+                isCorpusEnabled = featureSwitches.isCorpusEnabled
             }
-        }
+            .disposed(by: rx.disposeBag)
+        #endif
     }
-    #endif
 }
```

**复现测试（示例）**：行为不变，不需要新测试。现有的 `ReportViewModelTests.turnedOffFeatureRow` 覆盖了「开关关闭时显示一行、重新打开后消失」，正好走这条订阅的初值和后续变化两条路径。

**同类**：
- 本 PR 里 `FindCorpusCoordinator.subscribeToSettings`（FindCorpusCoordinator.swift:452 一带）也是手写循环。但它在协调器里，不是 Rx ViewModel，也没有 dispose bag 可挂，可以不改。
- `RuntimeBackgroundIndexingCoordinator.subscribeToSettings` 是基线就有的，同理。

**工作量**：S。


### PR121.62 镜像显示名有三份实现

- **严重度**：Cleanup
- **审查编号**：R8
- **状态**：方案待批，代码未改

**问题**：「镜像怎么显示名字」这件事，本 PR 里写了三处，结果还不止一种：
- `ReportOutline.imageName(of:)`（ReportViewModel.swift:395）和 `FindScope.imageName(of:)`（FindMode.swift:189）都取路径最后一段，保留扩展名，比如 "libobjc.A.dylib"。
- `FindSession.swift:457` 在摘要栏里又内联写了一遍同样的逻辑。
- Find 结果行的副标题用的是 `RuntimeObject.imageName`，会去掉扩展名，变成 "libobjc.A"（FindResultNode.swift:117、131）。

于是同一个镜像在范围选择器、Report 页、摘要栏里叫 "libobjc.A.dylib"，在结果行里叫 "libobjc.A"。

**四问**：
- 复现：在 Find 里搜一个 libobjc 里的类型，结果行副标题显示 "libobjc.A"；同一镜像在 Report 页显示 "libobjc.A.dylib"。
- 基线：本 PR 新代码；`RuntimeObject.imageName` 是基线就有的。
- 影响：只是显示不一致，加上重复实现。属于清理，建议顺手改。
- 历史：Report 页照抄了 Find 的写法，没有复用。

**改法**：
- 全部改用 `FindScope.imageName(of:)` 这一处实现。它的文档注释从「the navigator」改成「the navigators」，删掉 `ReportOutline.imageName`，摘要栏的内联写法也改为调用它。
- Report 依赖 `FindScope` 只是借用同一个模块里的一个静态函数。如果更想让它在中立的位置，可以把函数挪进一个新的 `RuntimeImageDisplayName` 枚举，调用点多出 6 处 Find 文件，行为不变。
- **拍板**：统一为带扩展名的文件名（推荐，与范围选择器、Report、摘要栏一致；Xcode 的导航器也显示文件名）。Find 结果行副标题是否跟着改由 PR121.43 一带的 Find 结果行条目决定；若改，就把那两处 `object.imageName` 换成 `FindScope.imageName(of: object.imagePath)`。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindMode.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindMode.swift
@@ -185,7 +185,8 @@ public enum FindScope: Hashable, Sendable {
     /// accents every scope but the workspace.
     public var isAccented: Bool { self != .allIndexedImages }
 
-    /// An image's name as the navigator shows it: its file name.
+    /// An image's name as the navigators show it — Find's scope, results and summary, and the
+    /// Report navigator: its file name, extension included.
     public static func imageName(of imagePath: String) -> String {
         (imagePath as NSString).lastPathComponent
     }
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift
@@ -454,7 +454,7 @@ public final class FindSession {
             }
             .min { $0.imagePath < $1.imagePath }
         if let building, building.progress.total > 0 {
-            let imageName = (building.imagePath as NSString).lastPathComponent
+            let imageName = FindScope.imageName(of: building.imagePath)
             text += " · building \(imageName) \(building.progress.built * 100 / building.progress.total)%"
         }
         return text
```

```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -204,7 +204,7 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
             if lhsIsBuilding != rhsIsBuilding {
                 return lhsIsBuilding
             }
-            return ReportOutline.imageName(of: lhs.key) < ReportOutline.imageName(of: rhs.key)
+            return FindScope.imageName(of: lhs.key) < FindScope.imageName(of: rhs.key)
         }
         for (imagePath, state) in activeBuilds {
             corpusChildren.append(node(.corpusBuild(imagePath: imagePath)) { ReportOutline.configure($0, forCorpusOf: imagePath, state: state) })
@@ -307,7 +307,7 @@ enum ReportOutline {
             detail = "Cancelled"
             status = .none
         }
-        cellViewModel.update(icon: icon(forImagePath: item.id), title: imageName(of: item.id), detail: detail, status: status, toolTip: item.id, isInProgress: !item.state.isTerminal)
+        cellViewModel.update(icon: icon(forImagePath: item.id), title: FindScope.imageName(of: item.id), detail: detail, status: status, toolTip: item.id, isInProgress: !item.state.isTerminal)
     }
 
     static func configure(_ cellViewModel: ReportCellViewModel, forCorpusOf imagePath: String, state: RuntimeInterfaceCorpusBuildState) {
@@ -321,7 +321,7 @@ enum ReportOutline {
             detail = "Waiting"
             status = .none
         }
-        cellViewModel.update(icon: icon(forImagePath: imagePath), title: imageName(of: imagePath), detail: detail, status: status, toolTip: imagePath, isCancellable: true, isInProgress: true)
+        cellViewModel.update(icon: icon(forImagePath: imagePath), title: FindScope.imageName(of: imagePath), detail: detail, status: status, toolTip: imagePath, isCancellable: true, isInProgress: true)
     }
 
     static func configure(_ cellViewModel: ReportCellViewModel, for finishedBuild: FindCorpusFinishedBuild) {
@@ -344,7 +344,7 @@ enum ReportOutline {
             detail = time.isEmpty ? "Cancelled" : "Cancelled · \(time)"
             status = .none
         }
-        cellViewModel.update(icon: icon(forImagePath: finishedBuild.imagePath), title: imageName(of: finishedBuild.imagePath), detail: detail, status: status, toolTip: toolTip)
+        cellViewModel.update(icon: icon(forImagePath: finishedBuild.imagePath), title: FindScope.imageName(of: finishedBuild.imagePath), detail: detail, status: status, toolTip: toolTip)
     }
 
     // MARK: - Filtering
@@ -392,10 +392,6 @@ enum ReportOutline {
         imagePath.contains(".framework/") ? RuntimeImageNode.frameworkIcon : RuntimeImageNode.imageIcon
     }
 
-    static func imageName(of imagePath: String) -> String {
-        (imagePath as NSString).lastPathComponent
-    }
-
     static func title(for reason: RuntimeIndexingBatchReason) -> String {
         switch reason {
         case .appLaunch:
```

**复现测试（示例）**：行为不变（三处实现原本结果相同），不需要新测试。现有的 `ReportViewModelTests.finishedWorkUnderItsKind`（断言标题为 "libobjc.A.dylib" 与 "libSystem.B.dylib"）和 `FindScopeChooserViewModelTests` 覆盖。如果拍板时决定让 Find 结果行副标题也带扩展名，就在 Find 结果行那一条的测试里断言副标题为 "libobjc.A.dylib"——修前是 "libobjc.A"。

**同类**：
- `FindSession.swift:457` 的内联写法（已在上面的 diff 里）。
- `RuntimeObject.imageName`（去掉扩展名）是 Core 的公共 API，侧栏等别处也在用，不动；只是 Find 结果行不该用它来显示镜像名。

**工作量**：S。与 PR121.55、PR121.59、PR121.65 改同一个文件中相邻的几行，按编号顺序落地时注意合并。


### PR121.63 BatchExportingProgressRowViewModel.State 不是 Equatable

- **严重度**：Cleanup
- **审查编号**：CV3
- **状态**：方案待批，代码未改

**问题**：本 PR 把批量导出进度行的显示状态合并成一个 `State`，挂在单个 `@RxObserved` 上。但 `State` 没有实现 `Equatable`，所以 `updateState` 不管内容是否真的变了，每次都赋值、每次都发事件（BatchExportingProgressRowViewModel.swift:102-106）。cell 的 `applyState` 收到后，会把 tooltip、图标、文字、进度条全部重设一遍（BatchExportingProgressViewController.swift:217-265）。本 PR 在 0005 补记里刚定下的规矩是「只在变了时整体赋值一次，cell 只重设变了的部分」；同批改过的另一种行 `BatchExportingImageSelectionCellViewModel` 已经做到了，这一种漏了。

**四问**：
- **复现**：读代码可确认。导出时，`updatePhase` 用相同文本连续调用、或者两次进度相同，都会让 cell 白白重设一遍所有部件。
- **基线**：本 PR 新引入（12e1227b）。
- **影响**：多一些主线程上的视图更新，看不出效果上的差别。属于规范类问题，建议顺手改。
- **历史**：同一提交按 0005 改了三种行，这一种的 `State` 没加 `Equatable`。

**改法**：
- `Status` 和 `State` 加上 `Equatable`。`Status.succeeded` 带的 `RuntimeInterfaceExportResult` 是 Core 的类型，要一起加 `Equatable`，能自动合成。
- `updateState` 在新旧状态相等时不赋值，和 `ReportCellViewModel.update` 的做法一致。
- cell 只在 `objectFailures` 变化时重设 tooltip，它是 `applyState` 里唯一一项与状态分支无关、每次都重设的部件；其余部件随状态分支变化，本来就要设。
- **拍板**：这个类在 App target 里，而 App target 没有单元测试 target，写不出红绿测试。两个选择：
  - 接受只靠代码审查（推荐）；
  - 为了能测，把这个行 ViewModel 挪进 `RuntimeViewerApplication`，再照 `ReportCellViewModelTests` 写——不建议只为这个就搬。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportEvent.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportEvent.swift
@@ -19,7 +19,7 @@ public enum RuntimeInterfaceExportEvent: Sendable {
     }
 }
 
-public struct RuntimeInterfaceExportResult: Sendable {
+public struct RuntimeInterfaceExportResult: Sendable, Equatable {
     public let succeeded: Int
     public let failed: Int
     public let totalDuration: TimeInterval
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BatchExporting/BatchExportingProgressRowViewModel.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BatchExporting/BatchExportingProgressRowViewModel.swift
@@ -4,7 +4,7 @@ import RuntimeViewerArchitectures
 import RuntimeViewerCore
 
 final class BatchExportingProgressRowViewModel: CellViewModel {
-    enum Status: Sendable {
+    enum Status: Sendable, Equatable {
         case queued
         case running
         case succeeded(RuntimeInterfaceExportResult)
@@ -15,7 +15,7 @@ final class BatchExportingProgressRowViewModel: CellViewModel {
     /// image the engine lists, after Select All — and every `@RxObserved` a cell binds costs a
     /// relay with a lock of its own for as long as the row exists (proposal
     /// 0005-cellvm-appearance-single-observed).
-    struct State {
+    struct State: Equatable {
         var status: Status = .queued
 
         /// Fraction of the current phase that is done. Each phase — every indexing
@@ -96,12 +96,14 @@ final class BatchExportingProgressRowViewModel: CellViewModel {
         }
     }
 
-    /// Applies a transition to a copy and publishes it in one assignment. `@RxObserved` sends an
-    /// event for every assignment, so setting the fields one by one would redraw the cell once
-    /// per field.
+    /// Applies a transition to a copy and publishes it in one assignment, and only when it
+    /// changed. `@RxObserved` sends an event for every assignment, so setting the fields one by
+    /// one, or republishing what the row already shows, would redraw the cell for nothing.
     private func updateState(_ transition: (inout State) -> Void) {
         var newState = state
         transition(&newState)
-        state = newState
+        if newState != state {
+            state = newState
+        }
     }
 }
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BatchExporting/BatchExportingProgressViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BatchExporting/BatchExportingProgressViewController.swift
@@ -128,6 +128,9 @@ extension BatchExportingProgressViewController {
         }
 
         private var isSymbolEffectRunning = false
+
+        /// The failures the tooltip was last built from; `nil` until this row's first state.
+        private var appliedObjectFailures: [BatchExportingObjectFailure]?
 
         override func setup() {
             super.setup()
@@ -171,6 +174,7 @@ extension BatchExportingProgressViewController {
 
         func bind(to rowViewModel: BatchExportingProgressRowViewModel) {
             rx.disposeBag = DisposeBag()
+            appliedObjectFailures = nil
 
             installFreshProgressBar()
             nameLabel.stringValue = rowViewModel.image.name
@@ -215,7 +219,10 @@ extension BatchExportingProgressViewController {
         }
 
         private func applyState(_ state: BatchExportingProgressRowViewModel.State) {
-            toolTip = state.objectFailures.exportFailureTooltip
+            if appliedObjectFailures != state.objectFailures {
+                appliedObjectFailures = state.objectFailures
+                toolTip = state.objectFailures.exportFailureTooltip
+            }
             switch state.status {
             case .queued:
                 statusIcon.image = .symbol(systemName: .circle)
```

**复现测试（示例）**：
- 行为不变，只是少发事件。App target 没有单元测试 target，所以没有新测试（见上面的拍板）。
- 如果选择把行 ViewModel 挪进 package，测试照 `ReportCellViewModelTests.repeatedUpdatePublishesNothing` 写：同一个 `updatePhase("Writing…")` 调两次，第二次不应发事件。修前两次都会发。

**同类**：0005 的规矩覆盖的其它行——`ReportCellViewModel` 和 `BatchExportingImageSelectionCellViewModel`——都已经是「不等才发」。批量导出完成页的行 `BatchExportingCompletionRowViewModel` 没有 `@RxObserved` 状态，不涉及。

**工作量**：S。注意要改 Core 的一个公共类型：只是加一个 `Equatable` 一致性，不破坏 API。


### PR121.64 ReportViewController 手写 relay 与 @objc 双击

- **严重度**：Cleanup
- **审查编号**：CV4（= R7）
- **状态**：方案待批，代码未改

**问题**：
- `ReportViewController` 用手写的 `appearedRelay` 加一个 `viewDidAppear` 覆写来报告「页面出现了」（ReportViewController.swift:19-20、164-167）。RxAppKit 已经有现成的 `rx.viewDidAppear`，批量导出的几个页面都在用。
- 双击走的是 `target` / `doubleAction` 加一个 `@objc` 处理器（:138-139、276-282）。RxAppKit 有 `rx.modelDoubleClicked()`，侧栏根列表就在用。
- 「双击 turnedOff 行就打开设置」这个判断写在了 VC 里，违反 MVVM：VC 只该把事件交给 ViewModel。
- 另有两处输出订阅用了 `self?.`（:223-231），不符合 `guard let self` 的规矩。

**四问**：复现——读代码即可确认，没有行为缺陷；基线——本 PR 新代码；影响——违反项目的 VC 约定（AGENTS.md「UI events — prefer RxAppKit / RxCocoa rx.* accessors」「MVVM-C Completeness」），属于清理，建议顺手改；历史——VC 里的注释写着「The page has no control whose accessor says 'came on screen'」，作者当时不知道 RxAppKit 有 `rx.viewDidAppear`。

**改法**：
- `appeared` 改为 `rx.viewDidAppear.asSignal()`。如果 PR121.59 落地，`appeared` 输入会整个换成 `isVisible`，这一半以 PR121.59 为准。
- 新增 `Input.doubleClickedNode: Signal<ReportNode>`，取自 `outlineView.rx.modelDoubleClicked()`。「turnedOff 行打开设置」的判断挪进 ViewModel。和 `openSettings` 一样，这段放在 `#if os(macOS)` 里，因为 `appRouter` 只在 macOS 上声明，见 PR121.01。
- 动作菜单和右键菜单的 relay 保留：菜单项是动态构建的，AGENTS.md 允许这种用 `PublishRelay` 汇总的写法，审查也确认这一半不算违规。
- 输出订阅改为 `guard let self`。
- 注意：`rx.viewDidAppear` 靠 `methodInvoked` 拦截，仓库里还没有泛型 VC 用过。改完要实际跑一次，确认它会触发。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -25,6 +25,9 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         public let cancelAll: Signal<Void>
         public let clearHistory: Signal<Void>
         public let openSettings: Signal<Void>
+        /// A row double-clicked. A feature's "Turned off in Settings" row opens Settings, where it
+        /// is turned back on; the other rows open nothing.
+        public let doubleClickedNode: Signal<ReportNode>
         /// The filter bar, as typed: rows whose title contains it, with their ancestors. Need not
         /// start with a value — until it reports one the outline is unfiltered.
         public let filterString: Driver<String>
@@ -134,6 +137,14 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
         }
         .disposed(by: rx.disposeBag)
 
+        #if os(macOS)
+        input.doubleClickedNode.emitOnNext { [weak self] node in
+            guard let self, case .turnedOff = node.identifier else { return }
+            appRouter.trigger(.settings)
+        }
+        .disposed(by: rx.disposeBag)
+        #endif
+
         input.filterString.driveOnNext { [weak self] filterString in
             guard let self else { return }
             self.filterString = filterString
```

```diff
--- a/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
+++ b/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Reports/ReportViewController.swift
@@ -16,9 +16,6 @@ import SnapKit
 final class ReportViewController<Route: Routable>: BaseEffectViewController<ReportViewModel<Route>>, NSMenuDelegate {
     // MARK: - Relays
 
-    /// The page has no control whose accessor says "came on screen".
-    private let appearedRelay = PublishRelay<Void>()
-
     /// The actions menu and the context menu are built on demand, so their items report here.
     private let cancelRelay = PublishRelay<ReportNode>()
 
@@ -135,8 +132,6 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
             $0.allowsTypeSelect = true
             $0.headerView = nil
             $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
-            $0.target = self
-            $0.doubleAction = #selector(outlineViewDoubleClicked(_:))
             $0.menu = NSMenu().then {
                 $0.delegate = self
             }
@@ -161,22 +156,18 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         }
     }
 
-    override func viewDidAppear() {
-        super.viewDidAppear()
-        appearedRelay.accept(())
-    }
-
     // MARK: - Bindings
 
     override func setupBindings(for viewModel: ReportViewModel<Route>) {
         super.setupBindings(for: viewModel)
 
         let input = ReportViewModel<Route>.Input(
-            appeared: appearedRelay.asSignal(),
+            appeared: rx.viewDidAppear.asSignal(),
             cancel: cancelRelay.asSignal(),
             cancelAll: cancelAllRelay.asSignal(),
             clearHistory: clearHistoryRelay.asSignal(),
             openSettings: openSettingsRelay.asSignal(),
+            doubleClickedNode: outlineView.rx.modelDoubleClicked().asSignal(),
             filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
             showsOnlyInProgress: showsOnlyInProgressButton.rx.state.asDriver().map { $0 == .on }.startWith(false)
         )
@@ -221,12 +212,14 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         .disposed(by: rx.disposeBag)
 
         output.hasWorkInProgress.driveOnNext { [weak self] hasWorkInProgress in
-            self?.hasWorkInProgress = hasWorkInProgress
+            guard let self else { return }
+            self.hasWorkInProgress = hasWorkInProgress
         }
         .disposed(by: rx.disposeBag)
 
         output.hasHistory.driveOnNext { [weak self] hasHistory in
-            self?.hasHistory = hasHistory
+            guard let self else { return }
+            self.hasHistory = hasHistory
         }
         .disposed(by: rx.disposeBag)
     }
@@ -273,14 +266,6 @@ final class ReportViewController<Route: Routable>: BaseEffectViewController<Repo
         cancelRelay.accept(node)
     }
 
-    /// A feature's "turned off" row opens Settings, where it is turned back on.
-    @objc private func outlineViewDoubleClicked(_ sender: NSOutlineView) {
-        guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? ReportNode else { return }
-        if case .turnedOff = node.identifier {
-            openSettingsRelay.accept(())
-        }
-    }
-
     // MARK: - Context Menu
```

```diff
--- a/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportViewModelTests.swift
+++ b/RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/ReportViewModelTests.swift
@@ -26,7 +26,7 @@ struct ReportViewModelTests {
         let viewModel: ReportViewModel<SidebarRootRoute>
         let output: ReportViewModel<SidebarRootRoute>.Output
 
-        init(documentState: DocumentState, filterString: Driver<String> = .just(""), showsOnlyInProgress: Driver<Bool> = .just(false)) {
+        init(documentState: DocumentState, doubleClickedNode: Signal<ReportNode> = .empty(), filterString: Driver<String> = .just(""), showsOnlyInProgress: Driver<Bool> = .just(false)) {
             viewModel = ReportViewModel(documentState: documentState, router: router)
             output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
                 appeared: .empty(),
@@ -34,6 +34,7 @@ struct ReportViewModelTests {
                 cancelAll: cancelAllRelay.asSignal(),
                 clearHistory: clearHistoryRelay.asSignal(),
                 openSettings: .empty(),
+                doubleClickedNode: doubleClickedNode,
                 filterString: filterString,
                 showsOnlyInProgress: showsOnlyInProgress
             ))
```

**复现测试（示例）**：放在 `ReportViewModelTests`。被替换的判断写在 App target 的 VC 里，没有测试 target，所以这条测试锁定的是挪进 ViewModel 之后的行为，修前无法写成红灯。`appRouter` 用 `withDependencies` 换成 `MockRouter<AppRoute>`。`@MainActor` 类型本身就是 `Sendable`，可以直接放进依赖。
```swift
@Test("double-clicking a feature's turned-off row opens Settings; other rows open nothing")
func doubleClickOnTurnedOffRowOpensSettings() async throws {
    let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.doubleClick")
    let environment = ViewModelTestEnvironment(runtimeEngine: engine)
    environment.settings.indexing.isEnabled = false
    environment.settings.search.isCorpusEnabled = false
    let appRouter = MockRouter<AppRoute>()
    let doubleClickRelay = PublishRelay<ReportNode>()
    let page = withDependencies {
        $0.appRouter = appRouter
    } operation: {
        environment.make { Page(documentState: environment.documentState, doubleClickedNode: doubleClickRelay.asSignal()) }
    }
    defer { withExtendedLifetime((page, appRouter)) {} }
    let nodes = try await nextValue(from: page.output.nodes) { !$0.isEmpty }
    let categoryRow = try #require(Self.node(.category(.backgroundIndexing), in: nodes))
    let turnedOffRow = try #require(Self.node(.turnedOff(.backgroundIndexing), in: nodes))

    doubleClickRelay.accept(categoryRow)
    #expect(appRouter.triggeredRoutes.isEmpty)

    doubleClickRelay.accept(turnedOffRow)
    #expect(appRouter.triggeredRoutes.count == 1)
    await engine.stop()
}
```

**同类**：
- Find 页的同类写法（CV5、CV6）由 PR121.51 和 PR121.52 处理。
- 仓库里其它 VC 的「出现」都已经用 `rx.viewDidAppear`（`BatchExportingProgressViewController`、`ExportingProgressViewController` 等）。

**工作量**：S。和 PR121.55 改同一处 `hasWorkInProgress`：两条一起落地时，以 PR121.55 的新名字 `hasCancellableWork` 为准。`appeared` 那一半以 PR121.59 为准。


### PR121.65 lhs / rhs 缩写

- **严重度**：Cleanup
- **审查编号**：CV7
- **状态**：方案待批，代码未改

**问题**：`ReportViewModel.makeNodes` 给进行中的语料构建排序时，闭包参数和局部变量叫 `lhs`、`rhs`、`lhsIsBuilding`、`rhsIsBuilding`（ReportViewModel.swift:201-207）。全局规则要求所有标识符都用完整名称，不允许缩写。

**四问**：
- **复现**：读代码即可确认。
- **基线**：本 PR 新代码。我 grep 了本 PR 新增的全部 Swift 行，只有这一处用了 `lhs` / `rhs`。
- **影响**：只违反命名规则，没有行为影响。属于清理，建议顺手改。
- **历史**：无。

**改法**：改为 `leftEntry` / `rightEntry`，相应的局部变量改为 `leftIsBuilding` / `rightIsBuilding`。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
+++ b/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Reports/ReportViewModel.swift
@@ -198,13 +198,13 @@ public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
             corpusChildren.append(node(.turnedOff(.searchableInterfaces)) { $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings") })
         }
         // The image being printed first, then the waiting ones by name.
-        let activeBuilds = corpusStates.filter(\.value.isActive).sorted { lhs, rhs in
-            let lhsIsBuilding = ReportOutline.isBuilding(lhs.value)
-            let rhsIsBuilding = ReportOutline.isBuilding(rhs.value)
-            if lhsIsBuilding != rhsIsBuilding {
-                return lhsIsBuilding
+        let activeBuilds = corpusStates.filter(\.value.isActive).sorted { leftEntry, rightEntry in
+            let leftIsBuilding = ReportOutline.isBuilding(leftEntry.value)
+            let rightIsBuilding = ReportOutline.isBuilding(rightEntry.value)
+            if leftIsBuilding != rightIsBuilding {
+                return leftIsBuilding
             }
-            return ReportOutline.imageName(of: lhs.key) < ReportOutline.imageName(of: rhs.key)
+            return ReportOutline.imageName(of: leftEntry.key) < ReportOutline.imageName(of: rightEntry.key)
         }
         for (imagePath, state) in activeBuilds {
             corpusChildren.append(node(.corpusBuild(imagePath: imagePath)) { ReportOutline.configure($0, forCorpusOf: imagePath, state: state) })
```

**复现测试（示例）**：行为不变，不需要新测试。语料行的排序（正在打印的在前，其余按名字）由现有的 `ReportViewModelTests.progressUpdatesRowInPlace` 和 `cancelFromRow` 间接覆盖。

**同类**：本 PR 新增的代码里没有别的 `lhs` / `rhs`（检查方法：`git diff 9ca0d5a6 12e1227b -- '*.swift' | grep '^+' | grep -E '\b(lhs|rhs)\b'`）。仓库其它地方原有的同类写法不在本 PR 的范围内。

**工作量**：S。PR121.62 会把这里的 `ReportOutline.imageName` 换成 `FindScope.imageName`，PR121.59 会把整段搬进 `ReportTreeBuilder`（新名字已经用在那里）。


### PR121.66 Swift 类的 Ancestors 漏掉采纳的 @objc 协议

- **严重度**：Minor
- **审查编号**：C31
- **状态**：方案待批，代码未改

**问题**：Swift 类型的 Ancestor Types 只读 Swift 的一致性记录（`swiftTypeAncestorNodes` → `conformingProtocolNames`）。Swift 类采纳 ObjC 协议时不会产生这种记录，只会写进类的 ObjC 面（`class_ro_t` 的协议表）。Conforming Types 走的正是 ObjC 表，会把这些类列出来（并按 AC6 换成 Swift 面），所以两个方向对不上：在 Conforming Types 里查得到某个类，它的 Ancestor Types 里却没有这个协议。

例子（来自 macOS 27.0 导出）：
- SwiftUI 的 `_TtC7SwiftUI18SharedMenuDelegate : NSObject <NSMenuDelegate>`；
- Foundation 的 `_TtCE10FoundationCSo20NSNotificationCenter22NotificationMessageKey : NSObject <NSCopying>`。

**四问**：
- **复现**：只加载 libobjc 和 Foundation，查 `NSCopying` 的 Conforming Types，能看到 Swift 类；再查其中任意一个的 Ancestor Types，没有 `NSCopying`。
- **基线**：本 PR 新引入（8b4309b2）。
- **影响**：这个缺口在 AppDelegate、各种 delegate、`NSCopying` 实现上都会出现，结果是错的但不崩溃。改动很小，建议修。
- **历史**：新代码。提案 §3 的表格里「类型 → 协议」一行，Swift 一侧只写了一致性记录，没有考虑 ObjC 面。

**改法**：
- 对 Swift 类，在 Swift 协议之后、父类之前，补上它 ObjC 面采纳的协议，步骤是：
  1. 通过 `RuntimeSwiftSection.objcClassName(forCounterpartOf:)` 拿到运行时类名（侧栏在两个面之间跳转用的也是它）；
  2. 读 `classGroupAcrossImages(forName:)` 返回结果的 `info.first?.protocols`；
  3. 交给现有的 `objcProtocolNodes`。
- 纯 Swift 类没有 ObjC 面，第 1 步直接返回 `nil`，结果不变。struct 和 enum 不能采纳 ObjC 协议，不走这条路。
- 两张表天然不重叠：`@objc` 协议没有 Swift 协议描述符，只会出现在 ObjC 表里；Swift 的一致性记录只覆盖 Swift 协议。
- **只修一半，另一半不修**：另一个镜像里声明的一致性（例如 CoreTransferable 里的 `extension String: Transferable`），两个方向本来就都缺。原因是 Conforming Types 用记录所在的镜像去物化类型，那个镜像并不定义这个类型，物化失败后结果被丢掉。这是 Inspector 早就有的共同缺口，不是本 PR 引入的不对称，建议本批不修，裁决写进 KnownIssues（下方附原文）。
- 如果 PR121.13 先落，这里的 `objcProtocolNodes` 调用要多传一个参数 `referencedFrom: object.imagePath`，这样协议节点就优先用这个类所在镜像的那一份。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -227,16 +227,32 @@ actor RuntimeTypeRelationshipsResolver {
         }
         return nodes
     }
 
-    /// A Swift struct's, enum's, actor's or class's ancestors: the protocols
-    /// it conforms to, then — for a class — its superclass with the same
-    /// underneath. A superclass no Swift image defines is looked up as an
-    /// Objective-C class by its printed name before it is given up on.
+    /// The Objective-C protocols a Swift class adopts. Adopting one leaves no
+    /// Swift conformance record: it is written into the class's Objective-C
+    /// face, where Conforming Types reads it, so Ancestor Types reads it
+    /// there too. A class with no Objective-C face adopts none.
+    private func objcProtocolNodes(adoptedBySwiftClass object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+        guard let objcClassName = await swiftSectionFactory.existingSection(for: object.imagePath)?.objcClassName(forCounterpartOf: object),
+              let (group, _) = objcSectionFactory.indexer.classGroupAcrossImages(forName: objcClassName),
+              let classInfo = group.info.first
+        else { return [] }
+        return await objcProtocolNodes(named: classInfo.protocols.map(\.name), visited: visited, depth: depth)
+    }
+
+    /// A Swift struct's, enum's, actor's or class's ancestors: the protocols
+    /// it conforms to — for a class, the Objective-C ones its Objective-C
+    /// face adopts as well — then, for a class, its superclass with the same
+    /// underneath. A superclass no Swift image defines is looked up as an
+    /// Objective-C class by its printed name before it is given up on.
     private func swiftTypeAncestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
         let indexer = swiftSectionFactory.indexer
         var nodes = await swiftProtocolNodes(
             qualifiedNames: indexer.conformingProtocolNames(forMangledTypeName: object.name).map(\.name),
             visited: visited,
             depth: depth + 1
         )
+        if case .swift(.type(.class)) = object.kind {
+            nodes += await objcProtocolNodes(adoptedBySwiftClass: object, visited: visited, depth: depth + 1)
+        }
         guard case .swift(.type(.class)) = object.kind,
```
```diff
--- a/Documentations/Evolutions/draft-find-navigator.md
+++ b/Documentations/Evolutions/draft-find-navigator.md
@@ -257,1 +257,1 @@
-  | 类型 → 协议 | `ObjCClassInfo.protocols`（含 category 采纳） | `SwiftDeclarationIndexer.conformingProtocolNamesByTypeName` |
+  | 类型 → 协议 | `ObjCClassInfo.protocols`（含 category 采纳） | `SwiftDeclarationIndexer.conformingProtocolNamesByTypeName`；Swift 类另读它 ObjC 面的 `ObjCClassInfo.protocols`（采纳 ObjC 协议不留 Swift 一致性记录） |
```

**复现测试（示例）**：
- **位置**：追加到 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceSearchTests.swift`，沿用文件里的 `makeEngine`（libobjc + Foundation）。
- **找对象**：先从 Conforming Types 取出 `NSCopying` 的 Swift 类遵循者，再按现有 `swiftClassAncestors` 的写法，用显示名逐个查 Ancestors。名字匹配不上的跳过；一个都找不到就记一条 Issue，而不是什么也没测就通过。
- **修复前**：第一层只有 Swift 一致性记录给出的协议，没有 `NSCopying`，测试变红。

```swift
@Test("a Swift class lists the Objective-C protocols its Objective-C face adopts")
func swiftClassAncestorsIncludeAdoptedObjCProtocols() async throws {
    let engine = try await Self.makeEngine("swift-class-objc-protocols")
    let conformerTrees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSCopying", matchMode: .matchingWord, relationship: .conformers, isCaseSensitive: true))
    let swiftClasses = conformerTrees
        .filter { $0.root.kind == .objc(.type(.protocol)) }
        .flatMap(\.nodes)
        .compactMap(\.object)
        .filter { $0.kind == .swift(.type(.class)) }
    try #require(!swiftClasses.isEmpty, "Foundation has no Swift class adopting NSCopying")

    for swiftClass in swiftClasses {
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: swiftClass.displayName, relationship: .ancestors, isCaseSensitive: true, candidateLimit: .max))
        guard let tree = trees.first(where: { $0.root == swiftClass }) else { continue }
        // Before: only the protocols of its Swift conformance records.
        #expect(tree.nodes.contains { $0.name == "NSCopying" && $0.object?.kind == .objc(.type(.protocol)) }, "\(swiftClass.displayName)")
        return
    }
    Issue.record("no Swift class adopting NSCopying could be found by its own name")
}
```

**同类**：
- **查过，不需要改**：ObjC 类的 Ancestor 走 `ObjCClassInfo.protocols`，本来就包括 category 采纳的协议（见提案表格）。struct 和 enum 只有 Swift 一致性。
- **跨镜像一致性，建议不修**。拟写进 KnownIssues 的裁决原文：

  > Swift 类型在别的镜像里声明的一致性（如 CoreTransferable 的 `String: Transferable`）在 Ancestor Types 和 Conforming Types / Inspector 两个方向上都不出现：一致性记录所在的镜像不定义该类型，按记录所在镜像物化时失败被丢弃。两边一致，不是本 PR 引入的不对称；要修需要先定「到定义该类型的镜像去物化，并决定节点显示哪个镜像」，两个方向一起改，另案处理。

**工作量**：S。不依赖其它条目，但与 PR121.13、PR121.69 改的是同一个函数，后落的一条需要机械变基（只是多传一个参数）。


### PR121.67 关系遍历不检查取消

- **严重度**：Minor
- **审查编号**：C28
- **状态**：方案待批，代码未改

**问题**：
- `RuntimeTypeRelationshipsResolver.trees(for:)` 和各个递归遍历函数都没有检查取消。`candidateTypes` 用 `try?` 读每个镜像的对象，下层抛出的取消也会被当成「没有对象」吞掉。
- 像 `NSObject` 的 Descendant Types 这种查询，要走上千个节点，每个节点都要跨一次 actor。被新搜索取代后，旧的遍历照样跑完，期间一直占着解析器 actor，别的窗口发出的关系查询只能排在它后面。

**四问**：
- **复现**：在进程内引擎上起一个 Task 调 `typeRelationships`（Descendants 查 `NSObject`），立刻取消，调用仍然把完整的树返回来，不会抛错。
- **基线**：本 PR 新引入（8b4309b2）。
- **影响**：只浪费资源和时间，结果不错。App 里的 `.local` 转发给 XPC service，而 FindSession 的取消现在传不到服务端（PR121.29），所以本条在 PR121.29 落地之前，对 App 用户没有可见效果。不过代价只有几行，建议现在一起修，等取消能跨连接传过去时立即生效。
- **历史**：同类问题以前登记过：PR88R2.6，说的是接口缓存的取数 Task 脱离了结构化取消。当时判为纯资源问题、留待后续，本条也按资源问题处理。

**改法**：
- 每处理一个候选之前，`trees(for:)` 调一次 `try Task.checkCancellation()`。遍历结束后再查一次：被取消的遍历只会带回走到一半的树，必须抛错，不能当成完整结果交出去。
- `candidateTypes` 每处理一个镜像查一次，因为每个镜像都要跨一次 actor。
- 递归函数在已有的深度上限判断里并上 `!Task.isCancelled`，返回空数组；三个没有深度判断的递归入口（`objcClassAncestorNodes`、`swiftTypeAncestorNodes`、`refiningProtocolNodes(ofObjCProtocolNamed:)`）补一行同样的判断。用 `isCancelled` 而不是 `checkCancellation()`，是为了不必把整串递归函数都改成 `throws`；最外层那次 `checkCancellation()` 保证结果不会外泄。
- Inspector 用的 `RuntimeRelationshipsResolver` 一次只查一层，不改。
- 若 PR121.69（遍历重构）先落，后两条合成一处：写进 `RelationshipWalkPath.descending(into:)` 的判断条件里。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -54,17 +54,23 @@ actor RuntimeTypeRelationshipsResolver {
-    /// Throws when the query is a regular expression that does not compile.
+    /// Throws when the query is a regular expression that does not compile,
+    /// and `CancellationError` when the task asking is cancelled — a walk cut
+    /// short is never handed out as if it were the whole tree.
     func trees(for query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree] {
         let candidates = try await candidateTypes(matching: query)
         var trees: [RuntimeRelationshipTree] = []
         trees.reserveCapacity(candidates.count)
         for candidate in candidates {
+            try Task.checkCancellation()
             let visited: Set<String> = [visitedKey(for: candidate)]
             let nodes: [RuntimeRelationshipNode]
             switch query.relationship {
             case .ancestors:
                 nodes = await ancestorNodes(of: candidate, visited: visited, depth: 0)
             case .descendants:
                 nodes = await descendantNodes(of: candidate, visited: visited, depth: 0)
             case .conformers:
                 nodes = await conformerNodes(of: candidate)
             }
+            // A cancelled walk returns what it had reached; throw rather than
+            // pass that off as the tree.
+            try Task.checkCancellation()
             if let imagePaths = query.imagePaths {
@@ -128,12 +134,14 @@ actor RuntimeTypeRelationshipsResolver {
         for imagePath in await objcSectionFactory.cachedImagePaths.sorted() {
+            try Task.checkCancellation()
             guard let section = await objcSectionFactory.existingSection(for: imagePath),
                   let objects = try? await section.allObjects()
             else { continue }
             objects.forEach(considerTree)
         }
         for imagePath in await swiftSectionFactory.cachedImagePaths.sorted() {
+            try Task.checkCancellation()
             guard let section = await swiftSectionFactory.existingSection(for: imagePath),
                   let objects = try? await section.allObjects()
             else { continue }
             objects.forEach(considerTree)
         }
@@ -172,2 +180,2 @@ actor RuntimeTypeRelationshipsResolver {
     private func ancestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+        guard depth < Self.maximumDepth, !Task.isCancelled else { return [] }
@@ -192,2 +200,3 @@ actor RuntimeTypeRelationshipsResolver {
     private func objcClassAncestorNodes(named className: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+        guard !Task.isCancelled else { return [] }
         guard let (group, _) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className),
@@ -216,2 +225,2 @@ actor RuntimeTypeRelationshipsResolver {
     private func objcProtocolNodes(named protocolNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+        guard depth < Self.maximumDepth, !Task.isCancelled else { return [] }
@@ -235,2 +244,3 @@ actor RuntimeTypeRelationshipsResolver {
     private func swiftTypeAncestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+        guard !Task.isCancelled else { return [] }
         let indexer = swiftSectionFactory.indexer
@@ -269,2 +279,2 @@ actor RuntimeTypeRelationshipsResolver {
     private func swiftProtocolAncestorNodes(qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+        guard depth < Self.maximumDepth, !Task.isCancelled else { return [] }
@@ -284,2 +294,2 @@ actor RuntimeTypeRelationshipsResolver {
     private func swiftProtocolNodes(qualifiedNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+        guard depth < Self.maximumDepth, !Task.isCancelled else { return [] }
@@ -301,2 +311,2 @@ actor RuntimeTypeRelationshipsResolver {
     private func descendantNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+        guard depth < Self.maximumDepth, !Task.isCancelled else { return [] }
@@ -328,2 +338,3 @@ actor RuntimeTypeRelationshipsResolver {
     private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+        guard !Task.isCancelled else { return [] }
         var nodes: [RuntimeRelationshipNode] = []
@@ -347,2 +358,2 @@ actor RuntimeTypeRelationshipsResolver {
     private func swiftRefiningProtocolNodes(of name: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+        guard depth < Self.maximumDepth, !Task.isCancelled else { return [] }
```

**复现测试（示例）**：
- **位置**：追加到 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceSearchTests.swift`，沿用文件里的 `makeEngine`。它建的是进程内引擎，测试进程没有 Info.plist 里的 service 键，所以 `.local` 不会转发出去。
- **修复前**：整条路径上没有任何取消检查，`search.value` 正常返回一组树，`#expect(throws:)` 失败，测试变红。
- **局限**：这条测试只能证明入口处的检查。遍历中途取消没有稳定的注入点，不强求。

```swift
@Test("a cancelled relationship search throws instead of returning a partial tree")
func cancelledRelationshipSearchThrows() async throws {
    let engine = try await Self.makeEngine("relationships-cancelled")
    let search = Task {
        try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", relationship: .descendants, isCaseSensitive: true))
    }
    search.cancel()

    // Before: nothing on the way checked, and the whole tree came back.
    await #expect(throws: CancellationError.self) {
        try await search.value
    }
}
```

**同类**：
- 跨连接取消（让 service 端处理请求的 Task 真正被取消）在 PR121.29。
- Inspector 的 `RuntimeRelationshipsResolver.relationships(for:)` 一次只查一层，量很小，不加检查。
- 同文件里没有别的长循环。

**工作量**：S。不依赖其它条目，与 PR121.69 改的是同一组函数，后落的一条需要机械变基。要到 PR121.29 落地，App 用户才能看到效果。


### PR121.68 materializeObjCClass 回退到 ObjC 面（建议不修）

- **严重度**：建议不修
- **审查编号**：C34（同 R5）
- **状态**：方案待批，代码未改

**问题**：两条路径在同一种情况下做法不同：Swift-stable 类（ObjC 运行时里由 Swift 定义的类）找不到对应的 Swift 面。
- Ancestor 树用的 `materializeObjCClass(named:)` 会退回 ObjC 面，用 ObjC 名把节点画出来（`RuntimeTypeRelationshipsResolver.swift:373-381`）。
- Inspector、Descendant Types 和 Conforming Types 用的 `materializeObjCReference(_:)` 按 AC6 直接丢弃这个类（`RuntimeRelationshipsResolver.swift:161-171`）。

所以同一个类，可能在一处以 ObjC 名出现，另一处却根本不出现。

**四问**：
- **复现**：要触发，必须是一个 Swift-stable 类在 Swift section 里配不上 Swift 面。2026-09-27 起改为按类对象指针配对，此后只剩「这个镜像的 Swift section 不存在」一种情况，而 `RuntimeEngine` 总是同时建两个 section。审查只判为「可能」，没有构造出实际场景。
- **基线**：差异由本 PR 引入（8b4309b2），但这是新函数有意采用的做法，不是疏忽。
- **影响**：几乎碰不到。即使碰到，Ancestor 一侧的做法也更好，建议不修。
- **历史**：AC6（关系结果里的桥接类一律显示为 Swift 面，配不上就丢弃）是 Inspector 关系视图定下的规则。`materializeObjCClass` 是本 PR 为祖先链新写的，没有照搬 AC6 的丢弃，但也没写注释说明原因。

**裁决理由**（将来原样写进 KnownIssues）：
> Ancestor Types 对配不上 Swift 面的 Swift-stable 类回退到 ObjC 面，而 Inspector / Descendant / Conforming 按 AC6 丢弃——这一差异有意保留。丢掉一个节点的代价在两种结构里不同：列表里丢一条只少一行；祖先链里丢掉父类，会把它上面直到 `NSObject` 的整条链连同链上的协议一起截掉，用户看到一棵断掉的树，比看到这个类的 ObjC 面更糟。另外，两个面自 2026-09-27 起按类对象指针配对，配不上只剩「该镜像没有 Swift section」一种情况，而 `RuntimeEngine` 总是同时建两个 section，实际几乎不发生。若将来出现能稳定触发的场景，再重新裁决。

**改法**：行为不变，只在 `materializeObjCClass` 上补一段注释说明这个差异是有意的，免得以后被当成不一致「统一」掉。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -370,4 +370,13 @@ actor RuntimeTypeRelationshipsResolver {
     /// The `RuntimeObject` for an Objective-C class from whichever indexed
     /// image declares it — as its Swift face when the class is a Swift class,
     /// the way the sidebar and the Inspector list it.
+    ///
+    /// Unlike `RuntimeRelationshipsResolver.materializeObjCReference(_:)`,
+    /// which drops a Swift class whose Swift face it cannot find, this falls
+    /// back to the Objective-C face, deliberately: a list loses one row to a
+    /// dropped entry, but an ancestor chain would lose the superclass and
+    /// everything above it, up to `NSObject` and the protocols on the way.
+    /// Since the two faces are paired through the class object, a class goes
+    /// unpaired only when its image has no Swift section, which
+    /// `RuntimeEngine` never builds apart from the Objective-C one.
     private func materializeObjCClass(named className: String) async -> RuntimeObject? {
```

**复现测试（示例）**：行为不变，不需要新测试。现有的 `RuntimeInterfaceSearchTests.swiftClassAncestors` 覆盖了 Swift 类沿祖先链走到 ObjC 父类这条路径。

**同类**：PR121.13 的候选去重遵循同一个回退：Swift 类的 ObjC 面在候选里一律换成 Swift 面，配不上时保留 ObjC 面。除这两处外，没有别的物化路径。

**工作量**：S，只是一段注释，可以随 PR121.69 的重构一起提交。


### PR121.69 关系遍历代码重复、visited 键写法不统一

- **严重度**：Cleanup
- **审查编号**：S4
- **状态**：方案待批，代码未改

**问题**：`RuntimeTypeRelationshipsResolver` 的遍历代码有三个毛病，读起来费劲，也容易改漏。
- 8 处几乎一样的代码块：拷贝 `visited`，插入键，再递归。
- `visited` 的键有五种写法：
  - `"objc:" + 名字`
  - `"objcProtocol:" + 名字`
  - `"swiftProtocol:" + 限定名`
  - `visitedKey(for:)` 生成的 `"\(kind)|\(name)"`
  - 只检查、从不插入的 `"unresolved:" + 显示名`

  同一个类型因此可能有两个键，例如根节点 NSObject 类的 `"objc(type(class))|NSObject"` 和父类链里的 `"objc:NSObject"`。经过根节点的环要多绕一层才会被切断。
- 有三个递归函数没有深度上限：`objcClassAncestorNodes`、`swiftTypeAncestorNodes`、`refiningProtocolNodes(ofObjCProtocolNamed:)`。

**四问**：
- **复现**：读代码即可确认。只有在损坏的镜像里出现环时，结果才会受影响。审查复核过，正常镜像不会无限递归，也不会出错。
- **基线**：本 PR 新代码（8b4309b2）。
- **影响**：正常数据上没有用户可见的影响。但 PR121.13（引用镜像）和 PR121.67（取消检查）都要把同样的改动复制到这 8 处；收敛到一个入口后，这类改动只需改一处。建议作为纯重构来做。
- **历史**：新代码。类的文档承诺「环会被切断，深度上限兜底」，实现只做到了一部分：键的写法不一、有三个递归函数没有上限，是同一段代码边写边长出来的结果。

**改法**：
- **统一身份键**：用一个身份枚举 `RelationshipTypeIdentity`（`objcClass` / `objcProtocol` / `swiftType` / `swiftProtocol`）取代五种字符串键。类与协议、Swift 类与它注册到 ObjC 的那一面，各自是不同的身份。
- **统一路径状态**：新增按查询构造的值类型 `RelationshipWalkPath`，持有当前路径上的身份集合和深度，并提供 `descending(into:)`。当该类型已经在路径上，或路径已到深度上限时，`descending(into:)` 返回 `nil`。8 处代码块都改成一行 `guard let … = path.descending(into: …) else { continue }`，深度上限也由它统一负责，补上了缺的三处。
- **两个辅助函数**：
  - `identity(of:)`：把物化出的 `RuntimeObject` 映射到身份；
  - `swiftProtocolQualifiedName(of:)`：取代原来在两处重复的「从 mangled 名还原限定名」。
- **删掉不会生效的检查**：`"unresolved:"` 那个检查永远为假。PR121.14 也删了同一行；它若先落，这里跳过即可。
- **行为**：正常数据上，结果与改前逐字节相同。兄弟节点之间仍互不影响，所以 PR121.13 修的副本重复在本条里原样保留。只有带环的损坏镜像会有差别：环在根节点处就被切断，而不是多绕一层。
- **落地顺序**：本条 diff 以 12e1227b 为基准，建议最后落（PR121.14 → 13 → 66 → 67 → 69）。变基时：
  - PR121.13 新加的 `referencedFrom:` 参数随节点变化，不属于路径，保持为参数；
  - PR121.67 的取消判断并进 `descending(into:)` 的条件里，各函数里那几行 `!Task.isCancelled` 随之删掉；
  - PR121.68 的那段注释可以随本条一起提交。

**拟修改**：
```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Relationships/RuntimeTypeRelationshipsResolver.swift
@@ -57,13 +57,13 @@ actor RuntimeTypeRelationshipsResolver {
         var trees: [RuntimeRelationshipTree] = []
         trees.reserveCapacity(candidates.count)
         for candidate in candidates {
-            let visited: Set<String> = [visitedKey(for: candidate)]
+            let path = RelationshipWalkPath(root: identity(of: candidate))
             let nodes: [RuntimeRelationshipNode]
             switch query.relationship {
             case .ancestors:
-                nodes = await ancestorNodes(of: candidate, visited: visited, depth: 0)
+                nodes = await ancestorNodes(of: candidate, path: path)
             case .descendants:
-                nodes = await descendantNodes(of: candidate, visited: visited, depth: 0)
+                nodes = await descendantNodes(of: candidate, path: path)
             case .conformers:
                 nodes = await conformerNodes(of: candidate)
             }
@@ -172,16 +172,14 @@ actor RuntimeTypeRelationshipsResolver {
-    private func ancestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+    private func ancestorNodes(of object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         switch object.kind {
         case .objc(.type(.class)):
-            return await objcClassAncestorNodes(named: object.name, visited: visited, depth: depth)
+            return await objcClassAncestorNodes(named: object.name, path: path)
         case .objc(.type(.protocol)):
-            return await objcProtocolAncestorNodes(named: object.name, visited: visited, depth: depth)
+            return await objcProtocolAncestorNodes(named: object.name, path: path)
         case .swift(.type(.protocol)):
-            let qualifiedName = swiftSectionFactory.indexer.protocolName(forMangledName: object.name)?.name ?? object.displayName
-            return await swiftProtocolAncestorNodes(qualifiedName: qualifiedName, visited: visited, depth: depth)
+            return await swiftProtocolAncestorNodes(qualifiedName: swiftProtocolQualifiedName(of: object), path: path)
         case .swift(.type):
-            return await swiftTypeAncestorNodes(of: object, visited: visited, depth: depth)
+            return await swiftTypeAncestorNodes(of: object, path: path)
         default:
             return []
         }
     }
@@ -192,38 +190,30 @@ actor RuntimeTypeRelationshipsResolver {
-    private func objcClassAncestorNodes(named className: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+    private func objcClassAncestorNodes(named className: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         guard let (group, _) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className),
               let classInfo = group.info.first
         else { return [] }
-        var nodes = await objcProtocolNodes(named: classInfo.protocols.map(\.name), visited: visited, depth: depth + 1)
-        if let superclassName = classInfo.superClassName, !superclassName.isEmpty {
-            let key = "objc:" + superclassName
-            if !visited.contains(key) {
-                var visited = visited
-                visited.insert(key)
-                let superclass = await materializeObjCClass(named: superclassName)
-                let children = await objcClassAncestorNodes(named: superclassName, visited: visited, depth: depth + 1)
-                nodes.append(RuntimeRelationshipNode(name: superclass?.displayName ?? superclassName, object: superclass, children: children))
-            }
+        var nodes = await objcProtocolNodes(named: classInfo.protocols.map(\.name), path: path)
+        if let superclassName = classInfo.superClassName, !superclassName.isEmpty,
+           let superclassPath = path.descending(into: .objcClass(name: superclassName)) {
+            let superclass = await materializeObjCClass(named: superclassName)
+            let children = await objcClassAncestorNodes(named: superclassName, path: superclassPath)
+            nodes.append(RuntimeRelationshipNode(name: superclass?.displayName ?? superclassName, object: superclass, children: children))
         }
         return nodes
     }
 
-    private func objcProtocolAncestorNodes(named protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        await objcProtocolNodes(named: objcSectionFactory.indexer.refinedProtocolNames(of: protocolName), visited: visited, depth: depth + 1)
+    private func objcProtocolAncestorNodes(named protocolName: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
+        await objcProtocolNodes(named: objcSectionFactory.indexer.refinedProtocolNames(of: protocolName), path: path)
     }
 
     /// Nodes for Objective-C protocols by name, each carrying the protocols
     /// it adopts underneath.
-    private func objcProtocolNodes(named protocolNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+    private func objcProtocolNodes(named protocolNames: [String], path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         var nodes: [RuntimeRelationshipNode] = []
         for protocolName in protocolNames {
-            let key = "objcProtocol:" + protocolName
-            guard !visited.contains(key) else { continue }
-            var visited = visited
-            visited.insert(key)
+            guard let protocolPath = path.descending(into: .objcProtocol(name: protocolName)) else { continue }
             let object = await materializeObjCProtocol(named: protocolName)
-            let children = await objcProtocolAncestorNodes(named: protocolName, visited: visited, depth: depth)
+            let children = await objcProtocolAncestorNodes(named: protocolName, path: protocolPath)
             nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? protocolName, object: object, children: children))
         }
         return nodes
     }
@@ -235,63 +225,55 @@ actor RuntimeTypeRelationshipsResolver {
-    private func swiftTypeAncestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+    private func swiftTypeAncestorNodes(of object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         let indexer = swiftSectionFactory.indexer
         var nodes = await swiftProtocolNodes(
             qualifiedNames: indexer.conformingProtocolNames(forMangledTypeName: object.name).map(\.name),
-            visited: visited,
-            depth: depth + 1
+            path: path
         )
         guard case .swift(.type(.class)) = object.kind,
               let superclassMangledName = indexer.superclassMangledName(forMangledTypeName: object.name)
         else { return nodes }
 
         if let superclass = await materializeSwiftType(mangledName: superclassMangledName) {
-            guard !visited.contains(visitedKey(for: superclass)) else { return nodes }
-            var visited = visited
-            visited.insert(visitedKey(for: superclass))
-            let children = await swiftTypeAncestorNodes(of: superclass, visited: visited, depth: depth + 1)
+            guard let superclassPath = path.descending(into: .swiftType(mangledName: superclass.name)) else { return nodes }
+            let children = await swiftTypeAncestorNodes(of: superclass, path: superclassPath)
             nodes.append(RuntimeRelationshipNode(object: superclass, children: children))
             return nodes
         }
 
         let displayName = indexer.superclassDisplayName(forMangledTypeName: object.name) ?? superclassMangledName
         let simpleName = displayName.components(separatedBy: ".").last ?? displayName
         if let objcSuperclass = await materializeObjCClass(named: simpleName) {
-            guard !visited.contains(visitedKey(for: objcSuperclass)) else { return nodes }
-            var visited = visited
-            visited.insert(visitedKey(for: objcSuperclass))
-            let children = await ancestorNodes(of: objcSuperclass, visited: visited, depth: depth + 1)
+            guard let superclassIdentity = identity(of: objcSuperclass),
+                  let superclassPath = path.descending(into: superclassIdentity)
+            else { return nodes }
+            let children = await ancestorNodes(of: objcSuperclass, path: superclassPath)
             nodes.append(RuntimeRelationshipNode(object: objcSuperclass, children: children))
-        } else if !visited.contains("unresolved:" + displayName) {
+        } else {
             nodes.append(RuntimeRelationshipNode(name: displayName, object: nil, children: []))
         }
         return nodes
     }
 
-    private func swiftProtocolAncestorNodes(qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+    private func swiftProtocolAncestorNodes(qualifiedName: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         var nodes: [RuntimeRelationshipNode] = []
         for refined in swiftSectionFactory.indexer.refinedProtocols(ofQualifiedName: qualifiedName) {
             if refined.isObjC {
-                nodes += await objcProtocolNodes(named: [refined.qualifiedName], visited: visited, depth: depth + 1)
+                nodes += await objcProtocolNodes(named: [refined.qualifiedName], path: path)
             } else {
-                nodes += await swiftProtocolNodes(qualifiedNames: [refined.qualifiedName], visited: visited, depth: depth + 1)
+                nodes += await swiftProtocolNodes(qualifiedNames: [refined.qualifiedName], path: path)
             }
         }
         return nodes
     }
 
     /// Nodes for Swift protocols by qualified name, each carrying the
     /// protocols it refines underneath.
-    private func swiftProtocolNodes(qualifiedNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+    private func swiftProtocolNodes(qualifiedNames: [String], path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         var nodes: [RuntimeRelationshipNode] = []
         for qualifiedName in qualifiedNames {
-            let key = "swiftProtocol:" + qualifiedName
-            guard !visited.contains(key) else { continue }
-            var visited = visited
-            visited.insert(key)
+            guard let protocolPath = path.descending(into: .swiftProtocol(qualifiedName: qualifiedName)) else { continue }
             let object = await materializeSwiftProtocol(qualifiedName: qualifiedName)
-            let children = await swiftProtocolAncestorNodes(qualifiedName: qualifiedName, visited: visited, depth: depth)
+            let children = await swiftProtocolAncestorNodes(qualifiedName: qualifiedName, path: protocolPath)
             nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? qualifiedName, object: object, children: children))
         }
         return nodes
     }
@@ -301,60 +283,51 @@ actor RuntimeTypeRelationshipsResolver {
-    private func descendantNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+    private func descendantNodes(of object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         switch object.kind {
         case .objc(.type(.class)), .swift(.type(.class)):
             var nodes: [RuntimeRelationshipNode] = []
             for subclass in await relationshipsResolver.relationships(for: object).subclasses {
-                guard !visited.contains(visitedKey(for: subclass)) else { continue }
-                var visited = visited
-                visited.insert(visitedKey(for: subclass))
-                let children = await descendantNodes(of: subclass, visited: visited, depth: depth + 1)
+                guard let subclassIdentity = identity(of: subclass),
+                      let subclassPath = path.descending(into: subclassIdentity)
+                else { continue }
+                let children = await descendantNodes(of: subclass, path: subclassPath)
                 nodes.append(RuntimeRelationshipNode(object: subclass, children: children))
             }
             return nodes
         case .objc(.type(.protocol)):
-            return await refiningProtocolNodes(ofObjCProtocolNamed: object.name, visited: visited, depth: depth)
+            return await refiningProtocolNodes(ofObjCProtocolNamed: object.name, path: path)
         case .swift(.type(.protocol)):
-            let qualifiedName = swiftSectionFactory.indexer.protocolName(forMangledName: object.name)?.name ?? object.displayName
-            return await refiningProtocolNodes(ofSwiftProtocolNamed: qualifiedName, visited: visited, depth: depth)
+            return await refiningProtocolNodes(ofSwiftProtocolNamed: swiftProtocolQualifiedName(of: object), path: path)
         default:
             return []
         }
     }
 
     /// The protocols refining an Objective-C protocol: Objective-C ones from
     /// the ObjC tables, and Swift ones — a Swift protocol may refine an
     /// Objective-C protocol — from the Swift tables, which key them by the
     /// same runtime name.
-    private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
+    private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         var nodes: [RuntimeRelationshipNode] = []
         for reference in objcSectionFactory.indexer.refiningProtocols(of: protocolName) {
-            let key = "objcProtocol:" + reference.protocolName
-            guard !visited.contains(key) else { continue }
-            var visited = visited
-            visited.insert(key)
+            guard let protocolPath = path.descending(into: .objcProtocol(name: reference.protocolName)) else { continue }
             let object = await objcSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forProtocolName: reference.protocolName)
-            let children = await refiningProtocolNodes(ofObjCProtocolNamed: reference.protocolName, visited: visited, depth: depth + 1)
+            let children = await refiningProtocolNodes(ofObjCProtocolNamed: reference.protocolName, path: protocolPath)
             nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.protocolName, object: object, children: children))
         }
-        nodes += await swiftRefiningProtocolNodes(of: protocolName, visited: visited, depth: depth)
+        nodes += await swiftRefiningProtocolNodes(of: protocolName, path: path)
         return nodes
     }
 
-    private func refiningProtocolNodes(ofSwiftProtocolNamed qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        await swiftRefiningProtocolNodes(of: qualifiedName, visited: visited, depth: depth)
+    private func refiningProtocolNodes(ofSwiftProtocolNamed qualifiedName: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
+        await swiftRefiningProtocolNodes(of: qualifiedName, path: path)
     }
 
-    private func swiftRefiningProtocolNodes(of name: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
-        guard depth < Self.maximumDepth else { return [] }
+    private func swiftRefiningProtocolNodes(of name: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
         var nodes: [RuntimeRelationshipNode] = []
         for reference in swiftSectionFactory.indexer.refiningProtocols(ofQualifiedName: name) {
-            let key = "swiftProtocol:" + reference.qualifiedName
-            guard !visited.contains(key) else { continue }
-            var visited = visited
-            visited.insert(key)
+            guard let protocolPath = path.descending(into: .swiftProtocol(qualifiedName: reference.qualifiedName)) else { continue }
             let object = await swiftSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forMangledProtocolName: reference.mangledName)
-            let children = await swiftRefiningProtocolNodes(of: reference.qualifiedName, visited: visited, depth: depth + 1)
+            let children = await swiftRefiningProtocolNodes(of: reference.qualifiedName, path: protocolPath)
             nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.qualifiedName, object: object, children: children))
         }
         return nodes
     }
@@ -397,5 +370,70 @@ actor RuntimeTypeRelationshipsResolver {
 
-    private func visitedKey(for object: RuntimeObject) -> String {
-        "\(object.kind)|\(object.name)"
+    // MARK: - Walk State
+
+    /// The identity a materialized type is walked under, `nil` for kinds a
+    /// walk never stands on.
+    private func identity(of object: RuntimeObject) -> RelationshipTypeIdentity? {
+        switch object.kind {
+        case .objc(.type(.class)):
+            return .objcClass(name: object.name)
+        case .objc(.type(.protocol)):
+            return .objcProtocol(name: object.name)
+        case .swift(.type(.protocol)):
+            return .swiftProtocol(qualifiedName: swiftProtocolQualifiedName(of: object))
+        case .swift(.type):
+            return .swiftType(mangledName: object.name)
+        default:
+            return nil
+        }
     }
+
+    /// The qualified name the Swift tables key a protocol by. One protocol
+    /// arrives under more than one printed name — the sidebar lists a
+    /// protocol nested in a type by its own short name — so it is recovered
+    /// from the mangled name rather than read off `displayName`.
+    private func swiftProtocolQualifiedName(of object: RuntimeObject) -> String {
+        swiftSectionFactory.indexer.protocolName(forMangledName: object.name)?.name ?? object.displayName
+    }
+
+    /// One type a walk can stand on. A class and a protocol of one name are
+    /// two types, and so are a Swift class and the Objective-C class it is
+    /// registered as. Every step keys the path through this one type, so a
+    /// cycle cannot slip past under a second spelling of the same type.
+    private enum RelationshipTypeIdentity: Hashable {
+        case objcClass(name: String)
+        case objcProtocol(name: String)
+        case swiftType(mangledName: String)
+        case swiftProtocol(qualifiedName: String)
+    }
+
+    /// The path from a tree's root to the node being built: the types on it
+    /// and how deep it runs. The visited set is per path, not per tree, so a
+    /// type reached along two paths shows under both, while a cycle along
+    /// one — only a corrupt image has one — is cut, with the depth cap as
+    /// the backstop.
+    private struct RelationshipWalkPath {
+        private var identities: Set<RelationshipTypeIdentity>
+        private var depth: Int
+
+        init(root: RelationshipTypeIdentity?) {
+            if let root {
+                identities = [root]
+            } else {
+                identities = []
+            }
+            depth = 0
+        }
+
+        /// The path one step further, onto `identity`; `nil` when that type
+        /// is on the path already or the path is as deep as a walk goes.
+        func descending(into identity: RelationshipTypeIdentity) -> RelationshipWalkPath? {
+            guard depth < RuntimeTypeRelationshipsResolver.maximumDepth,
+                  !identities.contains(identity)
+            else { return nil }
+            var path = self
+            path.identities.insert(identity)
+            path.depth += 1
+            return path
+        }
+    }
 }
```

**复现测试（示例）**：行为不变，不需要新测试。以下现有测试覆盖了每一种遍历：
- `RuntimeInterfaceSearchTests` 里的关系用例：
  - ObjC 类的祖先和后代（`objcAncestors`、`objcDescendants`）；
  - 限定镜像（`relationshipsLimitedToImages`）；
  - ObjC 协议的遵循者与 refine（`objcProtocolRelationships`）；
  - Swift 协议 refine（`swiftProtocolRefinements`）；
  - Swift 类走到 ObjC 父类（`swiftClassAncestors`）。
- `RuntimeTypeRelationshipsImageScopeTests`。

只有带环的损坏镜像才会让结果出现差别，正常系统镜像里没有可用的样本，所以不为它造测试。

**同类**：
- 同一个仓库里，Inspector 用的 `RuntimeRelationshipsResolver` 只查一层，没有遍历，不受影响。
- 其它遍历树的代码（侧栏、Find 结果树）不用 visited 集合，没有同样的写法。

**工作量**：M（纯重构，涉及整个文件的遍历函数）。建议最后落，按上面的「落地顺序」吸收 PR121.13、PR121.67 的改动；PR121.14 若先落，本条跳过 `unresolved:` 那一行的删除。


### PR121.70 锁文件钉着被变基孤立的 MachOSwiftSection 修订

- **严重度**：Major
- **审查编号**：新发现（起草修复方案时由模块 B2 发现，主会话核实）
- **状态**：已修复（与 PR121.71 同一个提交）。落地记录见本条末尾。

**问题**：Debug 和 Distribution 两个 workspace 的 `Package.resolved` 锁定 MachOSwiftSection 的 `86f65341`（2026-10-01，由 c30a8daf 写入）。这个修订之后被变基孤立了：远端 `feature/runtime-viewer/find-navigator` 现在指向 `beae202d`（2026-10-07，一次把 MachOSwiftSection `next` 合进来的 merge）。GitHub compare 显示 `86f65341` 相对新末端是 `diverged`，有 10 个提交不在远端任何分支上。SwiftPM 只抓取分支和 tag 能到达的对象，所以 CI 或另一台机器从空缓存解析时拿不到这个修订。本机能编，是因为本地 SwiftPM 缓存里还留着它。普通的 `RuntimeViewer.xcworkspace` 钉的又是另一个修订 `b72638f8`，比新末端落后 35 个提交。三个 workspace 一共钉了两个不同的修订。

**四问**：复现——`gh api repos/MxIris-Reverse-Engineering/MachOSwiftSection/compare/beae202d...86f65341` 返回 `status=diverged ahead_by=10`；从空缓存解析 Distribution workspace 会失败（未实测，依据是 SwiftPM 只按 ref 抓取）。基线——本 PR 的依赖调整（c30a8daf）引入，之后上游分支被变基。影响——Distribution workspace 是发版归档用的锁文件，CI 必挂；建议修。历史——同类「锁文件漂移」踩过多次（见记忆「Distribution workspace 的 pin 会漂移」），但「钉住的修订被上游变基孤立」是第一次。

**核实**：10 个孤立提交在新末端上都有对应版本，没有丢代码。`git cherry -v beae202d 86f65341` 里有 9 个提交 patch-id 与新末端某个提交完全相同。剩下一个 `9f5ffa92 feat(declaration): let several tasks print the same definitions at once` 在新末端上有同名提交 `677aae99`，是变基时改写过的版本。

**改法**：
- 用项目自己的脚本重新解析三个 workspace：`./UpdatePackagesScript.sh --clean`。它会先抓取所有相关的 SwiftPM 镜像，再从空的 checkout 解析，避免 Xcode 27 不更新镜像带来的陈旧结果。
- 新末端 `beae202d` 比钉住的修订多出 53 个提交，大部分来自这次合入的 MachOSwiftSection `next`。所以重新解析不只是换一个等价修订，还会带进上游 `next` 的改动。必须用 Distribution workspace 编一次 macOS 和 iOS 来验证，不能只用 Debug workspace：Debug workspace 用本地 checkout，会掩盖 pin 的问题。
- 脚本会把所有按分支依赖的包一起推到各自的分支末端。review 锁文件 diff 时，确认除 MachOSwiftSection 之外的变化也都是预期的。不想一起动的包，按「升级单个 SPM pin」的做法只删 MachOSwiftSection 那一条 pin 再解析。
- 以后上游分支要变基或强推时，先确认 RuntimeViewer 这边钉的修订还在新历史里；不在，就在同一批里重新解析锁文件。

**拟修改**（预期结果。实际修订以脚本解析出的为准；其它包可能也会变化）：
```diff
--- a/RuntimeViewer-Distribution.xcworkspace/xcshareddata/swiftpm/Package.resolved
+++ b/RuntimeViewer-Distribution.xcworkspace/xcshareddata/swiftpm/Package.resolved
@@ -184,9 +184,9 @@
       "identity" : "machoswiftsection",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection",
       "state" : {
         "branch" : "feature/runtime-viewer/find-navigator",
-        "revision" : "86f653418ef8a8d989fd6b8e778322cb22dc271a"
+        "revision" : "beae202dd484489cd12fc52af3696df8c8f80453"
       }
     },
```
```diff
--- a/RuntimeViewer-Debug.xcworkspace/xcshareddata/swiftpm/Package.resolved
+++ b/RuntimeViewer-Debug.xcworkspace/xcshareddata/swiftpm/Package.resolved
@@
       "state" : {
         "branch" : "feature/runtime-viewer/find-navigator",
-        "revision" : "86f653418ef8a8d989fd6b8e778322cb22dc271a"
+        "revision" : "beae202dd484489cd12fc52af3696df8c8f80453"
       }
```
```diff
--- a/RuntimeViewer.xcworkspace/xcshareddata/swiftpm/Package.resolved
+++ b/RuntimeViewer.xcworkspace/xcshareddata/swiftpm/Package.resolved
@@ -184,9 +184,9 @@
       "state" : {
         "branch" : "feature/runtime-viewer/find-navigator",
-        "revision" : "b72638f8cb61739cfa88577cc1a594e4866de070"
+        "revision" : "beae202dd484489cd12fc52af3696df8c8f80453"
       }
```

**验证（代替测试代码）**：
```bash
# 1. Every pinned MachOSwiftSection revision must be contained in the branch tip.
for resolved in RuntimeViewer*.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
  revision=$(/usr/bin/grep -A6 '"identity" : "machoswiftsection"' "$resolved" | sed -n 's/.*"revision" : "\(.*\)".*/\1/p')
  tip=$(git ls-remote https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection.git refs/heads/feature/runtime-viewer/find-navigator | cut -f1)
  gh api "repos/MxIris-Reverse-Engineering/MachOSwiftSection/compare/$tip...$revision" --jq "\"$resolved: \(.status)\""
done   # every line must say "identical" or "behind" (before the fix: "diverged" for Debug / Distribution)

# 2. Build against the released pins exactly as the release does.
queued-build xcodebuild build -workspace RuntimeViewer-Distribution.xcworkspace -scheme "RuntimeViewer macOS" \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /Volumes/DerivedData/Agents.noindex/claude/DerivedData/RuntimeViewer-FindNavigator \
  -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation -skipMacroValidation \
  -IDEEnableNewPackagePIFBuilder=NO CODE_SIGNING_ALLOWED=NO
# then the same with -scheme "RuntimeViewer iOS" -destination 'generic/platform=iOS Simulator' (needs PR121.01 first)
```
第 1 步修复前红、修复后绿，可以留作发版前的检查。第 2 步要在 PR121.01 修好后才能对 iOS 成功。

**同类**：`RuntimeViewerPackages/Package.resolved` 和 `RuntimeViewerCommandLine/Package.resolved` 里的 MachOSwiftSection 还钉着 `next` 分支，与 manifest 声明的 feature 分支不符。SwiftPM 解析时会自动纠正，不会失败，但锁文件是陈旧的，随本条一起重新解析。RxAppKit 的同类不一致见 PR121.71。
**工作量**：S（加一次 Distribution 构建）；应放在第一批，PR121.71 和其它依赖改动都建立在它之上。

**落地记录（2026-10-08，与 PR121.71 同一个提交）**：
- 三个 workspace 用 `UpdatePackagesScript.sh --clean`（Xcode 27.0）重新解析。Debug 与 Distribution 各有 14 条 pin 变化，两份完全一致：
  - MachOSwiftSection `86f65341 → beae202d`，即分支末端；
  - 随分支末端一起前进的 MachOKit `next@2b3e8cc9 → ecae5d19`、MachOObjCSection `next@ced3fea0 → ea14b1da`、MachOKitExtensions 1.0.0 → 1.2.0；
  - AppKitPlus-Release 0.6.0 → 0.7.0、MachInjector 0.5.1 → 0.6.1、RunningApplicationKit 0.6.0 → 0.7.0、swift-subprocess 0.5.0 → 1.0.0、SwiftMCP 1.13.0 → 1.14.0；
  - JSONFoundation、swift-collections、swift-log、swift-nio、swift-service-lifecycle 的补丁版本。
- 三个包级锁文件（Core、Packages、CommandLine）删掉后用 `swift package resolve` 从空 scratch 重新解析，结果与 Distribution workspace 的 pin 完全相同，只多一个 workspace 用预编译包代替的 swift-syntax。Core 的锁文件原先缺所有按分支依赖的包、还钉着 swift-capstone 5，属于同类，一并刷新。
- 验证：
  - 第 1 步：六份锁文件里钉住的 MachOSwiftSection 修订与分支末端比较，全部 `identical`；其余四个按分支依赖的包（MachOKit、MachOObjCSection、swift-demangling、swift-semantic-string）也都等于各自的分支末端。
  - Core、Packages、CommandLine 三个包的 `swift build --build-tests` 通过；App 用 Debug workspace、`-onlyUsePackageVersionsFromResolvedFile` 构建通过。
  - Distribution 的 macOS Release 与 iOS Simulator 构建放到全部条目修完后统一跑（iOS 要先有 PR121.01）。
- 依赖前进后跑了一次 Core 全量测试（381 个）作为后续各条的基线，2 个失败都与锁文件无关：
  - 关系快照少了 `Foundation.AttributeScopes._DefaultScopeRegistration`。快照录于 macOS 27，本机（macOS 26.7）的 Foundation 里没有这个类，已用 `objc_copyClassNamesForImage` 核实。
  - 后台索引的 `cancelBatchStopsPendingItemsAndEmitsCancelledEvent` 在满载并行时偶发超时，单独跑通过。


### PR121.71 RxAppKit 在 App 是 0.6.0、包测试与 CLI 锁文件是 0.5.4

- **严重度**：Minor（单独看不出错，但它决定 PR121.53 的修复和测试在哪个版本下成立）
- **审查编号**：新发现（模块 E 写 C17 方案时发现）
- **状态**：已修复（与 PR121.70 同一个提交）。落地记录见 PR121.70 末尾。

**问题**：
- App 用的三个 workspace（`RuntimeViewer`、`-Debug`、`-Distribution`）的锁文件解析到 RxAppKit **0.6.0**。
- `RuntimeViewerPackages/Package.resolved` 和 `RuntimeViewerCommandLine/Package.resolved` 仍钉 **0.5.4**（revision `cc84d4f`）。
- manifest 的下限是 `from: "0.5.4"`（RuntimeViewerPackages/Package.swift:220），所以 SwiftPM 重新解析时，0.5.4 仍然满足约束，会被优先保留，包级构建永远停在 0.5.4。

这两个版本在大纲适配器上的行为正好相反。0.6.0 带有 8e48b25：reload 路径不再用 `oldArray != newArray`，改为只在根层比较 `differenceIdentifier + isContentEqual`。结果是：
- `swift test` 跑的 `RuntimeViewerApplicationTests` 测的是与 App 相反的大纲行为。
- PR121.53 要用的节点约定（身份 `==`、递归 `isContentEqual`）在 0.6.0 下才正确，在 0.5.4 下会把所有同标识的树都判为「没变」。
- PR121.53 的 AppKit 测试在 0.5.4 下修前修后都会红，红绿判断不成立。

**四问**：
- **复现**：`grep -A6 '"identity" : "rxappkit"'` 分别查四个锁文件。两个 workspace 显示 `"version" : "0.6.0"`，两个包级锁文件显示 `"version" : "0.5.4"`。
- **基线**：基线已有。分叉点 `9ca0d5a6` 上就是这样，workspace 早在本 PR 之前就升到了 0.6.0，包级锁文件没有跟上。
- **影响**：包级测试与 App 不一致，凡是依赖 RxAppKit 0.6.0 行为的测试都不可信。对 PR121.53 是前提条件，建议与它同批修。
- **历史**：
  - `UpdatePackagesScript.sh` 只刷新三个 workspace 的锁文件，不碰包级锁文件（AGENTS.md「Updating package pins」）。
  - 包级锁文件最后一次整体刷新是 06d09732（2026-09-09，按当时的新下限刷新了所有锁文件），之后再没有动过。

**改法**：
- `RuntimeViewerPackages/Package.swift` 把 RxAppKit 下限提到 `0.6.0`，并在注释里写明原因：节点约定从 0.6.0 起成立，低于它大纲会吞掉子树的变化。只刷新锁文件不够，下限仍是 0.5.4 的话，下一次重新解析不会主动升级。
- 重新解析两个包级锁文件，`rxappkit` 那条 pin 变成 0.6.0（revision `c196e6f69c8a4508ed602363e31a41fd347a0514`）。按「升级单个 pin」的做法：删掉那条 pin，再解析；不要手工改版本号，手工改会被改回去。
- 已知的连带影响：改 `RuntimeViewerPackages/Package.swift` 的任何一行都会触发整体重新解析，提交的锁文件过不了这一关（branch pin 和 capstone 那几条会一起变）。所以这次一定会连带一次锁文件更新。建议把锁文件单独作为一个 `build(deps)` 提交，和代码改动分开，方便审阅。`originHash` 也会随 manifest 改变。
- 这是依赖下限的升级，没有破坏性 API 变更，不需要提案。

**拟修改**：
```diff
--- a/RuntimeViewerPackages/Package.swift
+++ b/RuntimeViewerPackages/Package.swift
@@ -215,9 +215,12 @@ let package = Package(
                 path: "../../RxAppKit",
                 isRelative: true,
             ),
             remote: .package(
                 url: "https://github.com/Mx-Iris/RxAppKit",
-                from: "0.5.4",
+                // 0.6.0 compares outline nodes by diffing semantics: value-type trees such as
+                // `ReportNode` rely on it (identity `==`, recursive `isContentEqual`). Below it the
+                // reload adapter compares with `==` and swallows every change inside a subtree.
+                from: "0.6.0",
             ),
         ),
```

```diff
--- a/RuntimeViewerPackages/Package.resolved
+++ b/RuntimeViewerPackages/Package.resolved
@@ -222,8 +222,8 @@
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/Mx-Iris/RxAppKit",
       "state" : {
-        "revision" : "cc84d4f0d9b86a1a3b8e042150254128998d1dc0",
-        "version" : "0.5.4"
+        "revision" : "c196e6f69c8a4508ed602363e31a41fd347a0514",
+        "version" : "0.6.0"
       }
     },
```

```diff
--- a/RuntimeViewerCommandLine/Package.resolved
+++ b/RuntimeViewerCommandLine/Package.resolved
@@ -222,8 +222,8 @@
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/Mx-Iris/RxAppKit",
       "state" : {
-        "revision" : "cc84d4f0d9b86a1a3b8e042150254128998d1dc0",
-        "version" : "0.5.4"
+        "revision" : "c196e6f69c8a4508ed602363e31a41fd347a0514",
+        "version" : "0.6.0"
       }
     },
```
（两个锁文件这里只列出 `rxappkit` 这一条，以及上面说明的连带变化。实际提交的锁文件由 SwiftPM 重新解析生成，不手工编辑。）

**复现测试（示例）**：这一条是构建验证类，用命令代替测试代码。目录都是 agent 专用的，构建经 `queued-build` 排队，测试只看原始退出码。
```bash
cd RuntimeViewerPackages
# Re-resolve after the floor bump (drop the rxappkit pin first; see the pin recipe).
queued-build swift package resolve --scratch-path /Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerPackages
grep -A6 '"identity" : "rxappkit"' Package.resolved          # expect "version" : "0.6.0"

# The node contract test from PR121.53: red at 0.5.4 whatever the code, red before the fix
# and green after it at 0.6.0.
queued-build swift build --build-tests --scratch-path /Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerPackages
queued-build swift test --skip-build --scratch-path /Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerPackages \
    --filter ReportOutlineBindingTests > /tmp/report-outline-binding.log 2>&1; echo "exit ${pipestatus[1]}"
# Then the whole RuntimeViewerApplicationTests suite once at 0.6.0: assertions written against
# 0.5.4's adapter, if any, surface here.

cd ../RuntimeViewerCommandLine
queued-build swift package resolve --scratch-path /Volumes/DerivedData/Agents.noindex/claude/SwiftPM/RuntimeViewerCommandLine
grep -A6 '"identity" : "rxappkit"' Package.resolved          # expect "version" : "0.6.0"
```

**同类**：两个包级锁文件落后于 workspace 的不止 RxAppKit。2026-10-08 对比四个锁文件，共有 17 条 pin 不一致：

| 依赖 | workspace（Debug / Distribution） | 包级（Packages / CommandLine） |
|---|---|---|
| uifoundation | 0.38.0 | 0.32.0（低于 manifest 下限 0.37.0） |
| machoswiftsection | 分支 `feature/runtime-viewer/find-navigator` | 分支 `next`（与 Core manifest 要求的分支不符，见 PR121.70） |
| appkitplus-release | 0.6.0 | 0.4.2 |
| swift-capstone / capstone | 6.0.1 / 6.0.100 | 5.0.0 / 5.0.100 |
| swift-demangling | `next` | 0.6.3 |
| 其余 11 条 | 较新的补丁或次版本 | 较旧（kingfisher、rainbow、swift-crypto、swift-collections 等） |

其中 UIFoundation 和 MachOSwiftSection 两条本身就与 manifest 冲突，包级构建无论如何都要重新解析。建议这一条和 PR121.70 合在一次「包级锁文件整体刷新」里，而不是只动 RxAppKit 一条。

至于防止复发——让 `UpdatePackagesScript.sh` 顺带刷新包级锁文件——这属于工具链变更。按规则要走提案，只作为后续项列出。

**工作量**：S（改动本身），加上一次锁文件整体刷新。PR121.53 依赖本条。


### PR121.72 语料为协议副本和 Swift 类的 ObjC 面各建一条，搜索重复命中

- **严重度**：Minor（协议副本部分）；建议不修（Swift 类 ObjC 面部分）
- **审查编号**：新发现（模块 F 在 C30 的同类排查中提出）
- **状态**：方案待批，代码未改

**问题**：`corpusObjects(in:)` 原样取 `_objects(in:)`，侧栏列出的每个对象都会建一条语料（`RuntimeEngine+Search.swift:158-160`）。这导致两类重复：
- **ObjC 协议副本**：编译器会给每个见过某个 `@protocol` 声明的镜像各发射一份 `protocol_t`；而且自 2026-08-05 起，侧栏有意按 `__objc_protolist` 全量列出这些副本。跨多个镜像搜索时，同一条协议声明就会按携带它的镜像各命中一次。比如搜 `copyWithZone`，CoreFoundation 和 Foundation 里的 `NSCopying` 各报一遍；`NSObject` 协议几乎每个 ObjC 镜像都带，搜 `respondsToSelector` 时每个镜像都报一遍。这些重复会挤占 1000 条的结果上限，也会把总数虚高。
- **Swift 类的 ObjC 面**：`RuntimeObjCSection.allObjects()`（:101-136）把带 Swift 位的 ObjC 类（`_TtC…`）也列出来，所以一个桥接类在同一个镜像里同时有 Swift 面和 ObjC 面两条语料。搜它的成员名会两边各命中一次。

**四问**：
- **复现**：
  - 协议副本：建好 CoreFoundation 和 Foundation 的语料后，Text 搜 `copyWithZone`，`NSCopying` 在两个镜像下各出现一次（模块 F 在本机 macOS 27.0 导出里核实过，`NSCopying`、`NSSecureCoding`、`NSFastEnumeration` 都同时由这两个镜像携带）。本机导出中，AppKit 带 579 个协议头，Foundation 带 55 个，两者同名的有 13 个；`NSObject-Protocol.h` 出现在 8 个已导出框架中的 6 个里。
  - ObjC 面：SwiftUI 的 `_TtC7SwiftUI18SharedMenuDelegate`。搜 `hoverDelegate` 时，ObjC 面的 `Unknown hoverDelegate;` 和 Swift 面的 `let hoverDelegate` 各命中一次。
- **基线**：两部分都是本 PR 新引入（语料随 8b4309b2 加入）。被重复的对象列表本身是既有、而且有意为之的设计。
- **影响**：
  - 协议副本：只在跨镜像搜索时出现，重复的是逐字相同的文本，建议修。
  - ObjC 面：两面打印的事实不同（见裁决理由），建议不修。
- **历史**：协议副本当年用「归属过滤」去掉过（8997bfea），但那个启发式在 dyld 的 upward 依赖环上会把整个镜像的协议清空，于是 2026-08-05 被撤回（`ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md`）。当时的结论是「索引层宁可多列，去重放到用的地方做」，本条就是在搜索这一层去重。

**改法（协议副本）**：
- **只在一次搜索内部去重**，索引和语料都不动。
- **判断规则**：一个 ObjC 协议条目，如果在当前选项下投影后的文本与本次搜索已经报告过命中的同名副本逐字相同，就不再报告它的命中，只计入摘要的新字段 `omittedRepeatedMatchCount`，也不计入 `totalMatchCount`。
- **为什么要求文本逐字相同**：各镜像的副本来自各自编译时看到的头文件，内容可能不同（例如少了较新的方法）。不同的副本照常各自报告，不会丢掉只在某一份里有的命中。
- **保留哪一份**：镜像本来就按路径排序读取（`searchedImagePaths(within:)`），所以保留的是路径最小的那份。这与模块 F 在 PR121.13 给关系树定的代表副本规则（范围内路径最小）一致。
- **只比较有命中的条目**，开销只落在命中的那几份副本上：
  - Text 搜索：投影本来就要算，直接用投影后的文本比较。
  - Members 搜索：在条目第一个命中的成员处才计算投影并比较。
- **摘要新增字段 `omittedRepeatedMatchCount`**：界面可以据此显示「另有 N 处命中在相同的协议副本里，已合并」。这一句文案归 Find 界面模块（D1 / D2），本条只在 Core 提供数字。
- **兼容性**：这个字段是 Codable 新增的非可选字段。搜索命令是本 PR 新加的，还没有发布过的对端，所以不需要兼容旧格式。
- **已知局限**：
  - 补搜（新语料建好后对新镜像再搜一次）是另一次搜索，新镜像里的副本不会和此前已显示的副本比较。要彻底去掉，需要会话在合并结果时也做一次同样的判断，留给 D1 评估。
  - 如果 PR121.06 先落地（它把扫描移出 store actor），本条的改动要跟着搬进它抽出的扫描函数，逻辑不变。

**拟修改**：
```diff
--- /dev/null
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceRepeatedProtocolCopies.swift
@@ -0,0 +1,27 @@
+import Foundation
+
+/// The Objective-C protocol copies a search has reported hits in, by name,
+/// as the text it read them in.
+///
+/// The compiler emits a protocol into every image that saw its declaration,
+/// and the sidebar lists every copy (`ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md`),
+/// so one search over several images meets the same declaration once per
+/// carrier. A copy that reads exactly like one already reported adds nothing
+/// but the same hits again. Copies that differ — an image built against an
+/// older header — are not repeats, and keep their own hits.
+struct RuntimeInterfaceRepeatedProtocolCopies {
+    private var reportedTextsByProtocolName: [String: [String]] = [:]
+
+    /// Whether `entry` is an Objective-C protocol copy reading exactly like
+    /// one this search already reported hits in.
+    func isRepeated(_ entry: RuntimeInterfaceCorpusEntry, readingAs text: String) -> Bool {
+        guard entry.object.kind == .objc(.type(.protocol)) else { return false }
+        return reportedTextsByProtocolName[entry.object.name]?.contains(text) ?? false
+    }
+
+    /// Remembers a protocol copy the search reported hits in.
+    mutating func recordReported(_ entry: RuntimeInterfaceCorpusEntry, readingAs text: String) {
+        guard entry.object.kind == .objc(.type(.protocol)) else { return }
+        reportedTextsByProtocolName[entry.object.name, default: []].append(text)
+    }
+}
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift
@@ -577,6 +577,13 @@
     /// Runs `query` over every built corpus, pushing matches to `onProgress`
     /// one image at a time, and returns the summary. Matches are collected up
     /// to `query.resultLimit`; the count goes on past it.
+    ///
+    /// An Objective-C protocol is carried by every image that saw its
+    /// declaration, so a search over several images meets the same one once
+    /// per carrier. A copy that reads exactly like one this search already
+    /// reported hits in is not reported again: images are read in path
+    /// order, so the copy shown is the one of the first such image, and the
+    /// hits withheld are counted in `omittedRepeatedMatchCount`.
     func searchInterfaces(
         _ query: RuntimeInterfaceSearchQuery,
         indexedImagePaths: Set<String>,
@@ -588,6 +595,8 @@
         var collectedCount = 0
         var scannedObjectCount = 0
         var scannedImagePaths: [String] = []
+        var repeatedProtocolCopies = RuntimeInterfaceRepeatedProtocolCopies()
+        var omittedRepeatedMatchCount = 0
         let now = Date()
         for imagePath in searchedImagePaths(within: query.imagePaths) {
             try Task.checkCancellation()
@@ -609,12 +618,20 @@
                     interface = entry.interface
                     nestedDefinitionRanges = entry.nestedDefinitionRanges
                 }
-                totalMatchCount += RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, excludingUTF8Ranges: nestedDefinitionRanges) { match in
+                if repeatedProtocolCopies.isRepeated(entry, readingAs: interface.text) {
+                    omittedRepeatedMatchCount += RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, excludingUTF8Ranges: nestedDefinitionRanges) { _ in false }
+                    continue
+                }
+                let entryMatchCount = RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, excludingUTF8Ranges: nestedDefinitionRanges) { match in
                     guard collectedCount < query.resultLimit else { return false }
                     batch.append(match)
                     collectedCount += 1
                     return true
                 }
+                totalMatchCount += entryMatchCount
+                if entryMatchCount > 0 {
+                    repeatedProtocolCopies.recordReported(entry, readingAs: interface.text)
+                }
             }
             corpora[imagePath]?.lastSearchedAt = now
             if !batch.isEmpty {
@@ -626,7 +643,8 @@
             scannedImagePaths: scannedImagePaths,
             scannedObjectCount: scannedObjectCount,
             isTruncated: totalMatchCount > collectedCount,
-            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: query.imagePaths)
+            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: query.imagePaths),
+            omittedRepeatedMatchCount: omittedRepeatedMatchCount
         )
     }
 
@@ -647,7 +665,8 @@
 
     /// The member counterpart of `searchInterfaces`: member names matched
     /// with the text search's match styles, optional kind filter, same
-    /// collection and counting rules. An empty query matches no member.
+    /// collection and counting rules — repeated protocol copies included. An
+    /// empty query matches no member.
     func searchMembers(
         _ query: RuntimeMemberSearchQuery,
         indexedImagePaths: Set<String>,
@@ -659,6 +678,8 @@
         var collectedCount = 0
         var scannedObjectCount = 0
         var scannedImagePaths: [String] = []
+        var repeatedProtocolCopies = RuntimeInterfaceRepeatedProtocolCopies()
+        var omittedRepeatedMatchCount = 0
         let now = Date()
         for imagePath in searchedImagePaths(within: query.imagePaths) {
             try Task.checkCancellation()
@@ -671,6 +692,12 @@
                 // Projected only once a member of this entry matches: most
                 // entries have none, and they cost nothing.
                 var projection: (projection: VisibilityProjection, lineStartOffsets: [Int])??
+                // The text the entry reads as, and whether it repeats a
+                // protocol copy already reported — settled at its first
+                // matching member, so an entry without one is never compared.
+                var shownText: String?
+                var isRepeatedProtocolCopy = false
+                var entryMatchCount = 0
                 for (memberIndex, member) in entry.members.enumerated() {
                     if let kinds = query.kinds, !kinds.contains(member.kind) { continue }
                     guard let range = RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern) else { continue }
@@ -685,11 +712,24 @@
                             shownMember = projectedMember
                         }
                     }
+                    if shownText == nil {
+                        let text = (projection ?? nil)?.projection.text.text ?? entry.interface.text
+                        shownText = text
+                        isRepeatedProtocolCopy = repeatedProtocolCopies.isRepeated(entry, readingAs: text)
+                    }
+                    if isRepeatedProtocolCopy {
+                        omittedRepeatedMatchCount += 1
+                        continue
+                    }
+                    entryMatchCount += 1
                     totalMatchCount += 1
                     guard collectedCount < query.resultLimit else { continue }
                     batch.append(RuntimeMemberMatch(object: entry.object, member: shownMember, matchRangeInName: range))
                     collectedCount += 1
                 }
+                if entryMatchCount > 0, let shownText {
+                    repeatedProtocolCopies.recordReported(entry, readingAs: shownText)
+                }
             }
             corpora[imagePath]?.lastSearchedAt = now
             if !batch.isEmpty {
@@ -701,7 +741,8 @@
             scannedImagePaths: scannedImagePaths,
             scannedObjectCount: scannedObjectCount,
             isTruncated: totalMatchCount > collectedCount,
-            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: query.imagePaths)
+            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: query.imagePaths),
+            omittedRepeatedMatchCount: omittedRepeatedMatchCount
         )
     }
```

```diff
--- a/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeInterfaceSearch.swift
+++ b/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeInterfaceSearch.swift
@@ -154,16 +154,22 @@
     /// the UI can say what the search did not see. Only the images the query
     /// covers count: every indexed image, or those of its `imagePaths`.
     public let unbuiltIndexedImagePaths: [String]
+    /// Hits in Objective-C protocol copies that read exactly like a copy the
+    /// search already reported hits in — the same declaration, carried by
+    /// another image. Neither collected nor part of `totalMatchCount`; the UI
+    /// can say how many were folded into the copy it shows.
+    public let omittedRepeatedMatchCount: Int
 
     public var scannedImageCount: Int {
         scannedImagePaths.count
     }
 
-    public init(totalMatchCount: Int, scannedImagePaths: [String], scannedObjectCount: Int, isTruncated: Bool, unbuiltIndexedImagePaths: [String]) {
+    public init(totalMatchCount: Int, scannedImagePaths: [String], scannedObjectCount: Int, isTruncated: Bool, unbuiltIndexedImagePaths: [String], omittedRepeatedMatchCount: Int = 0) {
         self.totalMatchCount = totalMatchCount
         self.scannedImagePaths = scannedImagePaths
         self.scannedObjectCount = scannedObjectCount
         self.isTruncated = isTruncated
         self.unbuiltIndexedImagePaths = unbuiltIndexedImagePaths
+        self.omittedRepeatedMatchCount = omittedRepeatedMatchCount
     }
 }
```

**复现测试（示例）**：新建 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RuntimeInterfaceRepeatedProtocolCopyTests.swift`。要用 `@testable` 读取 store 和可见性类型，所以不放进不带 `@testable` 的 `RuntimeInterfaceSearchTests`。
- 先用 `#require` 确认两个镜像都带 `NSCopying`，并且在这组选项下两份读起来一样；系统变了，测试会明确失败，而不是悄悄失效。
- 修复前，Text 和 Members 两个「只来自一个镜像」的断言都会红（两个镜像各报一次）。
- `omittedRepeatedMatchCount` 的断言依赖新字段，和字段一起加入。
```swift
import Foundation
import Testing
@testable import RuntimeViewerCore

/// An Objective-C protocol two images carry alike is one declaration: a
/// search over both reports it once, from the image it reads first.
@Suite("Repeated Objective-C protocol copies", .serialized)
struct RuntimeInterfaceRepeatedProtocolCopyTests {
    private enum Anchors {
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
        static let coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    @Test("a protocol both images carry alike is reported once, by text and by member")
    func repeatedCopyReportedOnce() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-repeated-protocol-copies")
        try await engine.connect()
        defer { Task { await engine.stop() } }
        for imagePath in [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath] {
            try await engine.loadImage(at: imagePath)
        }
        for imagePath in [Anchors.coreFoundationPath, Anchors.foundationPath] {
            _ = try await engine.buildInterfaceCorpus(for: imagePath, transformer: .default)
        }
        let options = RuntimeObjectInterface.GenerationOptions()
        let isCopyingProtocol: (RuntimeObject) -> Bool = { $0.kind == .objc(.type(.protocol)) && $0.name == "NSCopying" }

        // Both carry `NSCopying`, and it reads alike in both under these options.
        let visibility = RuntimeInterfaceVisibility(options)
        var shownTexts: [String] = []
        for imagePath in [Anchors.coreFoundationPath, Anchors.foundationPath] {
            let entries = try #require(await engine.interfaceCorpusStore.corpus(for: imagePath)?.entries)
            let copy = try #require(entries.first { isCopyingProtocol($0.object) }, "\(imagePath) no longer carries NSCopying")
            shownTexts.append((copy.projection(under: visibility)?.text ?? copy.interface).text)
        }
        try #require(shownTexts[0] == shownTexts[1], "the two copies of NSCopying no longer read alike")

        var textMatches: [RuntimeInterfaceSearchMatch] = []
        let textSummary = try await engine.searchInterfaces(RuntimeInterfaceSearchQuery(text: "copyWithZone", generationOptions: options)) { batch in
            textMatches += batch
        }
        let textImagePaths = Set(textMatches.filter { isCopyingProtocol($0.object) }.map(\.object.imagePath))
        #expect(textImagePaths.count == 1, "NSCopying reported from \(textImagePaths)")
        #expect(textSummary.omittedRepeatedMatchCount > 0)

        var memberMatches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "copyWithZone:", kinds: [.objcMethod], isCaseSensitive: true, generationOptions: options)) { batch in
            memberMatches += batch
        }
        let memberImagePaths = Set(memberMatches.filter { isCopyingProtocol($0.object) }.map(\.object.imagePath))
        #expect(memberImagePaths.count == 1, "NSCopying reported from \(memberImagePaths)")
    }
}
```

**裁决理由（Swift 类的 ObjC 面，建议不修，将来写进 KnownIssues）**：
- 桥接 Swift 类的 ObjC 面和 Swift 面是两份不同的接口：侧栏两份都列，`counterpart(for:)` 能在两者之间跳转。
- 两面描述的是同一个类型，但打印出的事实不同：
  - ObjC 面才有运行时名（`_TtC7SwiftUI18SharedMenuDelegate`）、选择子（`menuDidClose:`、`menu:willHighlightItem:`）、经 ObjC 采纳的协议（`<NSMenuDelegate>`），以及 ivar 偏移和 IMP 地址；
  - Swift 面才有 Swift 类型（`SwiftUI.MenuHoverDelegate`）和内存布局。
- 一个名字在两面各命中一次，命中的是两段不同的文本，两条结果都有用。把任何一面从语料里拿掉，都会让只在那一面出现的文本搜不到。
- 模块 F 在关系树里用 Swift 面替换 ObjC 面（PR121.13 的同类）：那里比的是类型身份；这里搜的是文本，两件事不同。
- 可以以后再做的展示改进：结果行为 ObjC 面加注对应的 Swift 名，归 Find 界面模块（D2），不在这一批。

**同类**：
- 关系树里的同一问题由 PR121.13（模块 F）处理，代表副本的选择规则与本条一致。
- 嵌套类型的重复早已在 1954a8a5 用嵌套块区间处理过，不属于本条。

**工作量**：S（协议副本部分）。如果 PR121.06 先合入，就把这里的改动搬进它抽出的扫描函数里；会话侧的跨补搜去重留给 D1 评估。


### PR121.73 旧版注入 payload 收到不认识的命令可能被标成断开

- **严重度**：待核实（若成立：Minor）
- **审查编号**：新发现（模块 C 提出，未经审查投票）
- **状态**：部分核实；方案待核实后再定，代码未改

**问题**：
- 一个非沙盒的 App 被注入的 payload（`RuntimeViewerServer`）通过 mach service 与 RuntimeViewer 通信。
- 用户升级 RuntimeViewer 后，目标进程里留下的仍是旧版 payload，新版 App 会经注入端点登记表重新连上它。
- 新版 App 此后发出的任何旧 payload 不认识的命令（本 PR 的语料命令就属于这类）都得不到回复，还会让 payload 一侧的连接状态被标成断开。
- 推测的后果：App 端的请求一直挂着，Report 的行停在 Waiting，Find 的搜索一直转圈。

**已核实的部分**（读代码确认）：读的是 v3.0.0-beta.6 实际依赖的版本：它的锁文件钉的是 SwiftyXPC 0.5.105 和 swift-helper-service 0.3.3，与本 PR 相同。
1. 非沙盒 payload 以 `.remote(role: .server)` 提供服务（`RuntimeViewerServer.swift:65`），对应 `RuntimeXPCMachServiceServerConnection`，内部是 `HelperPeerServer`（`RuntimeCommunicator.swift:94`、`RuntimeXPCMachServiceConnection.swift:216-224`）。
2. App 发给 payload 的消息，到达的是 payload 的匿名 `XPCListener` 接受下来的连接。SwiftyXPC 在接受连接时，会把 listener 的 `errorHandler` 复制到这条连接上（0.5.105 的 `XPCListener.swift:233`）。
3. 消息名没有对应的处理器时，`respond(to:)` 抛出 `unexpectedMessage`，交给 `errorHandler`，然后直接返回，**不发回复**（0.5.105 的 `XPCConnection.swift:563-571`）。
4. `HelperPeerServer` 的 listener `errorHandler` 遇到任何错误都会发出 `.disconnected(error)`（swift-helper-service 0.3.3 的 `HelperPeerServer.swift:252-256`）。
5. `RuntimeXPCMachServiceConnection` 把它转成 `.disconnected(error:)`（`RuntimeXPCMachServiceConnection.swift:66-76`）。payload 的 `RuntimeEngine` 随之进入断开状态，并置 `needsReregistrationOnConnect = true`（`RuntimeEngine.swift:424-430`）。
6. 读到的代码里，没有任何地方因此拆掉连接：`RuntimeViewerServer.swift` 不观察引擎状态。

**未核实的部分**：
- **A. App 端那次请求最后怎样了。**
  - `connection.h` 只写了「远端提前退出时，回复处理器收到 `XPC_ERROR_CONNECTION_INTERRUPTED`」，没写「远端收下消息却不回复」时会怎样。
  - 若一直挂着：协调器的请求永远停在 Waiting；PR121.35 的合并刷新也会被这次挂起的请求堵住，之后不再刷新。
  - 若返回错误：每个镜像各记一条 Failed，与 PR121.37 的情形相同，但错误内容不同，PR121.37 的识别方式认不出它。
- **B. payload 被标成断开后，有没有用户看得见的影响**，例如之后推送的 `imageNodes` 是否还能到达 App。
- **C. 实际出现的频率**：只有「升级 App 后，目标进程还活着、并经登记表重连」才会碰到。

**怎么验证**：
1. **进程内测试，回答 A 和第 2、3 条机制**。在 `RuntimeViewerCommunicationTests/RuntimeXPCServiceConnectionTests.swift` 里加一条，复用匿名 listener 装置。`RuntimeXPCServiceListenerConnection` 底下同样是 SwiftyXPC，它的 `handlePeerError` 也会在出错时把状态置为 `.disconnected`，机制与 `HelperPeerServer` 相同。
   - 先让客户端完成 hello，成为 listener 的 peer。
   - 再发一个 listener 没有注册的消息名，用 3 秒的 watchdog 包住。
   - 记录客户端是挂住还是抛错（抛的是哪种错误），以及 listener 的 `state` 是否变成 `.disconnected`。
   - 测试一开始只记录现象；结论确定后，改成对应的断言，作为回归测试保留下来。
   ```swift
   @Test("A message the listener has no handler for: what the sender gets, and what the listener reports")
   func unknownMessageOverXPC() async throws {
       let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
       listener.activate()
       let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint))
       defer {
           client.stop()
           listener.stop()
       }
       #expect(listener.state == .connected, "the hello did not adopt the client")

       let sending = Task {
           try await client.sendMessage(name: "com.RuntimeViewer.Tests.unknownCommand", request: "x")
       }
       let watchdog = Task {
           try? await Task.sleep(for: .seconds(3))
           sending.cancel()
       }
       let result = await sending.result
       watchdog.cancel()

       // To be replaced by assertions once the outcome is known: the sender
       // either never hears back (the watchdog fires; the send does not
       // honour cancellation, so `result` arrives only if XPC answers) or
       // gets an error; the listener either stays connected or reports
       // `.disconnected`.
       print("sender outcome:", result, "listener state:", listener.state)
   }
   ```
   注意：如果发送一直挂住，`sending.result` 也会一直等下去，因为 SwiftyXPC 的发送不响应取消。正式写测试时，应换用文件里现有的、不等输家的竞速写法（照搬 `ConnectionTransportRegressionTests.swift` 的 `withTransportTimeout`）。这里为了看清两种结果才写成这样。
2. **端到端手工验证，回答 B 和 C**：
   - 安装 v3.0.0-beta.6，注入一个非沙盒 App，然后退出 RuntimeViewer。
   - 启动本 PR 的构建，让它经登记表重连，打开这个引擎和 Find。
   - 在 Console 里按目标进程过滤，看是否出现 HelperPeer 的「Listener error: …unexpectedMessage」和 payload 引擎的「Connection state -> disconnected」。
   - 同时看 Report 的行是否一直停在 Waiting，以及侧栏后续是否还能收到更新。

**核实之后的候选改法**（尚未定，待结论出来再选）：
- **按 payload 版本做门控，不发任何新命令**：
  - App 在目标进程的镜像列表里能看到 payload 的路径，也能读到磁盘上 payload framework 的 `CFBundleVersion`。
  - 版本早于支持语料的那一版时，直接把 PR121.37 的 `isCorpusUnsupportedByEngine` 置为真，协调器不再对它发语料命令。
  - 这条路不依赖对端回复，对任何版本都安全。
- **提示用户重新注入**：发现 payload 比 App 旧时提示用户；也可以只在 Find / Report 里显示一条说明。
- **不选**：先问一句「你支持哪些命令」再决定。这句询问本身就是旧对端不认识的命令，同样会触发这个问题。
- PR121.29 的取消已经做了规避：`cancelRequest` 只对新命令开启，所以它不会发给旧 payload。本条剩下的风险来自语料命令本身。

**拟修改**：待核实后再给。

**复现测试（示例）**：见上面「怎么验证」第 1 条。

**同类**：
- `RuntimeXPCServiceListenerConnection.handlePeerError` 也会把来自 peer 的错误当成断开。但 App 和它内嵌的 XPC service 一定是同一个构建，不会出现不认识的命令，所以只要知道这一点即可。
- 本 PR 之后再新增引擎命令，都会面对同一个问题；版本门控一旦落地，应当同时覆盖这些命令。

**工作量**：核实 S（一条进程内测试加一次手工验证）；修复视结论而定，版本门控约为 M。

