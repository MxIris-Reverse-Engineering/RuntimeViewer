# Draft - 设备进程显示 app 图标

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-10-05
- **最后更新**: 2026-10-05
- **所属愿景**: 无
- **关联提案**: [`draft-jailbroken-ios-injection`](draft-jailbroken-ios-injection.md)（它把这件事明确列为「将来」）
- **实现分支 / PR**: `feature/jailbroken-ios-injection`

## 摘要

选中一台越狱 iOS 设备后打开 attach picker，每一行都没有图标——四百多个进程只有名字、pid
和路径，用户得靠认 `MobileSafari` 这样的可执行文件名来找目标。本提案让设备端读出目标进程
所属 app bundle 的图标 PNG，经一条新命令按 bundle 去重地传回宿主，填进 picker 已有的图标列，
并把同一张图接到注入成功后 Toolbar 那个引擎列表的行上。

这不是修 bug：三处留空都是
[`draft-jailbroken-ios-injection`](draft-jailbroken-ios-injection.md) 当初有意为之的，那份提案
第 608 行写着「将来若要显示 app 图标，走已有的『带 PNG 字节、由宿主解码』那条路」。本提案就是
兑现它。

## 现状

四处协同造成「没有图标」，缺一不可：

| 位置 | 现状 |
|------|------|
| `RuntimeProcess`（wire 类型） | 只有 pid / name / executablePath / uid / injectability，**没有图标相关字段** |
| `RuntimeDeviceProcessEnumerator` | 枚举时不碰 bundle |
| `RemoteProcessItemSource.swift:62` | `RunningProcess.init(remoteProcess:)` 不传 `icon`，注释写明「跨连接取不到图标」 |
| `AttachToProcessViewController.swift:69` | 远程分支 `allowsFields: [.name, .pid, .executablePath]`，**连图标那一列都没开** |

宿主侧的渲染能力是现成的：`RunningProcess` 已有 `icon: NSImage?`，public init 收它，
`ProcessField` 里有 `.icon`。本机分支用默认全字段，所以本机进程一直有图标——这正是两边观感
不同的原因。

## 方案

### 设备端怎么找到图标文件

新增 `RuntimeDeviceApplicationIconLocator`（`RuntimeViewerDeviceInjection`），沿用
`RuntimeDeviceProcessEnumerator` 已有的「故意写成跨平台，好让 Mac 上的测试覆盖它」的做法：

1. 从 `executablePath` 向上找**最近的 `.app` 目录**。`.appex` 扩展进程继续往上回溯到宿主 app。
   找不到 `.app` 的（绝大多数 daemon）直接判定无图标，零成本——这一步只是在字符串上往上走，不开文件。
2. 读该 bundle 的 `Info.plist`：先 `CFBundleIcons`，没有再 `CFBundleIcons~ipad`，取
   `CFBundlePrimaryIcon.CFBundleIconFiles` 里的基名。
3. 按 `@3x.png` → `@2x.png` → `.png` → `@2x~ipad.png` → `~ipad.png` 的顺序在 bundle 根找文件。
   声明了多个基名时**逐个试**，不是只试第一个。
4. 命中即把 **PNG bytes 原样返回**，不解码也不重新编码——文件本来就是 PNG，宿主要的也是 PNG。

**实现期发现的那个会让整条路线失效的点：iOS app 图标是 Xcode 压扁过的 CgBI PNG。**
实测本项目自己的 `.ipa`，两个图标文件的 8 字节 PNG 签名后面紧跟着一个 `CgBI` chunk —— 这是 Apple
私有的 PNG 变体（红蓝通道交换、预乘方式不同），**标准 PNG 解码器读不了**。如果 macOS 侧读不了它，
「原样回传」这条路就得改成设备端解码再重编码。实测结论是**能读，且颜色正确**：`NSImage(data:)`
给出 120×120，ImageIO 报 `public.png`，采样像素是蓝底（R12 G193 B252）配深色圆盘（R16 G51 B77），
通道若被交换会是橙色。这条测量是整个「原样回传」方案成立的前提，已写进代码里 `pngSignature` 的注释。

另外三条防护是实现时加的，提案初稿没有：**2 MB 单文件上限**、**PNG 签名校验**、**拒绝符号链接**
（读属性不跟随链接，所以链接会被识别出来而不是被跟过去）。前两条是因为字节要过网络、后一条是因为
路径由对端给，是 `.app` 边界之外的第二道口子。

**基名不是固定的 `AppIcon`，必须从 Info.plist 读。** Safari 是 `AppIconUpdated60x60`，设置是
`Settings60x60`。硬编码 `AppIcon` 会漏掉一大半系统 app。这条单独写出来，是因为它看起来像个
可以省掉的间接层。

实测（iOS 27 RuntimeRoot + 本项目自己的 `.ipa`）：

