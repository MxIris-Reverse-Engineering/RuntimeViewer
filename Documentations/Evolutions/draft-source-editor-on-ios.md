# Draft - iOS 版内容区接入重建版 SourceEditor

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-28
- **最后更新**: 2026-11-29
- **所属愿景**: [iOS 功能对齐](../Visions/IOSFeatureParity.md)（第五步「iOS 前端逐项补齐」里的一项）
- **关联提案**: [0009-content-editor-engine-selection](0009-content-editor-engine-selection.md)（macOS 选用 SourceEditor）；[0072-reconstructed-source-editor](0072-reconstructed-source-editor.md)（直接链接重建版、钉版本加 SHA-256）；[0080-source-editor-release-update](0080-source-editor-release-update.md)（`UpdateSourceEditorScript.sh`）；[0074-source-editor-reading-aids](0074-source-editor-reading-aids.md)（回到上次读到的位置、同名高亮）；[0101-settings-screen-on-ios](0101-settings-screen-on-ios.md)（iOS 设置页复用 Mac 的 SwiftUI 页面）；重建版仓库的 0014（UIKit 层）与 0015（UIKit 示例 App）
- **实现分支 / PR**: `feature/source-editor-on-ios`（从 `next` 切出），worktree `.worktrees/RuntimeViewer-SourceEditorOnIOS`
- **配套文档**: 待定 —— 落地时判断；至少要改 `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`、`RuntimeViewerUsingUIKit/AGENTS.md` 与根 `AGENTS.md` 的 SourceEditor 一节
- **网页版**: 同目录同名的 `.html`

## 摘要

iOS 版（`RuntimeViewerUsingUIKit`，iPhone 与 iPad）的内容区从 `UITextView` 换成重建版 SourceEditor 的 UIKit 版，和 macOS 一样经 `RuntimeViewerSourceEditorBridge` 驱动。重建版的 UIKit 层只发在 26.6 线上，所以 iOS 单独钉 `26.6.10`（新的 `PinnedRelease-iOS.txt`，框架下载到 `Frameworks-iOS/<平台>/`），macOS 留在 `27.2.0-alpha.2` 不动。桥接框架从只编 macOS 改为 macOS、iOS 真机、iOS 模拟器三处都编：平台无关的逻辑（语义着色、同名高亮、阅读位置）两边共用，视图层 iOS 另写一个 `UIKitSourceEditorBridge`。第一版在 iOS 上提供语法与语义着色、设置里的主题、行号、小地图、MARK 分隔线、插入点、同名高亮、系统查找（导航栏的放大镜按钮与 ⌘F）和回到上次读到的位置；Settings › Editor 页在嵌了框架的 iOS 版上出现，只列这几项。越狱版（arm64e，框架没有这个切片）、visionOS（上游不支持）和没下载到框架的检出照旧用 `UITextView`。点击跳转、注释标签与折叠、行内展开不在这一篇。

## 动机

完整动机见愿景《[iOS 功能对齐](../Visions/IOSFeatureParity.md)》：iOS 上的 RuntimeViewer 自己就能当完整的查看器用。这一步特有的部分：

- **iOS 的内容区还停在早期 Mac 版的水平。** `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/ContentTextViewController.swift` 是一个不可编辑的 `UITextView`，显示 `ContentTextRenderer` 上了色的属性字符串：没有行号、没有小地图、没有查找、没有同名高亮，长接口滚回去也找不到刚才读到哪里。macOS 早在 0009 / 0072 就换成了 SourceEditor。
- **上游已经具备能力。** 重建版仓库的 0014 照 Swift Playgrounds 4.7 给 26.6 复刻加了 iOS 与 Mac Catalyst 的 UIKit 层，0015 补了 UIKit 示例 App，从 26.6.7 起每个 release 的 xcframework 都带 `ios-arm64` 与 `ios-arm64-simulator` 切片（26.6.10 于 2026-11-27 发布）。RuntimeViewer 只差接上。
- **macOS 的桥接已经把难点做完。** 语义着色（`SemanticNodeTypeAdjuster`）、声明解析短路（`SourceModelDeclarationShortCircuitOverride`）、同名高亮（`SymbolOccurrenceProvider`）这几块只依赖共享框架类型，在 UIKit 下能原样编译（前期调研第 3 条），iOS 不必重写。

## 前期调研

以下出处中，重建版的文件都在 tag `26.6.10` 上、相对 `/Volumes/Repositories/Private/Personal/Library/macOS/SourceEditor`；RuntimeViewer 的文件相对仓库根。缩写：SEV = `SourceEditor/iOS/SourceEditorView.swift`。

### 1. 重建版的 UIKit 版在哪条线、带什么切片

- UIKit 层由重建版 0014 加在 main（26.6 线）上，随 26.6.7 发布；之后 26.6.8–26.6.10 都带。`26.6.10:Package.swift:11` 声明 `platforms: [.macOS(.v14), .iOS(.v18), .macCatalyst(.v17)]`。
- **27 线没有 UIKit**：合进 UIKit 的提交 `2fb58a810` 不是 `27.2.0-alpha.2`、也不是 `origin/xcode-27` 的祖先；`27.2.0-alpha.2:Package.swift` 只声明 `.macOS(.v14)`。27 线目前停工（`origin/xcode-27` 最新一条记录的是周额度重置时停在哪里）。0014 的非目标里写着「`xcode-27` 线的 UIKit 支持：那条线合 main 时再说」。
- 26.6.10 的 `_CodeCompletionFoundation.xcframework/Info.plist`（2026-11-28 下载核对）有四片：`macos-arm64`、`ios-arm64`、`ios-arm64-simulator`、`ios-arm64-maccatalyst`，**每片只有 arm64**。README 的「Platforms」一节：iOS 18、模拟器与 Catalyst 只编 arm64，Intel Mac 不支持。
- 越狱版 target `RuntimeViewerUsingUIKit-JB` 是 `ARCHS = arm64e`（`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit.xcodeproj/project.xcproj:203`），链接不了只有 arm64 的框架。visionOS 不在 0014 的平台里。
- iOS 真机切片未签名（重建版 `Configurations/Project.xcconfig` 的 `CODE_SIGNING_ALLOWED[sdk=iphoneos*] = NO`），runpath `@executable_path/Frameworks`、动态库、开了 library evolution（`Configurations/Framework.xcconfig`）：App 要自己嵌入并签名。主题资源在框架里，不需要另外的资源 bundle；iOS 不需要额外链接系统框架（`Configurations/SourceEditor.xcconfig`，只有 Catalyst 另链 AppKit）。

### 2. UIKit 版缺什么

UIKit 下不编的文件在 `Documentations/Reference/UIKit/UIKitExcludedFiles20261122.tsv`（632 行，第二列 `macos`）。与 RuntimeViewer 有关的：

- **折叠**：`Folding/FoldingController.swift`、`FoldedRegionDisplay.swift`、`MarginAccessories/FoldingRibbon.swift` 等都排除。
- **行内展开**：`Gaps/SourceEditorGapController.swift` 等 Gap 系列全部排除。
- **吸顶标题**：`StickyHeaders/` 整个排除；**缩进参考线**：`LayoutVisualizations/ScopeGuides/` 排除。
- **macOS 的查找面板**：`macOS/FindAndReplacePanel/` 排除；iOS 用系统的 `UIFindInteraction`（SEV:134 的 `findInteraction`）。
- macOS 版 `SourceEditor/macOS/SourceEditorView.swift` 整个排除；iOS 版 `SourceEditorView` 继承 `UIScrollView`，自己实现 `UITextInput`。

### 3. 桥接用到的 API 在 UIKit 下的情况

逐项核对了 `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/` 的 10 个文件（2026-11-28，读 26.6.10 源码，未编译）：

