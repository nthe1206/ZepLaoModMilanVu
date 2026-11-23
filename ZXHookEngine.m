#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <AVFoundation/AVFoundation.h>
#import "ZXHookEngine.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import "ZXAntiRecall.h"
#import "ZXRecallMarker.h"
#import <objc/runtime.h>

typedef uintptr_t ZXWord;

static NSMutableSet<NSString *> *gInstalled;
static NSMutableArray<NSDictionary *> *gPending;
static NSMutableDictionary<NSString *, NSDictionary *> *gHiddenChatsMap;
static NSMutableSet<NSString *> *gUnlockedSessionChats;
static NSURL *gLastVoiceURL;
static AVAudioRecorder *gCallRecorder;
static __weak UIViewController *gActiveChatVC;

// ---- helpers: trace logging and argument matching -------------------------

static NSString *ZXDescribeWord(ZXWord w, BOOL isObj)
{
    if (!isObj) return [NSString stringWithFormat:@"%lu", (unsigned long)w];
    if (w == 0) return @"nil";
    @try {
        id o = (__bridge id)(void *)w;
        NSString *d = [o description];
        if (d.length > 400) d = [[d substringToIndex:400] stringByAppendingString:@"..."];
        d = [d stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([o class]), d];
    } @catch (NSException *e) {
        (void)e;
        return @"<?>";
    }
}

static void ZXTraceCall(NSString *tag, NSArray<NSNumber *> *objKinds, const ZXWord *args)
{
    NSMutableString *out = [NSMutableString stringWithFormat:@"TRACE %@", tag];
    for (NSUInteger i = 0; i < objKinds.count; i++)
        [out appendFormat:@"\n    arg%lu = %@", (unsigned long)(i + 1), ZXDescribeWord(args[i], [objKinds[i] boolValue])];
    ZXLogImpl(out);
}

static void ZXMarkArgs(NSArray<NSNumber *> *objKinds, const ZXWord *args)
{
    NSMutableArray *objs = [NSMutableArray new];
    for (NSUInteger i = 0; i < objKinds.count; i++)
        if ([objKinds[i] boolValue] && args[i]) [objs addObject:(__bridge id)(void *)args[i]];
    [ZXRecallMarker markObjects:objs];
}

static BOOL ZXArgMatches(NSInteger matchArg, NSString *matchText, const ZXWord *args)
{
    if (matchArg < 1 || matchArg > 6 || matchText.length == 0) return YES;
    NSString *d = ZXDescribeWord(args[matchArg - 1], YES);
    return [d rangeOfString:matchText options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void ZXApplyVideoOriginal(id cfg, id info)
{
    if (!cfg || !info) return;
    @try {
        double curDim = [[cfg valueForKey:@"dimension"] doubleValue];
        double curBR = [[cfg valueForKey:@"videoBitrate"] doubleValue];
        if (curDim < 700) return;
        double srcBR = 0;
        id v = [info valueForKey:@"videoBitrate"];
        if ([v respondsToSelector:@selector(doubleValue)]) srcBR = [v doubleValue];
        CGSize rs = CGSizeZero;
        id r = [info valueForKey:@"resolution"];
        if ([r isKindOfClass:[NSValue class]]) rs = [r CGSizeValue];
        double side = MAX(rs.width, rs.height);
        double newDim = curDim, newBR = curBR;
        if (side > curDim) newDim = side;
        if (srcBR > curBR) newBR = MIN(srcBR, 40000000.0);
        if (newDim != curDim) [cfg setValue:@(newDim) forKey:@"dimension"];
        if (newBR != curBR) [cfg setValue:@(newBR) forKey:@"videoBitrate"];
        ZXLog(@"video original: dimension %.0f -> %.0f, bitrate %.0f -> %.0f (source %.0fx%.0f @ %.0f)",
              curDim, newDim, curBR, newBR, rs.width, rs.height, srcBR);
    } @catch (NSException *e) {
        ZXLog(@"video original failed: %@", e.reason);
    }
}

// ---- NTHE Feature 1: Hidden Chats persistence & extraction ----------------

static NSString *ZXHiddenChatsStorePath(void)
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"hidden_chats.json"];
}

static void ZXInitHiddenChatsStore(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gHiddenChatsMap = [NSMutableDictionary new];
        gUnlockedSessionChats = [NSMutableSet new];
        NSData *d = [NSData dataWithContentsOfFile:ZXHiddenChatsStorePath()];
        if (d) {
            id arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([arr isKindOfClass:[NSArray class]]) {
                for (NSDictionary *item in arr) {
                    NSString *uid = [item[@"uid"] description];
                    if (uid.length) gHiddenChatsMap[uid] = item;
                }
            }
        }
    });
}

static void ZXSaveHiddenChatsStore(void)
{
    ZXInitHiddenChatsStore();
    NSArray *all = gHiddenChatsMap.allValues ?: @[];
    NSData *d = [NSJSONSerialization dataWithJSONObject:all options:0 error:nil];
    if (d) [d writeToFile:ZXHiddenChatsStorePath() atomically:YES];
}

static NSString *ZXReadStringKVC(id obj, NSArray<NSString *> *keys)
{
    if (!obj) return @"";
    for (NSString *k in keys) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(k)]) {
                id v = [obj valueForKey:k];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return (NSString *)v;
                if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
            }
        } @catch (__unused NSException *e) {}
    }
    return @"";
}

static void ZXRecordHiddenConversationObject(id obj)
{
    if (!obj) return;
    ZXInitHiddenChatsStore();
    NSString *uid = ZXReadStringKVC(obj, @[@"threadId", @"conversationId", @"userId", @"uid", @"chatId", @"targetId", @"identifier"]);
    NSString *name = ZXReadStringKVC(obj, @[@"displayName", @"threadName", @"name", @"title", @"contactName", @"userName"]);
    NSString *lastMsg = ZXReadStringKVC(obj, @[@"lastMessage", @"lastMsgText", @"snippet", @"content", @"lastMessageContent", @"subtitle"]);
    if (uid.length == 0 && name.length == 0) return;
    if (uid.length == 0) uid = name;
    if (name.length == 0) name = [NSString stringWithFormat:@"Hội thoại #%@", uid];
    if (lastMsg.length == 0) lastMsg = @"(Tin nhắn đang ẩn)";
    NSDictionary *entry = @{
        @"uid": uid,
        @"name": name,
        @"lastMessage": lastMsg,
        @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
    };
    @synchronized (gHiddenChatsMap) {
        gHiddenChatsMap[uid] = entry;
        ZXSaveHiddenChatsStore();
    }
}