| 样本 | 结果 |
|------|------|
| iOS 27 系统 app 共 259 个 | 56 个声明了 `CFBundleIconFiles`，其余是 ViewService 之类，本就没有图标 |
| 这 56 个按上述规则解析 | **55 个命中**，只有 `GameCenterUIService.app` 落空（图标只在 `Assets.car` 里） |
| 本项目 `RuntimeViewerJailbroken.ipa` | 命中 `AppIcon60x60@2x.png` |

### 图标怎么过连接

`RuntimeProcess` 加一个字段，**不放图标字节**：

```swift
/// 这个进程所属的 app bundle，没有就是 nil（daemon 没有）。
/// 图标按这个路径单独取——见 applicationIcons 命令。
public let applicationBundlePath: String?
```

新增命令 `CommandNames.applicationIcons`，请求携带一组 bundle 路径，响应是
`[String: Data]`（bundle 路径 → PNG bytes）。同一个 app 的多个进程、以及回溯到同一宿主的多个
`.appex`，去重后只传一份。`RuntimeInjectionService` 相应新增一个有默认实现的方法，macOS 侧
不实现它。

**这条命令不能变成任意文件读取原语。** 它只接受以 `.app` 结尾的目录路径，而且只读该 bundle
的 `Info.plist` 所声明的图标文件名——调用方指定不了文件名，也读不到 bundle 以外的东西。请求
来自网络对端，这条边界是必须的。

### 宿主侧

`RemoteProcessItemSource.makeItemSource()` 改成两段：先 `processList()`，再对去重后的 bundle
路径取一次图标，解码成 `NSImage` 填进 `RunningProcess.icon`。
`AttachToProcessViewController` 的远程分支 `allowsFields` 加上 `.icon`。

取不到图标的行（daemon）用系统的通用可执行文件图标
`NSWorkspace.shared.icon(for: .unixExecutable)`，和本机 picker 的 `loadCachedIcon` 一致——
本机那条路从来不留空行，远端也不该。

**圆角遮罩在宿主侧做，设备端不动**（`ApplicationIconMask`，`RuntimeViewerUI`）。
bundle 里的图标文件是**方的、而且每一个像素都不透明**——实测一张 120×120 的,
14400/14400 不透明——设备上看到的圆角是系统**绘制时**套的遮罩，不在文件里。所以不套遮罩
就是一排方块贴在本机那些圆角图标旁边。

实现上走 `CALayer`（`contents` + `masksToBounds` + `cornerRadius`）而不是
`NSBezierPath(roundedRect:)`：iOS 的图标角是**连续曲率**而非圆弧，只有
`CALayerCornerCurve.continuous` 画得出来。这一点是实测的而非假定的——同一个 layer 两种
`cornerCurve` 渲染出来，120×120 里有 300 个像素的 alpha 不同，说明 `render(in:)` 认这个设置、
没有静默忽略。遮罩按 bundle 做一次（不是按行），且**只套在真的 app 图标上**——daemon 那个
通用图标是系统图标，有自己的形状，再切一刀就错了。

### 引擎列表（Toolbar 的 source 菜单）

picker 只是第一处。注入成功后那台设备在 Toolbar 的引擎菜单里再出现一次，而那里原先**三行全是
同一张图**——一张 LED Cinema Display。

三行本来就该是三样东西，规则按「这一行代表什么」定：

| 行 | 图标 |
|----|------|
| 设备上跑的 RuntimeViewer 自己（Bonjour 发现到的那个引擎）——它**代表这台设备** | 设备图标 |
| 注入进去的 app 进程 | 那个 app 自己的图标（已套圆角） |
| 注入进去的 daemon | 通用可执行文件图标 |

后两条不需要再取一次图标：**picker 刚刚为用户点的那一行取过、也套过圆角了**。所以
`AttachToProcessViewModel` 把选中行的 `icon` 一路带下去，在引擎报到之后交给
`RuntimeEngineIconProvider.record(_:for:)` 存住。daemon 那一行也存（存的是通用图标）——
「调用方没有图标」和「调用方知道它没有图标」是两回事，只有后者该拦住引擎列表回退到**设备**
的图标。两半竞速都可能赢（当前设备载荷是拨号回来的，模拟器载荷是自我广播的），所以图标记在
**真正报到的那个引擎**上，而不是监听时建的那个；`record` 的清理也因此要同时对着 attached 与
bonjour 两张表。

**图标是后到的，所以要有人通知界面重画。** 第一版漏了这一步，表现是「不点进去那一行就还是设备图标，
一点就变成 app 图标」——这正是它的指纹。时序：`launchInjectedDeviceEngine` 把引擎加进列表时管理器就
`rebuildSections()`，菜单在那一刻已经建好，而图标要等那个进程的引擎报到之后才记得下来；此后没有任何
东西再触发重建，直到用户点那一行让 `switchSourceState` 变化、`combineLatest` 重新发射为止。

