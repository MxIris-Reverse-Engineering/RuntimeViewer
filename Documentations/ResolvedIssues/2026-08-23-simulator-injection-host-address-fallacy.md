# 注入 iOS Simulator 进程：宿主的地址不能喂给目标

**日期**：2026-08-23
**相关提案**：[0014 支持注入 iOS Simulator 进程](../Evolutions/0014-inject-ios-simulator-process.md)
**涉及仓库**：RuntimeViewer、MachInjector

原始症状是「注入模拟器进程会把目标打崩」，一连打崩三个 SpringBoard。根因只有一句话，
但它有三个各自独立的变体，**每一个都能单独让注入失败，且失败的样子彼此不同**。
本文记录这三个变体、区分它们的判据，以及排查过程中那些会把人带偏的诊断陷阱。

代码里看不出来的部分都在这里；能从代码读出来的部分不重复。

---

## 一、根因：注入器的地址空间不是目标的地址空间

`MIMachInjector` 原本用 `dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread")` 取符号地址，
写进 shellcode 交给目标执行。对同一台 Mac 上的另一个 **macOS** 进程，这碰巧成立：
两者映射同一份 dyld shared cache、slide 相同，宿主算出的地址在目标里就是对的。

模拟器进程不满足这个前提。它由 `dyld_sim` 加载、映射的是模拟器 runtime 自带的
shared cache，与宿主的 cache 完全无关。宿主的地址喂过去，落在目标地址空间里的任意位置，
shellcode 跳过去当场崩。

### 判据：`lr - pthread_create_from_mach_thread = 4`

崩溃报告里出现这个偏移，说明 shellcode **确实跳到了它以为的那个函数**，
而那个地址在目标里不是那个函数。这条判据是分辨「地址错了」与「其他崩溃」的最快方法，
下次遇到类似崩溃先算这个差值。

---

## 二、变体一：宿主偏移 + 目标基址 —— 看起来对，实际偏 0x6f8

修根因时最自然的想法是：宿主 `dlsym` 地址减宿主镜像基址得到偏移，再加目标镜像基址。
**这是错的**，而且错得很隐蔽。

`/usr/lib/system/libsystem_pthread.dylib` 的 arm64 与 arm64e 两个 slice 里，
`_pthread_create_from_mach_thread` 的偏移**不同**：

| slice | 偏移 |
|---|---|
| arm64e（注入器用的，宿主 cache 里那份） | `0x847c` |
| arm64（模拟器进程用的） | `0x7d84` |

差 `0x6f8`。算出来的地址落在函数体**中间**，跳过去照样崩，而症状与「地址完全解析错」
难以区分 —— 评审阶段看不出来，只在实现后发作。

**正确做法**：解析**目标进程内存里**那份 Mach-O 的 `LC_SYMTAB` 求偏移。
不依赖宿主状态，也不必假设目标 map 的是 cache 还是磁盘文件。
落地在 `MITargetSymbolResolver`（MachInjector）。

### 解析目标符号表时的两个坑

- **不能一次读整张字符串表**。cache 内镜像的 `strsize` 是整个 cache 的共享字符串表，
  实测 387 MB；按符号索引范围开窗口也没用，跨度同样 378 MB（名字在表里是打散共享的）。
  改为**按需逐符号读**：算出该符号的 `stroff + n_strx`，只读要比较的那几十个字节。
- **`dyldPath` 不能用来判断目标是不是模拟器进程**。模拟器进程读出来是宿主的
  `/usr/lib/dyld`。要判断就看镜像路径里有没有 `/RuntimeRoot/` 或 `.simruntime/`。

### `TASK_DYLD_INFO` 拿到的是哪一份

实测（iOS 18.5 模拟器的 `peopled`）：拿到的**就是 `dyld_sim` 维护的那一份**，
580 个镜像里 576 个属于模拟器 RuntimeRoot，剩下 3 个宿主镜像恰好是
`libsystem_platform` / `libsystem_kernel` / `libsystem_pthread`。
`sharedCacheBaseAddress = 0x180000000`、slide 为 0 —— **但 slide 仍须从进程读取**，
不要因为实测是 0 就写死。

---

## 三、变体二：payload 切片平台不对

符号解析修好之后，注入不再打崩目标，改为目标返回一个正常的 `dlopen` 拒绝。
原因是投递过去的仍是 **macOS slice**。

