# 2026-11-21 空编辑栏起始页的自审

来由：[`draft-editor-start-page`](../Evolutions/draft-editor-start-page.md) 实现完成后，对 `feature/editor-start-page`
相对 `next` 的全部改动跑了一次 `/code-review medium`。六条发现逐条按四问核实：能否复现、`next` 上有没有、值不值得修、
以前修过没有。四条在分支上修掉，两条不修，理由在下面；对修复的第二轮又找出两条（SP.7 修掉、SP.8 不修）。后来加的第 6 步（⇧⌘O 浮动条与起始页同一个搜索）
在它自己的审查关里又找出五条（SP.9–SP.13），三条修掉、两条不修；对那批修复与第 7 步（删掉侧栏自己的 Open Quickly）的审查又找出三条（SP.14–SP.16），
两条修掉、一条不修。第 8 步（最近列表跟着侧栏分层）的审查关又找出五条（SP.17–SP.21），三条修掉、两条不修；对这批修复的再审又找出两条（SP.22 修掉、SP.23 不在本功能处理）。
所有涉及的代码都是这条分支新写的，所以「`next` 上有没有」一律是没有，
「以前修过没有」一律是没修过（`git log` 查过，相关文件在 `next` 上要么不存在，要么没有这部分代码）；SP.17 是例外，见该条。

**约定**
- ID 为 `SP.<N>`。
- 修掉一条时在这里注明修复的提交，条目不删。

## 条目

| ID | 发现 | 严重度 | 复现 | 处理 | 重新判断的条件 |
|---|---|---|---|---|---|
| SP.1 | 搜索框里按回车，打开的可能是上一次查询的结果：新查询的匹配还没回来时，`.results` 里还是旧结果，`commitSearch(in:)` 照开不误 | Major | 能。先搜「libobjc」等结果出来，再输入「NSObject」立刻回车，打开的是 libobjc 镜像而不是 NSObject。回归测试「Return before the newest text's results arrive…」修前失败 | 已修：VM 记住最新查询与结果对应的查询，两者不同时回车先挂起，最新结果一到就打开其中选中的一项 | — |
| SP.2 | 第一次搜索还在读目录时按回车，回车被吞掉、什么也不开 | Minor | 能。在新的 Engine 上输入「NSObject」立刻回车，什么也不开。回归测试「Return while the first search is still reading…」修前失败 | 已修：与 SP.1 同一处，回车挂起到结果到达 | — |
| SP.3 | 焦点在起始页空白处时按方向键、Page Up / Down、Home、End、功能键，焦点会跳进搜索框、按键进了输入框：转交按键时只滤掉了控制字符，这些键的字符在私用区 | Minor | 能（按代码推断，未在界面上实测）：`NSEvent.characters` 对方向键是 U+F700 一带，不在 `CharacterSet.controlCharacters` 里 | 已修：另外要求 `event.specialKey == nil`。只在视图控制器里，App target 没有测试 target，没有自动化测试，列为目视 | — |
| SP.4 | 行的注释说图标 32 点，实际按 24 点画、也按 24 点排版 | Minor | 是注释与代码不一致 | 已修：照 Xcode（`IconView` 的布局尺寸 32 × 32）把图标位改成 32 点，图仍按 24 点画、居中，注释改成一致。对象的字形画满 32 点会比 Xcode 行里留了边的文件图标大得多 | — |
| SP.5 | 搜索目录在输入框有字期间一直沿用，这期间新索引或新加载的镜像搜不到 | Minor | 能。输入「Foo」，再从侧栏加载定义 FooBar 的镜像，接着输入「FooB」，仍找不到 FooBar | **不修**。清空输入框（或打开一项、按 Esc）后的下一次搜索会重新读目录；边输入边加载镜像的情形少见。按引擎的索引通知把新镜像增量并进目录可以修，但索引成批进行时会让输入期间反复读取，不划算 | 有人报「刚加载的东西搜不到」；或 Engine 有了按名字找对象的命令、目录不再整份读进来时（提案后续项） |
| SP.6 | 输入框的文字经手写的 `PublishRelay` 从 `controlTextDidChange` 送进 VM，而不是用控件的 rx 接口；`RuntimeViewerUsingAppKit/AGENTS.md` 规定 `PublishRelay` 只用于控件接口表达不了的事件 | Minor | 是写法问题，不影响行为 | **不修**。方向键、回车、Esc 只能从文本框委托的 `control(_:textView:doCommandBy:)` 拿到，控制器必须当委托；而 RxCocoa / RxAppKit 的 `rx.text` 靠它们自己的委托代理，两者会互相覆盖。要用 rx 接口就得再装一层转发委托，比现在一个委托收齐文字与按键更复杂。规则要防的是「一个固定控件手写 target/action」，这里不属于那种情况 | 有一个不占委托、按通知上报文字的 rx 接口时 |

