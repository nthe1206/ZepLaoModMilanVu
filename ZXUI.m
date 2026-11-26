#import "ZXUI.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import "ZXHookEngine.h"
#import "ZXScanner.h"
#import "ZXAntiRecall.h"
#import "ZXRecallMarker.h"
#import "ZXBubble.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define ZX_MOD_VERSION @"v1.2"

// ---------------------------------------------------------------- theme palette

static UIColor *ZXColorBgPrimary(void)   { return [UIColor colorWithRed:0.051 green:0.059 blue:0.071 alpha:1.0]; } // #0D0F12
static UIColor *ZXColorCardBg(void)      { return [UIColor colorWithRed:0.094 green:0.106 blue:0.125 alpha:1.0]; } // #181B20
static UIColor *ZXColorCardBorder(void)  { return [UIColor colorWithRed:0.165 green:0.184 blue:0.227 alpha:1.0]; } // #2A2F3A
static UIColor *ZXColorTextSub(void)     { return [UIColor colorWithRed:0.612 green:0.639 blue:0.686 alpha:1.0]; } // #9CA3AF
static UIColor *ZXColorZaloRed(void)     { return [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:1.0]; } // #E53935
static UIColor *ZXColorNavTint(void)     { return [UIColor colorWithRed:0.950 green:0.260 blue:0.210 alpha:1.0]; } // High-contrast red

static UIColor *ZXColorFromHex(NSUInteger hex, CGFloat alpha)
{
    CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
    CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
    CGFloat b = (hex & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:alpha];
}

static NSArray<UIWindow *> *ZXUIAllSceneWindows(void)
{
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w && ![wins containsObject:w]) [wins addObject:w];
            }
        }
    }
    return wins;
}

static UIWindow *ZXKeyWindow(void)
{
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows)
                if (w.isKeyWindow) return w;
        }
    }
    NSArray<UIWindow *> *all = ZXUIAllSceneWindows();
    for (UIWindow *w in all) {
        if (w.isKeyWindow && !w.hidden) return w;
    }
    return all.firstObject;
}

static UIViewController *ZXTopVC(void)
{
    UIViewController *v = ZXKeyWindow().rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

/// Shows a sleek bottom Toast confirmation badge on any view controller.
static void ZXShowToast(UIView *hostView, NSString *message)
{
    UIView *parent = hostView ?: ZXKeyWindow();
    if (!parent || message.length == 0) return;
    UIView *old = [parent viewWithTag:0x544F4153];
    if (old) [old removeFromSuperview];

    UILabel *lbl = [UILabel new];
    lbl.text = message;
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;

    CGFloat maxW = parent.bounds.size.width - 48.0;
    CGSize sz = [lbl sizeThatFits:CGSizeMake(maxW - 28.0, 60.0)];
    CGFloat boxW = MIN(maxW, MAX(180.0, ceil(sz.width) + 28.0));
    CGFloat boxH = MAX(38.0, ceil(sz.height) + 16.0);

    UIView *toast = [[UIView alloc] initWithFrame:CGRectMake((parent.bounds.size.width - boxW) / 2.0,
                                                             parent.bounds.size.height - boxH - 46.0,
                                                             boxW, boxH)];
    toast.tag = 0x544F4153;
    toast.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    toast.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:0.96];
    toast.layer.cornerRadius = boxH / 2.0;
    toast.layer.borderWidth = 1.2;
    toast.layer.borderColor = ZXColorZaloRed().CGColor;
    toast.userInteractionEnabled = NO;

    lbl.frame = CGRectInset(toast.bounds, 12, 6);
    [toast addSubview:lbl];
    toast.alpha = 0;
    toast.transform = CGAffineTransformMakeTranslation(0, 14);
    [parent addSubview:toast];

    [UIView animateWithDuration:0.22 animations:^{
        toast.alpha = 1.0;
        toast.transform = CGAffineTransformIdentity;
    } completion:^(BOOL f) {
        (void)f;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL done) {
                (void)done;
                [toast removeFromSuperview];
            }];
        });
    }];
}

static UIView *ZXMakeVersionTitleView(void)
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 180, 40)];
    UILabel *mainLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 2, 180, 20)];
    mainLbl.text = @"thanhthe";
    mainLbl.textAlignment = NSTextAlignmentCenter;
    mainLbl.textColor = UIColor.whiteColor;
    mainLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy];
    [v addSubview:mainLbl];

    UILabel *subLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, 180, 15)];
    subLbl.text = [NSString stringWithFormat:@"thanhthe Mod • %@", ZX_MOD_VERSION];
    subLbl.textAlignment = NSTextAlignmentCenter;
    subLbl.textColor = ZXColorNavTint();
    subLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    [v addSubview:subLbl];
    return v;
}

static void ZXStyleNavBar(UINavigationBar *bar)
{
    if (!bar) return;
    if (@available(iOS 13.0, *)) bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.prefersLargeTitles = NO;
    bar.translucent = NO;
    bar.tintColor = ZXColorNavTint();
    bar.barTintColor = ZXColorBgPrimary();
    bar.backgroundColor = ZXColorBgPrimary();
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = ZXColorBgPrimary();
        ap.shadowColor = ZXColorCardBorder();
        ap.titleTextAttributes = @{
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightBold]
        };
        ap.largeTitleTextAttributes = @{
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSFontAttributeName: [UIFont systemFontOfSize:28 weight:UIFontWeightHeavy]
        };
        bar.standardAppearance = ap;
        bar.scrollEdgeAppearance = ap;
        bar.compactAppearance = ap;
        if (@available(iOS 15.0, *)) {
            bar.compactScrollEdgeAppearance = ap;
        }
    }
}

/// Custom high-contrast bar button with SF Symbol icon so iOS 18-26 never renders blank white buttons.
static UIBarButtonItem *ZXMakeNavButton(NSString *symbolName, NSString *title, UIColor *iconColor, id target, SEL action)
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.backgroundColor = ZXColorCardBg();
    btn.layer.cornerRadius = 17;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = ZXColorCardBorder().CGColor;
    btn.clipsToBounds = YES;

    UIImage *img = nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
        img = [[UIImage systemImageNamed:symbolName withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = iconColor ?: ZXColorNavTint();
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;

    UILabel *lbl = [UILabel new];
    lbl.text = title;
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    lbl.userInteractionEnabled = NO;
    [lbl sizeToFit];

    CGFloat padX = 10.0;
    CGFloat iconSz = 18.0;
    CGFloat gap = title.length ? 5.0 : 0.0;
    CGFloat totalW = padX + iconSz + gap + ceil(lbl.bounds.size.width) + padX;
    CGFloat h = 34.0;
    btn.frame = CGRectMake(0, 0, totalW, h);
    iv.frame = CGRectMake(padX, (h - iconSz) / 2.0, iconSz, iconSz);
    lbl.frame = CGRectMake(padX + iconSz + gap, 0, ceil(lbl.bounds.size.width), h);

    [btn addSubview:iv];
    if (title.length) [btn addSubview:lbl];
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    btn.accessibilityLabel = title;
    return [[UIBarButtonItem alloc] initWithCustomView:btn];
}

// ---------------------------------------------------------------- Face ID / Passcode / PIN Auth Helper

static void ZXAuthenticateUserFromVC(UIViewController *vc, NSString *reason, void (^onSuccess)(void))
{
    if (!onSuccess) return;
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&err]) {
        [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:(reason ?: @"Xác thực để truy cập mục bảo mật thanhthe")
                      reply:^(BOOL success, NSError * _Nullable error) {
            (void)error;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    onSuccess();
                } else if ([ZXConfig chatLockPIN].length > 0) {
                    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nhập mã PIN dự phòng"
                                                                               message:reason
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                        tf.keyboardType = UIKeyboardTypeNumberPad;
                        tf.secureTextEntry = YES;
                        tf.placeholder = @"Mã PIN 4 số";
                    }];
                    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
                    [a addAction:[UIAlertAction actionWithTitle:@"Xác nhận" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                        (void)act;
                        if ([a.textFields.firstObject.text isEqualToString:[ZXConfig chatLockPIN]]) {
                            onSuccess();
                        }
                    }]];
                    [vc presentViewController:a animated:YES completion:nil];
                }
            });
        }];
        return;
    }

    NSString *pin = [ZXConfig chatLockPIN];
    if (pin.length == 0) {
        onSuccess();
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nhập mã PIN bảo mật"
                                                               message:reason
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.secureTextEntry = YES;
        tf.placeholder = @"Mã PIN 4 số";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Mở" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        if ([a.textFields.firstObject.text isEqualToString:pin]) {
            onSuccess();
        }
    }]];
    [vc presentViewController:a animated:YES completion:nil];
}

// ---------------------------------------------------------------- CoreGraphics Red Zalo Logo & Bubble Sync

static UIImage *ZXDrawRedZaloLogo(CGSize size)
{
    CGFloat d = MAX(24.0, MIN(size.width, size.height));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d) format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGRect rect = CGRectMake(0, 0, d, d);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:rect];
        [circle addClip];

        [ZXColorZaloRed() setFill];
        [circle fill];

        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(rect, d * 0.045, d * 0.045)];
        ring.lineWidth = MAX(1.2, d * 0.035);
        [[UIColor colorWithWhite:1.0 alpha:0.30] setStroke];
        [ring stroke];

        NSString *text = @"Zalo";
        UIFont *font = [UIFont systemFontOfSize:round(d * 0.33) weight:UIFontWeightHeavy];
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: UIColor.whiteColor
        };
        CGSize ts = [text sizeWithAttributes:attrs];
        CGRect tr = CGRectMake((d - ts.width) / 2.0, (d - ts.height) / 2.0, ts.width, ts.height);
        [text drawInRect:tr withAttributes:attrs];
    }];
}

static UIImage *ZXCropCircularImage(UIImage *source, CGFloat diameter)
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
        [source drawInRect:CGRectMake((d - w) / 2.0, (d - h) / 2.0, w, h)];
    }];
}

static UIImage *ZXCurrentFloatingLogo(CGSize size)
{
    if ([ZXConfig customLogoMode]) {
        NSString *path = [ZXConfig customLogoPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            UIImage *custom = [UIImage imageWithContentsOfFile:path];
            if (custom) return ZXCropCircularImage(custom, MAX(size.width, size.height));
        }
    }
    return ZXDrawRedZaloLogo(size);
}

static void ZXRefreshFloatingBubbleNow(void)
{
    SEL refreshSel = NSSelectorFromString(@"refresh");
    if ([ZXBubble respondsToSelector:refreshSel]) {
        ((void (*)(id, SEL))[ZXBubble methodForSelector:refreshSel])([ZXBubble class], refreshSel);
    }
    CGFloat sz = (CGFloat)[ZXConfig bubbleSize];
    UIImage *logo = ZXCurrentFloatingLogo(CGSizeMake(sz, sz));
    for (UIWindow *w in ZXUIAllSceneWindows()) {
        if (w.windowLevel < UIWindowLevelAlert + 50 || w.windowLevel >= UIWindowLevelStatusBar + 90) continue;
        UIView *root = w.rootViewController.view;
        if (!root || root.subviews.count == 0) continue;
        CGRect b = w.windowScene ? w.windowScene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        CGRect wf = w.frame;
        wf.size = CGSizeMake(sz, sz);
        wf.origin.x = (wf.origin.x + sz / 2.0 < b.size.width / 2.0) ? 6.0 : (b.size.width - sz - 6.0);
        wf.origin.y = MAX(40.0, MIN(b.size.height - sz - 20.0, wf.origin.y));
        w.frame = wf;

        UIView *circle = root.subviews.firstObject;
        circle.frame = CGRectMake(0, 0, sz, sz);
        circle.backgroundColor = UIColor.clearColor;
        circle.layer.cornerRadius = sz / 2.0;
        circle.layer.borderWidth = 0;
        for (UIView *sub in circle.subviews) {
            if ([sub isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)sub;
                iv.frame = circle.bounds;
                iv.contentMode = UIViewContentModeScaleAspectFill;
                iv.clipsToBounds = YES;
                iv.layer.cornerRadius = sz / 2.0;
                iv.image = logo;
            }
        }
    }
}

static void ZXHookBubbleShow(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class meta = object_getClass([ZXBubble class]);
        SEL sel = @selector(show);
        Method m = class_getClassMethod([ZXBubble class], sel);
        if (!m || !meta) return;
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^(id self_) {
            ((void (*)(id, SEL))orig)(self_, sel);
            ZXRefreshFloatingBubbleNow();
        });
        method_setImplementation(m, hook);
    });
}

// ---------------------------------------------------------------- text viewer/editor

@interface ZXTextViewController : UIViewController
@property (nonatomic, copy) NSString *initialText;
@property (nonatomic, assign) BOOL editable;
@property (nonatomic, copy) BOOL (^onSave)(NSString *text, NSString **error);
@property (nonatomic, strong) UITextView *textView;
@end

