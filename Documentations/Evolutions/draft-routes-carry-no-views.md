# Draft - Route 不携带视图

- **状态**: In Progress
- **创建日期**: 2026-10-12
- **最后更新**: 2026-10-12

## 摘要

三个 Route case 把 popover 的锚点视图当关联值带着走：`MainRoute.generationOptions(sender: NSView)`、
`MainRoute.mcpStatus(sender: NSView)`、`SidebarRuntimeObjectRoute.scope(sender: NSView, …)`。前两个的视图来自
`MainViewModel.Input` 里的 `Signal<NSView>`，也就是视图先穿过 ViewModel 再进 Route；第三个干脆由 ViewController
自己调 `viewModel.router.trigger(...)`，绕开了 ViewModel。Route 与 ViewModel 的 `Input` 是导航层的词汇，不该认识
AppKit。改为 Route 不带任何 AppKit / UIKit 类型，锚点由 coordinator 在 `prepareTransition` 里向视图层要——与
`SidebarRuntimeObjectRoute.privateDeclaration` 已经采用的做法一致。

## 方案

- **工具栏的两个 popover**：两个 case 去掉参数；`MainViewModel.Input.generationOptionsClick` /
  `mcpStatusClick` 改成 `Signal<Void>`，`MainWindowController` 从 `rx.clickWithSelf` 改绑 `rx.click`。
  `MainCoordinator.popoverAnchorView(of:)` 直接取 `toolbarController` 里对应 item 的 `button`。
- **侧栏范围 popover**：case 改成 `.scope(relay:availableKinds:availableProperties:)`。触发挪进
  `SidebarRuntimeObjectViewModel`：`Input` 新增 `filterScopeClicked: Signal<Void>`（默认 `.empty()`，iOS 端不用改），
  ViewModel 拿自己的 `$scope` 与可用种类、属性去触发。ViewController 只转发点击。
  AppKitPlus 的 `NSFilterControlBarItem` 不公开它在栏上的按钮，只在 action 里把它作为 sender 给出，所以
  ViewController 在点击时用弱引用记下这个按钮，对外暴露 `filterScopeAnchorView`（不在窗口里时为 `nil`）；
  coordinator 依次问对象列表与书签列表，两者是同一个 tab view 的两页，同一时刻只有一个在屏幕上。
- **锚点不在屏幕上时返回 `.none()`**。工具栏 item 被挤进溢出菜单时按钮不在任何窗口里，原先会拿它去弹 popover。
- **约定写进 `AGENTS.md`** 的 Coordinator Conventions（*Routes carry no views*），列出三种取锚点的形态。
- **测试**：`SidebarRuntimeObjectViewModelTests` 新增一例，钉住按下范围按钮会触发且只触发一个 `.scope`，带的是
  ViewModel 自己的 relay 与可用种类、属性。`MainViewModel` 在 App target 里，没有测试 target 覆盖。
- **已验证**（2026-10-12，Xcode 27.0）：`RuntimeViewer-Debug.xcworkspace` 以 Debug-arm64e 编过整个 App，
  改动的文件没有新警告；`RuntimeViewerApplicationTests` 全过（466 个测试）。
- **未做**：界面上的手工验证——三个 popover 是否仍从各自按钮弹出。

未经询问采用的假设：`.scope` 里的 `BehaviorRelay` 和 `.privateDeclaration` 里的 cell ViewModel 都不是 AppKit
类型，不在本次范围内，保持不动。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-12 | Created as Draft：「Route 里面所有带有 NSView 等 UI 控件的全部换掉，不允许携带 AppKit 的相关类型」 | 用户要求 |
| 2026-10-12 | 锚点由 coordinator 向视图层要，不另造锚点标识 | 与 `privateDeclaration` 的 `anchorView(forTag:of:)` 同一套做法，Route 与 ViewModel 都不必知道锚点 |
| 2026-10-12 | 范围按钮的按钮由 ViewController 在点击时记下，不改 AppKitPlus | `NSFilterControlBarItem` 没有公开按钮；为此给 AppKitPlus 加公开 API 要发版抬 pin，换来的只是少存一个弱引用 |
| 2026-10-12 | `.scope` 的触发从 ViewController 挪进 ViewModel | Route 签名本来就要改；ViewController 直接调 router 违反 MVVM-C 的分工 |