// ---- NTHE Feature 5b: Automatic Call Recorder (.m4a) ----------------------

static void ZXStartCallRecordingIfNeeded(void)
{
    if (![ZXConfig boolForKey:ZXK_AUTO_CALL_RECORD]) return;
    if (gCallRecorder && gCallRecorder.isRecording) return;

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"Call_%@.m4a", [df stringFromDate:[NSDate date]]];
    NSString *fullPath = [[ZXConfig callRecordsDir] stringByAppendingPathComponent:fileName];
    NSURL *url = [NSURL fileURLWithPath:fullPath];

    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @44100.0,
        AVNumberOfChannelsKey: @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    };
    NSError *err = nil;
    AVAudioRecorder *rec = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&err];
    if (rec && !err) {
        [rec prepareToRecord];
        if ([rec record]) {
            gCallRecorder = rec;
            ZXLog(@"NTHE call recording started: %@", fileName);
        }
    } else {
        ZXLog(@"NTHE call recording error: %@", err.localizedDescription);
    }
}

static void ZXStopCallRecordingIfActive(void)
{
    if (gCallRecorder && gCallRecorder.isRecording) {
        [gCallRecorder stop];
        ZXLog(@"NTHE call recording saved: %@", gCallRecorder.url.lastPathComponent);
    }
    gCallRecorder = nil;
}

// ---- NTHE Feature 2 & 4 & 5c: UI Hooks (Chat Lock, Repeater, Voice Speed) --

static UIWindow *ZXActiveWindow(void)
{
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows)
                if (w.isKeyWindow) return w;
        }
    }
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    return w ?: UIApplication.sharedApplication.windows.firstObject;
}

static UIViewController *ZXTopPresentedVC(void)
{
    UIViewController *v = ZXActiveWindow().rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

static UITextView *ZXFindChatInputTextView(UIView *root)
{
    if (!root || root.hidden || root.alpha < 0.05) return nil;
    if ([root isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)root;
        if (tv.isEditable && tv.bounds.size.height >= 24 && tv.bounds.size.height <= 160) {
            return tv;
        }
    }
    for (UIView *sub in root.subviews) {
        UITextView *found = ZXFindChatInputTextView(sub);
        if (found) return found;
    }
    return nil;
}

static UIControl *ZXFindSendButtonNear(UIView *inputBar, UITextView *tv)
{
    UIView *container = inputBar ?: tv.superview.superview ?: tv.superview;
    if (!container) return nil;
    UIControl *best = nil;
    CGFloat maxX = -1;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[UIControl class]] && !sub.hidden && sub.alpha > 0.1 && sub.tag != 0x4E545250) {
            if (sub.frame.origin.x > maxX) {
                maxX = sub.frame.origin.x;
                best = (UIControl *)sub;
            }
        }
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:[UIControl class]] && !sub2.hidden && sub2.alpha > 0.1 && sub2.tag != 0x4E545250) {
                CGRect r = [sub2 convertRect:sub2.bounds toView:container];
                if (r.origin.x > maxX) {
                    maxX = r.origin.x;
                    best = (UIControl *)sub2;
                }
            }
        }
    }
    return best;
}

static void ZXSendSingleTextInChat(UIViewController *chatVC, NSString *text)
{
    if (text.length == 0) return;
    // 1. Try direct sendText/sendMessage selectors on chatVC
    for (NSString *selName in @[@"sendTextMessage:", @"sendMessageWithText:", @"sendText:", @"onSendText:"]) {
        SEL s = NSSelectorFromString(selName);
        if (chatVC && [chatVC respondsToSelector:s]) {
            @try {
                ((void (*)(id, SEL, id))[chatVC methodForSelector:s])(chatVC, s, text);
                return;
            } @catch (__unused NSException *e) {}
        }
    }
    // 2. Fallback: populate the active chat UITextView and trigger delegate / Send button
    UIView *root = chatVC.view ?: ZXActiveWindow();
    UITextView *tv = ZXFindChatInputTextView(root);
    if (tv) {
        tv.text = text;
        if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [tv.delegate textViewDidChange:tv];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
        UIControl *sendBtn = ZXFindSendButtonNear(tv.superview.superview, tv);
        if (sendBtn) {
            [sendBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
        if ([tv.delegate respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]) {
            [tv.delegate textView:tv shouldChangeTextInRange:NSMakeRange(text.length, 0) replacementText:@"\n"];
        }
    }
}

@interface ZXUIRuntimeHelper : NSObject
+ (void)onRepeatButtonTapped:(UIButton *)sender;
+ (void)onUnlockButtonTapped:(UIButton *)sender;
+ (void)onCellLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation ZXUIRuntimeHelper

+ (void)onRepeatButtonTapped:(UIButton *)sender
{
    (void)sender;
    [ZXHookEngine presentRepeaterDialogFromVC:ZXTopPresentedVC()];
}

+ (void)onUnlockButtonTapped:(UIButton *)sender
{
    UIView *shield = sender.superview;
    if (!shield) return;
    NSString *chatKey = objc_getAssociatedObject(shield, "nthe_chat_key") ?: @"locked";
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&err]) {
        [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"Xác thực để mở khóa phòng chat này"
                      reply:^(BOOL success, NSError * _Nullable error) {
            (void)error;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    [gUnlockedSessionChats addObject:chatKey];
                    [UIView animateWithDuration:0.22 animations:^{ shield.alpha = 0; } completion:^(BOOL f) {
                        (void)f;
                        [shield removeFromSuperview];
                    }];
                }
            });
        }];
    } else {
        // Fallback to 4-digit PIN prompt
        UIViewController *top = ZXTopPresentedVC();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nhập mã PIN khóa chat"
                                                                   message:@"Nhập mã PIN 4 số dự phòng của bạn"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.secureTextEntry = YES;
            tf.placeholder = @"****";
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Mở khóa" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            (void)act;
            NSString *entered = a.textFields.firstObject.text ?: @"";
            NSString *pin = [ZXConfig chatLockPIN];
            if (pin.length == 0 || [entered isEqualToString:pin]) {
                [gUnlockedSessionChats addObject:chatKey];
                [shield removeFromSuperview];
            }
        }]];
        [top presentViewController:a animated:YES completion:nil];
    }
}

