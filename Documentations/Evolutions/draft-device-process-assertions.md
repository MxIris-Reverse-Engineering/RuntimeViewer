# Draft - 阻止进程被挂起：越狱版保活与注入 App

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-10-03
- **最后更新**: 2026-10-03
- **所属愿景**: 无
- **关联提案**:
  [draft-jailbroken-ios-injection](draft-jailbroken-ios-injection.md)（父提案：越狱版枚举并注入设备进程；它的非目标里「注入其它 App」这一条由本提案接走）、
  [draft-device-payload-reverse-connection](draft-device-payload-reverse-connection.md)（载荷反向连接；本提案不改动那条通道）
- **实现分支 / PR**: `feature/jailbroken-ios-injection`
- **配套文档**:
  [`DevicePayloadReverseConnection.md`](../DevicePayloadReverseConnection.md) 第八节（实现说明，本提案推翻了它原先的一条结论）、
  [`Guides/JailbrokenDeviceInjection.md`](../Guides/JailbrokenDeviceInjection.md)（使用指南，entitlement 表与能注什么都改了）

## 摘要

给越狱版 RV iOS 增加一条 RunningBoard entitlement，并用一条 `RBSLegacyAttribute`
（`reason = 4` / `flags = 1`）assertion 显式阻止进程被挂起。同一个机制解决两件事：

1. **保活** —— RV 自己切到后台不再被挂起，所以从 Mac 端点 Attach 之前不必先去设备上把 RV 切回前台；
2. **注入 App** —— 给目标 App 下一条同样的 assertion，让「启动过、现在挂在后台」的 App 就地恢复运行，
   于是它变成一个和 daemon 一样普通的注入目标。

关键结论是**注入 App 并不依赖保活**：assertion 的目标可以是别的进程，所以 RV 留在前台、把目标唤醒
再注入就够了。两件事合为一个提案是因为它们是同一个机制、同一批 entitlement，而不是因为互相依赖。

## 动机

### 两个卡点，同一个根因

父提案落地后，非 root daemon 已经能注入并浏览（`searchpartyd`、`mediaplaybackd`、`dasd`、
`chronod`、`sharingd` 五个实测通过）。剩下两件事都卡在同一处：**iOS 在 App 离开前台后一秒内把它挂起**
（实测 `running-suspended`，jetsam 优先级降到 0），而**挂起的进程没有被调度的线程**。

- **注入 App 必然超时。** 注入器在目标里建一条 mach 线程、等它回报 `dlopen` 的结果；目标被挂起就永远
  等不到。实测注入设置 App 必然走满 20 秒的裁决预算然后报超时。
  `RuntimeViewerPackages/Sources/RuntimeViewerDeviceInjection/RuntimeDeviceInjectionDiagnosis.swift`
  里那段超时文案就是专为这个失败写的，它现在只能让用户「把目标切到前台再试」—— 而那恰恰会把 RV 自己
  挤下前台，两件事互斥。
- **Attach 之前必须先管设备屏幕。** 使用指南
  [`Guides/JailbrokenDeviceInjection.md`](../Guides/JailbrokenDeviceInjection.md) 现在写着
  「越狱版必须是设备屏幕上正在显示的那个 App」，判据是设备屏幕而不是 macOS 的窗口焦点。这条对
  「在 Mac 上操作、设备只是个被观察对象」的用法是实打实的摩擦。

### 为什么现在能做了，而当时的判断只对了一半

实现说明
[`DevicePayloadReverseConnection.md`](../DevicePayloadReverseConnection.md) 的「已知不支持」
把注入其它 App 写成「**这是结构性的，不是偶发**」。前半句对：iOS 确实只给一个 App 前台。后半句是错的
—— 前台并不是进程能运行的唯一途径，RunningBoard 有一条显式的「别挂起这个进程」的通道，而它的闸是
**纯 entitlement**，没有第二道校验。本提案推翻那条结论的后半句，并在同批次改掉那段文字。

## 前期调研

全部读自 `/Volumes/DyldSharedCaches/iOS/26.3.1/dyld_shared_cache_arm64e`
（`swift-section objc dump` 导出的头在同目录各框架的 `ObjCHeaders/` 下，IDA 库在
`RunningBoard/RunningBoard.i64`）。地址都是该 cache 的未滑移地址。

> **版本差异（已知风险）**：测试机是 **26.6.2**，本节结论全部来自 **26.3.1**。点版本，接口大概率一致，
> 但**没有实测**。方案据此把「API 不存在」和「权限被拒」设计成两种可区分的失败，见「详细设计」。

### 「运行 vs 挂起」就是一个布尔值

RunningBoard 把进程状态里的 `RBProcessState.preventSuspend` 当作唯一判据。只有四个 attribute 覆写
`preventsSuspension`：`RBSCPUAccessGrant`、`RBSDebugGrant`、`RBSDefineRelativeStartTimeGrant`、
`RBSLegacyAttribute`。其中 `RBSCPUAccessGrant` 是**无条件**成立的：