**这一条无法从架构上看出来**：Apple silicon 上，macOS 进程和 iOS Simulator 进程
`cputype` 相同（都是 arm64），只有 `LC_BUILD_VERSION` 的 `platform` 不同
（macOS = 1，iOS Simulator = 7）。所以：

- 判断目标要什么切片，**只能读 `LC_BUILD_VERSION`**，架构、路径都不够
  （路径尤其不行：RuntimeRoot 前缀只认得出模拟器自带的系统 daemon，
  用户自己装的 app 跑在设备 data 容器里，没有这个标记）。
- 两个切片**不能合并成一个 fat binary** —— 同架构不同平台正是 fat 格式无法表达的情况，
  这也正是 `.xcframework` 要拆成多个文件的原因。

落地为 `InjectionTargetPlatformProbe`（目标**是**什么）与 `PayloadPlatform`（我们**能给**什么）
两个类型，刻意分开：两者之间的缺口就是显式拒绝的位置。tvOS / watchOS / visionOS 模拟器进程
是完全可读的目标但没有对应切片，如实报错 —— 而不是把最近的切片交给 dyld 去拒，
那正是打崩进程的老路。

### 投递路径：`/Library/Frameworks` 可以用

一度以为 `dyld_sim` 会把 `/Library/Frameworks/...` 劫持到 RuntimeRoot 下、投递路径必须换地方。
**这个判断是错的**，实测推翻：

`dyld_sim` 对**任何**绝对路径都按同一顺序尝试：

1. `<RuntimeRoot>` + 原路径
2. **原路径本身（宿主视图）**
3. `.framework` 路径额外再试 `<RuntimeRoot>/System/Library/Frameworks/<Name>.framework/<Name>`

测了 `/Library/Frameworks`、`/System/Library/Frameworks`、`/usr/lib`、`/Users/Shared`、
`/tmp`、`/Volumes/…`、`/Applications` 七个前缀，行为一致。**投递目录的选择是自由的。**

复现方法（无副作用，路径都不存在，什么都不会被加载）：

```bash
lldb --batch -p <模拟器进程 pid> \
  -o "settings set target.max-string-summary-length 8192" \
  -o 'expr (void*)dlopen("/Library/Frameworks/Probe.framework/Probe", 2)' \
  -o "expr (char*)dlerror()" \
  -o detach -o quit
```

### payload 必须由 build phase 嵌入，不能事后拷进 .app

`Contents/Resources` 下的一切都被 app 的代码签名 seal，**签完再塞文件会让签名失效**，
进而破坏 `SMAppService` 的 daemon 注册（这个后果不明显，但很难反查）。

它也**不能**建模成 target dependency —— Xcode 把 iOS-family framework 视作 macOS app target
拒收的嵌入内容，与 Mac Catalyst helper 是同一个约束。所以顺序由 `RunScript.sh` /
`ArchiveScript.sh` 保证：先构建 `RuntimeViewerMobileServer`，再构建主 app，
路径通过 `RUNTIME_VIEWER_SIMULATOR_PAYLOAD_PATH` 显式传给 build phase
（**`BUILD_DIR` 在 `xcodebuild archive` 下不可靠**，archive 会重定向产物路径）。

---

## 四、变体三：会话建立走错了通道

宿主的 attach 流程原本是「先起一个 client engine → 注入 → 确认 payload 连回来」。
模拟器 payload 不会连回来：它的 transport 是**编译期**决定的，永远走 Bonjour
（见 `RuntimeViewerServer.main()`）。宿主准备的 XPC / socket 端点没人拨，
attach 超时，而超时提示说的是沙盒问题 —— 与真实原因完全无关。

**但这里不需要新的通道代码**：payload 一广播，宿主里本来就在跑的 Bonjour browser 就连上了。
要改的只是「别再去建那条用不上的 engine」。落地为 `AttachToProcessViewModel` 按 payload 平台
分成 `attachToLocalProcess` / `attachToSimulatorProcess`，后者注入完直接等
`RuntimeEngineManager.awaitInjectedBonjourEngine`。

匹配用 **pid**，不用服务名：模拟器进程是宿主的真实进程，payload 在 TXT 记录里发布的 pid
就是被注入的那个。端点键形如 `{deviceID}-{pid}`，而 deviceID 是**含短横线的 UUID**，
所以取最后一个 `-` 分段比较，不要写成后缀匹配。

---

## 五、诊断陷阱 —— 三次把排查带偏的东西

这一节是本文最值得先读的部分。上面三个变体都能靠代码和实测查清楚，
下面这三件事**看起来像答案，其实是假象**。

