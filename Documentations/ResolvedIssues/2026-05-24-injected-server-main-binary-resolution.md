# 2026-05-24 注入场景下目标进程主二进制解析错误

**调查日期：** 2026-05-24
**修复落地：** 本日,见 `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift:109-152`
**Severity：** Major —— 代码注入下"打开主二进制"功能完全失效,等同于核心场景之一断掉
**触发场景：** 现场反馈 —— "代码注入到目标进程后,打开目标 App 的主二进制,看到的内容是 RuntimeViewer 自己 App 的主二进制内容;Framework 是正常的;XPC / Socket 连接都有这个现象"

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 注入后请求 target 主二进制 → server 返回 `RuntimeViewerServer.framework` 自己,而不是 target 主二进制 |
| **影响范围** | 仅 "主二进制" 这一条路径;其他动态库 / Framework 不受影响 |
| **与连接类型无关** | XPC、Socket 走同一条 `machOImage(forPath:)` 路径 |
| **Status** | **Fixed** —— 改 `machOImage(forPath:)` 为"dyld 完整路径精确匹配优先" |

---

## 现象

`RuntimeViewerServer.framework` 被 `MachInjector` 注入到 target 进程,通过 XPC / TCP 与 host (RuntimeViewer) 通信。host 端在 sidebar 点击 target 主二进制节点时,server 应当返回 target 主二进制的 ObjC / Swift 解析结果,但实际返回的是 `RuntimeViewerServer.framework` 自己的内容(里面静态链接了大量 `RuntimeViewerCore` / `RuntimeViewerApplication` 等 host 端模块,所以看上去像 "RuntimeViewer App 主二进制")。

打开 target 的其他 Framework / dylib —— 例如 target 自己 bundle 里的 embed framework、系统库 —— 内容是对的。

---

## 根因

修复前的代码:

```swift
// RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift
package static func machOImage(forPath path: String) -> MachOImage? {
    if path == mainExecutablePath() {
        return MachOImage.current()              // ← 注入场景下错
    }
    let imageName = path.lastPathComponent.deletingPathExtension.deletingPathExtension
    return MachOImage(name: imageName)
}
```

`MachOImage.current(_ dso:)` 默认参数是 `#dsohandle`,Swift 编译器把它替换为**当前编译单元所属 Mach-O image 的 header 指针**:

```swift
// MachOKit
public static func current(_ dso: UnsafeRawPointer = #dsohandle) -> MachOImage {
    .init(ptr: dso.assumingMemoryBound(to: mach_header.self))
}
```

`DyldUtilities` 编进 `RuntimeViewerCore` 模块,`RuntimeViewerCore` 又被 `RuntimeViewerServer.framework` 静态链接,所以 `#dsohandle` 落点取决于**最终承载这段代码的二进制**:

| 调用方 | `#dsohandle` 落点 | `.current()` 返回 |
|---|---|---|
| Host App (Release) | host 主二进制 | host 主二进制 ✓ |
| Host App (Debug, Xcode `.debug.dylib` 拆分) | `<App>.debug.dylib` | `.debug.dylib`(实际承载代码) ✓ |
| **注入后的 server (target 进程内)** | `RuntimeViewerServer.framework` | **`RuntimeViewerServer.framework`** ✗ |

注入场景下走错分支的链路:

1. host 通过 `MachInjector.inject(pid:dylibPath:)` 把 `RuntimeViewerServer.framework` 加载进 target 进程(`/Library/Frameworks/RuntimeViewerServer.framework`)。
2. server 在 target 进程内启动 XPC / TCP listener,接收 host 请求。
3. host 请求 `mainExecutablePath`,server 用 `_NSGetExecutablePath()` 返回的**确实是 target 主二进制路径**(`_NSGetExecutablePath` 由 dyld 实现,对所在进程报告 LC_MAIN 那个 image)。
4. host 拿着 target 主二进制路径请求解析,server 调 `machOImage(forPath: path)`。
5. `path == mainExecutablePath()` 命中 → 走 `MachOImage.current()`。
6. `#dsohandle` 在 `RuntimeViewerServer.framework` 里 → 返回 server framework 自己。
7. host 收到 server framework 的 ObjC / Swift 解析结果,展示给用户 → 用户看到 "RuntimeViewer 自己的内容"。