provider 原有的两条路没有这个问题是**结构性**的：它们挂在管理器的 `willSet` 上，在列表发布之前就填好了。
注入到设备上的进程做不到，所以 `record(_:for:)` 多发一条 `recordedIconsChanged`，`MainViewModel` 把它与
管理器的 sections 合流后再往下发。**两个消费方都换成合流后的那条**——菜单的行，以及工具栏按钮自己那张图，
后者有同样的陈旧问题。

第一条是另一回事，而且根因和「iOS」无关：**那张 LED Cinema Display 是
`deviceIcon(forModelIdentifier:)` 的兜底**。macOS 通过 `com.apple.device-model-code` 把硬件型号码
解析成设备，真机是能解析的——实测 iPhone 的 `hw.model` 给的是**主板号**（`D74AP`）而不是
`iPhone15,3`，而 CoreTypes 两种写法都声明了。解析不了的是**虚拟机**：`VirtualMac2,1` 和它的 iOS
对应物都落到一个什么家族都不指的 dynamic UTType，于是兜底成了那台显示器。

**整套图标的画法也跟着换掉了，对齐 Xcode 27。** 用户指出我们原先的观感是 Xcode 26 的。实测确认：
Xcode 26 画的就是 CoreTypes 那套写实图标（所以它的列表里是一台黑边 iPad 配一台 2010 年的白 iPhone
——`com.apple.device-model-code` 解析出来就是这两张）；Xcode 27 改成了 **SF Symbol 的双色 palette
渲染**：机身用 label 颜色、屏幕用蓝色。把 `iphone.gen3`、`ipad`、`iphone.gen1` 这样渲染出来，和它
那三行逐一对得上，而且**一点 Xcode 的素材都不需要**。蓝色是字面的 `systemBlue` 而非强调色——
本机强调色是青色，而截图里的屏幕是 `#41A0F7`。

**配方不是猜的，是从 Xcode 里读出来的。** 前两版都是照着截图调，两次都明显不像；用户让停止猜测、
直接逆向。入口是 `IDEKit.RunDestinationIconProvider.icon(for:)`——运行目标那一列的图标就是它画的：
`NSImage(systemSymbolName:)` 加一个 symbol configuration，再包进 `DVTIcon`。配置来自
`symbolConfigurationIncludingEligibility(for:)`，**原样**是：

```swift
let paletteColors: [NSColor] = [
    .labelColor,
    NSColor.systemCyan.blended(withFraction: 0.13, of: .white)!,
    NSColor.systemBlue.blended(withFraction: 0.13, of: .white)!,
]
var configuration = NSImage.SymbolConfiguration(paletteColors: paletteColors)
if #available(macOS 26, *) {
    configuration = configuration.applying(.init(colorRenderingMode: .gradient))
}
```

三件按截图调不出来的事：

- **屏幕是在两个 palette 颜色之间渐变，不是在一个颜色里面渐变。** 所以两色 palette 怎么调都不对——
  这正是前两版的病根。
- **蓝色是字面的系统色，不是强调色**：本机强调色是青色，而 Xcode 的图标照样是蓝的。
- **`colorRenderingMode = .gradient` 是必须的**（macOS 26 起才有，更早的系统退回平涂而不是放弃颜色）；
  平涂肉眼就是另一张图。

另外两个分支也照搬了：设备不可达 / 未配对用 `hierarchicalColor: .secondaryLabelColor`，
模拟器（`device.reality == 2`）用 `hierarchicalColor: .labelColor`——单色、不亮屏，正是我们区分模拟器
的那条规则，Xcode 的做法与之一致。

**验收是逐字节的**：按这个配方渲染 `iphone.gen3`，机身像素 `#E0E0E1`，与 Xcode 截图上采到的值完全相同。

符号名那一半也查了：Xcode 走 IconServices 的私有 `ISSymbol(forTypeIdentifier:).name`。直接调它探了一轮，
返回的就是 `iphone.gen3` / `ipad` / `macstudio` / `appletv` 这些——**和 UIFoundation 公开的
`deviceSymbolName(forModelIdentifier:)` 那张表一模一样**，所以私有 API 没有额外价值，继续用公开的。
唯一分歧是 Xcode 把 Apple TV 特判成 `tv`，这条留着不动。

逆向材料按卷上的惯例落在 `/Volumes/RE/Xcode/27.0/`：新建了 `DeviceKit.i64`，并在那里的 `README.md`
里加了一节记下全部地址与结论。

于是 `DeviceGlyph`（`RuntimeViewerUI`）同时承担两件事：

- **选哪个符号**：型号优先（`deviceSymbolName(forModelIdentifier:)`，UIFoundation 里现成的有序表），
  型号认不出时按平台兜底。平台从哪来？**对端早就在报了**——`RuntimeDeviceMetadata.osVersion` 的格式
  是 `"iOS 26.5.0"` / `"macOS 27.0.0"`，Bonjour 的 TXT 记录里一直带着它。所以这件事**不需要设备端
  改一行**，连已经装在设备上的那个 build 都够用。
