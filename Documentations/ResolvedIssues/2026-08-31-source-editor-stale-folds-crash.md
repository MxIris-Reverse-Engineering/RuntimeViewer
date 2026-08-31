# 2026-08-31 折叠一段代码后切换类，SourceEditor 布局时崩溃

**调查日期：** 2026-08-31
**修复落地：** 本日，见 `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/SourceEditorBridge.swift` 的 `setSource`
**所属分支：** `feature/source-editor-integration`
**Severity：** Critical —— 进程直接终止，用户丢失当前文档窗口的状态
**触发场景：** 打开 Settings › Editor 的 Use Xcode Source Editor，折叠任意一段代码，然后在侧边栏点另一个类

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 点击侧边栏切换类的瞬间进程终止。崩溃报告是 `EXC_BREAKPOINT (SIGTRAP)`，栈顶为 `SourceEditor` 的 `FoldedRegionDisplay.visibleColumnRanges(for:in:)` |
| **影响范围** | 只影响开启 Xcode 编辑器且用过折叠的会话。内置 `NSTextView` 那条路径没有折叠，完全不受影响 |
| **根因** | 折叠区是 **view** 的状态而不是 data source 的状态。`SourceEditorView.dataSource` 的 setter 不清空折叠列表，于是上一份接口的折叠区活到了下一份接口里；布局据此构造出一个上界小于下界的 `Range`，触发 Swift 前置条件 |
| **Status** | **Fixed** —— 换 data source 之前先 `foldingController.unfoldAll(animate: false)`。自动化复现测试尚未落地，原因见文末 |

---

## 现象

崩溃报告（`RuntimeViewer-2026-08-31-160105.ips`，app 3.0.0 build 20260830.08.52，macOS 26.6.2，
Xcode 26.6）的主线程栈：

```
0  SourceEditor  specialized FoldedRegionDisplay.visibleColumnRanges(for:in:) + 692
1  SourceEditor  SourceEditorLayoutManager.visibleColumnRanges(for:) + 260
2  SourceEditor  SourceEditorLayoutManager.processedLineRenderData(for:context:) + 908
3  SourceEditor  SourceEditorLayoutManager.makeLineLayer(for:) + 492
…
10 SourceEditor  @objc SourceEditorContentView.layoutSublayers(of:) + 84
11 AppKit        -[NSViewBackingLayer layoutSublayers] + 120
…
15 QuartzCore    CA::Transaction::commit() + 652
…
30 AppKit        -[NSTableView mouseDown:] + 3328
31 AppKit        -[NSOutlineView mouseDown:] + 76
```

两个细节把范围收得很窄：

1. **异常类型是 `EXC_BREAKPOINT`，不是 `EXC_BAD_ACCESS`。** 崩溃地址上的指令是 `brk #0x1`，
   即 Swift 前置条件失败的陷阱。这是"框架检查出输入不合法"，不是野指针。
2. **它发生在 `mouseDown:` 的事件跟踪循环里。** 侧边栏点击尚未返回，内容视图的重新布局就已经在
   同一次 CoreAnimation 事务里跑完了 —— 所以换文本和崩溃之间没有任何时间间隔。

---

## 根因

三段连起来才解释得了。

### 一、崩溃点判定的是"折叠区结束列 ≤ 该行长度"

崩溃偏移 `0x38788` 落在 `FoldedRegionDisplay.visibleColumnRanges(for:in:)`（`0x384D4`）内。
反汇编显示这个 `brk` 只有一个入口：

```
38684:  cmp  x23, x26          ; x23 = 该行长度，x26 = 折叠区结束位置的列号
38688:  b.lt 0x38788           ; 行长 < 折叠结束列 → trap
…
385e8:  stp  x26, x23, [x8, #0x20]   ; 正常路径：把 x26 ..< x23 存进结果数组
```

即函数在构造 `foldEnd.column ..< lineLength` 这个 `Range<Int>`，而 `lineLength` 比
`foldEnd.column` 还小 —— `Range` 的 `lowerBound <= upperBound` 前置条件失败。

