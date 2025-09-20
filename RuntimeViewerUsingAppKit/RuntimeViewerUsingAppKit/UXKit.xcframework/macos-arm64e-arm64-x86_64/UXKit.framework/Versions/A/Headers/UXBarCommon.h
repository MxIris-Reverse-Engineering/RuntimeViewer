#import <Foundation/Foundation.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

typedef NS_ENUM(NSInteger, UXBarMetrics) {
    UXBarMetricsDefault,
    UXBarMetricsCompact,
    UXBarMetricsDefaultPrompt = 101, // Applicable only in bars with the prompt property, such as UXNavigationBar and UXSearchBar
    UXBarMetricsCompactPrompt,
};

typedef NS_ENUM(NSInteger, UXBarPosition) {
    UXBarPositionAny         = 0,
    UXBarPositionBottom      = 1, // The bar is at the bottom of its local context, and directional decoration draws accordingly (e.g., shadow above the bar).
    UXBarPositionTop         = 2, // The bar is at the top of its local context, and directional decoration draws accordingly (e.g., shadow below the bar)
    UXBarPositionTopAttached = 3, // The bar is at the top of the screen (as well as its local context), and its background extends upward—currently only enough for the status bar.
};

#define UXToolbarPosition       UXBarPosition
#define UXToolbarPositionAny    UXBarPositionAny
#define UXToolbarPositionBottom UXBarPositionBottom
#define UXToolbarPositionTop    UXBarPositionTop

NS_SWIFT_UI_ACTOR
@protocol UXBarPositioning <NSObject> // UXNavigationBar, UXToolbar, and UXSearchBar conform to this
@property (nonatomic, readonly) UXBarPosition barPosition;
@end

NS_SWIFT_UI_ACTOR
@protocol UXBarPositioningDelegate <NSObject> // UXNavigationBarDelegate, UXToolbarDelegate, and UXSearchBarDelegate all extend from this
@optional
/* Implement this method on your manual bar delegate when not managed by a UXKit controller.
   UXNavigationBar and UXSearchBar default to UXBarPositionTop, UXToolbar defaults to UXBarPositionBottom.
   This message will be sent when the bar moves to a window.
 */
- (UXBarPosition)positionForBar:(id <UXBarPositioning>)bar;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
