# Draft - 离线模式打开文件夹：列出其中全部二进制，按需打开

- **状态**: In Progress
- **创建日期**: 2026-11-06
- **最后更新**: 2026-11-06
- **关联提案**: [0069](0069-offline-mode.md)（离线模式本身：Mach-O 文件、bundle 与 dyld cache 的读法，每个文件一个进程，配对 cache）
- **实现分支 / PR**: `feature/offline-folders`（从 `next` 切，并回 `next`）

## 摘要

离线模式能打开单个 Mach-O、`.app` / `.framework` 包和 dyld cache，选普通文件夹却报「The bundle “…” has no
executable.」：`RuntimeOfflineFile(contentsOf:)` 把每个目录都当成 bundle，找不到主程序就拒绝（打开面板本来就允许选
目录）。本提案让不是 bundle 的目录按文件夹打开：它和所有子目录里（包括其中的 `.app`、`.framework`）的可执行文件、
动态库与插件都列进侧栏。同时把离线读文件改成按需打开：打开时只遍历、读文件头，点进去或被索引用到时才真正打开那个
二进制。现在一开包就把里面每个二进制都打开并一直不关，每个占一个文件描述符，文件夹一大就会耗尽；改了之后打开大的
`.app` 也跟着变轻。

## 方案

**判定**（Core，`RuntimeOfflineFile`）

- `RuntimeOfflineFile.Content` 加 `case folder`，名字照 `UTType.folder`（用户能浏览、不是包的目录）。目录照旧先问
  `Bundle(url:)?.executableURL`：有主程序是 `.bundle`，否则是 `.folder`——普通文件夹，也包括 `.xcframework`、
  `.xcarchive` 与没有主程序的包。
- 平台取「按名字排序、广度优先遇到的第一个二进制」的平台，按 0069 的规则挑配对的 cache；一个都找不到就在开窗口之前
  报错（新错误 `folderWithoutMachOFiles`）。这一步在 App 里跑，遇到第一个二进制就停。

**遍历**（Core，`RuntimeFileImageCatalog`，文件夹与 bundle 共用）

- 跳过符号链接（不跟进链接的目录，框架的 `Versions/Current` 不重复）；进入包内容与隐藏目录（SwiftPM 的 `.build`
  里就是产物）；读不了的子目录跳过，不中止遍历。
- 小于 4 KB 的文件不读（链接好的镜像至少有一整页 `__TEXT`），其余只读文件头：Mach-O 或胖文件的魔数，再取本机优先
  切片的 `filetype`。只收 dyld 能加载的镜像：`MH_EXECUTE`、`MH_DYLIB`、`MH_BUNDLE`；`.o`（`MH_OBJECT`，指针没有
  重定位）与 dSYM 里的 DWARF 文件（`MH_DSYM`，代码段在文件里没有内容）不收。单独打开一个文件的行为不变。
- 实测（单线程 `head` 读每个文件的前 4 字节，热缓存）：Xcode.app 有 126,027 个文件、3,227 个二进制，全部读一遍
  17.5 秒；先按大小筛掉后剩 58,259 个，4.1 秒。实现里目录本身顺序遍历，文件头并发读取。
- 镜像按路径排序。文件夹没有主程序，引擎的 `mainExecutablePath()` 返回空串，打开时不启动「主程序依赖闭包」那一批
  后台索引（打开 dyld cache 时就是这样）；点开某个镜像触发的索引照常进行。

**按需打开**

- 目录只记下每个镜像的路径与 `filetype`，不留任何打开的文件。`machO(forImagePath:)` 第一次被问到时才打开并缓存：
  点开镜像、后台索引走到它、批量导出用到它、依赖解析读它的加载命令。侧栏、镜像清单与 `isImageLoaded` 都只用路径。
- 按名字找 ObjC 类（`image(definingObjCType:)`）现在挨个查每个镜像的导出符号。改为第一次需要时把文件里的镜像逐个
  打开、记下导出的 `_OBJC_CLASS_$_` 名字、随即关掉，建成一张表，之后查表。配对 cache 的镜像照旧：它们共用 cache
  文件的映射，不额外占描述符。
- 不设数量上限。描述符只跟打开过的镜像有关（每个约 3 个：MachOKit 与 Swift、ObjC 两个读取层各一个），点开几十上百
  个不成问题。剩下的边界是一次会话里真正读过两三千个二进制（例如把一个大文件夹整个批量导出），写进使用指南。

**依赖查找按 App 划范围**

- MachOSwiftSection 的依赖定位器建闭包时，会把搜索路径里的每个 `.machOFile` 都打开。现在目录把包里每个二进制都放进
  搜索路径，解析 Swift 镜像时一用到依赖闭包，就把它们全部打开一遍；文件夹里装着几个 App 时，还会把别的 App 里同名
  的框架当成依赖。