```c
// -[RBSCPUAccessGrant(RBProcessState) preventsSuspension]   @ 0x266C8EFD0
return true;

// -[RBSCPUAccessGrant(RBProcessState) applyToProcessState:attributePath:context:]   @ 0x266C927D0
if (self.role > processState.role) { processState.role = self.role; }
[processState setPreventSuspend:1];
```

注意 `RBSSuspendableCPUGrant` **不在**那四个里面 —— 名字相近，语义相反，别拿错。

### ⚠️ 本节以下关于 `RBSCPUAccessGrant` 的结论在真机上被证伪

**初稿认为闸只有一条 entitlement。错了，而且这条路根本走不通。** 完整更正见后面的
「真机证伪与改道」一节；保留原文是因为它解释了方案最初为什么长成那样。

`RBSCPUAccessGrant` 的校验直接转给 primitive attribute 那条通用闸：

```c
// -[RBSCPUAccessGrant(RBProcessState) isValidForContext:withError:]   @ 0x266C92854
return [RBSAttribute allowedForPrimitiveAttributeForProcessTarget:context withError:error];

// +[RBSAttribute(RBProcessState) allowedForPrimitiveAttributeForProcessTarget:withError:]   @ 0x266CC21F8
if (context.targetIsSystem) → 拒：“Attribute is not applicable to system target”
if (context.ignoreRestrictions) → 放行
if ([context.originatorEntitlements rb_hasEntitlement:@"com.apple.runningboard.primitiveattribute"]) → 放行
否则 → RBSAssertionErrorDomain code 2，“Required client entitlement is missing”
```

完整校验链在 `-[RBAssertionDescriptorValidator isAssertionValidForContext:error:]`（`0x266cdfb24`）：
attribute 非空 → 每条 attribute 自己的 `isValidForContext:` → 若以 **identity** 为目标还要
`com.apple.runningboard.targetidentities` → 冲突检查。**按 pid 为目标不需要那条额外的。**

domain 位掩码到 entitlement 名的完整映射表在 `+[RBEntitlements _entitlementsForOption:]`
（`0x266c90ebc`），本提案用到两位：

| domain | entitlement（任一即可） | 本提案用途 |
|---|---|---|
| — | `com.apple.runningboard.primitiveattribute` | 下 assertion。**必需** |
| 1 | `com.apple.runningboard.process-state`、`com.apple.assertiond.app-state-monitor`、`com.apple.multitasking.termination` | 查别的进程是否真的醒了 |
| 2 | `com.apple.runningboard.launchprocess`、`com.apple.assertiond.system-shell`、`com.apple.private.xpc.launchd.app-server` | 冷启动没跑过的 App（**本次非目标**） |

### 自己给自己下 assertion 不会循环失效

这是最该担心的一点 —— 如果 RV 被挂起时它自己持有的 assertion 也跟着失效，就是死循环。实际不会：

```c
// -[RBAssertionResolutionContext _suspendOrResumeAssertionsForTarget:oldState:newState:]   @ 0x266CD7784
// 只在 preventSuspend 翻转时动作，且只处理标了 suspendsOnOriginatorSuspension 的 assertion
```

而 CPU grant 不置那个标志 —— `applyToAssertionIntransientState:`（`0x266C92848`）全文只有
`[state setPreventsSuspension:1]`。再加上 RV 持有它之后永远不会变回「可挂起」，那条分支根本不会触发。

### 后台 socket 不会被掐（一条被证伪的担心）

`RBSAppNapPreventBackgroundSocketsGrant` 的存在让人怀疑后台进程的 socket 会被抑制 —— 那会直接废掉
反向连接。实测该类在 iOS 上的 `applyToProcessState:`（`0x266CA1CDC`）是**空实现**，
`RBProcessState` 也只有一个 `throttleBestEffortNetworking`（节流，不是阻断）。风险排除。

### SDK 没有可链接的 stub

```
$ find $(xcrun --sdk iphoneos --show-sdk-path) -name "RunningBoardServices*"
（无输出）
```

iPhoneOS 27.0 SDK 既没有 `RunningBoardServices.framework`，也没有任何 `.tbd`。
`BackBoardServices`、`FrontBoardServices` 同样没有。**所以链接这条路不存在**，封装必须经
Objective-C 运行时取类。这直接决定了「详细设计」里为什么要新增一个 ObjC 声明 target、
以及为什么 Swift 侧一个字母都不能静态引用 `RBSAssertion`。

### 真机证伪与改道（2026-10-03，第一次装机之后）

第一版装到 26.6.2 上，**越狱版切到后台照样断连**。实测：

| 指标 | RV JB | `sharingd` / `backboardd` |
|---|---|---|
| 12 秒 CPU 增量 | **0.0000 秒** | 有增量 |
| jetsam band | **0** | 30 |

也就是 assertion 根本没拿到。根因不在检查点，在**构造** `originatorEntitlements` 的那一步：