- **有**：`SourceEditorView(frame:)`、`contentView`（SEV:585）、`layoutManager`（584）、`dataSource`（600）、`isEditingEnabled`（1317）、`hideCursorWhenEditingDisabled`（1325）、`gutter`（443；`MarginAccessories/SourceEditorGutter.swift:91` 的 `lineNumberFont` 是 `UIFont`、`enableLineNumbers()` 在 :68）、`installMinimap()` / `uninstallMinimap()`（495、505）、`setMinimapLandmarkIconProvider`（513；图标协议返回 `CGImage`，`Minimap/MinimapLandmarkIconProvider.swift:3`）、`showInvisibles()` / `hideInvisibles()`（400、404）、`showMarkSeparators()` / `hideMarkSeparators()`（537、542）、`selectedSymbolHighlightDelay`（1295）、`showCallout(for:)`（1043）、`findQuery`（1051）、`setTheme(_:)`（56）、`colorTheme` / `fontTheme`（74、66）、`contentViewContentMargins`（104）。
- **共享、无平台条件**：`SourceEditorDataSource(usingMutableString:language:formattingOptions:)`（`DataSource/SourceEditorDataSource.swift:35`）、`SourceModelLanguageService.nodeTypeAdjuster` / `hostExtension`（`SourceModelSupport/LanguageService/SourceModelLanguageService.swift:172、164`）、`tokenRangeAtPosition`（:1575）、`SourceEditorTheme(name:dictionary:fontSizeModifier:)`（`CoreEditor/Layout/SourceEditorTheme.swift:14`）、布局覆盖与 `LayoutVisualization`（`CoreEditor/Layout/`）。
- **换了签名**：`selectTextRange(_:scrollIfNeeded:)`（SEV:1340）；`positionAtPoint(_:absolute:)`（1847）；`perform(TextFindAction)`（`FindAndReplace/TextFindable.swift:73`）。`setSelection(…scrollPlacement:)` 与 `scrollTo(position:…)` 在 iOS 上是空壳（SEV:1331、926），能滚的是 `scrollToLine` 与 `scrollToSelection`（1205、887）。
- **没有**：`scrollView`（iOS 版本身就是滚动视图）、`enableCmdClickMultiCursor`、`contextualMenuItemProvider`、`addCursorRectOverrideProvider`、`scrollStateForStateRestoration` / `applyScrollState`、`defaultScrollViewContentInsets`、`scopeGuidesVisualization`、`install/uninstallFoldingRibbon`、`install/uninstallStickyHeaders`、`editorGapController`、`foldingController`。
- **四个逻辑文件能原样编**：`SemanticNodeTypeAdjuster.swift`（`SMSourceNodeTypes.h:11–12`、`SMSourceModelItem.h:51、54` 无平台条件，只需把 `import AppKit` 换掉）、`SymbolOccurrenceProvider.swift`、`SourceModelDeclarationShortCircuitOverride.swift`（`SMSourceModel.h:123`）。`ReadingStateCache.swift` 本身只用 Foundation，但它存的折叠状态与滚动状态在 iOS 上都取不到，iOS 改存 `contentOffset`。
- **注释标签与行尾标签**（`CommentDecorationController.swift`、`LineEndTagController.swift`）用的布局覆盖与 `LayoutVisualization` 在 UIKit 下都在，画得出来；但「可折叠」整套靠 `FoldingController`，点击靠 `handleMouseEvent(NSEvent)` 的 event consumer。iOS 上事件管理器的点击识别器只收间接指针（`iOS/EventHandling/SourceEditorEventManager.swift:29、37、44`），`SEEvent` 的字段不公开（`Utils/UIView+SourceEditorLayout.swift:69–75`）。
- **26.6.10 与 27.2.0-alpha.2 之间，桥接用到的共享 API 签名没有一处不同**：`SourceModelNodeTypeAdjuster.swift`、`SourceModelLanguageService.swift`、`SourceEditorLanguageService.swift`、`SMSourceNodeTypes.h`、`SMSourceModelItem.h`、`MinimapLandmarkIconProvider.swift`、`LandmarkType.swift` 在两个 tag 间完全相同；其余共享文件只差 27 把 `PlatformView` 之类的别名直接写成了 AppKit 类型。所以同一份共享逻辑能同时对着两个版本编。

### 4. iOS 版的接法（重建版的 UIKit 示例）

`Examples/SourceEditorUIKitExample/SourceEditorUIKitExample/SampleEditorViewController.swift`（下称 Sample）：

- 主题：`SourceEditorTheme.defaultDark` / `.defaultLight` 按 `userInterfaceStyle` 选，`setTheme(_:)`，外观变化时 `registerForTraitChanges` 重设（Sample:132–135、67）。两个内置 `.xccolortheme` 经 `Bundle(for:)` 读取（`SourceEditorTheme.swift:546`），iOS 版也带着。
- 行号：自建 `SourceEditorGutter` 赋给 `editorView.gutter`；**每次换主题都要重设 `lineNumberFont` 并再调一次 `enableLineNumbers()`**；文字左边距在设主题前写 `contentViewContentMargins.left`（Sample:98、134、140–141）。
- 文本：每次新建 `SourceEditorDataSource` 赋给 `dataSource`（Sample:157–160）。语言：`SourceModelEditorLanguage.swift`、`.objc`、`.cpp`（`SourceModelSupport/LanguageService/SourceModelEditorLanguage.swift:88、73、55`）。
- 查找：`editorView.findInteraction.presentFindNavigator(showingReplace: false)`（Sample:196）；视图成为第一响应者后系统的 ⌘F、⌘G 自动可用（0015 调研）。
- 不可见字符：**要 App 自带 SF Mono 的三个字重并登记在 `UIAppFonts`，缺一个就在画不可见字符时崩溃**（示例 README「Invisible characters need SF Mono」）。
- 首响应者：页面出现时由控制器自己抢首响应者，免得键盘自己弹出（Sample:84–86）。示例里没有 `isEditingEnabled = false` 的用法。

### 5. 只读时点按（推测，未实测）

- 单击走 `SetSelectionRange`：光标附近 20pt 内选中单词，否则放光标，然后 `becomeFirstResponder()`（`iOS/EventHandling/Actions/SetSelectionRange.swift:7–17、41`）；双击还会走 `ShowKeyboard`（SEV:189–196）。`canBecomeFirstResponder` 只看 `isInteractive`（SEV:1996），框架里没有压住软键盘的代码。**推测只读时一点也会弹键盘**，没实测。
- 打字改不了文本：`replaceTextInRange` 经 `isEditableInRange` 拦下（`EditAssistant/SourceEditorEditAssistant.swift:153` → SEV:2197）。

### 6. 头文件冲突

- macOS 不让 App 直接 import SourceEditor，是因为它的头文件声明了 AppKit 私有的 `NSScrollViewDelegate`，与 `UIFoundationAppleInternalObjC` 冲突（`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`）。那个声明在 `TARGET_OS_OSX` 条件里（`Headers/SourceEditorScrollViewSupport.h:3、22`），iOS 上不出现。
- iOS 上伞头文件会带进 `UIKitSPI.h`（`SourceEditorSupport.h:27`），声明 `@interface UIKeyboardImpl : UIView` 与 UIView、UIScrollView、UIWindow、UIEvent 的私有 category（`UIKitSPI.h:11–42`）。UIFoundation 与 AppKitPlus 的本地检出里没有同名声明（查的是检出当前代码，不是 RV 钉的发布版）。module map 没有 `export *`。所以 iOS 照旧只在桥接里 `internal import`，App 不碰 SourceEditor 模块。

### 7. RuntimeViewer 这边的现状

