# 2026-08-05 切换 RuntimeObject 时 Inspector 闪烁

**调查日期：** 2026-08-05
**修复落地：** 本日，见 `InspectorRuntimeObjectCoordinator.swift` / `InspectorClassViewModel.swift` / `InspectorRelationshipsViewModel.swift` / `TabViewController.swift` / `SkeletonPlaceholderView.swift`
**Severity：** Minor —— 纯视觉问题，数据始终正确，但每次点选都发生一次，属于高频噪声
**触发场景：** 用户反馈 —— "Content 模块不闪了，但 Inspector 切换 RuntimeObject 还是会闪"

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 在 sidebar 里点选另一个 RuntimeObject，Inspector 面板内容先清空再填回；切换对象类型时整块面板再多闪一次 |
| **影响范围** | Inspector 的 Hierarchy 与 Relationships 两个 tab（Specialization tab 数据同步产出，不受影响） |
| **根因** | 每次切换都新建 ViewModel 并重新 `setupBindings`，导致 Rx 表格适配器被拆掉重建、从空列表起步；叠加 `NSTabView` 的全量重建 |
| **Status** | **Fixed** —— tab ViewModel 常驻 + 显式 loading 状态 + 骨架屏占位 + tab items 增量协调 |

---

## 现象

在 sidebar 里连续点选同类型的对象（例如一个 ObjC class 换成另一个 ObjC class）：

- Relationships tab：列表立刻空掉，几十到几百毫秒后新行才出现。
- Hierarchy tab：旧对象的继承链一直留在屏幕上，直到新的算完才替换。

再切到不同类型的对象（例如 class 换成 protocol，Hierarchy 这一栏本身要消失）时，整个 tab 区域会额外闪一下。

对照组是 Content 模块：它同样在每次切换时新建 `ContentTextViewModel` 并重新绑定，却不闪。

---

## 根因

### 一、重新绑定会把表格清空

`InspectorRuntimeObjectCoordinator` 早已按"复用 ViewController"的思路做过一轮优化：同一个 `TabConfiguration` 下不动 `NSTabView`，只对现有的三个 ViewController 调用 `setupBindings(for:)`，喂一个新建的 ViewModel。

问题出在 `setupBindings(for:)` 的第一件事：

```swift
rx.disposeBag = DisposeBag()
```

这会拆掉 `tableView.rx.items` 的整条绑定。RxAppKit 的 `items(adapter:)` 每次订阅都会新建一个 `RxNSTableViewAdapter`，其内部 `items` 从空数组起步。而新建的 `InspectorRelationshipsViewModel` 里 `rows` 初值也是 `[]`，`$rows.asDriver()` 一订阅就同步吐出这个空数组：

```swift
dataSource.items = newItems   // []
tableView.reloadData()        // 表格当场清空
```

真数据要等 `relationships(for:)` 回来。那个查询会遍历**所有已索引的 image** 求并集（`RuntimeRelationshipsResolver.relationships(for:)`），耗时可观。中间这段空白就是闪烁。

Content 不闪的原因也随之清楚：`NSTextView` 的 `textStorage` 不会因为重新绑定而清空，旧文本会一直留到新文本算好。表格没有这个待遇。

### 二、同时暴露的时序缺陷

旧的 `InspectorRelationshipsViewModel.load()` 用裸 `Task {}`，没有取消也没有代次校验：

```swift
Task { [weak self] in
    let result = try await documentState.runtimeEngine.relationships(for: target)
    await MainActor.run { self.rows = ... }
}
```

在旧模型下这不可见（ViewModel 用完即弃，旧实例的结果到不了视图）。但一旦改成 ViewModel 常驻，快速连点就会让先发出的旧查询后返回、覆盖掉新对象的结果。因此常驻化必须同步换成 `flatMapLatest`。

### 三、tab items 全量重建

`TabConfiguration` 变化时走 `Transition.set`，旧实现是：

```swift
viewController.removeAllTabViewItems()
viewController.setTabViewItems(tabViewItems)
viewController.selectedTabViewItemIndex = initialIndex
```

`NSTabView` 在选中项变化时会立刻装载对应的 view，所以这一串在同一个 runloop 内会换好几次 view。原代码注释里也承认了这一点："the short-lived flash remains for kind transitions only"。

---

## 修复

### 1. tab ViewModel 常驻，`setupBindings` 只跑一次

`InspectorRuntimeObjectCoordinator` 除了持有三个 ViewController，现在还持有三个 ViewModel。首次使用时创建并绑定，之后只调用 `update(for:)` 把新对象推进去。表格适配器全程不重建，视图能观察到的只有 ViewModel 主动发出的状态变化。

