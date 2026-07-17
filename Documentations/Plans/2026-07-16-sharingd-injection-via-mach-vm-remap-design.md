# Sharingd 注入方案：mach_vm_remap 复刻 Apple 设计

**日期**：2026-07-16（Phase 1 POC 结果 2026-07-17 补记）
**状态**：Phase 1 POC 已完成 M1/M2 里程碑；M3 定位到最后一个 blocker（libobjc image 注册）；进入 Phase 2 工程化
**依赖**：
- `Documentations/ResolvedIssues/2026-07-16-sharingd-sandbox-injection-investigation.md`（Round 1：dlopen 死路结论）
- `Documentations/ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md`（Round 2：M1/M2/M3 实证纪要）

## 目标与非目标

### 目标

- 让 RuntimeViewer 能够 attach 类似 `sharingd`、`rapportd` 等**严格 seatbelt 平台守护进程**并获取其 ObjC/Swift 运行时信息。
- 复刻 Apple `RemoteInjectionAgent` / `libRemoteInjectionPayload` 的核心机制：**`mach_vm_remap` 内存到内存投递**，完全绕过 seatbelt 对 `file-map-executable` 的检查。
- 保留现有 dlopen 路径作为主流（普通 App、`get-task-allow` 目标）的默认方案，仅在识别到严格 daemon 时切换到新路径。

### 非目标

- 不复用 Apple 的 `libRemoteInjectionPayload.dylib`（法律/分发问题）。设计从其反编译中学习，实现自行完成。
- 不追求支持 iOS/tvOS/visionOS 上被完全隔离的进程——只解决 macOS 上「有 task_for_pid 权限但被 sandbox 阻挡代码加载」这一类。
- 不做「无痕注入」——目标进程 vmmap 会看到新映射的内存段，dtrace 会看到远程线程创建。

## 背景与调查回顾

上游背景见 `ResolvedIssues/2026-07-16-sharingd-sandbox-injection-investigation.md`。核心事实浓缩：

- sharingd sandbox profile 显式 `(deny default)`, `(deny file-map-executable)`，然后白名单 5 个 `/System/Library/*` 子路径。
- **`APP_SANDBOX_READ` extension 只 grant `file-read*`，不 grant `file-map-executable`**——无论怎么发 extension，`dlopen` 走的目标进程 `mmap(fd, PROT_EXEC)` 都会撞 profile 白名单。
- 关 SIP + 关 AMFI library-validation 都无效，因为拦截层是 seatbelt profile 本身。

**`mach_vm_remap` 为什么能绕过**：

- seatbelt 的 `file-map-executable` hook 挂在 syscall 层（`mmap` / `vm_map_enter_mem_object_with_file`），检查「文件 vnode 是否在允许的 subpath」。
- `mach_vm_remap` 是 Mach 层的 VM-to-VM 映射，源是**另一个 task 里的已存在虚拟内存**，不涉及 vnode，不触发 file-map-executable 检查。
- 源进程里已 `dlopen` 过的 payload 的 `__TEXT` 页，被 remap 到目标后仍保留原代码签名，AMFI 也不会拒（何况本机 AMFI 已 disabled）。

## Apple loader 反编译要点

反编译 IDA session：`libRemoteInjectionPayload.dylib` 只有两个函数、零 imports、零字符串、`__text` 共 650 字节。

### `_local_loader_function`（stage 1，mach thread entry，419 bytes）

- 从传入的 arg 表（16+ QWORDs）读入所有依赖的函数指针：`mach_thread_self`、`pthread_create_from_mach_thread`、`mach_msg`、`sandbox_extension_consume`、`dlopen`、`dlsym`、`dlerror`、`thread_terminate`、若干 mach 收尾函数。
- 把 mach thread 自己的 port 写入 notepad。
- 用 `pthread_create_from_mach_thread`（唯一能从 raw mach thread 调用的 pthread API，见 MachInjector CLAUDE.md 的 non-obvious invariants）拉起一个 pthread 跑 `pthread_local_loader_variant`。
- 遍历 arg 表尾部的可变长参数列表，跳过 NULL 终结符。
- 进入无限 `mach_msg`-based 循环 yield。raw mach thread 不能 `ret`（`x30 = 0` 会跳到 NULL）；只能由 pthread 端调 `thread_terminate` 外部干掉。

