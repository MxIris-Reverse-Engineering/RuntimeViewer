//
//  RuntimeViewerRunningBoardSupport.m
//
//  See the header for why none of these classes is named at compile time.
//

#import "include/RuntimeViewerRunningBoardSupport.h"

#include <dlfcn.h>
#include <unistd.h>

NSString *const RuntimeViewerRunningBoardErrorDomain = @"RuntimeViewerRunningBoardErrorDomain";

#pragma mark - The private surface, declared as protocols

/// `+[RBSTarget …]`.
///
/// Class methods are declared as instance methods and the `Class` object is
/// messaged directly: a class *is* an object, and its class methods are its
/// metaclass's instance methods, so this type-checks and dispatches correctly
/// without ever naming `RBSTarget`. Every protocol below follows the same
/// pattern.
@protocol RuntimeViewerRunningBoardTargetClass <NSObject>
- (id)targetWithPid:(pid_t)processIdentifier;
- (id)currentProcess;
@end

/// `+[RBSCPUAccessGrant grant]` — the attribute that sets `preventSuspend`.
@protocol RuntimeViewerRunningBoardCentralProcessingUnitAccessGrantClass <NSObject>
- (id)grant;
@end

/// `+[RBSJetsamPriorityGrant grantWithForegroundPriority]`.
@protocol RuntimeViewerRunningBoardJetsamPriorityGrantClass <NSObject>
- (id)grantWithForegroundPriority;
@end

/// `-[RBSAssertion initWithExplanation:target:attributes:]`.
///
/// The rest of the instance surface is the public
/// `RuntimeViewerRunningBoardAssertion` protocol in the header, which this one
/// extends so one cast covers construction and use both.
@protocol RuntimeViewerRunningBoardAssertionConstruction <RuntimeViewerRunningBoardAssertion>
- (instancetype)initWithExplanation:(NSString *)explanation
                             target:(id)target
                         attributes:(NSArray *)attributes;
@end

/// `+[RBSProcessHandle …]`.
///
/// The identifier is anything conforming to RunningBoard's own
/// `RBSProcessIdentifier`, and `NSNumber` is made to conform by a category in
/// the framework itself — which is why a boxed pid is the whole argument.
@protocol RuntimeViewerRunningBoardProcessHandleClass <NSObject>
- (id)handleForIdentifier:(id)identifier error:(NSError *_Nullable *_Nullable)error;
- (id)currentProcess;
@end

/// The part of `-[RBSProcessHandle …]` and `-[RBSProcessState …]` this file reads.
@protocol RuntimeViewerRunningBoardProcessHandle <NSObject>
- (id)currentState;
@end

@protocol RuntimeViewerRunningBoardProcessState <NSObject>
- (BOOL)isRunning;
@end

#pragma mark - Reaching the framework

/// Makes sure `RunningBoardServices` is in the process.
///
/// It usually already is — UIKit reaches it through `FrontBoardServices` — but
/// relying on that would make this file's behaviour depend on what else the
/// host happens to link, so it is loaded explicitly and once.
static BOOL RuntimeViewerRunningBoardLoadFramework(void) {
    static BOOL isLoaded = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Already present: nothing to do. Checking a class rather than the
        // handle keeps this correct whichever way it arrived.
        if (NSClassFromString(@"RBSAssertion") != Nil) {
            isLoaded = YES;
            return;
        }
        const char *frameworkPath =
            "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices";
        isLoaded = dlopen(frameworkPath, RTLD_LAZY) != NULL
            && NSClassFromString(@"RBSAssertion") != Nil;
    });
    return isLoaded;
}

static NSError *RuntimeViewerRunningBoardError(
    RuntimeViewerRunningBoardErrorCode code,
    NSString *failureReason
) {
    return [NSError errorWithDomain:RuntimeViewerRunningBoardErrorDomain
                               code:code
                           userInfo:@{NSLocalizedFailureReasonErrorKey: failureReason}];
}

