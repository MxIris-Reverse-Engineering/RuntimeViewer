#import <AppKit/AppKit.h>
#import <UXKit/UXView.h>
#import <UXKit/UXKitDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXLabel : UXView <NSAccessibilityStaticText>

@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic, strong, nullable) NSFont *font;
@property (nonatomic, strong, nullable) NSColor *textColor;
@property (nonatomic, strong, nullable) NSColor *shadowColor;
@property (nonatomic, strong, nullable) NSColor *highlightedTextColor;
@property (nonatomic) NSInteger numberOfLines;
@property (nonatomic) CGSize shadowOffset;
@property (nonatomic) BOOL selectable;
@property (nonatomic) BOOL centerVertically;
@property (nonatomic, getter = isHighlighted) BOOL highlighted;
@property (nonatomic) CGFloat preferredMaxLayoutWidth;
@property (nonatomic) NSInteger textAlignment;
@property (nonatomic) NSUInteger lineBreakMode;

- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines;
- (__kindof NSCell *)textFieldCell;
- (CGSize)sizeThatFits:(CGSize)size;
- (void)sizeToFit;
- (CGFloat)lastBaselineOffsetFromBottom;
- (CGFloat)firstBaselineOffsetFromTop;
- (NSEdgeInsets)alignmentRectInsets;

@end

NS_HEADER_AUDIT_END(nullability, sendability)