```c
// -[RBEntitlementManager _entitlementsForProcess:]   @ 0x266ce6424
//   取 SecTask → 按 _availableEntitlements 逐条提取 → 然后：
//   -[RBEntitlementManager _removeRestrictedEntitlements:forProcess:]   @ 0x266ce66cc
//
// 对每一条 entitlement，查 _restrictedEntitlements[该条] 得到一份"允许的身份"集合；
// 集合存在且不含本进程身份 → 剥掉，并打 fault：
//   "RunningBoard: Process %{public}@ does not have permission to have entitlement %{public}@"
```

`_restrictedEntitlements` 来自 `/System/Library/RunningBoard/runningboardEntitlementsConfiguration.plist`
（`restrictedEntitlementsFromPlist()` @ `0x266ca0ce4`）。**从设备上读了这个文件**：它是一张按
bundle id 的白名单，`com.apple.runningboard.primitiveattribute` 的允许身份是
`com.apple.SpringBoard`、`com.apple.backboardd`、`com.apple.dt.XcodePreviews`、CarPlay 两个、
以及若干 internal 的 `*Board` 工具 —— 共十余个 Apple 身份。**第三方没有任何办法进入这份名单。**
把这条 entitlement 签进二进制毫无作用，实测也确实毫无作用。

**改道：`RBSLegacyAttribute`。** 它是旧 `BKSProcessAssertion` 的桥，同样能 `preventsSuspension`，
但走的是完全不同的校验路径（`_isOriginatorValidForContext:` / `_isTargetValidForContext:`），
不碰那份白名单。选 `reason = 4`（`FinishTask`）、`flags = 1`（`PreventSuspend`）：

- `preventsSuspension` 是 `_role > 1`，而 `flags & 1` 时 `_role == 2`（`0x266CE2BD0` / `0x266c8bd34`）
- **自己对自己：originator 校验一条 entitlement 都不查**（`0x266ce2bf0`，reason 4 且 originator == target
  时直接通过）
- **目标是别的进程**：要求 originator 是 platform binary 或持有 entitlement **domain 63** 中任意一条；
  `rb_hasEntitlementDomain:` 是「任一位命中即真」，而 `com.apple.runningboard.process-state`
  正在 domain 1 里，**且它不在受限表中**
- 目标侧校验对 reason 4 只拒「系统目标」（`0x266ce3088`）
- jetsam band 由它自己给：reason 4 + flags 1 → **band 40**（`_explicitJetsamBand:` @ `0x266ce2a24`），
  高于守护进程的 30，所以**不再需要单独的 `RBSJetsamPriorityGrant`** —— 加了反而会让这条
  assertion 重新变成 primitive attribute，正好撞回被封的那道闸

净效果：**`primitiveattribute` 从 entitlement 清单里删掉**，entitlement 从五条回到四条，而
`process-state` 从「诊断用的锦上添花」升级为**注入 App 的必要条件**。

**仍未验证**：reason 4 是「有限时长任务」（runningboardd 里有 `_isLegacyReasonFinishableTask:`），
所以它**可能会到期**。到期就要续期。这一条只能在真机上量 —— 持有后盯目标进程的 CPU 增量，
看它保持非零多久。

### 旧门面已经没了

`BKSProcessAssertion` 在 iOS 26 的 `BackBoardServices` 里**不存在** —— 整个框架里一个 process
assertion 类都没有（`BackBoardServices/ObjCHeaders/BackBoardServices.h`，只剩 HID 事件延迟和
触摸策略那几类 assertion）。网上能搜到的保活配方基本都是基于它的，全部作废。

### 现状代码的落点

- `RuntimeViewerPackages/Sources/RuntimeViewerDeviceInjection/RuntimeDeviceInjectionService.swift:90`
  —— `inject(intoProcessWithIdentifier:rendezvous:)`，现在是「确认活着 → 暂存载荷 → `MachInjectorAsync`」。
  assertion 要插在暂存之后、注入之前。
- `RuntimeViewerPackages/Sources/RuntimeViewerDeviceInjection/RuntimeDeviceProcessEnumerator.swift:162`
  —— 可注入性预筛。**不需要改**：它对 App 本来就返回 `.injectable`，让尝试本身当权威
  （注释原文「anything unknown resolves to `.injectable` so the attempt is what reports it」）。
  本提案是让那个尝试真的能成功，不是改判定。
- `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/RuntimeEngineManager.swift:640`
  —— `terminateRuntimeEngine(for:)`。**这是释放 assertion 的唯一挂点**，因为所有拆引擎的路径都汇到它：
  `terminateInjectedDeviceEngine(name:rendezvous:)`（attach 失败回滚）走它，CLI 的
  `runtime-viewer-cli detach` 经 `SourceCatalog.swift:173` 也走它。它本来就有按 source 种类分的清理分支
  （`.bonjour` 重连记账、`.localSocket` 的 `removeInjectedSocketEndpointRecord(pid:)`），加一条
  `.injectedTCP` 的正好同构。
- **AppKit 侧没有 Detach 入口**，`RuntimeProcessAttacher.detach(_:)` 也只有 Mac 与模拟器两条分支、
  没有设备分支。Detach 今天是 CLI 独有的动作 —— 这不是本提案造成的，也不在本提案范围内。