- **桥接 target**：`RuntimeViewerUsingAppKit.xcodeproj/project.xcproj:471–492`，framework，synchronized folder 在 :144，最后一个脚本 phase「Copy SourceEditor Frameworks to Products」跑 `BuildPhases/EmbedSourceEditorFrameworks.sh "${BUILT_PRODUCTS_DIR}"`（:485–490）。设置在 `Configurations/RuntimeViewerSourceEditorBridge/Shared.xcconfig`：`FRAMEWORK_SEARCH_PATHS[arch=arm64*] = $(SRCROOT)/../RuntimeViewerPrecompiledLibraries/SourceEditor/Frameworks`（:20）、`BUILD_LIBRARY_FOR_DISTRIBUTION = YES`、`MACOSX_DEPLOYMENT_TARGET = 15.0`；平台来自工程级 `SDKROOT = macosx`（`Configurations/RuntimeViewerUsingAppKitProject/Shared.xcconfig:54`）。
- **公开接口全是 AppKit**：`SourceEditorBridging.swift` 与 `SourceEditorBridgeFactory.swift` 无条件 `import AppKit`，协议里用到 `NSView`、`NSColor`、`NSFont`、`NSMenuItem`、`NSImage`、`NSTextView`。其余 8 个文件在 `#if arch(arm64) && canImport(SourceEditor)` 里，其中 5 个 `import AppKit`。
- **下载脚本只取 macOS 切片**：`FetchSourceEditorScript.sh:104` 取 `"$name.xcframework"/macos-*/"$name.framework"`，要求恰好一个；`Frameworks/PinnedRelease.txt` 是「已下载哪一版」的标记，:65 用 `cmp` 判断要不要下载，:111–112 整体替换 `Frameworks/`。`EmbedSourceEditorFrameworks.sh:43–46` 发现标记与 pin 不一致就报错；没下载时删掉旧拷贝、给 note、正常结束（:35–39）。`UpdateSourceEditorScript.sh` 只认一个 pin 文件（:35），按 pin 的大版本线取最新（:99–113）。
- **调用 Fetch 的地方**：`RunScript.sh:217`、`TuistScript.sh:1850`（失败继续），`ArchiveScript.sh:399`（失败就停），`.github/workflows/release.yml:134–141`（CI 用 `SOURCE_EDITOR_RELEASES_TOKEN`）。**正式发版每次都编 iOS 模拟器版**：`release.yml:168` 总带 `--include-ios-simulator`，`ArchiveScript.sh:481–496` 用 scheme「RuntimeViewer iOS」、`generic/platform=iOS Simulator`、`CODE_SIGNING_ALLOWED=NO`；另有 `BuildSimulatorScript.sh:9`。
- **iOS 工程**：三个 target 共用 synchronized folder `RuntimeViewerUsingUIKit/`（:36–68），build settings 全写在工程文件里，没有 xcconfig 层、没有 Debug-arm64e。iOS 版 `IPHONEOS_DEPLOYMENT_TARGET = 18.0`（:142）、没设 `ARCHS`、没有 embed phase；工程级 `ENABLE_USER_SCRIPT_SANDBOXING = YES`（:351）。越狱版已有跨工程依赖 `RuntimeViewerServer.xcodeproj` 的 `RuntimeViewerMobileServer`（:168–180）。依赖按它自己的 `SDKROOT` 编，只有 `SDKROOT = auto` 才跟随宿主 App 的平台（`Configurations/AGENTS.md:27–33`）。iOS 工程不在 Tuist 里。
- **macOS 内容区怎么选**：`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift:78–91`，`sourceEditorBridgeProvider.isAvailable` 为真用 `ContentSourceEditorViewController`，否则 `ContentTextViewController`，两者绑同一个 `ContentTextViewModel`。`ContentSourceEditorViewController.swift` 里平台无关、可抽出来的：`semanticNodeTypes(of:)`（:441）、`languageIdentifier(for:interfaceLanguage:)`（:462）。`SourceEditorThemeConversion.swift`（151 行）只在 `themeString(for: NSColor)` / `themeString(for: NSFont)`（:142、148）用到 AppKit；它的 `syntaxColorKey(for:)` 也被语义区间用作节点类型名；AppUI 的 `ThemeProfile` 已用 `NSUIColor` / `NSUIFont`（`RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Theme/ThemeProfile.swift:16–24`）。
- **`ContentTextViewModel` 在 iOS 上可用**，`Output` 的字段都在；但取数一段在 iOS 走 `#else`（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentTextViewModel.swift:190–221`）：转换选项固定为默认值，注释结构、宏展开、C 导入类型名标签都关着；三个派生开关在 `Base/ViewModel.swift:62–89`，只在 AppKit 下编。**附带发现：iOS 已有的 Transformer 设置页因此不作用于内容区**——不在本篇修，登记为后续项。
- **iOS 没有任何代码跟随 `SelectionRoute`**：`ContentTextViewModel` 解析出点中的对象后发 `.focusEditorPane` 与 `.open(…)`（:698–700），但只有 macOS 的 `MainCoordinator.swift:85` 订阅 `documentState.routeSignal`；iOS 的 `MainCoordinator.swift:55–70` 只靠 `MainRoute.select`。愿景第四步原本就计划让 iOS 照 Mac 走 `SelectionRoute`。
- **设置**：`Settings.Editor`（`RuntimeViewerSettings/Settings+Types.swift:93–141`）无平台限定。`RuntimeViewerSettingsUI/Components/EditorSettingsView.swift` 整个是 `#if os(macOS)`，依赖 `SourceEditorFrameworks.availability`；`RuntimeViewerSettings/SourceEditorFrameworks.swift` 整个是 `#if os(macOS)`，二进制路径写死 `Versions/A`。iOS 的页面列表在 `RuntimeViewerSettingsUI/SettingsViewController.swift:17–29`（四页）。

## 提议方案

### 版本与下载

- **iOS 单独一个 pin**：新增 `RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease-iOS.txt`，格式同 `PinnedRelease.txt`，钉 `26.6.10` 与四个框架（SourceEditor、SourceModel、SourceModelSupport、_CodeCompletionFoundation；桥接不用 SourceEditorRegExSupport）的 SHA-256，取自 26.6.10 的 `Package.swift`。macOS 的 `PinnedRelease.txt` 不动。等 27 线有了 UIKit，再合成一个 pin（后续项）。
- **iOS 的框架放 `Frameworks-iOS/`**：`Frameworks-iOS/iphoneos/<Name>.framework`（`ios-arm64` 切片）、`Frameworks-iOS/iphonesimulator/<Name>.framework`（`ios-arm64-simulator` 切片），加标记文件 `Frameworks-iOS/PinnedRelease-iOS.txt`。子目录用 `PLATFORM_NAME` 的值命名，嵌入脚本直接拼路径。macOS 的 `Frameworks/` 布局不变，所以 macOS 的搜索路径、测试 rpath、`ArchiveScript.sh` 的核对都不用改。`.gitignore` 加这个目录。
- **`FetchSourceEditorScript.sh` 加 `--platform macos|ios|all`**，默认 `all`；每个平台独立做「标记相同就跳过」与整体替换，互不影响。`RunScript.sh`、`TuistScript.sh` 只编 macOS，改传 `--platform macos`；`ArchiveScript.sh` 在带 `--include-ios-simulator` 时取 `all`，取不到照旧停下；`release.yml` 的取框架一步取 `all`。
- **`UpdateSourceEditorScript.sh` 加 `--platform macos|ios`**（默认 `macos`，保持现有用法），按所选 pin 文件的大版本线取最新：iOS 停在 26 线、macOS 停在 27 线。
- **`EmbedSourceEditorFrameworks.sh` 按 `PLATFORM_NAME` 选 pin 与来源**：`macosx` → `Frameworks/` 与 `PinnedRelease.txt`；`iphoneos` / `iphonesimulator` → `Frameworks-iOS/$PLATFORM_NAME` 与 `PinnedRelease-iOS.txt`。iOS 框架是浅层 bundle，`ditto` 与 `codesign` 照常用；没签名身份（模拟器、`CODE_SIGNING_ALLOWED=NO`）就不签。

### 桥接框架改成双平台

