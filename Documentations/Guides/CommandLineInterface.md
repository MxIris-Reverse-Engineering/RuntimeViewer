# 使用指南：`runtime-viewer-cli`

- **面向**: 在终端或脚本里查本机运行时的人；把 RuntimeViewer 接进 agent 工作流的人
- **对应提案**: [draft-command-line-interface-foundation](../Evolutions/draft-command-line-interface-foundation.md)、[draft-command-line-interface-multi-source](../Evolutions/draft-command-line-interface-multi-source.md)
- **最后更新**: 2026-09-06

不打开 RuntimeViewer 的窗口，用一条命令拿到某个类型的接口、某个镜像的类型清单，或把整个镜像
的接口导出到目录。来源覆盖 GUI 支持的全部：本机进程内引擎（`--source local`，默认值）、Mac
Catalyst 运行时、attach 进的进程、Bonjour 发现的设备，以及对端转发过来的镜像引擎；`sources`
列出此刻能用的来源和回填 `--source` 的 selector。App 在跑时由 App 充当 host（见「App 优先与
接管」），否则第一条命令在后台拉起独立 host。

## 构建与运行

```bash
cd RuntimeViewerCommandLine
swift build -c release --product runtime-viewer-cli
.build/release/runtime-viewer-cli interface NSView --image AppKit
```

第一条命令会在后台拉起一个 **CLI host**（见下文），之后的命令都复用它。要看它在做什么，
可以在前台跑一个：`runtime-viewer-cli host run --idle-timeout 0`。

## 命令一览

全局选项对每条子命令都有效：`--source <selector>`、`--json`、`--timeout <秒>`、`--no-spawn`。

| 命令 | 作用 |
|---|---|
| `images [--loaded] [--query 文本]` | 列出 host 能看到的镜像：dyld 已映射的加上系统目录（共享缓存、`/System/Library/Frameworks` 等）。`--loaded` 只列已经加载并建好索引的 |
| `load <路径>` | 把一个 Mach-O 加载进 host 并建索引 |
| `types [--image i] [--kind k]...` | 列类型。`--kind` 可重复：`objc-class`、`objc-protocol`、`objc-category`、`swift-class`、`swift-struct`、`swift-enum`、`swift-protocol`、`swift-typealias`、`swift-extension`、`swift-conformance`、`c-struct`、`c-union` |
| `search <文本> [--image i] [--regex] [--kind k]...` | 按子串（不分大小写）或正则匹配类型名与显示名 |
| `interface <类型> [--image i] [--full \| --options default\|full\|app]` | 打印接口文本 |
| `hierarchy <类型>` / `relationships <类型>` / `members <类型> [--member 文本]` | 类层级 / 子类与遵循者 / 成员地址 |
| `specialize <泛型类型> --image i [--list] [--argument 参数=类型]...` | 先 `--list` 看泛型参数与候选，再逐个 `--argument` 绑定；输出特化后的接口 |
| `export <镜像> --output 目录 [--objc single\|directory] [--swift single\|directory] [--no-metadata]` | 导出整个镜像的接口，进度打到 stderr |
| `sources [--wait 秒]` | 按主机分组列出 host 能服务的来源，每行给出可回填 `--source` 的 selector、种类与连接状态。`--wait` 给还在连接的 Bonjour 对端留时间；列表连续 3 s 没变就提前返回 |
| `attach <pid \| 进程名>` | 注入运行中的进程并把它变成来源，进度打到 stderr；成功后打印该用的 selector（Mac 进程 `pid:<n>`，Simulator 进程 `engine:<id>`）。前提见「来源寻址」 |
| `detach <pid \| selector>` | 断开 attach 进的进程或一个 Bonjour 对端；不给参数时用 `--source` |
| `host [status]` / `host stop` / `host restart` / `host run [--app-bundle 路径] [--local-only]` | 查看、停止、重启 CLI host；`run` 在当前进程里前台运行一个 host，`--local-only` 只起一个进程内引擎（基础提案的行为） |

### 类型与镜像怎么解析