- 改为每个镜像一份搜索路径（`RuntimeImageCatalog.dependencySearchPaths(forImageAt:)`，Swift 工厂按镜像建索引配置与
  静态布局的依赖解析）：先是它所在 App（往上最外层、主程序为 `MH_EXECUTE` 的包）里的二进制，再是不属于任何 App 的
  二进制，最后是配对的 cache；别的 App 的不进来。打开一个 `.app` 时所有镜像都在同一个 App 里，结果与现在相同。

**`@executable_path` 按镜像所在的 App 展开**（文件夹与 bundle）

- 一个镜像的主程序，是它往上最近的、主程序为 `MH_EXECUTE` 的包（`.app`、`.appex`、`.xpc`；`.framework` 的主程序是
  动态库，跳过）里的那个可执行文件；镜像本身是可执行文件就是它自己；都不是时用后台索引传进来的那个。文件夹里有几个
  App 时各按各的展开，`.app` 里的 `.appex`、`.xpc` 也不再借用外层 App 的主程序。命令的线上格式不变。
- 依赖解析出的路径换成目录登记的路径（`RuntimeImageCatalog.listedImagePath(forResolvedPath:)`）：Xcode 编出的 App
  以 `@rpath/X.framework/X` 链接框架、运行路径是 `@executable_path/../Frameworks`，在磁盘上解析出来是
  `…/MacOS/../Frameworks/X.framework/X`，经过 `..` 和框架的两个符号链接，而目录登记的是链接最终指向的
  `…/X.framework/Versions/A/X`。离线目录按 `realpath(3)` 换回登记的路径；进程内的目录照旧，dyld 认不出路径时按文件名找。

**App**

- `Info.plist` 的 Viewer 文档类型加 `public.folder`，文件夹能拖到 Dock 图标上打开；Finder 里每个文件夹的「打开方式」
  都会列出 RuntimeViewer，`Alternate` 级别，不抢默认。类型名「Mach-O File or Bundle」不改。
- File › Open… 面板的说明加上文件夹；Open Recent 记的是 URL，不用改。
- 文件夹的 Dependency Cache 子菜单列出本机 cache 与全部登记的 cache，不按平台过滤，每份标上平台名：一个文件夹可能混着
  几个平台的二进制（如 `.xcframework`），自动挑的那份只按第一个二进制定。筛选挪进 `Settings.Offline`
  （`dependencyCaches(for:)`、`canPairWithThisMacsCache(_:)`），以便测试。

**测试**（swift-testing，Core 的在 `OfflineFolderTests`）

- 文件夹用临时目录现搭：`/usr/bin/true` 的副本（为 macOS 编的胖可执行文件，不定义 ObjC 与 Swift 类型），以及只有
  Mach-O 文件头、可带 `LC_LOAD_DYLIB` 与 `LC_RPATH` 的小文件——列出与依赖解析读的就这么多。
- 判定与列出：没有主程序的目录（含 `.xcframework` 那样带 `Info.plist` 的）是 `.folder`，平台取第一个二进制；只列出
  可执行文件、动态库与插件，`.o`、dSYM、小于 4 KB 的文件、符号链接与非 Mach-O 文件都不列；空文件夹报
  `folderWithoutMachOFiles`；文件夹没有主程序；`/var` 下的 bundle 主程序排第一、只出现一次。
- 按需打开：exit test 的子进程把描述符软、硬上限都压到 256，打开装着 300 个库的 bundle 并读它的可执行文件——改前只列得
  出一部分，改后 301 个全列出、读取成功；按名字找 ObjC 类找到文件夹里测试 bundle 二进制导出的类（打开的是它所在的
  `Contents/MacOS` 目录）。
- 按 App 划分：两个 App 的文件夹里，`@executable_path` 依赖按库所在 App 的主程序解析；`.appex` 里的库归它自己的主程序；
  依赖搜索路径只含自己 App 与不属于任何 App 的二进制；整个 `.app` 当 bundle 打开时是一个范围；经运行路径与框架符号链接
  的依赖解析到目录登记的文件。
- Settings：文件夹的 Dependency Cache 候选不按平台过滤。
- 界面、Dock 拖放与 Open Recent 归人工验收：打开一个装着几个第三方 App 的文件夹、一个 `.xcframework`，再按
  bundle 打开 Xcode.app，确认按需打开之后照常浏览。

**文档**：使用指南 `Guides/OfflineMode.md`（能打开什么、报错、文件夹的 Dependency Cache、描述符的边界）；根
`AGENTS.md` 与 `RuntimeViewerUsingAppKit/AGENTS.md` 里列离线文件种类的几处；README 两处；术语表「离线文件」「镜像
目录」两条；两份索引。

**不做**：`.a` 静态库（ar 归档，MachOKit 不读）；`.ipa`（zip，要先解压）；文件夹内容变了自动刷新（与现有离线文件
一致）；让读取层不常驻描述符、让依赖定位器按需打开搜索路径（上游 swift-fileio、MachOKit、MachOSwiftSection 的改动，
另立提案）。

**落地步骤**（每步构建通过、相关测试通过后提交一次）