### `_pthread_local_loader_variant`（stage 2，pthread entry，231 bytes）

有 TLS，可以安全调 MIG 的 dlopen/dlsym：

```pseudo
libpath  = arg[0]
flags    = arg[1]
tokenArr = arg[2]                 // NULL-terminated
funcs    = arg[10]                // function-pointer table base (relative offsets to fn ptrs)
notepad  = arg[5]

*(arg[8]) = arg[9]                // write pthread_port slot

for token in tokenArr:            // consume sandbox extensions
    funcs.sandbox_extension_consume(token)

handle = funcs.dlopen(libpath, flags)
if handle:
    fn = funcs.dlsym(handle, entrySymbol)     // entry symbol string is another arg
    if fn:
        notepad->returnValue = fn(userArg, ...)   // call user entry
    else:
        strncpy(notepad->errorBuf, funcs.dlerror(handle), 4088)
else:
    strncpy(notepad->errorBuf, funcs.dlerror(NULL), 4088)

notepad->result = funcs.something(...)         // set completion result
funcs.someWakeup(...)                          // wake the mach thread
funcs.thread_terminate(machThreadPort, ...)    // kill stage 1 → MACH_SEND_DEAD fires in injector
return
```

**关键**：整个 loader 里没有任何 `dyld` 依赖——所有跨模块调用都通过 arg 表里的函数指针，这些指针值都是 shared cache 里的地址，**跨进程一致**（shared cache slide 全系统统一）。

### 设计精髓

- **只 remap `__TEXT` 段**：因为 loader 没有 `__DATA` 需要（无全局变量）、没有 `__cstring` 需要（无常量字符串）、没有 `__la_symbol_ptr`（无 imports）。
- **arg 表位于目标进程自己分配的内存里**：由注入器 `mach_vm_write` 写入（普通数据写，不触发 `file-map-executable`）。
- **notepad 是目标进程分配的一块共享 RW 内存**：pthread 端把结果/错误写进去，注入器端 `mach_vm_read` 拉回来。
- **完成通知走 `MACH_SEND_DEAD`**：mach thread port 一被 `thread_terminate`，注入器的 `dispatch_source_type_mach_send` 立即触发（这是 MachInjector async V2 已经用的模式）。

## 设计方案

### 组件 A：`RuntimeViewerLoader.dylib`（新增，自包含 shellcode-in-dylib）

**位置**：`RuntimeViewerLoader/` 新建 Xcode project 或 sibling SPM package。产物是 arm64 + arm64e 的 fat dylib。

**内容**：只有两个 exported 函数，用**手写汇编**（`.s` 文件）实现：

```
runtime_viewer_local_loader_function   // stage 1，进入 mach thread 用
runtime_viewer_pthread_variant          // stage 2，进入 pthread 用
```

**编译约束**（构建脚本或 linker flag 保证）：
- 无 `__la_symbol_ptr` / `__got` / `__data`：链接期通过检查段列表 assert。
- 无 `__cstring` / 任何常量数据段：assert。
- 段结构最简：`__PAGEZERO`, `__TEXT`（只含 `__text`）, `__LINKEDIT`。

**签名**：`Apple Development` team 签名 + hardened runtime（跟其它 dev 产物一致）。虽然本机 AMFI 关着，签名不做校验，但保留 hardened 属性方便未来在 AMFI 打开的机器上验证行为。

**手写汇编要点**（参照 MachInjector `loader_arm64_async.s` 结构）：
- 遵循 `MachInjector` CLAUDE.md 里的 non-obvious invariants：raw mach thread 无 TLS、不能 ret、只能 `mach_thread_self` / `pthread_create_from_mach_thread`。
- ARM64e（arm64 + PAC）在两个 slice 各 build 一份，ptrauth 通过注入器侧 `ptrauth_strip` 后 patch 进 arg 表。
- 保留 x86_64 slice 是否必要待评估（Xcode 的 payload 是 fat 3-arch；我们的目标是 arm64 平台守护进程，短期不必）。

### 组件 B：`MachInjectorRemap`（新增 API）

上游到 MachInjector 仓库作为**第三条路径**（sync / async / **remap**）：