+ (void)onCellLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *cell = g.view;
    if (!cell) return;

    // Extract title or ID from the cell
    NSMutableArray<NSString *> *texts = [NSMutableArray new];
    for (UIView *sub in cell.subviews) {
        if ([sub isKindOfClass:[UILabel class]] && [(UILabel *)sub text].length)
            [texts addObject:[(UILabel *)sub text]];
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:[UILabel class]] && [(UILabel *)sub2 text].length)
                [texts addObject:[(UILabel *)sub2 text]];
        }
    }
    NSString *chatTitle = texts.firstObject ?: @"Hội thoại";
    BOOL hasVoice = [ZXConfig boolForKey:ZXK_VOICE_MSG_TOOLS] && gLastVoiceURL != nil;
    BOOL hasLock = [ZXConfig boolForKey:ZXK_CHAT_LOCK_ENABLED];
    if (!hasVoice && !hasLock) return;

    UIViewController *top = ZXTopPresentedVC();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:chatTitle
                                                                   message:@"Tiện ích nhanh thanhthe"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (@available(iOS 13.0, *)) sheet.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    if (hasLock) {
        BOOL locked = [ZXConfig isChatLocked:chatTitle];
        NSString *lockTitle = locked ? @"🔓 Mở khóa hội thoại này" : @"🔒 Khóa hội thoại này (Face ID / PIN)";
        [sheet addAction:[UIAlertAction actionWithTitle:lockTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            (void)act;
            if (locked) [ZXConfig removeLockedChatWithID:chatTitle];
            else [ZXConfig addLockedChatWithID:chatTitle name:chatTitle];
        }]];
    }

    if (hasVoice) {
        for (NSNumber *rateNum in @[@1.0, @1.5, @2.0]) {
            double r = rateNum.doubleValue;
            NSString *rt = [NSString stringWithFormat:@"⏩ Tốc độ phát thoại: %.1fx%@", r, ([ZXConfig voicePlaybackRate] == r ? @" (Đang chọn)" : @"")];
            [sheet addAction:[UIAlertAction actionWithTitle:rt style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                (void)act;
                [ZXConfig setVoicePlaybackRate:r];
            }]];
        }
        if (gLastVoiceURL) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"💾 Lưu / Chia sẻ tệp tin nhắn thoại gốc" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                (void)act;
                UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[gLastVoiceURL] applicationActivities:nil];
                if (@available(iOS 13.0, *)) av.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                av.popoverPresentationController.sourceView = cell;
                [top presentViewController:av animated:YES completion:nil];
            }]];
        }
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    [top presentViewController:sheet animated:YES completion:nil];
}

@end

