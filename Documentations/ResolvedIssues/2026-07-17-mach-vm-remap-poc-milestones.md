# mach_vm_remap POC 实证纪要（M1 – M3）

**日期**：2026-07-17
**背景**：Round 2 R3 前置实验——验证多段 `mach_vm_remap` + reslide + libobjc register 方案在 sharingd 这类严格 seatbelt 平台守护进程上的可行性。
**依赖**：
- `Documentations/Plans/2026-07-16-sharingd-injection-via-mach-vm-remap-design.md`（Round 2 设计）
- `Documentations/ResolvedIssues/2026-07-16-sharingd-sandbox-injection-investigation.md`（Round 1 dlopen 死路结论）

## 环境与前置条件

- 硬件：Apple Silicon（arm64e），Mac13,1
- 系统：macOS 26.5.2 (25F84)
- 安全：SIP disabled；AMFI 全局 disabled（不影响本次实验，仅避免签名侧噪音）
- 目标进程：`/usr/libexec/sharingd`（当前实验会话 pid 32991；每次 kill 后 launchd 重启）
- 注入器：独立 CLI（POC 目录 `scratchpad/remaptest/`），Apple Development 签名 + hardened runtime
- Sandbox profile：`/System/Library/Sandbox/Profiles/com.apple.sharingd.sb` 关键规则同 Round 1（`(deny file-map-executable)` + 5 个系统白名单）

## M1 里程碑 — 单段 remap + patch（决定性通过）

**目标**：证明 `mach_vm_remap` 能把注入器进程里的 `__TEXT` 段投递到 sharingd，并让远程 mach thread 执行该段代码。

**方法**：
- 最小 asm loader，只有 `__TEXT` 段，无 `__DATA` / `__cstring` / imports
- Loader 内容：写入固定 marker `0xDEADBEEF` 到一个 `notepad_slot`
  ```asm
  adr  x0, _notepad_slot
  ldr  x0, [x0]           ; x0 = notepad address (patched by injector)
  movz w1, #0xBEEF
  movk w1, #0xDEAD, lsl #16
  str  w1, [x0]
  1: b 1b                 ; spin (mach thread can't ret)
  ```
- 注入器：
  1. 本地 `dlopen(loader.dylib)`，`dladdr` 拿 loader 基址
  2. `task_for_pid(sharingdPid)` 拿远程 task port
  3. `mach_vm_remap(target, ..., VM_INHERIT_SHARE, copy=FALSE)` 把 loader `__TEXT` 页 remap 到 sharingd
  4. `mach_vm_protect(target, ..., VM_PROT_COPY | VM_PROT_READ | VM_PROT_WRITE)` 拿到 COW 写权限
  5. `mach_vm_write` 修补 `_notepad_slot` 指向目标里 `mach_vm_allocate` 分配的 notepad
  6. 恢复 `VM_PROT_READ | VM_PROT_EXECUTE`
  7. `thread_create_running(ARM_THREAD_STATE64, pc=loader_entry, sp=stack)`

**决定性证据**：sharingd 内的 notepad 被写入 `0xDEADBEEF`，`mach_vm_read` 回来验证一致。sharingd 无 crash。

**关键学习**：
- `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE` 应对多线程目标里 remap 目标地址被其它分配抢占的 race——比 "allocate → deallocate → FIXED remap" 稳
- `VM_INHERIT_SHARE` + `copy=FALSE` 保留源代码签名，AMFI 若开启也不拒（本机 AMFI 关，仅作 future-proofing）
- 单段 loader 是**最小可执行代码投递**的基础模式；stage-2 pthread bootstrap 建立在这个基础上

## M2 里程碑 — 多段 remap + pthread bootstrap + Swift Foundation（决定性通过）

**目标**：证明完整 Swift `@_cdecl` 入口 + Foundation + os_log 在 sharingd 内可运行。

**方法演化**：

M1 loader 只需 `__TEXT` 是因为配置槽 (`_notepad_slot`) 就在 `__TEXT` 内、注入器用 `VM_PROT_COPY` 现场改。但一旦要走 stage-2（pthread bootstrap 需要传入 `pthread_create_from_mach_thread` 函数指针 + start_routine + arg），配置槽必须**可写**，不能塞在只读的 `__TEXT`。因此：

- loader 从 __TEXT-only → **__TEXT + __DATA 两段**，配置槽移到 `.section __DATA,__data`
- 汇编从 `adr` 改为 `adrp+add`：`adr` 只覆盖 ±1MiB 单段，无法从 `__TEXT` 直接编址 `__DATA` 里的 `_cfg_*` 槽位；`adrp+add` 覆盖 ±4GiB
- 配置槽：`_cfg_pthread_create_addr` / `_cfg_pthread_start_addr` / `_cfg_pthread_arg` / `_cfg_pthread_out`