```objc
NS_SWIFT_NAME(MachInjectorRemap)
@interface MIMachInjectorRemap : NSObject

+ (void)injectWithPID:(pid_t)pid
            dylibPath:(NSString *)dylibPath
         entrySymbol:(NSString *)entrySymbol           // e.g. "runtime_viewer_server_start"
                 arg:(nullable NSString *)arg
              timeout:(NSTimeInterval)timeout
    completionHandler:(MIInjectionCompletionHandler)completionHandler
    NS_SWIFT_ASYNC_NAME(inject(pid:dylibPath:entrySymbol:arg:timeout:));

@end
```

**流程**（参照 IDA 反编译的 `sub_100001980`）：

1. 在**注入器进程内** `dlopen(@rpath/RuntimeViewerLoader.dylib, RTLD_NOW)`——注入器是 root 非 sandboxed，加载正常。
2. `dladdr(&runtime_viewer_local_loader_function, &info)` → 拿到 `__TEXT` 段基址。
3. `mach_vm_region(mach_task_self(), base, &size, ...)` → 拿到 `__TEXT` 页对齐后的确切大小。
4. `task_for_pid` → target task port。
5. `mach_vm_remap(target, &remoteText, size, 0, VM_FLAGS_ANYWHERE|VM_FLAGS_RETURN_DATA_ADDR, mach_task_self(), localText, FALSE, &cur, &max, VM_INHERIT_SHARE)` → 目标里出现只读可执行的 `__TEXT` 拷贝。**关键 flag**：`VM_INHERIT_SHARE` + `copy=FALSE` 保留 COW 与代码签名。
6. `mach_vm_allocate(target, &notepad, sizeof(Notepad), VM_FLAGS_ANYWHERE)` → 目标里分配 notepad。
7. `mach_vm_allocate(target, &argBlock, argSize, VM_FLAGS_ANYWHERE)` → 目标里分配 arg 表 + 字符串数据。
8. 本地构造 arg 表：函数指针从注入器进程 `dlsym(RTLD_DEFAULT, "dlopen")` 等取，`ptrauth_strip` 后填入；libpath、entrySymbol、arg 字符串紧跟其后。`mach_vm_write` 到目标 argBlock。
9. `mach_vm_allocate(target, &stack, stackSize, VM_FLAGS_ANYWHERE)`。
10. 计算 arm64 thread state：`pc = remoteText + (localFnPtr - localText)`（stage 1 入口在 __TEXT 内的相对偏移不变），`sp = stack + stackSize - 16`，`x0 = argBlock`（或按 stage 1 的 ARM64 调用约定填 x0-x3），`lr = 0`（挑衅错误定位）。
11. `dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_SEND, machThreadPort, DISPATCH_MACH_SEND_DEAD, queue)` 监听 mach thread 死亡。
12. `thread_create_running(target, ARM_THREAD_STATE64, ...)` 起线程。若目标是 Rosetta 翻译进程走 `oah_thread_create_running`（IDA 里可见 Apple 也做同样分支）。
13. `dispatch_source` handler 触发时 `mach_vm_read` notepad → 解析结果 / 错误 → 调 completionHandler。

**内部实现职责（mini-dyld 层，caller 透明）**：

`MIMachInjectorRemap` 库内实现以下步骤，call site 只需提供 `pid` / `dylibPath` / `entrySymbol`：

1. **多段 remap** —— `__TEXT` + `__DATA_CONST` + `__DATA`，`mach_vm_remap` 用 `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE` 避免与目标进程 VM 分配 race
2. **LC_DYLD_CHAINED_FIXUPS 正规 parser** —— 遍历 payload 的 chained-fixup 段，为每个 rebase pointer 计算重定位目标。POC 阶段用的是 upper-bit 启发式 hack（`addr_bits = value & 0x00007FFFFFFFFFFF`），产品化必须走 chained-fixup 格式，正确处理 stride、page fixup、bind vs rebase
3. **Internal pointer re-slide** —— `delta = target_remote_base − injector_local_base`；遍历所有指向 payload 内部的 rebase 指针，加 delta 后 `mach_vm_write` 修补到 target 的 `__DATA_CONST` / `__DATA`
4. **`_dyld_objc_notify_register` v3 callback 触发** —— 让 libobjc 认识 payload 的 `__objc_classlist` + `__objc_imageinfo`。若 v3 API 在目标 macOS 版本上不稳，退回私有 `_objc_addLoadImage`
5. **Swift metadata 注册** —— 分别调用 `swift_registerTypeMetadataRecords` + `swift_registerProtocols` + `swift_registerProtocolConformances`，参数来自 payload 的 `__swift5_types` / `__swift5_protos` / `__swift5_proto` section
6. **`__mod_init_func` replay** —— 在 pthread 上下文里按 `__DATA_CONST,__mod_init_func` 段的顺序执行每个 initializer 指针