- **设备侧没有「释放」这条命令**，注入相关的命令只有三条（`InjectionCapabilityRequest` /
  `ProcessListRequest` / `InjectIntoProcessRequest`，见
  `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+InjectionRequests.swift`）。
  所以要加第四条，见「提议方案」。
- `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit-Jailbroken.entitlements`
  —— 手写的三条 entitlement，ad-hoc 签名。该文件的注释已写明安装方式会原样保留 entitlement，
  所以**加条目的成本就是加几行 plist**。
- `RuntimeViewerPackages/Sources/RuntimeViewerProcessEnumerationSupport`
  —— 既有先例：「iOS SDK 不给的 libproc 声明」自成一个 ObjC target。本提案照这个形状加一个。

## 提议方案

### 一、一条新 entitlement

`RuntimeViewerUsingUIKit-Jailbroken.entitlements` 从三条变四条：

- `com.apple.runningboard.process-state` —— 两个用途：查目标进程是否真的离开了挂起态，
  以及**让 assertion 能以别的进程为目标**（它在 domain 63 里，而 legacy attribute 的 originator
  校验要的就是这个）。没有它，越狱版只能保活自己，注入 App 仍然不可能

初稿还要加 `com.apple.runningboard.primitiveattribute`，**那条已删** —— 它是受限 entitlement，
签了也会被 runningboardd 剥掉，见「真机证伪与改道」。

### 二、`RuntimeViewerRunningBoardSupport`：声明私有接口的新 target

因为 SDK 无 stub，这个 target 做两件事：用 `@protocol` 声明要用的那几个接口（**不声明 `@interface`**，
避免产生类符号引用），再提供一个极小的 ObjC 工厂 —— 构造 assertion 需要三参数的
`initWithExplanation:target:attributes:`，Swift 的 `perform` 最多两参数，所以这一步必须在 ObjC 里做。

### 三、两层 Swift 封装：能力与策略分开

- `RuntimeDeviceSuspensionAssertion`（iOS only）—— 持有令牌，`deinit` 即失效。能力层。
- `RuntimeDeviceSuspensionController`（**不按平台 gate**）—— 按 pid 引用计数、决定何时取何时放。
  策略层，获取 assertion 这一步经协议注入，所以 Mac 上有 test runner 能把全部时序跑出来。
  这和 `RuntimeDeviceProcessEnumerator` 把 `injectorUserIdentifier` 作参数传入是同一个手法，
  理由也一样：iOS 侧既没有 test runner 也没有办法让构建失败。

### 四、注入流程插一步

`inject(intoProcessWithIdentifier:rendezvous:)` 变成：确认活着 → 暂存载荷 →
**取 assertion → 确认目标离开挂起态** → 注入 → 失败则释放 assertion、成功则移交给控制器持有。

### 五、新增第四条注入命令

`StopKeepingProcessAwakeRequest`，因为设备侧原本没有「释放」这条路可走（见「前期调研」最后一条 ——
提案初稿把这点写错了）。它和既有三条同在 `registerSharedHandlers`，所以经 ProxyServer 转发自动可用。

`RuntimeInjectionService` 上对应新增一个**带默认空实现**的方法，所以 macOS 那套 helper daemon 实现和
模拟器实现一个字都不用改 —— 对它们来说「让进程保持能运行」本来就不需要做任何事。

### 六、RV 自己：启动即常开

越狱版启动时对自己取一条同样的 assertion，永不释放。取失败只记日志并降级（和现在「缺三条 entitlement
就注入不了」一致），不弹窗。

### 非目标

- **不做冷启动没跑过的 App。** 需要第三条 entitlement（`launchprocess`），而且现在的列表是「正在跑的
  进程」、冷启动要选的是「装着的 App」，两者是不同的数据源，要一整套新 UI。单独提案。
- **不走 `RBSLaunchRequest`。** 同上，本次一行都不写。
- **不碰 `DYLD_INSERT_LIBRARIES` 那条路。** `RBSLaunchContext._additionalEnvironment` 能做到启动即注入、
  绕开 task port 和线程竞速，但要 `launchprocess`，且 AMFI 可能把 `DYLD_*` 剥掉，**完全未验证**。
  列入替代方案留档。
- **不做 root 目标。** 父提案已列为非目标，本提案不改变那条。
- **不碰 `backboardd`。** 它的失败不是挂起 —— 注入返回目标自己写回的真裁决且是成功，而载荷不运行、
  内存不动。根因未查明，且归 MachInjector 自己的仓库。
- **不改反向连接通道。** 载荷怎么拨回宿主完全不动。
- **不做 iOS 侧设置界面。** 保活常开，没有开关，所以不需要。设置页现在是 macOS only，为一个常开行为
  新建一套 iOS 设置不划算。
- **不动模拟器那条路径。** 模拟器 guest 的沙盒宽松得多，这些问题都不存在。
- **不提升到 UIFoundationAppleInternal（本次）。** 见下。

## 详细设计

### 私有接口声明