@implementation ZXTextViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = ZXColorBgPrimary();
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.backgroundColor = ZXColorBgPrimary();
    self.textView.textColor = UIColor.whiteColor;
    self.textView.tintColor = ZXColorZaloRed();
    self.textView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.textView.text = self.initialText;
    self.textView.editable = self.editable;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.view addSubview:self.textView];
    if (self.editable)
        self.navigationItem.rightBarButtonItem = ZXMakeNavButton(@"checkmark.circle.fill", @"Lưu", ZXColorZaloRed(), self, @selector(save));
    else
        self.navigationItem.rightBarButtonItem = ZXMakeNavButton(@"doc.on.doc.fill", @"Sao chép", ZXColorZaloRed(), self, @selector(copyAll));
}
- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    ZXStyleNavBar(self.navigationController.navigationBar);
}
- (void)copyAll
{
    [UIPasteboard generalPasteboard].string = self.textView.text ?: @"";
    ZXShowToast(self.view, @"Đã sao chép vào bộ nhớ tạm");
}
- (void)save
{
    NSString *err = nil;
    if (self.onSave && !self.onSave(self.textView.text, &err)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Lỗi" message:err ?: @"Không lưu được" preferredStyle:UIAlertControllerStyleAlert];
        if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self.navigationController popViewControllerAnimated:YES];
}
@end

// ---------------------------------------------------------------- Screen 1: Hidden Chats Viewer

@interface ZXHiddenChatsViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary *> *chats;
@end

@implementation ZXHiddenChatsViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.title = @"Trò chuyện đang ẩn";
    self.tableView.backgroundColor = ZXColorBgPrimary();
    self.tableView.separatorColor = ZXColorCardBorder();
    self.navigationItem.rightBarButtonItem = ZXMakeNavButton(@"arrow.clockwise.circle.fill", @"Quét lại", ZXColorZaloRed(), self, @selector(rescanAndReload));

    UIView *headerWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 104)];
    headerWrap.backgroundColor = UIColor.clearColor;

    UIButton *dumpBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    dumpBtn.frame = CGRectMake(16, 10, headerWrap.bounds.size.width - 32, 40);
    dumpBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    dumpBtn.backgroundColor = [UIColor colorWithRed:0.055 green:0.647 blue:0.914 alpha:0.16];
    dumpBtn.layer.cornerRadius = 10;
    dumpBtn.layer.borderWidth = 1.0;
    dumpBtn.layer.borderColor = [UIColor colorWithRed:0.055 green:0.647 blue:0.914 alpha:1.0].CGColor;
    [dumpBtn setTitle:@"🔬 Dump Introspection Zalo 26 (Share Sheet)" forState:UIControlStateNormal];
    [dumpBtn setTitleColor:[UIColor colorWithRed:0.220 green:0.741 blue:0.973 alpha:1.0] forState:UIControlStateNormal];
    dumpBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    [dumpBtn addTarget:self action:@selector(onDumpIntrospectionTapped:) forControlEvents:UIControlEventTouchUpInside];
    [headerWrap addSubview:dumpBtn];

    UIButton *clearCacheBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    clearCacheBtn.frame = CGRectMake(16, 56, headerWrap.bounds.size.width - 32, 40);
    clearCacheBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    clearCacheBtn.backgroundColor = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:0.16];
    clearCacheBtn.layer.cornerRadius = 10;
    clearCacheBtn.layer.borderWidth = 1.0;
    clearCacheBtn.layer.borderColor = ZXColorZaloRed().CGColor;
    [clearCacheBtn setTitle:@"🧹 Lọc mục thừa & Xóa cache tên sai" forState:UIControlStateNormal];
    [clearCacheBtn setTitleColor:ZXColorZaloRed() forState:UIControlStateNormal];
    clearCacheBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    [clearCacheBtn addTarget:self action:@selector(onClearWrongNamesTapped) forControlEvents:UIControlEventTouchUpInside];
    [headerWrap addSubview:clearCacheBtn];
    self.tableView.tableHeaderView = headerWrap;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onHiddenChatsUpdated) name:@"ZXHiddenChatsUpdatedNotification" object:nil];
    self.chats = [ZXHookEngine discoveredHiddenChats] ?: @[];
    [ZXHookEngine scanMemoryForHiddenChats];
}
- (void)onDumpIntrospectionTapped:(UIButton *)sender
{
    ZXShowToast(self.navigationController.view ?: self.view, @"Đang trích xuất Class, SQLite & Cell Model...");
    NSString *pinSnap = [ZXHookEngine lastPinSearchIntrospectSnapshot];
    NSString *liveSceneSnap = [ZXScanner dumpLiveSceneListModelsOnMainThread];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *outPath = [ZXScanner runHiddenIntrospectionWithPinSnapshot:pinSnap liveSceneDump:liveSceneSnap];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || outPath.length == 0) return;
            NSURL *fileURL = [NSURL fileURLWithPath:outPath];
            UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
            if (@available(iOS 13.0, *)) av.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            av.popoverPresentationController.sourceView = sender ?: strongSelf.view;
            [strongSelf presentViewController:av animated:YES completion:nil];
        });
    });
}
- (void)onClearWrongNamesTapped
{
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Làm sạch danh sách Trò chuyện ẩn"
                                                                     message:@"Chọn thao tác làm sạch dữ liệu ẩn trên thiết bị:"
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    if (@available(iOS 13.0, *)) confirm.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [confirm addAction:[UIAlertAction actionWithTitle:@"🔍 Chỉ lọc bỏ mục thừa (giữ tên đã xác thực)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        [ZXHookEngine pruneAndRescanHiddenChats];
        [self reloadChats];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã lọc sạch các cuộc trò chuyện bình thường");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"🗑️ Xóa toàn bộ cache tên & Quét lại từ đầu" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        (void)act;
        [ZXHookEngine clearResolvedNamesCache];
        [self reloadChats];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã xóa sạch zx_resolved_profiles.json & quét lại");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    confirm.popoverPresentationController.sourceView = self.tableView.tableHeaderView ?: self.view;
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    ZXStyleNavBar(self.navigationController.navigationBar);
}
- (void)onHiddenChatsUpdated
{
    void (^updateUI)(void) = ^{
        self.chats = [ZXHookEngine discoveredHiddenChats] ?: @[];
        [self.tableView reloadData];
        ZXShowToast(self.navigationController.view ?: self.view,
                    [NSString stringWithFormat:@"Quét hoàn tất: %lu hội thoại ẩn", (unsigned long)self.chats.count]);
    };
    if ([NSThread isMainThread]) updateUI();
    else dispatch_async(dispatch_get_main_queue(), updateUI);
}
- (void)reloadChats
{
    self.chats = [ZXHookEngine discoveredHiddenChats] ?: @[];
    [self.tableView reloadData];
}
- (void)rescanAndReload
{
    ZXShowToast(self.navigationController.view ?: self.view, @"Đang quét lại HiddenChatEntity & gộp dữ liệu ẩn...");
    [ZXHookEngine scanMemoryForHiddenChats];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return MAX(1, (NSInteger)self.chats.count);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HiddenCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HiddenCell"];
        if (@available(iOS 13.0, *)) cell.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        cell.backgroundColor = ZXColorCardBg();
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
        cell.detailTextLabel.textColor = ZXColorTextSub();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5];
        cell.detailTextLabel.numberOfLines = 2;
    }
    if (self.chats.count == 0) {
        cell.textLabel.text = @"Chưa phát hiện cuộc trò chuyện ẩn nào";
        cell.detailTextLabel.text = @"Bấm nút 'Quét lại' ở góc phải để quét cơ sở dữ liệu SQLite của Zalo.";
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSDictionary *c = self.chats[indexPath.row];
    NSString *uid = [c[@"uid"] description] ?: @"?";
    NSString *rawName = [c[@"rawName"] description] ?: @"";
    BOOL modelVerified = [c[@"modelVerified"] boolValue];
    NSString *srcBadge = modelVerified ? @"Khớp 1-1 Model" : @"HiddenChatEntity";
    BOOL hasRealName = [ZXScanner isValidHumanDisplayName:rawName excludeUID:uid];
    NSString *titleText = hasRealName
        ? [NSString stringWithFormat:@"%@ (ID: %@)", rawName, uid]
        : [NSString stringWithFormat:@"Chưa giải mã tên (ID: %@)", uid];
    cell.textLabel.text = titleText;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"[%@] • %@", srcBadge, c[@"lastMessage"] ?: @"(Trống)"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView; (void)indexPath;
    return self.chats.count > 0;
}
- (void)deleteHiddenRowAtIndex:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)self.chats.count) return;
    NSDictionary *c = self.chats[(NSUInteger)row];
    NSString *uid = [c[@"uid"] description] ?: @"";
    if (uid.length == 0) return;
    [ZXHookEngine removeHiddenChatEntryWithID:uid];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadChats];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã xóa dòng khỏi danh sách Trò chuyện ẩn");
    });
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0))
{
    (void)tableView;
    if (self.chats.count == 0) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delAct = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Xóa"
                                                                       handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        (void)action; (void)sourceView;
        [weakSelf deleteHiddenRowAtIndex:indexPath.row];
        if (completionHandler) completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delAct]];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    if (editingStyle == UITableViewCellEditingStyleDelete && self.chats.count > 0) {
        [self deleteHiddenRowAtIndex:indexPath.row];
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.chats.count == 0) return;
    NSDictionary *c = self.chats[indexPath.row];
    NSString *uid = [c[@"uid"] description] ?: @"";
    NSString *rawName = [c[@"rawName"] description] ?: @"";
    BOOL hasRealName = [ZXScanner isValidHumanDisplayName:rawName excludeUID:uid];
    BOOL isSyntheticUID = ([uid hasPrefix:@"pin:"] || [uid hasPrefix:@"hide:"]);
    // STRICT RULE: NEVER pass numeric uid or "Hội thoại ẩn..." placeholder as a search name!
    NSString *verifiedRealName = hasRealName ? rawName : @"";
    NSString *sheetTitle = hasRealName
        ? (isSyntheticUID ? rawName : [NSString stringWithFormat:@"%@ (ID: %@)", rawName, uid])
        : [NSString stringWithFormat:@"Hội thoại ẩn (ID: %@)", uid];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:sheetTitle
                                                                   message:[NSString stringWithFormat:@"%@", c[@"lastMessage"] ?: @""]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (@available(iOS 13.0, *)) sheet.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [sheet addAction:[UIAlertAction actionWithTitle:@"💬 Mở thẳng khung chat" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                // Walk presentingViewController chain to the root-most host so ALL thanhthe popups close cleanly
                UIViewController *rootPresenter = self;
                while (rootPresenter.presentingViewController) {
                    rootPresenter = rootPresenter.presentingViewController;
                }
                UIWindow *keyWin = ZXKeyWindow();
                if (!rootPresenter && keyWin.rootViewController) {
                    rootPresenter = keyWin.rootViewController;
                }
                void (^afterDismiss)(void) = ^{
                    @try {
                        [ZXBubble show];
                        ZXRefreshFloatingBubbleNow();
                        [ZXHookEngine openChatWithID:uid displayName:verifiedRealName];
                    } @catch (NSException *ex) {
                        ZXLog(@"openChatWithID afterDismiss exception: %@", ex.reason);
                    }
                };
                if (rootPresenter.presentedViewController) {
                    [rootPresenter dismissViewControllerAnimated:YES completion:afterDismiss];
                } else {
                    [self dismissViewControllerAnimated:YES completion:afterDismiss];
                }
            } @catch (NSException *ex) {
                ZXLog(@"HiddenChat open action exception: %@", ex.reason);
            }
        });
    }]];
    if (!isSyntheticUID) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"👁️ Bỏ ẩn nhanh hội thoại này" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            (void)act;
            [ZXHookEngine unhideChatWithID:uid];
            [self reloadChats];
            ZXShowToast(self.navigationController.view ?: self.view,
                        [NSString stringWithFormat:@"Đã bỏ ẩn %@ & cập nhật danh sách Tin nhắn", (hasRealName ? rawName : sheetTitle)]);
        }]];
    }
    if (hasRealName) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"📋 Sao chép Tên thật" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            (void)act;
            [UIPasteboard generalPasteboard].string = verifiedRealName;
            ZXShowToast(self.navigationController.view ?: self.view, @"Đã sao chép tên thật vào bộ nhớ tạm");
        }]];
        if (!isSyntheticUID) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"🧹 Xóa tên bị gán sai của ID này" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
                (void)act;
                [ZXHookEngine clearResolvedNameForID:uid];
                [self reloadChats];
                ZXShowToast(self.navigationController.view ?: self.view, @"Đã xóa tên cũ của hội thoại này");
            }]];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"🗑️ Xóa dòng này khỏi danh sách" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        (void)act;
        [self deleteHiddenRowAtIndex:indexPath.row];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

// ---------------------------------------------------------------- Screen 2: Locked Chats Manager

@interface ZXLockedChatsViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@end