- **`--image`** 接受绝对路径或短名。短名按这个顺序找：已加载的镜像 → host 进程已映射的镜像 →
  系统目录（共享缓存与框架目录）→ 当作字面路径。每一步都先按去掉扩展名的文件名精确匹配（不分
  大小写），再退回到文件名包含该子串。所以 `--image AppKit` 在全新的 host 上也能用，`--image
  objc` 会命中 `libobjc.A.dylib`。
- **不给 `--image`** 就在已加载的镜像里找；一个也没加载时报 `imageNotFound`，提示先 `load`。
- **类型名**先精确匹配内部名 `name`，再精确匹配 `displayName`，最后不分大小写匹配两者；会深入
  已有的特化子节点。

### 来源怎么解析

| selector | 命中什么 | 找不到时 |
|---|---|---|
| `local` | 系统引擎组里的本机进程内引擎 | 刚拉起的 host 还没把它起来，稍后重试 |
| `catalyst` | 系统引擎组里 `source == .macCatalystClient` 的引擎 | 报 `sourceUnavailable`，附上管理器记录的 Catalyst helper 失败原因；需要 helper daemon 与 App 包里的 Catalyst helper |
| `pid:<n>` | attach 组里 identifier 等于该 pid 的引擎（XPC 或 local socket 都算） | 提示先 `attach <n>` |
| `process:<名>` | attach 组里显示名等于该名字（不分大小写）的引擎；多个同名报 `sourceUnavailable` 并列出各自的 `pid:` | 提示 `attach <名>` |
| `engine:<id>` | 四组里 `engineID` 相等的引擎——Bonjour 直连、镜像引擎，以及 sections 里隐藏的管理连接都靠它 | 提示 `sources --wait 5` 重新发现；对端重连后 id 会变 |

- 命中的引擎还要处于连接态；没连上时报 `sourceUnavailable` 并说明状态（still connecting / disconnected）。
- **刚拉起的 host 有 8 s 启动宽限**：管理器是异步把引擎起来的（`.local` 立刻，Catalyst helper 与
  已注入进程的重连稍后），resolver 创建后 8 s 内的未命中会每 100 ms 重试，宽限过了才报错。所以
  第一条命令不会因为时序失败，但一个确实不存在的 `pid:` 在这 8 s 里要等到宽限结束才得到错误。
- **attach 的前提**：helper daemon 已安装（RuntimeViewer → Settings → Helper Service），以及一份
  RuntimeViewer.app 用来取注入载荷与 Catalyst helper。独立 host 按这个顺序找 App 包：
  `host run --app-bundle <路径>` → 环境变量 `RUNTIME_VIEWER_APP_BUNDLE` → 自己所在的 `.app`（嵌入 App
  时）→ Launch Services 里按 bundle identifier 登记的已安装 App（Debug 工具找 `dev.JH.RuntimeViewer.arm64e`
  / `dev.JH.RuntimeViewer`，Release 找 `com.JH.RuntimeViewer`）。不存在的路径会被跳过。四步都落空时
  `attach` 报 `applicationBundleNotFound`，`catalyst` 报 `sourceUnavailable`；local 与 Bonjour 来源
  不受影响。`host.log` 的第一行会写明用了哪个 App 包。
- **进程名怎么匹配**：`attach <名>` 对进程名（`proc_name`）与可执行文件名不分大小写地精确匹配，
  多个命中报 `ambiguousProcessName` 并列出 pid；`attach <pid>` 对不可读的进程（别的用户的）用
  `pid <n>` 作为名字继续。已经 attach 过的进程直接回答现有引擎，不会注入第二次。
- **Simulator 进程**的引擎经 Bonjour 回连，identifier 是 `{deviceID}-{pid}`，所以 `attach` 对它输出
  `engine:<id>` 而不是 `pid:<n>`。

### 生成选项三档

| 取值 | 含义 |
|---|---|
| `default` | 库默认值 |
| `full`（或 `--full`） | 全部注释与布局细节打开，等于 App 里 MCP 用的那套（`GenerationOptions.mcp`） |
| `app` | RuntimeViewer App 当前配置：生成选项从 App 的 `UserDefaults` 域里 `generationOptions` 键读，transformer 配置从 `~/Library/Application Support/RuntimeViewer[-Debug]/settings.json` 的 `transformer` 键读；哪一半读不到就用那一半的默认值 |

