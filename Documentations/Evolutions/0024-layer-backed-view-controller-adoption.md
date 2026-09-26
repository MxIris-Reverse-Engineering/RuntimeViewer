# 0024 - `BaseViewController` 改接 UIFoundation 的 `LayerBackedViewController`

- **状态**: Implemented
- **创建日期**: 2026-09-26
- **最后更新**: 2026-09-26
- **配套文档**: 无独立指南——契约写在 `AGENTS.md` 的「ViewController Base Class Selection」一节

## 摘要

`BaseViewController` 直接继承 AppKitPlus 的 `NSLayerBackedViewController`。UIFoundation 从 0.31.0 起提供它的对位类
`LayerBackedViewController<View: LayerBackedView>`：父类随 `AppKitPlus` trait 解析（本项目开着这个 trait，所以仍是
`NSLayerBackedViewController`），根视图是 UIFoundation 的 `LayerBackedView`，以 `public` 的 `contentView` 暴露。
改接它，让页面控制器和视图一样统一走 UIFoundation 的基类。

障碍是重名：`BaseViewController.contentView` 是根视图里的一个内层容器——负责 `contentInsets` 与安全区约束、压在加载遮罩
`commonLoadingView` 下面、在 `BaseEffectViewController` 里于 macOS 26 以前换成 `NSVisualEffectView`——而 UIFoundation 的
`contentView` 就是根视图本身，子类既不能重声明也不能覆写它。所以分两步：先把内层容器改名为 `containerView`，再换父类，
`contentView` 让给父类。

## 方案

**第一步：纯改名，行为不变。**

- `contentView` → `containerView`，`contentViewUsingSafeArea` → `containerViewUsingSafeArea`。`contentInsets` 说的是内边距，
  不指代某个视图，保留原名。
- 改名时父类还是 `NSLayerBackedViewController`。AppKitPlus 0.4.4 的头文件与 UIFoundation 的源码都没有给
  `NSViewController` / `NSResponder` 加名为 `contentView` 的成员，代码里也没有字符串或 key path 形式的引用，所以漏改的
  引用必然编译失败——编译通过即改全。为了证明这一点，第一次构建故意留下一处旧引用，确认编译器只在那一行报错，再改掉它。
  编译通过后再 grep 一遍，剩下的 `contentView` 都与此无关（`NSScrollView.contentView`、`ImageLoadableView` 自己的属性等）。
- 内容区两处 `_backgroundColor` 设在容器上，容器仍是普通 `NSView`，照旧可用。

**第二步：换父类。**

- `BaseViewController<ViewModel>: LayerBackedViewController<LayerBackedView>`。内层容器、加载遮罩的层级、内边距与安全区、
  `BaseEffectViewController` 在 macOS 26 以前的 `NSVisualEffectView` 容器全部保持原样。
- 唯一的实际变化是根视图的类：`NSLayerBackedView` → UIFoundation 的 `LayerBackedView`。后者每次 `updateLayer` 都会把根 layer
  的背景色、阴影、圆角写回自己的配置（默认为空）。已核对没有代码往 `BaseViewController` 页面的根 layer 上写这些：
  `NavigationTransitionBackdropController` 的 `_backgroundColor` 和 AppKitPlus 视差 push 加的阴影只落在侧栏的
  `TabViewController` 页面上，内容区与 Inspector 的切换都是 `animated: false`。
- 引用一次 `layerBackedView`（只有 `NSLayerBackedViewController` 有这个成员）：`AppKitPlus` trait 若在某次构建里丢失，
  父类会静默退回 `NSViewController`，有这一行就会直接编译失败。

**不做的事**

- `TabViewController` 不迁。它的 `contentView` 是 private 的，不存在子类改写的问题；而侧栏转场会往它的根 layer 上写阴影与
  背景，与 `LayerBackedView` 的逐次改写冲突，要单独验证。
- `BaseEffectViewController` 靠覆写 `containerView` 把容器换成毛玻璃的写法暂不改。
- 不加「根视图里只能有 `containerView` 与加载遮罩」的 DEBUG 断言，理由见决策日志。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-26 | Created as Draft | 用户要求把 ViewController 基类换成 UIFoundation 的 `LayerBackedViewController` |
| 2026-09-26 | 不采用「删掉内层容器、内容直接装进根视图」 | 那样加载遮罩要改到首次出现时再安装才能保持在最上层；macOS 26 以前 Inspector 占位页的内容会移出毛玻璃、失去 vibrancy；内容区两处 `_backgroundColor` 会被 `LayerBackedView` 的 `updateLayer` 覆盖。保留容器则这些都不变 |
| 2026-09-26 | 内层容器改名 `containerView`，`contentView` 让给父类；先改名、再换父类 | 用户决定。先改名时 `contentView` 在页面里不复存在，编译器能证明改全；换父类后它才以根视图的身份重新出现 |
| 2026-09-26 | `contentInsets` 保留原名 | 描述的是内边距，不指代某个视图，不会与根视图 `contentView` 混淆 |
| 2026-09-26 | 子类可覆写 `containerView` 的问题暂不处理 | 用户决定，先把接入做完 |
| 2026-09-26 | 不加「根视图里只能有 `containerView` 与加载遮罩」的 DEBUG 断言 | 讨论时提过，用来防新页面把内容误装进根视图 `contentView`。但 `SpecializationViewController`、`SidebarRuntimeObjectScopeViewController`、`SidebarRootBookmarkViewController` 本来就直接往根视图里加视图，断言会立刻触发；改它们超出本次范围。另记一条现状：`SidebarRootBookmarkViewController` 的「No Bookmark」标签加在根视图上、位于加载遮罩之上 |
| 2026-09-26 | `TabViewController` 不在本次范围 | 见「不做的事」 |
| 2026-09-26 | 第一步完成，落地编号 0024 | 第一次构建故意留下 `ContentTextViewController.swift:116` 一处旧引用，编译器只在这一行报错：`has no dynamic member 'contentView' using key path from root type 'FrameworkToolbox<ContentTextViewController>'`。FrameworkToolbox 给类型提供了 `@dynamicMemberLookup`，是旧引用可能被悄悄绑走的另一条路，这次没有绑上。改掉这一处后构建通过；剩下的 `contentView` 都与此无关 |
| 2026-09-26 | 第二步完成，状态 In Progress → Implemented | 父类换成 `LayerBackedViewController<LayerBackedView>`，init 走 `init(viewGenerator:)`，Debug 构建通过、无新增警告。trait 检查写成 `viewDidLoad` 里的 `assert(layerBackedView === contentView)`：Release 下断言不求值但仍参与类型检查，所以两种配置都能拦住 trait 丢失；运行时这个等式由 UIFoundation 的 `LayerBackedViewControllerTests` 覆盖。没有单独让它变红——那要在关掉 trait 的情况下重建 UIFoundation；依据是 `NSViewController` 没有 `layerBackedView` 成员。只做了编译验证，没有启动 App，也没有做界面检查 |
| 2026-09-26 | 不写独立指南，不加术语表条目 | 基类的用法与两个视图的分工写进 `AGENTS.md` 的「ViewController Base Class Selection」，`_backgroundColor` 的适用范围写进同文件的 layer-backed 视图一节；`containerView` 是代码标识符，不是项目术语 |