@implementation ZXLockedChatsViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.title = @"Danh sách chat bị khóa";
    self.tableView.backgroundColor = ZXColorBgPrimary();
    self.tableView.separatorColor = ZXColorCardBorder();
    self.navigationItem.rightBarButtonItem = ZXMakeNavButton(@"plus.circle.fill", @"Thêm", ZXColorZaloRed(), self, @selector(addLockedChat));
    [self reloadList];
}
- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    ZXStyleNavBar(self.navigationController.navigationBar);
}
- (void)reloadList
{
    self.items = [ZXConfig lockedChats];
    [self.tableView reloadData];
}
- (void)addLockedChat
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Thêm phòng chat cần khóa"
                                                               message:@"Nhập Tên hiển thị hoặc UID của phòng chat (hoặc nhấn giữ trực tiếp hội thoại ở danh sách chat Zalo)"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Tên hiển thị hoặc UID...";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Khóa" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        NSString *val = a.textFields.firstObject.text ?: @"";
        if (val.length) {
            [ZXConfig addLockedChatWithID:val name:val];
            [ZXConfig setBool:YES forKey:ZXK_CHAT_LOCK_ENABLED];
            [self reloadList];
            ZXShowToast(self.navigationController.view ?: self.view, [NSString stringWithFormat:@"Đã khóa: %@", val]);
        }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return MAX(1, (NSInteger)self.items.count);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LockCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LockCell"];
        if (@available(iOS 13.0, *)) cell.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        cell.backgroundColor = ZXColorCardBg();
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
        cell.detailTextLabel.textColor = ZXColorTextSub();
    }
    if (self.items.count == 0) {
        cell.textLabel.text = @"Chưa có phòng chat nào bị khóa";
        cell.detailTextLabel.text = @"Bấm nút '+ Thêm' ở góc trên hoặc nhấn giữ hội thoại ngoài danh sách chat Zalo để khóa.";
        return cell;
    }
    NSDictionary *d = self.items[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"🔒 %@", d[@"name"] ?: d[@"id"]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID/Tên khớp: %@ • Bấm để mở khóa (xóa khỏi danh sách)", d[@"id"]];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.items.count == 0) return;
    NSDictionary *d = self.items[indexPath.row];
    NSString *cid = [d[@"id"] description] ?: @"";
    [ZXConfig removeLockedChatWithID:cid];
    [self reloadList];
    ZXShowToast(self.navigationController.view ?: self.view, [NSString stringWithFormat:@"Đã mở khóa: %@", cid]);
}
@end

// ---------------------------------------------------------------- Screen 3: Call Recordings Manager

@interface ZXCallRecordsViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *files;
@property (nonatomic, strong) AVAudioPlayer *player;
@end