- `RuntimeViewerSourceEditorBridge` 的 xcconfig：`SDKROOT = auto`、`SUPPORTED_PLATFORMS = macosx iphoneos iphonesimulator`、`IPHONEOS_DEPLOYMENT_TARGET = 18.0`；搜索路径按 SDK 分开（`[sdk=macosx*][arch=arm64*]` → `Frameworks`，`[sdk=iphoneos*][arch=arm64*]` → `Frameworks-iOS/iphoneos`，`[sdk=iphonesimulator*][arch=arm64*]` → `Frameworks-iOS/iphonesimulator`）；iOS 的 runpath `@executable_path/Frameworks @loader_path/Frameworks`。macOS 的值一个不改。
- **守卫照旧是 `#if arch(arm64) && canImport(SourceEditor)`**：模拟器的通用构建（`generic/platform=iOS Simulator`）也编 x86_64，与 macOS 的 Intel 切片同样编空，`isAvailable` 为 `false`。只在 macOS 用的文件在这层守卫之外再加 `#if os(macOS)`，只在 iOS 用的加 `#if os(iOS)`。
- **公开协议 `SourceEditorBridging` 按平台声明**：成员名与参数在两个平台上相同，只有平台类型不同的成员用 `#if os(macOS) … #else … #endif` 各写一份（`editorView`、`applyBackgroundColor(_:)`、`applyTheme(…lineNumberFont:)`、地标图标协议的返回值）；只有 macOS 能做的成员整个包进 `#if os(macOS)`（导航委托、注释标签外观、顶部内边距、`revealCharacterRange(_:)`、行内展开、行尾标签、折叠命令）。不引入新的公开别名，macOS 的调用点一行不改（详细设计）。
- **iOS 的视图层是新类 `UIKitSourceEditorBridge`**（`#if os(iOS)`，与 macOS 的 `SourceEditorBridge` 同在一个 target；Swift 不允许一个模块里有两个同名源文件，所以类名也不同）。它用 `ReadOnlySourceEditorView`（`SourceEditorView` 的子类，压住软键盘）做编辑器视图，实现 `setSource`、主题、四项显示选项、查找、同名高亮与阅读位置。`SourceEditorBridgeFactory.makeBridge()` 按平台返回两者之一，`builtInThemeDictionary(named:)` 同样。
- **四个逻辑文件两边共用**：`SemanticNodeTypeAdjuster`、`SourceModelDeclarationShortCircuitOverride`、`SymbolOccurrenceProvider` 只换 import；`ReadingStateCache` 改成按存储状态泛型，macOS 存原来的折叠与滚动状态，iOS 存 `contentOffset`。

### App 这边

- **两端共用的值下沉到 AppUI**：`SourceEditorThemeConversion` 从 macOS App 搬到 `RuntimeViewerAppUI/Theme/`，颜色与字体改用 `NSUIColor` / `NSUIFont`（UIKit 下另写颜色转字符串）；新增 `SourceEditorSourceDescription`（`RuntimeViewerAppUI/Content/`），由 `ContentInterface` 与对象种类算出 `setSource` 要的四样东西：文本、语言标识、UTF-16 语义区间、节点类型名。macOS 的 `ContentSourceEditorViewController` 改用它，删掉自己的两个私有静态方法。
- **iOS App 只有 iOS target 接入**：`RuntimeViewerUsingUIKit` target 加对桥接 target 的跨工程依赖、「Embed SourceEditor Bridge」copy phase、「Embed SourceEditor Frameworks」脚本 phase（同一个脚本）、`ENABLE_USER_SCRIPT_SANDBOXING = NO` 与编译条件 `RUNTIME_VIEWER_SOURCE_EDITOR`。新文件放在三个 target 共用的 synchronized folder 里，整个包在 `#if RUNTIME_VIEWER_SOURCE_EDITOR` 中：越狱版与 visionOS 没有这个条件，编出来是空文件，不链接桥接。**不用 `canImport(RuntimeViewerSourceEditorBridge)` 判断**：越狱版与 iOS 版同在 `Debug-iphoneos` 产物目录，iOS 版编过之后越狱版也能 import 到桥接模块，链接时才失败。
- **iOS 的内容页**：新增 `ContentSourceEditorViewController`（`UIKitViewController<ContentTextViewModel>`），`ContentCoordinator` 在桥接可用时用它、否则照旧 `ContentTextViewController`。它订阅 `output.interface` → `SourceEditorSourceDescription` → `bridge.setSource`，之后报 `interfaceDisplayed`；订阅 `ContentTextRenderer.theme` → `SourceEditorThemeConversion.themeDictionary` → `applyTheme` 与 `applyBackgroundColor`（深浅以 `traitCollection.userInterfaceStyle` 选内置的 `Default (Dark)` / `Default (Light)` 作底）；`observe` `settings.editor` → `applyDisplayOptions(from:)`；导航栏标题照旧用 `runtimeObjectName`；导航栏右侧加放大镜按钮，点了 `showFindInterface(query: "", pattern: .contains, isCaseSensitive: false)`。
- iOS 的 `SourceEditorBridgeProvider` 与 `SourceEditorBridging+Settings` 各写一份 iOS 版（`@Dependency` 规则照旧），只做可用性、建桥与取内置主题，不做 macOS 那套为小地图预热的事（小地图默认关）。

### 设置

- `SourceEditorFrameworks` 放开平台限定：iOS 上看 `Bundle.main.privateFrameworksURL` 下的浅层 bundle（`<Name>.framework/<Name>`），macOS 照旧 `Versions/A`；路径的拼法写成按布局参数化的纯函数，以便在 macOS 上测。Settings › Developer 里显示「运行在哪份副本上」的部分仍只在 macOS。
- `EditorSettingsView` 在 iOS 上也编，**iOS 只列四项**：行号、小地图、MARK 分隔线、插入点；折叠条、吸顶标题、缩进参考线、不可见字符、注释标签只在 macOS 列。macOS 的页面不变。
- iOS 的 `SettingsViewController` 在 `SourceEditorFrameworks.availability` 为可用时加「Editor」页，否则不加——越狱版与 visionOS 看不到这一页。

### 非目标

