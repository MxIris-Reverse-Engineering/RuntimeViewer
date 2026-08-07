# 库校验拦住 dlopen 注入：Music 一类 Apple App 附加不上

**日期**：2026-08-06
**背景**：用户报告 attach `Music.app` 失败——注入侧不报错，但 Music 进程里什么都没加载；同一套代码以前用 dlopen 是能注入进去的。

## 结论先行

Music 走的不是 remap，是 dlopen；而 dlopen 在 Music 里被 AMFI 的 **库校验（library validation）** 拦掉了。

判据只问了 sandbox 一件事，漏掉了代码签名这条完全独立的拦截线。Music 这类 Apple App 恰好是「sandbox 全放行、但强制库校验」，于是被送进一条注定失败的路径；再加上同步 dlopen shellcode 从来不回传 `dlopen` 的返回值，失败被静默吞掉，最终只表现为后续握手确认超时。

## 三个叠加的成因

### 1. 路由判据漏了这一类目标

`AttachToProcessViewModel` 原本只用一个条件决定走 remap：目标 sandbox 是否禁止 `file-map-executable`。对运行中的 Music 实测：

```
sandbox_check(Music,    "file-map-executable", <payload 路径>) = 0   ← 允许
sandbox_check(sharingd, 同上)                                  = 1   ← 拒绝
```

Music 完全不受 sandbox 限制（mach-lookup 也返回 0），所以判据返回 false，走 dlopen 分支。

### 2. 但 Music 强制库校验，dlopen 注定失败

读运行中进程的代码签名状态（`csops(pid, CS_OPS_STATUS)`）：

| 进程 | status | 关键位 |
| --- | --- | --- |
| Music | `0x26016a01` | VALID KILL RESTRICT **REQUIRE_LV** PLATFORM |
| Finder / Safari / Mail / Xcode | `0x26016a01` | 同上 |
| Dock | `0x26014a21` | 无 REQUIRE_LV |
| sharingd | `0x26014a01` | 无 REQUIRE_LV（它是被 seatbelt 拦的） |

`CS_REQUIRE_LV` 的含义是：该进程只接受 Apple 签名或**同一个 Team ID** 的 dylib。我们的 payload 签的是 `D5Q73692VW`，Music 是 Apple 平台二进制，两边不一致，AMFI 直接拒绝。

**这条今天确实在生效**，用同一个测试程序做了对照实验，唯一差别是签名时加不加 `library` 选项：

```
codesign -o library,runtime →  dlopen -> 0x0
    dlerror: ... not valid for use in process:
             mapping process and mapped file (non-platform) have different Team IDs
codesign -o runtime         →  dlopen -> 0x580006cf8f050   ← 成功
```

这也解释了「以前可以」：`Documentations/ResolvedIssues/2026-07-16-sharingd-sandbox-injection-investigation.md` 当时写明这台机器「AMFI library validation 已全局关闭」。到 macOS 26.6 已不再如此——SIP 依然 disabled、boot-args 依然只有 `-arm64e_preview_abi`，但库校验实测在拦。**变的是机器的 AMFI 行为，不是代码。**

关键点是：**库校验和 sandbox 是两条独立的拦截线**。sharingd 那类被 seatbelt 拦、不带 REQUIRE_LV；Apple App 这类不受 sandbox 限制、却带 REQUIRE_LV。只问其中一条，必然漏掉另一半。

### 3. 失败还是静默的

`MachInjector/Sources/MachInjector/loader_arm64.s` 里，mach 线程在 `pthread_create_from_mach_thread` 返回后立刻把 x0 置成 `"DONE"`，而真正的 `dlopen` 在新建的 pthread 上跑、返回值直接丢弃。于是无论 dlopen 成不成功，injector 一律报成功。用户看到的只有后面 `confirmAttachedRuntimeEngineConnected` 的握手超时——一个跟真正病因毫无关系的错误。

## 改了什么

### swift-helper-service（选路逻辑所在地）