```objc
// RuntimeViewerRunningBoardSupport/include/RuntimeViewerRunningBoardSupport.h
//
// The iOS SDK ships no RunningBoardServices stub — no framework, no .tbd — so
// these cannot be linked and are reached through the Objective-C runtime. They
// are declared as protocols rather than @interface on purpose: an @interface
// would make any Swift mention of the class emit a reference to
// _OBJC_CLASS_$_RBSAssertion, and the link would then fail.

/// What `RBSAssertion` offers once acquired. Obtained from
/// `RuntimeViewerRunningBoardMakeSuspensionPreventingAssertion`, never by name.
@protocol RuntimeViewerRunningBoardAssertion <NSObject>
- (BOOL)acquireWithError:(NSError **)error;
- (void)invalidate;
@property (nonatomic, readonly, getter=isValid) BOOL valid;
@end

/// Builds an unacquired assertion that prevents the target being suspended.
///
/// Returns nil and sets `error` when the classes are absent — which is the one
/// outcome that means "this OS version is not the one this was measured on",
/// as opposed to a refusal, which arrives from `acquireWithError:`.
id<RuntimeViewerRunningBoardAssertion> _Nullable
RuntimeViewerRunningBoardMakeSuspensionPreventingAssertion(
    pid_t targetProcessIdentifier,
    NSString *explanation,
    NSError *_Nullable *_Nullable error
);

/// Whether RunningBoard reports the process as running (that is, not suspended).
///
/// Needs `com.apple.runningboard.process-state` for any process but this one.
/// `outIsKnown` separates "reported as suspended" from "could not be asked",
/// so a missing entitlement never reads as a suspended target.
BOOL RuntimeViewerRunningBoardIsProcessRunning(
    pid_t targetProcessIdentifier,
    BOOL *outIsKnown,
    NSError *_Nullable *_Nullable error
);
```

内部实现取类的方式（`RBSAssertion` / `RBSTarget` / `RBSCPUAccessGrant` /
`RBSJetsamPriorityGrant`）用 `NSClassFromString`，并在首次使用前
`dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_LAZY)`
兜底 —— UIKit 经 FrontBoardServices 间接链了它，所以类通常已在进程里，但不能靠这个。

### 能力层

```swift
/// A held promise that RunningBoard will not suspend one process.
///
/// Releasing this releases the promise: RunningBoard invalidates an assertion
/// when the object holding it goes away, so the lifetime of this value *is* the
/// lifetime of the target staying awake.
public final class RuntimeDeviceSuspensionAssertion {
    public enum AcquisitionFailure: Error {
        /// The classes are not in this process. Measured on 26.3.1 and expected
        /// on 26.6.2 — if this ever fires, the interfaces moved.
        case runningBoardUnavailable(reason: String)
        /// RunningBoard refused. Carries its own words, which name the missing
        /// entitlement.
        case refused(reason: String)
    }

    public static func preventingSuspension(
        ofProcessWithIdentifier processIdentifier: pid_t,
        explanation: String,
    ) throws(AcquisitionFailure) -> RuntimeDeviceSuspensionAssertion
}
```

两种失败分开是为了版本差异那条风险：`runningBoardUnavailable` 说的是「这个 OS 不是量过的那个」，
`refused` 说的是「entitlement 没给」。糊成一种的话，26.6.2 上万一接口变了，用户看到的会是
「去重装一个带权限的版本」——一个完全错的指引。

### 策略层

```swift
/// Keeps the processes Runtime Viewer has injected into awake, one assertion per
/// process, for as long as anything still needs them.
///
/// Not gated on iOS, although only the device variant has a RunningBoard to
/// talk to: the reference counting and the release ordering are where the bugs
/// live, and this is the side of the gate that has a test runner.
public final class RuntimeDeviceSuspensionController {
    /// How an assertion is obtained. The live implementation calls
    /// `RuntimeDeviceSuspensionAssertion`; tests supply their own.
    public protocol AssertionProviding: Sendable {
        func assertion(
            preventingSuspensionOfProcessWithIdentifier processIdentifier: pid_t,
            explanation: String,
        ) throws -> any RuntimeDeviceSuspensionAssertionHolding
    }

    public init(assertionProvider: any AssertionProviding)

    /// Takes a reference, acquiring the assertion if this is the first one.
    public func retainAwake(processWithIdentifier: pid_t, explanation: String) throws

    /// Drops a reference, releasing the assertion when it was the last one.
    public func releaseAwake(processWithIdentifier: pid_t)
}
```

引用计数的键就是 pid。pid 复用理论上存在，但 RunningBoard 在目标进程退出时自己就把 assertion
作废了，再加一层「pid + 启动时间」的防护是过度设计。

### 注入流程