- **点击跳转**：iOS 没有任何代码跟随 `SelectionRoute`（前期调研第 7 条），点中了也不会跳；这属于愿景第四、五步，到时 `UITextView` 与 SourceEditor 两种内容页一起接。
- **注释标签与折叠、C 导入类型名的行尾标签**：iOS 的 `ContentTextViewModel` 不取注释结构与宏展开，放开它属于愿景第四步「AppCore 放开平台限定」；折叠在 UIKit 版里没有。
- **行内展开（宏展开预览）、吸顶标题、缩进参考线、折叠条**：UIKit 版没有。
- **不可见字符**：要在 App 里自带 SF Mono 三个字重，涉及字体的授权，另议。
- **越狱版与 visionOS**：框架没有 arm64e 切片，上游不支持 visionOS。
- **iOS 上的右键与长按菜单、交叉引用**：后续随点击跳转一起做。
- **macOS 的任何行为变化**、**合成一个 pin**、**Tuist 覆盖 iOS 工程**、**修 iOS 的 Transformer 设置不生效**（登记为后续项）。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease-iOS.txt` | 新增 | 钉 `26.6.10` 与四个框架的 SHA-256 | UIKit 版只在 26.6 线 | 1 |
| `.gitignore` | 修改 | 加 `/RuntimeViewerPrecompiledLibraries/SourceEditor/Frameworks-iOS/` | 下载目录不进仓库 | 1 |
| `FetchSourceEditorScript.sh` | 修改 | `--platform macos\|ios\|all`；iOS 取 `ios-arm64` 与 `ios-arm64-simulator` 切片放 `Frameworks-iOS/<PLATFORM_NAME>/`；每个平台独立的标记与替换 | iOS 要两片、另一个版本 | 1 |
| `UpdateSourceEditorScript.sh` | 修改 | `--platform macos\|ios`，选 pin 文件，按它的大版本线取最新 | 两条线各自换版 | 1 |
| `RuntimeViewerUsingAppKit/BuildPhases/EmbedSourceEditorFrameworks.sh` | 修改 | 按 `PLATFORM_NAME` 选 pin 与来源目录 | iOS App 与 iOS 版桥接共用这个脚本 | 1 |
| `RunScript.sh`、`TuistScript.sh` | 修改 | 调 Fetch 时传 `--platform macos` | 只编 macOS，不多下 iOS | 1 |
| `ArchiveScript.sh` | 修改 | 带 `--include-ios-simulator` 时取 `--platform all`，取不到就停 | 发版的 iOS 模拟器版要带框架 | 1 |
| `.github/workflows/release.yml` | 修改 | 取框架一步传 `--platform all` | 同上 | 1 |
| `Configurations/RuntimeViewerSourceEditorBridge/Shared.xcconfig` | 修改 | `SDKROOT = auto`、`SUPPORTED_PLATFORMS`、`IPHONEOS_DEPLOYMENT_TARGET = 18.0`、按 SDK 分开的搜索路径与 iOS runpath | 桥接跟着宿主 App 的平台编 | 2 |
| `RuntimeViewerUsingAppKit/Project.swift`、`Tuist/` | 不改 | 平台设置都在 xcconfig 里，Tuist 的桥接 target 照旧声明为 macOS；`./TuistScript.sh check` 的设置接线与 target 名单一致 | 根 `AGENTS.md` 要求同一 commit 更新 Tuist 描述，核对后不需要 | 2 |
| `RuntimeViewerSourceEditorBridge/SourceEditorBridging.swift` · `SourceEditorBridging` 等 | 修改 | 平台类型成员按平台各写一份；macOS 独有成员与类型包进 `#if os(macOS)` | 让公开接口在 iOS 上编得过 | 2 |
| `RuntimeViewerSourceEditorBridge/SourceEditorBridgeFactory.swift` | 修改 | 按平台 import；`makeBridge()`、`builtInThemeDictionary(named:)` 按平台选实现 | 同上 | 2、4 |
| `RuntimeViewerSourceEditorBridge/SourceEditorBridge.swift`、`CommentDecorationController.swift`、`LineEndTagController.swift`、`InlineExpansionView.swift` | 修改 | 外层再包 `#if os(macOS)` | 它们只能在 AppKit 下编 | 2 |
| `RuntimeViewerSourceEditorBridge/SemanticNodeTypeAdjuster.swift`、`SymbolOccurrenceProvider.swift`、`SourceModelDeclarationShortCircuitOverride.swift` | 修改 | `import AppKit` 换成 Foundation | 两边共用 | 2 |
| `RuntimeViewerSourceEditorBridge/ReadingStateCache.swift` · `ReadingStateCache` | 修改 | 按存储状态泛型（`ReadingStateCache<ReadingState>`） | iOS 存 `contentOffset` | 2、4 |
| `RuntimeViewerSourceEditorBridge/UIKitSourceEditorBridge.swift` · `UIKitSourceEditorBridge` | 新增 | iOS 的桥：数据源、语言服务与语义类型、主题与行号、四项显示选项、查找、同名高亮、阅读位置 | iOS 的视图层 | 4 |
| `RuntimeViewerSourceEditorBridge/ReadOnlySourceEditorView.swift` · `ReadOnlySourceEditorView` | 新增 | `SourceEditorView` 子类，`inputView` 返回空视图、`isEditingEnabled = false` | 只读时点按不弹键盘 | 4 |
| `RuntimeViewerSourceEditorBridgeTests/` | 修改 | 更新两处提到 `SourceEditorThemeConversion` 的注释；补 `ReadingStateCache` 泛型后的用例 | 搬家与泛型化 | 2、3 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/SourceEditorThemeConversion.swift` | 移动 | 搬到 `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Theme/SourceEditorThemeConversion.swift`，改用 `NSUIColor` / `NSUIFont`，UIKit 下另写颜色转字符串 | 两端共用 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Content/SourceEditorSourceDescription.swift` · `SourceEditorSourceDescription` | 新增 | 由 `ContentInterface` 与对象种类算出文本、语言标识、语义区间、节点类型名 | 从 macOS 控制器抽出，两端共用 | 3 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentSourceEditorViewController.swift` | 修改 | 改用 `SourceEditorSourceDescription`，删掉 `semanticNodeTypes(of:)`、`languageIdentifier(for:interfaceLanguage:)` | 去重；macOS 行为不变 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/SourceEditorThemeConversionTests.swift`、`SourceEditorSourceDescriptionTests.swift` | 新增 | 主题字典的键与值、UTF-16 区间、语言标识 | 共用逻辑在 macOS 上测 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/SourceEditorFrameworks.swift` | 修改 | 放开平台限定；iOS 的浅层 bundle 路径；路径拼法按布局参数化；「运行在哪份副本上」仍只在 macOS | iOS 判断框架是否嵌入 | 3 |
| `RuntimeViewerPackages/Tests/…/SourceEditorFrameworksTests.swift` | 新增 | 两种布局的二进制路径 | 在 macOS 上测 iOS 的路径 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/EditorSettingsView.swift` | 修改 | 放开平台限定，iOS 只列四项 | iOS 的 Editor 页 | 5 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsViewController.swift` | 修改 | 框架可用时加「Editor」页 | 越狱版、visionOS 不显示 | 5 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit.xcodeproj/project.xcproj` | 修改 | 引用 AppKit 工程；iOS target 加桥接依赖、两个 embed phase、`ENABLE_USER_SCRIPT_SANDBOXING = NO`、`SWIFT_ACTIVE_COMPILATION_CONDITIONS` 加 `RUNTIME_VIEWER_SOURCE_EDITOR` | 只有 iOS 版接入 | 5 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/ContentSourceEditorViewController.swift` · `ContentSourceEditorViewController` | 新增 | iOS 的 SourceEditor 内容页 | 替代 `UITextView` | 5 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/SourceEditorBridgeProvider.swift` · `SourceEditorBridgeProvider` | 新增 | 可用性、建桥、内置主题；`@DependencyEntry` | 控制器经 `@Dependency` 取 | 5 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/SourceEditorBridging+Settings.swift` | 新增 | `applyDisplayOptions(from:)` | 设置变化时一次传给桥 | 5 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/ContentCoordinator.swift` | 修改 | 桥接可用时建 SourceEditor 内容页 | 选择显示方式 | 5 |
| `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`、根 `AGENTS.md`、`RuntimeViewerUsingUIKit/AGENTS.md` | 修改 | 两个 pin、iOS 布局与守卫、编译条件、iOS 内容页 | 规则跟着代码走 | 6 |
| `Documentations/Visions/IOSFeatureParity.md`、`Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 相关提案表加一行；索引；后续项 | 文档索引 | 6 |

## 架构图

改了什么：

```text
RuntimeViewerPrecompiledLibraries/SourceEditor/
  PinnedRelease.txt                     macOS, 27.2.0-alpha.2          (unchanged)
+ PinnedRelease-iOS.txt                 iOS, 26.6.10
  Frameworks/<Name>.framework           macos-arm64 slices             (unchanged)
+ Frameworks-iOS/iphoneos/              ios-arm64 slices
+ Frameworks-iOS/iphonesimulator/       ios-arm64-simulator slices

RuntimeViewerUsingAppKit.xcodeproj
~ RuntimeViewerSourceEditorBridge.framework      macosx -> macosx + iphoneos + iphonesimulator (SDKROOT = auto)
~   SourceEditorBridging                         per-platform members; macOS-only ones under #if os(macOS)
~   SourceEditorBridgeFactory                    picks the platform's bridge
~   SourceEditorBridge                           #if os(macOS)
~   CommentDecorationController, LineEndTagController, InlineExpansionView    #if os(macOS)
~   SemanticNodeTypeAdjuster, SymbolOccurrenceProvider,
~   SourceModelDeclarationShortCircuitOverride   shared by both platforms
~   ReadingStateCache<ReadingState>              folds + scroll on macOS, contentOffset on iOS
+   UIKitSourceEditorBridge                      #if os(iOS)
+   ReadOnlySourceEditorView                     #if os(iOS), no software keyboard
  RuntimeViewerUsingAppKit (macOS app)