**折叠区记录的位置，对不上它所在那一行的实际长度。**

### 二、换 data source 不会清掉折叠区

折叠状态存在 `FoldingController` 上，而这个对象属于 view（`SourceEditorView.foldingController`
是一个 stored `let`，dump 里字段偏移 `0x38`），不属于 data source。

`SourceEditorView.dataSource` 的 setter（`0x3D3484`）在折叠这一侧只做一件事：调用
`FoldingController.dataSource` 的 didSet（`0x51E88`）。而那个 didSet 从头到尾只重建
delimiter data（字段 `0x30`），**从不触碰 `allFolds`（字段 `0x68`）**。

Xcode 自己踩不到：它一个文档一个编辑器实例，从不给活着的 view 换 data source。而
`SourceEditorBridge` 复用同一个 view 展示每一份接口 —— 这个用法是本项目独有的。

### 三、于是旧折叠区遇上新文本

`visibleColumnRanges` 取折叠区的入口是 `FoldingController.foldedRanges(containing:)`（`0x52AC8`），
它直接读 `allFolds`；数组为空就返回空数组，调用方随即提前返回 `nil`，整个断言不可达。

反过来，只要 `allFolds` 里还留着一条按旧文本记录的折叠区，而新文本对应行更短，就必然触发第一段
那个 `b.lt`。

---

## 与 Xcode 版本无关

`SourceEditor.framework` 是运行时从系统注册的 `com.apple.dt.Xcode` 加载的，所以第一反应会怀疑
Xcode 版本。实测排除：

- 崩溃报告里 `SourceEditor` 的 UUID 是 `cbba3d3b-632d-38ec-9bcd-545b1176ba82`，与本机
  `/Applications/Xcode.app`（26.6）的二进制**完全一致**（崩溃机器上它装在
  `/Applications/Xcode-26.6.0.app`，只是路径不同）。
- 崩溃点前后 32 字节在 **26.5 与 26.6 中逐字节相同**。
- 27.0 Beta 6 里同名函数仍然存在（地址移到 `0xD228C`）。

换 Xcode 版本修不好这个问题。

---

## 修复

`setSource` 在换 data source **之前**展开全部折叠：

```swift
sourceEditorView.foldingController.unfoldAll(animate: false)

sourceEditorView.dataSource = dataSource
```

三个决定各有依据：

**为什么在赋值之前。** `unfoldAll` 会让被折叠的行重新布局
（`SourceEditorDataSource.evictLineLayerForLine(_:relayout:layoutManagerIdentifier:)` +
`notifyDataSourceUpdatedLayoutInfo()`）。此刻 data source 还是折叠区被记录时的那一个，两者自洽；
放到赋值之后就会在展开的过程中撞上同一个断言。

**为什么 `animate: false`。** `unfoldAll(animate:)`（`0x5655C`）转发给私有的
`unfold(ranges:select:restoreNestedFolds:animate:)`（`0x565EC`）。`animate: true` 把工作交给
`FoldingAnimationController.runAnimation` 稍后完成；`animate: false` 走同步分支，在返回前就由
`updateAllFolds`（`0x56AE4`）改写 `allFolds`（`+0x68`）并把 `_cascadedFoldedRanges` 缓存
（`+0x70`）置 nil。对一个下一行就要换 data source 的调用方来说，只有后者可用。

**为什么可以每次都调。** `unfold(ranges:…)` 的第一件事就是 `ranges` 为空即返回，而
`unfoldAll` 传的是 `topLevelFolds`。绝大多数接口从未被折叠过，这条路径上没有任何开销。

### stub 侧的改动

`FoldingController` 此前不在 `Stubs/SourceEditor.framework` 的接口子集里，本次按
`Stubs/README.md` 的三条规则新增：

