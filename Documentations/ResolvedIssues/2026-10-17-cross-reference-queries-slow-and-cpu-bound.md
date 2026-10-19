# 2026-10-17 交叉引用查询又慢又占满 CPU：查一个 AppKit 内部结构体的引用，本地运行时服务 2690% 跑了几分钟

**调查日期：** 2026-10-17
**修复落地：** 本日，`feature/cross-references`（未合入 `next`）与 MachOSwiftSection `feature/cross-reference-analysis` @ `e470f193`
**Severity：** High —— 结果最终是对的，但在 Debug 构建里一次查询要几分钟，期间除一个之外的所有核心满载；在侧栏里点来点去，Inspector 会对每个经过的对象再起一次这样的扫描
**触发场景：** 交叉引用功能（提案 `0056-cross-references` 第 5、6 步）落地后第一次试用：在 Debug 构建（从 Xcode 运行）里打开 AppKit 的 Swift 结构体 `NSSmartNamingSuggestion`，Find 导航页的 Type References 与 Inspector 的 References 标签同时在查它的引用

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | Find 的 Type References 一直停在「Loading…」，Inspector 的 References 标签一直是骨架占位；Xcode 的调试导航显示 `RuntimeViewerLocalRuntimeService` 2690%（27 个核心），App 本身 0%。控制台还有两条 RxSwift 的「Reentrancy anomaly was detected」 |
| **影响范围** | 都是这个功能新引入的（第 5、6 步与它依赖的库第二批），`main` 与 `next` 上没有 |
| **根因** | 四处叠加：① 库对 Swift 类型的预筛只看链接关系，内部类型也扫所有链接其定义镜像的镜像；② Inspector 对每个对象都查、不管标签在不在屏幕上，范围是全部镜像；③ Find 与 Inspector 同时查同一个主题，各扫一遍；④ Debug 构建里扫描器没有优化，比 Release 慢一个数量级以上，把前三条的代价放大 |
| **Status** | **Fixed** —— ①②③ 已修，各带一个修复前失败的测试；④ 是 Debug 构建的特性，不修，前三条修好后大部分查询只扫一个镜像。重入警告的成因另修（见下）。2026-10-18 第二次试用仍然满载，又修了 ⑤⑥，见「第二轮」 |

---

## 根因与修法

### ① 内部类型也按链接关系扫几乎整个缓存

库的 `imageIndices(referencingSwiftType:among:)` 把「能绑定到定义镜像的镜像」都算作候选——缓存里很少有镜像在符号表里留着 Swift 的未定义符号，所以第二批改成按链接关系判断。可这对内部类型不成立：别的镜像要引用一个类型，只能经它的符号绑定（描述符 `…Mn`、元数据访问器 `…Ma`、元数据 `…N`），或者在名字里拼出它，内部类型在别的模块里拼不出来。

`NSSmartNamingSuggestion` 就是内部的：`dyld_info -exports` 列出 AppKit 的 11323 个导出，没有一个属于它（28 个同名前缀的都是另一个类 `NSSmartNamingSuggestionController`）。它的一次类型引用查询却扫了所有链接 AppKit 的镜像。实测（RuntimeViewer 的测试，Debug 构建）：修复前 231 秒，修复后 6.8 秒（只扫 AppKit，含分析器第一次初始化）。

修法在库里：定义镜像一个这类符号都不导出时，候选只留定义镜像；类的那条预筛（Swift 类也会按链接关系补一遍）跟着不补。公开类型三个符号都导出（`URL`、`SwiftUI.Text`、`JSONEncoder` 已核对），原有「不漏引用」的测试照样通过。Swift 函数不需要同样处理：缓存里没导出的函数在进程内看不到本地符号，本来就不会按链接关系扩大候选。测试：库的 `typesNoImageExportsAreLookedForInTheirOwnImage`（还对链接 AppKit 的镜像每 64 个抽 1 个确认确实没有引用）、本仓库的 `internalSwiftTypesScanTheirOwnImage`。

### ② Inspector 在看不见的时候也查，查的还是全部镜像

Inspector 让每个标签都跟着当前对象更新（`InspectorRuntimeObjectCoordinator.updateTabViewControllers`），References 标签因此在每次选中对象时都发起一次全部镜像的类型引用扫描，标签选没选中都一样。

修法：标签不在屏幕上时什么都不查，出现时再查隐藏期间变了的主题（`rx.viewWillAppear` / `rx.viewWillDisappear`，Report 导航页同样做法）；范围改为对象所在的那一个镜像，标题下注明「In AppKit」，要看全部镜像用段尾的 Show in Find Navigator（用户 2026-10-17 选定）。测试：`queriesWaitForTheTabToShow`。

### ③ 两处同时查同一个主题，各扫一遍

