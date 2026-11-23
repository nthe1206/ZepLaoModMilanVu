#import "ZXBubble.h"
#import "ZXConfig.h"
#import "ZXUI.h"
#import "ZXLog.h"
#import "ZXRecallMarker.h"
#import <objc/runtime.h>

static NSString *const kActiveKey = @"zx_bubble_active";
static NSString *const kPosKey = @"zx_bubble_pos";
static const NSInteger kCircleTag = 9101;
static const NSInteger kImageViewTag = 9102;

static UIWindow *gWindow;

@interface ZXBubbleHost : NSObject
+ (void)onTap:(UITapGestureRecognizer *)g;
+ (void)onPan:(UIPanGestureRecognizer *)g;
+ (void)onLongPress:(UILongPressGestureRecognizer *)g;
@end

static CGFloat ZXCurrentBubbleSize(void)
{
    return (CGFloat)[ZXConfig bubbleSize];
}

static UIWindowScene *ZXActiveScene(void)
{
    if (@available(iOS 13.0, *)) {
        UIWindowScene *fallback = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
            if (!fallback) fallback = (UIWindowScene *)s;
        }
        return fallback;
    }
    return nil;
}

static CGRect ZXScreenBounds(void)
{
    UIWindowScene *sc = ZXActiveScene();
    if (@available(iOS 13.0, *)) if (sc) return sc.coordinateSpace.bounds;
    return UIScreen.mainScreen.bounds;
}

static CGPoint ZXSavedOrigin(void)
{
    CGFloat sz = ZXCurrentBubbleSize();
    CGRect b = ZXScreenBounds();
    NSArray *p = [[NSUserDefaults standardUserDefaults] arrayForKey:kPosKey];
    CGFloat fx = p.count == 2 ? [p[0] doubleValue] : 1.0;   // 1 = right edge
    CGFloat fy = p.count == 2 ? [p[1] doubleValue] : 0.55;
    CGFloat x = fx < 0.5 ? 6 : b.size.width - sz - 6;
    CGFloat y = MAX(60, MIN(b.size.height - sz - 60, fy * b.size.height));
    return CGPointMake(x, y);
}

static void ZXSavePosition(CGRect frame)
{
    CGFloat sz = frame.size.width;
    CGRect b = ZXScreenBounds();
    CGFloat fx = (frame.origin.x + sz / 2) < b.size.width / 2 ? 0.0 : 1.0;
    CGFloat fy = frame.origin.y / MAX(1, b.size.height);
    [[NSUserDefaults standardUserDefaults] setObject:@[@(fx), @(fy)] forKey:kPosKey];
}

@implementation ZXBubbleHost

+ (void)onTap:(UITapGestureRecognizer *)g
{
    (void)g;
    [ZXBubble hide];
    [ZXUI show];
}

+ (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [ZXRecallMarker dumpViewHierarchy];
    UIView *v = g.view;
    [UIView animateWithDuration:0.12 animations:^{ v.transform = CGAffineTransformMakeScale(1.2, 1.2); }
                     completion:^(BOOL d) {
        (void)d;
        [UIView animateWithDuration:0.15 animations:^{ v.transform = CGAffineTransformIdentity; }];
    }];
}

+ (void)onPan:(UIPanGestureRecognizer *)g
{
    UIWindow *w = gWindow;
    if (!w) return;
    CGFloat sz = ZXCurrentBubbleSize();
    CGRect b = ZXScreenBounds();
    CGPoint t = [g translationInView:w];
    [g setTranslation:CGPointZero inView:w];
    CGRect f = w.frame;
    f.origin.x = MAX(0, MIN(b.size.width - sz, f.origin.x + t.x));
    f.origin.y = MAX(40, MIN(b.size.height - sz - 20, f.origin.y + t.y));
    w.frame = f;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat x = (f.origin.x + sz / 2) < b.size.width / 2 ? 6 : b.size.width - sz - 6;
        [UIView animateWithDuration:0.22 animations:^{
            CGRect nf = w.frame;
            nf.origin.x = x;
            w.frame = nf;
        } completion:^(BOOL done) {
            (void)done;
            ZXSavePosition(w.frame);
        }];
    }
}

@end

@implementation ZXBubble

+ (UIImage *)redZaloLogoImageWithSize:(CGSize)size
{
    CGFloat d = MAX(24.0, MIN(size.width, size.height));
    CGSize canvas = CGSizeMake(d, d);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGRect rect = CGRectMake(0, 0, d, d);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:rect];
        [circle addClip];

        // Red Zalo background (#E53935)
        [[UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:1.0] setFill];
        [circle fill];

        // Subtle inner white speech-bubble / ring accent
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(rect, d * 0.045, d * 0.045)];
        ring.lineWidth = MAX(1.2, d * 0.035);
        [[UIColor colorWithWhite:1.0 alpha:0.28] setStroke];
        [ring stroke];

        // Crisp white "Zalo" text in the center
        NSString *label = @"Zalo";
        CGFloat fontSize = round(d * 0.33);
        UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightHeavy];
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: UIColor.whiteColor,
        };
        CGSize textSize = [label sizeWithAttributes:attrs];
        CGRect textRect = CGRectMake((d - textSize.width) / 2.0,
                                     (d - textSize.height) / 2.0,
                                     textSize.width,
                                     textSize.height);
        [label drawInRect:textRect withAttributes:attrs];
    }];
}

