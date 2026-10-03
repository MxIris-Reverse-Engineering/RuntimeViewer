//
//  RuntimeViewerRunningBoardSupport.h
//
//  The `RunningBoardServices` surface needed to stop a process being
//  suspended, reached through the Objective-C runtime because there is nothing
//  to link against.
//
//  **The iOS SDK ships no stub for this framework.** Not the framework, not a
//  `.tbd`, nothing — the same is true of `BackBoardServices` and
//  `FrontBoardServices`:
//
//      $ find $(xcrun --sdk iphoneos --show-sdk-path) -name "RunningBoardServices*"
//      (no output)
//
//  So every class here is obtained with `NSClassFromString` and every message
//  is sent through a protocol declared below. Declaring them as `@protocol`
//  rather than `@interface` is the load-bearing part: an `@interface RBSAssertion`
//  would make any mention of the class — from here or from Swift — emit a
//  reference to `_OBJC_CLASS_$_RBSAssertion`, and the link would then fail on
//  a device SDK that has no such symbol to resolve.
//
//  Why this framework at all, and why these specific classes:
//  `Documentations/Evolutions/draft-device-process-assertions.md` carries the
//  measurements, each cited with its address in the 26.3.1 shared cache.
//
//  The short version is that RunningBoard decides "running versus suspended"
//  from one flag, `RBProcessState.preventSuspend`, and two kinds of attribute
//  can set it. The obvious one, `RBSCPUAccessGrant`, is **unusable**: it is a
//  primitive attribute, and primitive attributes need
//  `com.apple.runningboard.primitiveattribute`, which is a *restricted*
//  entitlement — `runningboardd` strips it from any process whose bundle
//  identifier is not in the allow-list at
//  `/System/Library/RunningBoard/runningboardEntitlementsConfiguration.plist`
//  (measured on the device: about fifteen Apple identities, and no way for a
//  third party to be among them). Signing it into the binary achieves nothing.
//
//  So this uses the other one: `RBSLegacyAttribute`, the bridge for the old
//  `BKSProcessAssertion` API, which is validated by a different path that never
//  consults that list.
//

#ifndef RuntimeViewerRunningBoardSupport_h
#define RuntimeViewerRunningBoardSupport_h

#import <Foundation/Foundation.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// Errors raised by this file itself, as opposed to the ones RunningBoard
/// raises and this file passes through untouched.
extern NSString *const RuntimeViewerRunningBoardErrorDomain;

typedef NS_ERROR_ENUM(RuntimeViewerRunningBoardErrorDomain, RuntimeViewerRunningBoardErrorCode) {
    /// `RunningBoardServices` is not in this process and could not be loaded.
    ///
    /// Distinct from a refusal on purpose: a refusal means the entitlement is
    /// missing and the user should reinstall a variant that has it, while this
    /// means the framework is not where it was measured to be — a different
    /// problem with a different answer, and sending someone to reinstall over
    /// it would be a wrong instruction.
    RuntimeViewerRunningBoardErrorCodeFrameworkUnavailable = 1,

    /// A class is present but does not answer a selector this code needs.
    ///
    /// Every measurement behind this file was taken on iOS 26.3.1. This code is
    /// what fires when a later version moved the interface, and it says so
    /// instead of failing as though permission were missing.
    RuntimeViewerRunningBoardErrorCodeInterfaceChanged = 2,
};

/// What an `RBSAssertion` offers once this file has built one.
///
/// Obtained only from `RuntimeViewerRunningBoardMakeSuspensionPreventingAssertion`
/// below — never by naming the class, for the linking reason in the file
/// comment.
///
/// **The assertion holds for exactly as long as this object does.** RunningBoard
/// invalidates an assertion when the object that acquired it goes away, so
/// releasing the last reference is how the promise is given back; there is no
/// separate "release" step to forget.
@protocol RuntimeViewerRunningBoardAssertion <NSObject>