static void ZXAttachLockShieldIfNeeded(UIViewController *vc)
{
    if (!vc || ![ZXConfig boolForKey:ZXK_CHAT_LOCK_ENABLED]) return;
    NSString *clsName = NSStringFromClass([vc class]);
    if ([clsName hasPrefix:@"ZX"] || [clsName hasPrefix:@"UI"] || [clsName hasPrefix:@"_"]) return;
    BOOL looksLikeChat = ([clsName rangeOfString:@"Chat" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                          [clsName rangeOfString:@"CSC" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                          [clsName rangeOfString:@"MessageView" options:NSCaseInsensitiveSearch].location != NSNotFound);
    if (!looksLikeChat) return;

    gActiveChatVC = vc;
    NSString *chatTitle = vc.navigationItem.title ?: vc.title ?: @"";
    NSString *threadId = ZXReadStringKVC(vc, @[@"threadId", @"chatId", @"targetUserId", @"conversationId", @"userId"]);
    NSString *matchKey = nil;
    if (chatTitle.length && [ZXConfig isChatLocked:chatTitle]) matchKey = chatTitle;
    else if (threadId.length && [ZXConfig isChatLocked:threadId]) matchKey = threadId;
    if (!matchKey) return;

    ZXInitHiddenChatsStore();
    if ([gUnlockedSessionChats containsObject:matchKey]) return;
    if ([vc.view viewWithTag:0x4E544845]) return;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark];
    UIVisualEffectView *shield = [[UIVisualEffectView alloc] initWithEffect:blur];
    shield.tag = 0x4E544845;
    shield.frame = vc.view.bounds;
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shield.backgroundColor = [UIColor colorWithRed:0.051 green:0.059 blue:0.071 alpha:0.92];
    objc_setAssociatedObject(shield, "nthe_chat_key", matchKey, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(24, shield.bounds.size.height * 0.34, shield.bounds.size.width - 48, 64)];
    lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    lbl.numberOfLines = 2;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    lbl.text = [NSString stringWithFormat:@"🔒 Phòng chat \"%@\" đang khóa\nXác thực Face ID / Mật khẩu để xem", matchKey];
    [shield.contentView addSubview:lbl];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake((shield.bounds.size.width - 210) / 2.0, shield.bounds.size.height * 0.46, 210, 46);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    btn.backgroundColor = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:1.0];
    btn.layer.cornerRadius = 12;
    [btn setTitle:@"Xác thực Mở khóa" forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    [btn addTarget:[ZXUIRuntimeHelper class] action:@selector(onUnlockButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [shield addSubview:btn];

    [vc.view addSubview:shield];
    [ZXUIRuntimeHelper onUnlockButtonTapped:btn];
}

static void ZXAttachRepeaterButtonIfNeeded(UIViewController *vc)
{
    if (!vc || ![ZXConfig boolForKey:ZXK_MSG_REPEATER]) return;
    NSString *clsName = NSStringFromClass([vc class]);
    if ([clsName hasPrefix:@"ZX"] || [clsName hasPrefix:@"UI"]) return;
    UITextView *tv = ZXFindChatInputTextView(vc.view);
    if (!tv) return;
    gActiveChatVC = vc;

    UIView *bar = tv.superview ?: vc.view;
    if ([bar viewWithTag:0x4E545250]) return;

    UIButton *repBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    repBtn.tag = 0x4E545250;
    repBtn.frame = CGRectMake(MAX(4, bar.bounds.size.width - 78), MAX(4, (bar.bounds.size.height - 32) / 2.0), 32, 32);
    repBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    repBtn.backgroundColor = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:0.95];
    repBtn.layer.cornerRadius = 16;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
        UIImage *im = [[UIImage systemImageNamed:@"repeat" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        [repBtn setImage:im forState:UIControlStateNormal];
    } else {
        [repBtn setTitle:@"↻" forState:UIControlStateNormal];
    }
    repBtn.tintColor = UIColor.whiteColor;
    [repBtn addTarget:[ZXUIRuntimeHelper class] action:@selector(onRepeatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:repBtn];
}

// ---- Dynamic runtime hooks for all 6 new features -------------------------

static void ZXInstallExtendedFeatureHooks(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZXInitHiddenChatsStore();

        // 1. Hook UIViewController -viewDidAppear: for Chat Lock & Message Repeater button attachment
        Method vda = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
        if (vda) {
            IMP origVDA = method_getImplementation(vda);
            method_setImplementation(vda, imp_implementationWithBlock(^(UIViewController *self_, BOOL animated) {
                ((void (*)(id, SEL, BOOL))origVDA)(self_, @selector(viewDidAppear:), animated);
                @try {
                    ZXAttachLockShieldIfNeeded(self_);
                    ZXAttachRepeaterButtonIfNeeded(self_);
                } @catch (__unused NSException *e) {}
            }));
        }

        // 2. Hook UITableViewCell -didMoveToWindow for long-press quick lock & voice message menu
        Method dmw = class_getInstanceMethod([UITableViewCell class], @selector(didMoveToWindow));
        if (dmw) {
            IMP origDMW = method_getImplementation(dmw);
            method_setImplementation(dmw, imp_implementationWithBlock(^(UITableViewCell *self_) {
                ((void (*)(id, SEL))origDMW)(self_, @selector(didMoveToWindow));
                if (!self_.window) return;
                NSString *cn = NSStringFromClass([self_ class]);
                if ([cn hasPrefix:@"ZX"]) return;
                static const char kLPKey;
                if (!objc_getAssociatedObject(self_, &kLPKey)) {
                    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[ZXUIRuntimeHelper class] action:@selector(onCellLongPress:)];
                    lp.minimumPressDuration = 1.0;
                    lp.cancelsTouchesInView = NO;
                    [self_ addGestureRecognizer:lp];
                    objc_setAssociatedObject(self_, &kLPKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }));
        }

        // 3. Hook AVAudioPlayer for Voice Message Playback Rate (1.0x / 1.5x / 2.0x) & audio URL capture
        Method avInitURL = class_getInstanceMethod([AVAudioPlayer class], @selector(initWithContentsOfURL:error:));
        if (avInitURL) {
            IMP origInitURL = method_getImplementation(avInitURL);
            method_setImplementation(avInitURL, imp_implementationWithBlock(^id(AVAudioPlayer *self_, NSURL *url, NSError **err) {
                AVAudioPlayer *p = ((id (*)(id, SEL, NSURL *, NSError **))origInitURL)(self_, @selector(initWithContentsOfURL:error:), url, err);
                if (url.isFileURL) gLastVoiceURL = url;
                if (p && [ZXConfig boolForKey:ZXK_VOICE_MSG_TOOLS]) {
                    p.enableRate = YES;
                    p.rate = (float)[ZXConfig voicePlaybackRate];
                }
                return p;
            }));
        }
        Method avPlay = class_getInstanceMethod([AVAudioPlayer class], @selector(play));
        if (avPlay) {
            IMP origPlay = method_getImplementation(avPlay);
            method_setImplementation(avPlay, imp_implementationWithBlock(^BOOL(AVAudioPlayer *self_) {
                if (self_.url.isFileURL) gLastVoiceURL = self_.url;
                if ([ZXConfig boolForKey:ZXK_VOICE_MSG_TOOLS]) {
                    self_.enableRate = YES;
                    self_.rate = (float)[ZXConfig voicePlaybackRate];
                }
                return ((BOOL (*)(id, SEL))origPlay)(self_, @selector(play));
            }));
        }

        // 4. Hook AVAudioSession -setCategory:mode:options:error: to detect call start/stop for Auto Call Recording
        Method avCat = class_getInstanceMethod([AVAudioSession class], @selector(setCategory:mode:options:error:));
        if (avCat) {
            IMP origCat = method_getImplementation(avCat);
            method_setImplementation(avCat, imp_implementationWithBlock(^BOOL(AVAudioSession *self_, AVAudioSessionCategory cat, AVAudioSessionMode mode, AVAudioSessionCategoryOptions opts, NSError **err) {
                BOOL ok = ((BOOL (*)(id, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionCategoryOptions, NSError **))origCat)(self_, @selector(setCategory:mode:options:error:), cat, mode, opts, err);
                if ([cat isEqualToString:AVAudioSessionCategoryPlayAndRecord] && [ mode isEqualToString:AVAudioSessionModeVoiceChat]) {
                    ZXStartCallRecordingIfNeeded();
                } else if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient] || [cat isEqualToString:AVAudioSessionCategoryAmbient]) {
                    ZXStopCallRecordingIfActive();
                }
                return ok;
            }));
        }

        // 5. Scan app classes for Hidden Chats, Story Seen, and WebRTC Force Relay
        NSString *appPath = [[NSBundle mainBundle] bundlePath];
        unsigned count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned i = 0; i < count; i++) {
            Class c = classes[i];
            const char *img = class_getImageName(c);
            if (!img || strncmp(img, appPath.UTF8String, appPath.length) != 0) continue;
            unsigned mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            for (unsigned j = 0; j < mc; j++) {
                SEL s = method_getName(ms[j]);
                NSString *sn = NSStringFromSelector(s);
                NSString *lower = sn.lowercaseString;
                unsigned argc = method_getNumberOfArguments(ms[j]);

                // Hidden chats check: isHiddenChat / isHiddenConversation / isHiddenThread
                if (argc == 2 && ([lower isEqualToString:@"ishiddenchat"] ||
                                  [lower isEqualToString:@"ishiddenconversation"] ||
                                  [lower isEqualToString:@"ishiddenthread"] ||
                                  [lower isEqualToString:@"ishideconversation"])) {
                    char *rt = method_copyReturnType(ms[j]);
                    BOOL isBool = rt && (rt[0] == 'B' || rt[0] == 'c');
                    if (rt) free(rt);
                    if (isBool) {
                        IMP origH = method_getImplementation(ms[j]);
                        method_setImplementation(ms[j], imp_implementationWithBlock(^BOOL(id self_) {
                            BOOL realHidden = ((BOOL (*)(id, SEL))origH)(self_, s);
                            if (realHidden) ZXRecordHiddenConversationObject(self_);
                            if ([ZXConfig boolForKey:ZXK_UNHIDE_CHATS]) return NO;
                            return realHidden;
                        }));
                    }
                }

                // Story seen: markStoryAsSeen / sendSeenStory / reportStorySeen
                if ([lower containsString:@"markstoryasseen"] ||
                    [lower containsString:@"sendseenstory"] ||
                    [lower containsString:@"reportstoryseen"] ||
                    [lower containsString:@"sendstoryseen"]) {
                    char *rt = method_copyReturnType(ms[j]);
                    BOOL isVoid = rt && rt[0] == 'v';
                    if (rt) free(rt);
                    if (isVoid && argc <= 4) {
                        IMP origS = method_getImplementation(ms[j]);
                        method_setImplementation(ms[j], imp_implementationWithBlock(^(id self_, ZXWord a1, ZXWord a2) {
                            if ([ZXConfig boolForKey:ZXK_GHOST_STORY]) {
                                ZXLog(@"NTHE blocked story seen: -[%@ %@]", NSStringFromClass([self_ class]), sn);
                                return;
                            }
                            ((void (*)(id, SEL, ZXWord, ZXWord))origS)(self_, s, a1, a2);
                        }));
                    }
                }

                // WebRTC Force Relay: filter out host/srflx ICE candidates
                if (argc == 3 && ([lower isEqualToString:@"addicecandidate:"] || [lower isEqualToString:@"didgenerateicecandidate:"])) {
                    char *rt = method_copyReturnType(ms[j]);
                    BOOL isVoid = rt && rt[0] == 'v';
                    if (rt) free(rt);
                    if (isVoid) {
                        IMP origIce = method_getImplementation(ms[j]);
                        method_setImplementation(ms[j], imp_implementationWithBlock(^(id self_, id candidate) {
                            if ([ZXConfig boolForKey:ZXK_CALL_FORCE_RELAY] && candidate) {
                                NSString *sdp = [[candidate description] lowercaseString];
                                @try {
                                    if ([candidate respondsToSelector:@selector(sdp)]) {
                                        sdp = [[[candidate valueForKey:@"sdp"] description] lowercaseString];
                                    }
                                } @catch (__unused NSException *e) {}
                                if ([sdp containsString:@"typ host"] || [sdp containsString:@"typ srflx"]) {
                                    ZXLog(@"NTHE Call Force Relay blocked non-relay ICE candidate");
                                    return;
                                }
                            }
                            ((void (*)(id, SEL, id))origIce)(self_, s, candidate);
                        }));
                    }
                }
            }
            free(ms);
        }
        free(classes);
    });
}

