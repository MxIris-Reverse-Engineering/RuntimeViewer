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

## M3 里程碑 — Swift 用户类 + Task { }（决定性通过）

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

## M3.a 里程碑 — gAPIs 定位 + libobjc map_images 直接 call（决定性通过）

**假设**：结果 B 的 SIGABRT 定位说明 libobjc 不认识 payload 的 class。让 libobjc 认识 payload image 就能通过 msgSend slow path。

### 关键情报（dyld 4 源码研究）

- `_dyld_objc_notify_register` (v1) 已在 dyld 4 里 halt (`DyldAPIs.cpp:853-858`)。libobjc 现役走 `_dyld_objc_register_callbacks(v4 struct)`
- v4 struct 里 `mapped3` 字段是 libobjc 的 `map_images` 函数指针
- libobjc `_objc_init` 里注册 v4 struct 后，dyld 4 `RuntimeState._notifyObjCMapped3` 存储了 mapped3 指针 (`DyldRuntimeState.cpp:2136`)
- `_dyld_lookup_section_info(mh, sectionLocationMetadata, kind)` 当 `sectionLocationMetadata == NULL` 时**dyld 自动 fallback** 到 `JustInTimeLoader::parseSectionLocations(mh, ...)` 直接从 mach_header 派生 section 表 (`DyldAPIs.cpp:3038-3042`)

后一条是决定性的——我们**不需要构造假 `Loader*`**，只需要传 `sectionLocationMetadata: nullptr`，dyld 会自己从 mach_header 派生 objc section。

### 方法

1. **gAPIs 定位** —— libdyld 里 `__TPRO_CONST,__dyld_apis` section 的第一个 qword 就是 `gAPIs` 指针（`APIs` 继承自 `RuntimeState`）
2. **map_images 定位** —— 从 gAPIs 起扫描内存，找**连续 4 个 qword，PAC bits stripped 后都落在 libobjc TEXT range 内**的位置。这就是 RuntimeState 里的 4 个 objc callback (`_notifyObjCMapped3`, `_notifyObjCPatchClass`, `_notifyObjCInit2`, `_notifyObjCUnmapped`)。qword[0] 就是 `map_images`

   本机 macOS 26.5 实测：offset `0x290` in RuntimeState，qword[0] = **`0x18d88dd20`**。反汇编验证前 4 条指令 `pacibsp; sub sp, ...; mov x21, x0; mrs x23, tpidrro_el0; casa` 完美匹配 objc4 里 `map_images` 的源码 (`objc-runtime-new.mm:3546`)：`mutex_locker_t lock(runtimeLock); map_images_nolock(...)`

3. **调用**（在 sharingd 内 pthread 上下文里）：
   ```c
   _dyld_objc_notify_mapped_info info = {
       .mh = payload_remote_mh,          // sharingd 里的 payload 基址
       .path = "…/payload_swift.dylib",
       .sectionLocationMetadata = NULL,  // 让 dyld fallback 解析 mach_header
       .flags = 0
   };
   _dyld_objc_mark_image_mutable mark = ^(uint32_t idx) { };
   map_images(1, &info, mark);
   ```

### 决定性证据

sharingd (pid 78273) 内 log stream 捕获 M3.a marker：
```
T4 swift registers done
T5 calling map_images(1, &info, mark) ...
T6 map_images returned                    ← libobjc 无异常返回
T7 object created                         ← SwiftMiniTestClass(identifier: 42, label: "hello") 成功实例化
```

M3 结果 B 的 `_objc_fatal in lookUpImpOrForward` 消失。

### Scan pattern 的稳定性

无需硬编码 RuntimeState offset。4-连 qword-in-libobjc 启发式跨 macOS 版本稳定——只要 `_notifyObjCMapped3` / `_notifyObjCPatchClass` / `_notifyObjCInit2` / `_notifyObjCUnmapped` 4 个字段在 RuntimeState 里保持连续声明（这是核心 API 结构），offset 变了不影响。

## M3.b 里程碑 — Swift metadata register + Task { } + Property access（决定性通过）

**假设**：M3.a T7 后（SwiftMiniTestClass 实例化）在 T8 依然 crash 于 `objc_retain(0x4d7466697770)`。初步归因为 property 读到 garbage → Swift metadata 未注册。

### 方法

1. Injector `dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY)`（C 程序默认不 link libswiftCore，`RTLD_DEFAULT` 找不到 Swift 符号）
2. `dlsym` 3 个 API（全部 exported）:
   - `swift_registerTypeMetadataRecords` (0x1a1448794)
   - `swift_registerProtocols` (0x1a144a2e0)
   - `swift_registerProtocolConformances` (0x1a13bec0c)
3. 遍历 payload mach_header 找 3 个 section 并计算目标空间 `[begin, end)`:
   - `__TEXT,__swift5_types`
   - `__TEXT,__swift5_protos`
   - `__TEXT,__swift5_proto`
4. Payload 里先 register 3 个 section，再 call map_images

### 意外发现——crash 真正根因不是 metadata

把 `describe()` interpolation 拆成分开 log 两个基础类型 field 后**首次通过**：
```swift
os_log("T8a identifier=%d", testObject.identifier)     // 42 ✅
os_log("T8b label length=%d", testObject.label.count)  // 5 ✅（"hello"）
```

`identifier=42` 和 `label.count=5` 都正确 —— **class field offset 从头就是对的**。Swift 5 pure class（不继承 NSObject）编译期 fixed layout，metadata 不 register 也不影响 property 直接访问。

