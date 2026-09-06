# 使用指南：`runtime-viewer-cli`

- **面向**: 在终端或脚本里查本机运行时的人；把 RuntimeViewer 接进 agent 工作流的人
- **对应提案**: [draft-command-line-interface-foundation](../Evolutions/draft-command-line-interface-foundation.md)
- **最后更新**: 2026-09-06

不打开 RuntimeViewer 的窗口，用一条命令拿到某个类型的接口、某个镜像的类型清单，或把整个镜像
的接口导出到目录。当前版本只接**本机进程内引擎**（`--source local`，默认值）；attach 进程、
Catalyst、Bonjour 对端由后续提案接入，`--source` 的其它取值今天一律回答 `sourceUnavailable`。

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
| `host [status]` / `host stop` / `host restart` / `host run` | 查看、停止、重启 CLI host；`run` 在当前进程里前台运行一个 host |

### 类型与镜像怎么解析

- **`--image`** 接受绝对路径或短名。短名按这个顺序找：已加载的镜像 → host 进程已映射的镜像 →
  系统目录（共享缓存与框架目录）→ 当作字面路径。每一步都先按去掉扩展名的文件名精确匹配（不分
  大小写），再退回到文件名包含该子串。所以 `--image AppKit` 在全新的 host 上也能用，`--image
  objc` 会命中 `libobjc.A.dylib`。
- **不给 `--image`** 就在已加载的镜像里找；一个也没加载时报 `imageNotFound`，提示先 `load`。
- **类型名**先精确匹配内部名 `name`，再精确匹配 `displayName`，最后不分大小写匹配两者；会深入
  已有的特化子节点。

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
7. **协议版本不匹配时**：host 是独立进程就会被自动换掉（客户端先请它退出，再拉起新的）；host 是
   RuntimeViewer App（后续提案）则报错，请更新 App 或工具。

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

`host stop` 和 App 接管（后续提案）走同一条路：host 不再接受新连接、删掉 socket 文件、等在途命令
跑完、回 ack、退出。等待期间新命令得到 `hostBusy`。

## 已知的坑

- **socket 路径有 104 字节上限**（`sockaddr_un`）。默认目录在多数机器上 80 多字节；用户名很长时
  会报 `Socket path is longer than 103 bytes`，用 `RUNTIME_VIEWER_CLI_HOST_DIRECTORY` 指到短一点
  的目录（例如 `/tmp/rvcli`）。
- **`images` 不带 `--loaded` 会很长**（共享缓存里几千个镜像）。配 `--query` 用。
- **`specialize` 只支持叶子候选**。候选本身是泛型（`--list` 里标了 `generic`）时，命令行没法再
  给内层参数，请在 App 里做。
- **一次连接掉线只重试一次，且只重试只读命令**。`export` 不重试，因为它已经在写文件。