/// Looks up one class, reporting the two failures apart.
static Class _Nullable RuntimeViewerRunningBoardClass(
    NSString *className,
    NSError *_Nullable *_Nullable error
) {
    if (!RuntimeViewerRunningBoardLoadFramework()) {
        if (error != NULL) {
            *error = RuntimeViewerRunningBoardError(
                RuntimeViewerRunningBoardErrorCodeFrameworkUnavailable,
                @"RunningBoardServices is not loaded in this process and could not be loaded from "
                @"/System/Library/PrivateFrameworks."
            );
        }
        return Nil;
    }
    Class foundClass = NSClassFromString(className);
    if (foundClass == Nil && error != NULL) {
        *error = RuntimeViewerRunningBoardError(
            RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
            [NSString stringWithFormat:
                @"RunningBoardServices is loaded but has no %@ class, so its interface is not the "
                @"one this was built against.", className]
        );
    }
    return foundClass;
}

/// Checks a selector before sending it, so a moved interface reports itself
/// instead of raising an unrecognized-selector exception.
static BOOL RuntimeViewerRunningBoardClassResponds(
    Class subjectClass,
    SEL selector,
    NSError *_Nullable *_Nullable error
) {
    if ([subjectClass respondsToSelector:selector]) {
        return YES;
    }
    if (error != NULL) {
        *error = RuntimeViewerRunningBoardError(
            RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
            [NSString stringWithFormat:@"%@ does not answer +%@, so its interface is not the one "
                                       @"this was built against.",
                                       NSStringFromClass(subjectClass), NSStringFromSelector(selector)]
        );
    }
    return NO;
}

#pragma mark - Assertions

id<RuntimeViewerRunningBoardAssertion> _Nullable
RuntimeViewerRunningBoardMakeSuspensionPreventingAssertion(
    pid_t targetProcessIdentifier,
    NSString *explanation,
    NSError *_Nullable *_Nullable error
) {
    Class targetClass = RuntimeViewerRunningBoardClass(@"RBSTarget", error);
    Class centralProcessingUnitAccessGrantClass =
        targetClass == Nil ? Nil : RuntimeViewerRunningBoardClass(@"RBSCPUAccessGrant", error);
    Class jetsamPriorityGrantClass =
        centralProcessingUnitAccessGrantClass == Nil
            ? Nil
            : RuntimeViewerRunningBoardClass(@"RBSJetsamPriorityGrant", error);
    Class assertionClass =
        jetsamPriorityGrantClass == Nil ? Nil : RuntimeViewerRunningBoardClass(@"RBSAssertion", error);
    if (assertionClass == Nil) {
        return nil;
    }

    // `currentProcess` for ourselves rather than `targetWithPid:` with our own
    // pid: it is the path RunningBoard's own clients take for self-assertions,
    // and it needs no process lookup to resolve.
    SEL targetSelector = targetProcessIdentifier == getpid()
        ? @selector(currentProcess)
        : @selector(targetWithPid:);
    if (!RuntimeViewerRunningBoardClassResponds(targetClass, targetSelector, error)
        || !RuntimeViewerRunningBoardClassResponds(
               centralProcessingUnitAccessGrantClass, @selector(grant), error)
        || !RuntimeViewerRunningBoardClassResponds(
               jetsamPriorityGrantClass, @selector(grantWithForegroundPriority), error)) {
        return nil;
    }
    if (![assertionClass instancesRespondToSelector:
              @selector(initWithExplanation:target:attributes:)]) {
        if (error != NULL) {
            *error = RuntimeViewerRunningBoardError(
                RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
                @"RBSAssertion does not answer -initWithExplanation:target:attributes:, so its "
                @"interface is not the one this was built against."
            );
        }
        return nil;
    }

    id<RuntimeViewerRunningBoardTargetClass> targetFactory =
        (id<RuntimeViewerRunningBoardTargetClass>)targetClass;
    id target = targetProcessIdentifier == getpid()
        ? [targetFactory currentProcess]
        : [targetFactory targetWithPid:targetProcessIdentifier];
    if (target == nil) {
        if (error != NULL) {
            *error = RuntimeViewerRunningBoardError(
                RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
                [NSString stringWithFormat:@"RunningBoard produced no target for process %d.",
                                           targetProcessIdentifier]
            );
        }
        return nil;
    }

    id<RuntimeViewerRunningBoardCentralProcessingUnitAccessGrantClass>
        centralProcessingUnitAccessGrantFactory =
            (id<RuntimeViewerRunningBoardCentralProcessingUnitAccessGrantClass>)
                centralProcessingUnitAccessGrantClass;
    id<RuntimeViewerRunningBoardJetsamPriorityGrantClass> jetsamPriorityGrantFactory =
        (id<RuntimeViewerRunningBoardJetsamPriorityGrantClass>)jetsamPriorityGrantClass;

    // The CPU-access grant is the one that matters: it sets `preventSuspend`
    // unconditionally. The jetsam grant is insurance — a process held awake in
    // the background would otherwise sit in the band the kernel kills first.
    NSArray *attributes = @[
        [centralProcessingUnitAccessGrantFactory grant],
        [jetsamPriorityGrantFactory grantWithForegroundPriority],
    ];

    id<RuntimeViewerRunningBoardAssertionConstruction> assertion =
        (id<RuntimeViewerRunningBoardAssertionConstruction>)[assertionClass alloc];
    return [assertion initWithExplanation:explanation target:target attributes:attributes];
}