会话按镜像缓存扫描结果，但只认扫完的：两个同时开始的查询都看不到对方，于是各扫一遍，各开满处理器核数减一个任务。修法：会话按「扫描键 + 镜像 + 代次」登记正在进行的扫描，后到的查询等它的结果（`CrossReferenceSession.sharedScan`）。一个镜像的扫描一旦开始就做完，和以前一样；取消一个查询停下的是它还没开始的镜像。测试：`concurrentQueriesShareTheirScans`（修复前同一个 AppKit 扫了两次）。

### ④ Debug 构建里扫描器没有优化

测试也是 Debug 构建：只扫 Foundation 一个镜像的类型引用测试要 3.4 秒，而库在 Release 下实测六个大镜像单线程合计 1.15 秒。SwiftPM 的远程依赖在 Debug 配置里按 `-Onone` 编译，没有按目标单独打开优化的办法（`unsafeFlags` 对依赖包不可用）。不修；要判断 Release 的体感用 Release 构建。

### Rx 的「Reentrancy anomaly」

Find 页在应用一次发布的结果时会把该展开的行重新展开（`FindResultsPresentation.apply(to:)`），展开通知同步回到会话；一层刚加载完、没有在跑的加载时，会话就在这次通知里启动下一层并再发布一次——新结果在页面还没处理完上一次时送到同一个订阅者手里。多个根一起自动展开时最容易碰到。

修法：展开行时只登记，启动下一层放到主线程的下一轮；一层加载完时先启动下一层，再统一发布一次。测试：`expansionNeverPublishesWhileThePageApplies`（换回提交里的旧版 `FindSession` 跑过，修复前红）。

---

## 第二轮（2026-10-18）：换上新库后仍然满载

用户换上 MachOSwiftSection `e470f193` 再试（Debug，从 Xcode 跑）：「目前太慢了，而且占用CPU太多了，直接100%啥也干不了」。上面三条修好后，没导出符号的类型与 Inspector 都只扫一个镜像了，剩下的是 Find 的查询本身。

### ⑤ 交叉引用按整个缓存扫，界面却写着只查已索引的镜像

Find 的范围按钮默认是「In Indexed Images」，文本搜索也确实只读已索引的镜像；交叉引用却把它换成 `.allImages`——整个共享缓存（4,113 个镜像）加上缓存外已加载的镜像。常见的方法名与公开类型预筛之后仍有成百上千个候选：`makeKeyAndOrderFront:` 约一百个，`init` 两千多个。而用户设置里常驻索引的只有 AppKit、Foundation、libswiftCore、SwiftUI、SwiftUICore 五个。

### ⑥ 扫描占住了服务进程的 Swift 协作线程池

每次查询开「核数减一」个任务（这台机器 27 个），每个都在协作线程上不让出地解码一整个镜像，Debug 下一个大镜像要几秒。协作线程池的宽度等于核数（28），被占掉 27 个之后，本地运行时服务里引擎的其他工作——侧栏的对象列表、内容区的接口——只剩一个线程，App 里点什么都要等。第 3 步选「核数减一」本来就是要给这些请求留线程（提案决策日志 2026-10-16），可只留一个不够；Find 与 Inspector 的查询同时在跑时，两边各开 27 个，连那一个也保不住。④ 的 Debug 慢 20–50 倍又把这两条放大了。

### 修法

用户定的：「分析只在已经索引的image里面进行，其他没加载索引的不分析」；「具体用多少核让用户可以决定，跟后台索引一样，设置里面可以改」。

- 范围 `.allImages` 改名 `.indexedImages`：候选只从引擎已索引的镜像里挑（两种 section 都建好了的，`indexedImagePathList()`，与文本搜索同一个判定）；指定的单个镜像没索引就报 `imageNotIndexed`，不扫。Callees 只解码一个函数，不受影响。
- 扫描移到会话自己的 `OperationQueue`：utility 优先级，不占协作线程池，整个进程同时最多 N 个；每个查询也只把 N 个镜像交给队列，取消时剩下要扫完的不超过 N 个。
- N 是设置 › Search › Cross References 的 Max Concurrent Scans（1 到核数，默认 4，与后台索引的默认并发数相同），Find 与 Inspector 每次查询都经选项 `maximumConcurrentScans` 带到服务进程。

### 测试

都在 `CrossReferenceQueryTests`，都在临时把三处改回旧行为后确认失败，跑完恢复：

| 测试 | 旧行为下 |
|---|---|
| `indexedImagesBoundTheScan`：只索引 AppKit，查 `makeKeyAndOrderFront:` 的调用者 | 结果里有 AppKit 以外的镜像，进度的镜像总数不是 1 |
| `imagesNotIndexedAreRefused`：只索引 AppKit，指定 Foundation | 没报错，照扫 Foundation |
| `queriesReadTheirEnginesIndexedImages`：真引擎只索引了 libobjc | 结果来自未索引的镜像，指定 Foundation 也没报错 |
| `scansRunAFewAtATimeOffTheThreadPool`：上限 3，同时发起 9 个扫描 | 9 个同时跑，default 优先级，跑在协作线程上 |
| `optionsSetHowManyImagesAreScannedAtOnce`：查询选项带 2 | 没生效，上限停在 4 |