| 步骤 | 内容 | 状态 |
|------|------|------|
| 1 判定与遍历 | `Content.folder`、`folderWithoutMachOFiles`、平台探测；文件夹与 bundle 共用的遍历（符号链接、4 KB、`filetype`、排序） | 完成（与第 2 步同一次提交）：`OfflineFolderTests` 8 例通过；离线相关的 Core 测试（`OfflineFileEngineTests`、`RuntimeOfflineServiceHostTests`、离线派生数据与交叉引用）全过 |
| 2 按需打开 | 目录只记路径与 `filetype`，`machO(forImagePath:)` 首次打开并缓存；ObjC 类名表 | 完成：描述符压到 256 的子进程测试在改前的 `next` 上是红的（目录只列出一部分），改后通过 |
| 3 按 App 划分 | 每个镜像一份依赖搜索路径（目录与 Swift 工厂）；`@executable_path` 按镜像所在的 App 展开 | 完成：`OfflineFolderTests` 增至 13 例全过；经运行路径与框架符号链接的依赖那条在改前的 `next` 上是红的 |
| 4 App | `Settings.Offline` 的文件夹候选 cache 与 `OfflineFileController`；打开面板说明；`Info.plist` 的 `public.folder` | 完成：`OfflineSettingsTests` 7 例通过（Debug 设置文件校验和前后不变）；`./RunScript.sh --no-launch`（隔离构建目录）编过，产物 `Info.plist` 的 Viewer 类型带 `public.folder` |
| 5 文档与验证 | 使用指南、`AGENTS.md`、README、术语表；Core 与 Packages 测试、App 构建 | 完成：Core 全量 1,046 项、Packages 全量 1,083 项；满载下各挂 2 条，交叉引用预先准备、后台索引取消批次、Find 调用层级 3 条单独重跑全过，标题区悬停显示进度 1 条在改前的 `next` 上同样失败；Debug 设置文件校验和前后不变 |

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-06 | Created as Draft | 离线模式能打开 App 却打不开普通文件夹：目录一律按 bundle 判定，找不到主程序就报错 |
| 2026-11-06 | 文件夹与 bundle 都改成按需打开，去掉初稿的 2,000 个上限 | 用户指出侧栏只需列出、点进去才加载。上限是现有实现一开就把每个二进制都打开、一直占着描述符造成的，不是列出本身的代价；同一套读法让打开大的 `.app` 也变轻 |
| 2026-11-06 | `Info.plist` 声明 `public.folder` | 用户选定：文件夹能拖到 Dock 图标上打开，代价是 Finder「打开方式」里多一项 |
| 2026-11-06 | 依赖搜索路径按镜像所在的 App 划范围 | 按需打开之后，依赖定位器仍会把搜索路径里的文件全部打开；文件夹里有几个 App 时还会混用别的 App 里同名的框架 |
| 2026-11-06 | 用户批准，开始实现；补上落地步骤 | 精简提案原先只有方案，开工前拆成五步，每步各自构建、测试通过后提交 |
| 2026-11-06 | 第 1、2 步合成一次提交 | 按需打开改的正是第 1 步新写的遍历与目录，先写一版一开就全打开的再改掉，中间那版没有用处 |
| 2026-11-06 | 遍历到的路径改记在打开时的路径之下 | 目录枚举按真实路径报结果（`/var/…` 下报成 `/private/var/…`），而 `RuntimeOfflineFile` 记的路径去掉了 `/private`，bundle 的主程序也按它去找；不改的话临时目录里的包找不到主程序 |
| 2026-11-06 | 文档类型名不改，只在 `LSItemContentTypes` 里加 `public.folder` | 改名只是好看；类型名是 `NSDocument` 认文档种类的键，改了可能牵动已有文档，没有必要冒这个险 |
| 2026-11-06 | 文件夹的 Dependency Cache 菜单项标上平台名 | 不按平台过滤之后，同一个版本号可能是几个平台的 cache，不标就分不出；文件与包的菜单项照旧 |
| 2026-11-06 | 依赖解析出的路径换成目录登记的路径（新的目录要求 `listedImagePath(forResolvedPath:)`），顺带修掉 bundle 的老问题 | 第 3 步写测试时发现：按运行路径链接的框架解析成带 `..` 与符号链接的写法，离线目录按路径精确查找，查不到，后台索引把这些依赖记成打不开。0069 起离线 bundle 就是这样（同一测试在改前的 `next` 上是红的）；进程内的目录查不到时按文件名兜底，没有这个问题。整个代码库只有 `dependencyEntries` 一处把解析结果当路径用 |
| 2026-11-06 | 实现完成，待用户验收后收尾 | 五步都已提交并推送功能分支；界面、Dock 拖放与 Open Recent 的人工验收还没做。文档：更新已有的使用指南 `Guides/OfflineMode.md`，不另写实现说明（「包与文件夹的镜像只在用到时打开」这条约束写进了根 `AGENTS.md`）；没有新术语，术语表「离线文件」「镜像目录」两条补上文件夹与按需打开 |