@implementation ZXCallRecordsViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.title = @"Bản ghi âm cuộc gọi";
    self.tableView.backgroundColor = ZXColorBgPrimary();
    self.tableView.separatorColor = ZXColorCardBorder();
    [self updateNavBtn];
    [self reloadFiles];
}
- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    ZXStyleNavBar(self.navigationController.navigationBar);
}
- (void)updateNavBtn
{
    BOOL rec = [ZXHookEngine isCallRecording];
    NSString *title = rec ? @"Dừng ghi" : @"Ghi âm ngay";
    NSString *sym = rec ? @"stop.circle.fill" : @"record.circle.fill";
    self.navigationItem.rightBarButtonItem = ZXMakeNavButton(sym, title, ZXColorZaloRed(), self, @selector(toggleRec));
}
- (void)toggleRec
{
    [ZXHookEngine toggleManualCallRecording];
    [self updateNavBtn];
    [self reloadFiles];
    ZXShowToast(self.navigationController.view ?: self.view,
                [ZXHookEngine isCallRecording] ? @"Đang ghi âm (.m4a)..." : @"Đã lưu bản ghi âm");
}
- (void)reloadFiles
{
    NSString *dir = [ZXConfig callRecordsDir];
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray *m4a = [NSMutableArray new];
    for (NSString *f in all) {
        if ([f.lowercaseString hasSuffix:@".m4a"] || [f.lowercaseString hasSuffix:@".caf"]) [m4a addObject:f];
    }
    [m4a sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a];
    }];
    self.files = m4a;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return MAX(1, (NSInteger)self.files.count);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RecCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RecCell"];
        if (@available(iOS 13.0, *)) cell.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        cell.backgroundColor = ZXColorCardBg();
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        cell.detailTextLabel.textColor = ZXColorTextSub();
    }
    if (self.files.count == 0) {
        cell.textLabel.text = @"Chưa có bản ghi âm nào";
        cell.detailTextLabel.text = @"Thư mục: Documents/NTHE_CallRecords/ (.m4a)";
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSString *fn = self.files[indexPath.row];
    NSString *path = [[ZXConfig callRecordsDir] stringByAppendingPathComponent:fn];
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    double kb = [attr fileSize] / 1024.0;
    cell.textLabel.text = [NSString stringWithFormat:@"🎙️ %@", fn];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Dung lượng: %.1f KB • Bấm để Nghe lại / Chia sẻ / Xóa", kb];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.files.count == 0) return;
    NSString *fn = self.files[indexPath.row];
    NSString *path = [[ZXConfig callRecordsDir] stringByAppendingPathComponent:fn];
    NSURL *url = [NSURL fileURLWithPath:path];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:fn message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (@available(iOS 13.0, *)) sheet.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [sheet addAction:[UIAlertAction actionWithTitle:@"▶️ Nghe lại bản ghi âm" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
        [self.player prepareToPlay];
        [self.player play];
        ZXShowToast(self.navigationController.view ?: self.view, [NSString stringWithFormat:@"Đang phát: %@", fn]);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"📤 Chia sẻ / Lưu tệp .m4a" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        if (@available(iOS 13.0, *)) av.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        av.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:av animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"🗑️ Xóa bản ghi âm" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        (void)act;
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [self reloadFiles];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã xóa bản ghi âm");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

// ---------------------------------------------------------------- forward declarations for floating tabbar

static void ZXHookFloatingTabBar(void);
static BOOL ZXFloatingTabBarOn(void);
static void ZXNoteTabBarInteraction(UIView *bar);
static BOOL ZXReduceMotion(void) { return UIAccessibilityIsReduceMotionEnabled(); }
static BOOL ZXReduceTransparency(void) { return UIAccessibilityIsReduceTransparencyEnabled(); }

// ---------------------------------------------------------------- 5 Category Cards Catalog

static NSArray<NSDictionary *> *ZXFiveCategories(void)
{
    return @[
        @{
            @"title": @"Quyền riêng tư & Ẩn danh",
            @"desc": @"Tạm hiện chat ẩn, Danh sách chat đang ẩn, Khóa chat Face ID/PIN, Giữ kết nối nhận tin nền, Xem Story ẩn danh",
            @"icon": @"eye.slash.fill",
            @"color": @(0x3B82F6),
            @"items": @[
                @{ @"key": ZXK_UNHIDE_CHATS, @"title": @"Tạm hiện tất cả chat bị ẩn", @"sub": @"Quét SQLite & RAM ẩn hội thoại và trả về NO để hiện trên danh sách chính", @"icon": @"eye.circle.fill", @"color": @(0x10B981), @"kw": @"tam hien chat an hidden conversation" },
                @{ @"action": @"hidden_chats_list", @"title": @"Danh sách trò chuyện đang ẩn", @"sub": @"Xác thực Face ID / PIN để quét SQLite + RAM Profile, xem tên thật và mở thẳng chat", @"icon": @"list.bullet.rectangle.portrait.fill", @"color": @(0x14B8A6), @"kw": @"danh sach tro chuyen dang an hidden list" },
                @{ @"key": ZXK_KEEP_ALIVE_BG, @"title": @"Giữ kết nối nhận tin nền (Anti-Sleep)", @"sub": @"Duy trì WebSocket & âm thanh im lặng 8000Hz khi ẩn ứng dụng ra màn hình chính", @"icon": @"antenna.radiowaves.left.and.right.circle.fill", @"color": @(0x22C55E), @"kw": @"giu ket noi nhan tin nen anti sleep background keep alive" },
                @{ @"key": ZXK_CHAT_LOCK_ENABLED, @"title": @"Khóa phòng chat tự chọn (Face ID / PIN)", @"sub": @"Che mờ & yêu cầu Face ID / Mật khẩu khi mở phòng chat đã khóa", @"icon": @"lock.shield.fill", @"color": @(0xE53935), @"kw": @"khoa phong chat faceid pin lock" },
                @{ @"action": @"set_lock_pin", @"title": @"Đặt / Đổi mã PIN dự phòng (4 số)", @"sub": @"Dùng để mở khóa chat và xem danh sách chat ẩn khi không dùng Face ID", @"icon": @"key.fill", @"color": @(0xF59E0B), @"kw": @"ma pin 4 so du phong" },
                @{ @"action": @"locked_chats_list", @"title": @"Danh sách chat bị khóa", @"sub": @"Thêm/xóa phòng chat cần khóa (hoặc nhấn giữ hội thoại ở danh sách chat)", @"icon": @"lock.rectangle.stack.fill", @"color": @(0xEF4444), @"kw": @"danh sach chat bi khoa locked" },
                @{ @"key": ZXK_GHOST_STORY, @"title": @"Xem Khoảnh khắc (Story) ẩn danh", @"sub": @"Chặn gửi gói tin xác nhận đã xem Story/Khoảnh khắc lên server", @"icon": @"sparkles.tv.fill", @"color": @(0x8B5CF6), @"kw": @"story khoanh khac an danh seen" },
                @{ @"key": ZXK_BLOCK_SEEN, @"title": @"Chặn trạng thái \"Đã xem\"", @"sub": @"Người gửi không biết bạn đã đọc tin nhắn", @"icon": @"eye.slash.fill", @"color": @(0x3B82F6), @"kw": @"seen ghost da xem doc" },
                @{ @"key": ZXK_SILENT_TYPING, @"title": @"Ẩn trạng thái \"Đang nhập\"", @"sub": @"Người nhận không thấy bạn đang soạn tin", @"icon": @"keyboard.fill", @"color": @(0x0EA5E9), @"kw": @"typing dang nhap soan go" },
            ]
        },
        @{
            @"title": @"Tin nhắn & Spam tự động",
            @"desc": @"Gửi tin nhắn lặp lại, Chống thu hồi tin nhắn, Đánh dấu tin thu hồi",
            @"icon": @"paperplane.fill",
            @"color": @(0xE53935),
            @"items": @[
                @{ @"key": ZXK_MSG_REPEATER, @"title": @"Nút Spam nổi trên bàn phím (↻ xN)", @"sub": @"Hiện nút đỏ ↻ xN ở tầng cửa sổ cao nhất ngay phía trên bàn phím Zalo", @"icon": @"repeat.circle.fill", @"color": @(0xE53935), @"kw": @"gui tin nhan lap lai repeater spam delay" },
                @{ @"action": @"open_repeater", @"title": @"Mở bảng Gửi tin nhắn lặp lại", @"sub": @"Chọn nhanh 5/10/20/50 lần, giãn cách 0.1s–2.0s tùy chỉnh, chống trùng tin", @"icon": @"paperplane.circle.fill", @"color": @(0xF97316), @"kw": @"mo bang gui tin lap lai spam delay" },
                @{ @"key": ZXK_ANTI_RECALL, @"title": @"Chống thu hồi tin nhắn", @"sub": @"Tin vẫn hiển thị trong khung chat khi đối phương thu hồi", @"icon": @"shield.checkered", @"color": @(0x10B981), @"kw": @"anti recall chong thu hoi" },
                @{ @"key": ZXK_SHOW_CONTENT, @"title": @"Hiện nội dung tin bị thu hồi/xóa", @"sub": @"Lưu tạm nội dung tin nhắn nhận được trên thiết bị", @"icon": @"text.bubble.fill", @"color": @(0x14B8A6), @"kw": @"noi dung thu hoi xoa" },
                @{ @"key": ZXK_RECALL_NOTE, @"title": @"Đánh dấu nhãn \"đã thu hồi\"", @"sub": @"Hiện ghi chú nhỏ trong bong bóng tin nhắn được giữ lại", @"icon": @"tag.fill", @"color": @(0x059669), @"kw": @"nhan label da thu hoi" },
                @{ @"key": ZXK_ANTI_RECALL_INCLUDE_ME, @"title": @"Áp dụng cả tin do mình thu hồi", @"sub": @"Giữ lại luôn tin nhắn do chính bạn thu hồi", @"icon": @"person.crop.circle.badge.checkmark", @"color": @(0x10B981), @"kw": @"minh thu hoi" },
                @{ @"key": ZXK_ANTI_DELETE, @"title": @"Giữ tin bị xóa", @"sub": @"Ngăn xóa tin nhắn phía máy của bạn", @"icon": @"trash.slash.fill", @"color": @(0x22C55E), @"kw": @"anti delete chong xoa" },
                @{ @"key": ZXK_ANTI_DELETE_INCLUDE_ME, @"title": @"Áp dụng cả tin do mình xóa", @"sub": @"Giữ lại luôn tin nhắn do chính bạn bấm xóa", @"icon": @"person.fill.checkmark", @"color": @(0x16A34A), @"kw": @"minh xoa" },
                @{ @"action": @"history", @"title": @"Lịch sử tin bị thu hồi / xóa", @"sub": @"Xem danh sách toàn bộ tin nhắn đã bắt được", @"icon": @"clock.arrow.circlepath", @"color": @(0x0EA5E9), @"kw": @"lich su history" },
                @{ @"action": @"clearmarks", @"title": @"Xóa danh sách tin đã đánh dấu", @"sub": @"Làm sạch các nhãn đã thu hồi trên khung chat", @"icon": @"sparkles", @"color": @(0xF59E0B), @"kw": @"xoa danh dau clear marks" },
                @{ @"action": @"clearcache", @"title": @"Xóa bộ nhớ đệm tin nhắn", @"sub": @"Dọn dữ liệu tin nhắn lưu tạm trên máy", @"icon": @"internaldrive.fill", @"color": @(0xF97316), @"kw": @"xoa cache bo nho dem" },
                @{ @"action": @"uid", @"title": @"User ID Zalo của bạn", @"sub": @"Dùng để phân biệt tin nhắn của bạn và người khác", @"icon": @"person.text.rectangle.fill", @"color": @(0x6366F1), @"kw": @"uid user id" },
            ]
        },
        @{
            @"title": @"Cuộc gọi & Âm thanh",
            @"desc": @"Bảo vệ IP Force Relay, Ghi âm cuộc gọi tự động, Danh sách bản ghi âm, Tốc độ & Lưu tin nhắn thoại",
            @"icon": @"phone.waves.left.and.right",
            @"color": @(0x06B6D4),
            @"items": @[
                @{ @"key": ZXK_CALL_FORCE_RELAY, @"title": @"Bảo vệ IP cuộc gọi (Force Relay)", @"sub": @"Ép kết nối WebRTC/Zalo Call qua máy chủ Relay, chặn P2P/STUN lộ IP thật", @"icon": @"network.badge.shield.half.filled", @"color": @(0x06B6D4), @"kw": @"bao ve ip cuoc goi force relay webrtc stun p2p" },
                @{ @"key": ZXK_AUTO_CALL_RECORD, @"title": @"Ghi âm cuộc gọi tự động (.m4a)", @"sub": @"Tự động ghi âm cuộc gọi thoại Zalo lưu vào Documents/NTHE_CallRecords/", @"icon": @"waveform.circle.fill", @"color": @(0xE53935), @"kw": @"ghi am cuoc goi tu dong call record m4a" },
                @{ @"action": @"call_records_list", @"title": @"Danh sách bản ghi âm cuộc gọi", @"sub": @"Nghe lại, ghi âm thử hoặc chia sẻ các tệp .m4a đã lưu", @"icon": @"folder.fill.badge.waveform", @"color": @(0xF59E0B), @"kw": @"danh sach ban ghi am" },
                @{ @"key": ZXK_VOICE_MSG_TOOLS, @"title": @"Tốc độ & Lưu tin nhắn thoại", @"sub": @"Cho phép phát tốc độ 1.0x/1.5x/2.0x và lưu tệp âm thanh gốc khi nhấn giữ", @"icon": @"speedometer", @"color": @(0x10B981), @"kw": @"toc do luu tin nhan thoai voice speed audio" },
                @{ @"action": @"voice_speed_menu", @"title": @"Chỉnh tốc độ phát & Lưu thoại gần nhất", @"sub": @"Chọn nhanh 1.0x, 1.5x, 2.0x hoặc xuất file tin nhắn thoại vừa nghe", @"icon": @"slider.horizontal.below.waveform", @"color": @(0x14B8A6), @"kw": @"chinh toc do phat 1.5x 2.0x" },
            ]
        },
        @{
            @"title": @"Giao diện & Nút nổi",
            @"desc": @"Đổi ảnh nút nổi từ Thư viện, Khôi phục Logo Zalo Đỏ, Thanh trượt kích thước nút nổi",
            @"icon": @"paintbrush.fill",
            @"color": @(0xF59E0B),
            @"items": @[
                @{ @"action": @"picklogo", @"title": @"Đổi ảnh nút nổi từ Thư viện", @"sub": @"Cắt tròn tự động, lưu vào Documents/nthe_custom_logo.png", @"icon": @"photo.circle.fill", @"color": @(0xE53935), @"kw": @"logo anh nut noi thu vien custom" },
                @{ @"action": @"resetlogo", @"title": @"Khôi phục Logo Zalo Đỏ mặc định", @"sub": @"Dùng biểu tượng Zalo nền đỏ #E53935 vẽ bằng CoreGraphics", @"icon": @"arrow.counterclockwise.circle.fill", @"color": @(0xF97316), @"kw": @"khoi phuc mac dinh zalo do" },
                @{ @"type": @"slider", @"title": @"Kích thước nút nổi", @"sub": @"Kéo để chỉnh độ lớn nút nổi ngay lập tức", @"icon": @"arrow.up.left.and.arrow.down.right.circle.fill", @"color": @(0xEF4444), @"kw": @"kich thuoc size nut noi slider" },
                @{ @"key": ZXK_FLOATING_TABBAR, @"title": @"Thanh tab nổi bo tròn (thử nghiệm)", @"sub": @"Biến thanh Tin nhắn/Danh bạ dưới cùng thành thanh nổi hiện đại", @"icon": @"dock.rectangle", @"color": @(0x8B5CF6), @"kw": @"tabbar floating thanh tab noi" },
                @{ @"action": @"tabbaridle", @"title": @"Thời gian tự thu gọn thanh tab (giây)", @"sub": @"Không chạm vào bao lâu thì tự co lại thành nút tròn (0 = tắt)", @"icon": @"timer", @"color": @(0x6366F1), @"kw": @"tabbar idle thu gon giay" },
            ]
        },
        @{
            @"title": @"Công cụ & Hệ thống",
            @"desc": @"Chặn quảng cáo/theo dõi, Gửi ảnh/file chất lượng gốc, Quét runtime & Log",
            @"icon": @"wrench.and.screwdriver.fill",
            @"color": @(0x10B981),
            @"items": @[
                @{ @"key": ZXK_BLOCK_ADS, @"title": @"Chặn quảng cáo Zalo", @"sub": @"Chặn kết nối tới các máy chủ phân phối quảng cáo", @"icon": @"hand.raised.fill", @"color": @(0xEF4444), @"kw": @"ads quang cao chan" },
                @{ @"key": ZXK_DISABLE_TRACKING, @"title": @"Tắt theo dõi hành vi (Tracking)", @"sub": @"Không gửi dữ liệu phân tích thao tác về máy chủ", @"icon": @"location.slash.fill", @"color": @(0xF59E0B), @"kw": @"tracking theo doi" },
                @{ @"key": ZXK_BLOCK_QOS, @"title": @"Chặn báo cáo chất lượng (QoS)", @"sub": @"Giảm lưu lượng ngầm gửi định kỳ của ứng dụng", @"icon": @"antenna.radiowaves.left.and.right.slash", @"color": @(0xEAB308), @"kw": @"qos log" },
                @{ @"key": ZXK_DISABLE_FIREBASE, @"title": @"Tắt Firebase Analytics", @"sub": @"Vô hiệu hóa thu thập thống kê Firebase", @"icon": @"flame.fill", @"color": @(0xF97316), @"kw": @"firebase logging" },
                @{ @"key": ZXK_DEFAULT_ORIGINAL, @"title": @"Gửi ảnh chất lượng gốc (Original)", @"sub": @"Tự động bật chế độ ảnh gốc khi chọn ảnh gửi đi", @"icon": @"photo.fill", @"color": @(0xEC4899), @"kw": @"hd original anh goc" },
                @{ @"key": ZXK_VIDEO_ORIGINAL, @"title": @"Gửi video giữ nguyên gốc (thử nghiệm)", @"sub": @"Bỏ qua bước nén giảm chất lượng video khi gửi", @"icon": @"video.fill", @"color": @(0xD946EF), @"kw": @"video hd original" },
                @{ @"key": ZXK_UNLIMITED_MEDIA, @"title": @"Mở khóa giới hạn dung lượng gửi", @"sub": @"Cho phép đính kèm file và media dung lượng lớn", @"icon": @"externaldrive.fill.badge.plus", @"color": @(0xA855F7), @"kw": @"file size dung luong" },
                @{ @"key": ZXK_TTL_OVERRIDE, @"title": @"Bật thời gian tự hủy tin nhắn (TTL)", @"sub": @"Áp dụng thời gian tự hủy tùy chỉnh cho tin bạn gửi", @"icon": @"hourglass", @"color": @(0xF43F5E), @"kw": @"ttl tu huy" },
                @{ @"action": @"ttl", @"title": @"Đặt giá trị TTL (mili-giây)", @"sub": @"Nhập số ms tin nhắn tự hủy (ví dụ: 60000 = 1 phút)", @"icon": @"slider.horizontal.3", @"color": @(0xEC4899), @"kw": @"ttl ms gia tri" },
                @{ @"action": @"dump_hidden_introspect", @"title": @"Dump Introspection Chat Ẩn (Share Sheet)", @"sub": @"Xuất zalo_26_introspect.txt gồm Schema SQLite, Snapshot Cell Model khi gõ PIN & Class Zalo 26", @"icon": @"doc.badge.gearshape.fill", @"color": @(0x06B6D4), @"kw": @"dump introspect hidden model sqlite zalo 26" },
                @{ @"action": @"scan", @"title": @"Quét Class / Method Runtime", @"sub": @"Dò danh sách hàm nội bộ của Zalo để viết hook", @"icon": @"magnifyingglass.circle.fill", @"color": @(0x3B82F6), @"kw": @"scan quet class method" },
                @{ @"action": @"viewscan", @"title": @"Xem & Chia sẻ kết quả quét", @"sub": @"Mở hoặc xuất tệp scan.txt", @"icon": @"square.and.arrow.up.fill", @"color": @(0x0EA5E9), @"kw": @"view scan chia se" },
                @{ @"action": @"rules", @"title": @"Trình sửa rules.json", @"sub": @"Chỉnh sửa quy tắc hook trực tiếp trong ứng dụng", @"icon": @"curlybraces.square.fill", @"color": @(0x10B981), @"kw": @"rules json hook" },
                @{ @"action": @"log", @"title": @"Xem nhật ký hoạt động (log.txt)", @"sub": @"Kiểm tra trạng thái các hook đang chạy", @"icon": @"doc.text.magnifyingglass", @"color": @(0xF59E0B), @"kw": @"log nhat ky" },
                @{ @"action": @"exit", @"title": @"Khởi động lại Zalo", @"sub": @"Đóng ứng dụng ngay để nạp lại toàn bộ cấu hình mới", @"icon": @"power.circle.fill", @"color": @(0xE53935), @"kw": @"exit thoat khoi dong lai" },
            ]
        }
    ];
}

// ---------------------------------------------------------------- Category Card Cell (Main Screen 5 Cards)

@interface ZXCategoryCardCell : UITableViewCell
@property (nonatomic, strong) UIView *cardContainer;
@property (nonatomic, strong) UIView *iconBadge;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *countBadge;
@property (nonatomic, strong) UIImageView *chevronView;
- (void)configureWithCategory:(NSDictionary *)cat;
@end

@implementation ZXCategoryCardCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 14.0, *)) {
        self.automaticallyUpdatesBackgroundConfiguration = NO;
        self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    }
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _cardContainer = [UIView new];
    _cardContainer.backgroundColor = ZXColorCardBg();
    _cardContainer.layer.cornerRadius = 14.0;
    if (@available(iOS 13.0, *)) _cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    _cardContainer.layer.borderWidth = 1.0;
    _cardContainer.layer.borderColor = ZXColorCardBorder().CGColor;
    _cardContainer.clipsToBounds = YES;
    _cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_cardContainer];

    _iconBadge = [UIView new];
    _iconBadge.layer.cornerRadius = 12.0;
    _iconBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_iconBadge];

    _iconView = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [_iconBadge addSubview:_iconView];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.numberOfLines = 1;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_titleLabel];

    _descLabel = [UILabel new];
    _descLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    _descLabel.textColor = ZXColorTextSub();
    _descLabel.numberOfLines = 2;
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_descLabel];

    _countBadge = [UILabel new];
    _countBadge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    _countBadge.textAlignment = NSTextAlignmentCenter;
    _countBadge.layer.cornerRadius = 11.0;
    _countBadge.layer.masksToBounds = YES;
    _countBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_countBadge];

    _chevronView = [UIImageView new];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
        _chevronView.image = [[UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    _chevronView.tintColor = ZXColorTextSub();
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [_cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [_cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        [_cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [_iconBadge.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:14],
        [_iconBadge.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_iconBadge.widthAnchor constraintEqualToConstant:46],
        [_iconBadge.heightAnchor constraintEqualToConstant:46],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBadge.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBadge.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24],
        [_iconView.heightAnchor constraintEqualToConstant:24],

        [_chevronView.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_chevronView.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:12],
        [_chevronView.heightAnchor constraintEqualToConstant:16],

        [_countBadge.trailingAnchor constraintEqualToAnchor:_chevronView.leadingAnchor constant:-8],
        [_countBadge.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_countBadge.widthAnchor constraintGreaterThanOrEqualToConstant:44],
        [_countBadge.heightAnchor constraintEqualToConstant:22],

        [_titleLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:14],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBadge.trailingAnchor constant:14],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_countBadge.leadingAnchor constant:-10],

        [_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [_descLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_descLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardContainer.bottomAnchor constant:-14],
        [_cardContainer.heightAnchor constraintGreaterThanOrEqualToConstant:86],
    ]];

    return self;
}

- (void)configureWithCategory:(NSDictionary *)cat
{
    _titleLabel.text = cat[@"title"];
    _descLabel.text = cat[@"desc"];
    NSUInteger hex = [cat[@"color"] unsignedIntegerValue] ?: 0xE53935;
    _iconBadge.backgroundColor = ZXColorFromHex(hex, 0.18);
    _iconView.tintColor = ZXColorFromHex(hex, 1.0);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
        UIImage *im = [UIImage systemImageNamed:(cat[@"icon"] ?: @"folder.fill") withConfiguration:cfg];
        _iconView.image = [im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    NSInteger totalToggles = 0, activeToggles = 0;
    for (NSDictionary *it in cat[@"items"]) {
        NSString *k = it[@"key"];
        if (k.length) {
            totalToggles++;
            if ([ZXConfig boolForKey:k]) activeToggles++;
        }
    }
    if (totalToggles > 0) {
        _countBadge.hidden = NO;
        _countBadge.text = [NSString stringWithFormat:@" %ld/%ld ", (long)activeToggles, (long)totalToggles];
        _countBadge.backgroundColor = activeToggles > 0 ? ZXColorFromHex(hex, 0.25) : [UIColor colorWithWhite:1.0 alpha:0.07];
        _countBadge.textColor = activeToggles > 0 ? ZXColorFromHex(hex, 1.0) : ZXColorTextSub();
    } else {
        _countBadge.hidden = NO;
        _countBadge.text = [NSString stringWithFormat:@" %lu mục ", (unsigned long)[cat[@"items"] count]];
        _countBadge.backgroundColor = ZXColorFromHex(hex, 0.22);
        _countBadge.textColor = ZXColorFromHex(hex, 1.0);
    }
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:highlighted animated:animated];
    _cardContainer.backgroundColor = highlighted
        ? [UIColor colorWithRed:0.14 green:0.16 blue:0.20 alpha:1.0]
        : ZXColorCardBg();
}