### 组件 C：`RuntimeViewerServer` 加 exported entry

**问题**：mach_vm_remap 路径不走 dyld，`__attribute__((constructor))` 不会自动执行。而现有 server 依赖 constructor 完成初始化。

**方案**：在 `RuntimeViewerServer` 的 `main.m` 添加一个显式 exported 函数：

```objc
// RuntimeViewerServer/main.m

__attribute__((visibility("default")))
int runtime_viewer_server_start(const char *initArg) {
    // Runs the same setup as the current constructor:
    //   - install signal handlers
    //   - start LocalSocket client connection with identifier from initArg
    //   - register request handlers
    // Returns 0 on success, negative errno-like code on failure.
    return RuntimeViewerServer_bootstrap(initArg);
}

__attribute__((constructor))
static void RuntimeViewerServer_dylibConstructor(void) {
    // Existing behavior for the dlopen path: derive initArg from pid and call
    // runtime_viewer_server_start automatically.
    char defaultArg[64];
    snprintf(defaultArg, sizeof defaultArg, "%d", getpid());
    runtime_viewer_server_start(defaultArg);
}
```

好处：
- 现有 dlopen 路径**行为无变化**（constructor 仍自动执行）。
- 新 remap 路径通过 `entrySymbol="runtime_viewer_server_start"` 显式调用，避开 dyld constructor 环节。

### 组件 D：`RuntimeInjectClient` 分流

App 端在 `AttachToProcessViewModel` 里做目标分类：

```swift
if SandboxProbe.isStrictSeatbeltDaemon(pid: pid) {
    try await runtimeInjectClient.injectApplicationViaRemap(
        pid: pid,
        dylibURL: dylibURL,
        entrySymbol: "runtime_viewer_server_start"
    )
} else {
    try await runtimeInjectClient.injectApplication(pid: pid, dylibURL: dylibURL)
}
```

`SandboxProbe.isStrictSeatbeltDaemon` 的判断依据（新增，接续现有 `SandboxProbe.isRuntimeViewerServiceMachLookupBlocked`）：
- 目标路径以 `/usr/libexec/` 或 `/System/Library/` 开头，且
- 是 platform binary（`csops(CS_OPS_STATUS)` 里 `CS_PLATFORM_BINARY` 位置位）

Helper 端 `InjectionService` 增加 `InjectApplicationViaRemapRequest`，路由到新 API。

## 关键技术细节

### 函数指针跨进程一致性

- 所有从注入器 dlsym 拿到的 shared cache 地址（libdyld / libSystem 里的 dlopen、dlsym、sandbox_extension_consume 等）在两个进程里 **slide 完全相同**——dyld shared cache 是全系统 slide，不是 per-process。这是这个方案能工作的关键前提。
- `ptrauth_strip` 后填入 arg 表，loader 端如果需要用 PAC 调用（arm64e），在汇编里用 `braa` 之类 signed indirect branch；否则用 `blr` 裸调。跟 MachInjector `loader_arm64_async.s` 里对 dlopen 等的处理方式保持一致。

### notepad 布局

参照 MachInjector `MINotepad`（280 bytes 已有格式），新增字段：

```c
typedef struct {
    uint32_t pthread_port;      // 4
    uint32_t mach_thread_port;  // 4
    int32_t  result_code;       // 4
    uint32_t padding;           // 4
    uint64_t handle;            // 8
    char     error_message[256]; // 256
} MINotepad;
```

remap 路径的 notepad 可以复用同一格式。

### VM_INHERIT_SHARE vs COPY

- `mach_vm_remap` 的最后一个参数是 inheritance mode。
- 用 `VM_INHERIT_SHARE`：目标里的 remap 与源共享物理页（COW）。若源进程 unload dylib，目标里的映射会怎样？取决于源进程 vm entry 的生命周期——为安全起见，注入器持有 `dlopen` handle 到 injection 完成。
- 用 `VM_INHERIT_COPY`：立即物理拷贝。开销大但独立性强。
- 先用 `VM_INHERIT_SHARE` + copy=FALSE，POC 阶段验证。