选择 dlopen 还是 remap，**由守护进程决定，客户端不参与**。答案完全来自对目标进程的探测，daemon 本来就以 root 运行、握着 task port；把同一套判据在客户端再存一份，正是这次踩的坑的形状。

- **新增 C target `HelperProcessProbe`**：`HelperProcessProbeSandboxCheckPath`（`sandbox_check` 是变参，必须由 C 编译器发射调用）和 `HelperProcessProbeCodeSigningStatus`（`csops` 是 SPI，Swift 无可导入声明）。这个包此前没有任何 C target。
- **`InjectionServiceImplementation/InjectionStrategy.swift`**：唯一决策点 `InjectionStrategy.forTarget(pid:payloadPath:)`，两条拒绝理由都在这里成文。默认仍是 dlopen——它比 remap 简单得多也稳得多，remap 要自己套用 chained fixups、自己替 dyld 重放 runtime 通知。规则是「除非目标会拒绝，否则用 dlopen」。
- **`InjectApplicationRequest`** 增加 `remapEntrySymbol: String?`，**删除** `InjectApplicationViaRemapRequest`。该符号只在 daemon 选了 remap 时才用；留空的 payload 只有在目标恰好需要 remap 时才会失败，并给出明确错误——比强迫每个调用方编一个它给不出的符号名更诚实。

### RuntimeViewer

- **`RuntimeInjectClient`**：两个注入方法合并为 `injectApplication(pid:dylibURL:remapEntrySymbol:)`。
- **`AttachToProcessViewModel`**：只剩一次调用，不再判断走哪条路。
- **删除** `InjectionStrategy.swift`、`CodeSigningProbe.swift`、`RVProcessRequiresLibraryValidation`，以及 `SandboxProbe.isFileMapExecutableBlocked` + `RVSandboxCheckPath`。保留 `isMachLookupBlocked` / `isRuntimeViewerServiceMachLookupBlocked`——那是选传输通道用的，与注入无关。

### MachInjector

- **`loader_arm64.s` / `loader_x86_64.s`**：pthread 在 `dlopen` 返回后，把 handle 以及失败时 `dlerror()` 的消息写进一块 report 内存；先写内容再写结果码（arm64 用 `dmb sy`，x86 用 `mfence`），保证 injector 不会读到只写了一半的报告。
- **`MIMachInjector.m`**：在目标进程里额外 `mach_vm_allocate` 一页读写内存作为 report block，把地址补进 shellcode；看到 `"DONE"` 之后轮询该 report，读到明确失败就带上 `dlerror` 消息报错。

  report block 单独占一页而不是塞进 shellcode blob，是因为 shellcode 在目标进程里被映射成 read+execute，pthread 根本写不进去。

## 关键取舍

- **判据只看 `CS_REQUIRE_LV`，不比较 Team ID。** 严格来说，目标 Team ID 与 payload 相同时 dlopen 仍然可行；但那种目标基本只有我们自己的 App，为它引入「读 payload 自身 Team ID」的一层逻辑不划算。多余地走一次 remap 是可接受的代价。
- **「结果仍是 pending」按成功处理。** 轮询预算 2 秒（100 × 20ms）。构造函数慢的 payload 可能超出这个预算；只有明确的失败码才降级为错误，因此这项改动不可能让原本能用的路径变坏。
- **dead pid 的不对称行为不修，只记录。** `sandbox_check` 对找不到的 pid 返回「拒绝」而非错误，所以已退出的目标会被判成 remap；`csops` 对同样的 pid 返回错误，于是库校验探测 fail-closed 到 dlopen。两条路在死目标上都会卡在 `task_for_pid`，实际没有差别，因此按文档记录处理，不动既有 sandbox 探测的行为。

## 回归测试

`swift-helper-service/Tests/InjectionServiceTests/InjectionStrategyTests.swift`

没有任何系统二进制天然具备「不受 sandbox 限制 + 强制库校验」这个组合（平台 daemon 恰好相反），所以测试自己造一个：复制 `/bin/sleep` 到临时目录，用 `codesign --sign - --options library,runtime` 重签名后运行。ad-hoc 重签名同时会去掉平台二进制身份，这正是让库校验拒绝真正可达的前提。