```swift
// RuntimeDeviceInjectionService.inject(intoProcessWithIdentifier:rendezvous:)
// 既有的「确认活着」「暂存载荷」两步不变，之后插入：

do {
    try suspensionController.retainAwake(
        processWithIdentifier: processIdentifier,
        explanation: "Runtime Viewer is injecting its runtime server",
    )
} catch {
    return .failed(code: 0, reason: /* assertion 自己的话，含缺失的 entitlement 名 */)
}

// 目标刚被唤醒，确认它真的离开了挂起态再注入——否则下面要白等满 20 秒裁决预算。
// 问不出来（缺 process-state）不作为失败：那只说明问不出来，不说明没醒。

guard injection.success else {
    suspensionController.releaseAwake(processWithIdentifier: processIdentifier)   // 回滚
    return result(for: ...)
}
// 成功则不释放——引用由控制器持有到 Detach
```

和宿主侧「先开监听、失败就拆掉」是同一个形状。

### 释放点

`terminateInjectedDeviceEngine(name:rendezvous:)` 已经是宿主侧的 Detach 动作，它经既有的注入命令
通道通知设备侧 `releaseAwake`。目标进程自己退出时不需要额外处理 —— RunningBoard 会作废 assertion，
控制器下次触碰那个 pid 时清掉记录。

### RV 自己

越狱版启动路径上取一条 `[RBSTarget currentProcess]` 的同款 assertion 并永久持有。
取不到就 `#log(.error, …)` 并继续 —— 保活失败不该让一个本来能用的功能整体不可用。

## 替代方案考量

- **`BKSProcessAssertion`** —— iOS 26 已经没有这个类，整个 `BackBoardServices` 里一个 process
  assertion 都不剩。唯一值得写下来的理由是：网上几乎所有 iOS 保活资料都基于它，不留档的话下次还会有人去找。
- **后台音频 / 定位 / VoIP 那套「假保活」** —— 播静音音频、申请后台定位之类。要更多 entitlement 和
  后台模式声明，行为不确定且随版本漂移，**而且根本不解决注入 App** —— 它只能保自己，没法唤醒别人。
  RunningBoard 这条是 iOS 自己用的那条，直接、可证伪、一条 entitlement。
- **把注入器做成 root 的 LaunchDaemon** —— 不被挂起是 daemon 的天然属性，顺带还解决 root 目标。
  但那就不是 App 分发了，而「越狱版是个能装的 App」是父提案最看重的性质。父提案已把 root 注入器
  列为另一个提案，这里不动它。
- **`RBSLaunchRequest` + `_additionalEnvironment` 塞 `DYLD_INSERT_LIBRARIES`** ——
  启动即注入，绕开 task port、绕开建线程等裁决、绕开 81 MB 镜像的 `dlopen` 竞速，理论上是最干净的
  注入方式。否的理由是三条叠加：要 `launchprocess`（本次非目标）、AMFI 可能剥掉 `DYLD_*`（未验证）、
  且只适用于冷启动。**留作后续**，因为如果它成立，它比现在这条路好。
- **让载荷自己给自己下 assertion** —— 载荷就在目标进程里，看起来最自然。**物理上不行**：entitlement
  按二进制签名算，载荷跑在目标进程里拿到的是**目标的** entitlement，而目标没有 `primitiveattribute`。
  这也是为什么 assertion 必须由注入方持有。
- **直接把封装放进 UIFoundationAppleInternal** —— 项目既有惯例是私有 API 封装一律进那里，形状也是
  现成的。否的理由是验证风险：结论全部读自 26.3.1 而测试机是 26.6.2，接口要在真机上确认，而放本地
  可以改一次编一次，进 UIFoundation 则每改一次要么发版抬 pin、要么全程挂 `USING_LOCAL_DEPENDENCIES=1`。
  **提升列为明确的后续项**，不是「以后再说」。
- **assertion 跟引擎绑，引擎销毁即释放** —— 不用新状态，最省事。否的理由是一个真实隐患：引擎断开时
  assertion 跟着没了，目标立刻被挂起，于是重连永远连不上 —— 而重连是已经验证过、现在就在用的行为
  （越狱版切回前台后引擎自己回来）。
- **注入过就不放，直到 RV 退出** —— 最不会出错，但被注入过的 App 会一直在后台跑，设备上感觉得到。
  引用计数的成本只有一个字典，不值得用这个换。

## 影响

### 用户可见变化

- **能注入 App 了**，前提是它启动过、现在挂在后台。进程列表的呈现不变（它本来就把 App 列为可注入，
  只是尝试会超时）。
- **从 Mac 点 Attach 不再要求越狱版在设备屏幕上。** 使用指南里「越狱版必须在设备屏幕上」整节要改写。
- **已注入的目标会保持运行**，直到用户 Detach。这是新行为：此前目标是 daemon，本来就不会被挂起。

用户原有操作习惯没有失效项 —— 这次只是去掉一条限制。

### 可发现性

没有新界面，没有开关。保活常开，注入 App 走的是已有的进程选择器。
用户感知到的变化就是「以前超时的目标现在能成」。

失败时的文案是唯一的可发现性载体，所以两种失败必须说不同的话：缺 entitlement 要指向重装，
接口不在要指向「这个 iOS 版本没量过」。

### 数据与配置兼容