@end

// ---------------------------------------------------------------- Modern Feature Row Cell (Inside Popup & Search)

@interface ZXModernRowCell : UITableViewCell
@property (nonatomic, strong) UIView *cardContainer;
@property (nonatomic, strong) UIView *iconBadge;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UISwitch *toggleSwitch;
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) UISlider *sizeSlider;
@property (nonatomic, strong) UILabel *valueBadgeLabel;
@end

@implementation ZXModernRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 14.0, *)) {
        self.automaticallyUpdatesBackgroundConfiguration = NO;
        self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    }
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _cardContainer = [UIView new];
    _cardContainer.backgroundColor = ZXColorCardBg();
    _cardContainer.layer.cornerRadius = 14.0;
    if (@available(iOS 13.0, *)) _cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    _cardContainer.layer.borderWidth = 1.0;
    _cardContainer.layer.borderColor = ZXColorCardBorder().CGColor;
    _cardContainer.clipsToBounds = YES;
    _cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_cardContainer];

    _iconBadge = [UIView new];
    _iconBadge.layer.cornerRadius = 10.0;
    _iconBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_iconBadge];

    _iconView = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [_iconBadge addSubview:_iconView];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.numberOfLines = 0;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_titleLabel];

    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = ZXColorTextSub();
    _subtitleLabel.numberOfLines = 0;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_subtitleLabel];

    _toggleSwitch = [UISwitch new];
    _toggleSwitch.onTintColor = ZXColorZaloRed();
    _toggleSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_toggleSwitch];

    _chevronView = [UIImageView new];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
        _chevronView.image = [[UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    _chevronView.tintColor = ZXColorTextSub();
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_chevronView];

    _valueBadgeLabel = [UILabel new];
    _valueBadgeLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
    _valueBadgeLabel.textColor = ZXColorZaloRed();
    _valueBadgeLabel.textAlignment = NSTextAlignmentRight;
    _valueBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_valueBadgeLabel];

    _sizeSlider = [UISlider new];
    _sizeSlider.minimumValue = 38.0f;
    _sizeSlider.maximumValue = 88.0f;
    _sizeSlider.minimumTrackTintColor = ZXColorZaloRed();
    _sizeSlider.maximumTrackTintColor = ZXColorCardBorder();
    _sizeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_sizeSlider];

    [NSLayoutConstraint activateConstraints:@[
        [_cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [_cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [_iconBadge.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:12],
        [_iconBadge.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:12],
        [_iconBadge.widthAnchor constraintEqualToConstant:36],
        [_iconBadge.heightAnchor constraintEqualToConstant:36],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBadge.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBadge.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:20],
        [_iconView.heightAnchor constraintEqualToConstant:20],

        [_toggleSwitch.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-12],
        [_toggleSwitch.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],

        [_chevronView.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_chevronView.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:12],
        [_chevronView.heightAnchor constraintEqualToConstant:16],

        [_valueBadgeLabel.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_valueBadgeLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:13],
        [_valueBadgeLabel.widthAnchor constraintEqualToConstant:52],

        [_titleLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:12],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBadge.trailingAnchor constant:12],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-72],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

        [_sizeSlider.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:8],
        [_sizeSlider.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_sizeSlider.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_sizeSlider.bottomAnchor constraintEqualToAnchor:_cardContainer.bottomAnchor constant:-10],
    ]];

    NSLayoutConstraint *subBottom = [_subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardContainer.bottomAnchor constant:-12];
    subBottom.priority = UILayoutPriorityDefaultHigh;
    subBottom.active = YES;

    NSLayoutConstraint *minCardHeight = [_cardContainer.heightAnchor constraintGreaterThanOrEqualToConstant:62];
    minCardHeight.priority = UILayoutPriorityDefaultHigh;
    minCardHeight.active = YES;

    return self;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:highlighted animated:animated];
    _cardContainer.backgroundColor = highlighted
        ? [UIColor colorWithRed:0.13 green:0.15 blue:0.19 alpha:1.0]
        : ZXColorCardBg();
}

@end

// ---------------------------------------------------------------- Category Popup Sheet & Main Controller

static NSString *ZXFoldText(NSString *t)
{
    NSString *f = [t ?: @"" stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil];
    f = [f stringByReplacingOccurrencesOfString:@"đ" withString:@"d"];
    f = [f stringByReplacingOccurrencesOfString:@"Đ" withString:@"d"];
    return f.lowercaseString;
}

@interface ZXFeatureListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *allCategories;
@property (nonatomic, strong) NSDictionary *singleCategory;
@property (nonatomic, copy) void (^onDismissCallback)(void);
@property (nonatomic, strong) NSArray<NSDictionary *> *searchResults;
@property (nonatomic, assign) BOOL isSearching;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *searchField;
@end

@implementation ZXFeatureListViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = ZXColorBgPrimary();
    self.allCategories = ZXFiveCategories();

    if (self.singleCategory) {
        self.title = self.singleCategory[@"title"];
        self.navigationItem.rightBarButtonItem = ZXMakeNavButton(@"xmark.circle.fill", @"Đóng", ZXColorNavTint(), self, @selector(closeSheet));
    } else {
        self.title = @"thanhthe";
        self.navigationItem.titleView = ZXMakeVersionTitleView();
        self.navigationItem.leftBarButtonItem = ZXMakeNavButton(@"xmark.circle.fill", @"Đóng", ZXColorNavTint(), self, @selector(closeMenu));
        self.navigationItem.rightBarButtonItem = ZXMakeNavButton(@"arrow.clockwise.circle.fill", @"Khởi động lại", ZXColorNavTint(), self, @selector(restartZalo));
    }

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    if (@available(iOS 13.0, *)) self.tableView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = ZXColorBgPrimary();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 82;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[ZXCategoryCardCell class] forCellReuseIdentifier:@"ZXCategoryCardCell"];
    [self.tableView registerClass:[ZXModernRowCell class] forCellReuseIdentifier:@"ZXModernRowCell"];

    if (!self.singleCategory) {
        UIView *searchHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 82)];
        searchHeader.backgroundColor = ZXColorBgPrimary();

        UILabel *verBanner = [[UILabel alloc] initWithFrame:CGRectMake(16, 4, self.view.bounds.size.width - 32, 18)];
        verBanner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        verBanner.text = [NSString stringWithFormat:@"thanhthe Mod • %@ (Zalo iOS 26.11.02.1)", ZX_MOD_VERSION];
        verBanner.textAlignment = NSTextAlignmentCenter;
        verBanner.textColor = ZXColorTextSub();
        verBanner.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
        [searchHeader addSubview:verBanner];

        UIView *searchBox = [[UIView alloc] initWithFrame:CGRectMake(16, 28, self.view.bounds.size.width - 32, 42)];
        searchBox.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        searchBox.backgroundColor = ZXColorCardBg();
        searchBox.layer.cornerRadius = 12.0;
        searchBox.layer.borderWidth = 1.0;
        searchBox.layer.borderColor = ZXColorCardBorder().CGColor;

        UIImageView *searchIcon = [[UIImageView alloc] initWithFrame:CGRectMake(12, 12, 18, 18)];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
            searchIcon.image = [[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        searchIcon.tintColor = ZXColorTextSub();
        [searchBox addSubview:searchIcon];

        self.searchField = [[UITextField alloc] initWithFrame:CGRectMake(36, 0, searchBox.bounds.size.width - 44, 42)];
        self.searchField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.searchField.textColor = UIColor.whiteColor;
        self.searchField.tintColor = ZXColorZaloRed();
        self.searchField.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
        self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
        self.searchField.returnKeyType = UIReturnKeyDone;
        self.searchField.delegate = self;
        self.searchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Tìm nhanh tính năng trong 5 nhóm..."
            attributes:@{ NSForegroundColorAttributeName: ZXColorTextSub() }];
        [self.searchField addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged];
        [searchBox addSubview:self.searchField];
        [searchHeader addSubview:searchBox];
        self.tableView.tableHeaderView = searchHeader;
    }

    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    ZXStyleNavBar(self.navigationController.navigationBar);
    [self.tableView reloadData];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (self.onDismissCallback) self.onDismissCallback();
}

- (void)closeSheet
{
    [self dismissViewControllerAnimated:YES completion:self.onDismissCallback];
}

- (void)closeMenu
{
    [self dismissViewControllerAnimated:YES completion:^{
        [ZXBubble show];
        ZXRefreshFloatingBubbleNow();
    }];
}

- (void)restartZalo
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Khởi động lại Zalo?"
                                                               message:@"Zalo sẽ đóng ngay để áp dụng toàn bộ cấu hình và rules mới."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Khởi động lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        (void)act;
        exit(0);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)searchChanged:(UITextField *)tf
{
    NSString *raw = [(tf.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (raw.length == 0) {
        self.isSearching = NO;
        self.searchResults = @[];
        [self.tableView reloadData];
        return;
    }
    self.isSearching = YES;
    NSArray<NSString *> *tokens = [[ZXFoldText(raw) componentsSeparatedByString:@" "]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *sec in self.allCategories) {
        NSMutableArray *hits = [NSMutableArray new];
        for (NSDictionary *it in sec[@"items"]) {
            NSString *hay = ZXFoldText([NSString stringWithFormat:@"%@ %@ %@ %@",
                                        it[@"title"] ?: @"", it[@"sub"] ?: @"", it[@"kw"] ?: @"", sec[@"title"] ?: @""]);
            BOOL ok = YES;
            for (NSString *tok in tokens) {
                if ([hay rangeOfString:tok].location == NSNotFound) { ok = NO; break; }
            }
            if (ok) [hits addObject:it];
        }
        if (hits.count) {
            NSMutableDictionary *copy = [sec mutableCopy];
            copy[@"items"] = hits;
            [out addObject:copy];
        }
    }
    self.searchResults = out;
    [self.tableView reloadData];
}

- (void)openCategoryPopup:(NSDictionary *)cat
{
    ZXFeatureListViewController *sheetVC = [ZXFeatureListViewController new];
    sheetVC.singleCategory = cat;
    __weak typeof(self) weakSelf = self;
    sheetVC.onDismissCallback = ^{
        [weakSelf.tableView reloadData];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheetVC];
    if (@available(iOS 13.0, *)) nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    ZXStyleNavBar(nav.navigationBar);
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 22.0;
        }
    }
    [self presentViewController:nav animated:YES completion:nil];
}

// ---------------------------------------------------------------- TableView DataSource & Delegate