## 第二轮（只审 SP.1–SP.4 的修复）

| ID | 发现 | 严重度 | 复现 | 处理 | 重新判断的条件 |
|---|---|---|---|---|---|
| SP.7 | 按回车挂起后继续打字，挂起的回车不认它是为哪段文字按的，新文字的结果一到就自动打开第一项，用户还在打字页面就跳走了 | Minor | 能。输入「NSObject」回车，紧接着改成「NSObj」，「NSObj」的结果一到就打开了。回归测试「Return waiting for its results is dropped…」修前失败 | 已修：挂起时记下当时的文字，文字一变就作废 | — |
| SP.8 | 挂起期间用 ↑ / ↓ 选的是旧结果里的行，新结果到了打开的是新结果的第一项，不是用户选的那行 | Minor | 能：新文字的结果还没到时按 ↓ 再按回车 | **不修**。旧结果里的第几行与新结果没有对应关系，按提案打开新结果里选中的那一项（新结果默认选第一项）；Xcode 在这种情况下也只有新结果可选 | 有人报「按方向键选了却打开了别的」 |

## 第 6 步的审查关（⇧⌘O 浮动条与 `OpenQuicklySearch`）

| ID | 发现 | 严重度 | 复现 | 处理 | 重新判断的条件 |
|---|---|---|---|---|---|
| SP.9 | 关掉浮动条只结束了目录，还在作答的那个词没被丢掉：它的函数体照常进入 `matches(for:)`、读出一份新目录，一直留到下次打开或关闭浮动条 | Major | 能。输入「NSObject」立刻按 Esc，匹配照样发出。回归测试「closing the bar drops the search still under way」修前失败 | 已修（2a9ea3c4）：关掉、打开一项、切换 Engine 都经同一条流复位，`flatMapLatest` 丢掉在答的词；`matches(for:)` 在调用方已取消时什么也不读 | — |
| SP.10 | 切换 Engine 后，从旧 Engine 读到的结果落地时按当前 Engine 取名字与 ID，被标成新 Engine 的；选中其中一项就在新 Engine 上打开旧 Engine 的对象 | Major | 能。输入「NSObject」后立刻切换 Engine，结果照样发出。回归测试「a window moved to another engine drops the search under way」修前失败 | 已修（2a9ea3c4）：切换 Engine 也经复位丢掉在答的词，结果另带上它来自的 Engine，落地时与当前 Engine 不同就丢掉 | — |
| SP.11 | Engine 还没列出任何镜像时（文件还在读、Engine 还在连接）读到的空目录被留用整次搜索，之后打字什么也搜不到 | Minor | 能。回归测试「a search begun before the engine lists any image reads the catalog again once it does」修前失败 | 已修（2a9ea3c4）：镜像树为空时读到的目录不缓存，下一次匹配重新读 | — |
| SP.12 | 起始页与浮动条各持有一个 `OpenQuicklySearch`，同一窗口里先用起始页的框、再按 ⇧⌘O，会各读一份目录 | Minor | 能：两处先后输入，各读一遍全部已索引镜像的对象 | **不修**。两份目录各随自己的界面结束（起始页清空或从头开始、浮动条关掉），很少同时存在；共用一份要给它们找一个文档级的主人并按使用者计数，两处结束搜索的时机也不同，代价大于偶尔多读的一份 | 测出目录的内存占用显著；或两处常被同时使用 |
| SP.13 | 浮动条「只收下当前这个词的结果」那段核对写在 `MainWindowController` 的绑定里，ViewModel 测试覆盖不到 | Minor | 是测试覆盖问题，不是错误 | **不修**。核对依赖 `QuickActionBar` 的 `SearchTask`，只在 App target 里；App target 没有测试 target。列为目视项 | App target 有了测试 target |

## 第 6 步修复与第 7 步的审查关