~   Content/ContentSourceEditorViewController    uses SourceEditorSourceDescription
-   Content/SourceEditorThemeConversion          moved to RuntimeViewerAppUI

RuntimeViewerPackages
  RuntimeViewerAppUI
+   Theme/SourceEditorThemeConversion            moved here, NSUIColor / NSUIFont
+   Content/SourceEditorSourceDescription        text, language, semantic ranges, node type names
  RuntimeViewerSettings
~   SourceEditorFrameworks                       builds on iOS, shallow bundle layout
  RuntimeViewerSettingsUI
~   Components/EditorSettingsView                builds on iOS, lists 4 options there
~   SettingsViewController (iOS)                 + "Editor" page when the frameworks are embedded

RuntimeViewerUsingUIKit.xcodeproj
~ RuntimeViewerUsingUIKit (iOS app)              + bridge dependency, + 2 embed phases, + RUNTIME_VIEWER_SOURCE_EDITOR
+   Content/ContentSourceEditorViewController
+   Content/SourceEditorBridgeProvider
+   Content/SourceEditorBridging+Settings
~   Content/ContentCoordinator                   picks the pane
  RuntimeViewerUsingUIKit-JB, RuntimeViewerUsingVision    (unchanged: no flag, UITextView)
```

iOS 上一页内容怎么显示、框架怎么进 App：

```text
ContentCoordinator, route .root(object)
└─ sourceEditorBridgeProvider.isAvailable
   ├─ true  → ContentSourceEditorViewController(ContentTextViewModel)
   │    output.interface ─► SourceEditorSourceDescription(interface, kind)
   │                        └─► bridge.setSource(text, language, semanticRanges, nodeTypeNames)
   │                            └─► input.interfaceDisplayed
   │    ContentTextRenderer.theme ─► SourceEditorThemeConversion.themeDictionary(...)
   │                                 └─► bridge.applyTheme / applyBackgroundColor
   │    observe settings.editor ─► bridge.applyDisplayOptions(from:)
   │    find bar button ─► bridge.showFindInterface(...) ─► UIFindInteraction
   └─ false → ContentTextViewController (UITextView, unchanged)

FetchSourceEditorScript.sh --platform ios
└─► Frameworks-iOS/$(PLATFORM_NAME)/<Name>.framework
    ├─► bridge: FRAMEWORK_SEARCH_PATHS[sdk=iphone*][arch=arm64*]
    └─► iOS app phase "Embed SourceEditor Frameworks" ─► App/Frameworks (+ codesign)
```

## 详细设计

### 桥接的公开协议

macOS 的调用点不变；iOS 上同名成员换成 UIKit 类型，macOS 独有的成员不存在。

```swift
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@objc(RuntimeViewerSourceEditorBridging)
public protocol SourceEditorBridging: NSObjectProtocol {
    init()

    #if os(macOS)
    var editorView: NSView { get }
    var navigationDelegate: SourceEditorBridgingNavigationDelegate? { get set }
    #else
    var editorView: UIView { get }
    #endif

    var minimapLandmarkIconProvider: SourceEditorBridgingMinimapLandmarkIconProvider? { get set }

    /// On iOS `commentDecorations` is ignored: the decorations need the framework's folding,
    /// which its UIKit build does not have.
    func setSource(
        _ source: String,
        languageIdentifier: String,
        semanticRanges: [NSValue],
        semanticNodeTypeNames: [String],
        commentDecorations: SourceEditorBridgingCommentDecorations?,
        restoresScrollPosition: Bool
    )

    /// On iOS `showsFoldingRibbon`, `showsStickyHeaders`, `showsScopeGuides` and `showsInvisibles`
    /// are ignored: the framework's UIKit build has no folding ribbon, sticky headers or scope
    /// guides, and invisibles need SF Mono bundled with the app.
    func applyDisplayOptions(
        showsLineNumbers: Bool,
        showsFoldingRibbon: Bool,
        showsStickyHeaders: Bool,
        showsMinimap: Bool,
        showsScopeGuides: Bool,
        showsInvisibles: Bool,
        showsMarkSeparators: Bool,
        showsInsertionPoint: Bool
    )

    #if os(macOS)
    func applyBackgroundColor(_ backgroundColor: NSColor)
    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: NSFont)
    #else
    func applyBackgroundColor(_ backgroundColor: UIColor)
    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: UIFont)
    #endif

    /// On iOS this presents the system find navigator (`UIFindInteraction`) with `query` as its
    /// search text; `pattern` and `isCaseSensitive` are macOS-only and ignored.
    func showFindInterface(query: String, pattern: SourceEditorBridgingFindPattern, isCaseSensitive: Bool)

    #if os(macOS)
    func applyCommentTagAppearance(_ appearance: SourceEditorBridgingCommentTagAppearance)
    func applyTopContentInset(_ topInset: CGFloat)
    func revealCharacterRange(_ characterRange: NSRange)
    func showInlineExpansion(/* unchanged */)
    func hideInlineExpansion(identifier: String)
    func isInlineExpansionShown(identifier: String) -> Bool
    func showLineEndTags(_ tags: [SourceEditorBridgingLineEndTag])
    #endif
}
```

- `SourceEditorBridgingMinimapLandmarkIconProvider` 的返回值同样按平台：macOS `NSImage?`，iOS `UIImage?`（桥接取 `cgImage` 交给框架）。iOS 的 App 第一版不设图标提供者，标签照框架的规则「没有提供者就不建」；后续项。
- `SourceEditorBridgingNavigationDelegate`、`SourceEditorBridgingCodeFoldingCommands`、`SourceEditorBridgingCommentTagAppearance`、`SourceEditorBridgingLineEndTag`、行内展开的两个类型整个包进 `#if os(macOS)`；`SourceEditorBridgingCommentDecorations`、`SourceEditorBridgingFindPattern`、`SourceEditorBridgingLandmarkKind`、注释的两个样式枚举两边都编（只用 Foundation）。
- 为什么不加公开的平台别名：桥接不链接 UIFoundation，再声明一组 `NSUIColor` 式的公开别名会让 App 同时看到三家的同名别名；按平台各写一份只多四个成员，且不引入新名字。照 Apple 自己的跨平台 API（同一个名字在 AppKit 与 UIKit 上各自声明）。

### iOS 的桥

```swift
#if os(iOS) && arch(arm64) && canImport(SourceEditor)
internal import SourceEditor
internal import SourceModel
internal import SourceModelSupport
import UIKit

final class UIKitSourceEditorBridge: NSObject, SourceEditorBridging {
    private let sourceEditorView = ReadOnlySourceEditorView(frame: .zero)
    private let gutter = SourceEditorGutter()
    private let readingStateCache = ReadingStateCache<CGPoint>()
    var editorView: UIView { sourceEditorView }
    // setSource: new SourceEditorDataSource(usingMutableString:language:formattingOptions:) per text,
    // the same SemanticNodeTypeAdjuster and declaration short circuit as macOS, then restores the
    // cached contentOffset (or scrolls to the top) once the layout manager has laid the lines out.
    // applyTheme: SourceEditorTheme(name:dictionary:fontSizeModifier:), setTheme(_:), then
    // gutter.lineNumberFont = lineNumberFont and enableLineNumbers() again (Sample:134, 140–141).
    // applyDisplayOptions: gutter on/off, installMinimap()/uninstallMinimap() guarded by
    // isMinimapShown, show/hideMarkSeparators(), hideCursorWhenEditingDisabled = !showsInsertionPoint.
    // showFindInterface: findInteraction.searchText = query; presentFindNavigator(showingReplace: false).
}

final class ReadOnlySourceEditorView: SourceEditorView {
    // No software keyboard for a text that cannot be edited; the view still becomes first
    // responder, which the find interaction and the selection need.
    override var inputView: UIView? { UIView(frame: .zero) }
}
#endif
```