- **怎么画**：真机双色（机身 + 蓝屏），模拟器单色。两边都是符号之后，「模拟器 vs 真机」原来靠
  「符号 vs 写实图」的区分没了，改由「屏幕亮不亮」承担。没有屏幕图层的符号（`macstudio`、`macmini`）
  自动忽略第二个颜色，这是对的——那些机器本来就没有屏幕。

**返回的图是正方形的**，这不是洁癖：符号图本身不是正方形（`iphone.gen3` 是 14×16，`macstudio` 是
19×11），而引擎菜单把每一项的图钉成 20×20，直接交过去会被**拉伸**。模拟器那几行原本就在被拉
（14×16 拉成 20×20），顺手一起修了。图是用 drawing handler 画的而不是先栅格化，所以与分辨率无关；
**外观切换时重新解析的只有 `labelColor`** ——palette 里放的是它，浅色菜单里是黑、深色里是白，实测
同一张图两种画法。亮屏那两种颜色不在此列：它们是 systemCyan / systemBlue 与白色混出来的固定 RGB，
在建图那一刻就定死（见 2026-10-06 那条）。

只映射 iOS 一个平台，是算出来而不是偷懒：watchOS / tvOS / visionOS 的型号码全都是声明过的（实测
`Watch6,1`、`AppleTV11,1`、`RealityDevice14,1` 都解析得到），那几条分支永远不会被执行；macOS 更是
故意不映射——Mac 虚拟机的型号码同样未声明，而一台 Mac 正该用那张显示器兜底。代价是 iPadOS 也自报
`iOS`，所以型号未知的 iPad 会拿到 iPhone 的图；要触发它得是虚拟机或比当前 macOS 还新的硬件，
而且画错 iOS 设备也好过画一台台式显示器。

**本机那一行（「My Mac」）也一起换了。** 一行写实图配三行扁平图，比两种画法里的任何一种都差；
既然目标是对齐 Xcode 27，就整套换。要改回去是 `machineIcon(for:)` 里的一行。

### 新旧版本混用

两个方向都不能让 picker 失败：

- **老设备端 + 新宿主**：没有 `applicationIcons` 的 handler，dispatch 抛错。宿主把这个错当
  「这台设备没有图标」，列表照常显示。沿用 `injectionAvailability()` 已有的「老 peer 没
  handler ≡ 不支持」读法。
- **新宿主解码老设备端的 `RuntimeProcess`**：`applicationBundlePath` 是 Optional，合成的
  `Codable` 用 `decodeIfPresent`，缺 key 即 nil，不请求图标。

### 已知代价

`RunningItemSource.loadItems()` 是一次性快照，**库里没有「先出行、图标后到」的钩子**。所以这
两次往返是串联的，picker 首屏会比现在多等一个 RTT。接受它，换来的是列表请求保持便宜、图标
按 bundle 去重、以及这条命令将来能被引擎列表复用（见非目标）。

### 取的假设

- 一台越狱设备上有图标的进程是几十个量级，去重后几百 KB 的 PNG 走 `\nOK` 分帧的通道没有问题
  （通道本来就在传几 MB 的接口文本，没有帧长上限）。设备端**不做缩放**——120×120 的原始
  PNG 在 picker 的 50 点图标列里绰绰有余，缩放只会多花 CPU 和一次有损重编码。单文件 2 MB 上限
  把这条假设从「希望如此」变成「强制如此」。
- 去重的收益有实测旁证：本机 1244 个有可读路径的进程里 175 个在 `.app` 内，去重后 **114 个
  bundle**（1.5:1）。iOS 上的比例不同，但「多个进程共用一个 bundle」是常态而非边界情况。
- 不处理 alternate icon（`CFBundleAlternateIcons`）。picker 要的是「这是哪个 app」，主图标够了。

## 非目标

- **私有 API 取系统渲染好的圆角图标**。`LSApplicationProxy` / `MobileIcons` /
  `UIImage._applicationIconImageForBundleIdentifier:format:scale:` 这条路能拿到带圆角遮罩、
  尺寸统一、且能覆盖 `Assets.car`-only 那一个的图标，但要先在 iOS 26.5 的 dyld cache 导出里
  核实接口仍在、再在设备上实测 no-sandbox app 能否调用。本次先把零私有 API 的版本落地，这条
  列为后续提案。圆角本身已经有了（宿主侧自己套遮罩，见上），这条非目标现在只剩两件事：
  让**系统**来渲染，以及覆盖那个图标只在 `Assets.car` 里的 app。

## 落地的文件