| ID | 发现 | 严重度 | 复现 | 处理 | 重新判断的条件 |
|---|---|---|---|---|---|
| SP.14 | 为 SP.11 的修法留下的口子：镜像树为空时读的目录不缓存，`end()` 也就取消不到它，而且每敲一个键都新起一次读取 | Minor | 能。Engine 还没列出镜像时连敲 5 个字，起 5 次读取。回归测试「keystrokes before the engine lists any image read nothing」修前失败（读了 5 次） | 已修：镜像树为空时什么也不读、直接回答没有匹配，下一次匹配再看；`OpenQuicklySearch` 加了只读的 `catalogReadCount` 供测试计数 | — |
| SP.15 | SP.9、SP.10 的两条回归测试有一部分可能因为错误的理由通过：「关掉浮动条」那条覆盖不到 `matches(for:)` 进门的取消检查；「切换 Engine」那条靠复位通过，结果上的 Engine 核对删掉它也照样通过 | Minor | 能：分别删掉取消检查、Engine 核对，两条测试都不变红 | 取消检查已补测试「a caller already cancelled reads no catalog」（删掉检查就红）。**Engine 核对不补**：它挡的是「答案已排进主队列、复位还没到」这一拍的窗口，要构造它得能替换搜索、控制答案何时排队，`OpenQuicklyViewModel` 没有这个接缝，为一行 `===` 加注入不划算 | `OpenQuicklyViewModel` 有了可替换的搜索时 |
| SP.16 | 删掉 `invalidateNodeDerivedState()` 时，「镜像未加载也要清空列表」那条测试一起没了，去掉 `.notLoaded` 分支的 `self.nodes = []` 整套测试仍全绿 | Minor | 能：删掉那一行，全绿 | 已修：给重载加了可覆写的 `isImageLoaded()`（与 `buildRuntimeObjects()` 同一类测试接缝），补测试「a reload that finds the image unloaded drops the object list the previous load published」，删掉那一行就红 | — |

另外，全量测试里起始页的「Return while the first search is still reading…」在负载下偶尔失败：挂起的回车在结果送达的回调里打开对象，
而结束搜索要经 `observeOnMainScheduler` 晚一拍才落地，测试等到对象打开就断言搜索已结束。是测试的时序写法，功能不受影响；
改为等到搜索结束。同文件其余断言 `.inactive` 的地方都是在主线程直接发出、当场执行，不受影响。

## 第 8 步的审查关（最近列表跟着侧栏分层）