| 声明 | 依据 |
|---|---|
| `public class FoldingController`（原生 Swift 类，非 `NSObject`） | `AuditClasses.sh` 报 `native`；dump 中是 `class FoldingController {`，无超类 |
| `public func unfoldAll(animate:)`（不加 `final`） | `AuditMembers.sh` 报 `thunk=1 direct=0`，导出为 dispatch thunk |
| `public final var foldingController: FoldingController { get }` | `AuditMembers.sh` 报 `thunk=0 direct=1`，与 `contentView` / `layoutManager` 同形 |

`UsedSymbols.txt` 相应增加两个符号，`Generate.sh` 重新生成 `.tbd`（仍为 8 KB）。

---

## 验证

构建：Debug 与 Release × arm64 与 x86_64 四种组合全部通过，四个产物的 `nm -u` 里都出现且仅出现
新增的那两个符号，说明 stub 声明与实际引用一致。

复现测试落在新建的 `RuntimeViewerSourceEditorBridgeTests` target 里（`SourceEditorStaleFoldTests`），
两个测试分工不同：

| 测试 | 撤掉修复后的表现 |
|---|---|
| `swappingTheSourceClearsTheFolds` | 断言失败，打印出残留的那条折叠区 `Range(line: 1, col: 0 ..< line: 4, col: 191)` |
| `layoutSurvivesASwapToShorterTextWhileFolded` | **进程被 SIGTRAP 杀死**，退出码 133 |

红绿都实测过：把 `unfoldAll` 那行注释掉，整个 bundle 退出码 133；恢复后 `2 tests passed`，退出码 0。

**第二个测试失败的方式是杀死 test runner，没有任何测试框架能捕获 `EXC_BREAKPOINT`。** 第一个
测试因此排在前面并断言同一个不变量——回归时先得到一句能读的诊断，然后 runner 才死。

两个决定值得记：

- **离屏就够。** 崩溃要的是一个 layer-backed view 的 `layoutSublayers(of:)` 跑在 CoreAnimation
  事务里，不是可见窗口。`NSWindow` + `orderFront(nil)` + `CATransaction.flush()` 即可，无需
  屏幕交互，也无需 app 宿主。
- **测试驱动 bridge，不是裸的 `SourceEditorView`。** 受测的顺序在 `SourceEditorBridge.setSource`
  里；自建视图的测试无论那个方法怎么写都会通过。

### 怎么跑

test target 已登记进 `RuntimeViewerUsingAppKit.xctestplan`。但走 scheme 的那条路
（`xcodebuild test -scheme "RuntimeViewer macOS"`）在本机跑不起来：它要先构建整个 app target，
而那一步缺 `RuntimeViewerMobileServer.framework`（与本测试无关的既有问题）。测试本身是无宿主的，
不需要 app，所以直接跑 bundle：

```sh
xcodebuild -project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj \
  -target RuntimeViewerSourceEditorBridgeTests -configuration Debug ARCHS=arm64 \
  SYMROOT=<产物目录> OBJROOT=<中间产物目录> build
cd <产物目录>/Debug && xcrun xctest RuntimeViewerSourceEditorBridgeTests.xctest
```

没装 Xcode 的机器上，`-weak_framework` 让 bundle 照常加载、类查不到，`.enabled(if:)` 把两个测试
跳过——是 skip，不是失败。

### 工程文件的改法

新 target 是手工写进 `project.pbxproj` 的：本会话没有 Xcode MCP，而 `xcodeproj` gem 打不开
`objectVersion = 90` 的工程（它不认数组形式的 `shellScript`，也不认新的 `dstSubfolder`）。
对象结构照抄同样手工添加的 bridge target，标识符用相邻的 `E95ED17F` 段。改完先在副本上
`plutil -convert xml1` 验语法，再 `xcodebuild -list` 验语义。

## 相关

- 此前唯一与折叠有关的改动是 `6404cda0 fix(content): separate the text from the folding ribbon`，
  处理的是折叠条与正文之间的间距，与本问题无关。
- 折叠条默认开启（`Settings.Editor.showsFoldingRibbon` 默认 `true`），但 Xcode 编辑器本身默认
  关闭（`usesSourceEditor` 默认 `false`），所以只有主动开过这个开关的用户会遇到。