其他 Framework 走 `MachOImage(name:)` (basename 匹配 dyld 已加载 image),`_dyld_get_image_name/_header` 在注入场景下正确报告 target 进程的全部已加载镜像,所以那条路径没问题。

---

## 为什么旧代码要用 `.current()`

源码注释清楚说明了 `.current()` 是为绕过 host 进程 Debug 模式下 Xcode `.debug.dylib` stub 拆分:

> In Debug builds Xcode emits the product as a thin stub at `Contents/MacOS/<Name>` plus a sibling `<Name>.debug.dylib` that holds the real code; `MachOImage(name:)` strips both extensions and matches by basename, so it picks the stub (loaded first at dyld index 0) and the caller never sees the actual dependency graph or sections.

—— 是合理的 host 本地优化,只是**当时没有考虑代码会被注入到外部进程**。`#dsohandle` 在注入场景下指向 server framework,不再代表 "主二进制"。

---

## 修复方案 (已采用,方案 A)

改 `machOImage(forPath:)` 为三级 fallback,优先用 dyld 自己的 image 注册表精确匹配:

```swift
package static func machOImage(forPath path: String) -> MachOImage? {
    // 1) dyld 完整路径精确匹配 —— 注入场景下直接命中 target 主二进制
    for index in 0..<_dyld_image_count() {
        guard let cName = _dyld_get_image_name(index),
              let header = _dyld_get_image_header(index) else { continue }
        if String(cString: cName) == path {
            return MachOImage(ptr: header)
        }
    }
    // 2) host Debug stub 兜底:stub 路径与 mainExecutablePath() 相等,
    //    但 dyld 注册的是 .debug.dylib,所以 tier 1 不会命中。
    if path == mainExecutablePath() {
        return MachOImage.current()
    }
    // 3) 最后按 basename 兜底(symlink / 不规范路径)
    let imageName = path.lastPathComponent.deletingPathExtension.deletingPathExtension
    return MachOImage(name: imageName)
}
```

各场景行为:

| 场景 | `#dsohandle` 落点 | dyld 中的精确路径 | tier 1 是否命中 | 最终返回 |
|---|---|---|---|---|
| Release host | 主二进制 | 主二进制路径 | 是 | 主二进制 ✓ |
| Debug host (`.debug.dylib`) | `.debug.dylib` | dyld 注册的是 `.debug.dylib`,但 client 传的是 stub 路径 | 否 → 走 tier 2 | `.current()` = `.debug.dylib` ✓ |
| **注入 server (target 进程)** | server framework | target 主二进制路径 = client 传的 path | **是** | **target 主二进制 ✓** |

### 编译验证

- `xcodebuild build -workspace MxIris-Reverse-Engineering.xcworkspace -scheme RuntimeViewerCore -configuration Debug -destination 'generic/platform=macOS'`
- 0 errors / 0 linker errors
- 2 个 warning 均与本次改动无关(`RuntimeRequestResponse.swift:25` 关联类型重声明、`FileOperationRequest.swift:18` Sendable 一致性)

### 运行时验证

代码注入是运行时行为(`MachInjector` + SIP 关闭 + 后台 XPC / TCP 握手),需要人工跑:

1. 注入到任意 target 进程
2. 打开 target 主二进制,确认 class 列表来自 target 而非 RuntimeViewer
3. 复跑 framework 路径,确认无回归
4. 验证 host 自身(非注入)在 Debug + Release 两种 build 下打开自身主二进制仍能看到真实内容

---

## 备用方案 (尚未采用)

### 方案 B —— 用 dyld 私有 API `_dyld_get_prog_image_header()`

`dyld_priv.h` (macOS 10.16+) 提供:

```c
// Return the mach header of the process
extern const struct mach_header* _dyld_get_prog_image_header(void);
```

