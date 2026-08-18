# 0013 - 用 AppKitPlus 取代 UXKit

- **状态**: In Progress
- **作者**: JH
- **日期**: 2026-08-18
- **最后更新**: 2026-08-18
- **取代**: [0012](0012-replace-uxkit-navigation-with-uifoundation.md)（在 `feature/uifoundation-navigation` 分支上，状态 In Progress）

## 摘要

把导航容器从 Apple 私有的 `UXKit.framework` 换成 [AppKitPlus](https://github.com/AppKitSupportProgram/AppKitPlus-Release)
的 `NSNavigationController`，`Base/ViewControllers.swift` 里三个以 `UX` 开头的基类改名并
直接继承 `NSViewController` / `NSNavigationController`。随后从
`RuntimeViewerPackages/Package.swift` 删掉 `OpenUXKit` 与 `UXKitCoordinator` 两个依赖，
以及 `USING_SYSTEM_UXKIT` 这个编译开关。

## 动机

动机与 0012 完全相同，不重复论证，只记录三条结论与本提案的差异：

1. **隐藏的导航栏每次 push 仍被重新布局。** 0012 的冷启动 `sample` 显示，`.push` 分支
   主线程 100 个样本里约 50 个落在两次 push 的转场机制上，导航栏那一段每次约 10 个，
   而本项目从来不显示导航栏。**本提案不保证解决这一条**——见「与 0012 的取舍差异」。
2. **依赖 Apple 私有框架。** `isNavigationBarHidden`、`interactivePopGestureRecognizer`、
   `transitionCoordinator` 全是 `/System/Library/PrivateFrameworks/UXKit.framework`
   的私有 API，没有兼容性承诺。**本提案解决这一条**，这也是它的主要收益。
3. **`USING_SYSTEM_UXKIT` 的第二条路（OpenUXKit）从未被验证。** 保留一个从不走的编译分支
   等于保留一份不会被发现的坏代码。**本提案解决这一条**，开关随依赖一起删掉。

## 提议方案

### 换成什么

AppKitPlus 是把 UIKit 的现代 API 移植到 AppKit 的 Objective-C 框架，以预编译
`AppKitPlus.xcframework` 分发（`macos-arm64_arm64e_x86_64`，macOS 12+，
library evolution 已开启）。本提案只用到其中的导航栈部分：

| 头文件 | 用途 |
|---|---|
| `NSNavigationController.h` | 栈容器与 `NSNavigationControllerDelegate` |
| `NSViewController+NavigationController.h` | `navigationItem` / `toolbarItems` / `transitionCoordinator` 等，以 category 挂在 stock `NSViewController` 上 |
| `NSView+NavigationSupport.h` | `backgroundColor` / `userInteractionEnabled` / `tintColor`，以 category 挂在 stock `NSView` 上 |
| `NSViewControllerTransitionCoordinator.h` | `animate(alongsideTransition:completion:)`、`viewController(forKey:)` |

其头文件注明**逐文件 port 自 OpenUXKit @ 6d11772**，接口与 UXKit 同名同义。这决定了本次
迁移的性质：**它是一次改名，不是一次重写。**

已用 `swiftc -typecheck` 对着 xcframework 验证过下列 API 在 Swift 侧的拼写与 UXKit 版**逐字相同**：

```swift
final class Probe: NSNavigationController, NSNavigationControllerDelegate {
    func navigationController(_ navigationController: NSNavigationController, willShow viewController: NSViewController) {
        guard let coordinator = navigationController.transitionCoordinator,
              let fromViewController = coordinator.viewController(forKey: .from),
              let toViewController = coordinator.viewController(forKey: .to) else { return }
        coordinator.animate(alongsideTransition: { _ in
            fromViewController.view.backgroundColor = .windowBackgroundColor
        }, completion: { _ in })
    }
}
```

零错误零警告。`isToolbarHidden` / `isNavigationBarHidden` / `interactivePopGestureRecognizer`
以及 `NSView.userInteractionEnabled` 同样通过。

### 与 0012 的取舍差异

0012 选的是 UIFoundation 的 `NavigationController`。两条路线的目标一致，代价不同：

| | UXKit（现状） | UIFoundation（0012） | AppKitPlus（本提案） |
|---|---|---|---|
| 来源 | Apple 私有框架 | 自有开源包，源码分发 | 自有包，**二进制分发** |
| 栈元素类型 | `UXViewController` | `NSViewController` | `NSViewController` |
| 导航栏 / 工具栏 | 有（本项目全部隐藏） | **没有** | 有（可隐藏），API 同名 |
| `transitionCoordinator` | 有 | **没有对应物** | 有，签名相同 |
| 子视图定位 | 内部机制 | **按 frame，禁止外部约束** | 与 UXKit 同（port） |
| 迁移动作 | — | 换容器 + 删背景色补丁 + 逐面板验证约束 | 逐符号改名 |
| 动机一（隐藏导航栏的布局开销） | 问题所在 | **消除**（不存在导航栏） | **未知，需实测** |

两条路线的核心分歧只有一条：**0012 用「没有导航栏」直接消灭了动机一的开销，代价是
`transitionCoordinator` 没有对应物、子视图定位规则改变，需要逐面板实测；本提案保留了
与 UXKit 同构的接口，迁移退化为机械改名，代价是动机一是否解决取决于 port 的实现细节。**

选择本提案的理由：

- 迁移风险与工作量都低一个量级。0012 的「未完成」里列了三项实机验证（转场观感、背景色伪影、
  面板错位），本提案只有一项（转场开销是否下降），且失败也不影响功能正确性。
- `SidebarNavigationController` 那个 macOS 26 背景色补丁**可以原样保留**，只改类型名。
  0012 把它删掉了，删得对不对要靠实机确认；本提案不需要做这个判断。
- 两条路线都摆脱了 Apple 私有框架，动机二与动机三的收益完全相同。

**动机一如果实测证明未被解决**，退路是在 AppKitPlus 上游给 `NSNavigationController` 加一条
「导航栏隐藏时跳过 item 转场」的短路——它是自有代码，改得动；UXKit 改不动，这正是动机二的价值。

### 改动清单

`next` 分支上 `UX` 前缀符号的全部出现（已逐个数过，不含 `.build/checkouts`）：

| 符号 | 处数 | 处理 |
|---|---|---|
| `UXKitViewController<VM>` | 26 | → `BaseViewController<VM>`，改继承 `NSViewController` |
| `UXEffectViewController<VM>` | 5 | → `BaseEffectViewController<VM>` |
| `UXKitNavigationController` | 4 | → `BaseNavigationController: NSNavigationController` |
| `UXNavigationController` / `UXNavigationControllerDelegate` | 4 | → `NSNavigationController` / `NSNavigationControllerDelegate` |
| `UXViewController` | 3 | → `NSViewController` |
| `UXView` / `uxView` | 8 | → `NSView` / `view`（`backgroundColor` 由 AppKitPlus 的 category 提供） |
| `.uxPopover` / `.closeUXPopover()` | 5 | → CocoaCoordinator 自带的 `.popover` / `.closePopover()` |
| `UXPopoverController` | 3 | **只在注释里**，早已迁走，顺手改文字 |
| `USING_SYSTEM_UXKIT` / `@_exported import UXKit` | 6 | 删除；AppKitPlus 改为按需 `import` |

外加：

- `RuntimeViewerPackages/Package.swift`：删除 `OpenUXKit`、`UXKitCoordinator` 两个
  `.package(...)` 与对应 `.product(...)`；删除 `usingSystemUXKit` 与 `USING_SYSTEM_UXKIT`
  define；新增 AppKitPlus 依赖，挂到 `RuntimeViewerUI` 与 `RuntimeViewerArchitectures`
  两个 target 上，`condition: .when(platforms: appkitPlatforms)`。
- `RuntimeViewerUI.swift`：删掉 `@_exported import UXKit`，**不**换成 `@_exported import AppKitPlus`
  （原因见「风险 1 的实际情况」），改由需要导航栈的少数文件显式 `import AppKitPlus`。
- `RuntimeViewerArchitectures.swift`：删掉 `@_exported import UXKitCoordinator`。
- `AGENTS.md`：「ViewController Base Class Selection」一节按新基类名重写。

### 版本 pin：用 `exact:` 而不是 `from:`

AppKitPlus 的 README 写明「**No API or ABI stability is promised.** Any release may remove
classes, change type layouts, or change protocol requirements, with no deprecation period.」
且二进制框架的 `.swiftinterface` 不保证被未来编译器读得懂（0.1.0 由 Xcode 26.6 构建）。

因此本提案用 `.package(url: "…/AppKitPlus-Release", exact: "0.1.0")`，升级是显式动作，
每次升级前读 release notes。这与项目里其他二进制/私有依赖的处理一致。

### 转场层要重写

现在 push/pop/set 靠 `UXKitCoordinator` 提供的
`extension Transition where ViewController: UXNavigationController`。换掉容器后这一层失效，
需要写等价的 `extension Transition where ViewController: NSNavigationController`，提供
`push` / `pop` / `pop(to:)` / `popToRoot` / `set` 五个操作。

**放在 `RuntimeViewerArchitectures/Transition+Navigation.swift`**，与 0012 的已定方向一致：
本仓库内解决，不等上游发版；稳定后再作为独立改动搬到 CocoaCoordinator 上游。

`NSNavigationController` 的栈 API 与 UIKit 一样不收 completion（`UXKitCoordinator` 那层也
只是调完就同步回调），所以新实现同样同步调 completion。completion 最终只到达
`Presentable.presented(from:)`，其默认实现为空，CocoaCoordinator 与本项目都没有覆写，
今天没人观察得到差别。这条前提写进文件注释。

### popover 直接用 CocoaCoordinator 自带的

`.uxPopover` 存在的唯一理由是 `UXViewController` 用私有 ivar 覆盖了 `preferredContentSize`
且不转发给 `NSViewController`，普通 `NSPopover` 读不到，只能靠 `UXPopoverController` 桥接。
迁移后所有内容控制器都是 stock `NSViewController`，`preferredContentSize` 走标准 KVO，
这个桥不再需要——**顺带消除了它 KVO 重发中间值导致的「popover 先塌成零高再长大」伪影**，
`SidebarRuntimeObjectScopeViewController` 的注释里记的正是这个问题。

`animates` 参数无需保留：调用点传的都是 `true`，而 `NSPopover.animates` 默认就是 `true`。

## 替代方案考量

- **保留 UXKit，只绕过导航栏开销**：`_pushNavigationItem` 由 `_beginTransitionWithContext`
  无条件调用，没有导出的开关，且不解决动机二、动机三。0012 已论证，结论不变。
- **UIFoundation 的 `NavigationController`（0012）**：见上表。它在动机一上更彻底，
  在迁移风险上更重。判断是先用低风险路线摆脱私有框架，动机一留作可独立处理的后续问题。
- **自己写一个导航容器**：AppKitPlus 已经是自有代码，再写一份没有增量收益。

## 影响

### 用户可见变化

- **转场动画预期不变**——AppKitPlus 的导航栈 port 自 OpenUXKit，与现在链接的 UXKit 同源。
  实机确认前不写「无变化」。
- **交互式返回**：两边都关着，无变化。
- **导航栏**：本来就隐藏，无变化。
- **Sidebar 的 macOS 26 转场底色补丁保留**，行为不变。
- **两处 popover 伪影预期消失**（scope 弹出框的展开塌缩、类型选择器）。
- 性能收益**待实测**，不作承诺。

### 可发现性

无新增 UI，无新增设置项。

### 数据与配置兼容

不涉及持久化数据。

### 平台与最低版本

不变（macOS 15+，AppKitPlus 要求 macOS 12+）。AppKitPlus 只在 `appkitPlatforms` 条件下引入，
iOS 变体（`RuntimeViewerUsingUIKit`）与 Catalyst helper 不受影响。

### 发布

- **新增一个二进制依赖**：`AppKitPlus.framework` 是 `mh_dylib`，SPM 会自动 Embed & Sign 进
  app target。需要确认公证与 `ArchiveScript.sh` 流程不受影响。
- **摆脱对 Apple 私有框架的链接**，对公证与未来 macOS 版本的稳健性是净收益。
- Debug 与 Distribution 两个 workspace 都要重新解析 `Package.resolved`。
- **Debug-arm64e 需单独验证**：xcframework 带 arm64e slice，但 `iOSPackagesShouldBuildARM64e=true`
  下二进制 target 的行为要实测。

## 风险与待验证

| # | 风险 | 处理 |
|---|---|---|
| 1 | **已兑现，见下。** `@_exported import AppKitPlus` 把 Carbon 的整个命名空间泄漏进每个 `import RuntimeViewerUI` 的文件 | 改为按需 `import AppKitPlus`，不做全局导出 |
| 2 | **已兑现，见下。** AppKitPlus 给 stock `NSView` 加 `backgroundColor`，项目里 `NSView` 子类自己声明的同名属性变成非法 override | 把项目侧的属性改名 |
| 3 | 框架头文件自己警告：进程内若有第二个给 `NSView` 加 `backgroundColor` 的 category，后加载者胜 | 项目内无第二份；记录在案 |
| 4 | 动机一（隐藏导航栏的布局开销）可能原样保留 | 落地后按 0012 同法 `sample` 复测；未解决则在 AppKitPlus 上游加短路 |
| 5 | 二进制依赖无 API/ABI 承诺 | `exact:` pin，升级前读 release notes |
| 6 | Debug-arm64e 构建 | 已验证通过，xcframework 的 arm64e slice 正常参与构建与签名 |

### 风险 1 的实际情况：AppKitPlus 会把 Carbon 一起带进来

`RuntimeViewerUI.swift` 里把原来的 `@_exported import UXKit` 直接换成
`@_exported import AppKitPlus`，编译立刻报：

```
RuntimeViewerUI/AppKit/AreaSegmentedControl.swift:7:34:
  error: 'Control' is ambiguous for type lookup in this context
UIFoundation/Sources/UIFoundationAppKit/Base/Control.swift:5:12: note: found this candidate
Carbon.Control:1:14: note: found this candidate
```

成因是两层叠加：`NSKeyConstants.h`（虚拟键码常量，从 Carbon 的键码映射而来）里写着
`#import <Carbon/Carbon.h>`，而 AppKitPlus 的 module map 是 `export *`——于是
`import AppKitPlus` 传递导出 Carbon，`@_exported` 再把它送进每个 `import RuntimeViewerUI`
的文件。Carbon 里全是 `Control`、`Point`、`Style`、`Handle` 这种裸名，撞名是必然的。

**处理：`RuntimeViewerUI` 不再 `@_exported` AppKitPlus**，改为在真正需要导航栈的少数文件里
显式 `import AppKitPlus`（`Base/ViewControllers.swift`、`SidebarNavigationController.swift`、
`ContentTextViewController.swift`，以及 `RuntimeViewerArchitectures/Transition+Navigation.swift`）。
`RuntimeViewerUI.swift` 里留了注释说明为什么不能改回 `@_exported`。

**上游跟进项**：AppKitPlus 可以把 `#import <Carbon/Carbon.h>` 收进 `.m`，或改成
`#include <Carbon/HIToolbox/Events.h>` 并让它不参与 re-export，这样下游就不必为一个键码
常量头文件放弃 `@_exported`。

### 风险 2 的实际情况：`NSView.backgroundColor` 挡住了项目自己的同名属性

```
ContentLineNumberRulerView.swift:22:9:
  error: cannot override mutable property 'backgroundColor' of type 'NSColor?'
         with covariant type 'NSColor'
```

`ContentLineNumberRulerView: NSRulerView` 给自己加了一个 `var backgroundColor: NSColor`
（`NSRulerView` 本身没有这个属性）。AppKitPlus 把 `backgroundColor: NSColor?` 加在
**`NSView`** 上，于是这个新增属性变成了对祖先属性的 override，可选性还对不上。

**注意这一条不是 `import` 能隔离的**：Objective-C category 的成员只要模块被加载就参与类型查找，
与哪个文件写了 `import AppKitPlus` 无关（`ContentLineNumberRulerView.swift` 并没有 import 它）。
UXKit 时代不会撞，是因为 `backgroundColor` 挂在 `UXView` 这个子类上，够不到 `NSRulerView`。

**处理**：项目侧属性改名 `backgroundColor` → `gutterBackgroundColor`（调用点仅 1 处），
名字也更准确——它填的是 gutter 的底，不是视图的底。

横向排查过整个代码库里可能与 AppKitPlus 的三个 category（`NSView`、`NSViewController`、
`NSCell`）撞名的成员——`backgroundColor` / `tintColor` / `userInteractionEnabled` /
`snapshotView` / `navigationItem` / `toolbarItems` / `transitionCoordinator` /
`edgesForExtendedLayout` / `topLayoutGuide` / `bottomLayoutGuide` /
`hidesBottomBarWhenPushed`——只有这一处需要改。`SidebarRootTableRowView.backgroundColor`
是对 `NSTableRowView` 公开属性的正常 override，更具体的类声明胜出，不受影响；
`HUDView.Configuration.tintColor` 与 `ThemeProfile.backgroundColor` 都不在 `NSView` 继承链上。

## 落地步骤

1. `Package.swift`：删 UXKit 侧依赖与开关，加 AppKitPlus（`exact: "0.1.0"`）。
2. 两个 umbrella 模块的 `@_exported import` 调整。
3. 新增 `RuntimeViewerArchitectures/Transition+Navigation.swift`（5 个 transition）。
4. `Base/ViewControllers.swift`：删除零调用点的 `AppKitViewController<VM>` 薄壳；
   `UXKitViewController` → `BaseViewController`（继承 `NSViewController`，**补 `loadView()`**——
   原先由 `UXViewController` 提供，`NSViewController` 默认会去找同名 nib，本项目不发 nib）；
   `UXEffectViewController` → `BaseEffectViewController`；
   `UXKitNavigationController` → `BaseNavigationController: NSNavigationController`。
5. `TabViewController`：`UXViewController` → `NSViewController`，同样补 `loadView()`。
6. 26 + 5 + 4 处调用点机械改名；`UXView()` → `NSView()`；`uxView` → `view`。
7. `SidebarNavigationController`：delegate 方法**实现保留**，仅改类型名与 `uxView` → `view`。
8. 5 处 popover transition 换成 `.popover` / `.closePopover()`。
9. `AGENTS.md` 基类一节重写；`SidebarRuntimeObjectScopeViewController` 等处的过期注释更新。
10. 两处命名冲突的修复（见「风险 1 / 风险 2 的实际情况」）。
11. 编译验证全部通过：`RuntimeViewerPackages`（`swift build`）、`RuntimeViewerCatalystHelper`、
    `RuntimeViewer macOS`（Debug）、以及 `RunScript.sh` 的 `Debug-arm64e`。
    产物侧确认：`AppKitPlus.framework` 已嵌入 `Contents/Frameworks/`，
    `lipo -info` 报 `x86_64 arm64 arm64e`（风险 6 排除），已用本项目 Team ID 重新签名；
    主二进制链接 `@rpath/AppKitPlus.framework`，**整个 app bundle 里再也搜不到 `UXKit` 字样**
    ——动机二（脱离 Apple 私有框架）已达成。
12. **待做**：实机走一遍三个面板的导航，确认转场观感与 macOS 26 底色补丁仍然成立。
13. **待做**：`sample` 复测动机一（按 0012 的方法：点一个 RuntimeObject，看
    `MainCoordinator.fanOut` 的 `.push` 分支样本数是否从 100 降下来）。

`Documentations/Evolutions/0002`、`0003` 与 `Plans/` 里出现的 `UXKitViewController` **不改**——
它们是当时的决策快照，按「提案落地后保持原貌」「旧文档原地不动」的约定保留。

## 决策日志

| 日期 | 事件 | 说明 |
|---|---|---|
| 2026-08-18 | Accepted → In Progress | 落地步骤 1–9 已完成，编译与实机验证进行中。 |
| 2026-08-18 | Created as Draft | 用户指定改用 AppKitPlus。同日确认 0012 转 `Superseded`，基类命名定为 `BaseViewController` / `BaseEffectViewController` / `BaseNavigationController`。 |