| ID | 发现 | 严重度 | 复现 | 处理 | 重新判断的条件 |
|---|---|---|---|---|---|
| SP.17 | 模拟器进程的 Engine 连上之后才异步问到 `DYLD_ROOT_PATH`（负载下要十几秒，旧版 peer 不回答）。问到之前侧栏进的镜像按不带前缀的路径记下，之后看它的对象时按带前缀的 `imagePath` 又记一项，最近镜像里同一个镜像出现两行；起始页只在侧栏移动时算一次规范路径，问到前缀之后一直对不上 | Minor | 能。Engine 先不设根路径、侧栏进到镜像，再设根路径、显示它的一个对象：修前存储里是两项。回归测试「an image filed before the engine learned its peer's spelling is folded into it at the next record」与「an image the sidebar went into before the engine learned its root lists its objects from the next record」修前失败 | 已修：记录一个镜像（或对象）时，把「按 Engine 当前写法改过来正好是它」的几项合并进来（`RecentRuntimeImages.foldingOtherSpellings(of:in:canonicalImagePath:)`），别的项不动（见 SP.22）；起始页按当前写法算侧栏的路径，随存储每次变化重算。**剩下的两点**：Engine 问到根路径不通知任何人，起始页要到下一次记录才赶上，要立即赶上得让 Core 发通知，列入提案后续项；旧版 payload 根本不回答根路径时，侧栏的路径一直是不带前缀的那种，同一镜像的两行会一直留着——这时 Reveal in Sidebar、路径栏同样对不上，是全 App 的同一限制，不在本功能处理。是本步新引入的（旧的按 Engine 一列对象不涉及镜像路径）。同类问题 PR121.33 修过 Reveal in Sidebar 的比较，这次是新代码重犯 | Core 能通知根路径变化时，改为跟着通知重算 |
| SP.18 | 最近列表变空时只把列表藏起来，焦点若在列表上就留在被隐藏的视图上，方向键与回车打在它身上 | Minor | 理论上能：先单击选中一行（列表取得焦点），再不经点击侧栏让侧栏进到一个没有记录的镜像（比如从菜单），列表变空。点侧栏本身会把焦点带走，所以很少碰到 | **不修**。不崩溃（打开有越界保护），点一下搜索框就恢复；基线上换到没有记录的 Engine 时也一样。焦点只能在 App target 的视图控制器里处理，App target 没有测试 target，修了也带不上测试。列入后续项 | 有人报焦点丢失；或 App target 有了测试 target |
| SP.19 | `.switchEngine` 先换 session、再清 `currentImageNode`，起始页的 `combineLatest` 中间多发一次「新 Engine 加旧镜像路径」 | Minor | 能看到这次中间结果，但看不到后果：两次发出都在同一个路由调用里同步完成（`observeOnMainScheduler` 在主线程上直接执行），中间不会画出一帧；Show All 与选中的最终结果与没有中间这次时相同 | **不修**。没有用户可见的后果；要消除它得改 `.switchEngine` 里的赋值顺序，牵动所有跟着 `currentImageNode` 的订阅者 | 中间结果开始有副作用（比如写存储、发请求） |
| SP.20 | 路径为空的对象会被记成一个路径为空的镜像，最近镜像里多出一行没有名字的行 | Minor | 疑似：Core 有几处造出 `imagePath: ""` 的对象（按修饰名找接口时的临时对象），没查到它们会进到焦点栏。回归测试「an object or an image without a path records nothing」修前失败 | 已修（防御）：路径为空的对象与镜像都不记 | — |
| SP.21 | 测试缺口：「Recent Images」标题的断言等于初始值、永远不会失败；从镜像 A 换到镜像 B 关掉 Show All、在镜像里换 Engine、规范路径都没有测试 | Minor | 能：删掉标题逻辑，或把来源比较退化成只看「是否在镜像里」，原有测试全绿 | 已修：标题断言改为先变成 Recent Objects 再变回；补了 A→B 的 Show All、在镜像里换 Engine（标题回到 Recent Images）、模拟器路径、换 Engine 不把旧内容记到新 Engine 下几条测试 | — |
| SP.22 | SP.17 的第一版修法在每次记录前把这个键下的整列路径都按当前 Engine 的写法改写。两个同名、根路径不同的模拟器进程（或一个 Mac 进程与一个同名的模拟器进程）共用一个键，每记一次就给对方的路径再叠一层根路径，越改越长 | Major | 能。两个共用键、根路径不同的 Engine 各进同一镜像、各看一个对象：按第一版，存储里出现 `/second_root/first_root/…`。回归测试「two engines that share a key, on different roots, leave each other's images as they are」与「an entry another root spells as something else is left alone」在第一版写法下失败 | 已修：改为只合并改写后正好是这次记录的镜像的那几项，其余一概不改写。一个 Mac 进程（没有根路径）与同名模拟器进程共用键时，模拟器一侧记 `/root/X` 会把 Mac 那一项 `/X` 合并过去，Mac 一侧再记 `/X` 又建回来，之后每轮都可能再并一次。**这一点不修**：对模拟器一侧来说，Mac 的 `/X` 与自己问到根路径之前记下的 `/X` 无从区分；共用键本来就把两边的列表（以及 Always Index、Filter Scope 记忆）混在一起；每个镜像最多 10 个对象、每个键最多 10 个镜像，不会越改越长；同时附加 Mac 上与模拟器里的同名进程也少见 | 共用键的规则改变时 |
| SP.23 | `canonicalImagePath(_:)` 给一切绝对路径加模拟器根路径，模拟器 App 自己的二进制与自带 framework 在 `~/Library/Developer/CoreSimulator/Devices/…` 下，加前缀后成了不存在的路径；侧栏按这个形式记下的这类镜像，打开镜像页会找不到 | Minor | 疑似：没有实测这类镜像的对象 `imagePath` 是什么形式。若对象带的是真实路径，侧栏一项与对象一项对不上 | **不修**（不在本功能）：规范形式是 Core 的定义，`DocumentState.isSelectedRuntimeObjectInCurrentImage`、路径栏、Find 用的是同一口径，本功能照它记。要改得在 Core 里让规范形式认出根路径之外的镜像 | 实测确认对象路径与规范形式不一致时，作为 Core 的问题另立 |

## 同类排查

- **SP.1 的模式**（回车用的是还没换成新查询的结果）：⇧⌘O 浮动 Open Quickly（第 6 步起在 `MainWindowController`，侧栏那一份已删）
  由 UIFoundation 的 `QuickActionBar` 管搜索与回车，结果异步回来之前按回车打开的是什么，由那个组件决定，不在本仓库，这次没有改。
- **SP.9 / SP.10 的模式**（结束搜索只丢目录、不丢在答的词）：起始页的搜索一直是经同一条流复位的（`startOver()` 发空串），
  只剩一个罕见的竞态（复位之后才开始执行的那次匹配），由 `matches(for:)` 的取消检查一并堵上；仓库里没有别处用 `OpenQuicklySearch`。
- **SP.3 的模式**（把按键转交给输入框）：仓库里没有别处这样转交按键。
- **SP.17 的模式**（在 Engine 问到路径写法之前算好规范路径、之后不再重算）：路径栏的 `EditorJumpBarItemStore`
  把镜像节点按规范路径建成表，只在镜像树换掉时重建；表若在问到 `DYLD_ROOT_PATH` 之前建好，模拟器进程的对象就找不到它的镜像节点，
  路径栏退回「未列出的镜像」那一项。基线上本来就有，与本功能无关，不在这条分支上修，记进提案后续项。
  其余按规范路径比较的地方（Find、交叉引用、索引、`DocumentState`）都在用的时候现算，没有这个问题。
