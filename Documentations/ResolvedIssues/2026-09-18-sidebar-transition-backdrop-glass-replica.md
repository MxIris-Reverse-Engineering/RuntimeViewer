# 2026-09-18 侧栏导航转场的背景色在 macOS 27 上永远差一点：系统玻璃只能用同组玻璃复刻

**调查日期：** 2026-09-17 ～ 2026-09-18
**修复落地：** 本日，见 `App/NavigationTransitionBackdropController.swift`（侧栏导航控制器的 `NSNavigationControllerDelegate`：macOS 27 起 push / pop 开始时在两页下面各插一块 `GlassEffectReplicaView`、转场完成即卸载，26 保留 `windowBackgroundColor`）、`Sidebar/SidebarNavigationController.swift`（只负责把它设为 delegate）、`Base/TabViewController.swift` 与 `Base/ViewControllers.swift`（页面在 macOS 26+ 保持透明，不再常驻任何背景）；`GlassEffectReplicaView` 本体在 UIFoundation 的 `AppleInternal` trait 下，提案 `draft-glass-effect-replica-view`
**所属分支：** `next`
**Severity：** Minor —— 功能正确，但侧栏每次 push / pop 时整块背景会闪一下颜色，用户描述为「突兀」
**触发场景：** 用户反馈 —— macOS 15 时两页各套一个 `NSVisualEffectView` 完全看不出来；26 起 split view 给 sidebar 塞了 `NSGlassEffectView`，`NSVisualEffectView` 显得格格不入；27 玻璃样式又改，之前转场用的 `windowBackgroundColor` 变成明显的一块深色

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 侧栏 push / pop 期间两页要涂一个不透明背景（否则两张列表互相透出），而这个背景和停下来时的侧栏颜色总差 1 ～ 9 个色阶，转场时整块侧栏闪一下 |
| **影响范围** | 只影响侧栏导航转场的观感。列表、选中、导航逻辑不受影响 |
| **根因** | macOS 26 起 `_NSSplitViewItemViewWrapper` 给 sidebar item 套的是 `NSGlassEffectView`（私有 `_variant` 17），颜色由窗口服务器按窗口背后的内容加一层桌面取色（`CAChameleonLayer`，opacity 0.1，`colorBlendMode`）实时合成，随窗口位置和激活状态漂移：实测同一台机器上出现过 rgb(40, 40, 43) / rgb(40, 40, 42) / rgb(39, 39, 41)。任何常量颜色都注定差一点；任何 `NSVisualEffectView` material 嵌在玻璃里会叠加合成，落在目标两侧；连同配置的第二块玻璃也会去采样外层玻璃的输出、再叠一次桌面取色，差 +1/+1/+2 |
| **Status** | **Fixed** —— 转场期间在两页下面临时插一块 `GlassEffectReplicaView`：拷贝外层玻璃配置，把自己的 `CABackdropLayer` 塞进外层玻璃的 backdrop group，同组只采样一次，实测激活 / 非激活 / 移动 / 缩放四种状态下逐像素一致且不透明；转场完成即卸载，页面静止时保持透明、直接坐在系统玻璃上 |

---

## 根因

### 侧栏底下到底是什么

AppKit 27.0（2775.10.103.1）反编译：`-[_NSSplitViewItemViewWrapper wrapView]` 在
`-[NSSplitViewItem _wantsGlass]`（`_hasSolariumAppearance && (isSidebar || isInspector)`）为真时建一个
`NSGlassEffectView`：`cornerRadius = 0`、`effectIsInteractive = NO`、`_adaptiveAppearance = 1`、
`_variant = [self _glassVariant]`（sidebar 17、inspector 18），我们的 view controller 全部放进它的 `contentView`。

