# 0018 - `@RxObserved` 宏：仿 `@Observable` 的内联可观察属性

- **状态**: Implemented
- **创建日期**: 2026-09-02
- **最后更新**: 2026-09-02
- **关联**: [0017](0017-observed-lazy-relay.md) 的下一步；代码改动在上游 [RxSwiftPlus](https://github.com/Mx-Iris/RxSwiftPlus)

## 摘要

0017 让 `@Observed` 只在首次访问 `$x` 时才建 relay，但 property wrapper 是个 struct、setter 是 `nonmutating`，状态只能装进一个堆上的盒子：每个属性仍要一个 `ObservedStorage` 对象加一把堆分配的 `os_unfair_lock`，两次 malloc，读写各过一次锁。本提案照 `@Observable` / `@ObservationTracked` 的做法把它换成宏：`@RxObserved var x: T` 展开成 `get` / `set` / `init` accessor，存储是内联在对象里的值类型 `RxObservedSlot<T>`（当前值加一个可空 relay 引用），`$x` 由 peer 宏生成、类型仍是 `BehaviorRelay<T>`。未被观察的属性只剩值本身和 8 字节的 nil 引用：零分配、零锁；读写是普通 load / store。

调用点表面不变：`x` 读写、`$x.asDriver()`、`bind(to: $x)`、`_x.hasMaterializedRelay` 全部照旧。RuntimeViewer 的 99 处 `@Observed` 一对一换成 `@RxObserved`。

## 方案

### RxSwiftPlus 侧

- `RxSwiftPlus` 新增 `public struct RxObservedSlot<Value>`：`value`、`relay: BehaviorRelay<Value>?`、`currentValue`（有 relay 时取 `relay.value`，因为 `bind(to: $x)` 直接写进 relay）、`hasMaterializedRelay`。
- `RxSwiftPlusMacro` 新增 `@RxObserved`：`@attached(accessor, names: named(init), named(get), named(set))` 加 `@attached(peer, names: prefixed(_), prefixed($))`。同一模块 `@_exported` 了 `RxSwiftPlus` 与 `RxRelay`，展开代码用模块限定名引用 `RxSwiftPlus.RxObservedSlot` / `RxRelay.BehaviorRelay`。
- 展开形态（以 `@RxObserved public private(set) var title: String = ""` 为例）：
  - accessor：`@storageRestrictions(initializes: _title) init(initialValue) { _title = RxObservedSlot(initialValue) }`、`get { _title.currentValue }`、`set { _title.value = newValue; let relay = _title.relay; relay?.accept(newValue) }`。
  - peer：`private var _title: RxObservedSlot<String>` 与 `public var $title: BehaviorRelay<String>`（有则返回，无则用 `_title.value` 建一个存回去）。
  - `$x` 的访问级别取属性的 getter 级别，`private(set)` 这类带 detail 的修饰符跳过，`open` 降为 `public`。
  - 可选类型且无初始值时 `_x` 默认 `RxObservedSlot(nil)`，与普通可选存储属性行为一致；`T!` 按 `T?` 处理。
- **独占性约束**：`set` 先写存储，再把 relay 引用拷出来、在任何对 `_x` 的访问之外调 `accept`。订阅回调里同步读 `x` 是主线程 Driver 的常态，若 `accept` 发生在对 `_x` 的 modify 访问期间会触发运行时独占性检查崩溃。`RxObservedTests` 有两条用例钉住这一点。
- **线程模型**同 `@Observable`：存储不加锁，由类型自己保证隔离。需要锁的场景继续用 `@Observed` wrapper，两者并存。
- 诊断：`let`、无类型标注（`$x` 需要显式类型）、计算属性、`static` / `lazy` / `weak` / `unowned`、非 class / actor 宿主（用 `lexicalContext` 判断）各报一条错误；只在 peer 角色报，accessor 角色沉默，避免同一声明报两次。
- 测试：`RxSwiftPlusMacroTests`（新 test target，`assertMacroExpansion`）覆盖带初始值、可选无初始值两种展开与三种诊断；`RxSwiftPlusTests/RxObservedTests` 覆盖惰性、播种、订阅、`bind(to:)`、init accessor、可选默认 nil、回放中读写回、写入过程中订阅者读到新值。

### RuntimeViewer 侧

- `RuntimeViewerArchitectures` 依赖 `RxSwiftPlusMacro` 产品并 `@_exported import`，所有已 `import RuntimeViewerArchitectures` 的文件直接可见 `@RxObserved`。
- 99 处 `@Observed` → `@RxObserved`（32 个文件，含测试与 AGENTS.md 里的规范文本）；`SidebarRuntimeObjectCellViewModel.appearance` 补上显式类型标注，它是唯一一处靠初始值推断类型的声明。
- 0017 的测试缝 `_appearance.hasMaterializedRelay` 表达式不变，`SidebarFilterRelayMaterializationTests` 原样生效。
- `RuntimeViewer-Debug.xcworkspace` 把 `../RxSwiftPlus` 加进本地包列表，与 MachOKit 等同型，Debug 构建直接吃本地检出。
- 交付：RxSwiftPlus 打 `0.2.5`，pin 升到 `from: "0.2.5"`。

### 验收

- 行为：`RuntimeViewerApplicationTests` 全绿；`SidebarFilterRelayMaterializationTests` 证明过滤链路仍不建 relay。
- 内存（推算，待用户复测回填）：每个未观察属性从 0017 的「`ObservedStorage` 约 80 B 加锁 16 B、两次 malloc」降到 0；13k 镜像行约省 1.2 MB 与 26k 次分配。读写从过一次 unfair lock 变成普通 load / store。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-02 | Created as Draft | 用户要求「继续优化一下，模仿 @Observable 宏」 |
| 2026-09-02 | 逐属性 `@RxObserved`，不做类级全量追踪 | 用户拍板。类级 `@RxObservable` 要给 cell VM 里 8 个内部状态 var 标 ignored，还要处理 weak / lazy 边界，风险高收益无差 |
| 2026-09-02 | RuntimeViewer 全部 99 处替换 | 用户拍板。项目内只留一种写法，规范同步改 |
| 2026-09-02 | 宏名 `@RxObserved`，wrapper `@Observed` 保留 | 同名会让 attribute 解析歧义；Camera / CodeEditorView / CodeOrganizer 仍用 wrapper |
| 2026-09-02 | 存储不加锁 | 照 `@Observable` 的契约；本项目写入方全在主线程（0017 已核实）。要锁就用 wrapper |
| 2026-09-02 | `accept` 必须在对 `_x` 的访问之外调用 | 否则订阅回调里同步读属性会触发独占性检查崩溃，而这在主线程 Driver 下是常态 |
| 2026-09-02 | 宏展开测试的期望里不写属性初始值 | `assertMacroExpansion` 会省略被 `init` accessor 吃掉的初始值，编译器本身保留它；`RxObservedTests` 证明初始值确实进了存储 |
| 2026-09-02 | Implemented，落地编号 0018 | 上游 RxSwiftPlus `0.2.5` 已发布（commit `64a9b8c`），pin 升到 `from: "0.2.5"`，三份 `Package.resolved` 同步。验证：RxSwiftPlus 宏展开测试 5 个、行为测试 15 个全绿；RuntimeViewer 用本地检出跑 `RuntimeViewerApplicationTests` 37 套件 197 测试全绿；`RunScript.sh --no-launch` 走 Debug 工作区（宏插件经自建预编译 swift-syntax、arm64e）主 app 编译成功；按远程 `0.2.5` pin 的解析构建与测试结果见下一行。配套文档裁定：不需要单独指南，规范已在 AGENTS.md；无新术语 |
| 2026-09-02 | 远程 pin 验证通过 | 关闭本地依赖开关、用干净 scratch 按远程 `0.2.5` 解析（`64a9b8c`），构建与 `RuntimeViewerApplicationTests` 37 套件 197 测试全绿 |