- 阅读位置：macOS 的缓存键与规则不变（按显示过的文本记，`restoresScrollPosition` 为假时不恢复）；iOS 的值是 `contentOffset`，在 `sourceEditorViewDidFinishLayingOutLines` 之后才设，避免被首次布局冲掉。
- `ReadOnlySourceEditorView` 压键盘的写法是推测（前期调研第 5 条）；第 4 步编完、第 6 步在模拟器上验证，不成立就改用别的办法（例如框架的 `isInteractive`）。

### 两端共用的值

```swift
// RuntimeViewerAppUI/Content/SourceEditorSourceDescription.swift
public struct SourceEditorSourceDescription: Equatable {
    public let source: String
    /// `"swift"`, `"objc"` or `"cpp"`.
    public let languageIdentifier: String
    /// UTF-16 ranges into `source`, parallel to `semanticNodeTypeNames`.
    public let semanticRanges: [NSRange]
    public let semanticNodeTypeNames: [String]

    public init(interface: ContentInterface, objectKind: RuntimeObjectKind)
}

// RuntimeViewerAppUI/Theme/SourceEditorThemeConversion.swift (moved, same members)
public enum SourceEditorThemeConversion {
    public static func syntaxColorKey(for semanticType: SemanticType) -> String
    public static func themeDictionary(
        from themeProfile: ThemeProfile,
        basedOn baseTheme: NSDictionary,
        baseThemeDimming: UnfocusedEditorPaneDimming.ColorScheme?
    ) -> NSDictionary?
}
```

- 语言标识的规则照搬 macOS 的 `languageIdentifier(for:interfaceLanguage:)`：要的是 Swift 接口就 `swift`，否则 Swift 对象 `swift`、ObjC 与 C `objc`、C++ `cpp`。`interfaceLanguage` 从 `ContentInterface` 取（实现时核对它是否带着；没有就改成 `init(interface:objectKind:interfaceLanguage:)`）。
- 主题转换的颜色字符串：AppKit 下保持现在 `NSColor` 的换算；UIKit 下取 sRGB 分量写成同样的 `"r g b a"` 格式。字体照旧写 `"<PostScript 名> - <字号>"`；iOS 上系统等宽字体的 PostScript 名能否被框架的 `UIFont(name:size:)` 解析是**推测**，第 3 步写测试时核对，不成立就在转换里对系统等宽字体写框架认得的名字。

### 设置

```swift
// RuntimeViewerSettings/SourceEditorFrameworks.swift
public enum SourceEditorFrameworks {
    public enum BundleLayout { case versioned, shallow }   // macOS, iOS
    /// `<frameworks>/<Name>.framework/Versions/A/<Name>` or `<frameworks>/<Name>.framework/<Name>`.
    static func binaryURL(forFrameworkNamed name: String, in frameworksURL: URL, layout: BundleLayout) -> URL
    public static var availability: Availability { get }   // now on iOS too
}
```

- iOS 的 Editor 页只列四项，写在 `EditorSettingsView` 里用 `#if os(macOS)` 包住其余五项；可用性说明的文字在 iOS 上不出现（不可用时整页不注册）。

## 替代方案考量

- **两端都退回 26.6.10，只留一个 pin**：否。macOS 会丢掉 27 线上的修复——行内展开的关闭按钮在 macOS 27 SDK 下点不了（`27.2.0-alpha.1`），换回来就是回归。用户定了 iOS 单钉。
- **等重建版把 UIKit 合进 27 线再接**：否。27 线停工，0014 也把它写成非目标，等不到日期。将来合成一个 pin 是后续项。
- **另建一个 iOS 专用的桥接 target**：否。四个逻辑文件要么复制、要么拆成第三个 target；同名模块在两个 target 里还会让两边的 App 各 import 一份。一个 `SDKROOT = auto` 的多平台 target 有现成先例（`RuntimeViewerMobileServer`）。
- **iOS App 直接 import SourceEditor、不经桥接**：否。`UIKitSPI.h` 带进一批 UIKit 私有声明（前期调研第 6 条），和 UIFoundation 钉的版本会不会冲突没验证；经桥接 `internal import` 与 macOS 一致，也让「没下载框架就退回 `UITextView`」只靠一个 `isAvailable`。
- **用 `canImport(RuntimeViewerSourceEditorBridge)` 区分 iOS 版与越狱版**：否。两者共用 `Debug-iphoneos` 产物目录，iOS 版编过之后越狱版也能 import 到桥接模块，链接才失败——与 AGENTS.md 里 x86_64 那条陷阱同理。
- **把 iOS 的框架也放进 `Frameworks/` 的子目录**：否。Fetch 整体替换 `Frameworks/`（`FetchSourceEditorScript.sh:111–112`），两个平台会互相删；放在旁边的 `Frameworks-iOS/` 让 macOS 的一切路径不变。
- **第一版就做点击跳转**：否。iOS 没有跟随 `SelectionRoute` 的代码，点中了不会跳；接上它属于愿景第四步，到时两种内容页一起接。
- **第一版就做注释标签（只画不折叠）**：否。iOS 的 `ContentTextViewModel` 不取注释结构，放开它属于第四步；1025 行的 `CommentDecorationController` 还要改坐标、外观与滚动监听。

## 影响

### 用户可见变化

- iOS 普通版（iPhone、iPad）的内容区变成 Xcode 风格的编辑器：行号、语法与语义着色、设置里的主题，可选小地图、MARK 分隔线、插入点。
- 点一个标识符，同名的其他出现一起高亮；切到别的对象再回来，回到上次读到的位置。
- 内容页导航栏右侧多一个放大镜按钮，打开系统查找；接了硬件键盘时 ⌘F、⌘G 可用。
- Settings 多一页「Editor」，列上面四项。
- 原来 `UITextView` 能选中文字、拷贝；SourceEditor 实现了 `UITextInput`，预计同样能选中与拷贝，只是不弹键盘（未实测，第 6 步在模拟器上看）。
- 越狱版与 visionOS 不变。

### 可发现性

- 内容区直接换，不设开关，与 macOS 的 0072 一致（0072 删掉了「用 SourceEditor」开关）。
- 显示选项的默认值沿用 `Settings.Editor` 现有的默认值，与 macOS 相同（小地图默认关）。

### 数据与配置兼容

- 不新增持久化的设置：Editor 页的四项本来就在 `Settings.Editor` 里，iOS 只是开始读它们。`accessPersistedValues()` 与 `SettingsPersistenceTests` 不用改。
- 阅读位置只在内存里，不持久化。

### 平台与最低版本

- iOS 版的最低版本本来就是 iOS 18.0，与框架一致，不变。
- 只有 arm64：真机与 Apple 芯片 Mac 上的模拟器用 SourceEditor；模拟器通用构建的 x86_64 切片退回 `UITextView`。
- macOS 不变。

### 发布

- 不需要新的权限、entitlement 或隐私清单条目。
- 发版：`release.yml` 的取框架一步多下 26.6.10 的四个 zip（约 69 MB），每次发版附带的 iOS 模拟器版会带上重建版的四个框架，体积增加。macOS 的公证、Sparkle 不受影响。
- iOS 真机版的签名：框架由 App 的嵌入脚本签；真机版目前不在发版流程里。

## 落地步骤

1. **下载与嵌入两个 pin**（已完成）—— 改动地图里的 `PinnedRelease-iOS.txt`、`.gitignore`、`FetchSourceEditorScript.sh`、`UpdateSourceEditorScript.sh`、`EmbedSourceEditorFrameworks.sh`、`RunScript.sh`、`TuistScript.sh`、`ArchiveScript.sh`、`release.yml`
   - 行为：`fetchWithPlatformIOSPutsDeviceAndSimulatorSlicesUnderFrameworksIOS`
   - 行为：`fetchWithPlatformMacOSLeavesFrameworksIOSUntouched`
   - 行为：`fetchSkipsAPlatformWhoseMarkerMatchesItsPin`
   - 行为：`embedPicksFrameworksByPlatformName`
   - 行为：`embedFailsWhenFrameworksIOSHoldsAnotherPin`
   - 行为：`updateWithPlatformIOSStaysOnThe26Line`
   - 验证：`RunScript.sh --no-launch` 照旧编过；手动跑 Fetch 的三种 `--platform` 与 `--dry-run` 的 Update。