| 文件 | 做什么 |
|------|--------|
| `RuntimeViewerDeviceInjection/RuntimeDeviceApplicationIconLocator.swift` | 新增。回溯 bundle、读 `Info.plist`、探文件、三道防护 |
| `RuntimeViewerDeviceInjection/RuntimeDeviceProcessEnumerator.swift` | 枚举时填 `applicationBundlePath` |
| `RuntimeViewerDeviceInjection/RuntimeDeviceInjectionService.swift` | 实现 `applicationIcons(forBundlesAtPaths:)` |
| `RuntimeViewerCore/Injection/RuntimeProcess.swift` | 加 `applicationBundlePath: String?` |
| `RuntimeViewerCore/Injection/RuntimeInjectionService.swift` | 加带默认实现的协议方法（macOS 不实现） |
| `RuntimeViewerCore/RuntimeEngine.swift` | 加 `CommandNames.applicationIcons` |
| `RuntimeViewerCore/RuntimeEngine+InjectionRequests.swift` | 加 `ApplicationIconsRequest` 与不抛错的 public caller |
| `RuntimeViewerCore/RuntimeEngineRequest.swift` | 登记 handler |
| `RuntimeViewerUsingAppKit/Attach Process/RemoteProcessItemSource.swift` | 两段式取图标、填 `RunningProcess.icon`、daemon 回退通用图标 |
| `RuntimeViewerUsingAppKit/Attach Process/AttachToProcessViewController.swift` | `allowsFields` 加 `.icon` |
| `RuntimeViewerUI/AppKit/ApplicationIconMask.swift` | 新增。把方形图标切成 iOS 的连续曲率圆角 |
| `RuntimeViewerUI/AppKit/DeviceGlyph.swift` | 新增。型号优先、平台兜底地选符号，按 Xcode 27 的双色 palette 画，并补成正方形 |
| `RuntimeViewerApplication/Engine/RuntimeEngineIconProvider.swift` | 加 `record(_:for:)` 与 `recordedIconsChanged`，以及对着两张引擎表的清理 |
| `RuntimeViewerUsingAppKit/Attach Process/AttachToProcessViewModel.swift` | 把选中行的图标带下去，记在报到的引擎上 |
| `RuntimeViewerUsingAppKit/Main/MainViewModel.swift` | 每一行机器的图标统一走 `DeviceGlyph`；sections 与 `recordedIconsChanged` 合流 |

## 测试

- **图标定位逻辑在 Mac 上用临时 bundle 测**（`RuntimeDeviceApplicationIconLocatorTests`，24 例）：
  基名不是 `AppIcon`（带一个 `AppIcon@2x.png` 诱饵，猜基名的实现会被它骗过去）、`@3x` 优先、
  四种后缀各自单独存在、声明了但文件不存在时落到下一个基名、没有 `CFBundleIcons`、没有
  `Info.plist`、`CFBundleIcons` 压过 `~ipad`、非 PNG 跳过、空文件跳过、超 2 MB 跳过、`.appex`
  回溯到宿主 app、路径不在任何 `.app` 里、只叫 `.app` 的隐藏目录不算 bundle。
- **安全边界单独测**：非 `.app` 路径（7 种）、含 `..` 的路径（**带对照断言**：同一个 bundle
  直接点名时是能返回图标的，所以拒掉的确实是 `..` 而不是 fixture 坏了）、声明的基名想走出
  bundle（6 种，并在 `../outside` 会落到的位置真的放一个合法 PNG，所以唯一拦住它的就是名字
  过滤）、图标名下埋符号链接。
- **枚举器的接线**（`RuntimeDeviceProcessEnumeratorBundlePathTests`，3 例）：拿活的进程表比对，
  凡是能回溯出 bundle 的进程都必须报出来。实测这台机器上有 **175 个样本**，不是空跑。
- **命令的 wire 格式**进 `InjectionCommandWireFormatTests`（新增 4 例）：命令名字符串、请求类型
  自报命令名、老 peer 的 `RuntimeProcess` 缺 key 时解码为 nil、`nil` 不编码成 null、
  `[String: Data]` 逐字节往返。
- **圆角遮罩**（`ApplicationIconMaskTests`，4 例，放在已链接 `RuntimeViewerUI` 的 `RuntimeViewerApplicationTests` 里，不用新开测试靶）：四个角透明且中心不透明、四条边中点仍不透明（遮罩退化成圆形会在这里挂而前面全过）、**确实切掉了东西**（`applied(to:)` 在任何处理不了的分支都原样返回，所以「有没有真的干活」必须断言而不能从「结果是张合法图」推出来）、非方形图原样返回、point size 不变（返回像素尺寸的话图标会在 22 点的列里画成五倍大）。
- **机器图标**（`DeviceGlyphTests`，9 例）：**结果是正方形**（菜单钉 20×20，不补正就会把
  19×11 的 `macstudio` 拉成方块）、声明过的型号压过平台、真机主板号自己就能解析（所以平台只是
  兜底）、未知型号 + iOS 画成和真 iPhone 一样的图、未知型号 + macOS 照旧报 miss（Mac 虚拟机行为
  不变）、未映射的平台不借用 iPhone 的图、**真机有亮屏而模拟器没有**（直接查像素里有没有蓝，
  因为 palette 颜色没生效正是值得抓的那种静默失败）、**屏幕是渐变而不是平涂**（取中线上下两点比，
  `colorRenderingMode` 是个可以被忽略的请求，忽略了画出来照样是张像样的图）、**机身是中性色不是着色的**
  （单看这条只证明「有一层是中性的」，和上一条配对才钉住顺序）。**红过四条**：去掉补正方形、把模拟器
  配置换成双色、把渐变退回平涂、把 palette 顺序对调，每次都有对应的例子如期失败（原始退出码 1）。