### 完成通知与超时

- 完全复用 MachInjector async V2 的 `MACH_SEND_DEAD` dispatch source 模型。
- 超时侧：dispatch_after 触发时抢先 cancel dispatch source 并强制 completionHandler。

### Rosetta / 翻译进程

- IDA 里 Apple 检测目标进程是否翻译（sub_10000285D）后走 `oah_thread_create_running` 分支。
- 我们的目标（sharingd 等系统 daemon）都是 native arm64e，不需要 Rosetta 分支。POC 阶段忽略；后续如果发现有 x86_64 目标才补。

## 分阶段实施计划

### Phase 1 — POC：独立 CLI 验证机制（已完成 M1/M2，M3 剩余 libobjc register）

原计划的 4 步描述已过时——实际实证走了一条更细粒度的路径。详细方法与决定性证据见 `ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md`。总览：

- **M1** ✅ —— 最小 asm loader 单段 remap + `mach_vm_protect(VM_PROT_COPY)` patch，sharingd 内 mach thread 成功写入 `0xDEADBEEF` marker
- **M2** ✅ —— 多段 remap（`__TEXT` + `__DATA`）+ `adrp+add` 跨段配置槽 + `pthread_create_from_mach_thread` bootstrap 到 Swift `@_cdecl` 入口 → sharingd 内发出 `REMAP_POC_M2: os_log fired from pid=32991` marker，sharingd 存活
- **M3** ⏳ —— Swift 用户类 + `Task { }`；POC reslide hack 生效后 crash 从 SIGSEGV (`objc_opt_self+16`) 变到 SIGABRT (`_objc_fatal in lookUpImpOrForward`)，定位为 libobjc 未 register payload image

### Phase 2 — 工程化到 MachInjector（1-2 天）

- 把 loader dylib 移进 MachInjector 仓库或 RuntimeViewer sibling package。
- 加 `MIMachInjectorRemap` API。
- 完善 arm64e ptrauth、超时、错误上报。
- 补全 dispatch_source 生命周期管理（参照 async V2）。

### Phase 3 — RuntimeViewerServer 侧改动（半天）

- 加 `runtime_viewer_server_start` exported entry。
- 保留现有 constructor 行为不变。
- 单元验证：普通 App 走原路径行为不变。

### Phase 4 — App 端分流与 UI（半天）

- `SandboxProbe.isStrictSeatbeltDaemon` 判定。
- `RuntimeInjectClient` 新 API。
- Helper 端 `InjectionService` 分支。
- attach 失败时把 `remoteErrorMessage` 端到端从 helper 传回 App（此前 handshakeTimedOut 的临时文案可以简化）。

### Phase 5 — 端到端验证（半天）

- 打 sharingd、rapportd、其它 seatbelt daemon 分别验证。
- 打普通 App 确保原路径回归无破坏。
- 关闭 helper 或注入器 crash 时 socket 泄漏路径回归（socket 修复的持续验证）。

**总估算**：3-4 个工作日。

## 风险与开放问题

### R1：函数指针 slide 假设

**风险**：如果某个函数不在 shared cache 里（例如 `sandbox_extension_consume` 若被移出 libsystem_sandbox），跨进程地址就不一致。

**mitigation**：POC 阶段用 `dladdr` 验证注入器里每个准备 patch 的函数地址都在 shared cache 范围内（`mach_task_self` 的 `dyld_shared_cache_range`）。若命中非共享地址，改让 loader 在目标里 `dlsym(RTLD_DEFAULT, ...)` 自查——只对少数关键函数走 self-lookup 路径。

### R2：VM_INHERIT_SHARE 生命周期

**风险**：源进程 unload payload dylib 后目标里的 remap 可能失效。

**mitigation**：注入器持 dlopen handle 直到 completionHandler 返回；生产代码把 handle 存到 daemon 生命周期里，永不 dlclose。

### R3：sandbox 对 dlopen 用户 libpath 仍然拦

**警告**：即使 loader 已经在目标里跑起来，它的 `dlopen(userLibpath)` 仍然走**目标进程**的 mmap——**同样撞 sharingd 的 file-map-executable 白名单**。