- 强制库校验的目标 → 断言 sandbox 探测说「允许」（即旧判据会选 dlopen），而策略必须是 remap。**已确认该用例在修复前失败、修复后通过。**
- 同样的进程、不带 `library` 选项签名 → 策略必须是 dlopen（证明不是无脑一律返回 remap）。
- 不存在的 pid → 库校验探测 fail-closed。

## 第一次实测 remap：暴露出 loader 的 PAC 漏签

改完路由后实际 attach Music，Music 被杀，留下 `Music-2026-08-06-235757.ips`。**好消息是 remap 本身成立**——库校验确实没拦住它，payload 和 loader 都映射进去了。崩的是后面一步。

崩溃报告的关键几行：

```
termination:  {"namespace":"PAC_EXCEPTION","code":1}
exception:    EXC_BAD_ACCESS / SIGKILL
subtype:      KERN_INVALID_ADDRESS at 0xd54e80010c4d84cc
              -> 0x000000010c4d84cc (possible pointer authentication failure)
线程栈:        <未知帧> / _pthread_start / thread_start
vmregioninfo: 0x10c4d84cc 落在 10c4d8000-10c4dc000 [16K] r-x  mapped file
```

剥掉 PAC 位后的落点是 `loader base + 0x4cc`。把内嵌 loader 的字节还原成 dylib 后 `nm -arch arm64e -n` 一比：`_pthread_thunk` 的偏移正是 `0x4cc`。也就是说 **loader 的 pthread 入口一条指令都没执行**，`_pthread_start` 在 branch 过去的那一刻就认证失败了。

根因在 `MachInjector/Sources/MachInjector/loader_arm64_remap.s` 的 Phase 2：

```asm
adrp    x2, _pthread_thunk@PAGE
add     x2, x2, _pthread_thunk@PAGEOFF   ; ← raw address，没签名
```

`pthread_create_from_mach_thread` 的第三个参数是 `void *(*)(void *)`，在 arm64e 上就是 IA+0 签名的函数指针。libpthread 会把它重签进 `pthread_s.fun`，`_pthread_start` 再认证一次才 branch——传 raw 进去，指针被 poison，新线程一启动就炸。

**实证**（不需要 root，进程内就能验）：写一个程序分别用裸指针和 `paciza` 签过的指针作 start routine 调 `pthread_create_from_mach_thread`——签名的正常执行，裸的进程直接死，且两种情况下 `pthread_create_from_mach_thread` **都返回 0**。这就是为什么故障现场毫无提示。

**修复**：Phase 2 里补一条 `paciza x2`，然后跑 `build_loader.sh` 重新生成内嵌的 loader 字节。

这是一次回归——最早的版本里 start routine 是从 injector 填的 `_cfg_pthread_start_addr` 槽位读的，后来改成 loader 内部符号 `_pthread_thunk` 时签名没跟着搬过来。同一份 loader 的 C 部分（`loader_arm64_remap_handoff.c:216`）对 payload 入口是签了的，所以问题只出在汇编这一处。

**回归护栏**：MachInjector 没有测试 target，而 loader 是生成产物，所以护栏放进了唯一生产它的地方——`build_loader.sh` 汇编完会反汇编 `_remap_stage1_entry`，两个切片都检查 `paciza` 是否存在，缺了就以非零码退出、拒绝重写头文件。已验证：删掉 `paciza` 后脚本退出码为 1 并打印诊断。

## 待验证

Music 那次崩在 pthread 入口，所以 pthread 之后的整条链路——`map_images`、三个 `swift_register*`、payload 入口——在带 `REQUIRE_LV` 的目标上一次都还没跑过。修完 PAC 后需要再 attach 一次，才知道后面是否还有问题。

不改代码的临时解法是给 boot-args 加 `amfi_get_out_of_my_way=0x1` 后重启，dlopen 路径即恢复；但那是全系统降安全等级、换台机器就失效，所以不作为方案。