`update(for:)` 会对同一个对象短路返回，所以 `.back` 路由（关标签页、历史光标移动）不会触发重新查询，也就不会闪出占位。

### 2. loading 与内容合并为单一状态

两个异步 tab 各自定义状态枚举：

```swift
public enum HierarchyState { case loading, loaded(String) }
public enum RelationshipsState { case loading, loaded([InspectorRelationshipsCellViewModel]) }
```

刻意不拆成 `isLoading` + `content` 两条 driver ——那样视图就有可能同时观察到"没在加载"和"上一个对象的内容"，而这正是要消除的中间态。管线形如：

```swift
$runtimeObject
    .flatMapLatest { runtimeObject in
        Observable.async { ... }.startWith(.loading)
    }
```

`flatMapLatest` 顺带解决了上面第二条时序缺陷。Cell ViewModel 会构造 `NSImage` / `NSAttributedString`，所以后台只回传 `[RuntimeObject]`，等管线回到主调度器再映射成 cell ViewModel。

### 3. 骨架屏占位

新增 `RuntimeViewerUI` 组件 `SkeletonPlaceholderView`：按内容形状摆圆角灰条（Hierarchy 是阶梯缩进的层级条，Relationships 是"图标 + 名字条 + 镜像名条"），整块以 1.0 ↔ 0.5 的透明度缓慢脉动。

它是**替换式**占位，不是覆盖式效果：呈现期间调用方会把真实子视图隐藏掉，所以上一个对象的数据绝不会从底下透出来。这是它与既有 `NSView.showSkeleton(using:)` 的关键区别——后者是半透明扫光遮罩，底下的内容仍然可见，且 0.35 秒的淡入本身就像闪一下。既有那套没有被删除，只是 Inspector 不使用它。

Hierarchy tab 的占位条用绝对点宽而非百分比：承载它的 disclosure 区域宽度由内容撑开，没有可供取百分比的容器宽度。

### 3b. 骨架屏本身不能变成新的闪烁

第一版占位是随加载**立刻**出现的，结果换来一次回归反馈："以前那种闪烁没有了，但是会闪骨架屏"。原因很直接：`hierarchy(for:)` 命中已缓存的 section 时只要几毫秒，占位出现又立刻消失，等于把旧的闪烁换成了新的。

引入 `ObservableType.withLoadingPlaceholder(_:appearsAfter:staysAtLeast:)`（`RuntimeViewerArchitectures`），两个门槛缺一不可：

- **`appearsAfter`（150 ms）** —— 在此之前完成的加载完全不发占位，内容直接换掉。少了这一条，每次命中缓存都闪一下。
- **`staysAtLeast`（300 ms，从占位出现的时刻算起）** —— 占位一旦露面就必须待够。少了这一条，恰好卡在阈值附近返回的查询会让占位只存在一帧。

时长从占位**实际出现的时刻**起算，而不是从结果返回时再加一段，所以真正慢的查询不会被额外拖延。两个数值集中在 `LoadingPlaceholderTiming`，Inspector 各 tab 共用，避免彼此节奏不一致。

代价是切换后的前 150 ms 内旧内容仍在屏幕上。这低于"看得出在给我看旧东西"的感知阈值，且这段时间内根本不会出现占位 —— 用户能观察到的只是内容瞬间换掉。

### 4. tab items 增量协调

`TabViewController.setTabViewItems(_:selectedIndex:)` 改为按 ViewController 身份对账：先切到目标 tab（避免移除选中项时 `NSTabView` 自行挑选邻居并装载一个马上要被替换的 view），再移除消失的、插入新增的、必要时才调整顺序。留下来的 tab 全程保持自己的 view。

---

## 影响面与注意事项

- **Specialization tab 不需要占位**：`$runtimeObject.map { $0.children.filter { ... } }` 是同步的，数据已在内存里，加占位反而会凭空多一帧空窗。
- **未被当前配置需要的 tab 不刷新**：它们在屏幕外，刷新只会浪费一次没人等的查询；下次被需要时 `update(for:)` 会补上。
- **骨架屏的高度约束是软的**：行间距与末行底部锚点均为 `.priority(.high)`，Inspector 面板被压得很矮时占位会自行收紧或溢出，而不是报必需约束冲突。
- **Content 模块未改动**：它靠"旧文本留到新文本算好"避开了这个问题。若日后也要求切换时不显示旧数据，可以套用同一套状态枚举 + 骨架屏。