@implementation ZXHookEngine

+ (NSString *)rulesPath
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"rules.json"];
}

#define ZX_RULES_VERSION_MARK @"// zx-rules-version: 11"

+ (NSString *)defaultRulesJSON
{
    return
    @"[\n"
    @"  {\n"
    @"    \"id\": \"firebase_analytics_log\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"FIRAnalytics\",\n"
    @"    \"selector\": \"logEventWithName:parameters:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"logging_disable_firebase\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"anti_recall_socket\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatUIManager\",\n"
    @"    \"selector\": \"processUndoWithSocketChatEntity:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"enable_anti_recall\",\n"
    @"    \"mark\": true\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"anti_recall_operation\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatOperationProcessor\",\n"
    @"    \"selector\": \"_processUndoMessageWithOperationItem:\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"enable_anti_recall\",\n"
    @"    \"mark\": true\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"block_seen_send_server\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatSendSeenDataManager\",\n"
    @"    \"selector\": \"sendSeenServer\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"block_send_seen\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"block_seen_force_send\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatSendSeenDataManager\",\n"
    @"    \"selector\": \"forceSendSeenServer\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"block_send_seen\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"block_seen_send_message\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatSendSeenDataManager\",\n"
    @"    \"selector\": \"_sendSeenMessageWithSeenData:messageType:\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"block_send_seen\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"block_seen_last_message\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatSendSeenDataManager\",\n"
    @"    \"selector\": \"sendSeenLastMessageWithThreadIds:withMessageType:\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"block_send_seen\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"silent_typing\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatSocketCmdHelper\",\n"
    @"    \"selector\": \"sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"skip\",\n"
    @"    \"returnValue\": 0,\n"
    @"    \"configKey\": \"enable_silent_typing\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"block_seen_check\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatDataManager\",\n"
    @"    \"selector\": \"checkCanSendSeenInboxEntity:messageType:withToUserId:\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"block_send_seen\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"block_seen_entity\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatSendSeenDataManager\",\n"
    @"    \"selector\": \"sendSeenWithChatEntity:\",\n"
    @"    \"action\": \"skip\",\n"
    @"    \"configKey\": \"block_send_seen\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"typing_feature_flag\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"FeatureManager\",\n"
    @"    \"selector\": \"isEnableTypingMessage\",\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 0,\n"
    @"    \"configKey\": \"enable_silent_typing\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"custom_ttl\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatDataManager\",\n"
    @"    \"selector\": \"attachTTLValueForMessageIfNeed:\",\n"
    @"    \"action\": \"setttl\",\n"
    @"    \"argIndex\": 1,\n"
    @"    \"configKey\": \"enable_msg_ttl_override\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"unlimited_file_size\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ChatDataManager\",\n"
    @"    \"selector\": \"getMaxFileSizeWithPickerQuality:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 10737418240,\n"
    @"    \"configKey\": \"enable_unlimited_media\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"picker_open_original\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"UXMediaPickerUnities\",\n"
    @"    \"selector\": \"showQualityPickerWithCurrentQuality:entryPoint:animatingPromote:changeBlock:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"setarg\",\n"
    @"    \"argIndex\": 1,\n"
    @"    \"returnValue\": 2,\n"
    @"    \"configKey\": \"default_original_quality\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"can_upload_original\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ZCFPickerConfig\",\n"
    @"    \"selector\": \"canUploadOriginalQuality\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 1,\n"
    @"    \"configKey\": \"default_original_quality\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"enable_send_original\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"CommFeatureBase.ZCFQualityPickerConfig\",\n"
    @"    \"selector\": \"enableSendOriginal\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 1,\n"
    @"    \"configKey\": \"default_original_quality\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"zcloud_file_limit\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ZCloudFoundation.ZCloudFileSetting\",\n"
    @"    \"selector\": \"zCloudFileLimitInBytes\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 100000000000,\n"
    @"    \"configKey\": \"enable_unlimited_media\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"file_error_bypass\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"FilePickerObject\",\n"
    @"    \"selector\": \"sendFileErrorWithFileObject:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 0,\n"
    @"    \"configKey\": \"enable_unlimited_media\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"video_bypass_transcode\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ZAVideoExportHelper\",\n"
    @"    \"selector\": \"shouldByPassVideoSize:withDimensionMax:\",\n"
    @"    \"classMethod\": true,\n"
    @"    \"action\": \"return_size\",\n"
    @"    \"returnValue\": 1,\n"
    @"    \"configKey\": \"video_original\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"video_max_upload\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"UXSessionContext\",\n"
    @"    \"selector\": \"maxUploadVideoSize\",\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 10737418240,\n"
    @"    \"configKey\": \"enable_unlimited_media\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"video_original_config\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"ZAVideoExportManager\",\n"
    @"    \"selector\": \"_reconfigBitrateForConfiguration:assetInfo:videoID:source:\",\n"
    @"    \"action\": \"videocfg\",\n"
    @"    \"argIndex\": 1,\n"
    @"    \"configKey\": \"video_original\"\n"
    @"  },\n"
    @"  {\n"
    @"    \"id\": \"webrtc_force_relay_policy\",\n"
    @"    \"enabled\": true,\n"
    @"    \"class\": \"RTCConfiguration\",\n"
    @"    \"selector\": \"iceTransportPolicy\",\n"
    @"    \"action\": \"return\",\n"
    @"    \"returnValue\": 1,\n"
    @"    \"configKey\": \"nthe_call_force_relay\"\n"
    @"  }\n"
    @"]\n"
    @"// zx-rules-version: 11\n";
}

