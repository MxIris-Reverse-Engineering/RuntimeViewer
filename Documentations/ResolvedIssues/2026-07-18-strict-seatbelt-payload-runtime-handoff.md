# Strict-seatbelt payload runtime handoff 抽离到 MachInjector loader

**日期**：2026-07-18
**背景**：`RuntimeViewerServer.framework` 通过 `MIMachInjectorRemap` 注入 `sharingd` 已经打通（见 `Documentations/ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md`）。当时 `main.m` 里手写了一大段 runtime handoff 逻辑——replay dyld 的 `map_images` + `swift_register*` 通知——用来告诉 target 里的 libobjc / libswiftCore 新 image 已经存在。本次把这段逻辑从 payload 抽到 `MachInjector` 的 loader 里，让 payload contract 回到最朴素的 `void *(*)(void *)`。
**依赖**：
- `Documentations/ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md`（POC 里程碑 M1–M3）
- `Documentations/ResolvedIssues/2026-07-14-seatbelt-daemon-injection-socket-fallback.md`（strict-seatbelt daemon 的历史 workaround）

## 动机

打通注入后的第一版 `RuntimeViewerServer/main.m` 长这样（截取要点）：

- 复刻 `MIMachInjectorRemapPayloadConfig` 结构、`_dyld_objc_notify_mapped_info` 结构、arm64e block layout。
- 手动 sign `mark` block 的 `invoke` 字段（`ptrauth_sign_unauthenticated` + `blend_discriminator`）。
- 手动 sign 从 injector 传下来的 raw function pointer（strip 后 IA+0 重签）。
- 顺序 `map_images` → `swift_registerTypeMetadataRecords` → `swift_registerProtocols` → `swift_registerProtocolConformances`，然后 tail-call `swift_initializeRuntimeViewerServer`。

问题：每一个未来的 payload 都要复制粘贴这套逻辑；任何 Apple 侧 ABI 微调（`map_images` signature、`_dyld_objc_notify_mapped_info` layout、Swift register API 数量）都得同步改所有 payload。这套逻辑跟 payload 本身的业务无关，属于 injection 机制的固有职责，应该由 `MachInjector` 承担。

## 设计

把 handoff 移进 loader 后，payload contract 缩到最小：

```c
// 唯一要求：签名 void *(*)(void *)
void *my_payload_entry(void *arg) {
    (void)arg;              // loader 已完成 runtime handoff
    my_real_initializer();  // 直接开始业务
    return NULL;
}
```

`RuntimeViewerServer/main.m` 相应从 167 行简化到 48 行：只保留 constructor（配 `RUNTIMEVIEWERSERVER_SKIP_CONSTRUCTOR` env-var 门）和一个转发到 `swift_initializeRuntimeViewerServer` 的 `runtime_viewer_server_start`。

### 为什么 handoff 要在 pthread 里跑，不能在 raw mach thread 里做

Stage1 asm 里 `apply_fixups` 跑完就在原地做 `map_images` 是最简单的写法，但**不能这么做**。原因：libobjc 的 `map_images` 路径会：

- 拿 `runtimeLock`（pthread mutex）
- 首次走 `preopt_init()`（`dispatch_once`）
- 通过 `sel_registerNameNoLock` 用 pthread TLS

raw mach thread 没 TLS。这些调用不会立刻崩，但会**静默走错分支**——`map_images` 会 return 但 `__objc_selrefs` 不会被 uniquify。symptom 是 payload 后续第一个 `dispatch_once + objc_msgSend` 触发 `+[NSBundle (dynamic selector)]: unrecognized selector sent to class 0x...`，位置离真正的 root cause 十万八千里。

正解：stage1 只做 `apply_fixups`，用 `pthread_create_from_mach_thread` 起 pthread，start_routine 指向 loader 内的 `pthread_thunk`。thunk 里做 handoff，再 tail-call 真正的 payload entry。

### 结构

新拓扑（对比 POC 时的"在 raw mach thread 里 handoff"和第一版"在 payload 里 handoff"）：

```
stage1_entry (raw mach thread, in loader __TEXT):
  apply_fixups()                                         ← Phase 1: 目标 PAC keys 重签 payload chained fixups
  pthread_create_from_mach_thread(_, _,
      pthread_thunk,                                     ← Phase 2: start_routine 是 loader 里的 thunk
      config)                                            ←          （不再是 cfg_pthread_start_addr）
  spin

pthread_thunk (in pthread, has TLS, in loader __TEXT):
  perform_runtime_handoff(config)                        ← libobjc runtimeLock / dispatch_once / TLS 都可用
  entry = sign(cfg_pthread_start_addr, IA + 0)
  return entry(config)                                   ← tail-call payload entry
```

payload entry（`runtime_viewer_server_start`）拿到控制权时，`__objc_selrefs` 已经 uniquify，Swift 元数据已经 register。它只需要做业务初始化——本例是 `swift_initializeRuntimeViewerServer`。

### `perform_runtime_handoff` 里的 PAC 细节

`loader_arm64_remap_handoff.c` 里两个 ptrauth 关键点：

1. **给函数指针签名（IA + const 0）**。injector 侧调 `ptrauth_strip` 得到原始 raw addr 写进 `config`，target 侧要再签一次 payload 才能 `blraaz` 过去。
    ```c
    MIRemapMapImagesFunction mapImages =
        (MIRemapMapImagesFunction)__builtin_ptrauth_sign_unauthenticated(
            (void *)(uintptr_t)config->mapImages, ptrauth_key_asia, 0);
    ```

