# 2026-10-17 交叉引用查询又慢又占满 CPU：查一个 AppKit 内部结构体的引用，本地运行时服务 2690% 跑了几分钟

**调查日期：** 2026-10-17
**修复落地：** 本日，`feature/cross-references`（未合入 `next`）与 MachOSwiftSection `feature/cross-reference-analysis` @ `e470f193`
**Severity：** High —— 结果最终是对的，但在 Debug 构建里一次查询要几分钟，期间除一个之外的所有核心满载；在侧栏里点来点去，Inspector 会对每个经过的对象再起一次这样的扫描
**触发场景：** 交叉引用功能（提案 `draft-cross-references` 第 5、6 步）落地后第一次试用：在 Debug 构建（从 Xcode 运行）里打开 AppKit 的 Swift 结构体 `NSSmartNamingSuggestion`，Find 导航页的 Type References 与 Inspector 的 References 标签同时在查它的引用

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | Find 的 Type References 一直停在「Loading…」，Inspector 的 References 标签一直是骨架占位；Xcode 的调试导航显示 `RuntimeViewerLocalRuntimeService` 2690%（27 个核心），App 本身 0%。控制台还有两条 RxSwift 的「Reentrancy anomaly was detected」 |
| **影响范围** | 都是这个功能新引入的（第 5、6 步与它依赖的库第二批），`main` 与 `next` 上没有 |
| **根因** | 四处叠加：① 库对 Swift 类型的预筛只看链接关系，内部类型也扫所有链接其定义镜像的镜像；② Inspector 对每个对象都查、不管标签在不在屏幕上，范围是全部镜像；③ Find 与 Inspector 同时查同一个主题，各扫一遍；④ Debug 构建里扫描器没有优化，比 Release 慢一个数量级以上，把前三条的代价放大 |
| **Status** | **Fixed** —— ①②③ 已修，各带一个修复前失败的测试；④ 是 Debug 构建的特性，不修，前三条修好后大部分查询只扫一个镜像。重入警告的成因另修（见下） |

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