+ (void)ensureRulesFile
{
    NSString *path = [self rulesPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) {
        NSString *cur = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if ([cur containsString:ZX_RULES_VERSION_MARK]) return;
        NSString *bak = [path stringByAppendingString:@".bak"];
        [fm removeItemAtPath:bak error:nil];
        [fm moveItemAtPath:path toPath:bak error:nil];
        ZXLog(@"rules.json cũ đã được sao lưu thành rules.json.bak và thay bằng bản mới");
    }
    [[self defaultRulesJSON] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (NSArray *)loadRules
{
    [self ensureRulesFile];
    NSString *path = [self rulesPath];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return @[];
    NSMutableArray *lines = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"//"]) continue;
        [lines addObject:line];
    }
    NSData *data = [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSArray class]]) {
        ZXLog(@"rules.json invalid: %@", err.localizedDescription ?: @"root must be an array");
        return @[];
    }
    return json;
}

+ (void)installFromRules
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInstalled = [NSMutableSet new];
        gPending = [NSMutableArray new];
    });
    ZXInstallExtendedFeatureHooks();
    for (id r in [self loadRules]) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        if ([r[@"enabled"] respondsToSelector:@selector(boolValue)] && ![r[@"enabled"] boolValue]) continue;
        if (![self installRule:r]) [gPending addObject:r];
    }
    ZXLog(@"rules installed: %lu, pending: %lu", (unsigned long)gInstalled.count, (unsigned long)gPending.count);
}

+ (void)retryPending
{
    ZXInstallExtendedFeatureHooks();
    if (gPending.count == 0) return;
    NSArray *todo = [gPending copy];
    [gPending removeAllObjects];
    for (NSDictionary *r in todo)
        if (![self installRule:r]) [gPending addObject:r];
}

static BOOL ZXWordArgType(char c)
{
    return c != 0 && strchr("cCsSiIlLqQB@#^*:", c) != NULL;
}