不涉及。没有新的偏好设置、缓存或钥匙串条目。entitlements 文件是构建期产物，
旧的越狱版 IPA 继续能用 —— 只是没有新能力，且表现为现在这样的超时。

### 平台与最低版本

- 最低系统版本不变。
- 新代码只在 iOS 设备上生效；`RuntimeDeviceSuspensionController` 在 macOS 上编译并被测试，
  但没有 RunningBoard 可谈。
- **实测基线是 iOS 26.6.2（待验证）/ 26.3.1（静态结论来源）**。更低的 iOS 版本未考察。

### 发布

- **新增两条 entitlement**，都是 `com.apple.runningboard.*` 私有项。
  Xcode 签不了（没有 provisioning profile 给这些），和现有三条一样靠 ad-hoc 签名 + 保留 entitlement
  的安装方式。**这不改变分发故事**：越狱版本来就需要三条 Apple 私有 entitlement。
- 不影响公证、不影响 Sparkle —— 越狱版不走那两条路。
- 不涉及隐私清单：RunningBoard assertion 不属于需要申报的 API 类别，且该 target 不上 App Store。

## 落地步骤

1. ✅ **`RuntimeViewerRunningBoardSupport` target + 私有接口声明 + ObjC 工厂。**
2. ✅ **`RuntimeDeviceSuspensionAssertion`（能力层）。**
3. ✅ **`RuntimeDeviceSuspensionController`（策略层）+ 测试。** 7 个用例覆盖首次取、重复取只取一次、
   释放到零才失效、获取失败不留下半个引用、未知 pid 释放是空操作、多 pid 互不影响。
   另加 2 个用例实证 **RunningBoard 的运行时查找在 macOS 上真的能走通**（macOS 带着同一批 `RBS…` 类），
   这是版本风险唯一的自动化防线。
4. ✅ **第四条命令 `StopKeepingProcessAwakeRequest`** + `RuntimeInjectionService` 上带默认空实现的新方法
   + 线格式测试。
5. ✅ **两条 entitlement 落进 `-Jailbroken.entitlements`**，带实测理由与反编译依据的注释。
6. ✅ **注入流程接上 assertion**（含失败回滚与「取到了但仍挂起」的提前失败）；
   宿主侧在 `terminateRuntimeEngine(for:)` 加 `.injectedTCP` 分支释放；
   越狱版启动即对自己取一条；超时文案改写并换掉已失效的建议。
7. ✅ **文档同批次**：实现说明新增第八节并改写「已知不支持」；使用指南改 entitlement 表（三条→五条）、
   改「越狱版必须在设备屏幕上」整节、改能注什么的表格与错误文案；术语表加
   `挂起`、`assertion`、`保活` 三条。
8. ⬜ **真机验证（需要用户装 IPA）**：26.6.2 上确认接口存在、两条 entitlement 通过；
   注入一个挂在后台的 App；确认越狱版切出前台后仍能应答 Attach。

**收尾判断（两条都已执行）**：配套文档 —— 两份都改了、不新增，已登记进头部；
新术语 —— 加了 `挂起`、`assertion`、`保活` 三条。

### 本提案范围外的已知缺口