2. **给 block invoke 签名（IA + addr_diverse + const 0）**。clang 对 block invoke 存储位置默认 schema 是 `PointerAuthSchema(ASIA, addr_diverse=true, Discrimination::None)`。libobjc 里 `mark(idx)` 调用点用 `blend(&block->invoke, 0)` 做 modifier `autia`。我们在栈上手搓 block layout，`invoke` 用同一 schema 签：
    ```c
    markBlock.invoke = __builtin_ptrauth_sign_unauthenticated(
        __builtin_ptrauth_strip((void *)MIRemapHandoffMarkInvoke, ptrauth_key_asia),
        ptrauth_key_asia,
        __builtin_ptrauth_blend_discriminator(&markBlock.invoke, 0));
    ```
    `strip` 那步是必要的：`(void *)funcName` 在 arm64e ABI 下会走 `paciza` 隐式签名（把函数名当 R-value 用），已经是签过一次的指针；不 strip 就等于在 signed pointer 上再 sign，authenticate 时必然对不上。

3. `mark` block 的 `isa` / `descriptor` 都不被 libobjc 在这条 hot path 上 deref（objc4 `objc-runtime-new.mm:4200` 里 `mark(idx)` 只用 `invoke`），所以 `isa=NULL` + `descriptor=&fileprivate-const-struct` 是安全的，不用拉进 `_NSConcreteGlobalBlock` 或 blocks runtime helpers。

## 实施

- **`Sources/MachInjector/loader_arm64_remap.s`**：Phase 2 的 pthread_create start_routine 从 `_cfg_pthread_start_addr` 改成 loader-internal `_pthread_thunk`。`_cfg_pthread_start_addr` 保留，它现在存"真正的 payload entry raw addr"。
- **`Sources/MachInjector/loader_arm64_remap_handoff.c`**（新文件）：
  - `pthread_thunk` — start_routine 入口，跑 handoff 后 tail-call 真 payload entry。
  - `perform_runtime_handoff` — map_images 优先，然后 swift_register*。顺序跟 dyld 自己一致（DyldRuntimeState.cpp）。
  - `MIRemapHandoffMarkInvoke` — mark block 的 no-op invoke。
- **`Sources/MachInjector/MIMachInjectorRemap.h`**：更新 payload contract 注释，示例代码改成新的最小签名。
- **`Sources/MachInjector/MIMachInjectorRemap.m`**：把 handoff 相关的 14 处 `os_log_error("MIRemap.diag ...")` 降级为 `os_log_debug`——注入成功后默认不再刷日志，需要 debug 时用 `log stream --predicate 'subsystem == "com.mxiris.machinjector.remap"' --level debug` 打开。
- **`Sources/MachInjector/build_loader.sh`**：input 加上新的 `loader_arm64_remap_handoff.c`；注释同步。
- **`RuntimeViewer/RuntimeViewerServer/RuntimeViewerServer/main.m`**：删除全部 mirror struct、PAC signing、map_images / swift_register 调用；只留 constructor（带 env-var 门）和 3 行 `runtime_viewer_server_start`。

## 排查过程中的坑（未来提醒）

1. **改 loader 后必须确认 RuntimeViewer 引的是本地 MachInjector Package**。`RuntimeViewer.xcworkspace` / `RuntimeViewer-Debug.xcworkspace` 要把 MachInjector 加成本地 Package Dependency（sibling `/Volumes/Repositories/Private/Personal/Library/macOS/MachInjector`），Xcode Package Dependencies 里应该看到 "MachInjector (local)"。否则 `RunScript.sh` 会拉远端 SPM tag，本地 `Sources/MachInjector/*.c` / `*.s` / `build_loader.sh` 生成的 `loader_arm64_remap_dylib.h` 全部对 injector 不可见——症状是"改 loader 后 sharingd 崩溃日志跟没改一模一样"。这次因此浪费两轮排查才发现根因。
2. **`build_loader.sh` 生成的 `loader_arm64_remap_dylib.h` 不在 Xcode 的 header dep graph 里**。即使本地引用生效，只跑 `build_loader.sh` 不足以让 Xcode 重编 `MIMachInjectorRemap.m`——必须 `touch MIMachInjectorRemap.m`（或 clean），否则 `.m` 保留旧 shellcode bytes。
3. **first crash 症状 `+[NSBundle (dynamic selector)]: unrecognized selector`** 一般不是 NSBundle 或 Swift Foundation 里真的少了什么，而是 payload `__objc_selrefs` 没被 uniquify 的信号。倒推方向：`map_images` 是不是根本没调（loader 版本不对 / stage1 asm 没到 Phase 2）→ 是不是在 raw mach thread 里调了（回到本次结论：必须在 pthread 里）→ mark block invoke 签名是不是错了（是不是 double-sign 了）。

## 验收

- `sudo rm -rf /Library/Frameworks/RuntimeViewerServer.framework`
- `sudo launchctl kickstart -k system/dev.arm64e.mxiris.runtimeviewer.service`
- 启 RuntimeViewer 主 app → 触发 sharingd 注入 → app 内 outline 出现 sharingd 的 Objective-C 类清单（Foundation / SharedFramework / 各种私有 SDK 的 mangled 名字）。sharingd 无 crash，`consecutiveCrashCount` 停在触发注入前的旧值不再增长。

## 关联

- `Documentations/ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md` — 基础机制的 POC 里程碑。
- `Documentations/ResolvedIssues/2026-07-16-sharingd-sandbox-injection-investigation.md` — 为什么 dlopen 路径不通、为什么要走 mach_vm_remap。
- MachInjector 侧同名设计文档：`MachInjector/Documentations/Design/StrictSeatbeltPayloadRuntimeHandoff.md`。