- (NSArray<NSDictionary *> *)activeFeatureSections
{
    if (self.singleCategory) return @[self.singleCategory];
    return self.searchResults ?: @[];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    if (!self.singleCategory && !self.isSearching) {
        return 1;
    }
    return [self activeFeatureSections].count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (!self.singleCategory && !self.isSearching) {
        return self.allCategories.count;
    }
    return [[self activeFeatureSections][section][@"items"] count];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 32)];
    v.backgroundColor = UIColor.clearColor;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(22, 6, tableView.bounds.size.width - 44, 20)];
    if (!self.singleCategory && !self.isSearching) {
        l.text = @"CHỌN NHÓM TÍNH NĂNG (BẤM ĐỂ MỞ BẢNG)";
    } else {
        l.text = [[self activeFeatureSections][section][@"title"] uppercaseString];
    }
    l.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightHeavy];
    l.textColor = ZXColorTextSub();
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return 32.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    NSInteger totalSec = [self numberOfSectionsInTableView:tableView];
    if (section != totalSec - 1) return nil;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 64)];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 10, tableView.bounds.size.width - 40, 44)];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.text = [NSString stringWithFormat:@"thanhthe Mod • %@\nDựa trên ZaloXposed của ElectroHeavenVN (AGPL-3.0)", ZX_MOD_VERSION];
    l.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    l.textColor = ZXColorTextSub();
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSInteger totalSec = [self numberOfSectionsInTableView:tableView];
    return (section == totalSec - 1) ? 68.0 : 6.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.singleCategory && !self.isSearching) {
        ZXCategoryCardCell *card = [tableView dequeueReusableCellWithIdentifier:@"ZXCategoryCardCell" forIndexPath:indexPath];
        [card configureWithCategory:self.allCategories[indexPath.row]];
        return card;
    }

    ZXModernRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ZXModernRowCell" forIndexPath:indexPath];
    NSDictionary *item = [self activeFeatureSections][indexPath.section][@"items"][indexPath.row];

    cell.titleLabel.text = item[@"title"];
    NSString *action = item[@"action"];
    NSString *type = item[@"type"];
    NSString *key = item[@"key"];

    if ([action isEqualToString:@"uid"]) {
        NSString *uid = [ZXConfig currentUserID];
        cell.subtitleLabel.text = uid.length ? [NSString stringWithFormat:@"ID hiện tại: %@", uid] : item[@"sub"];
    } else if ([action isEqualToString:@"ttl"]) {
        cell.subtitleLabel.text = [NSString stringWithFormat:@"Hiện tại: %lld ms — %@", [ZXConfig ttl], item[@"sub"]];
    } else if ([action isEqualToString:@"tabbaridle"]) {
        cell.subtitleLabel.text = [NSString stringWithFormat:@"Hiện tại: %.0f giây — %@", [ZXConfig tabBarIdleSeconds], item[@"sub"]];
    } else if ([action isEqualToString:@"picklogo"]) {
        BOOL isCustom = [ZXConfig customLogoMode] && [[NSFileManager defaultManager] fileExistsAtPath:[ZXConfig customLogoPath]];
        cell.subtitleLabel.text = isCustom ? @"Đang dùng: Ảnh tùy chỉnh (Documents/nthe_custom_logo.png)" : item[@"sub"];
    } else if ([action isEqualToString:@"resetlogo"]) {
        BOOL isCustom = [ZXConfig customLogoMode] && [[NSFileManager defaultManager] fileExistsAtPath:[ZXConfig customLogoPath]];
        cell.subtitleLabel.text = isCustom ? @"Nhấn để quay về Logo Zalo Đỏ mặc định" : @"Đang sử dụng Logo Zalo Đỏ mặc định";
    } else if ([action isEqualToString:@"set_lock_pin"]) {
        BOOL hasPin = [ZXConfig chatLockPIN].length > 0;
        cell.subtitleLabel.text = hasPin ? @"Đã thiết lập mã PIN 4 số • Nhấn để đổi mã PIN" : item[@"sub"];
    } else if ([action isEqualToString:@"locked_chats_list"]) {
        cell.subtitleLabel.text = [NSString stringWithFormat:@"Đang khóa: %lu hội thoại — %@", (unsigned long)[ZXConfig lockedChats].count, item[@"sub"]];
    } else if ([action isEqualToString:@"hidden_chats_list"]) {
        cell.subtitleLabel.text = [NSString stringWithFormat:@"Đã phát hiện: %lu hội thoại ẩn — %@", (unsigned long)[ZXHookEngine discoveredHiddenChats].count, item[@"sub"]];
    } else if ([action isEqualToString:@"voice_speed_menu"]) {
        cell.subtitleLabel.text = [NSString stringWithFormat:@"Tốc độ hiện tại: %.1fx — %@", [ZXConfig voicePlaybackRate], item[@"sub"]];
    } else {
        cell.subtitleLabel.text = item[@"sub"];
    }

    NSUInteger hex = [item[@"color"] unsignedIntegerValue] ?: 0xE53935;
    if ([action isEqualToString:@"picklogo"] || [action isEqualToString:@"resetlogo"]) {
        cell.iconBadge.backgroundColor = UIColor.clearColor;
        cell.iconView.tintColor = nil;
        cell.iconView.image = [action isEqualToString:@"resetlogo"]
            ? ZXDrawRedZaloLogo(CGSizeMake(36, 36))
            : ZXCurrentFloatingLogo(CGSizeMake(36, 36));
        cell.iconView.layer.cornerRadius = 10.0;
        cell.iconView.clipsToBounds = YES;
    } else {
        cell.iconView.layer.cornerRadius = 0;
        cell.iconView.clipsToBounds = NO;
        cell.iconBadge.backgroundColor = ZXColorFromHex(hex, 0.18);
        UIColor *icColor = ZXColorFromHex(hex, 1.0);
        UIImage *img = nil;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
            NSString *sym = item[@"icon"] ?: @"circle.fill";
            img = [UIImage systemImageNamed:sym withConfiguration:cfg] ?: [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg];
            img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        cell.iconView.image = img;
        cell.iconView.tintColor = icColor;
    }

    [cell.toggleSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.sizeSlider removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    if ([type isEqualToString:@"slider"]) {
        cell.toggleSwitch.hidden = YES;
        cell.chevronView.hidden = YES;
        cell.sizeSlider.hidden = NO;
        cell.valueBadgeLabel.hidden = NO;
        double sz = [ZXConfig bubbleSize];
        cell.sizeSlider.value = (float)sz;
        cell.valueBadgeLabel.text = [NSString stringWithFormat:@"%.0f pt", sz];
        [cell.sizeSlider addTarget:self action:@selector(bubbleSliderChanged:) forControlEvents:UIControlEventValueChanged];
    } else if (key.length > 0) {
        cell.toggleSwitch.hidden = NO;
        cell.chevronView.hidden = YES;
        cell.sizeSlider.hidden = YES;
        cell.valueBadgeLabel.hidden = YES;
        cell.toggleSwitch.on = [ZXConfig boolForKey:key];
        cell.toggleSwitch.tag = indexPath.section * 1000 + indexPath.row;
        [cell.toggleSwitch addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
    } else {
        cell.toggleSwitch.hidden = YES;
        cell.chevronView.hidden = NO;
        cell.sizeSlider.hidden = YES;
        cell.valueBadgeLabel.hidden = YES;
    }

    return cell;
}

- (void)switchToggled:(UISwitch *)sw
{
    NSInteger sec = sw.tag / 1000;
    NSInteger row = sw.tag % 1000;
    NSArray<NSDictionary *> *secs = [self activeFeatureSections];
    if (sec < 0 || sec >= (NSInteger)secs.count) return;
    NSArray *items = secs[sec][@"items"];
    if (row < 0 || row >= (NSInteger)items.count) return;
    NSDictionary *item = items[row];
    NSString *key = item[@"key"];
    if (!key) return;

    [ZXConfig setBool:sw.on forKey:key];
    if ([key isEqualToString:ZXK_FLOATING_TABBAR]) {
        ZXHookFloatingTabBar();
    } else if ([key isEqualToString:ZXK_UNHIDE_CHATS] && sw.on) {
        [ZXHookEngine scanMemoryForHiddenChats];
    }
    NSString *title = item[@"title"] ?: key;
    ZXShowToast(self.navigationController.view ?: self.view,
                [NSString stringWithFormat:@"%@: %@", title, (sw.on ? @"ĐÃ BẬT" : @"ĐÃ TẮT")]);
}

- (void)bubbleSliderChanged:(UISlider *)slider
{
    double val = round(slider.value);
    [ZXConfig setBubbleSize:val];
    UIView *v = slider;
    while (v && ![v isKindOfClass:[ZXModernRowCell class]]) v = v.superview;
    if ([v isKindOfClass:[ZXModernRowCell class]]) {
        ((ZXModernRowCell *)v).valueBadgeLabel.text = [NSString stringWithFormat:@"%.0f pt", val];
    }
    [ZXBubble show];
    ZXRefreshFloatingBubbleNow();
}

// ---------------------------------------------------------------- Custom Floating Logo Picker

- (void)pickCustomLogo
{
    UIImagePickerController *picker = [UIImagePickerController new];
    if (@available(iOS 13.0, *)) picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.allowsEditing = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info
{
    UIImage *chosen = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
    if (chosen) {
        UIImage *circular = ZXCropCircularImage(chosen, 256.0);
        NSData *png = UIImagePNGRepresentation(circular ?: chosen);
        if (png) {
            [png writeToFile:[ZXConfig customLogoPath] atomically:YES];
            [ZXConfig setCustomLogoMode:YES];
        }
    }
    [picker dismissViewControllerAnimated:YES completion:^{
        [ZXBubble show];
        ZXRefreshFloatingBubbleNow();
        [self.tableView reloadData];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã cập nhật ảnh nút nổi mới");
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)resetDefaultRedLogo
{
    [[NSFileManager defaultManager] removeItemAtPath:[ZXConfig customLogoPath] error:nil];
    [ZXConfig setCustomLogoMode:NO];
    [ZXBubble show];
    ZXRefreshFloatingBubbleNow();
    [self.tableView reloadData];
    ZXShowToast(self.navigationController.view ?: self.view, @"Đã khôi phục Logo Zalo Đỏ mặc định");
}

// ---------------------------------------------------------------- Row Actions & Alerts

- (void)showAlert:(NSString *)title message:(NSString *)msg
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptInput:(NSString *)title currentText:(NSString *)text numeric:(BOOL)numeric completion:(void (^)(NSString *))done
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = text;
        tf.keyboardType = numeric ? UIKeyboardTypeNumberPad : UIKeyboardTypeDefault;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        (void)x;
        done(a.textFields.firstObject.text ?: @"");
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pushTextViewer:(NSString *)text editable:(BOOL)editable title:(NSString *)title onSave:(BOOL (^)(NSString *, NSString **))save
{
    ZXTextViewController *vc = [ZXTextViewController new];
    vc.title = title;
    vc.initialText = text ?: @"";
    vc.editable = editable;
    vc.onSave = save;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.singleCategory && !self.isSearching) {
        NSDictionary *cat = self.allCategories[indexPath.row];
        [self openCategoryPopup:cat];
        return;
    }

    NSDictionary *item = [self activeFeatureSections][indexPath.section][@"items"][indexPath.row];
    NSString *action = item[@"action"];
    if (!action) return;

    __weak typeof(self) weakSelf = self;
    if ([action isEqualToString:@"picklogo"]) {
        [self pickCustomLogo];
    } else if ([action isEqualToString:@"resetlogo"]) {
        [self resetDefaultRedLogo];
    } else if ([action isEqualToString:@"hidden_chats_list"]) {
        ZXAuthenticateUserFromVC(self, @"Xác thực Face ID / Mã PIN để xem danh sách trò chuyện đang ẩn", ^{
            ZXHiddenChatsViewController *vc = [[ZXHiddenChatsViewController alloc] initWithStyle:UITableViewStyleGrouped];
            [weakSelf.navigationController pushViewController:vc animated:YES];
        });
    } else if ([action isEqualToString:@"set_lock_pin"]) {
        ZXAuthenticateUserFromVC(self, @"Xác thực trước khi đặt mã PIN khóa chat", ^{
            [weakSelf promptInput:@"Nhập mã PIN dự phòng (4 chữ số)" currentText:[ZXConfig chatLockPIN] numeric:YES completion:^(NSString *t) {
                NSString *clean = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                [ZXConfig setChatLockPIN:clean];
                [weakSelf.tableView reloadData];
                ZXShowToast(weakSelf.navigationController.view ?: weakSelf.view, @"Đã lưu mã PIN bảo mật");
            }];
        });
    } else if ([action isEqualToString:@"locked_chats_list"]) {
        ZXAuthenticateUserFromVC(self, @"Xác thực để quản lý danh sách phòng chat bị khóa", ^{
            ZXLockedChatsViewController *vc = [[ZXLockedChatsViewController alloc] initWithStyle:UITableViewStyleGrouped];
            [weakSelf.navigationController pushViewController:vc animated:YES];
        });
    } else if ([action isEqualToString:@"open_repeater"]) {
        [ZXHookEngine presentRepeaterDialogFromVC:self];
    } else if ([action isEqualToString:@"call_records_list"]) {
        ZXCallRecordsViewController *vc = [[ZXCallRecordsViewController alloc] initWithStyle:UITableViewStyleGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"voice_speed_menu"]) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Tốc độ & Lưu tin nhắn thoại"
                                                                       message:@"Chọn tốc độ phát mặc định hoặc lưu tệp tin nhắn thoại gần nhất"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        if (@available(iOS 13.0, *)) sheet.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        for (NSNumber *rNum in @[@1.0, @1.5, @2.0]) {
            double r = rNum.doubleValue;
            NSString *title = [NSString stringWithFormat:@"⏩ Tốc độ phát %.1fx%@", r, ([ZXConfig voicePlaybackRate] == r ? @" (Đang chọn)" : @"")];
            [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                (void)act;
                [ZXConfig setVoicePlaybackRate:r];
                [ZXConfig setBool:YES forKey:ZXK_VOICE_MSG_TOOLS];
                [weakSelf.tableView reloadData];
                ZXShowToast(weakSelf.navigationController.view ?: weakSelf.view,
                            [NSString stringWithFormat:@"Đã đặt tốc độ thoại %.1fx", r]);
            }]];
        }
        NSURL *lastURL = [ZXHookEngine lastVoiceMessageURL];
        if (lastURL) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"💾 Lưu / Chia sẻ tệp tin nhắn thoại gần nhất" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                (void)act;
                UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[lastURL] applicationActivities:nil];
                if (@available(iOS 13.0, *)) av.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                av.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
                [weakSelf presentViewController:av animated:YES completion:nil];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:sheet animated:YES completion:nil];
    } else if ([action isEqualToString:@"uid"]) {
        [self promptInput:@"User ID Zalo của bạn" currentText:[ZXConfig currentUserID] numeric:YES completion:^(NSString *t) {
            [ZXConfig setCurrentUserID:[t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
            [weakSelf.tableView reloadData];
            ZXShowToast(weakSelf.navigationController.view ?: weakSelf.view, @"Đã lưu User ID");
        }];
    } else if ([action isEqualToString:@"ttl"]) {
        [self promptInput:@"Giá trị TTL (ms)" currentText:[NSString stringWithFormat:@"%lld", [ZXConfig ttl]] numeric:YES completion:^(NSString *t) {
            [ZXConfig setTTL:t.longLongValue];
            [weakSelf.tableView reloadData];
            ZXShowToast(weakSelf.navigationController.view ?: weakSelf.view, @"Đã lưu thời gian tự hủy (TTL)");
        }];
    } else if ([action isEqualToString:@"tabbaridle"]) {
        [self promptInput:@"Tự thu gọn sau (giây), 0 = tắt"
              currentText:[NSString stringWithFormat:@"%.0f", [ZXConfig tabBarIdleSeconds]]
                  numeric:YES
               completion:^(NSString *t) {
            [ZXConfig setTabBarIdleSeconds:MAX(0, t.doubleValue)];
            [weakSelf.tableView reloadData];
            ZXShowToast(weakSelf.navigationController.view ?: weakSelf.view, @"Đã lưu thời gian thu gọn thanh tab");
        }];
    } else if ([action isEqualToString:@"dump_hidden_introspect"]) {
        ZXShowToast(self.navigationController.view ?: self.view, @"Đang trích xuất zalo_26_introspect.txt...");
        NSString *pinSnap = [ZXHookEngine lastPinSearchIntrospectSnapshot];
        NSString *liveSceneSnap = [ZXScanner dumpLiveSceneListModelsOnMainThread];
        UITableViewCell *anchorCell = [tableView cellForRowAtIndexPath:indexPath];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *outPath = [ZXScanner runHiddenIntrospectionWithPinSnapshot:pinSnap liveSceneDump:liveSceneSnap];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || outPath.length == 0) return;
                NSURL *fileURL = [NSURL fileURLWithPath:outPath];
                UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
                if (@available(iOS 13.0, *)) av.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                av.popoverPresentationController.sourceView = anchorCell ?: strongSelf.view;
                [strongSelf presentViewController:av animated:YES completion:nil];
            });
        });
    } else if ([action isEqualToString:@"scan"]) {
        ZXShowToast(self.navigationController.view ?: self.view, @"Đang quét runtime Zalo...");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [ZXScanner runScan];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showAlert:@"Quét hoàn tất" message:@"Chọn 'Xem & Chia sẻ kết quả quét' để xem danh sách class/method."];
            });
        });
    } else if ([action isEqualToString:@"viewscan"]) {
        NSString *t = [NSString stringWithContentsOfFile:[ZXScanner scanPath] encoding:NSUTF8StringEncoding error:nil];
        if (!t) {
            [self showAlert:@"Chưa có dữ liệu" message:@"Hãy chạy 'Quét Class / Method Runtime' trước."];
            return;
        }
        [self pushTextViewer:t editable:NO title:@"scan.txt" onSave:nil];
        ZXTextViewController *vc = (ZXTextViewController *)self.navigationController.topViewController;
        UIBarButtonItem *copyItem = vc.navigationItem.rightBarButtonItem;
        UIBarButtonItem *shareItem = ZXMakeNavButton(@"square.and.arrow.up", @"Chia sẻ", ZXColorZaloRed(), self, @selector(shareScan:));
        vc.navigationItem.rightBarButtonItems = copyItem ? @[shareItem, copyItem] : @[shareItem];
    } else if ([action isEqualToString:@"rules"]) {
        [ZXHookEngine ensureRulesFile];
        NSString *t = [NSString stringWithContentsOfFile:[ZXHookEngine rulesPath] encoding:NSUTF8StringEncoding error:nil];
        [self pushTextViewer:t editable:YES title:@"rules.json" onSave:^BOOL(NSString *text, NSString **error) {
            NSMutableArray *lines = [NSMutableArray new];
            for (NSString *l in [text componentsSeparatedByString:@"\n"])
                if (![[l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] hasPrefix:@"//"]) [lines addObject:l];
            NSData *d = [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            NSError *e = nil;
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
            if (![j isKindOfClass:[NSArray class]]) {
                if (error) *error = e.localizedDescription ?: @"JSON phải là một mảng [ ... ]";
                return NO;
            }
            [text writeToFile:[ZXHookEngine rulesPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return YES;
        }];
    } else if ([action isEqualToString:@"history"]) {
        NSString *t = [NSString stringWithContentsOfFile:[ZXAntiRecall historyPath] encoding:NSUTF8StringEncoding error:nil];
        [self pushTextViewer:(t ?: @"(Chưa có tin nhắn nào bị thu hồi/xóa)") editable:NO title:@"Lịch sử thu hồi" onSave:nil];
    } else if ([action isEqualToString:@"clearmarks"]) {
        [ZXRecallMarker clearMarks];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã xóa danh sách tin đánh dấu");
    } else if ([action isEqualToString:@"clearcache"]) {
        [ZXAntiRecall clearCache];
        ZXShowToast(self.navigationController.view ?: self.view, @"Đã xóa bộ nhớ đệm tin nhắn");
    } else if ([action isEqualToString:@"log"]) {
        NSString *t = [NSString stringWithContentsOfFile:ZXLogPath() encoding:NSUTF8StringEncoding error:nil];
        [self pushTextViewer:(t ?: @"(Trống)") editable:NO title:@"log.txt" onSave:nil];
    } else if ([action isEqualToString:@"exit"]) {
        [self restartZalo];
    }
}

- (void)shareScan:(UIButton *)sender
{
    NSURL *url = [NSURL fileURLWithPath:[ZXScanner scanPath]];
    UIActivityViewController *v = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (@available(iOS 13.0, *)) v.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    v.popoverPresentationController.sourceView = sender;
    [self presentViewController:v animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------- button in Zalo's Settings screen

static const NSInteger kZXFooterTag = 0x5A59;
static BOOL gSettingsHooked;

static void ZXAddSettingsButton(UIViewController *vc)
{
    UITableView *tv = nil;
    @try { tv = [vc valueForKey:@"tableView"]; } @catch (NSException *e) { (void)e; return; }
    if (![tv isKindOfClass:[UITableView class]]) return;
    UIView *footer = tv.tableFooterView;
    if (footer.tag == kZXFooterTag) return;

    CGFloat width = tv.bounds.size.width;
    CGFloat oldH = 0;
    if (footer) {
        oldH = footer.frame.size.height;
        if (oldH < 1)
            oldH = [footer systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                          withHorizontalFittingPriority:UILayoutPriorityRequired
                                verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    }
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, oldH + 76)];
    container.tag = kZXFooterTag;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (footer) {
        footer.frame = CGRectMake(0, 0, width, oldH);
        footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [container addSubview:footer];
    }
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(16, oldH + 14, width - 32, 48);
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [b setTitle:[NSString stringWithFormat:@"thanhthe • %@", ZX_MOD_VERSION] forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = ZXColorZaloRed();
    b.layer.cornerRadius = 12;
    [b addTarget:[ZXUI class] action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:b];
    tv.tableFooterView = container;
}

static void ZXHookSettingsButton(void)
{
    if (gSettingsHooked) return;
    Class cls = NSClassFromString(@"SettingUI40TableViewController");
    if (!cls) return;
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(id self_, BOOL animated) {
        ((void (*)(id, SEL, BOOL))orig)(self_, sel, animated);
        ZXAddSettingsButton(self_);
    });
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m)))
        method_setImplementation(m, newImp);
    gSettingsHooked = YES;
    ZXLog(@"settings button hooked");
}