**AppKit 侧没有 Detach 入口。** 本提案的释放挂在 `terminateRuntimeEngine(for:)` 上，所以 CLI 的
`runtime-viewer-cli detach` 和 attach 失败回滚都覆盖到了；但 App 里用户没有「Detach 这个注入的引擎」
这个动作可点，`RuntimeProcessAttacher.detach(_:)` 也只有 Mac 与模拟器两条分支。**这是本提案之前就有的
状态**，不是本次引入的。实际后果：在 App 里注入一个 App 之后，那个目标会一直保持运行到它自己退出或
RV 退出。补这个口子要先设计 Detach 的 UI，是另一件事。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-03 | Created as Accepted | 完整档澄清提问一轮问完四题（能力范围 / assertion 生命周期 / 保活触发 / API 归属），四题答案均与建议一致，用户当场批准动工。提案文件按规矩是提问之后的产物，故直接以 `Accepted` 创建 |
| 2026-10-03 | 范围定为「保活 + 注入已启动的 App」，不含冷启动 | 冷启动要第三条 entitlement，且「正在跑的进程」和「装着的 App」是不同数据源、需要一整套新 UI。单独提案 |
| 2026-10-03 | assertion 由独立控制器按 pid 引用计数持有，Detach 才释放 | 跟引擎绑会让断线重连永远连不上目标，而重连是已验证且在用的行为 |
| 2026-10-03 | RV 自己保活常开，不做开关 | 越狱版是调试工具不是日用 App；且「什么时候开」本身就是一类 bug 的来源。连带免掉新建 iOS 设置界面 |
| 2026-10-03 | 私有 API 先就地放 `RuntimeViewerDeviceInjection`，提升到 UIFoundationAppleInternal 列为后续项 | 刻意偏离「私有 API 一律进 UIFoundationAppleInternal」的既有惯例。理由是验证风险：结论读自 26.3.1 而测试机 26.6.2，真机确认期间需要改一次编一次，进 UIFoundation 要发版抬 pin 或全程本地依赖构建 |
| 2026-10-03 | 两种获取失败刻意分开（接口不在 / 权限被拒） | 版本差异风险的直接产物：糊成一种会在 26.6.2 接口有变时把用户指向「重装带权限的版本」，那是个完全错的指引 |
| 2026-10-03 | 推翻实现说明里「注入其它 App 是结构性的」后半句 | 前台不是进程能运行的唯一途径。该段文字在第 7 步同批次改写 |
| 2026-10-03 | 不改进程列表的可注入性预筛 | 它对 App 本来就返回 `.injectable`、让尝试当权威。本提案是让那个尝试成功，不是改判定 |
| 2026-10-03 | **更正初稿的一处事实错误**：设备侧原本没有「释放」通道，故新增第四条命令 `StopKeepingProcessAwakeRequest` | 初稿「前期调研」写的是「经既有的注入命令通道通知设备侧」。实际只有三条注入命令，没有一条能表达释放。新方法在 `RuntimeInjectionService` 上带默认空实现，所以 macOS 与模拟器实现一个字不用改 —— 对它们来说这件事本来就不需要做 |
| 2026-10-03 | 释放挂在 `terminateRuntimeEngine(for:)` 而不是某个 Detach 方法上 | 所有拆引擎的路径都汇到它（CLI detach、attach 失败回滚），而它本来就有按 source 种类分的清理分支。挂在这里是一处代码覆盖全部路径 |
| 2026-10-03 | 记录「引擎 ↔ (设备引擎, pid)」的配对放在 `RuntimeEngineManager`，且在**注入之前**就记 | `.injectedTCP` 带的是 rendezvous 不是 pid，配对只能记下来。记早不记晚是因为失败路径也要释放，而设备侧对未持有的 pid 释放是空操作（有测试钉住），所以记早没有代价 |
| 2026-10-03 | 取到 assertion 后额外确认目标真的离开挂起态，否则提前失败 | 否则会白等满 20 秒的裁决预算再报一个什么都没说的超时。问不出来（缺 `process-state`）不算失败——那只说明问不出来 |
| 2026-10-03 | 两个 RunningBoard 运行时查找的测试**不容忍类不存在** | macOS 带着同一批 `RBS…` 类，这是版本风险唯一的自动化防线。一个对缺失耸耸肩的测试什么都保护不了 |
| 2026-10-03 | 超时文案删掉「把目标切到前台再试」，并加测试钉住它不回来 | 那正是现在代码替用户做掉的事。陈旧的指引比含糊的指引更糟：它让用户去做一件已经做过的事 |
| 2026-10-03 | 记录范围外缺口：App 里没有 Detach 入口 | 本提案之前就是这样，`RuntimeProcessAttacher.detach(_:)` 连设备分支都没有。后果是 App 里注入的目标会保持运行到自身退出。补它要先设计 UI |
| 2026-10-03 | **真机证伪**：`RBSCPUAccessGrant` + `primitiveattribute` 这条路不可行，改用 `RBSLegacyAttribute`（`reason 4` / `flags 1`） | 第一版装机后越狱版切后台照样断连，实测 12 秒 CPU 增量 0.0000、jetsam band 仍为 0。根因是 `primitiveattribute` 是**受限 entitlement**：`runningboardd` 在 `_removeRestrictedEntitlements:forProcess:` 按 `/System/Library/RunningBoard/runningboardEntitlementsConfiguration.plist` 的 bundle id 白名单剥掉它，而那张表（已从设备读出）只有十余个 Apple 身份。初稿只跟到了检查点，没跟到 `originatorEntitlements` 的**构造**过程，第二道闸在那儿 |
| 2026-10-03 | entitlement 回到四条：删 `primitiveattribute`，`process-state` 升为必要条件 | 删的那条签了也会被剥掉。留的那条原本只是诊断用，改道后它成了「assertion 能以别的进程为目标」的充分条件（legacy 的 originator 校验要 domain 63 里任意一条，`process-state` 在 domain 1） |
| 2026-10-03 | 不加 `RBSJetsamPriorityGrant` | legacy attribute 自带 band 40（高于守护进程的 30）。再加一条 grant 会让 assertion 重新变成 primitive attribute，正好撞回刚绕开的那道闸 |
| 2026-10-03 | 考虑过但未采用：把本 App 的 bundle id 加进白名单 | runningboardd 还读同目录的 `runningboardAdditionalEntitlementsConfiguration.plist` 与 `com.apple.runningboard` suite 的 `AdditionalEntitlementsConfigurations`，合并逻辑是**纯追加**（`0x266ca07c4`），确实可行。否的理由是它需要设备侧一次性配置 + 重启 runningboardd，App 自己不能给自己授权，削弱父提案最看重的分发性质。留作 legacy 路线失败时的退路 |
| 2026-10-03 | 新增术语 `受限 entitlement` | 这次弯路的可复用教训：判断一条私有 entitlement 可不可用，必须跟到消费方构造权限集合那一步 |