## 必须遵守的契约

这些都从命令签名上看不出来，违反了会得到莫名其妙的结果。

1. **相对路径在客户端解析**。`load`、`export --output`、`--image` 里的路径在发给 host 之前就被
   转成绝对路径；host 的工作目录与你的终端无关。脚本里传相对路径没问题，但不要指望 host 会
   按你的 `cwd` 去找。
2. **Debug 与 Release 成对**。Debug 构建的 CLI 用 `~/Library/Application Support/RuntimeViewer-Debug/
   CommandLineHost/`，读 Debug App（`dev.JH.RuntimeViewer`）的选项；Release 构建用不带后缀的目录
   和 `com.JH.RuntimeViewer`。两套互不相见，`swift build` 默认是 Debug。
3. **host 会自己退出**。没有连接也没有在途命令持续 600 s 后 host 退出，下一条命令再拉起来（重新
   建索引要几秒）。环境变量 `RUNTIME_VIEWER_CLI_IDLE_TIMEOUT` 改默认值（秒，`0` 表示不退出），
   `host run --idle-timeout` 对前台 host 同样有效。
4. **只服务同一用户**。socket 文件权限 `0600`，host 还会核对对端 uid；别指望跨用户共享一个 host。
5. **`--json` 时 stdout 只有一个 JSON 文档**。成功是结果模型本身（字段名与 MCP 的
   `MCPRuntimeTypeInfo` 对齐：`name` / `displayName` / `kind` / `imagePath` / `imageName`），失败
   是 `{"error":{"code":…,"message":…}}`。进度与警告一律走 stderr。
6. **退出码**：`0` 成功；`1` 命令失败（错误码见 stderr 或 JSON 的 `error.code`）；`64` 参数错误；
   `69` 没有 host 且拉不起来（或 `--no-spawn` 时没有 host）。
7. **协议版本不匹配时**：host 是独立进程就会被自动换掉（客户端先请它退出、等它真正退出，必要时
   `SIGTERM`，再拉起新的）；host 是 RuntimeViewer App 则报错，请更新 App 或工具。当前协议版本 2。
8. **注入记录不分 Debug / Release**。helper daemon 里的 XPC 端点注册表与
   `~/Library/Application Support/RuntimeViewer/injected-socket-endpoints.json` 都只有一份，任何配置的
   host 启动时都会重连里面记录的进程；`detach` 会从记录里删掉它。
9. **同一时刻只有一个进程做 Bonjour 客户端与注入者**：App 在跑就是 App，否则是独立 host。独立 host
   不广播自己、不共享引擎；只做客户端。

## CLI host 的生命周期

目录 `<Application Support>/RuntimeViewer[-Debug]/CommandLineHost/`（环境变量
`RUNTIME_VIEWER_CLI_HOST_DIRECTORY` 可改）里有：

| 文件 | 作用 |
|---|---|
| `host.sock` | 监听的 Unix domain socket，`0600` |
| `host.pid` | host 存活期间持有的独占 `flock`；第二个 host 拿不到就退出 |
| `host.lock` | 客户端发现没有 host 时先拿这把锁再拉起，保证并发的客户端只拉起一个 |
| `host.json` | `{processIdentifier, kind, version, protocolVersion, startedAt, socketPath}`；只有写过它的那个 host 会在退出时删它（沿用 0006 的守卫） |
| `host.log` | 客户端后台拉起的 host 的 stdout / stderr |

客户端的拉起序列：`connect` → 失败（`ENOENT` / `ECONNREFUSED`）→ 对 `host.lock` 取独占锁 → 再
`connect` 一次（别的客户端可能刚拉起）→ 仍失败才 `posix_spawn` 自己的可执行文件跑 `host run`
（新会话、stdio 重定向到 `host.log`、除三个标准描述符外全部 close-on-exec）→ 每 100 ms 试连，
最多 10 s → 释放锁。