// ---------------------------------------------------------------- floating tab bar (experimental)

static const char kZXTabBarStyledKey;

static UIVisualEffect *ZXTabBarBlurEffect(void)
{
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
}

static UIView *ZXFindTabBar(UIView *root)
{
    if (!root) return nil;
    NSString *lc = NSStringFromClass(root.class).lowercaseString;
    if (([lc containsString:@"tabbar"] || [root isKindOfClass:[UITabBar class]])
        && root.bounds.size.width > 100) {
        NSInteger itemCount = 0;
        for (UIView *v in root.subviews)
            if ([NSStringFromClass(v.class) containsString:@"TabBarButton"]) itemCount++;
        if (itemCount >= 2) return root;
    }
    for (UIView *v in root.subviews) {
        UIView *found = ZXFindTabBar(v);
        if (found) return found;
    }
    return nil;
}

static UIView *ZXFindTabBarInAnyWindow(void)
{
    for (UIWindow *w in ZXUIAllSceneWindows()) {
        UIView *found = ZXFindTabBar(w);
        if (found) return found;
    }
    return nil;
}

static NSString *ZXClassChain(Class c)
{
    NSMutableString *s = [NSMutableString new];
    for (int i = 0; c && i < 6; i++, c = class_getSuperclass(c)) {
        if (s.length) [s appendString:@" < "];
        [s appendString:NSStringFromClass(c)];
    }
    return s;
}

static CGRect ZXFloatingTabBarFrame(UIView *bar, CGRect proposed)
{
    CGFloat width = proposed.size.width > 0 ? proposed.size.width : bar.superview.bounds.size.width;
    CGFloat bottom = proposed.origin.y + proposed.size.height;
    if (width <= 0 || bottom <= 0) return proposed;
    UIWindow *w = bar.window ?: ZXKeyWindow();
    CGFloat safeBottom = w ? w.safeAreaInsets.bottom : 0;
    CGFloat margin = 14, height = 56;
    CGFloat y = bottom - height - MAX(safeBottom, 8) - 6;
    return CGRectMake(margin, y, width - margin * 2, height);
}

@interface ZXTabBarBlob : NSObject
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, weak) UIVisualEffectView *blob;
@property (nonatomic, weak) UILongPressGestureRecognizer *gesture;
@property (nonatomic, weak) UIView *startButton;
@end

@implementation ZXTabBarBlob

- (NSArray<UIView *> *)buttonsSortedByX
{
    NSMutableArray<UIView *> *btns = [NSMutableArray new];
    for (UIView *v in self.bar.subviews)
        if ([NSStringFromClass(v.class) containsString:@"TabBarButton"]) [btns addObject:v];
    [btns sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return btns;
}

- (UIView *)buttonNearestX:(CGFloat)x among:(NSArray<UIView *> *)btns
{
    UIView *best = nil;
    CGFloat bestDist = CGFLOAT_MAX;
    for (UIView *b in btns) {
        CGFloat cx = b.frame.origin.x + b.frame.size.width / 2;
        CGFloat d = fabs(cx - x);
        if (d < bestDist) { bestDist = d; best = b; }
    }
    return best;
}

- (void)moveBlobTo:(UIView *)button
{
    if (!button || !self.blob) return;
    CGRect target = CGRectInset(button.frame, -6, -6);
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.blob.frame = target;
        self.blob.alpha = 0.85;
    } completion:nil];
}

- (void)handlePress:(UILongPressGestureRecognizer *)g
{
    UIView *bar = self.bar;
    if (!bar || !ZXFloatingTabBarOn() || ZXReduceMotion()) { self.blob.alpha = 0; return; }
    CGPoint pt = [g locationInView:bar];
    NSArray<UIView *> *btns = [self buttonsSortedByX];
    UIView *target = [self buttonNearestX:pt.x among:btns];

    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            self.startButton = target;
            [self moveBlobTo:target];
            ZXNoteTabBarInteraction(bar);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            [self moveBlobTo:target];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (target != self.startButton && [target isKindOfClass:[UIControl class]])
                [(UIControl *)target sendActionsForControlEvents:UIControlEventTouchUpInside];
            [UIView animateWithDuration:0.25 delay:0.12 options:0 animations:^{ self.blob.alpha = 0; } completion:nil];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [UIView animateWithDuration:0.2 animations:^{ self.blob.alpha = 0; }];
            break;
        }
        default:
            break;
    }
}
@end

static const char kZXTabBarBlobKey;

static void ZXAttachTabBarBlob(UIView *bar)
{
    if (objc_getAssociatedObject(bar, &kZXTabBarBlobKey)) return;
    UIVisualEffectView *blob = [[UIVisualEffectView alloc] initWithEffect:ZXTabBarBlurEffect()];
    blob.userInteractionEnabled = NO;
    blob.alpha = 0;
    blob.layer.cornerRadius = 20;
    if (@available(iOS 13.0, *)) blob.layer.cornerCurve = kCACornerCurveContinuous;
    blob.clipsToBounds = YES;
    [bar insertSubview:blob atIndex:1];

    ZXTabBarBlob *h = [ZXTabBarBlob new];
    h.bar = bar;
    h.blob = blob;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:h action:@selector(handlePress:)];
    g.minimumPressDuration = 0;
    g.cancelsTouchesInView = NO;
    [bar addGestureRecognizer:g];
    h.gesture = g;
    objc_setAssociatedObject(bar, &kZXTabBarBlobKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ZXDetachTabBarBlob(UIView *bar)
{
    ZXTabBarBlob *h = objc_getAssociatedObject(bar, &kZXTabBarBlobKey);
    if (!h) return;
    [h.blob removeFromSuperview];
    if (h.gesture) [bar removeGestureRecognizer:h.gesture];
    objc_setAssociatedObject(bar, &kZXTabBarBlobKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface ZXTabBarCollapser : NSObject
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, strong) UIButton *pill;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, assign) NSInteger idleGeneration;
@end

@implementation ZXTabBarCollapser

- (void)ensurePill
{
    if (self.pill || !self.bar.superview) return;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.hidden = YES;
    b.clipsToBounds = YES;
    b.backgroundColor = ZXColorCardBg();
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = ZXColorCardBorder().CGColor;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowRadius = 5;
    b.layer.shadowOffset = CGSizeMake(0, 2);

    UIImageView *iv = [[UIImageView alloc] init];
    iv.tag = 7001;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:iv];
    [NSLayoutConstraint activateConstraints:@[
        [iv.centerXAnchor constraintEqualToAnchor:b.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
        [iv.widthAnchor constraintLessThanOrEqualToConstant:20],
        [iv.heightAnchor constraintLessThanOrEqualToConstant:20],
    ]];
    [b addTarget:self action:@selector(pillTapped) forControlEvents:UIControlEventTouchUpInside];
    self.pill = b;
    [self.bar.superview addSubview:b];
}

- (void)updatePillIcon
{
    UIImageView *iv = [self.pill viewWithTag:7001];
    UIImage *img = nil;
    if ([self.bar isKindOfClass:[UITabBar class]]) {
        UITabBarItem *item = ((UITabBar *)self.bar).selectedItem;
        img = item.selectedImage ?: item.image;
    }
    if (!img) {
        if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:@"circle.grid.2x2.fill"];
    }
    iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    iv.tintColor = ZXColorZaloRed();
}