### 1. 截断的诊断信息比没有信息更危险

`MIMachInjector` 的 dlopen report 原本只有 256 字节错误缓冲。dyld 的拒绝消息会列出
它试过的**每一条**路径，而单是一条模拟器路径就超过 200 字符 —— 256 字节恰好切在
**第一个**候选路径中间，只看得到 `<RuntimeRoot>/Library/Frameworks/…`。

据此一度判定「模拟器进程的文件系统视图不是宿主的」，进而认为投递路径方案被推翻。
实测证明完全相反（见上文）。**它看起来像一个完整答案**，这正是危险所在。

缓冲已扩到 2048 字节。report block 本来就是目标进程里一次独立的 `mach_vm_allocate`、
已经占满一页，在页内扩大字段零成本。

### 2. 模拟器进程的 os_log 不在宿主的 log store 里

payload 在模拟器进程里打的日志，宿主 `log show` **看不到**，要用：

```bash
xcrun simctl spawn <device-udid> log show --last 5m \
  --predicate 'eventMessage CONTAINS "RuntimeViewerServer"' --style compact
```

排查时「日志一条都没有」很容易被读成「payload 没跑起来」，实际只是查错了地方。
判断 payload 是否正常启动，看这三条是否齐全：
`Attach successfully` → `RuntimeViewerServer Will Launch` → `RuntimeViewerServer Did Launch`。

### 3. 不要拿 SpringBoard 判断「类型信息是否正常」

SpringBoard 是验证注入最直觉的对象，也恰好是最会误导人的：
它的主二进制只有 249 KB，**连 `__objc_classlist` 段都没有** ——
实现都在它加载的 SpringBoardHome / SpringBoardUI / SpringBoardFoundation 等框架里。
注入成功后主二进制显示为空是**正确结果**，不是故障。

用 `backboardd` 做对照：2.5 MB，`__objc_classlist` 0x558 字节（171 个类）。

---

## 六、排查顺序

遇到「注入模拟器进程失败」，按这个顺序走：

1. **目标还活着吗**。死了 → 多半是地址喂错或走了 remap 回退，算 `lr - pthread_create_from_mach_thread`。
2. **拿到目标的 `dlerror` 了吗**。拿到了说明 shellcode 在目标里**跑通了**
   （`pthread_create_from_mach_thread` → `dlopen` → `dlerror` → 写 report 四步都成），
   问题在 payload 本身，不在注入器。
3. **读完整的 `dlerror`**，不要只看开头 —— 见陷阱 1。
4. **确认投的是哪个切片**：`otool -l <payload> | grep -A2 LC_BUILD_VERSION`，
   模拟器目标要 `platform 7`。
5. **payload 起来了吗**：用 `simctl spawn ... log show` 查那三条 —— 见陷阱 2。
6. **起来了但没有类型信息**：先确认目标主二进制有没有 `__objc_classlist` —— 见陷阱 3。

---

## 七、验证状态（2026-08-23）

| 项 | 结果 |
|---|---|
| 产品路径注入模拟器 SpringBoard | 通过，目标存活 |
| 浏览 ObjC / Swift 接口 | 通过（`backboardd`，类型信息完整） |
| 同设备多进程并入同一 Section | 通过（`mobiletimerd` + `nanoprefsyncd`） |
| `SIMULATOR_UDID` 存在且同设备一致 | 通过 |
| arm64 目标上的 PAC 指令 | 通过 —— 无条件 PAC 签名的代码原样未改即成功 |
| 断开、重注入 | **未验** |
| 用户自己安装的 app（非系统 daemon） | **未验** |

### 两道纵深防御（`swift-helper-service`，2026-08-23 已实现）

- **平台守卫**：payload 的 `LC_BUILD_VERSION` platform 与目标的不相等时，注入前就拒绝。
  比较的是**这两者**，不是「与宿主平台是否一致」—— 后者会把注入模拟器进程本身挡掉。
  **读不到平台时不拦**：守卫是第二道防线，「看不清就拦下」会把每个解析不了的目标变成注入失败。
- **跨平台目标禁用 remap 回退**：目标平台与 daemon 平台不同时，dlopen 失败**不再**回退 remap，
  而是带着目标自己的拒绝理由如实报错，并说明为什么没有第二次尝试。
  调用方仍可显式 pin remap（否则这条路径修好后无从验证），但 daemon 会记一行「大概率会打死目标」。

被关掉的只是**回退**。dlopen 路径本身没动，它已经改成对着目标自己的符号表解析。
