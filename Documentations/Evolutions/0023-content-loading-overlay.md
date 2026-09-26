# 0023 - 加载指示换成系统菊花，内容区加载改成 Xcode 式的整块遮罩

- **状态**: Implemented
- **创建日期**: 2026-09-25
- **最后更新**: 2026-09-26

## 摘要

`BaseViewController` 的加载指示 `CommonLoadingView` 原先是一个强调色圆环：macOS 26 起背景透明（更早是毛玻璃），
在内容区里圆环直接压在上一个对象的文字上，常常看不清；SourceEditor 开着 Minimap 时，圆环按整个内容区宽度居中，
而 Minimap 仍露在右侧，看上去不在文字区中间。

改成：`CommonLoadingView` 一律用系统菊花（spinning 样式的 `NSProgressIndicator`），背景照旧（macOS 26 以前毛玻璃、
26 起透明），所有用到它的面板一起换上；内容区另给它**编辑器背景色**，于是变成一整块不透明的遮罩，盖住整个内容区（Minimap、行号栏、工具栏
下方那一条都盖住）——Xcode 打开系统符号的生成接口时就是这个样子。出现与消失仍由 `delayedLoading` 决定，它的
宽限期从 500 ms 缩短为 100 ms：加载超过 100 ms 才出现，结束立即消失。另加一个 Debug 专用的 Settings › Developer 页，可以人为拖慢内容加载，专门用来测这个遮罩。

## 方案

**`CommonLoadingView`**（`RuntimeViewerUsingAppKit/Base/`）：

- 系统菊花，regular 尺寸（32pt），在**工具栏以下的可见区域**居中（贴它自己的 `safeAreaLayoutGuide`）。
- 视图本身铺满整个 `view`（原来只铺安全区）：设了背景色时连工具栏下面那一条也要盖住，否则上一个对象的文字会透过
  工具栏的玻璃露出来；透明时铺多铺少看不出区别。
- 默认背景照旧：macOS 26 以前是毛玻璃（给 macOS 15 用，和原来一样只铺安全区），26 起透明。背景色就用
  `LayerBackedView` 自带的 `backgroundColor`，默认 `nil`；设了之后毛玻璃让开（它是子视图，会盖在视图自己的图层
  背景之上），由背景色铺满整个视图。
- 菊花的明暗跟背景色走，不跟系统外观走：设了背景色时，按它在当前外观下解析出的亮度给菊花设 `.aqua` 或
  `.darkAqua`；没设时跟随外观。这段在 `updateLayer()` 里算，背景色变了、外观切了都会走到。内置的 Xcode 主题两种外观
  下结果与跟随外观相同；它救的是自定义主题在浅色模式下用深色背景（或反过来）的情况。
- 初始隐藏——显示着的视图哪怕透明，也会吞掉本该落到下面面板上的点击；显示、隐藏都是瞬时的，不加淡入淡出。

**`BaseViewController`**：`commonLoadingView` 从 `private` 放宽为 internal，让子类能设背景色；约束改成铺满 `view`。
绑定不动：`delayedLoading.drive(commonLoadingView.rx.isRunning)`，`isRunning` 只在 `delayedLoading` 发值时改变。
内容区每换一个对象都会在 `setupBindings(for:)` 里换上新的 ViewModel；新对象若已在加载，`delayedLoading` 在宽限期内
什么也不发，遮罩就保持换对象之前的状态，不会先撤掉、露出旧内容、再盖上。

**两个内容视图**（`ContentTextViewController`、`ContentSourceEditorViewController`）：照旧
`shouldDisplayCommonLoading`，在铺编辑器背景色的地方多一行 `commonLoadingView.backgroundColor = …`，与编辑器背景是
同一个颜色。

**一个坑**：app 里原先有个 `NSView` 扩展属性就叫 `backgroundColor`，经 KVC 转到 AppKitPlus 的
`NSView (Appearance)` 分类上。`LayerBackedView` 子类里不加限定地写 `backgroundColor`，解析到的是它，而不是图层渲染器
自己的属性，背景色于是根本不显示。用户已把这个桥接改名为 `_backgroundColor`（挂在 FrameworkToolbox 的 `box` 上），
只给 `BaseViewController.contentView` 这类普通视图用；这条也写进了 `AGENTS.md` 的 Layer-backed views 一节。

**Settings › Developer（测试手段）**。本机取接口多半命中缓存，几毫秒就回来，遮罩根本没机会出现，所以加了一个只在
Debug 构建里注册的设置页，上面一个「内容加载延迟」：关 / 0.05 s / 0.3 s / 1 s / 2 s / 5 s。短的用来确认短加载不出
遮罩；长的用来试「加载中切换对象，遮罩保持不撤」。

- 模型是新分支 `Settings.Developer`，挂在 `Settings.developer` 上，**和其它设置一样存盘**（进了
  `accessPersistedValues()` 与 `SettingsPersistenceTests` 的覆盖清单）。页面顶部是总开关 `isEnabled`（默认关）：
  关着时页上所有选项都不起作用，但各自的值保留，下次打开照旧。消费方读的是 `effectiveContentLoadingDelay`
  这类已经算上总开关的属性，不直接读原值、也不各自判断开关——测完关掉总开关即可，不用把延迟调回 Off。
- 延迟加在 `ContentTextViewModel` 默认的取数闭包里、接口缓存之前，所以缓存命中的对象也会被拖住；注入了取数
  闭包的测试不受影响。值在 ViewModel 构造时读一次（取数跑在主 actor 之外，那里读不了设置），内容区每选中一个
  对象就新建一个 ViewModel，所以改了设置从下一次选中生效。
- 这个页面是通用的开发开关归宿，不只为本提案服务；以后新增开发开关放这里，规则写进了 `AGENTS.md` 的
  Settings Integration 一节。