- **构建与测试状态**：Core 28 例、设备端 29 例全绿（看的是原始退出码）；
  `RuntimeViewerApplicationTests` 全绿（期间有一条与本次无关的红：
  `StatefulOutlineViewTrackingLoopTests` 的哨兵钉死了私有识别器的名字，而 macOS 27.2 把它改名拆二。
  那套件已按用户决定删除——它是「用私有 API 实现那个行为」那条路线的遗留，实际的修法是覆写
  `mouseDown`，与识别器名字无关。见该 ResolvedIssues 的追记）；macOS App 经
  `RuntimeViewer.xcworkspace` / `RuntimeViewer macOS` / Debug 编过，零错误。
- **「图标后到」这条没能配上单元测试，且是有意不配的**：坏的那一半在 App target 的 `MainViewModel`，
  包测试够不着；另一半 `RuntimeEngineIconProvider` 是 `private init` 的单例，测试里构造不出来，强行
  构造会连带起整个 `RuntimeEngineManager`（会去开 Bonjour 浏览）。为一条两行的接线改动把单例拆开，
  代价不对等。**改为靠设备实测，2026-10-05 用户已在真机上确认**：注入成功后不点那一行，引擎列表里
  显示的就已经是 app 自己的图标。
- **设备上的实测（2026-10-05，用户在真实越狱设备上）**：attach picker 里 app 进程显示图标、
  注入之后引擎列表里那一行**不用点就已经是 app 自己的图标**——两条都确认。仍未单独核对的是
  daemon 行的通用图标与 picker 首屏多那一个 RTT 的延迟观感，没有报告问题但也没有专门看过。
  宿主侧按菜单真实的 20 点尺寸渲染过 before/after 对照图确认过观感。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-05 | Created as Draft | 用户报告：iOS 越狱端的进程 picker 没有图标 |
