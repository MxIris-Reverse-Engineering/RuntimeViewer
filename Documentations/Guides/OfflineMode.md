# 使用指南：离线读文件

RuntimeViewer 可以不运行任何东西，直接从磁盘读一个 Mach-O 文件、一个 `.app` / `.framework` 包或一份 dyld
shared cache，像看「My Mac」一样浏览它的 ObjC 与 Swift 接口。设计与取舍见提案
[离线模式](../Evolutions/draft-offline-mode.md)。

## 能打开什么、从哪打开

- **能打开**：薄或胖的 Mach-O 文件（胖文件按 arm64e、arm64、x86_64 的顺序取本机优先的切片）；`.app`、
  `.framework` 等包（包里的每个 Mach-O 都列出来，主程序排第一）；dyld shared cache 的主文件（选子缓存或符号文件
  也行，会换成主文件，子缓存自动带上）。
- **从哪打开**：File › Open…、Open Recent、把文件拖到 Dock 图标上，以及引擎菜单 Offline Files 一组末尾的
  Open File…。每次打开都开一个新窗口；同一个文件再开，新窗口和旧窗口用同一个引擎。
- **窗口立刻出现**：文件在后台读，读完之前内容区显示转圈和「Reading “…”…」，侧栏是空的；一份 dyld cache
  要读一会儿，单个文件通常一闪而过（读得快就不显示）。读完文件才进 Open Recent。
- 打不开时弹出原因：认不出的文件（不是 Mach-O 文件、包或 dyld cache，包里没有主程序，胖文件里没有能读的切片）
  在开窗口之前就报错；后台读失败的（文件读不了、配对的 cache 打不开）在窗口上弹提示，点 OK 后窗口关掉。

## 依赖从哪来：配对的 cache

文件链接的系统库不在文件里。读的时候要配一份 dyld cache，侧栏里文件一组、cache 一组：

- **macOS 与 Mac Catalyst 的文件**：自动配本机的 cache。
- **别的平台的文件**：从 Settings › Offline Files 登记的 cache 里挑——同平台的（模拟器的文件只配模拟器的
  cache），取版本不低于文件 SDK 版本的最旧一份，都更旧就取最新的；没有同平台的就只读文件本身。
- **换一份**：窗口在离线引擎上时，引擎菜单 Offline Files 一组末尾的 Dependency Cache 子菜单列出可选的 cache
  与 None。换了之后文件在新进程里重读，所有在这个引擎上的窗口跟着刷新。
- 打开的本来就是 dyld cache 时没有配对这一说，子菜单不出现。

## 必须知道的行为

- **每个文件一个进程**：每个离线文件在一个只属于它的离线 service 进程里解析，一个文件崩了不影响别的窗口与
  「My Mac」。进程崩了会自动拉起新的、重读文件，窗口退回镜像列表。
- **停放**：最后一个窗口离开某个离线引擎 30 秒后，它的进程退出、内存还回去，引擎留在菜单里。再选它（或再打开
  那个文件）会重新拉起进程、重新解析，窗口立刻切过去并显示「Reading…」，大文件要等一会儿。
- **不跨重启**：退出 App 后离线引擎不保留，重新打开文件即可。
- **不支持的功能**：注入（离线文件没有进程）、Load Frameworks…（工具栏按钮置灰）、交叉引用与「Keep Cross
  References Ready」（Find 与 Report 显示「此来源不支持」）。命令行 `runtime-viewer-cli` 第一版看不到离线文件；
  MCP 按窗口工作，照常可用。
- **文件变了不会自动刷新**：改了磁盘上的文件，要关掉它的窗口等停放、或换一次 Dependency Cache，才会重读。
- **派生数据**：打开 dyld cache 或配对 cache 时，cache 镜像的 Find 语料会存进派生数据（目录名
  `Offline-<平台>-<版本>-<UUID>`），下次打开同一份 cache 时直接读回；这些目录只由「删除派生数据」清掉。