lldb 读活的 layer 树：玻璃由一个 SwiftUI hosting view（`NSGlassEffectView.RootView`）渲染，而且它在
content holder **上面**；内容之所以可见，是因为 RootView 里有个 `CAPortalLayer` 把 content holder
（`hidesSourceLayer = 1`）重画进玻璃管线。玻璃本身 = `CABackdropLayer`（filter `glassBackground`，
`windowServerAware`，SwiftUI 自动起的 `groupName` 如 `SwiftUI:461.00.0`）+ `CAChameleonLayer`
桌面取色 + SDF 形状层 + 一层带 `vibrantColorMatrix` 的白色填充。桌面取色就是颜色漂移的来源。

### 为什么每个候选都差一点

上半区是原生侧栏、下半区是塞进页面里的探针，无损截图逐像素读：

| 候选 | 原生 | 探针 |
|---|---|---|
| `windowBackgroundColor`（27 之前的做法） | 40, 40, 43 | 30, 30, 30 |
| `underPageBackgroundColor`（常量里最近的） | 40, 40, 43 | 40, 40, 40 |
| `NSVisualEffectView` `.titlebar` / `.menu` / `.popover` / `.sidebar` | 40, 40, 42 | 45, 45, 47 |
| `NSVisualEffectView` `.headerView` / `.sheet` / `.windowBackground` / `.contentBackground` | 40, 40, 42 | 36, 36, 38 |
| 嵌套一块同配置的 `NSGlassEffectView`（variant 17） | 40, 40, 43 | 41, 41, 45 |
| 同上，再把它的 `CABackdropLayer.groupName` 改成外层的 | 40, 40, 42 | **40, 40, 42** |

最后一行就是修法。Core Animation 对同一个 backdrop group 只采样一次背景，组里每一层对同一份输入跑
同一套 filter，所以两块玻璃输出相同；在它下面垫一块纯红 view 完全被盖住（隐藏玻璃后读到
rgb(255, 2, 0)），说明它是不透明的。之后窗口失焦（40, 40, 42 / 40, 40, 42）、移到别处（39, 39, 41 /
39, 39, 41）、缩放窗口、缩放探针本身，两区始终一致，SwiftUI 也没有把 groupName 改回去。

### 第一版落地后又踩到的两条

- **分组名不是设一次就完。** 接进 app 后实测：窗口变 key 时 SwiftUI 把它自己生成的名字写回同一个
  `CABackdropLayer`（sidebar 复刻玻璃 485→773、inspector 505→631，系统那两层不动），复刻玻璃立刻退回
  +2。修法在 UIFoundation：把那个 layer 的类换成 `GroupPinnedBackdropLayer`（`object_setClass`，
  KVO 的同一招），之后所有 `groupName` 写入都被钉住的名字顶掉；另外监听窗口 key 通知兜底。
- **背景要挂在被 push 的那一层，不是列表 VC。** 第一版把两个列表 VC 改成 `BaseEffectViewController`，
  但被导航栈推来推去的页面是 `SidebarRootTabViewController` / `SidebarRuntimeObjectTabViewController`
  （`TabViewController`，拥有 segmented control 和 tab view，整页 967 pt），列表 VC 只是它 tab view 里
  877 pt 高的孩子；顶部安全区加 segmented control 那条 90 pt 的带没人盖。逐帧录像里那条带在 push 期间
  从 39 掉到 28 再花 8 帧爬回来（AppKitPlus 默认动画器的投影和 dimming 透过两页透明的部分露出来），
  而复刻玻璃盖住的区域全程稳在 39。当时改成 `TabViewController.contentView` 在 macOS 26+ 用复刻玻璃
  （它 26 之前本来就是 `NSVisualEffectView`），两个列表 VC 恢复 `BaseViewController`。最终改为转场时插入之后，
  插入点直接就是被推的那一层的 `view`，这条自然成立，`TabViewController` 也不再常驻背景。
- **页面回到窗口后 SwiftUI 会重建 layer 树。** pop 回来的页面，其复刻玻璃的 `CABackdropLayer` 是一个
  新实例、带新名字（实测 465），而 `viewDidMoveToWindow` 那一刻找到的还是旧的、已钉住的那个，
  于是重试提前结束、新 layer 从未被钉住，页面停在 +2。修法：定时器窗口内每一拍都重新钉当前 layer，
  不因第一次找到就停。