`host stop` 和 App 接管走同一条路：host 不再接受新连接、删掉 socket 文件、等在途命令跑完、回
ack、退出。等待期间新命令得到 `hostBusy`。

## App 优先与接管

RuntimeViewer App 启动时（`CommandLineHostController.start()`，`applicationDidFinishLaunching` 里一行）
自己充当 host：

1. 连 `host.sock`。连不上就直接绑定。
2. 对方 `Welcome.hostKind == .standalone`：发 `shutdownHost(.applicationTakeover)`，等它排空在途命令并
   退出（最多 5 s；socket 消失且进程不在才算退出，超时按 `host.json` 里的 pid 发 `SIGTERM` 再等 2 s）。
   对方协议版本太旧而握手失败时，直接按 `host.json` 的 pid 发 `SIGTERM`。
3. 对方已经是 `.application`（另一个 App 实例）：本实例不充当 host，只记日志。
4. 用 App 自己的 `RuntimeEngineManager`（`.application` 配置）跑同一个 `CommandLineHostServer`，
   `kind: application`、不空闲退出；`--options app` 此时读 App 内存里的实时设置而不是文件。

App 退出（`applicationWillTerminate`）时同步删掉自己写的 `host.sock` 与 `host.json`；下一条命令再拉起
独立 host，已注入的进程由它经注册表重连。接管的几秒窗口里，客户端遇到掉线会按契约 4 重试一次只读命令。

`host status` 能看出谁在服务：`Kind: application` 或 `standalone`。

### 手动验证清单

自动化测试用进程内 host 与打桩的注入器覆盖了解析规则、attach 的记账与接管的握手；下面这些要在装了
helper daemon 的机器上手动跑：

1. App 未运行：`sources` 列出 `local`，装了 helper 且能找到 App 包时含 `catalyst`。
2. `attach <pid>`（例如 Finder）后 `interface NSObject --source pid:<pid> --image libobjc.A` 可用，
   `sources` 的本机分组里出现该进程；`detach <pid>` 后它消失。
3. 启动 App：几秒后 `host status` 的 `Kind` 变为 `application`，`sources` 能看到 App 里的引擎（含
   App 里 attach 的进程与 Bonjour 对端）；`host.log` 里旧 host 记录 `Shutdown requested (applicationTakeover)`。
4. 退出 App：下一条命令拉起独立 host，`pid:` 来源经重连仍可用。
5. 有 Simulator 时：`attach <模拟器进程 pid>` 输出 `engine:<id>`，`sources` 在设备分组里列出它。

## 已知的坑

- **socket 路径有 104 字节上限**（`sockaddr_un`）。默认目录在多数机器上 80 多字节；用户名很长时
  会报 `Socket path is longer than 103 bytes`，用 `RUNTIME_VIEWER_CLI_HOST_DIRECTORY` 指到短一点
  的目录（例如 `/tmp/rvcli`）。
- **`images` 不带 `--loaded` 会很长**（共享缓存里几千个镜像）。配 `--query` 用。
- **`specialize` 只支持叶子候选**。候选本身是泛型（`--list` 里标了 `generic`）时，命令行没法再
  给内层参数，请在 App 里做。
- **一次连接掉线只重试一次，且只重试只读命令**。`export`、`attach`、`detach` 不重试：前者已经在写
  文件，中者已经在注入，后者在换上来的 host 上可能还没重连到目标。
- **`sources --wait` 的提前返回条件是「3 s 没变」**。`--wait` 不超过 3 s 时会等满；一个对端刚被发现
  就返回的话，它的 `isConnected` 可能还是 `no`，再跑一次即可。
- **`detach` 一个 Bonjour 对端只是断开连接**，浏览器随后可能重新发现并重连；它的用途是 Simulator
  里注入的进程。
- **Debug 工具与 Release App 同时跑**：两者的 host 目录与 App 包各自成对、互不接管，但独立 host 会
  把正在跑的 Release App 当成一个 Bonjour 对端并镜像它的引擎（GUI 里第二个 RuntimeViewer 实例也是
  这样）。要避免就用 Release 构建的工具。
