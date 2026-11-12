# 2026-11-11 行内宏展开左上角的关闭按钮点了没反应：行号栏盖在它上面，SDK 27 下的普通按钮不接转来的点击

**调查日期：** 2026-11-11
**修复落地：** SourceEditor `27.2.0-alpha.1`（它的 `xcode-27` 线、提案 0012），RuntimeViewer 在 `feature/observable-macro` 上把 pin 抬到这一版，RuntimeViewer 自己的代码不改。回归测试：RuntimeViewer 的 `InlineExpansionTests.dismissButtonTracksWithItsOwnMouseDown()`，SourceEditor 的 `SourceEditorGapContractTests.dismissButtonOverridesMouseDown()`
**所属分支：** `feature/observable-macro`
**Severity：** Minor —— 展开还能用右键菜单的 Hide Macro Expansion 收起
**触发场景：** 用户在 `RuntimeViewer-Local.xcworkspace` 编的 Debug 版里，在 `AppKit.StepperModel` 的 `@Observation.Observable` 上展开宏，点展开第一行行号处的 ✕，没有反应。macOS 27.2，App 链接 macOS 27.2 SDK

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 内容区用 SourceEditor 显示时，行内展开（SourceEditor 的 gap）左上角的关闭按钮点了不收起 |
| **影响范围** | 用 macOS 27 SDK 编译、跑在 macOS 27 上的 App。用 26 SDK 编的宿主（例如 Xcode 26.6 自己）不受影响 |
| **根因** | 主编辑器的行号栏浮在文档视图之上，盖住了关闭按钮；窗口的 hit-test 落在行号栏上，点击只能靠 AppKit 转给下面的按钮，而 SDK 27 下的普通 `NSButton` 由手势识别器跟踪，不接受转来的点击。重建版复刻的是 26.6，关闭按钮是普通 `NSButton` |
| **Status** | **Fixed** |

---

## 根因

关闭按钮由 SourceEditor 的 `SourceEditorGapView` 创建，位置由内容视图的 `layoutInfoForDismissButton(_:size:)` 给出。RuntimeViewer 的 `InlineExpansionView` 照 Xcode 把它放在展开自己的行号栏里、第一行行号的位置，正好在主编辑器行号栏那一列。主编辑器的行号栏（`SourceEditorGutterMarginContentView`）经 `scrollView.addFloatingSubview(_:for: .horizontal)` 浮在文档视图之上，gap 视图在文档视图里，所以窗口在按钮中心的 hit-test 落在行号栏上。行号栏既没有覆写 `hitTest(_:)`，也没有覆写 `mouseDown(with:)`（重建版 26.6.6，`ContentViewLayoutContainer.swift` 的 `addMarginAccessory`，`SourceEditorGutter.swift`）。

没处理的 mouseDown 由 AppKit 经 `-[NSView _nextResponderForEvent:]` 转给下面 hit-test 命中的兄弟视图，最后落到按钮上。用 macOS 26 SDK 编的宿主里，按钮的 `mouseDown:` 就地跑老的 tracking loop，所以 Xcode 26.6 里能点。用 macOS 27 SDK 编的宿主里，普通 `NSButton` 由 `NSControlGestureRecognizer` 跟踪：AppKit 只沿 hit-test 命中视图的 superview 链收集识别器，按钮的识别器收集不到，转来的 mouseDown 也不再起作用（`appkit-mouse-event-routing` skill，TN3212）。

## 修复

Xcode 27.2（27B52）的 SourceEditor 就是这样修的（逆向，SourceEditor UUID `6E5DBC54-96DD-3101-A63E-CDCE9E3B0572`）：私有子类 `GapDismissButton: NSButton` 只覆写 `mouseDown:`（0x1C6C4C），里面调 super；`SourceEditorGapView.init(sourceEditorView:isNested:)`（0x1CAF14）改用它。macOS 27.2 的 AppKit 里，`-[NSControl _overridesRequireMouseDownFallback]`（0x18B0E082C）见子类覆写了 `mouseDown:`，就不装手势识别器，`-[NSControl mouseDown:]`（0x18B0E775C）改走老的 tracking loop，转来的点击接得住。27.2 别处都没改：行号栏照旧浮在上面，按钮位置和各视图的 `hitTest:` 不变。

用户定重建版的 26.6 线不改逻辑，SourceEditor 因此新开 `xcode-27` 线，照 27.2 移植这一处，发 `27.2.0-alpha.1`（预发布版）。细节和汇编比对在 SourceEditor 的提案 0012 与 SourceNotes 的 `SourceEditorGapController.swift.md`。RuntimeViewer 抬 pin 即可，bridge 不用改。

## 测试为什么断言结构，而不是投递一次点击

测试里先把 mouseUp 放进事件队列，再对窗口发 mouseDown，结果在 26.6.4 和 27.2.0-alpha.1 下展开都没有收起：测试进程从来不是前台 App，这样投递的点击区分不了修复前后。投递点击能不能复现，本来就取决于测试宿主链接的 SDK 和窗口是不是 key，不适合做回归测试（`appkit-mouse-event-routing` skill）。所以测试断言 AppKit 据以决定的那件事：关闭按钮的类不是 `NSButton` 本身，而且自己的方法表里有 `mouseDown:`。在 26.6.6 下它失败（两条断言都不过），在 27.2.0-alpha.1 下通过。

另一个坑：gap 用 SourceEditor 的 `DisplayLinkedAnimation` 展开，按显示器的帧推进。显示器睡着时动画一帧都不走，gap 一直是 0 高，关闭按钮也不会被摆放。等 gap 展开的测试，要在显示器醒着时跑。

## 验证

- RuntimeViewer：`RuntimeViewerSourceEditorBridgeTests` 60 个测试，在 27.2.0-alpha.1 下只剩 `SourceEditorScrollerTests` 两条，那是 `next` 上早就存在的失败。
- 在 App 里点 ✕ 由用户验收。