+ (BOOL)installRule:(NSDictionary *)rule
{
    NSString *className = rule[@"class"], *selName = rule[@"selector"];
    NSString *action = rule[@"action"] ?: @"skip";
    if (![className isKindOfClass:[NSString class]] || ![selName isKindOfClass:[NSString class]]) {
        ZXLog(@"rule %@: missing class/selector", rule[@"id"]);
        return YES;
    }
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    BOOL isClassMethod = [rule[@"classMethod"] boolValue];
    Class target = isClassMethod ? object_getClass(cls) : cls;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(target, sel);
    if (!m) {
        ZXLog(@"rule %@: %c[%@ %@] not found", rule[@"id"], isClassMethod ? '+' : '-', className, selName);
        return YES;
    }
    NSString *key = [NSString stringWithFormat:@"%c%@ %@", isClassMethod ? '+' : '-', className, selName];
    if ([gInstalled containsObject:key]) return YES;

    if ([action isEqualToString:@"return_size"]) {
        char *a0 = method_copyArgumentType(m, 2);
        BOOL okSig = method_getNumberOfArguments(m) == 4 && a0 && strncmp(a0, "{CGSize", 7) == 0;
        if (a0) free(a0);
        char *a1 = okSig ? method_copyArgumentType(m, 3) : NULL;
        okSig = okSig && a1 && ZXWordArgType(a1[0]);
        if (a1) free(a1);
        char *rt2 = method_copyReturnType(m);
        okSig = okSig && rt2 && ZXWordArgType(rt2[0]);
        if (rt2) free(rt2);
        if (!okSig) { ZXLog(@"rule %@: return_size needs (CGSize, integer) -> integer", rule[@"id"]); return YES; }
        NSString *scfg = [rule[@"configKey"] isKindOfClass:[NSString class]] ? rule[@"configKey"] : nil;
        ZXWord sval = (ZXWord)[rule[@"returnValue"] longLongValue];
        IMP sorig = method_getImplementation(m);
        const char *stypes = method_getTypeEncoding(m);
        id sblock = ^ZXWord(id self_, CGSize size, ZXWord a2) {
            if (!scfg || [ZXConfig boolForKey:scfg]) return sval;
            return ((ZXWord (*)(id, SEL, CGSize, ZXWord))sorig)(self_, sel, size, a2);
        };
        IMP simp = imp_implementationWithBlock(sblock);
        if (!class_addMethod(target, sel, simp, stypes)) method_setImplementation(m, simp);
        [gInstalled addObject:key];
        ZXLog(@"hooked %@ (%@) action=return_size", key, rule[@"id"] ?: key);
        return YES;
    }

    unsigned argc = method_getNumberOfArguments(m);
    if (argc < 2 || argc - 2 > 6) { ZXLog(@"rule %@: too many args", rule[@"id"]); return YES; }
    for (unsigned i = 2; i < argc; i++) {
        char *t = method_copyArgumentType(m, i);
        BOOL ok = t && ZXWordArgType(t[0] == 'r' || t[0] == 'n' || t[0] == 'N' || t[0] == 'o' || t[0] == 'O' || t[0] == 'R' || t[0] == 'V' ? t[1] : t[0]);
        if (t) free(t);
        if (!ok) { ZXLog(@"rule %@: unsupported arg type at %u", rule[@"id"], i - 2); return YES; }
    }
    char *rt = method_copyReturnType(m);
    char rc = rt ? rt[0] : '?';
    if (rt) free(rt);
    BOOL isVoid = (rc == 'v');
    if (rc == 'f' || rc == 'd') {
        if (argc != 2 || ![action isEqualToString:@"return"]) { ZXLog(@"rule %@: float method needs action return and no args", rule[@"id"]); return YES; }
        NSString *fkey = [NSString stringWithFormat:@"%c%@ %@", isClassMethod ? '+' : '-', className, selName];
        if ([gInstalled containsObject:fkey]) return YES;
        NSString *fcfg = [rule[@"configKey"] isKindOfClass:[NSString class]] ? rule[@"configKey"] : nil;
        double fv = [rule[@"returnValue"] doubleValue];
        IMP forig = method_getImplementation(m);
        const char *ftypes = method_getTypeEncoding(m);
        id fblock;
        if (rc == 'f') {
            fblock = ^float(id self_) {
                if (!fcfg || [ZXConfig boolForKey:fcfg]) return (float)fv;
                return ((float (*)(id, SEL))forig)(self_, sel);
            };
        } else {
            fblock = ^double(id self_) {
                if (!fcfg || [ZXConfig boolForKey:fcfg]) return fv;
                return ((double (*)(id, SEL))forig)(self_, sel);
            };
        }
        IMP fimp = imp_implementationWithBlock(fblock);
        if (!class_addMethod(target, sel, fimp, ftypes)) method_setImplementation(m, fimp);
        [gInstalled addObject:fkey];
        ZXLog(@"hooked %@ (%@) action=return(float %g)", fkey, rule[@"id"] ?: fkey, fv);
        return YES;
    }
    if (!isVoid && !ZXWordArgType(rc)) { ZXLog(@"rule %@: unsupported return type %c", rule[@"id"], rc); return YES; }

    NSInteger argIndex = [rule[@"argIndex"] integerValue];
    BOOL antiRecall = [action isEqualToString:@"antirecall"];
    if (antiRecall) {
        if (argIndex < 1 || argIndex > (NSInteger)argc - 2) { ZXLog(@"rule %@: bad argIndex", rule[@"id"]); return YES; }
        char *t = method_copyArgumentType(m, (unsigned)argIndex + 1);
        BOOL isObj = t && (t[0] == '@');
        if (t) free(t);
        if (!isObj) { ZXLog(@"rule %@: argIndex is not an object", rule[@"id"]); return YES; }
    }
    BOOL isSetArg = [action isEqualToString:@"setarg"];
    if (isSetArg && (argIndex < 1 || argIndex > (NSInteger)argc - 2)) { ZXLog(@"rule %@: bad argIndex", rule[@"id"]); return YES; }
    BOOL isSetTTL = [action isEqualToString:@"setttl"];
    if (isSetTTL) {
        if (argIndex < 1 || argIndex > (NSInteger)argc - 2) { ZXLog(@"rule %@: bad argIndex", rule[@"id"]); return YES; }
        char *t = method_copyArgumentType(m, (unsigned)argIndex + 1);
        BOOL isObj = t && (t[0] == '@');
        if (t) free(t);
        if (!isObj) { ZXLog(@"rule %@: argIndex is not an object", rule[@"id"]); return YES; }
    }
    BOOL isVideoCfg = [action isEqualToString:@"videocfg"];
    if (isVideoCfg && (!isVoid || argc < 4)) { ZXLog(@"rule %@: videocfg needs a void method with (config, assetInfo, ...)", rule[@"id"]); return YES; }
    BOOL isTTL = [action isEqualToString:@"ttl"];
    if (isTTL && isVoid) { ZXLog(@"rule %@: ttl needs a non-void method", rule[@"id"]); return YES; }

    NSString *configKey = [rule[@"configKey"] isKindOfClass:[NSString class]] ? rule[@"configKey"] : nil;
    ZXWord retVal = (ZXWord)[rule[@"returnValue"] longLongValue];
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    NSString *ruleId = rule[@"id"] ?: key;

    BOOL isLog = [action isEqualToString:@"log"];
    NSMutableArray<NSNumber *> *objKinds = [NSMutableArray new];
    for (unsigned i = 2; i < argc; i++) {
        char *t = method_copyArgumentType(m, i);
        [objKinds addObject:@(t && t[0] == '@' && t[1] != '?')];
        if (t) free(t);
    }
    NSString *traceTag = key;
    BOOL markFlag = [rule[@"mark"] boolValue];

    NSInteger matchArg = [rule[@"matchArg"] integerValue];
    NSString *matchText = [rule[@"matchText"] isKindOfClass:[NSString class]] ? rule[@"matchText"] : nil;

    id block;
    if (isVoid) {
        block = ^(id self_, ZXWord a1, ZXWord a2, ZXWord a3, ZXWord a4, ZXWord a5, ZXWord a6) {
            ZXWord args[6] = {a1, a2, a3, a4, a5, a6};
            if (isLog) {
                ZXTraceCall(traceTag, objKinds, args);
            } else if ((!configKey || [ZXConfig boolForKey:configKey]) && ZXArgMatches(matchArg, matchText, args)) {
                if (markFlag) ZXMarkArgs(objKinds, args);
                if (isVideoCfg) {
                    ((void (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                    ZXApplyVideoOriginal((__bridge id)(void *)args[0], (__bridge id)(void *)args[1]);
                    return;
                }
                if (isSetArg) {
                    args[argIndex - 1] = retVal;
                    ((void (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                    return;
                }
                if (isSetTTL) {
                    id o = (__bridge id)(void *)args[argIndex - 1];
                    @try { [o setValue:@([ZXConfig ttl]) forKey:@"ttl"]; } @catch (__unused id e) {}
                } else if (!antiRecall) return;
                if (isSetTTL) {
                    ((void (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                    return;
                }
                id replaced = [ZXAntiRecall processObject:(__bridge id)(void *)args[argIndex - 1]];
                CFTypeRef held = NULL;
                if (replaced) { held = CFBridgingRetain(replaced); args[argIndex - 1] = (ZXWord)held; }
                ((void (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                if (held) CFRelease(held);
                return;
            }
            ((void (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
        };
    } else {
        block = ^ZXWord(id self_, ZXWord a1, ZXWord a2, ZXWord a3, ZXWord a4, ZXWord a5, ZXWord a6) {
            ZXWord args[6] = {a1, a2, a3, a4, a5, a6};
            if (isLog) {
                ZXTraceCall(traceTag, objKinds, args);
            } else if ((!configKey || [ZXConfig boolForKey:configKey]) && ZXArgMatches(matchArg, matchText, args)) {
                if (markFlag) ZXMarkArgs(objKinds, args);
                if (isTTL) return (ZXWord)[ZXConfig ttl];
                if (isSetArg) {
                    args[argIndex - 1] = retVal;
                    return ((ZXWord (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                }
                if (isSetTTL) {
                    id o = (__bridge id)(void *)args[argIndex - 1];
                    @try { [o setValue:@([ZXConfig ttl]) forKey:@"ttl"]; } @catch (__unused id e) {}
                    return ((ZXWord (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                }
                if (!antiRecall) return retVal;
                id replaced = [ZXAntiRecall processObject:(__bridge id)(void *)args[argIndex - 1]];
                CFTypeRef held = NULL;
                if (replaced) { held = CFBridgingRetain(replaced); args[argIndex - 1] = (ZXWord)held; }
                ZXWord r = ((ZXWord (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
                if (held) CFRelease(held);
                return r;
            }
            return ((ZXWord (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
        };
    }

    IMP newImp = imp_implementationWithBlock(block);
    if (!class_addMethod(target, sel, newImp, types))
        method_setImplementation(m, newImp);

    [gInstalled addObject:key];
    ZXLog(@"hooked %@ (%@) action=%@", key, ruleId, action);
    return YES;
}

// ---- Extended NTHE Public API ---------------------------------------------

+ (NSArray<NSDictionary *> *)discoveredHiddenChats
{
    ZXInitHiddenChatsStore();
    @synchronized (gHiddenChatsMap) {
        return gHiddenChatsMap.allValues ?: @[];
    }
}

+ (BOOL)unhideChatWithID:(NSString *)chatID
{
    if (chatID.length == 0) return NO;
    ZXInitHiddenChatsStore();
    @synchronized (gHiddenChatsMap) {
        [gHiddenChatsMap removeObjectForKey:chatID];
        ZXSaveHiddenChatsStore();
    }
    [ZXConfig setBool:YES forKey:ZXK_UNHIDE_CHATS];
    return YES;
}

+ (BOOL)openChatWithID:(NSString *)chatID
{
    if (chatID.length == 0) return NO;
    NSURL *deepLink = [NSURL URLWithString:[NSString stringWithFormat:@"zalo://conversation?id=%@", chatID]];
    if (deepLink && [[UIApplication sharedApplication] canOpenURL:deepLink]) {
        [[UIApplication sharedApplication] openURL:deepLink options:@{} completionHandler:nil];
        return YES;
    }
    return NO;
}

+ (NSURL *)lastVoiceMessageURL
{
    return gLastVoiceURL;
}

+ (BOOL)isCallRecording
{
    return gCallRecorder != nil && gCallRecorder.isRecording;
}

+ (void)toggleManualCallRecording
{
    if ([self isCallRecording]) {
        ZXStopCallRecordingIfActive();
    } else {
        BOOL prev = [ZXConfig boolForKey:ZXK_AUTO_CALL_RECORD];
        [ZXConfig setBool:YES forKey:ZXK_AUTO_CALL_RECORD];
        ZXStartCallRecordingIfNeeded();
        if (!prev) [ZXConfig setBool:prev forKey:ZXK_AUTO_CALL_RECORD];
    }
}

+ (void)presentRepeaterDialogFromVC:(UIViewController *)vc
{
    UIViewController *host = vc ?: ZXTopPresentedVC();
    if (!host) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Gửi tin nhắn lặp lại"
                                                               message:@"Nhập nội dung, số lần gửi và độ trễ (giây) giữa mỗi lần gửi"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (@available(iOS 13.0, *)) a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UITextView *chatTV = ZXFindChatInputTextView(gActiveChatVC.view ?: ZXActiveWindow());
    NSString *prefill = chatTV.text ?: @"";

    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Nội dung tin nhắn...";
        tf.text = prefill;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Số lần gửi (mặc định: 5)";
        tf.text = @"5";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Độ trễ (giây, mặc định: 0.5)";
        tf.text = @"0.5";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Bắt đầu gửi" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        NSString *msg = a.textFields.count > 0 ? (a.textFields[0].text ?: @"") : @"";
        NSInteger count = a.textFields.count > 1 ? [a.textFields[1].text integerValue] : 5;
        double delay = a.textFields.count > 2 ? [a.textFields[2].text doubleValue] : 0.5;
        if (count <= 0) count = 5;
        if (count > 200) count = 200;
        if (delay < 0.05) delay = 0.5;
        if (msg.length == 0) return;

        UIViewController *targetChat = gActiveChatVC;
        for (NSInteger i = 0; i < count; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ZXSendSingleTextInChat(targetChat, msg);
            });
        }
    }]];
    [host presentViewController:a animated:YES completion:nil];
}

@end
