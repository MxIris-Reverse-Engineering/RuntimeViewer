#import <AppKit/AppKit.h>
#import <UXKit/UXViewController.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class UXView;

typedef NSString * UXTransitionContextViewControllerKey NS_TYPED_ENUM;
typedef NSString * UXTransitionContextViewKey NS_TYPED_ENUM;

@protocol UXViewControllerTransitionCoordinatorContext <NSObject>
// The view in which the animated transition is taking place.
@property (nonatomic, readonly) UXView *containerView;
- (nullable __kindof UXViewController *)viewControllerForKey:(UXTransitionContextViewControllerKey)key;
// These three methods are potentially meaningful for interactive transitions that are
// completing. It reports the percent complete of the transition when it moves
// to the non-interactive completion phase of the transition.
@property (nonatomic, readonly) CGFloat percentComplete;
@property (nonatomic, readonly) CGFloat completionVelocity;
@property (nonatomic, readonly) NSInteger completionCurve;
// The full expected duration of the transition if it is run non-interactively.
@property (nonatomic, readonly) NSTimeInterval transitionDuration;
/// initiallyInteractive indicates whether the transition was initiated as an interactive transition.
/// It never changes during the course of a transition.
/// It can only be YES if isAnimated is YES.
///If it is NO, then isInteractive can only be YES if isInterruptible is YES
@property (nonatomic, readonly) BOOL initiallyInteractive;
// A modal presentation style whose transition is being customized or UIModalPresentationNone if this is not a modal presentation
// or dismissal.
@property (nonatomic, readonly) NSInteger presentationStyle;
// Most of the time isAnimated will be YES. For custom transitions that use the
// new UIModalPresentationCustom presentation type we invoke the
// animateTransition: even though the transition is not animated. (This allows
// the custom transition to add or remove subviews to the container view.)
@property (nonatomic, readonly, getter = isAnimated) BOOL animated;
// Interactive transitions have non-interactive segments. For example, they all complete non-interactively. Some interactive transitions may have
// intermediate segments that are not interactive.
@property (nonatomic, readonly, getter = isInteractive) BOOL interactive;

// isCancelled is usually NO. It is only set to YES for an interactive transition that was cancelled.
@property (nonatomic, readonly, getter = isCancelled) BOOL cancelled;
@end


@protocol UXViewControllerTransitionCoordinator <UXViewControllerTransitionCoordinatorContext>
- (BOOL)animateAlongsideTransitionInView:(nullable UXView *)view
                               animation:(void (^__nullable)(id <UXViewControllerTransitionCoordinatorContext>context))animation
                              completion:(void (^__nullable)(id <UXViewControllerTransitionCoordinatorContext>context))completion;
- (BOOL)animateAlongsideTransition:(void (^__nullable)(id <UXViewControllerTransitionCoordinatorContext>context))animation
                        completion:(void (^__nullable)(id <UXViewControllerTransitionCoordinatorContext>context))completion;
- (void)notifyWhenInteractionEndsUsingBlock:(void (^)(id <UXViewControllerTransitionCoordinatorContext>context))handler;
@end





NS_HEADER_AUDIT_END(nullability, sendability)