### 落地后第四条：第一次 push 整页发白，根因在 AppKitPlus

复刻玻璃全部到位后，每个窗口的**第一次** push 里被推走的根页整页变浅（60 fps 录像里 216 → 203，
黑色 dimming 在上面慢慢压下来；第二次 push 与 pop 都正常）。逐项排除了动画器的遮罩、新页阴影、
输入拦截视图、工具栏返回项、首响应者、`styleMask` / `titlebarSeparatorStyle` 切换、layout 重钉和
`CATransaction activate`，最后是把转场拉长到 8 秒、在中途用 lldb 对比两块玻璃的滤镜参数才抓到：
被推走那页的内层 `NSGlassEffectView.tintColor` 变成了 `System controlTextColor`，SwiftUI 层树多出一层
染色用的 `CASDFLayer`；系统玻璃和新推入的页都还是 nil。

来源是 AppKitPlus 给 `NSView` 加的分类属性 `tintColor`（UIKit 语义的树状 tint）：getter 第一次没值时
`self.tintColor = controlTextColor` 并递归写给整棵子树，递归到 macOS 26 自带公开 `tintColor`
（玻璃染色）的 `NSGlassEffectView` 时命中的是它自己的 setter。触发点是 `NSNavigationController` 造第一个
返回项时读了一次 `self.view.tintColor`——所以只有第一次；pop 回来时复刻玻璃重新拷贝系统玻璃的
nil tint，顺手把污染清掉，所以第二次干净。静态复现：新窗口不 push，只读一次那个 getter，根页就从 40
变 62；把内层玻璃 tint 置回 nil 再做第一次 push，不闪。

修在 AppKitPlus（Evolution 0039，main `375741a`，随 AppKitPlus-Release 0.4.3 发布）：整个成员删掉，
bar 按钮改为自持 tint，`NSBarButtonItem.tintColor` 只写它生成的按钮。回归测试 `NSViewHasNoTintColorTests`。

### 已排除的路线

- `NSGlassEffectView` 的私有 `_backdropGroupName` / `_groupIdentifier`：只存 ivar，触发一次 SwiftUI
  更新（缩放）后 `CABackdropLayer.groupName` 仍是 SwiftUI 自己的名字。
- ~~转场开始时现装玻璃~~：`NSGlassEffectView` 的 layer 树要等 run loop 转一圈才建出来，
  `layoutSubtreeIfNeeded` / `displayIfNeeded` / `CATransaction.flush` 在进程停住时都催不出来，
  首帧一定拿不到分组后的玻璃——当时因此改为常驻。**最终版本又回到了这条**（见「修复」）：首帧的空档落在
  两页都还没动的第 0 帧，透明的被推走页露出的正是它本来坐着的系统玻璃；按 `GlassEffectReplicaView` 的约定，
  之后复刻玻璃先以未入组的形态出现（差 +2）、再入组。用户实机测试认为可接受，换来的是页面静止时不再常驻
  一块私有 API 玻璃，pop 回来后重钉 group 名、SwiftUI 重建 layer 树那两条也不用再在页面层面处理。
- `CAPortalLayer` 复制外层 RootView：RootView 的渲染里已经包含内容的 portal 副本，会把被盖住那一页
  的内容一起带进来。
- 让两页保持透明、用 mask 裁掉被盖住的那页（不依赖私有 API）：像素上等价，但 AppKitPlus 默认的
  `NSParallaxTransitionController` 给上面那页整层加投影、下面盖一层 dimming，两页透明时投影和 dimming
  会从上面那页透出来，得换 UIKit 风格的 `NSNavigationParallaxTransitionController` 并放弃手势返回。
  留作私有 API 失效时的退路。

## 修复

