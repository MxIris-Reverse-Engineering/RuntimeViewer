#import <AppKit/AppKit.h>
#import <UXKit/UXKitDefines.h>
#import <UXKit/UXToolbar.h>
#import <UXKit/UXViewController.h>
#import <UXKit/UXKitDefines.h>

@class UXNavigationBar, UXToolbar, UXView, UXViewController, UXBarButtonItem;
@protocol UXViewControllerAnimatedTransitioning, UXViewControllerInteractiveTransitioning, UXNavigationControllerDelegate;

typedef NS_ENUM(NSInteger, UXNavigationControllerOperation) {
    UXNavigationControllerOperationNone,
    UXNavigationControllerOperationPush,
    UXNavigationControllerOperationPop,
} NS_SWIFT_NAME(UXNavigationController.Operation);

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXNavigationController : UXViewController <UXToolbarDelegate, NSMenuDelegate>

@property (nonatomic, weak, nullable) id <UXNavigationControllerDelegate> delegate;
@property (nonatomic, readonly, null_resettable) UXToolbar *toolbar;
@property (nonatomic, getter = isToolbarHidden) BOOL toolbarHidden;
@property (nonatomic, readonly, nullable) UXToolbar *subtoolbar;
@property (nonatomic, getter = isSubtoolbarHidden) BOOL subtoolbarHidden;
@property (nonatomic, readonly, null_resettable) UXToolbar *accessoryBar;
@property (nonatomic, readonly, getter = isAccessoryBarHidden) BOOL accessoryBarHidden;
@property (nonatomic, readonly) UXNavigationBar *navigationBar;
@property (nonatomic, getter = isNavigationBarHidden) BOOL navigationBarHidden;
@property (nonatomic, getter = isNavigationBarDetached) BOOL navigationBarDetached;
@property (nonatomic, copy) NSArray<UXViewController *> *viewControllers;
@property (nonatomic, readonly, nullable) UXViewController *visibleViewController;
@property (nonatomic, readonly, nullable) UXViewController *topViewController;
@property (nonatomic, readonly, nullable) NSGestureRecognizer *interactivePopGestureRecognizer;

- (instancetype)initWithNavigationBarClass:(nullable Class)navigationBarClass toolbarClass:(nullable Class)toolbarClass;
- (instancetype)initWithRootViewController:(UXViewController *)rootViewController;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (nullable UXViewController *)popViewControllerAnimated:(BOOL)animated;
- (nullable NSArray<__kindof UXViewController *> *)popToRootViewControllerAnimated:(BOOL)animated;
- (nullable NSArray<__kindof UXViewController *> *)popToViewController:(UXViewController *)viewController animated:(BOOL)animated NS_SWIFT_NAME(popToViewController(_:animated:));
- (void)pushViewController:(UXViewController *)viewController animated:(BOOL)animated;
- (void)setViewControllers:(NSArray<UXViewController *> *)viewControllers animated:(BOOL)animated;
- (void)detachNavigationBar;
- (void)setToolbarHidden:(BOOL)hidden animated:(BOOL)animated;
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated;

@end
NS_SWIFT_UI_ACTOR
@protocol UXNavigationControllerDelegate <NSObject>
@optional
- (nullable id<UXViewControllerAnimatedTransitioning>)navigationController:(UXNavigationController *)navigationController animationControllerForOperation:(UXNavigationControllerOperation)operation fromViewController:(UXViewController *)fromViewController toViewController:(UXViewController *)toViewController;
- (nullable id<UXViewControllerInteractiveTransitioning>)navigationController:(UXNavigationController *)navigationController interactionControllerForAnimationController:(id<UXViewControllerAnimatedTransitioning>)animationController;
- (void)navigationController:(UXNavigationController *)navigationController didShowViewController:(UXViewController *)viewController;
- (BOOL)navigationController:(UXNavigationController *)navigationController shouldBeginInteractivePopFromViewController:(UXViewController *)fromViewController toViewController:(UXViewController *)toViewController;
- (BOOL)navigationController:(UXNavigationController *)navigationController shouldPopFromViewController:(UXViewController *)fromViewController toViewController:(UXViewController *)toViewController;
- (void)navigationController:(UXNavigationController *)navigationController willShowViewController:(UXViewController *)viewController;

@end

NS_HEADER_AUDIT_END(nullability, sendability)