| 2026-10-05 | 图标走**读 bundle 里的 PNG**，不用私有 API | 用户决策。零私有 API，逻辑能在 Mac 上用 fixture 测，实测 55/56 命中。代价是图标是方的；私有 API 那条（圆角、覆盖 `Assets.car`-only）列为后续提案 |
| 2026-10-05 | 图标走**独立命令按 bundle 去重**，不内联进 `RuntimeProcess` | 用户决策。同一个 app 的多个进程共用一份图标；`processList()` 保持便宜；这条命令将来能被引擎列表的图标复用。代价是 picker 首屏多一个 RTT——`loadItems()` 是一次性快照，库里没有「图标后到」的钩子 |
| 2026-10-05 | 「内联会让 CLI 白背字节」这条理由**不成立**，不写进动机 | 查证：`engine.processList()` 的唯一消费方就是 picker，`runtime-viewer-cli` 有自己的 `ProcessDirectory`。去重与复用是独立命令真正站得住的理由 |
| 2026-10-05 | 图标基名从 `Info.plist` 读，不硬编码 `AppIcon` | 实测 Safari 是 `AppIconUpdated60x60`、设置是 `Settings60x60`。硬编码会漏掉一大半系统 app |
| 2026-10-05 | 新命令只接受 `.app` 路径、只读 `Info.plist` 声明的图标文件名 | 请求来自网络对端，否则这就是一个任意文件读取原语 |
| 2026-10-05 | 设备端不缩放，PNG 原样传 | 文件本来就是 PNG，宿主要的也是 PNG；120×120 在 50 点的列里够用，缩放只是多一次有损重编码 |
| 2026-10-05 | 用户批准，状态置 Accepted，按上面的方案实现 | —— |
| 2026-10-05 | **确认 macOS 能解码 CgBI PNG，「原样回传」才站得住** | iOS app 图标是 Xcode 压扁过的 CgBI 变体（签名后紧跟 `CgBI` chunk，红蓝通道交换），标准解码器读不了。实测本项目 `.ipa`：`NSImage(data:)` 给 120×120、ImageIO 报 `public.png`、采样像素是蓝底深盘而非橙色，说明颜色也对。**若这条不成立，设备端就必须解码再重编码**，整个「不碰字节」的设计就没了。已写进 `pngSignature` 的注释 |
| 2026-10-05 | 基名的键序改成 `CFBundleIcons` 优先、`~ipad` 兜底（提案初稿写的是反的） | 55/56 那个测量本来就是读 `CFBundleIcons` 得出的，所以通用键单独就能覆盖全部 56 个；反过来优先 `~ipad` 会在 iPhone 上拿到 iPad 的图。`~ipad` 保留作只声明它的 iPad-only app 的兜底 |
| 2026-10-05 | 声明了多个基名时逐个试，不只试第一个 | 初稿的假设是「取哪个都一样」，逐个试是同一理由的稳健版本：多花一次 `stat`，换掉「第一个基名的文件恰好不在」这个真实情况 |
| 2026-10-05 | 加 2 MB 单文件上限、PNG 签名校验、拒绝符号链接 | 都因为路径来自网络对端。上限防「一个请求点名几十个 bundle、每个读进一大块内存再发走」；签名校验让非 PNG 就地跳过而不是走完全程到宿主才失败；符号链接是 `.app` 边界之外的第二个出口（读属性不跟随链接，所以能识别出来）。**当时只覆盖了叶子图标文件那一层，`.app` 目录本身漏了 —— 见 2026-10-06 那条** |
| 2026-10-05 | 圆角遮罩**在宿主侧做，设备端不动** | 用户看到实际效果后的决策（「太丑了」）。设备端不动有实在好处：传的还是文件原样的字节，设备不花 CPU、不做有损重编码，老设备端也照样能被新宿主画成圆角。实测前提：bundle 里的图标文件是方的且**每个像素都不透明**（120×120 的那张 14400/14400），圆角是系统绘制时套的遮罩，不在文件里 —— 所以这一步不是锦上添花，不做就是一排方块 |
| 2026-10-05 | 遮罩走 `CALayer` + `cornerCurve = .continuous`，不走 `NSBezierPath(roundedRect:)` | iOS 图标角是连续曲率，`NSBezierPath` 只画得出圆弧。实测 `render(in:)` 认 `cornerCurve`：同一个 layer 两种画法，120×120 里 300 个像素 alpha 不同 —— 不是假定它生效。顺带实测「图片作 `contents` + `masksToBounds`」这条路也认（同样 300 个像素），而不是只对 `backgroundColor` 生效 |
| 2026-10-05 | 引擎列表的图标**复用 picker 刚取过的那一张**，不再发一次请求 | 用户报告三行图标全一样。picker 为用户点的那一行已经取过、解码过、套过圆角，attach 流程是唯一同时知道「这个引擎 = 那台设备上的那个进程」的地方，所以由它把图推给 `RuntimeEngineIconProvider`，而不是让 provider 回头再问一次 |
| 2026-10-05 | daemon 的通用图标**也记下来**，不留空 | 「没有图标」和「知道它没有图标」是两回事。只有后者该拦住引擎列表回退到**设备**的图标——不记的话每个注入进去的 daemon 都会顶着一台手机的图 |
| 2026-10-05 | 真机验收通过：picker 与引擎列表的 app 图标都正确，后者不用点进去 | 用户确认。这条是「图标后到」那个修复唯一的验收手段——它没有单元测试，理由见上 |
| 2026-10-05 | 记图标时多发一条 `recordedIconsChanged`，菜单与工具栏按钮都跟着重画 | 用户报告「不点进去那一行还是设备图标」。根因是时序：引擎进列表时菜单就建好了，而图标要等它报到之后才有，此后没有东西再触发重建——点一下让 `switchSourceState` 变化恰好触发了，所以才像「点进去才显示」。provider 原有两条路挂在 `willSet` 上，天然赶得上，只有注入到设备的进程赶不上 |
| 2026-10-05 | 这条接线**不配单元测试**，记录理由而不是沉默跳过 | 坏的一半在 App target 够不着；另一半是 `private init` 单例，强行构造会拉起整个 `RuntimeEngineManager`（开 Bonjour 浏览）。为两行接线拆单例不划算，改为列进「需要设备实测」的清单 |
| 2026-10-05 | **停止照截图调色，改为逆向 Xcode 取原配方** | 用户第三次指出不像并直接要求「逆一下 Xcode，不要猜了」。两轮按观感调（平涂双色、再加渐变）都明显不对，根因是两色 palette 画不出它的屏幕——它在**两个** palette 颜色之间渐变。配方取自 `IDEKit.RunDestinationIconProvider.symbolConfigurationIncludingEligibility(for:)`：`[.labelColor, systemCyan·white(0.13), systemBlue·white(0.13)]` + `colorRenderingMode = .gradient`。验收是逐字节的：机身 `#E0E0E1` 与截图采样相同 |
| 2026-10-05 | 模拟器用 `hierarchicalColor: .labelColor`，不是单色 palette | 同一处逆向结果：Xcode 对 `device.reality == 2` 正是这么画的，和我们「模拟器不亮屏」的规则一致 |
| 2026-10-05 | 符号名继续用 UIFoundation 的公开表，不引入 `ISSymbol` | 探了 IconServices 私有的 `+[ISSymbol symbolForTypeIdentifier:error:]`，返回值与公开表逐项相同，私有 API 不带来任何东西 |
| 2026-10-05 | 整套机器图标改画成 **Xcode 27 的双色 SF Symbol**，不再用 CoreTypes 写实图 | 用户指出我们的观感还是 Xcode 26 的。实测确认 Xcode 26 画的就是 CoreTypes 那套，Xcode 27 换成了 SF Symbol + palette（机身 label 色、屏幕蓝）；把 `iphone.gen3` / `ipad` / `iphone.gen1` 这样渲染和它三行逐一对得上，且不需要 Xcode 的任何素材。蓝色取字面 `systemBlue` 而非强调色——本机强调色是青色而截图里是 `#41A0F7` |
| 2026-10-05 | 「模拟器 vs 真机」的区分改由**屏幕亮不亮**承担 | 原来的区分是「符号 vs 写实图」，两边都变成符号之后它就没了。单色＝不是真机，和 Xcode 的意思一致 |
| 2026-10-05 | `DeviceGlyph` 返回**正方形**图，补正放在这里而不是调用方 | 符号图不是正方形（`iphone.gen3` 14×16、`macstudio` 19×11），而菜单把每项钉成 20×20 —— 直接交过去会被拉伸。模拟器那几行原本就在被拉，顺手修掉 |
| 2026-10-05 | 本机「My Mac」那一行也一起换 | 一行写实配三行扁平比两种里的任何一种都差；改回去是一行 |
| 2026-10-05 | 设备行那张 LED Cinema Display 的根因是**虚拟机**，不是 iOS | 实测：iPhone 的 `hw.model` 是主板号 `D74AP`，CoreTypes 照样声明，所以**真机上这一行一直是对的**；解析不了的是 vphone 这类虚拟机的型号码。这改变了修法——不是「iOS 要特判」，而是「型号未知时按平台兜底」 |
| 2026-10-05 | 平台从 `osVersion` 读，**设备端不动** | `RuntimeDeviceMetadata.osVersion` 的格式本来就是 `"iOS 26.5.0"`，Bonjour TXT 一直在传。已经装在设备上的 build 就够用，不必为这件事重打一次 `.ipa` |
| 2026-10-05 | 只映射 iOS 一个平台 | watchOS / tvOS / visionOS 的型号码实测全都声明过，那几条分支不可能执行；macOS 故意不映射，因为 Mac 虚拟机正该用那张显示器兜底。代价：型号未知的 iPad 会拿到 iPhone 的图（iPadOS 自报 `iOS`），接受 |
| 2026-10-05 | 圆角半径取边长的 0.2237，定为具名常量 | iOS 图标遮罩一贯的比例。这是观感问题不是正确性问题，所以用本项目自己的图标按 picker 实际尺寸（22 点）渲染出来看过再定；要调是一处编辑 |
| 2026-10-06 | **PR #119 review：`.app` 本身是符号链接时会被放行**，决策日志里「拒绝符号链接」只做了一半 | 叶子图标文件那一半是对的（`attributesOfItem` 不跟随链接，已有测试钉住），但 `.app` 目录那一层漏了：三道校验全是对**字符串**的判断（绝对路径、无 `..`、以 `.app` 结尾），而内核解析路径时会跟随每一个目录分量，所以指向任意目录的 `Link.app` 能让 `Data(contentsOf:)` 读到任何 bundle 之外的 `Info.plist`，再读它声明的 PNG。路径来自对端，而设备侧的 Bonjour server 不鉴权，所以「以 `.app` 结尾」不是关于那个目录的证据。实际危害接近零 —— 链接得事先布在设备上，而同一条连接本来就提供任意路径的 `loadImage`（基线既有）—— 但模块注释自称「confined to application bundles」「not an arbitrary file read primitive」，比实现强。修法是对末段 lstat、要求是目录，三行；注释与本提案这条措辞一并改准 |
| 2026-10-06 | 范围外记录：`DeviceGlyph` 的屏幕色在构建时被冻结，切换浅/深色后不更新（PR #119 review `PR119.12`，判为待办不修） | `physicalConfiguration` 把 systemCyan / systemBlue 与白色混色，得到的是固定 RGB，只有 `labelColor` 会在绘制时重新解析 —— 所以浅色下建好的图在系统切到深色后仍是浅色时的亮屏颜色，直到引擎列表下次变化才重建。本提案第 212 行「会在外观切换时重新解析颜色」因此只对 `labelColor` 成立。review 另称「每次调用重建是浪费」，不成立：每次发射只为几行机器各建一张图。要修就把两种屏幕色换成 `NSColor(name:dynamicProvider:)`、配置改 static；纯观感，故留待办 |