**这就意味着 mach_vm_remap 只能让 loader 进入目标，但 RuntimeViewerServer.framework 本身**还是无法通过 dlopen 加载进去**。

**这是这个方案的根本挑战**。三个可能的应对：
1. **Server-in-payload**：把 RuntimeViewerServer 的功能直接编进 loader dylib，remap 时一起进入。缺点：loader 不再自包含，涉及 __DATA、__la_symbol_ptr、完整 Mach-O，工程量爆炸——退回到「完整 Mach-O loader」问题。
2. **多阶段 remap**：注入器进程里 dlopen RuntimeViewerServer.framework，然后**分段** remap（`__TEXT` + `__DATA` + `__LINKEDIT`），loader 端手动执行 constructor list。核心难点：目标里的 `__la_symbol_ptr` 指向 shared cache 函数—**跨进程有效**（因为 slide 一致）；rebase 相对内部符号——remap 后的段间偏移必须与源一致（要求 remap 时用 `VM_FLAGS_FIXED` 分别放到相对偏移正确的地址）。可行，但工程复杂。
3. **走 Apple 官方路径**：sandbox extension **class** 可能不止 `APP_SANDBOX_READ`。Apple 内部可能有仅授给 `com.apple.dt.RemoteInjection` 的 extension class（如 `com.apple.dt.RemoteInjection.file-map-executable`）。IDA 里 DVTInstrumentsFoundation 只看到 `APP_SANDBOX_READ`，但 Apple 也许在其它 code path 里发别的 class。这条需要更深入的 IDA 挖掘（特别是 launchd/xpcproxy 端发放的 extension）。

**下一步调研** —— **已完成**（M1/M2 里程碑，详见 `ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md`）。方案 2 的分段 remap **已被 POC 决定性证明可行**：多段 remap + `adrp+add` 跨段配置槽 + `pthread_create_from_mach_thread` bootstrap 让 Swift `@_cdecl` 入口在 sharingd 内成功执行并发出 `REMAP_POC_M2: os_log fired from pid=32991` marker（sharingd 存活、无 crash、Foundation + os_log 全线通）。

**方案 3（Apple 官方 extension class 深挖）**未进一步投入，作为长期备选。

### R4：Apple 系统更新可能改变 seatbelt profile

**风险**：sharingd 的 profile 白名单未来可能扩展/收窄。

**mitigation**：策略是「用一次调查一次」——不硬依赖当前 profile 具体内容，只在攻克方案上依赖 mach_vm_remap 绕过文件系统的机制层假设。

## 决策点：Phase 2 工程化范围与顺序

R3 前置实验已通过（M1/M2 决定性 PASS，M3 定位到 libobjc register 是最后一个 blocker）。Phase 1 POC 阶段结束，**方案 2（多段 remap + reslide + libobjc register）**被证明可行，进入 Phase 2 工程化。

组件 A/B/C/D 的**内部职责列表**已在上述 "组件 B → 内部实现职责" 一节完整给出（多段 remap / chained-fixup parser / reslide / `_dyld_objc_notify_register` / Swift metadata register / `__mod_init_func` replay）。这里只列**时间顺序**：

- **Phase 2.a** —— 在现有 POC 目录里独立跑通 mini-dyld 层（chained-fixup parser + libobjc register + Swift metadata register + `__mod_init_func` replay），拿到"Swift 用户类 + Task { } 在 sharingd 内成功执行"的决定性证据。**这一步是 M3 收尾**，不动 MachInjector
- **Phase 2.b** —— 把跑通的 mini-dyld 层作为 `MIMachInjectorRemap` API 上游到 MachInjector 仓，caller 透明
- **Phase 2.c** —— `RuntimeViewerServer` 侧加 `runtime_viewer_server_start` exported entry（不动 constructor 保持 dlopen 路径行为不变）
- **Phase 2.d** —— App 端 `SandboxProbe.isStrictSeatbeltDaemon` 分流 + Helper 端 `InjectionService` 路由 + UI + 端到端验证

**Phase 2.a 需要在新 session 冷启动做**——mini-dyld 是新战场（chained-fixup 格式、`_dyld_objc_notify_register` 私有 ABI），冷思路推更高效。

**方案 3（Apple 官方 extension class）**未投入，长期备选。
