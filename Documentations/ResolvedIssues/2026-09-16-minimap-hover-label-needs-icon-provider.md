# 2026-09-16 minimap 悬停只有选中框、没有名字浮层：框架没有 icon provider 就不建浮层

**调查日期：** 2026-09-15 ～ 2026-09-16
**修复落地：** 本日，见 `SourceEditorBridge.swift` 末尾的 `MinimapLandmarkIconProvider` conformance 与 `Content/SourceEditorLandmarkIcon.swift`
**所属分支：** `next`
**Severity：** Minor —— 功能缺失，不崩不错，但 minimap 少了 Xcode 里最直观的那一半
**触发场景：** 开启 Settings › Editor 的 minimap，鼠标停在 minimap 的某一行上

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 悬停时 minimap 里出现强调色的选中框（一段范围的起止括号），但 Xcode 里贴在分割线左侧、写着 `[M] -copyWithZone:` 的那个名字浮层始终不出现 |
| **影响范围** | 只影响 Xcode 编辑器路径的 minimap。landmark 数据、宽度门槛、事件投递全部正常，是纯粹的"少注册一个对象" |
| **根因** | `MinimapView.showExpandedLandmarks(_:mainLandmark:availableWidth:)` 开头三道 guard：`attributes`、**`iconProvider`（weak）**、`layoutPass`，任一为 nil 就直接 return，一层浮层都不建。bridge 从没调过 `SourceEditorView.setMinimapLandmarkIconProvider(_:)`，Xcode 自己是 `IDESourceEditorView` conform 后把自己传进去。选中框由更早一步的 `MinimapView.highlightLandmark(_:scopeHighlight:)` 画，不受 provider 影响，所以"有框没字" |
| **Status** | **Fixed** —— bridge 无条件把自己注册为 provider；图标向 App 侧要，App 侧用 sidebar 同一套 `RuntimeObjectIcon` 渲染 |

---

## 现象

用户的描述前后收敛了三次，最后一次是关键：**"这个东西不在 minimap 里面，在 minimap 分割线的左边"**。
对照用户提供的 Xcode 视图层级捕获（`Xcode-MinimapExpanded.viewhierarchy`）：

```
MinimapExpandedLandmarkLayer  frame=(-179, 599, 161, 18)  opacity=0  masksToBounds=0
  MinimapLandmarkLayer        frame=(18, 0, 141, 18)      opacity=0.7
```

x 为负——它故意向左溢出 minimap，画在正文之上。RuntimeViewer 这边同一位置什么都没有，
连 `MinimapExpandedLandmarkLayer` 实例都没有（`expandedLandmarkLayers` 与复用池长度都是 0）。

---

## 排除过的假设（都有数据）

按时间顺序，每一条都是一轮 build + 手动悬停换来的，记下来免得下次再走：

| 假设 | 结论 | 证据 |
|---|---|---|
| landmark 树为空或名字不对 | 否 | `languageService.landmarks()` 返回完整树，`-copyWithZone:` 等名字与 Xcode 一致；`landmarksCache.lineIndex.flatLandmarks = 107` |
| 被某层 `masksToBounds` 裁掉 | 否 | 从 `SourceEditorView` 到 `MinimapVisualEffectView` 无一层裁剪 |
| minimap 太窄没到 `minWidthToShowLandmarks`（100） | 否 | 128pt，`showLandmarks = true` 两处都真 |
| `Minimap.layoutWidth` 为 nil | 否 | 669；`performLayout()` 到写入之间是直线代码 |
| 窗口没开 `acceptsMouseMovedEvents` | 无关 | 打开后无变化；tracking area 本就带 `mouseMoved` |
| `hoverLandmark` 的 `gestureState >= 2` 门槛没过 | 否 | 连续 24 次 mouseMoved 全在 state 2 下到达 |
| `shouldUpdate`（`|deltaY| < 6`）常为 false | 否 | 慢速移动下必然有小 deltaY 的样本 |
| `structureLandmark(at:)` 第二步行号对不上 | 否 | 选中框就是它成功匹配后画出来的（见下） |

**教训：每一项都在"数据齐不齐"上打转，而真正的开关在渲染函数的第一行 guard 里。**
以后遇到"某个 UI 元素从未被创建"，先去读**创建它的那个函数**的开头，再回头看数据。

---

## 根因

### hover 的完整链路（SourceEditor 26.6，地址为文件内偏移）

```
Minimap.handleMouseEvent(_:in:)                       0x19501C   .mouseMoved 分支：shouldUpdate = |deltaY| < 6
  → Minimap.updateHoverState(…)                       0x1997E8   （specialized）
    → Minimap.hoverLandmark(mouseLocation:shouldUpdate:)  0x1957E0
        guard gestureState >= 2, !didStartDragInMinimap
      → Minimap.structureLandmark(at:)                0x1970C4   见下
      → Minimap.highlightLandmark(_:)                 0x1975A8
          → MinimapView.highlightLandmark(_:scopeHighlight:)   0x1B5274   ← 画选中框（MinimapStructuredSelectionLayer）
          → MinimapView.showExpandedLandmarks(_:mainLandmark:availableWidth:)  0x1B75E8   ← 建名字浮层
```

`showExpandedLandmarks` 反编译开头：

```
guard let attributes = self.attributes else { return }              // MinimapView+0x98
guard let iconProvider = self.iconProvider /* weak */ else { return } // MinimapView+0x88
guard let layoutPass = self.layoutPass else { return }
```