之前 T7→T8 crash 的根因是 **`os_log("...%s", cstr)` 里 Swift os_log 的 `_os_log_encode` 把 `withCString` 出来的 `CChar*` 误当 CFString 去 `objc_retain`**。这跟 image registration 无关，是格式串-类型不匹配的编程 bug。

即便如此，产品化 mini-dyld 层保留 `swift_registerTypeMetadataRecords` 调用**仍然正确**——针对含 protocol / conformance 的 dylib，或需要 `swift_lookupType(mangledName)` 走 `SectionsToScan` 路径的情况，register 是必需的（对本 payload 只是 no-op 但不 harm）。

### Task { } 决定性验证

```swift
let capturedIdentifier = testObject.identifier   // 42
let taskFinished = DispatchSemaphore(value: 0)
Task {
    os_log("T10 inside Task { } closure, captured=%d", capturedIdentifier)
    taskFinished.signal()
}
_ = taskFinished.wait(timeout: .now() + .milliseconds(1500))
```

**结果**（sharingd pid 96294，log stream）：
```
T10 inside Task { } closure, captured=42
T11 Task { } completed
T12 done          ← sharingd 无 restart
```

Task closure 执行 + captured value = 42 正确 + semaphore signal 触发 wait 返回成功。sharingd 里 Swift Concurrency runtime 已经初始化（sharingd 自己用 Swift Concurrency），payload 的 closure metadata 通过前面的 register 就完全可用。

### 完整 timeline（M3.b 最终版）

```
T0-T3    payload 入口 + config dereference
T4       swift_registerTypeMetadataRecords(types [begin, end))
         (protos + conformances 空 range 跳过 — payload 无 protocol)
T5-T6    map_images(1, &info, mark) 返回，libobjc 认识 image
T7       SwiftMiniTestClass(identifier: 42, label: "hello") 成功
T8a-T8c  identifier=42 + label length=5 + label bytes withCString 可读
T10-T11  Task { } closure captured=42 + Task completed
T12      done — sharingd 无 restart, 无 diagnostic report
```

## M3 mini-dyld 组件工程化落定

M3 全部实证通过，Round 2 spec 里 "组件 B mini-dyld 层" 的每个子项状态：

| 组件 | 实现方法 | 实证状态 |
|---|---|---|
| **libobjc 注册** | gAPIs pattern scan → 直接 call libobjc `map_images`；`sectionLocationMetadata = NULL` 让 dyld fallback parse mach_header | ✅ M3.a |
| **Swift metadata 注册** | `dlopen(libswiftCore) + dlsym` 3 个 API → forward payload section range | ✅ M3.b |
| **Internal pointer re-slide** | POC upper-bit hack 生效（M3.a 每次 reslid 20 pointer）；产品化仍需 LC_DYLD_CHAINED_FIXUPS parser | ✅ POC / ⏳ 产品化 |
| **PAC discriminator** | `_dyld_objc_callbacks_v4` mapped3 有 `__ptrauth_dyld_objc_notify_mapped3`，但**gAPIs 内的 RuntimeState 里存的是 stripped raw pointer**，直接 call 无需重签 | ✅ 无额外工作 |
| **`__mod_init_func` replay** | M3 POC payload 无 mod_init（Swift 5 pure class 编译期 fixed layout）；产品化需要处理带 mod_init 的 dylib | ⏳ 产品化 |

## 教训

- **os_log format 与 arg 类型必须匹配** —— `os_log("%s", cstr)` 会被 Swift overload 编码到 CFString 分支后 `objc_retain(cstr)` 崩，很容易误判为 metadata 或 image registration bug（这次实际排查花了 30+ min）。产品化 mini-dyld 上层若要 log 复杂 String，用 `os_log("%{public}@", nsString)` + 显式 bridge
- **NSLog 在 sharingd 不 route 到 unified log** —— 只有 os_log 会。M2 baseline 里两条 log 只有 os_log 版本出现。sub-M3.a debug 循环里我一度以为 payload 没执行，实际只是 marker 用了 NSLog
- **`RTLD_DEFAULT` 找不到 libswiftCore 符号** —— C injector 不 link Swift，必须显式 `dlopen("/usr/lib/swift/libswiftCore.dylib")` 才能 dlsym Swift register API
- **Swift `@convention(c)` 里嵌套 `@convention(block)` 时**，其它参数必须 ObjC-representable —— `UnsafePointer<MyStruct>` 不 representable，改成 `UnsafeRawPointer` 绕开

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
├── m3/
│   ├── payload_swift.swift            # SwiftMiniTestClass + Task { }
│   ├── payload_swift_task_only.swift  # sub-M3 diagnostic
│   └── run_sharingd_no_minidyld.sh    # M3 baseline (uses M2 injector)
└── m3a/
    ├── loader.s                       # same as m2 (adrp+add, __DATA config slots)
    ├── payload_swift.swift            # SwiftMiniTestClass + Task { }, os_log markers
    ├── remaptest_m3a.c                # M2 injector + gAPIs scan + Swift register API
    │                                  # dlopen + config page write
    ├── Makefile
    └── run_sharingd.sh                # sudo-driven M3.a smoke test
```

以及 `scratchpad/askpass.sh`：`SUDO_ASKPASS` 用 `osascript` popup 让用户输入密码，避免在长 debug loop 里每次都手贴 sudo 输出。