- (void)collapse
{
    if (self.collapsed || !ZXFloatingTabBarOn()) return;
    UIView *bar = self.bar;
    if (!bar || bar.alpha < 0.5) return;
    self.collapsed = YES;
    [self ensurePill];
    if (!self.pill) return;
    CGRect f = bar.frame;
    CGFloat d = 40;
    self.pill.frame = CGRectMake(f.origin.x, f.origin.y + (f.size.height - d) / 2, d, d);
    self.pill.layer.cornerRadius = d / 2;
    [self updatePillIcon];
    self.pill.hidden = NO;
    self.pill.alpha = 0;
    self.pill.transform = CGAffineTransformMakeScale(0.6, 0.6);
    bar.userInteractionEnabled = NO;
    void (^apply)(void) = ^{
        bar.alpha = 0;
        self.pill.alpha = 1;
        self.pill.transform = CGAffineTransformIdentity;
    };
    if (ZXReduceMotion()) { apply(); return; }
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.3
                         options:UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
}

- (void)expand
{
    if (!self.collapsed) { [self noteInteraction]; return; }
    UIView *bar = self.bar;
    if (!bar) return;
    self.collapsed = NO;
    bar.userInteractionEnabled = YES;
    void (^apply)(void) = ^{
        bar.alpha = 1;
        self.pill.alpha = 0;
        self.pill.transform = CGAffineTransformMakeScale(0.6, 0.6);
    };
    void (^done)(BOOL) = ^(BOOL fin) { if (fin) self.pill.hidden = YES; };
    if (ZXReduceMotion()) { apply(); done(YES); } else {
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.3
                             options:UIViewAnimationOptionAllowUserInteraction animations:apply completion:done];
    }
    [self noteInteraction];
}

- (void)pillTapped { [self expand]; }

- (void)noteInteraction
{
    self.idleGeneration++;
    double secs = [ZXConfig tabBarIdleSeconds];
    if (secs <= 0) return;
    NSInteger gen = self.idleGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.idleGeneration == gen && [ZXConfig tabBarIdleSeconds] > 0) [strongSelf collapse];
    });
}

- (void)syncWithBarHidden:(BOOL)barHidden
{
    if (!self.pill) return;
    if (barHidden) self.pill.hidden = YES;
    else if (self.collapsed) self.pill.hidden = NO;
}
@end

static const char kZXTabBarCollapserKey;

static void ZXNoteTabBarInteraction(UIView *bar)
{
    ZXTabBarCollapser *c = objc_getAssociatedObject(bar, &kZXTabBarCollapserKey);
    [c noteInteraction];
}

static void ZXSyncTabBarVisibility(UIView *bar)
{
    ZXTabBarCollapser *c = objc_getAssociatedObject(bar, &kZXTabBarCollapserKey);
    [c syncWithBarHidden:bar.hidden];
}

static void ZXAttachTabBarCollapser(UIView *bar)
{
    ZXTabBarCollapser *c = objc_getAssociatedObject(bar, &kZXTabBarCollapserKey);
    if (c) return;
    c = [ZXTabBarCollapser new];
    c.bar = bar;
    objc_setAssociatedObject(bar, &kZXTabBarCollapserKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [c noteInteraction];
}

static void ZXDetachTabBarCollapser(UIView *bar)
{
    ZXTabBarCollapser *c = objc_getAssociatedObject(bar, &kZXTabBarCollapserKey);
    if (!c) return;
    c.idleGeneration++;
    [c.pill removeFromSuperview];
    bar.alpha = 1;
    bar.userInteractionEnabled = YES;
    objc_setAssociatedObject(bar, &kZXTabBarCollapserKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ZXStyleTabBarOnce(UIView *bar)
{
    if (objc_getAssociatedObject(bar, &kZXTabBarStyledKey)) return;
    objc_setAssociatedObject(bar, &kZXTabBarStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    bar.layer.cornerRadius = 26;
    if (@available(iOS 13.0, *)) bar.layer.cornerCurve = kCACornerCurveContinuous;
    bar.layer.masksToBounds = NO;
    bar.layer.borderWidth = 1.0;
    bar.layer.borderColor = ZXColorCardBorder().CGColor;
    bar.layer.shadowColor = UIColor.blackColor.CGColor;
    bar.layer.shadowOpacity = 0.25;
    bar.layer.shadowRadius = 14;
    bar.layer.shadowOffset = CGSizeMake(0, 6);

    if ([bar isKindOfClass:[UITabBar class]]) {
        UITabBar *tb = (UITabBar *)bar;
        if (@available(iOS 13.0, *)) {
            UITabBarAppearance *ap = [UITabBarAppearance new];
            [ap configureWithTransparentBackground];
            ap.backgroundColor = UIColor.clearColor;
            ap.shadowColor = UIColor.clearColor;
            tb.standardAppearance = ap;
            if (@available(iOS 15.0, *)) tb.scrollEdgeAppearance = ap;
        } else {
            tb.backgroundImage = [UIImage new];
            tb.shadowImage = [UIImage new];
            tb.translucent = YES;
        }
    } else {
        bar.backgroundColor = UIColor.clearColor;
        bar.opaque = NO;
        @try { [bar setValue:[UIImage new] forKey:@"backgroundImage"]; } @catch (__unused id e) {}
    }

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:ZXTabBarBlurEffect()];
    blur.frame = bar.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 26;
    if (@available(iOS 13.0, *)) blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
    blur.userInteractionEnabled = NO;
    [bar insertSubview:blur atIndex:0];
}

static void ZXUnstyleTabBar(UIView *bar)
{
    if (!objc_getAssociatedObject(bar, &kZXTabBarStyledKey)) return;
    objc_setAssociatedObject(bar, &kZXTabBarStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    bar.layer.cornerRadius = 0;
    bar.layer.borderWidth = 0;
    bar.layer.shadowOpacity = 0;
    for (UIView *v in bar.subviews.copy)
        if ([v isKindOfClass:[UIVisualEffectView class]]) [v removeFromSuperview];
    if ([bar isKindOfClass:[UITabBar class]]) {
        UITabBar *tb = (UITabBar *)bar;
        if (@available(iOS 13.0, *)) {
            UITabBarAppearance *def = [UITabBarAppearance new];
            [def configureWithDefaultBackground];
            tb.standardAppearance = def;
            if (@available(iOS 15.0, *)) tb.scrollEdgeAppearance = def;
        } else {
            tb.backgroundImage = nil;
            tb.shadowImage = nil;
        }
    }
}

static BOOL ZXFloatingTabBarOn(void) { return [ZXConfig boolForKey:ZXK_FLOATING_TABBAR] && !ZXReduceTransparency(); }

static void ZXApplyFloatingTabBarState(UIView *bar)
{
    if (!bar) return;
    if (ZXFloatingTabBarOn()) {
        ZXStyleTabBarOnce(bar);
        CGRect full = bar.superview ? bar.superview.bounds : bar.frame;
        bar.frame = ZXFloatingTabBarFrame(bar, full);
        ZXAttachTabBarBlob(bar);
        ZXAttachTabBarCollapser(bar);
    } else {
        ZXUnstyleTabBar(bar);
        ZXDetachTabBarBlob(bar);
        ZXDetachTabBarCollapser(bar);
        [bar setNeedsLayout];
    }
}

static void ZXHookFloatingTabBar(void)
{
    UIView *bar = ZXFindTabBarInAnyWindow();
    if (!bar) return;
    Class cls = object_getClass(bar);
    static NSMutableSet<NSString *> *hooked;
    if (!hooked) hooked = [NSMutableSet new];
    NSString *clsName = NSStringFromClass(cls);
    if ([hooked containsObject:clsName]) { ZXApplyFloatingTabBarState(bar); return; }

    NSMutableString *subs = [NSMutableString new];
    for (UIView *v in bar.subviews) [subs appendFormat:@"%@(%@) ", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
    ZXLog(@"tab bar candidate: %@ | chain: %@ | frame=%@ | subviews: %@",
          clsName, ZXClassChain(cls), NSStringFromCGRect(bar.frame), subs);

    SEL sel = @selector(setFrame:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(UIView *self_, CGRect frame) {
        if (ZXFloatingTabBarOn() && !self_.hidden) frame = ZXFloatingTabBarFrame(self_, frame);
        ((void (*)(id, SEL, CGRect))orig)(self_, sel, frame);
    });
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m)))
        method_setImplementation(m, newImp);

    SEL layoutSel = @selector(layoutSubviews);
    Method lm = class_getInstanceMethod(cls, layoutSel);
    if (lm) {
        IMP origLayout = method_getImplementation(lm);
        IMP newLayoutImp = imp_implementationWithBlock(^(UIView *self_) {
            ((void (*)(id, SEL))origLayout)(self_, layoutSel);
            if (ZXFloatingTabBarOn()) {
                CGRect full = self_.superview ? self_.superview.bounds : self_.frame;
                CGRect want = ZXFloatingTabBarFrame(self_, full);
                if (!CGRectEqualToRect(self_.frame, want)) self_.frame = want;
            }
        });
        if (!class_addMethod(cls, layoutSel, newLayoutImp, method_getTypeEncoding(lm)))
            method_setImplementation(lm, newLayoutImp);
    }

    SEL windowSel = @selector(didMoveToWindow);
    Method wm = class_getInstanceMethod(cls, windowSel);
    if (wm) {
        IMP origWindow = method_getImplementation(wm);
        IMP newWindowImp = imp_implementationWithBlock(^(UIView *self_) {
            ((void (*)(id, SEL))origWindow)(self_, windowSel);
            if (self_.window) ZXApplyFloatingTabBarState(self_);
        });
        if (!class_addMethod(cls, windowSel, newWindowImp, method_getTypeEncoding(wm)))
            method_setImplementation(wm, newWindowImp);
    }

    SEL hiddenSel = @selector(setHidden:);
    Method hm = class_getInstanceMethod(cls, hiddenSel);
    if (hm) {
        IMP origHidden = method_getImplementation(hm);
        IMP newHiddenImp = imp_implementationWithBlock(^(UIView *self_, BOOL hidden) {
            ((void (*)(id, SEL, BOOL))origHidden)(self_, hiddenSel, hidden);
            ZXSyncTabBarVisibility(self_);
        });
        if (!class_addMethod(cls, hiddenSel, newHiddenImp, method_getTypeEncoding(hm)))
            method_setImplementation(hm, newHiddenImp);
    }

    [hooked addObject:clsName];
    ZXLog(@"floating tab bar hooked on %@", clsName);
    ZXApplyFloatingTabBarState(bar);
}

// ---------------------------------------------------------------- installer

@implementation ZXUI

+ (void)install
{
    @try {
        ZXHookBubbleShow();
        ZXHookSettingsButton();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            (void)n;
            @try {
                ZXHookSettingsButton();
                [ZXBubble show];
                ZXRefreshFloatingBubbleNow();
            } @catch (__unused NSException *e) {}
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try {
                ZXHookSettingsButton();
                [ZXBubble restoreIfNeeded];
                ZXRefreshFloatingBubbleNow();
            } @catch (__unused NSException *e) {}
        });
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                @try { ZXHookFloatingTabBar(); } @catch (__unused NSException *e) {}
            });
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            (void)n;
            @try {
                [self attachGesture];
                [ZXBubble restoreIfNeeded];
                ZXRefreshFloatingBubbleNow();
                ZXHookFloatingTabBar();
            } @catch (__unused NSException *e) {}
        }];
    } @catch (NSException *e) {
        ZXLog(@"ZXUI install exception: %@", e.reason);
    }
}

+ (void)attachGesture
{
    UIWindow *w = ZXKeyWindow();
    if (!w) return;
    static const char kKey;
    if (objc_getAssociatedObject(w, &kKey)) return;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    g.numberOfTouchesRequired = 3;
    g.minimumPressDuration = 0.8;
    g.cancelsTouchesInView = NO;
    [w addGestureRecognizer:g];
    objc_setAssociatedObject(w, &kKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state == UIGestureRecognizerStateBegan) [self show];
}

+ (void)show
{
    [ZXBubble hide];
    UIViewController *top = ZXTopVC();
    if (!top) return;
    if ([top isKindOfClass:[UINavigationController class]]) {
        UIViewController *first = ((UINavigationController *)top).viewControllers.firstObject;
        if ([first isKindOfClass:[ZXFeatureListViewController class]]) return;
    }
    ZXFeatureListViewController *mainVC = [ZXFeatureListViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:mainVC];
    if (@available(iOS 13.0, *)) nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    ZXStyleNavBar(nav.navigationBar);
    [top presentViewController:nav animated:YES completion:nil];
}

@end
