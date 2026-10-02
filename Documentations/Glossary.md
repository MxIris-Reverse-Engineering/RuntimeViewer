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
| **本地运行时 service（local-runtime service）** | 随 App 打包在 `Contents/XPCServices/` 里的普通 XPC service `RuntimeViewerLocalRuntimeService.xpc`，「My Mac」引擎真正 `dlopen` 与索引镜像的进程。不经 Mach service，不经 helper daemon，launchd 在 App 自己的 bundle 里按需拉起；崩了只丢已加载的镜像，App 不受影响 | [draft-local-runtime-xpc-service](Evolutions/draft-local-runtime-xpc-service.md) |
| **rendezvous（报到信息）** | 注入方交给载荷的一切：宿主的可达地址、端口，以及这次注入的认领令牌。以 `rendezvous.json` 写在暂存目录里载荷旁边，载荷启动时读。存在的理由是消除「载荷在别人的进程里推导自己是谁、该连到哪」这一整类问题 —— 两者在目标进程里都答不可靠。为 nil 表示「自己广播」，那是模拟器走的路 | [`DevicePayloadReverseConnection.md`](DevicePayloadReverseConnection.md)、[draft-device-payload-reverse-connection](Evolutions/draft-device-payload-reverse-connection.md) |
| **认领令牌（claim token）** | rendezvous 里的一次性标识，载荷连上时原样呈上，宿主只认自己发出去的那一个。**它只做区分，不做认证** —— 和载荷同在一个世界可读的目录里，谁能读到它也就能加载旁边那个载荷。一次注入一个，所以两次并发注入不会把先到的交给错误的请求 | 同上 |
| **反向连接（reverse connection）** | 真机上载荷不监听、改为主动连回宿主的那条路径。叫「反向」是相对 Bonjour 而言：那条是设备广播、宿主连进去 | 同上 |
| **镜像引擎（mirrored engine）** | 经 Bonjour 对端转发过来的第三方引擎，在对端的引擎列表里出现、由本机的 proxy 层代理 | [`EngineMirroringWalkthrough.md`](EngineMirroringWalkthrough.md) |
| **合成扩展（synthetic extension）** | MachOSwiftSection 索引器为「父级不是本镜像里的类型」的嵌套类型生成的 `ExtensionDefinition`：父级是扩展上下文、是别的镜像的类型、或只能经符号找到时，把类型包进 `.types`，按被扩展类型的键存进 `typeExtensionDefinitions`。源码里并没有这样一个扩展块，它只是给无处安放的嵌套类型找个落脚处 | [`SwiftObjectTreeWalkthrough.md`](SwiftObjectTreeWalkthrough.md) |
| **并入（folded extension）** | `RuntimeSwiftSection.allObjects()` 对「键对应的类型 / 协议就在本镜像里」的扩展与协议遵循的处理：不在侧栏单独列一条，内容拼进那个类型 / 协议节点的 interface，扩展里声明的类型挂成它的子节点。与「单独列出的扩展节点」相对 | [`SwiftObjectTreeWalkthrough.md`](SwiftObjectTreeWalkthrough.md) |
