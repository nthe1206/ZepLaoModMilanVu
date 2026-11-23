#import <UIKit/UIKit.h>

/// Floating draggable NTHE button (Red Zalo Logo by default, or custom user image).
@interface ZXBubble : NSObject
+ (void)show;      // show bubble (and remember it)
+ (void)hide;      // hide bubble (and forget it)
+ (void)restoreIfNeeded; // re-show after app launch if it was visible
+ (void)refresh;   // update icon and size immediately if visible
+ (UIImage *)redZaloLogoImageWithSize:(CGSize)size;
+ (UIImage *)currentBubbleImageWithSize:(CGSize)size;
+ (UIImage *)circularCroppedImage:(UIImage *)source diameter:(CGFloat)diameter;
@end