**loader.s 骨架**：
```asm
_remap_stage1_entry:
    adrp x0, _cfg_pthread_out@PAGE
    add  x0, x0, _cfg_pthread_out@PAGEOFF        ; &out
    mov  x1, xzr                                  ; attr = NULL
    adrp x2, _cfg_pthread_start_addr@PAGE
    add  x2, x2, _cfg_pthread_start_addr@PAGEOFF
    ldr  x2, [x2]                                 ; start_routine
    adrp x3, _cfg_pthread_arg@PAGE
    add  x3, x3, _cfg_pthread_arg@PAGEOFF
    ldr  x3, [x3]                                 ; arg
    adrp x9, _cfg_pthread_create_addr@PAGE
    add  x9, x9, _cfg_pthread_create_addr@PAGEOFF
    ldr  x9, [x9]                                 ; pthread_create_from_mach_thread
    blr  x9
1:  b    1b
```

**payload_swift.swift**：
```swift
@_cdecl("m2_pthread_start")
public func m2_pthread_start(_ argument: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    let processIdentifier = getpid()
    NSLog("REMAP_POC_M2: hello from Swift @_cdecl entry via pthread, pid=%d", processIdentifier)
    os_log("REMAP_POC_M2: os_log fired from pid=%d", processIdentifier)
    return nil
}
```

**注入器**：
- 现在要 remap **两个 dylib**：payload_swift.dylib 的多段（`__TEXT` + `__DATA_CONST` + `__DATA`）+ loader.dylib 的多段（`__TEXT` + `__DATA`）
- 所有段都用 `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE`；同一 image 的内部段间偏移必须保持
- 从注入器 `dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread")` 拿到共享 cache 地址 → shared cache slide 跨进程一致 → 直接 patch 到目标 loader 的 `_cfg_pthread_create_addr` 槽
- `start_routine = remoteTargetPayloadTextBase + (m2_pthread_start_local_offset)`

**决定性证据**：
```
2026-07-17 11:29:00.741645+0800  localhost sharingd[32991]:
  (REMAP_POC_M2: os_log fired from pid=%d) REMAP_POC_M2: os_log fired from pid=32991
```
sharingd 存活、无 crash、Foundation + os_log 全线通。

**关键学习**：
- Raw mach thread 无 TLS (`TPIDRRO_EL0=0`)，任何 `dispatch_*` / `pthread_*` / Foundation 调用都会段错。**必须**用 `pthread_create_from_mach_thread` bootstrap 到一个正常 pthread，才能安全进 Swift/Foundation
- Swift `@_cdecl` 入口不需要 Swift metadata 提前注册（入口本身是 C 函数指针）
- `Foundation` 已被 sharingd 主进程加载 → `_bridgeInitializedSuccessfully` 为真 → Swift↔ObjC bridge 就绪；这是 M2 能 work 的隐性前提。**若目标进程没加载 Foundation，Swift 代码进入 bridge 路径就会 trap**
- `os_log` 沿系统通道走，跟 payload image 是否 register 无关

## M3 里程碑 — Swift 用户类 + Task { }（部分完成）

**目标**：证明用户自定义 Swift class + Swift concurrency 也能在 sharingd 内跑。

**方法**：M2 payload 的基础上加：
```swift
public class SwiftMiniTestClass {
    public let identifier: Int
    public let label: String
    public init(identifier: Int, label: String) { ... }
    public func describe() -> String { ... }
}

@_cdecl("m3_pthread_start")
public func m3_pthread_start(_ argument: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    NSLog("REMAP_POC_M3: pthread_start begin")
    let testObject = SwiftMiniTestClass(identifier: 42, label: "hello")
    NSLog("REMAP_POC_M3: created — %@", testObject.describe())
    Task { NSLog("REMAP_POC_M3: inside Task") }
    ...
}
```

### 结果 A — 无 reslide

**crash**：SIGSEGV in `objc_opt_self+16`，faulting address 落在**注入器进程**的 payload_swift.dylib 基址（不是 sharingd 的 remap 目标）。

**分析**：payload 的 `__DATA_CONST` / `__DATA` 里有 ObjC/Swift 内部 rebase 指针（例如 class metadata pointer、Swift TypeContextDescriptor 内的相对偏移解析结果）。这些指针在**注入器进程**里被 dyld 修复成注入器空间地址；remap 到 sharingd 后，指针值不变，但 sharingd 里那个地址没映射任何东西——read 就 SIGSEGV。

### 结果 B — POC reslide hack