/// Asks RunningBoard to honour the assertion.
///
/// Returns `NO` and fills `error` with RunningBoard's own words, which name the
/// entitlement when that is what is missing.
- (BOOL)acquireWithError:(NSError *_Nullable *_Nullable)error;

/// Gives the assertion back ahead of deallocation.
- (void)invalidate;

@property (nonatomic, readonly, getter=isValid) BOOL valid;

@end

/// Builds an **unacquired** assertion that, once acquired, stops RunningBoard
/// suspending the given process.
///
/// One attribute goes on it: `RBSLegacyAttribute` with reason 4 and flags 1 —
/// the old `BKSProcessAssertionReasonFinishTask` and
/// `BKSProcessAssertionFlagPreventSuspend`. That pair was chosen because of
/// what each one buys, all measured:
///
/// - **flags 1** makes `-[RBSLegacyAttribute _role]` return 2, and
///   `preventsSuspension` is `_role > 1`. It also sets the explicit jetsam band
///   to 40, above the 30 daemons sit at and far above the 0 a backgrounded app
///   gets — so no separate jetsam attribute is needed, and adding one would
///   reintroduce the entitlement problem this avoids.
/// - **reason 4** is the one reason whose originator check passes with no
///   entitlement at all when a process targets itself. For *another* process it
///   wants the originator to be a platform binary or to hold any entitlement in
///   domain 63 — which `com.apple.runningboard.process-state` satisfies, and
///   that one is not restricted.
///
/// Nothing else in the legacy path applies here: the target check for reason 4
/// refuses only the system target.
///
/// Returns `nil` and fills `error` with a
/// `RuntimeViewerRunningBoardErrorDomain` error when the framework or the
/// interface is not what it was measured to be. A *refusal* is not reported
/// here — it arrives from `acquireWithError:`, because RunningBoard only
/// consults the client's entitlements when the assertion is acquired.
///
/// - Parameter targetProcessIdentifier: the process to keep awake. Passing this
///   process's own identifier is supported and takes RunningBoard's dedicated
///   path for it.
/// - Parameter explanation: shown in RunningBoard's state dumps, so make it
///   name this application and what it is doing.
id<RuntimeViewerRunningBoardAssertion> _Nullable
RuntimeViewerRunningBoardMakeSuspensionPreventingAssertion(
    pid_t targetProcessIdentifier,
    NSString *explanation,
    NSError *_Nullable *_Nullable error
);

/// Whether RunningBoard reports a process as running.
typedef NS_ENUM(NSInteger, RuntimeViewerRunningBoardRunningState) {
    /// RunningBoard could not be asked, or did not answer.
    ///
    /// **Not a synonym for suspended.** Querying another process needs
    /// `com.apple.runningboard.process-state`, so a variant without that
    /// entitlement lands here for every target — and treating that as "the
    /// target is suspended" would report a permission problem as a target
    /// problem.
    RuntimeViewerRunningBoardRunningStateUnknown = 0,

    /// Scheduled, so injected code in it can run.
    RuntimeViewerRunningBoardRunningStateRunning,

    /// Suspended: no thread is scheduled, and injected code in it cannot run.
    RuntimeViewerRunningBoardRunningStateSuspended,
};

/// Asks RunningBoard whether a process is currently scheduled.
///
/// `error` is filled on anything but `…StateRunning` / `…StateSuspended`, and
/// carries RunningBoard's own words when it was reached and refused.
///
/// Asking about **this** process takes RunningBoard's dedicated path and needs
/// no entitlement, which is what lets a test exercise the whole runtime lookup
/// — class to handle to state — on a machine with a test runner.
RuntimeViewerRunningBoardRunningState
RuntimeViewerRunningBoardRunningStateOfProcess(
    pid_t targetProcessIdentifier,
    NSError *_Nullable *_Nullable error
);

NS_ASSUME_NONNULL_END

#endif /* RuntimeViewerRunningBoardSupport_h */
