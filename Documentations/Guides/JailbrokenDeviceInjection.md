# 注入越狱 iOS 设备上的进程

把 RuntimeViewer 接到一台越狱 iOS 设备上的某个进程：选设备 → 选进程 → Attach，之后像浏览本机运行时
一样浏览它。本篇讲前提、能注什么、以及失败时怎么读。

实现侧的「为什么是这个形状」见 [`DevicePayloadReverseConnection.md`](../DevicePayloadReverseConnection.md)。

## 前提

1. **设备上装着越狱版 RV iOS**，且安装方式授予了这五条 entitlement：

   | entitlement | 没有它会怎样 |
   |---|---|
   | `com.apple.private.security.no-sandbox` | 连进程都列不出来 |
   | `com.apple.private.security.no-container` | 同上 |
   | `task_for_pid-allow` | 能列、但注不进去 |
   | `com.apple.multitasking.unlimitedassertions` | daemon 照常；**App 注不进去**，且越狱版切出前台就不再应答 |
   | `com.apple.runningboard.process-state` | 功能都在，只是目标仍被挂起时报得没那么准 |

   走 Xcode 正常 Run 装进去的版本**一条都没有**。前三条缺任意一条，功能整体不可用；
   后两条缺了是降级，不是报废 —— 仍然能注 daemon，因为系统本来就不挂起 daemon。

2. **设备和 Mac 在同一个二层链路上**，且**设备能主动连到 Mac**。

### 网络：方向是「设备连 Mac」，不是反过来

注入的载荷跑在目标进程里，而目标进程的沙盒通常禁止它监听。所以**载荷主动连回 Mac**。这决定了几件事：

- **macOS 防火墙若阻止传入连接，整个功能不可用。** 设备连不进来。
- **虚拟机的网络模式必须允许入向。** vphone 的 `tunnel` 是「仅出向」（文档原话：Nothing on the Mac or
  the LAN can connect to a port in the guest through this network），**该模式下不可用**；用 `nat` 或
  `bridged`。真机经 Wi-Fi 不受此限。
- 地址每次都从到设备的那条活连接现读，所以**换网络、重启虚拟机都不用做任何配置** —— 包括链路上没有
  DHCP、两端各自用 `169.254.x.x` 的情况（实测可用）。

### 越狱版不需要停在设备屏幕上

iOS 在 App 离开前台后**一秒内**把它挂起（实测：`running-suspended`，jetsam 优先级降到 0），
而被挂起的进程没有被调度的线程，什么请求都处理不了。越狱版启动时就对自己取一条 RunningBoard
assertion 来免掉这件事，所以**从 Mac 点 Attach 之前不必先去设备上把它切回前台**。

没有开关，也不耗什么 —— 它是个调试工具，不是要长住在手机上的 App。

**失败是降级，不是报废。** 拿不到 assertion 时行为退回到以前：越狱版切出前台就不再应答，
得先在设备上把它切回来。这只会写进日志，不会弹窗。

**已经注入好的目标本来就不受影响**：载荷活在目标进程里，不随越狱版一起挂起。

## 能注什么

| 目标 | 能否 | 说明 |
|---|---|---|
| **非 root 的 daemon** | ✅ | 主要用法。`searchpartyd`、`mediaplaybackd`、`dasd`、`chronod`、`sharingd` 等均已实测 |
| **启动过、现在挂在后台的 App** | ✅ | 注入前先把它从挂起态唤醒，注入后一直保持到你 Detach |
| **从没启动过的 App** | ❌ | 需要先在后台把它拉起来，那要另一条 entitlement 和一份「装着的 App」列表，是另一件事 |
| **uid 0 的进程** | ❌ | 拿不到 root 进程的 task port，需要 root 身份的注入方 |
| **`backboardd`** | ❌ | 已知不支持，根因未查明；**和挂起无关**，它是 daemon，从来不会被挂起 |
| **`launchd`、`kernel_task`** | ❌ | 列出但不可选 |

进程列表来自**设备**，可注入性也由**设备**判定 —— 宿主不猜。注意列表里的「可注入」是**预筛**：
它只排除确定会失败的，剩下的以实际尝试为准。

**被注入的 App 会一直在后台运行**，直到你 Detach 或它自己退出 —— 这是它能持续应答的前提。

## 失败时怎么读

错误文案是按原因分开写的，先照字面读，它们说的是实话。

**「Could not work out an address … could reach this Mac on, because …」**
连设备的那条连接报不出本机地址。`because` 后面会说是哪种：连接刚断、还没有网络路径、或者它运行在一个
没有可用 IPv4 的接口上。这是**注入之前**就拒绝的，不会留下半成品。

**「Timed out waiting for X (pid N) to report back after injection.」**
载荷装进去了，但没连回来。先查这几条：设备和 Mac 是否同网、macOS 防火墙、虚拟机网络模式是否允许入向。

**「This build is not allowed to stop the target being suspended…」**
缺 `com.apple.runningboard.process-state`。装一个授予它的版本。daemon 不受影响 —— 系统不挂起它们。

**「Could not reach the system service that decides whether a process may run…」**
**这条不是权限问题，重装没用。** 它说的是这台设备上的接口不是本构建量过的那个。本功能的全部判据读自
iOS 26.3.1 的共享缓存，所以换个 iOS 版本就可能撞上。

**「The thread that loads the payload never reported what happened…」**
注入器等不到目标的回报。注入前已经确认过目标在运行、并且会一直保持，所以**挂起已经被排除**，剩两种：
载荷自己没起来（去设备日志里找它的启动行），或者目标在不报错的情况下拒绝加载它（`backboardd` 就是
这种）。最可靠的判据是目标进程的驻留内存，见下。

**「That device would not give Runtime Viewer control of the process」**
拿不到 task port：通常是目标是 root 进程，或越狱版缺 `task_for_pid-allow`。

### 自己动手量一条

最可靠的单一指标是**目标进程的驻留内存**：载荷加载并运行后实测增加 15–25 MB，没跑是 ±2 MB 的正常波动。
比读日志快，也比读日志准。