**遮罩变得不透明后更容易看出来的一点**：遮罩一撤，编辑器此刻画的就是新内容。管线里新文字先交给编辑器、
下一个主队列块才撤遮罩，按理同一帧落地；SourceEditor 若自己把排版推迟到之后，会露出一帧旧内容或空白。
这不是本改动引入的，只是以前透明看不出，需要在 App 里看实际效果时留意。

**验证**：见决策日志最后几条；界面效果要在 App 里看：内容区遮罩是否连 Minimap 一起盖满、菊花是否在工具栏以下居中、
撤遮罩那一刻有没有一帧旧内容或空白；其它面板（侧栏根列表、导出、Attach to Process）换成菊花后的样子。

**文档同步**：`AGENTS.md` 里 `BaseViewController` 一条改写为新的 `CommonLoadingView` 约定，Layer-backed views 一节
加上 `_backgroundColor` 的坑，Settings Integration 一节加上 Developer 页的规则；`0016-application-viewmodel-tests.md`
覆盖表里 `ContentTextViewModel` 一行补上延迟。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-25 | Created as Draft | 用户：「Content加载目前是一个loading在中间，有时候会看不清loading，另外由于引入了SourceEditor，在开启Minimap的时候loading还不会到中间……模仿Xcode的editor loading效果……需要单独封装一个loading VC，不改变目前loading的触发时机，只改界面UI」 |
| 2026-09-25 | 没找到 Xcode 画这个遮罩的具体类，按用户描述的效果实现 | `/Volumes/RE/Xcode` 只有 26.5 的 DVT* 与 SourceEditor 头文件导出，没有 IDEKit；本机没装 `runtime-viewer-cli` / `objc-section`，按符号名搜 IDEKit / IDESourceEditor 也没有对应的 loading 视图类 |
| 2026-09-25 | Draft → In Progress | 用户批准方案（「开工」），在 next worktree 里实现，暂不提交 |
| 2026-09-26 | 实现与测试完成，等界面验收；仍未提交 | 包测试全过、变异验证能变红、App 编译通过；界面效果只能在 App 里看 |
| 2026-09-26 | 加 Debug 专用的 Settings › Developer 页与内容加载延迟 | 用户：「在设置加一个develop tab，再加一个延迟加载content，让我测一下这个功能」；本机取接口多半命中缓存，不人为拖慢就看不到遮罩 |
| 2026-09-26 | 延迟不存盘，每次启动都是关 | 测完忘了关会让内容区一直变慢，而那种变慢看起来像性能回归；需要跨启动保留时再改 |
| 2026-09-26 | 页面与模型统一叫 Developer | 用户：「settings page应该叫Developer」；页面 id、`Settings.Developer`、`DeveloperSettingsView` 一并改名，免得同一个东西两种叫法 |
| 2026-09-26 | 推翻上面「不存盘」一条：Developer 设置改为存盘，加总开关 `isEnabled` 统一管住页上所有选项 | 用户：「这个要持久化，写一个总开关控制」；存盘后「忘了关」的风险由总开关兜住——关掉开关即全部失效且保留配置值 |
| 2026-09-26 | 推翻「单独封装 loading VC」：`CommonLoadingView` 本身换成系统菊花、默认透明，内容区只多设一个背景色；删掉 `ContentLoadingViewController`、`ContentLoadingViewModel` 及其测试 | 用户：「另外把CommonLoading直接换成系统菊花吧，这样就不用单独处理content的loading了，contentLoading专门给个背景色，其他地方就是透明背景」。「不改时机」不再需要单独的 ViewModel 来守：`isRunning` 本来就只在 `delayedLoading` 发值时改变 |
| 2026-09-26 | 记下 `_backgroundColor` 的坑，写进 `AGENTS.md` | 用户：「之前走了KVC的backgroundColor，导致LayerBackedView的背景颜色没用，现在我改名了」 |
| 2026-09-26 | 改造后验证：设置层 22 个全过；应用层 231 个中 1 个失败；App（Debug、arm64）编译通过 | 失败的是 `ViewModelBaseTests` 的「半秒内完成的加载不报告」：工作区里 `delayedLoading` 的等待被改成了 100 ms（用户的改动，是否保留待定），而这条测试模拟的是 150 ms 的加载。本轮包里只删了文件，没动 `delayedLoading` |
| 2026-09-26 | macOS 26 以前保留毛玻璃，设了背景色时让开 | 用户：「那个毛玻璃要保留，那个是给macOS15用的」。毛玻璃仍只铺安全区；上一轮把它连同 macOS 26 的透明背景一起改成「各处透明」是理解错了 |
| 2026-09-26 | `delayedLoading` 的宽限期从 500 ms 改为 100 ms | 用户在测试时改的，确认保留（「100ms保留」）。`ViewModelBaseTests` 的两条随之改为 100 ms：「报告长加载」那条原先靠 400 ms 的静默窗口判断，窗口必须在宽限期结束前关上，100 ms 下余量太小，改为直接量「开始加载到报告」至少 100 ms。Developer 页的档位换成 0.05 s（低于宽限期）/ 0.3 s / 1 s / 2 s / 5 s |
| 2026-09-26 | In Progress → Implemented，编号 0023，随代码同批提交到 next | 用户：「100ms保留，提交」。落地时取 origin/main 与 origin/next 的全局最大编号（0022）+1。无需配套指南或实现说明：Developer 页只在 Debug 构建出现，`CommonLoadingView` 与 Developer 页的约定已写进 `AGENTS.md`。未引入新术语，词汇表不变。macOS 15 上的毛玻璃与内容区底色、各面板换成菊花后的样子尚未人工确认 |