+ (UIImage *)circularCroppedImage:(UIImage *)source diameter:(CGFloat)diameter
{
    if (!source) return nil;
    CGFloat d = MAX(32.0, diameter);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d) format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGRect rect = CGRectMake(0, 0, d, d);
        [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
        CGSize src = source.size;
        CGFloat scale = MAX(d / MAX(1.0, src.width), d / MAX(1.0, src.height));
        CGFloat w = src.width * scale;
        CGFloat h = src.height * scale;
        CGRect drawRect = CGRectMake((d - w) / 2.0, (d - h) / 2.0, w, h);
        [source drawInRect:drawRect];
    }];
}

+ (UIImage *)currentBubbleImageWithSize:(CGSize)size
{
    if ([ZXConfig customLogoMode]) {
        NSString *path = [ZXConfig customLogoPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            UIImage *custom = [UIImage imageWithContentsOfFile:path];
            if (custom) {
                return [self circularCroppedImage:custom diameter:MAX(size.width, size.height)];
            }
        }
    }
    return [self redZaloLogoImageWithSize:size];
}

+ (void)applyLayoutAndImage
{
    if (!gWindow) return;
    CGFloat sz = ZXCurrentBubbleSize();
    CGRect b = ZXScreenBounds();
    CGRect f = gWindow.frame;
    f.size = CGSizeMake(sz, sz);
    if (f.origin.x + sz / 2 < b.size.width / 2) {
        f.origin.x = 6;
    } else {
        f.origin.x = b.size.width - sz - 6;
    }
    f.origin.y = MAX(40, MIN(b.size.height - sz - 20, f.origin.y));
    gWindow.frame = f;

    UIView *rootView = gWindow.rootViewController.view;
    UIView *circle = [rootView viewWithTag:kCircleTag];
    UIImageView *iv = (UIImageView *)[circle viewWithTag:kImageViewTag];
    if (circle) {
        circle.frame = CGRectMake(0, 0, sz, sz);
        circle.layer.cornerRadius = sz / 2.0;
    }
    if (iv) {
        iv.frame = circle.bounds;
        iv.layer.cornerRadius = sz / 2.0;
        iv.image = [self currentBubbleImageWithSize:CGSizeMake(sz, sz)];
    }
}

+ (void)refresh
{
    if (gWindow) {
        [self applyLayoutAndImage];
    }
}

+ (void)show
{
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kActiveKey];
    if (gWindow) {
        [self applyLayoutAndImage];
        gWindow.hidden = NO;
        return;
    }

    CGFloat sz = ZXCurrentBubbleSize();
    CGPoint o = ZXSavedOrigin();
    CGRect frame = CGRectMake(o.x, o.y, sz, sz);
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *sc = ZXActiveScene();
        w = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:frame];
    } else {
        w = [[UIWindow alloc] initWithFrame:frame];
    }
    w.frame = frame;
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    if (@available(iOS 13.0, *)) root.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;

    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sz, sz)];
    circle.tag = kCircleTag;
    circle.backgroundColor = UIColor.clearColor;
    circle.layer.cornerRadius = sz / 2.0;
    circle.layer.shadowColor = UIColor.blackColor.CGColor;
    circle.layer.shadowOpacity = 0.36;
    circle.layer.shadowRadius = 6;
    circle.layer.shadowOffset = CGSizeMake(0, 3);

    UIImageView *iv = [[UIImageView alloc] initWithFrame:circle.bounds];
    iv.tag = kImageViewTag;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.layer.cornerRadius = sz / 2.0;
    iv.layer.borderWidth = 1.5;
    iv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    iv.image = [self currentBubbleImageWithSize:CGSizeMake(sz, sz)];
    [circle addSubview:iv];
    [root.view addSubview:circle];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[ZXBubbleHost class] action:@selector(onTap:)];
    [root.view addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[ZXBubbleHost class] action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.7;
    [root.view addGestureRecognizer:lp];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[ZXBubbleHost class] action:@selector(onPan:)];
    [root.view addGestureRecognizer:pan];

    w.hidden = NO;
    gWindow = w;
    ZXLog(@"bubble shown");
}

+ (void)hide
{
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kActiveKey];
    gWindow.hidden = YES;
    gWindow = nil;
}

+ (void)restoreIfNeeded
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:kActiveKey] == nil) {
        [ud setBool:YES forKey:kActiveKey];
    }
    if (!gWindow && [ud boolForKey:kActiveKey]) [self show];
}

@end
