# 2026-11-05 离线服务读 Dock.app 时崩溃：每读一个镜像就把 dyld cache 的文件再映射一次，描述符用光

**调查日期：** 2026-11-05
**修复落地：** 2026-11-06。MachOSwiftSection 分支 `fix/shared-cache-file-mappings`，本仓库分支 `fix/offline-descriptor-exhaustion`；本仓库钉的 MachOSwiftSection 抬到含修复的 `next` 之后，读取层那一半才在 App 里生效
**Severity：** High —— 离线服务进程整个停下，正在读的文件要重新打开
**触发场景：** 离线打开 `/Volumes/RE/Dock/27.0/Dock.app`（bundle，配对本机的 dyld shared cache），后台给 DockHelper 建 Find 语料

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `RuntimeViewerOfflineService` 停在 MachOSwiftSection `MachOReading/Extensions/DyldCache+.swift:50` 的 `try! MemoryMappedFile.open`：`'try!' expression unexpectedly raised an error: system error 24`（`EMFILE`）。栈自上而下：`DyldCache.fileIO` ← `MachOFile.readWrapperElement` ← `BuiltinTypeLayoutIndex.init` ← `ImageReference.init` ← `ImageUniverse.indexNextDependency()` ← `ImageUniverse.resolveProtocolClassConstraint("DockCore.MenuHelperClientProtocol")` ← 存在类型与 Optional 的布局 ← DockHelper 一个类的字段布局 ← `RuntimeSwiftSection.corpusPrints` ← `RuntimeInterfaceCorpusStore.run` |
| **影响范围** | 所有离线读 dyld cache 镜像的进程，读过的镜像越多占的描述符越多；swift-section 等 MachOSwiftSection 的离线读者同样受影响。字段类型里有 Swift 声明的 `@objc` 协议时，一个镜像就要把几百个依赖镜像读一遍，最快撞上限 |
| **根因** | MachOSwiftSection 读取层的文件映射挂在每个 `MachOFile` / `DyldCache` 实例上，而 MachOKit 给每个镜像新建 `DyldCache`、依赖闭包给每个根新建一批 `MachOFile`：同一个 cache 文件被映射几百次，每次占一个描述符 |
| **Status** | **Fixed** —— MachOSwiftSection 改为每次打开的文件只映射一次；本仓库的离线服务读文件前自己抬高描述符上限，配对本机 cache 改用进程共享的那一份 |

---

## 现场

- 崩溃的进程停在调试器里时用 `lsof -nP -p <pid> -a -d 0-1000000` 数：2,560 个描述符，正好是它的上限。其中 2,548 个指向 dyld cache 的文件，却只有 85 个不同的文件——`.26.dyldreadonly` 一个文件开了 343 次，`.05`、`.01` 各 320 多次。
- 2,560 = launchd 给 XPC 服务的软上限 256（`launchctl limit maxfiles`）+ CoreFoundation 第一次有人碰 `CFSocket` 时自动加的 2,304（swift-corelibs-foundation 的 `CFSocket.c`，`CFSocketGetTypeID`）。服务从没设过自己的上限。
- DockHelper 的 `DockHelperDelegate.helperClient` 与 `syncHelperClient` 类型是 `Optional<DockCore.MenuHelperClientProtocol>`。这个协议是 Dock 可执行文件（模块名 DockCore）里用 Swift 声明的 `@objc` 协议，DockHelper 持有它的 ObjC 协议记录副本。

## 根因

1. **映射按实例，不按文件。** MachOSwiftSection 的 `MachOFile.fileIO`、`DyldCache.fileIO` 是挂在实例上的关联对象，每个实例第一次读时自己 mmap 一遍所在文件，映射一直攥着一个描述符。实例却很多：
   - `FullDyldCache.machOFiles()` 给每个不在主文件里的镜像新建一个 `DyldCache`（`cache(atIndex:)`）；
   - MachOKitExtensions 的子 cache 表按 `MachOFile` 各建一套子 cache 实例，读到别的子 cache 时用的是这一套；
   - 依赖定位器给每个根各做一批依赖 `MachOFile`。

   描述符于是随「读过的镜像数」线性增长，与 cache 有几个文件无关。
