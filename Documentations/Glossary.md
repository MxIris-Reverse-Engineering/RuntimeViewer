# RuntimeViewer 术语表

收录本项目自造的名字、内部代号、带项目特定含义的通用词，以及容易混淆的近义词对。通用的
Swift / Apple 框架词汇不收。跨项目通用的术语见全局术语表。

| 术语 | 含义 | 出处 |
|---|---|---|
| **CLI host** | 承载 `runtime-viewer-cli` 的常驻进程：持有运行时引擎与索引，客户端每条命令都是短命的薄进程。App 不在跑时由第一条命令在后台拉起，空闲到期自动退出；App 在跑时由 App 充当（见 host takeover）。用户口中的「Helper」，愿景改称此名以区别于特权 helper daemon 与 Catalyst helper | [愿景《无头 RuntimeViewer》](Visions/HeadlessRuntimeViewer.md)、[draft-command-line-interface-foundation](Evolutions/draft-command-line-interface-foundation.md) |
| **source selector** | `--source` 的取值，指明命令跑在哪个运行时来源上：`local`、`catalyst`、`pid:<n>`、`process:<名>`、`engine:<id>`。全集在基础提案里一次定死，多来源提案起全部可用；`sources` 命令为每个来源给出可回填的 selector | [draft-command-line-interface-foundation](Evolutions/draft-command-line-interface-foundation.md)、[draft-command-line-interface-multi-source](Evolutions/draft-command-line-interface-multi-source.md) |
| **host takeover（App 优先）** | RuntimeViewer App 启动时接管 CLI host 的角色：先请正在跑的独立 host 排空退出（`shutdownHost(.applicationTakeover)`，超时则 `SIGTERM`），再自己绑定同一个 socket（`host.json` 的 `kind` 为 `application`）。同一时刻只有一个进程做 Bonjour 客户端与注入者；App 退出后下一条命令再拉起独立 host。代码在 `HostTakeover` 与 App 的 `CommandLineHostController` | [draft-command-line-interface-multi-source](Evolutions/draft-command-line-interface-multi-source.md) |
| **helper daemon** | 经 `SMAppService` 安装的特权 daemon（`com.JH.RuntimeViewerService`），负责注入与列进程；与 CLI host 无关 | `AGENTS.md`「Helper Service」 |
| **Catalyst helper** | 嵌在 App 包 `Contents/Applications/` 里的 Mac Catalyst 应用，提供 Catalyst 运行时引擎；与 CLI host 无关 | `AGENTS.md`「Embedded iOS-family products」 |
| **镜像引擎（mirrored engine）** | 经 Bonjour 对端转发过来的第三方引擎，在对端的引擎列表里出现、由本机的 proxy 层代理 | [`EngineMirroringWalkthrough.md`](EngineMirroringWalkthrough.md) |