#pragma mark - Process state

RuntimeViewerRunningBoardRunningState
RuntimeViewerRunningBoardRunningStateOfProcess(
    pid_t targetProcessIdentifier,
    NSError *_Nullable *_Nullable error
) {
    Class processHandleClass = RuntimeViewerRunningBoardClass(@"RBSProcessHandle", error);
    // `currentProcess` for ourselves, for the same two reasons as the target
    // above: it is the path RunningBoard's own clients take, and it needs no
    // lookup — which also means it needs no `process-state` entitlement, so
    // asking about this process works on any build.
    BOOL isThisProcess = targetProcessIdentifier == getpid();
    SEL handleSelector = isThisProcess ? @selector(currentProcess)
                                       : @selector(handleForIdentifier:error:);
    if (processHandleClass == Nil
        || !RuntimeViewerRunningBoardClassResponds(processHandleClass, handleSelector, error)) {
        return RuntimeViewerRunningBoardRunningStateUnknown;
    }

    id<RuntimeViewerRunningBoardProcessHandleClass> processHandleFactory =
        (id<RuntimeViewerRunningBoardProcessHandleClass>)processHandleClass;
    NSError *lookupError = nil;
    id handle = isThisProcess
        ? [processHandleFactory currentProcess]
        : [processHandleFactory handleForIdentifier:@(targetProcessIdentifier)
                                              error:&lookupError];
    if (handle == nil) {
        if (error != NULL) {
            // RunningBoard's own words when it answered, ours when it did not.
            // A missing `process-state` entitlement arrives here, and it must
            // not be mistaken for the target being suspended.
            *error = lookupError ?: RuntimeViewerRunningBoardError(
                RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
                [NSString stringWithFormat:
                    @"RunningBoard returned neither a handle nor an error for process %d.",
                    targetProcessIdentifier]
            );
        }
        return RuntimeViewerRunningBoardRunningStateUnknown;
    }

    if (![handle respondsToSelector:@selector(currentState)]) {
        if (error != NULL) {
            *error = RuntimeViewerRunningBoardError(
                RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
                @"RBSProcessHandle does not answer -currentState, so its interface is not the one "
                @"this was built against."
            );
        }
        return RuntimeViewerRunningBoardRunningStateUnknown;
    }

    id state = [(id<RuntimeViewerRunningBoardProcessHandle>)handle currentState];
    if (state == nil || ![state respondsToSelector:@selector(isRunning)]) {
        if (error != NULL) {
            *error = RuntimeViewerRunningBoardError(
                RuntimeViewerRunningBoardErrorCodeInterfaceChanged,
                @"RunningBoard produced no readable state for the process."
            );
        }
        return RuntimeViewerRunningBoardRunningStateUnknown;
    }

    return [(id<RuntimeViewerRunningBoardProcessState>)state isRunning]
        ? RuntimeViewerRunningBoardRunningStateRunning
        : RuntimeViewerRunningBoardRunningStateSuspended;
}
