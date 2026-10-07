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
| **挂起（suspended）** | iOS 进程被停到没有任何线程被调度的状态，App 离开前台后一秒内就会进入。**不是「慢」，是「完全不执行」** —— 注进去的代码不会跑，等它回报的一方等多久都等不到。系统里的判据就是 `RBProcessState.preventSuspend` 这一个布尔值 | [`DevicePayloadReverseConnection.md`](DevicePayloadReverseConnection.md) 第八节、[draft-device-process-assertions](Evolutions/draft-device-process-assertions.md) |
| **assertion（RunningBoard assertion）** | 向 iOS 的进程生命周期管家 `runningboardd` 声明「这个进程要保持某种状态」的一张凭据。本项目只用一种：带 `RBSLegacyAttribute`（`reason 10004` = `FinishTaskUnbounded` / `flags 1`）的那种，效果是目标不被挂起。**凭据的寿命就是承诺的寿命** —— 持有它的对象一消失，RunningBoard 就收回。目标可以是别的进程，这正是「注入 App 不需要先保活自己」的原因 | 同上 |
| **受限 entitlement（restricted entitlement）** | iOS 上一类 entitlement：消费它的守护进程另带一份按 bundle id 的白名单，不在名单里的进程在**读取阶段**就被剥掉这一条，签名里有也没用。`com.apple.runningboard.primitiveattribute` 就是其中之一，名单在 `/System/Library/RunningBoard/runningboardEntitlementsConfiguration.plist`。判断一条私有 entitlement 可不可用，必须跟到消费方构造权限集合那一步，只看检查点会得出相反结论 | 同上 |
| **保活（keeping awake）** | 本项目里专指「持有 assertion 让某个进程不被挂起」，有两处用法：越狱版对自己（所以切出前台仍能应答），以及对注入目标（所以注得进去、也连得住）。**不是**后台任务、静音音频那类「假保活」 | 同上 |
| **镜像引擎（mirrored engine）** | 经 Bonjour 对端转发过来的第三方引擎，在对端的引擎列表里出现、由本机的 proxy 层代理 | [`EngineMirroringWalkthrough.md`](EngineMirroringWalkthrough.md) |
| **合成扩展（synthetic extension）** | MachOSwiftSection 索引器为「父级不是本镜像里的类型」的嵌套类型生成的 `ExtensionDefinition`：父级是扩展上下文、是别的镜像的类型、或只能经符号找到时，把类型包进 `.types`，按被扩展类型的键存进 `typeExtensionDefinitions`。源码里并没有这样一个扩展块，它只是给无处安放的嵌套类型找个落脚处 | [`SwiftObjectTreeWalkthrough.md`](SwiftObjectTreeWalkthrough.md) |
| **并入（folded extension）** | `RuntimeSwiftSection.allObjects()` 对「键对应的类型 / 协议就在本镜像里」的扩展与协议遵循的处理：不在侧栏单独列一条，内容拼进那个类型 / 协议节点的 interface，扩展里声明的类型挂成它的子节点。与「单独列出的扩展节点」相对 | [`SwiftObjectTreeWalkthrough.md`](SwiftObjectTreeWalkthrough.md) |
| **命令扩展（command extension）** | 一组由 `RuntimeViewerCore` 之外的模块声明、在运行时装进引擎命令表的 RPC 命令。那个模块自己 `extension RuntimeEngine.CommandName` 声明短名（命名空间前缀不变 —— 它是线上契约），把遵循 `RuntimeEngineCommand` 的命令类型归在自己的命名空间下，再用 `RuntimeEngine.addCommandExtension(named:install:)` 登记；Core 一行不改。代价是**每个 serve 引擎的进程都要在入口显式调一次那个模块的 install**，漏调没有编译错误。`RuntimeViewerInjection` 是第一个，也是范式 | [draft-open-command-registry-and-injection-module](Evolutions/draft-open-command-registry-and-injection-module.md) |
| **内置命令（built-in command）** | 与命令扩展相对：`RuntimeViewerCore` 自己的那三十来条命令，清单在 `RuntimeEngine.registerBuiltInHandlers(into:)`，每条连接上**先**装它们。因此先到先得的重名拒绝意味着外部模块抢不走 Core 的命令名 | 同上 |