2. **`@objc` 协议让一个镜像读遍整个依赖闭包。** 静态布局遇到协议存在类型时，先问依赖闭包里有没有这个协议的 Swift 描述符（`resolveProtocolClassConstraint`），Swift 声明的 `@objc` 协议没有描述符，必然落空，于是先把根的整个闭包（DockHelper 是五百多个镜像）一个个索引进来，最后才去查 ObjC 协议记录——而根自己就有。
3. **配对本机 cache 时开了两份。** `RuntimeFileImageCatalog` 用 `FullDyldCache.host`（每次访问都重新打开并映射全部八十几个文件），MachOSwiftSection 的依赖定位器用进程共享的 `FullDyldCache.cachedHost`，同一个 cache 在进程里有两份。
4. **`try!`** 把打开失败变成了整个进程停下。

## 修复

- **MachOSwiftSection**（`fix/shared-cache-file-mappings`，细节在它的 `Documentations/Internal/ProjectEvolutionLog.md`）：
  - 映射按 MachOKit 的 `fileHandleIdentity` 共享：同一次打开的 cache 文件，MachOKit 组装出的每个 `DyldCache` 与 `MachOFile` 都带同一个身份，映射挂在身份上（新类型 `SharedFileMapping`），描述符数等于打开的文件数。
  - `fileIO` 改为抛错：打不开就让这次读取失败，不再停掉进程。
  - `ImageUniverse.resolveProtocol` 每索引一个镜像就同时查 Swift 描述符和 ObjC 记录，谁先认出就停：DockHelper 那个字段不再读任何依赖。
- **本仓库**（`fix/offline-descriptor-exhaustion`）：
  - `RuntimeFileImageCatalog` 配对本机 cache 时用 `FullDyldCache.cachedHost`，与依赖定位器共用一份。
  - `RuntimeOfflineServiceHost` 在读文件之前把软上限抬到 `min(OPEN_MAX, rlim_max)`——`setrlimit(2)` 手册建议的最大值，本机是 10,240。共享之后整份 cache 由 MachOKit、Swift 读取层、ObjC 读取层各映射一遍就要两百多个描述符，256 不够，不能再指望 CoreFoundation 顺手抬上去。

## 复现与验证

- **复现回路**（不用 App，5 秒）：

  ```bash
  ( ulimit -Hn 256; ulimit -Sn 256
    swift-section dump /System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper \
      --architecture arm64e --sections types --emit-field-offsets -o out.txt )
  ```

  修复前退出码 133（`SIGTRAP`），报的就是 `DyldCache+.swift:50` 那一行；修复后退出码 0，输出与修复前不设上限时逐字节一致。**硬上限要一起压**：只压软上限时 CoreFoundation 会把它抬上去，同一条命令在上限 100 下也能跑完（实测开到 924 个）。
- **回归测试，修复前红、修复后绿**：
  - MachOSwiftSection `SharedFileMappingTests`：子进程里压到 256 后连读本机 cache 的 400 个 Swift 镜像（修复前 `SIGTRAP`）；同一文件的各个读者拿到同一个映射；文件被删后读取抛错而不是停下（修复前 `SIGTRAP`）。
  - MachOSwiftSection `SwiftDeclaredObjCProtocolExistentialLayoutTests`：`@objc` 协议的存在类型字段在依赖闭包里算布局，一个依赖都不索引（修复前索引了全部 513 个、64 秒，修复后 0.19 秒）。
  - 本仓库 `OfflineFileEngineTests`：配对本机 cache 的目录用的是 `FullDyldCache.cachedHost`。
  - 本仓库 `RuntimeOfflineServiceHostTests`：子进程从软上限 256 起跑一次宿主启动，之后软上限达到 `min(OPEN_MAX, rlim_max)`。

## 以前修过吗

- MachOSwiftSection 第 82 节（2026-10-06）修子 cache 查找时已经注意到「按实例缓存的文件映射每换一个实例就重开」，当时让同一个 `MachOFile` 每次拿回同一个子 cache 实例，跨 `MachOFile` 的重复没有处理；07993a5f（2026-10-08）给映射加了创建锁，仍是按实例。
- 先查 Swift 描述符、落空再查 ObjC 记录的顺序，是认出 Swift 声明 `@objc` 协议时（静态布局引擎阶段 8）定的，当时没考虑落空的代价。

## 教训

- 复现「描述符不够」要同时压硬上限，判断一个进程的上限也别假设它停在 256。
- 「映射有缓存、有锁」不等于「每个文件只映射一次」：缓存挂在谁身上，决定了它按什么去重。