`attributes` 由 `Minimap.willLayoutInContentView` 写入（minimap 能画出行就说明它非空），
`layoutPass` 探针测过是 207 行。**只剩 `iconProvider`，它在 `MinimapView`、`Minimap`、
`MinimapConfig` 三处都是 `weak var`，唯一的写入口是**

```
SourceEditorView.setMinimapLandmarkIconProvider(_:)   0x3DB958
```

它把 provider 写进 `minimapConfig.iconProvider`，若此时 minimap 已装好，再写进
`MinimapView.iconProvider`；`Minimap.init(config:)`（0x19A9D8）建视图时也从 config 拷一份。
所以**调用顺序与 `installMinimap()` 无关**，两边都覆盖。bridge 从没调过它。

Xcode 侧：`IDESourceEditorView` conform `MinimapLandmarkIconProvider`（IDESourceEditor 26.6 dump，
`icon(for:)` @ 0xBDC50），把自己传进去。协议只有一个 requirement：

```swift
protocol MinimapLandmarkIconProvider: AnyObject {
    func icon(for: LandmarkType) -> CGImage?     // PWT offset 0x8
}
```

### 为什么是"有框没字"

`Minimap.highlightLandmark(_:)` 先调 `MinimapView.highlightLandmark(_:scopeHighlight:)`
——它新建 `MinimapStructuredSelectionLayer`，给 start / end / line 三个子图层设 frame，颜色取
`controlAccentColor`，这就是用户看见的"选中框"——**然后**才在
`!isHoldingCommand && layoutWidth != nil` 下调 `showExpandedLandmarks`。前者不看 provider，
后者第二行就因 provider 为 nil 返回。

### 顺带查清的两条（与本 bug 无关，但下次会问）

- **`structureLandmark(at:)` 的匹配规则**：先在 `layoutPass.lines` 里找 frame 包含鼠标点的
  `MinimapLine`，再倒序遍历 `landmarksCache.lineIndex.flatLandmarks`，取第一个满足
  `range.lowerBound.line <= line.lineNumber <= range.upperBound.line` 的 landmark（witness +0x28
  是 `range`）。静态开关 `Minimap.restrictLandmarkHoveringToDeclaration`（一个 `UserDefaults`
  键，注册默认值 false，初始化闭包 @ 0x1918D4）为 true 时窗口收窄为
  `lowerBound.line ... lowerBound.line + 3`。
- **`LandmarksCache.isWaitingForInitialContent` 探针里一直是 true**：含义未查，但
  `updateLandmarks()`（0x438E14）不读不写它，hover 链路也不读，与本问题无关。

---

## 修复

三层，各一处：

1. **stub**（`Stubs/SourceEditor.framework/…/arm64-apple-macos.swiftinterface`）：补
   `LandmarkType`（34 个 case 按 dump 顺序全写——resilient enum 的 case 索引来自声明顺序，
   26.6 与 27.0 逐 case 相同）、`MinimapLandmarkIconProvider` 协议、
   `SourceEditorView.setMinimapLandmarkIconProvider(_:)`（有 dispatch thunk，非 `final`）。
2. **bridge**：`SourceEditorBridge` conform `MinimapLandmarkIconProvider`，`init` 里
   **无条件**注册自己——provider 为空的代价不是"没图标"而是"没浮层"，所以不能等 App 侧设了
   才注册。`icon(for:)` 把 `LandmarkType` 折成 `SourceEditorBridgingLandmarkKind`（decl / def
   合并，Xcode 画法相同），经 `@objc` 协议向 App 侧要 `NSImage`，再在 editor 的
   `effectiveAppearance` 与窗口倍率下栅格化成 `CGImage`——框架不自己画，只把它设成图层的
   `contents`，所以倍率和明暗都得在这里定。图标边长 14pt：框架取标签高减 4，标签 18pt
   （Xcode 捕获里 `MinimapLandmarkLayer` 从 x = 18 = 2 + 14 + 2 开始）。
3. **App 侧**：`ContentSourceEditorViewController` conform 桥接协议，转给
   `SourceEditorLandmarkIcon`——用 sidebar 同一套 `RuntimeObjectIcon` 出图，所以类在两处都是
   同一个 `C`；类型级 kind 按当前接口语言配色（ObjC 橙 / Swift 蓝，照抄 sidebar），方法
   `M` 蓝、属性 `P` 青、函数 `ƒ` 蓝，`// MARK:` / 文件 / 其它语言专有的 kind 不给图标。

stub 新增 39 个符号：协议描述符、requirement 描述符、`setMinimapLandmarkIconProvider` 的
dispatch thunk、`LandmarkType` 与 `MarkStyle` 的元数据访问器，以及 34 个 case 各自的索引符号
（`…FWC`，"enum case"）——对 resilient enum 做 `switch`，编译器不知道各 case 的 tag，逐个从
框架导出的这些常量里取。它们全在 26.6 与 27.0 里导出。

---

## 验证

- 实机验证（2026-09-16，用户操作）：悬停单行时浮层出现在分割线左侧，图标 + 名字，随 landmark 切换；按住 ⌘ 时全部 landmark 的浮层一起展开。两种模式都正常。
- 26.6 与 27.0 的 `LandmarkType` case 顺序、`MinimapLandmarkIconProvider` 签名、
  `setMinimapLandmarkIconProvider` 符号全部一致（`nm` 逐一比对），本修复对两个版本都成立。