**做法**：`delta = target_remote_base − injector_local_base`；扫描 payload 的 `__DATA_CONST` + `__DATA`，用 upper-bit 启发式识别 rebase pointer：
```c
if (!getenv("REMAPTEST_SKIP_RESLIDE")) {
    uint64_t injector_local_base = (uint64_t)payload_mh;
    int64_t slide_delta = (int64_t)payload_remote_base - (int64_t)injector_local_base;
    // Skip __TEXT; scan __DATA_CONST + __DATA
    uint64_t addr_bits = value & 0x00007FFFFFFFFFFFULL;
    if (addr_bits >= injector_local_base &&
        addr_bits < injector_local_base + payload_span) {
        uint64_t upper = value & 0xFFFF800000000000ULL;
        uint64_t new_addr = (addr_bits + slide_delta) & 0x00007FFFFFFFFFFFULL;
        fixed[j] = upper | new_addr;
    }
    // mach_vm_write fixed buffer to target
}
```

**结果**：__DATA_CONST 7 pointers + __DATA 16 pointers 被 reslid。sharingd crash 从 SIGSEGV 变到 SIGABRT via OBJC namespace：

```
_pthread_start                       ← payload pthread 入口
 → payload_swift+0x13a4              ← Swift 代码 (reslide 生效，跑得动)
 → payload_swift+0x1590              ← 触发 msgSend
 → _objc_msgSend_uncached            ← libobjc slow path
 → lookUpImpOrForward+0x330
 → _objc_fatal(...)                  ← libobjc 抛致命 assert
 → abort_with_reason
```

**分析**：reslide 有效，payload 内部指针指对了；msgSend 走到 slow path 后 libobjc 查表失败 —— libobjc **不知道** payload 里有 `SwiftMiniTestClass`。因为 `_dyld_objc_notify_register` 的 map 回调从没被触发过，libobjc 的 image list 里没有 payload 的 `__objc_classlist` / `__objc_imageinfo`。

### M3 定位到的最后一个 blocker

**核心 blocker**：libobjc image 注册。

**产品化路径**：
1. **正规 LC_DYLD_CHAINED_FIXUPS parser**——POC 用的是 upper-bit 启发式 hack（`value & 0x00007FFFFFFFFFFF`），只对 arm64 raw pointer 生效；真正的 dyld chained-fixup 用页内 chain + stride，不同格式（`DYLD_CHAINED_PTR_ARM64E` / `DYLD_CHAINED_PTR_64` / `..._REBASE`）需要各自解析
2. **`_dyld_objc_notify_register` v3 callback**——让 libobjc 认识 payload 的 `__objc_classlist` + `__objc_imageinfo`；备选私有 `_objc_addLoadImage`
3. **Swift metadata 注册**——`swift_registerTypeMetadataRecords` + `swift_registerProtocols` + `swift_registerProtocolConformances`，从 payload 的 `__swift5_types` / `__swift5_protos` / `__swift5_proto` section 读入
4. **`__mod_init_func` replay**——在 pthread 上下文里按顺序执行 initializer

以上四项属 **Phase 2.a** 范围（详见 Plans/2026-07-16 spec 的决策点段落）。

## 附：M2 baseline "回归"事件（教训）

**现象**：2026-07-17 debug 循环中曾出现 M2 marker 突然不发的现象。同一份 loader + payload + injector 二进制、同一目标 pid、`REMAPTEST_SKIP_RESLIDE=1` 也不恢复。反复排查多小时无果，判断力下降。

**根因**：目标 sharingd 进程内部有前一次注入残留的 mach 线程 / 占用了 remap 目标地址（我们的 injector 每次都用 `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE` 但对已经在跑的 injected pthread 无能为力）。

**修复**：`sudo killall sharingd` 让 launchd 重启一个干净 sharingd。M2 marker 立刻恢复 `REMAP_POC_M2: os_log fired from pid=32991`。

**教训**：
- POC 阶段每次实验前后都要 clean-slate 目标进程（`kill` + 等 launchd 拉起）
- 长 debug session 里疲劳导致的循环诊断代价很高，遇到不明回归时**停下来重启目标**比继续排查代码高效得多
- 生产化 API 需要有 "reset target state" 的 helper（否则用户遇到同类问题也会陷进去）

## POC 目录结构（reference）

```
scratchpad/remaptest/
├── m1/          # 单段 __TEXT + patch (M1)
├── m2/
│   ├── loader.s              # adrp+add 跨段配置槽
│   ├── loader.dylib          # __TEXT + __DATA
│   ├── payload_swift.swift   # @_cdecl m2_pthread_start
│   ├── payload_swift.dylib
│   ├── remaptest3.c          # 多段 remap + reslide POC + injector
│   ├── remaptest3
│   ├── Makefile
│   └── run_sharingd.sh       # sudo-driven M2 baseline runner
└── m3/
    ├── payload_swift.swift        # SwiftMiniTestClass + Task { }
    ├── payload_swift_task_only.swift  # sub-M3 diagnostic
    └── run_sharingd_no_minidyld.sh    # M3 baseline (uses M2 injector)
```

以及 `scratchpad/askpass.sh`：`SUDO_ASKPASS` 用 `osascript` popup 让用户输入密码，避免在长 debug loop 里每次都手贴 sudo 输出。