- UIFoundation（`AppleInternal` trait）新增 `GlassEffectReplicaView` 与 `NSGlassEffectView` 的
  `glassBackdropLayer` / `glassBackdropGroupName` / `matchGlassConfiguration(of:)` /
  `enclosingGlassEffectView(of:)`，私有头 `NSGlassEffectView_Private.h`。variant 从活的外层玻璃拷贝，
  不写死 17。分组挂在 `CATransaction` 完成回调上重试，并在每次 `layout()` 复核。
- 本仓库：页面在 macOS 26+ 一律透明——`TabViewController.contentView` 是 `NSLayerBackedView`、
  `BaseEffectViewController.contentView` 是普通 `NSView`（26 之前两处都是 `NSVisualEffectView`，即 macOS 15
  时代「给两个 vc 套上背景」的形状），静止时直接坐在 split view item 的系统玻璃上；
  转场背景由 `NavigationTransitionBackdropController` 负责——它就是 `SidebarNavigationController` 的
  `NSNavigationControllerDelegate`：macOS 27+ 在 `willShow` 里给 from / to 两页的 `view` 最底下各插一块
  `GlassEffectReplicaView`（`frame = bounds`，autoresizing），在 transition coordinator 的 completion 里卸载；
  26 上仍按老办法在动画期间给两页涂 `windowBackgroundColor`（那一代的玻璃和它足够接近）。调查期间挂在
  Debug 菜单下、用来在运行时切换颜色 / 材质候选的 `NSPanel` 在上表定型后已删除，候选数据以上表为准。
- Inspector 那四个 `BaseEffectViewController` 子类不参与导航转场，保持透明即可，不需要复刻玻璃。

## 验证

- 上表全部数据来自我自己起的 Debug-arm64e 实例（lldb 注入探针 + `screencapture -o -x -l` 无损截图 +
  区域采样），不是推断。
- 首帧「未分组」的容忍：push 进来的页在屏幕外，pop 回来的页被上面那页盖着，启动时 layer 还没建
  等于透明，三种首帧都看不见。
- UIFoundation 全 trait `swift build` 通过；`GlassEffectReplicaViewTests` 六条全过（含"钉住的名字
  顶掉后续写入"和"渲染后分组"两条，后者在本机测试进程里 150 ms 内成功）。
- 常驻版本（改为转场时插入之前）在我自己的实例上逐帧录了 push、pop、再 push 三次转场（ScreenCaptureKit 60 fps，采样点：
  顶部间隙、右侧空白列三处、左边缘、内容区）：复刻玻璃盖住的区域全程稳在 39,39,42，转场里唯一的
  背景变化是动画器给下面那页的 8% dimming（两三帧、最多差 3 个色阶），其余变化全是列表文字经过采样点。
  push / pop 之后新建或重建的 backdrop layer 都重新钉到了系统的 group 名（`SwiftUI:483.00.0`），
  失焦 / 激活一轮后名字不变。
- 改为转场时插入的最终版本没有再逐帧录，由用户实机测试 push / pop 确认可接受（2026-09-19）。

## 未做的事

- 26.x 上的 variant 值没有重新读过（头文件里同样有 `_variant` / `_glassVariant`）；拷贝活值的设计
  让这一点不影响正确性，但没有在 26 上实机验证。
- 转场时插入的最终版本没有逐帧数据，只有目测；首帧空档和入组前的 +2 到底可不可见，如需核对可用
  `/tmp/claude/LiveProbe/flowrecorder` 那套工具（采样点：顶部间隙、右侧空白列三处、左边缘、内容区）。
- UIFoundation 已发 0.34.0，pin 已抬到 `from: "0.34.0"`。第一次 push 发白的修复已随 AppKitPlus-Release
  0.4.3 发布（2026-09-19），两个 workspace 的 `Package.resolved` 已抬到 0.4.3；RuntimeViewer 和 UIFoundation
  对它的 pin（`from: "0.4.2"` / `from: "0.3.1"`）都不用改，resolve 时统一落到 0.4.3。
- 可选加固没做：让 `GlassEffectReplicaView` 像钉 group 名一样钉住内层玻璃的 `tintColor`，防其它
  UIKit 移植库再往里写。