由 dyld 直接返回 "LC_MAIN 那个 image",**无视 `#dsohandle`、无视 `DYLD_INSERT_LIBRARIES` 索引位置、无视 Debug `.debug.dylib` stub 拆分**。Swift wrapper 已经存在于 `swift-dyld-private` 包(本仓 workspace 内已解析此依赖):

```swift
DyldPriv.programImageHeader() -> UnsafePointer<mach_header>?
```

伪代码:

```swift
package static func mainExecutableImage() -> MachOImage? {
    // Debug stub 例外:#dsohandle 落在 .debug.dylib,
    // _dyld_get_prog_image_header 给的是空壳 stub。
    var info = Dl_info()
    if dladdr(#dsohandle, &info) != 0,
       let fname = info.dli_fname,
       String(cString: fname).hasSuffix(".debug.dylib") {
        return MachOImage.current()
    }
    if #available(macOS 11.0, *),
       let header = DyldPriv.programImageHeader() {
        return MachOImage(ptr: header)
    }
    return MachOImage.current()
}
```

**为什么没选**:方案 A 用纯公共 API 就能解决,引入私有 API 增加 App Store / 上架风险(虽然本项目不上 App Store),`swift-dyld-private` 已经做了符号混淆但仍是 dlsym 私有符号。先用 A 验证够不够,不够再升 B。

### 方案 C —— 让 server 显式区分 "host vs 注入"

让 `RuntimeViewerServer` 启动时记录一个 `isInjected: Bool` flag,`machOImage(forPath:)` 在 `isInjected == true` 时**直接禁用** `.current()` 分支。

侵入性比 A 大,需要给 `DyldUtilities` 注入一个运行时状态,但语义最清楚。如果未来发现方案 A 的精确路径匹配在某些边角(symlink 解析、Catalyst bundle 路径规范化、shared cache 镜像)失败,可以升级到这个方向。

---

## 未来改善方向

- **回归测试**:增加注入场景下 "打开 target 主二进制" 的端到端测试。当前主二进制 vs framework 的行为分歧没有自动化捕获手段,bug 是靠人工现场反馈才暴露的。
- **路径规范化策略统一**:`mainExecutablePath()` (走 `_NSGetExecutablePath`) 与 dyld 注册的 image name 在 symlink、`/private` 前缀、Catalyst bundle 路径上可能不完全一致。tier 1 的 byte-for-byte 比较在这些场景会失败、跌到 tier 3 basename。如果现场报告有这类失败,需要补一层规范化(`realpath` / symlink 解析)再比较,或者直接迁移到方案 B。
- **`.current()` 的使用审计**:全仓 grep `MachOImage.current(` 与 `#dsohandle`,确保没有其他被注入到 target 进程后会"穿透"到 host 的 API。已知 Foundation 侧 `Bundle.main`、`ProcessInfo.processInfo.processName` 在注入场景下也是"对的"(报告所在进程信息),但需要逐条 review `RuntimeViewerServer.swift:35-45, 106` 这一类用 `Bundle.main` 上报身份的位置,确认是否需要改用 PID / 命令行参数。
- **文档化**:`DyldUtilities` 头部加一段 "注入语义" 说明,提醒后续修改者凡是涉及 "当前进程信息" 的 API,都要分别问一遍 "host 进程 vs 注入到 target 时的语义"。

---

## 相关代码

- `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift:73-152` —— `mainExecutablePath()` 与 `machOImage(forPath:)`,本次修复落点
- `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift:17-27` —— `mainExecutablePath()` 通过 IPC 暴露给 client
- `RuntimeViewerPackages/Sources/RuntimeViewerService/InjectionService.swift:14-36` —— 注入入口
- `RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift:26-114` —— server 在 target 进程内启动 listener
- `swift-dyld-private/Sources/DyldPrivate/API/DyldPriv+Image.swift:143-146` —— 方案 B 备用入口 `programImageHeader()`
- `MachOKit/Sources/MachOKit/MachOImage+static.swift:28-34` —— `MachOImage.current()` 行为定义