2. **桥接框架改成双平台（还没有 iOS 实现）**（已完成）—— 桥接 xcconfig、Tuist 描述、`SourceEditorBridging.swift`、`SourceEditorBridgeFactory.swift`、四个只在 macOS 编的文件、三个共用的逻辑文件、`ReadingStateCache.swift`
   - 行为：`macOSBridgeTestsPassUnchanged`
   - 行为：`bridgeBuildsForIPhoneOSAndSimulatorWithAndWithoutFrameworks`
   - 行为：`simulatorX86SliceCompilesOutAndReportsUnavailable`
   - 行为：`readingStateCacheRestoresTheStateOfTheTextItWasRecordedFor`
   - 验证：`./TuistScript.sh check` 通过；`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md` 要求守卫改动用同一 DerivedData 连编两次 Release universal（半小时级，跑之前先说一声）。
3. **两端共用的值下沉到 AppUI 与 Settings** —— `SourceEditorThemeConversion` 搬家、`SourceEditorSourceDescription`、macOS 控制器改用它、`SourceEditorFrameworks`、三个新测试文件
   - 行为：`themeDictionaryMatchesTheMacOSConversion`
   - 行为：`semanticRangesCountUTF16OutsideTheBasicPlane`
   - 行为：`languageIdentifierIsSwiftForAGeneratedSwiftInterfaceOfAnObjCObject`
   - 行为：`languageIdentifierIsCppForCPlusPlusObjects`
   - 行为：`shallowLayoutBinaryURLHasNoVersionsDirectory`
   - 验证：`RuntimeViewerAppUITests` 与 Settings 测试全过；macOS App 编过。
4. **iOS 的桥：`UIKitSourceEditorBridge` 与 `ReadOnlySourceEditorView`** —— 两个新文件、Factory 的 iOS 分支
   - 行为：`iOSBridgeAppliesSemanticRunsThroughTheSharedNodeTypeAdjuster`
   - 行为：`iOSBridgeReappliesLineNumbersAfterATheme`
   - 行为：`iOSBridgeInstallsTheMinimapOnce`
   - 行为：`iOSBridgeIgnoresTheOptionsUIKitDoesNotHave`
   - 验证：只编译（iOS 真机与模拟器，Debug 与 Release）；iOS 没有能跑的测试宿主，上面的行为在第 6 步的模拟器验证里看。
5. **iOS App 接入** —— iOS 工程文件、三个新文件、`ContentCoordinator.swift`、`EditorSettingsView.swift`、`SettingsViewController.swift`
   - 行为：`iOSContentPaneUsesSourceEditorWhenTheBridgeIsAvailable`
   - 行为：`iOSContentPaneFallsBackToTextViewWithoutFrameworks`
   - 行为：`iOSContentPaneReportsInterfaceDisplayedAfterSetSource`
   - 行为：`editorSettingsPageAppearsOnIOSOnlyWithEmbeddedFrameworks`
   - 行为：`jailbrokenAndVisionOSBuildsDoNotLinkTheBridge`
   - 验证：iOS 版真机与模拟器编过（有框架、没框架各一次）；越狱版（`BuildJailbrokenIPAScript.sh`，只产出 ipa、不装机）与 visionOS 编过；macOS 包测试与 `RunScript.sh --no-launch` 照旧。
6. **文档与验收** —— 三份 AGENTS.md、愿景、索引
   - 行为：`readOnlyTapDoesNotShowTheKeyboard`（模拟器）
   - 行为：`findButtonPresentsTheSystemFindNavigator`（模拟器）
   - 验证：在 iPhone 与 iPad 模拟器上看效果——**要用户另外同意才能启动模拟器**；看过后登记结论。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：两个 pin 的布局与守卫写进 `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`，iOS 内容页写进 `RuntimeViewerUsingUIKit/AGENTS.md`；预计不另写实现说明。
- **有没有引入新术语**：预计没有。

### 后续项（不在本篇）

- 点击跳转与长按菜单（愿景第四、五步，两种内容页一起接）。
- iOS 的注释标签（先放开 `ContentTextViewModel` 在 iOS 上的取数，再移植 `CommentDecorationController`）。
- iOS 的 Transformer 设置不作用于内容区（`ContentTextViewModel.swift:190–221` 的 `#else` 分支）。
- 小地图的地标图标（`SourceEditorLandmarkIcon` 下沉到 AppUI，iOS 用 UIKitPlus 的 `NSIcon`）。
- 不可见字符（自带 SF Mono 的授权问题）。
- 重建版 27 线有了 UIKit 后合成一个 pin；越狱版要等重建版带 arm64e 切片。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-28 | Created as Draft | 用户要给 iOS 版接入 SourceEditor。调研发现重建版的 UIKit 层只在 26.6 线（最新 26.6.10），macOS 钉的 27.2.0-alpha.2 没有 iOS 切片；框架只有 arm64。 |
| 2026-11-28 | iOS 单钉 26.6.10，macOS 不动 | 用户定。两端都退回 26.6.10 会让 macOS 丢掉 27 线的修复；等 27 线合 UIKit 没有日期。 |
| 2026-11-28 | 越狱版与 visionOS 先不接 | 用户定。越狱版是 arm64e，框架没有这个切片；visionOS 上游不支持。两者照旧用 `UITextView`。 |
| 2026-11-28 | 点击跳转、注释标签移出第一版 | 调研发现 iOS 没有任何代码跟随 `SelectionRoute`，`ContentTextViewModel` 在 iOS 上也不取注释结构；两者都属于愿景第四步的放开平台限定，放在这里做会和那一步重叠。 |
| 2026-11-28 | 不做不可见字符 | 框架画不可见字符要 App 自带 SF Mono 三个字重，缺了会崩，自带又涉及字体授权；另议。 |
| 2026-11-29 | Accepted | 用户批准，开始实现；同时同意第 6 步在 iPhone 与 iPad 模拟器上启动 App 看效果。 |
| 2026-11-29 | In Progress；第 1 步完成 | `FetchSourceEditorScript.sh` 每个平台在自己的子 shell 里取，子 shell 自己开 errexit：放在 `\|\|` 左边时 bash 会在里面关掉 errexit，`ditto`、`mv` 失败也不会停。`ArchiveScript.sh` 带 `--include-ios-simulator` 时在 macOS 归档之前就取 iOS，缺 iOS 的框架在长时间的归档之前就停。实测：两个平台各取一次、`--check` 前后退出码 2 与 0、嵌入脚本对模拟器与 macOS 拷贝成功、标记过期与不支持的平台都报错退出 1；iOS 两片分别是 `IOS` 与 `IOSSIMULATOR` 平台、arm64、minos 18.0。 |
| 2026-11-29 | 第 2 步完成 | 桥接单独为 `iphonesimulator`、`iphoneos`、`macosx` 各编一次都过；产物目录已有框架后再编模拟器的 arm64 + x86_64，x86_64 照旧编空。iOS 上导入 SourceEditor 模块会带出框架头文件 `PlaygroundMenuController.h` 的两条 `UIMenuController` / `UIMenuItem` 废弃警告，来自重建版、不是桥接的代码，不处理。Tuist 描述不用改：平台设置都在 xcconfig 里，`./TuistScript.sh check` 的设置接线、target 名单与 trait 都一致；它报的锁文件不符（swift-type-indexing：Tuist 0.2.0、原生 0.1.1）与本次无关，这条分支没动任何锁文件与清单。macOS 桥接测试 37 条里 35 条过，红的两条是 `SourceEditorScroller` 的滚动条自动隐藏，基线上早就红（见 0064、0072）；新增 `ReadingStateCacheTests` 三条。`ReadingStateCache` 的 macOS 状态挪成 `SourceEditorBridge.ReadingState`。同一 DerivedData 连编两次 Release universal 放到第 5 步的完整验证一起跑。 |
