# 注入越狱 iOS 设备上的进程

把 RuntimeViewer 接到一台越狱 iOS 设备上的某个进程：选设备 → 选进程 → Attach，之后像浏览本机运行时
一样浏览它。本篇讲前提、能注什么、以及失败时怎么读。

实现侧的「为什么是这个形状」见 [`DevicePayloadReverseConnection.md`](../DevicePayloadReverseConnection.md)。

## 前提

1. **设备上装着越狱版 RV iOS**，且安装方式授予了这三条 entitlement：
   `com.apple.private.security.no-sandbox`、`com.apple.private.security.no-container`、
   `task_for_pid-allow`。走 Xcode 正常 Run 装进去的版本**注入不了** —— 它没有这三条。
2. **设备和 Mac 在同一个二层链路上**，且**设备能主动连到 Mac**。
3. **越狱版必须是设备屏幕上正在显示的那个 App**（见下）。

### 网络：方向是「设备连 Mac」，不是反过来

注入的载荷跑在目标进程里，而目标进程的沙盒通常禁止它监听。所以**载荷主动连回 Mac**。这决定了几件事：

- **macOS 防火墙若阻止传入连接，整个功能不可用。** 设备连不进来。
- **虚拟机的网络模式必须允许入向。** vphone 的 `tunnel` 是「仅出向」（文档原话：Nothing on the Mac or
  the LAN can connect to a port in the guest through this network），**该模式下不可用**；用 `nat` 或
  `bridged`。真机经 Wi-Fi 不受此限。
- 地址每次都从到设备的那条活连接现读，所以**换网络、重启虚拟机都不用做任何配置** —— 包括链路上没有
  DHCP、两端各自用 `169.254.x.x` 的情况（实测可用）。

### 越狱版必须在设备屏幕上

iOS 在 App 离开前台后**一秒内**把它挂起（实测：`running-suspended`，jetsam 优先级降到 0）。
注入由越狱版自己执行，被挂起就没人处理请求。

判据是**设备屏幕上是哪个 App**，不是 macOS 的窗口焦点 —— guest 不知道你的鼠标在哪，所以在 Mac 上点
Attach 本身不会让它挂起，只有在设备里切走才会。

**已经注入好的目标不受影响**：载荷活在目标进程里，不随越狱版一起挂起。越狱版切回前台后，它自己那条
引擎会自动回来，不需要重新注入。

## 能注什么

| 目标 | 能否 | 说明 |
|---|---|---|
| **非 root 的 daemon** | ✅ | 主要用法。`searchpartyd`、`mediaplaybackd`、`dasd`、`chronod`、`sharingd` 等均已实测 |
| **其它 App** | ❌ | iOS 只给一个 App 前台，越狱版在跑就意味着目标 App 被挂起，注不进去 |
| **uid 0 的进程** | ❌ | 拿不到 root 进程的 task port，需要 root 身份的注入方 |
| **`backboardd`** | ❌ | 已知不支持，根因未查明 |
| **`launchd`、`kernel_task`** | ❌ | 列出但不可选 |

进程列表来自**设备**，可注入性也由**设备**判定 —— 宿主不猜。

## 失败时怎么读

错误文案是按原因分开写的，先照字面读，它们说的是实话。

**「Could not work out an address … could reach this Mac on, because …」**
连设备的那条连接报不出本机地址。`because` 后面会说是哪种：连接刚断、还没有网络路径、或者它运行在一个
没有可用 IPv4 的接口上。这是**注入之前**就拒绝的，不会留下半成品。

**「Timed out waiting for X (pid N) to report back after injection.」**
载荷装进去了，但没连回来。先查这几条：设备和 Mac 是否同网、macOS 防火墙、虚拟机网络模式是否允许入向。

**「The thread that loads the payload never reported what happened…」**
注入器等不到目标的回报。**十有八九是目标没在运行** —— 挂起的进程没有被调度的线程，等多久都没用。
如果目标是 daemon（不会被这样挂起），那指向载荷自己，去设备日志里看它的启动行。

**「That device would not give Runtime Viewer control of the process」**
拿不到 task port：通常是目标是 root 进程，或越狱版缺 `task_for_pid-allow`。

### 自己动手量一条

最可靠的单一指标是**目标进程的驻留内存**：载荷加载并运行后实测增加 15–25 MB，没跑是 ±2 MB 的正常波动。
比读日志快，也比读日志准。
