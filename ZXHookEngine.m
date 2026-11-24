#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <AVFoundation/AVFoundation.h>
#import "ZXHookEngine.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import "ZXAntiRecall.h"
#import "ZXRecallMarker.h"
#import "ZXScanner.h"
#import <objc/runtime.h>

typedef uintptr_t ZXWord;

static NSMutableSet<NSString *> *gInstalled;
static NSMutableArray<NSDictionary *> *gPending;
static NSMutableDictionary<NSString *, NSDictionary *> *gHiddenChatsMap;
static NSMutableDictionary<NSString *, NSDictionary *> *gResolvedProfilesMap;
static BOOL gProfilesSaveScheduled;
static NSMutableSet<NSString *> *sUnhiddenThreadIDs;
static NSMutableSet<NSString *> *gUnlockedSessionChats;
static NSURL *gLastVoiceURL;
static AVAudioRecorder *gCallRecorder;
static AVAudioPlayer *gSilentBgPlayer;
static UIBackgroundTaskIdentifier gBgTask = 0;
static __weak UIViewController *gActiveChatVC;
static __weak UIView *sActiveInputView;
static UIWindow *gSpamOverlayWindow;
static UIButton *gKeyboardSpamButton;
static CGFloat gLastKeyboardTopY;
static BOOL gSQLiteScanInProgress;

// Spam state
static BOOL gSpamRunning;
static BOOL sSpamAntiDuplicate = YES;
static double gActiveSpamDelay = 0.5;
static NSInteger gSpamGeneration;
static NSInteger gSpamSentCount;
static NSInteger gSpamTotalCount;
static NSString *gLastSpamText;

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
    @try {
        NSMutableString *out = [NSMutableString stringWithFormat:@"TRACE %@", tag];
        for (NSUInteger i = 0; i < objKinds.count; i++)
            [out appendFormat:@"\n    arg%lu = %@", (unsigned long)(i + 1), ZXDescribeWord(args[i], [objKinds[i] boolValue])];
        ZXLogImpl(out);
    } @catch (__unused NSException *e) {}
}

static void ZXMarkArgs(NSArray<NSNumber *> *objKinds, const ZXWord *args)
{
    @try {
        NSMutableArray *objs = [NSMutableArray new];
        for (NSUInteger i = 0; i < objKinds.count; i++)
            if ([objKinds[i] boolValue] && args[i]) [objs addObject:(__bridge id)(void *)args[i]];
        [ZXRecallMarker markObjects:objs];
    } @catch (__unused NSException *e) {}
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

// ---- Feature 1: Hidden Chats Store (No automatic SQLite scan at launch!) ---

static NSString *ZXHiddenChatsStorePath(void)
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"hidden_chats.json"];
}

static void ZXInitHiddenChatsStore(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gBgTask = UIBackgroundTaskInvalid;
        gHiddenChatsMap = [NSMutableDictionary new];
        gResolvedProfilesMap = [NSMutableDictionary new];
        gUnlockedSessionChats = [NSMutableSet new];
        NSArray *savedUnhidden = [[NSUserDefaults standardUserDefaults] arrayForKey:@"nthe_unhidden_thread_ids"];
        sUnhiddenThreadIDs = [NSMutableSet setWithArray:(savedUnhidden ?: @[])];
        @try {
            NSData *pData = [NSData dataWithContentsOfFile:[ZXScanner resolvedProfilesPath]];
            if (pData) {
                id pDict = [NSJSONSerialization JSONObjectWithData:pData options:0 error:nil];
                if ([pDict isKindOfClass:[NSDictionary class]]) {
                    [gResolvedProfilesMap addEntriesFromDictionary:(NSDictionary *)pDict];
                }
            }
        } @catch (__unused NSException *e) {}
        @try {
            NSData *d = [NSData dataWithContentsOfFile:ZXHiddenChatsStorePath()];
            if (d) {
                id arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([arr isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *item in arr) {
                        NSString *uid = [item[@"uid"] description];
                        NSString *name = [item[@"name"] description];
                        if (uid.length == 0 || [ZXScanner isGarbageChatIdentifier:uid] || [ZXScanner isGarbageChatIdentifier:name]) {
                            continue;
                        }
                        if ([sUnhiddenThreadIDs containsObject:uid]) continue;
                        gHiddenChatsMap[uid] = item;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    });
}

static void ZXScheduleSaveResolvedProfiles(void)
{
    if (gProfilesSaveScheduled) return;
    gProfilesSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSDictionary *snap = nil;
            @synchronized (gResolvedProfilesMap) {
                gProfilesSaveScheduled = NO;
                snap = [gResolvedProfilesMap copy];
            }
            if (snap.count > 0) {
                NSData *d = [NSJSONSerialization dataWithJSONObject:snap options:0 error:nil];
                if (d) [d writeToFile:[ZXScanner resolvedProfilesPath] atomically:YES];
            }
        } @catch (__unused NSException *e) {
            gProfilesSaveScheduled = NO;
        }
    });
}

static void ZXSaveHiddenChatsStore(void)
{
    @try {
        ZXInitHiddenChatsStore();
        NSArray *all = gHiddenChatsMap.allValues ?: @[];
        NSData *d = [NSJSONSerialization dataWithJSONObject:all options:0 error:nil];
        if (d) [d writeToFile:ZXHiddenChatsStorePath() atomically:YES];
    } @catch (__unused NSException *e) {}
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

/// Safely indexes a decrypted Zalo model object in RAM into zx_resolved_profiles.json.
static void ZXIndexDecryptedModelObject(id obj)
{
    if (!obj || [obj isKindOfClass:[UIView class]] || [obj isKindOfClass:[UIViewController class]]) return;
    @try {
        NSString *cn = NSStringFromClass([obj class]);
        if ([cn hasPrefix:@"UI"] || [cn hasPrefix:@"NS"] || [cn hasPrefix:@"_"] || [cn hasPrefix:@"ZX"]) return;

        NSString *uid = ZXReadStringKVC(obj, @[@"userId", @"uid", @"threadId", @"conversationId", @"contactId", @"friendId", @"groupId", @"chatId", @"targetId", @"zaloId"]);
        if (uid.length < 4 || [ZXScanner isGarbageChatIdentifier:uid]) return;

        NSString *name = ZXReadStringKVC(obj, @[@"displayName", @"dName", @"name", @"threadName", @"title", @"contactName", @"userName", @"zaloName", @"fullName", @"aliasName"]);
        if (![ZXScanner isValidHumanDisplayName:name excludeUID:uid]) name = @"";

        NSString *lastMsg = ZXReadStringKVC(obj, @[@"lastMessage", @"lastMsgText", @"snippet", @"content", @"lastMessageContent", @"message", @"text", @"subtitle", @"desc"]);
        if ([ZXScanner isGarbageChatIdentifier:lastMsg]) lastMsg = @"";

        BOOL isHidden = NO;
        for (NSString *hk in @[@"isHidden", @"isHiddenChat", @"isHiddenConversation", @"hiddenType", @"hideStatus", @"isHide"]) {
            if ([obj respondsToSelector:NSSelectorFromString(hk)]) {
                id hv = [obj valueForKey:hk];
                if ([hv respondsToSelector:@selector(integerValue)] && [hv integerValue] > 0) {
                    isHidden = YES;
                    if ([ZXConfig boolForKey:ZXK_UNHIDE_CHATS]) {
                        @try { [obj setValue:@0 forKey:hk]; } @catch (__unused NSException *e) {}
                    }
                    break;
                }
            }
        }

        if (name.length == 0 && lastMsg.length == 0 && !isHidden) return;

        ZXInitHiddenChatsStore();
        @synchronized (gResolvedProfilesMap) {
            NSDictionary *old = gResolvedProfilesMap[uid];
            NSString *mergedName = name.length > 0 ? name : (old[@"name"] ?: @"");
            NSString *mergedMsg = lastMsg.length > 0 ? lastMsg : (old[@"lastMessage"] ?: @"");
            BOOL mergedHidden = isHidden || [old[@"isHidden"] boolValue];
            if ([sUnhiddenThreadIDs containsObject:uid]) mergedHidden = NO;

            gResolvedProfilesMap[uid] = @{
                @"uid": uid,
                @"name": mergedName,
                @"lastMessage": mergedMsg,
                @"isHidden": @(mergedHidden),
                @"timestamp": @((long long)[[NSDate date] timeIntervalSince1970])
            };
        }
        ZXScheduleSaveResolvedProfiles();
    } @catch (__unused NSException *e) {}
}

static void ZXIndexCellAndSubviews(UIView *cell)
{
    if (!cell) return;
    @try {
        for (NSString *prop in @[@"chatEntity", @"item", @"chatItem", @"entity", @"model", @"contact", @"user", @"thread", @"conversation", @"viewModel", @"data", @"chatObject"]) {
            if ([cell respondsToSelector:NSSelectorFromString(prop)]) {
                id model = [cell valueForKey:prop];
                if (model) ZXIndexDecryptedModelObject(model);
            }
        }
    } @catch (__unused NSException *e) {}
}

// ---- Feature 3: Anti-Sleep Background Keep-Alive (Silent 8000Hz Audio + BgTask) ----

static NSData *ZXSilentWAVData(void)
{
    static NSData *wavData;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t sampleRate = 8000;
        uint32_t numSamples = sampleRate; // 1 second mono 16-bit PCM silence
        uint32_t dataSize = numSamples * 2;
        uint32_t totalSize = 36 + dataSize;
        NSMutableData *d = [NSMutableData dataWithLength:(44 + dataSize)];
        uint8_t *p = (uint8_t *)d.mutableBytes;
        memcpy(p, "RIFF", 4);
        memcpy(p + 4, &totalSize, 4);
        memcpy(p + 8, "WAVEfmt ", 8);
        uint32_t fmtSize = 16;
        uint16_t audioFormat = 1;
        uint16_t numChannels = 1;
        uint32_t byteRate = sampleRate * 2;
        uint16_t blockAlign = 2;
        uint16_t bitsPerSample = 16;
        memcpy(p + 16, &fmtSize, 4);
        memcpy(p + 20, &audioFormat, 2);
        memcpy(p + 22, &numChannels, 2);
        memcpy(p + 24, &sampleRate, 4);
        memcpy(p + 28, &byteRate, 4);
        memcpy(p + 32, &blockAlign, 2);
        memcpy(p + 34, &bitsPerSample, 2);
        memcpy(p + 36, "data", 4);
        memcpy(p + 40, &dataSize, 4);
        wavData = d;
    });
    return wavData;
}

static void ZXStopBackgroundKeepAlive(void)
{
    @try {
        if (gSilentBgPlayer) {
            [gSilentBgPlayer stop];
            gSilentBgPlayer = nil;
        }
        if (gBgTask != 0 && gBgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:gBgTask];
            gBgTask = UIBackgroundTaskInvalid;
        }
    } @catch (__unused NSException *e) {}
}

static void ZXStartBackgroundKeepAlive(void)
{
    @try {
        if (![ZXConfig boolForKey:ZXK_KEEP_ALIVE_BG]) {
            ZXStopBackgroundKeepAlive();
            return;
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gBgTask == 0 || gBgTask == UIBackgroundTaskInvalid) {
            gBgTask = [app beginBackgroundTaskWithName:@"thanhthe_keep_alive" expirationHandler:^{
                @try {
                    if (gBgTask != 0 && gBgTask != UIBackgroundTaskInvalid) {
                        [app endBackgroundTask:gBgTask];
                        gBgTask = UIBackgroundTaskInvalid;
                    }
                    if ([ZXConfig boolForKey:ZXK_KEEP_ALIVE_BG]) {
                        ZXStartBackgroundKeepAlive();
                    }
                } @catch (__unused NSException *e) {}
            }];
        }
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:nil];
        [session setActive:YES error:nil];

        if (!gSilentBgPlayer) {
            gSilentBgPlayer = [[AVAudioPlayer alloc] initWithData:ZXSilentWAVData() error:nil];
            gSilentBgPlayer.numberOfLoops = -1;
            gSilentBgPlayer.volume = 0.0f;
            [gSilentBgPlayer prepareToPlay];
        }
        if (!gSilentBgPlayer.isPlaying) {
            [gSilentBgPlayer play];
        }
        ZXLog(@"thanhthe Anti-Sleep background keep-alive active");
    } @catch (NSException *e) {
        ZXLog(@"ZXStartBackgroundKeepAlive exception: %@", e.reason);
    }
}

// ---- Feature 5b: Automatic Call Recorder (.m4a) ---------------------------

static void ZXStartCallRecordingIfNeeded(void)
{
    @try {
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
                ZXLog(@"thanhthe call recording started: %@", fileName);
            }
        } else {
            ZXLog(@"thanhthe call recording error: %@", err.localizedDescription);
        }
    } @catch (NSException *e) {
        ZXLog(@"startCallRecording exception: %@", e.reason);
    }
}

static void ZXStopCallRecordingIfActive(void)
{
    @try {
        if (gCallRecorder && gCallRecorder.isRecording) {
            [gCallRecorder stop];
            ZXLog(@"thanhthe call recording saved: %@", gCallRecorder.url.lastPathComponent);
        }
        gCallRecorder = nil;
    } @catch (NSException *e) {
        ZXLog(@"stopCallRecording exception: %@", e.reason);
    }
}

// ---- Window, Active Input & Precision Send Discovery ----------------------

static UIWindowScene *ZXCurrentWindowScene(void)
{
    if (@available(iOS 13.0, *)) {
        @try {
            UIWindowScene *fallback = nil;
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
                if (!fallback) fallback = (UIWindowScene *)s;
            }
            return fallback;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static UIWindow *ZXActiveWindow(void)
{
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                if (s.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows)
                    if (w.isKeyWindow && w != gSpamOverlayWindow) return w;
            }
        }
        UIWindow *w = UIApplication.sharedApplication.keyWindow;
        if (w && w != gSpamOverlayWindow) return w;
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win != gSpamOverlayWindow && !win.hidden) return win;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static UIViewController *ZXTopPresentedVC(void)
{
    @try {
        UIViewController *v = ZXActiveWindow().rootViewController;
        while (v.presentedViewController) v = v.presentedViewController;
        return v;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static UIViewController *ZXNearestViewControllerForView(UIView *view)
{
    if (!view) return nil;
    @try {
        UIResponder *r = view.nextResponder;
        while (r) {
            if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
            r = r.nextResponder;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static BOOL ZXIsModScreenVisible(void)
{
    @try {
        UIViewController *top = ZXTopPresentedVC();
        if (!top) return NO;
        NSString *topCls = NSStringFromClass([top class]);
        if ([topCls hasPrefix:@"ZX"]) return YES;
        if ([top isKindOfClass:[UINavigationController class]]) {
            UIViewController *vis = ((UINavigationController *)top).visibleViewController;
            if (vis && [NSStringFromClass([vis class]) hasPrefix:@"ZX"]) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static UIView *ZXFindChatInputView(UIView *root)
{
    if (!root || root.hidden || root.alpha < 0.05) return nil;
    @try {
        if ([root isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)root;
            if (tv.isEditable && tv.bounds.size.height >= 18 && tv.bounds.size.height <= 200) {
                sActiveInputView = tv;
                return tv;
            }
        } else if ([root isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)root;
            if (tf.isEnabled && tf.bounds.size.height >= 18 && tf.bounds.size.height <= 100) {
                sActiveInputView = tf;
                return tf;
            }
        }
        for (UIView *sub in root.subviews) {
            UIView *found = ZXFindChatInputView(sub);
            if (found) return found;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static void ZXCollectSendCandidates(UIView *root, UIWindow *win, CGRect inputRectInWin, NSMutableArray<UIView *> *outViews)
{
    if (!root || !win || root.hidden || root.alpha < 0.05 || root == sActiveInputView) return;
    @try {
        if ([root isKindOfClass:[UIControl class]] || root.gestureRecognizers.count > 0) {
            CGRect r = [root convertRect:root.bounds toView:win];
            CGFloat inputRight = CGRectGetMaxX(inputRectInWin);
            CGFloat inputMidY = CGRectGetMidY(inputRectInWin);
            CGFloat candMidX = CGRectGetMidX(r);
            CGFloat candMidY = CGRectGetMidY(r);
            BOOL rightOfInput = (candMidX >= inputRight - 44.0) && (candMidX <= inputRight + 135.0);
            BOOL sameRow = fabs(candMidY - inputMidY) <= 56.0;
            BOOL reasonableSize = (r.size.width >= 20.0 && r.size.width <= 100.0 && r.size.height >= 20.0 && r.size.height <= 80.0);
            if (rightOfInput && sameRow && reasonableSize) {
                [outViews addObject:root];
            }
        }
        for (UIView *sub in root.subviews) {
            ZXCollectSendCandidates(sub, win, inputRectInWin, outViews);
        }
    } @catch (__unused NSException *e) {}
}

static void ZXFireTouchAndGesturesOnView(UIView *v)
{
    if (!v) return;
    @try {
        if ([v isKindOfClass:[UIControl class]]) {
            UIControl *ctrl = (UIControl *)v;
            [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]] && gr.isEnabled) {
                Ivar targetsIvar = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
                if (targetsIvar) {
                    NSArray *targets = object_getIvar(gr, targetsIvar);
                    for (id pair in targets) {
                        id target = nil;
                        @try { target = [pair valueForKey:@"_target"] ?: [pair valueForKey:@"target"]; } @catch (__unused NSException *e) {}
                        if (!target) continue;
                        for (NSString *selStr in @[@"handleTap:", @"onTap:", @"sendButtonTapped:", @"didTapSendButton:", @"onSendButtonClicked:"]) {
                            SEL s = NSSelectorFromString(selStr);
                            if ([target respondsToSelector:s]) {
                                ((void (*)(id, SEL, id))[target methodForSelector:s])(target, s, gr);
                                break;
                            }
                        }
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ZXSendSingleTextInChat(UIViewController *chatVC, NSString *text)
{
    if (text.length == 0) return;
    @try {
        UIView *inputView = sActiveInputView;
        if (!inputView || !inputView.window) {
            inputView = ZXFindChatInputView(chatVC.view ?: ZXActiveWindow());
        }
        UIViewController *ownerVC = ZXNearestViewControllerForView(inputView) ?: chatVC;
        if (ownerVC && ![NSStringFromClass([ownerVC class]) hasPrefix:@"ZX"]) {
            gActiveChatVC = ownerVC;
        }

        if (inputView && inputView.window) {
            UIWindow *win = inputView.window;
            if ([inputView isKindOfClass:[UITextView class]]) {
                UITextView *tv = (UITextView *)inputView;
                tv.text = @"";
                [tv insertText:text];
                if (tv.text.length == 0) tv.text = text;
                if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                    [tv.delegate textViewDidChange:tv];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
            } else if ([inputView isKindOfClass:[UITextField class]]) {
                UITextField *tf = (UITextField *)inputView;
                tf.text = @"";
                [tf insertText:text];
                if (tf.text.length == 0) tf.text = text;
                [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
            }

            CGRect inputRect = [inputView convertRect:inputView.bounds toView:win];
            UIView *searchRoot = inputView.superview.superview.superview ?: inputView.superview.superview ?: win;
            NSMutableArray<UIView *> *cands = [NSMutableArray new];
            ZXCollectSendCandidates(searchRoot, win, inputRect, cands);

            [cands sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
                CGRect ra = [a convertRect:a.bounds toView:win];
                CGRect rb = [b convertRect:b.bounds toView:win];
                if (ra.origin.x > rb.origin.x) return NSOrderedAscending;
                if (ra.origin.x < rb.origin.x) return NSOrderedDescending;
                return NSOrderedSame;
            }];

            for (UIView *cand in cands) {
                ZXFireTouchAndGesturesOnView(cand);
                NSString *remaining = [inputView respondsToSelector:@selector(text)] ? [(id)inputView text] : @"";
                if (remaining.length == 0) return;
            }

            if ([inputView isKindOfClass:[UITextView class]]) {
                UITextView *tv = (UITextView *)inputView;
                if ([tv.delegate respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]) {
                    [tv.delegate textView:tv shouldChangeTextInRange:NSMakeRange(tv.text.length, 0) replacementText:@"\n"];
                    if (tv.text.length == 0) return;
                }
            }
        }

        NSArray<NSString *> *sendSelectors = @[
            @"sendTextMessage:", @"sendMessageWithText:", @"sendText:",
            @"onSendText:", @"didSendText:", @"sendCurrentText"
        ];
        NSMutableArray *targets = [NSMutableArray new];
        if (ownerVC) [targets addObject:ownerVC];
        for (NSString *k in @[@"chatInputBar", @"inputBar", @"inputToolBar", @"viewModel", @"presenter", @"chatController"]) {
            @try {
                if (ownerVC && [ownerVC respondsToSelector:NSSelectorFromString(k)]) {
                    id sub = [ownerVC valueForKey:k];
                    if (sub) [targets addObject:sub];
                }
            } @catch (__unused NSException *e) {}
        }
        for (id t in targets) {
            for (NSString *selName in sendSelectors) {
                SEL s = NSSelectorFromString(selName);
                if ([t respondsToSelector:s]) {
                    @try {
                        if ([selName hasSuffix:@":"]) {
                            ((void (*)(id, SEL, id))[t methodForSelector:s])(t, s, text);
                        } else {
                            ((void (*)(id, SEL))[t methodForSelector:s])(t, s);
                        }
                        return;
                    } @catch (__unused NSException *e) {}
                }
            }
        }
    } @catch (NSException *e) {
        ZXLog(@"ZXSendSingleTextInChat exception: %@", e.reason);
    }
}

// ---- One-Touch Dark Spam Popup Controller ---------------------------------

@interface ZXSpamPopupViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) UITextField *countField;
@property (nonatomic, strong) UITextField *delayField;
@property (nonatomic, strong) NSArray<UIButton *> *countButtons;
@property (nonatomic, strong) NSArray<UIButton *> *speedButtons;
@property (nonatomic, strong) UISwitch *antiDupSwitch;
@property (nonatomic, strong) UIButton *startStopButton;
@property (nonatomic, assign) NSInteger selectedCount;
@property (nonatomic, assign) double selectedDelay;
@property (nonatomic, strong) NSTimer *statusTimer;
@end

@implementation ZXSpamPopupViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    self.selectedCount = 5;
    self.selectedDelay = [ZXConfig spamDelaySeconds];

    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBackdropTap:)];
    bgTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:bgTap];

    CGFloat sw = self.view.bounds.size.width;
    CGFloat sh = self.view.bounds.size.height;
    CGFloat cw = MIN(sw - 32.0, 384.0);
    CGFloat ch = 392.0;

    self.cardView = [[UIView alloc] initWithFrame:CGRectMake((sw - cw) / 2.0, (sh - ch) / 2.0 - 20.0, cw, ch)];
    self.cardView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.cardView.backgroundColor = [UIColor colorWithRed:0.094 green:0.106 blue:0.125 alpha:1.0];
    self.cardView.layer.cornerRadius = 18.0;
    self.cardView.layer.borderWidth = 1.2;
    self.cardView.layer.borderColor = [UIColor colorWithRed:0.165 green:0.184 blue:0.227 alpha:1.0].CGColor;
    [self.view addSubview:self.cardView];

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(18, 16, cw - 68, 24)];
    titleLbl.text = @"Gửi tin nhắn lặp lại (Spam)";
    titleLbl.textColor = UIColor.whiteColor;
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [self.cardView addSubview:titleLbl];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(cw - 46, 12, 32, 32);
    closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    closeBtn.layer.cornerRadius = 16;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [closeBtn addTarget:self action:@selector(closePopup) forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:closeBtn];

    UIView *activeIn = sActiveInputView ?: ZXFindChatInputView(gActiveChatVC.view ?: ZXActiveWindow());
    NSString *curText = [activeIn respondsToSelector:@selector(text)] ? [(id)activeIn text] : @"";
    NSString *prefill = (curText.length > 0) ? curText : (gLastSpamText ?: @"");

    self.messageField = [[UITextField alloc] initWithFrame:CGRectMake(16, 52, cw - 32, 42)];
    self.messageField.backgroundColor = [UIColor colorWithRed:0.051 green:0.059 blue:0.071 alpha:1.0];
    self.messageField.layer.cornerRadius = 10;
    self.messageField.layer.borderWidth = 1.0;
    self.messageField.layer.borderColor = [UIColor colorWithRed:0.165 green:0.184 blue:0.227 alpha:1.0].CGColor;
    self.messageField.textColor = UIColor.whiteColor;
    self.messageField.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
    self.messageField.text = prefill;
    self.messageField.delegate = self;
    self.messageField.returnKeyType = UIReturnKeyDone;
    self.messageField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 42)];
    self.messageField.leftViewMode = UITextFieldViewModeAlways;
    self.messageField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.messageField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Nhập nội dung tin nhắn cần gửi..."
        attributes:@{ NSForegroundColorAttributeName: [UIColor colorWithRed:0.612 green:0.639 blue:0.686 alpha:1.0] }];
    [self.cardView addSubview:self.messageField];

    UILabel *cntLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 104, cw - 32, 18)];
    cntLbl.text = @"SỐ LẦN GỬI (CHỌN NHANH HOẶC NHẬP TÙY Ý)";
    cntLbl.textColor = [UIColor colorWithRed:0.612 green:0.639 blue:0.686 alpha:1.0];
    cntLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    [self.cardView addSubview:cntLbl];

    NSArray<NSNumber *> *presets = @[@5, @10, @20, @50];
    NSMutableArray<UIButton *> *cBtns = [NSMutableArray new];
    CGFloat gap = 6.0;
    CGFloat pillW = floor((cw - 32.0 - gap * 4.0) / 5.0);
    for (NSUInteger i = 0; i < presets.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(16 + i * (pillW + gap), 126, pillW, 36);
        b.tag = [presets[i] integerValue];
        b.layer.cornerRadius = 9;
        b.layer.borderWidth = 1.0;
        [b setTitle:[NSString stringWithFormat:@"%@", presets[i]] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
        [b addTarget:self action:@selector(onCountPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:b];
        [cBtns addObject:b];
    }
    self.countButtons = cBtns;

    self.countField = [[UITextField alloc] initWithFrame:CGRectMake(16 + 4 * (pillW + gap), 126, cw - 32 - 4 * (pillW + gap), 36)];
    self.countField.backgroundColor = [UIColor colorWithRed:0.051 green:0.059 blue:0.071 alpha:1.0];
    self.countField.layer.cornerRadius = 9;
    self.countField.layer.borderWidth = 1.0;
    self.countField.layer.borderColor = [UIColor colorWithRed:0.165 green:0.184 blue:0.227 alpha:1.0].CGColor;
    self.countField.textColor = UIColor.whiteColor;
    self.countField.textAlignment = NSTextAlignmentCenter;
    self.countField.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    self.countField.keyboardType = UIKeyboardTypeNumberPad;
    self.countField.text = @"5";
    [self.countField addTarget:self action:@selector(onCustomCountEdited:) forControlEvents:UIControlEventEditingChanged];
    [self.cardView addSubview:self.countField];

    UILabel *spdLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 174, cw - 32, 18)];
    spdLbl.text = @"THỜI GIAN GIÃN CÁCH MỖI TIN (GIÂY)";
    spdLbl.textColor = [UIColor colorWithRed:0.612 green:0.639 blue:0.686 alpha:1.0];
    spdLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    [self.cardView addSubview:spdLbl];

    NSArray<NSString *> *spdTitles = @[@"0.1s", @"0.3s", @"0.5s", @"1.0s", @"2.0s"];
    NSArray<NSNumber *> *spdTags = @[@100, @300, @500, @1000, @2000];
    NSMutableArray<UIButton *> *sBtns = [NSMutableArray new];
    CGFloat spdGap = 5.0;
    CGFloat spdW = floor((cw - 32.0 - spdGap * 5.0) / 6.0);
    for (NSUInteger i = 0; i < spdTitles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(16 + i * (spdW + spdGap), 196, spdW, 38);
        b.tag = [spdTags[i] integerValue];
        b.layer.cornerRadius = 9;
        b.layer.borderWidth = 1.0;
        [b setTitle:spdTitles[i] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
        [b addTarget:self action:@selector(onSpeedPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:b];
        [sBtns addObject:b];
    }
    self.speedButtons = sBtns;

    self.delayField = [[UITextField alloc] initWithFrame:CGRectMake(16 + 5 * (spdW + spdGap), 196, cw - 32 - 5 * (spdW + spdGap), 38)];
    self.delayField.backgroundColor = [UIColor colorWithRed:0.051 green:0.059 blue:0.071 alpha:1.0];
    self.delayField.layer.cornerRadius = 9;
    self.delayField.layer.borderWidth = 1.0;
    self.delayField.layer.borderColor = [UIColor colorWithRed:0.165 green:0.184 blue:0.227 alpha:1.0].CGColor;
    self.delayField.textColor = UIColor.whiteColor;
    self.delayField.textAlignment = NSTextAlignmentCenter;
    self.delayField.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    self.delayField.keyboardType = UIKeyboardTypeDecimalPad;
    self.delayField.text = [NSString stringWithFormat:@"%g", self.selectedDelay];
    [self.delayField addTarget:self action:@selector(onCustomDelayEdited:) forControlEvents:UIControlEventEditingChanged];
    [self.cardView addSubview:self.delayField];

    UILabel *dupLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 248, cw - 90, 32)];
    dupLbl.text = @"Tự thêm số đếm / emoji cuối tin ([1] ✨)";
    dupLbl.textColor = UIColor.whiteColor;
    dupLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.cardView addSubview:dupLbl];

    self.antiDupSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cw - 68, 248, 51, 31)];
    self.antiDupSwitch.onTintColor = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:1.0];
    self.antiDupSwitch.on = sSpamAntiDuplicate;
    [self.antiDupSwitch addTarget:self action:@selector(onAntiDupToggled:) forControlEvents:UIControlEventValueChanged];
    [self.cardView addSubview:self.antiDupSwitch];

    self.startStopButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.startStopButton.frame = CGRectMake(16, 298, cw - 32, 48);
    self.startStopButton.layer.cornerRadius = 12;
    [self.startStopButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.startStopButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [self.startStopButton addTarget:self action:@selector(onStartStopTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:self.startStopButton];

    UILabel *hintLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 356, cw - 32, 18)];
    hintLbl.text = @"Mẹo: Bấm lại nút ↻ xN để Dừng khẩn cấp bất kỳ lúc nào";
    hintLbl.textAlignment = NSTextAlignmentCenter;
    hintLbl.textColor = [UIColor colorWithRed:0.612 green:0.639 blue:0.686 alpha:1.0];
    hintLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    [self.cardView addSubview:hintLbl];

    [self refreshSelectionUI];
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(refreshSelectionUI) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
}

- (void)onAntiDupToggled:(UISwitch *)sw
{
    sSpamAntiDuplicate = sw.on;
}

- (void)onBackdropTap:(UITapGestureRecognizer *)g
{
    CGPoint pt = [g locationInView:self.view];
    if (!CGRectContainsPoint(self.cardView.frame, pt)) {
        [self.view endEditing:YES];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)onCountPresetTapped:(UIButton *)sender
{
    self.selectedCount = sender.tag;
    self.countField.text = [NSString stringWithFormat:@"%ld", (long)self.selectedCount];
    [self refreshSelectionUI];
}

- (void)onCustomCountEdited:(UITextField *)tf
{
    NSInteger v = [tf.text integerValue];
    if (v > 0) self.selectedCount = MIN(500, v);
    [self refreshSelectionUI];
}

- (void)onSpeedPresetTapped:(UIButton *)sender
{
    self.selectedDelay = MAX(0.05, sender.tag / 1000.0);
    self.delayField.text = [NSString stringWithFormat:@"%g", self.selectedDelay];
    [ZXConfig setSpamDelaySeconds:self.selectedDelay];
    [self refreshSelectionUI];
}

- (void)onCustomDelayEdited:(UITextField *)tf
{
    NSString *norm = [tf.text ?: @"" stringByReplacingOccurrencesOfString:@"," withString:@"."];
    double v = [norm doubleValue];
    if (v > 0) {
        self.selectedDelay = MAX(0.05, MIN(60.0, v));
        [ZXConfig setSpamDelaySeconds:self.selectedDelay];
    }
    [self refreshSelectionUI];
}

- (void)refreshSelectionUI
{
    UIColor *red = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:1.0];
    UIColor *dark = [UIColor colorWithRed:0.051 green:0.059 blue:0.071 alpha:1.0];
    UIColor *border = [UIColor colorWithRed:0.165 green:0.184 blue:0.227 alpha:1.0];

    for (UIButton *b in self.countButtons) {
        BOOL sel = (b.tag == self.selectedCount);
        b.backgroundColor = sel ? red : dark;
        b.layer.borderColor = (sel ? red : border).CGColor;
    }
    NSInteger curMs = (NSInteger)round(self.selectedDelay * 1000.0);
    for (UIButton *b in self.speedButtons) {
        BOOL sel = (b.tag == curMs);
        b.backgroundColor = sel ? red : dark;
        b.layer.borderColor = (sel ? red : border).CGColor;
    }

    if ([ZXHookEngine isSpamRunning]) {
        self.startStopButton.backgroundColor = [UIColor colorWithRed:0.95 green:0.35 blue:0.15 alpha:1.0];
        NSString *t = [NSString stringWithFormat:@"⏹ Dừng khẩn cấp (Đang gửi %ld/%ld • %gs...)",
                       (long)[ZXHookEngine spamSentCount], (long)[ZXHookEngine spamTotalCount], gActiveSpamDelay];
        [self.startStopButton setTitle:t forState:UIControlStateNormal];
    } else {
        self.startStopButton.backgroundColor = red;
        [self.startStopButton setTitle:@"🚀 Bắt đầu gửi" forState:UIControlStateNormal];
    }
}

- (void)onStartStopTapped
{
    @try {
        if ([ZXHookEngine isSpamRunning]) {
            [ZXHookEngine stopSpamNow];
            [self refreshSelectionUI];
            return;
        }
        NSString *msg = [self.messageField.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSInteger cnt = [self.countField.text integerValue];
        if (cnt <= 0) cnt = self.selectedCount > 0 ? self.selectedCount : 5;
        if (msg.length == 0) {
            self.messageField.layer.borderColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.21 alpha:1.0].CGColor;
            return;
        }
        gLastSpamText = msg;
        sSpamAntiDuplicate = self.antiDupSwitch.on;

        UIViewController *presenting = self.presentingViewController;
        [self dismissViewControllerAnimated:YES completion:^{
            UIViewController *outerPresenting = presenting.presentingViewController;
            NSString *pClass = NSStringFromClass([presenting class]);
            BOOL isModVC = [pClass hasPrefix:@"ZX"] || ([presenting isKindOfClass:[UINavigationController class]] &&
                [NSStringFromClass([((UINavigationController *)presenting).viewControllers.firstObject class]) hasPrefix:@"ZX"]);
            if (isModVC) {
                [presenting dismissViewControllerAnimated:YES completion:^{
                    if (outerPresenting && ([NSStringFromClass([outerPresenting class]) hasPrefix:@"ZX"] ||
                        ([outerPresenting isKindOfClass:[UINavigationController class]] &&
                         [NSStringFromClass([((UINavigationController *)outerPresenting).viewControllers.firstObject class]) hasPrefix:@"ZX"]))) {
                        [outerPresenting dismissViewControllerAnimated:YES completion:^{
                            [ZXHookEngine startSpamWithText:msg count:cnt delay:self.selectedDelay];
                        }];
                    } else {
                        [ZXHookEngine startSpamWithText:msg count:cnt delay:self.selectedDelay];
                    }
                }];
            } else {
                [ZXHookEngine startSpamWithText:msg count:cnt delay:self.selectedDelay];
            }
        }];
    } @catch (NSException *e) {
        ZXLog(@"onStartStopTapped exception: %@", e.reason);
    }
}

- (void)closePopup
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ---- Dedicated High-Level Overlay Window for ↻ xN Button ------------------

@interface ZXUIRuntimeHelper : NSObject
+ (void)onRepeatButtonTapped:(UIButton *)sender;
+ (void)onUnlockButtonTapped:(UIButton *)sender;
+ (void)onCellLongPress:(UILongPressGestureRecognizer *)g;
+ (void)onKeyboardWillShow:(NSNotification *)n;
+ (void)onKeyboardWillHide:(NSNotification *)n;
+ (void)onInputDidBeginEditing:(NSNotification *)n;
+ (void)onAppDidEnterBackground:(NSNotification *)n;
+ (void)onAppWillEnterForeground:(NSNotification *)n;
@end

static void ZXShowOrUpdateSpamOverlayButton(CGFloat keyboardTopY)
{
    @try {
        if (![ZXConfig boolForKey:ZXK_MSG_REPEATER] || ZXIsModScreenVisible()) {
            if (gSpamOverlayWindow) gSpamOverlayWindow.hidden = YES;
            return;
        }
        UIWindowScene *sc = ZXCurrentWindowScene();
        if (@available(iOS 13.0, *)) {
            if (!sc) return; // Never create UIWindow without an active UIWindowScene on iOS 13-26
        }

        CGSize screenSz = sc ? sc.coordinateSpace.bounds.size : UIScreen.mainScreen.bounds.size;
        CGFloat btnW = 68.0, btnH = 36.0;
        CGFloat topY = keyboardTopY > 100.0 ? (keyboardTopY - btnH - 52.0) : (screenSz.height * 0.52);
        topY = MAX(76.0, MIN(screenSz.height - btnH - 60.0, topY));
        CGRect btnFrame = CGRectMake(screenSz.width - btnW - 12.0, topY, btnW, btnH);

        if (!gSpamOverlayWindow) {
            if (@available(iOS 13.0, *)) {
                gSpamOverlayWindow = [[UIWindow alloc] initWithWindowScene:sc];
            } else {
                gSpamOverlayWindow = [[UIWindow alloc] initWithFrame:btnFrame];
            }
            gSpamOverlayWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
            gSpamOverlayWindow.backgroundColor = UIColor.clearColor;
            UIViewController *rootVC = [UIViewController new];
            if (@available(iOS 13.0, *)) rootVC.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            rootVC.view.backgroundColor = UIColor.clearColor;
            gSpamOverlayWindow.rootViewController = rootVC;

            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(0, 0, btnW, btnH);
            b.backgroundColor = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:0.98];
            b.layer.cornerRadius = btnH / 2.0;
            b.layer.borderWidth = 1.5;
            b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
            b.layer.shadowColor = UIColor.blackColor.CGColor;
            b.layer.shadowOpacity = 0.4;
            b.layer.shadowRadius = 5;
            b.layer.shadowOffset = CGSizeMake(0, 2);
            [b setTitle:@"↻ xN" forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
            [b addTarget:[ZXUIRuntimeHelper class] action:@selector(onRepeatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [rootVC.view addSubview:b];
            gKeyboardSpamButton = b;
        } else if (@available(iOS 13.0, *)) {
            if (sc && gSpamOverlayWindow.windowScene != sc) {
                gSpamOverlayWindow.windowScene = sc;
            }
        }

        UIWindowLevel maxLevel = UIWindowLevelStatusBar + 100.0;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w != gSpamOverlayWindow && w.windowLevel >= maxLevel && w.windowLevel < UIWindowLevelAlert + 500) {
                maxLevel = w.windowLevel + 10.0;
            }
        }
        gSpamOverlayWindow.windowLevel = maxLevel;
        gSpamOverlayWindow.frame = btnFrame;
        gKeyboardSpamButton.frame = CGRectMake(0, 0, btnW, btnH);
        [gKeyboardSpamButton setTitle:([ZXHookEngine isSpamRunning] ? @"⏹ Dừng" : @"↻ xN") forState:UIControlStateNormal];
        gSpamOverlayWindow.hidden = NO;
    } @catch (NSException *e) {
        ZXLog(@"ZXShowOrUpdateSpamOverlayButton exception: %@", e.reason);
    }
}

@implementation ZXUIRuntimeHelper

+ (void)onRepeatButtonTapped:(UIButton *)sender
{
    (void)sender;
    @try {
        if ([ZXHookEngine isSpamRunning]) {
            [ZXHookEngine stopSpamNow];
            if (gKeyboardSpamButton) {
                [gKeyboardSpamButton setTitle:@"↻ xN" forState:UIControlStateNormal];
            }
            return;
        }
        [ZXHookEngine presentRepeaterDialogFromVC:ZXTopPresentedVC()];
    } @catch (NSException *e) {
        ZXLog(@"onRepeatButtonTapped exception: %@", e.reason);
    }
}

+ (void)onInputDidBeginEditing:(NSNotification *)n
{
    @try {
        id obj = n.object;
        if (![obj isKindOfClass:[UIView class]]) return;
        UIView *v = (UIView *)obj;
        UIViewController *vc = ZXNearestViewControllerForView(v);
        if (vc && [NSStringFromClass([vc class]) hasPrefix:@"ZX"]) return;

        sActiveInputView = v;
        if (vc) gActiveChatVC = vc;
        ZXShowOrUpdateSpamOverlayButton(gLastKeyboardTopY);
    } @catch (NSException *e) {
        ZXLog(@"onInputDidBeginEditing exception: %@", e.reason);
    }
}

+ (void)onKeyboardWillShow:(NSNotification *)n
{
    @try {
        CGRect kbEnd = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        if (kbEnd.size.height < 80) return;
        gLastKeyboardTopY = kbEnd.origin.y;

        if (!sActiveInputView || !sActiveInputView.window) {
            ZXFindChatInputView(ZXActiveWindow());
        }
        ZXShowOrUpdateSpamOverlayButton(gLastKeyboardTopY);
    } @catch (NSException *e) {
        ZXLog(@"onKeyboardWillShow exception: %@", e.reason);
    }
}

+ (void)onKeyboardWillHide:(NSNotification *)n
{
    (void)n;
    @try {
        if (gSpamOverlayWindow && ![ZXHookEngine isSpamRunning]) {
            gSpamOverlayWindow.hidden = YES;
        }
    } @catch (NSException *e) {
        ZXLog(@"onKeyboardWillHide exception: %@", e.reason);
    }
}

+ (void)onAppDidEnterBackground:(NSNotification *)n
{
    (void)n;
    ZXStartBackgroundKeepAlive();
}

+ (void)onAppWillEnterForeground:(NSNotification *)n
{
    (void)n;
    ZXStopBackgroundKeepAlive();
}

+ (void)onUnlockButtonTapped:(UIButton *)sender
{
    @try {
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
    } @catch (NSException *e) {
        ZXLog(@"onUnlockButtonTapped exception: %@", e.reason);
    }
}

+ (void)onCellLongPress:(UILongPressGestureRecognizer *)g
{
    @try {
        if (g.state != UIGestureRecognizerStateBegan) return;
        UIView *cell = g.view;
        if (!cell) return;

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
    } @catch (NSException *e) {
        ZXLog(@"onCellLongPress exception: %@", e.reason);
    }
}

@end

static void ZXAttachLockShieldIfNeeded(UIViewController *vc)
{
    if (!vc) return;
    @try {
        NSString *clsName = NSStringFromClass([vc class]);
        if ([clsName hasPrefix:@"ZX"] || [clsName hasPrefix:@"UI"] || [clsName hasPrefix:@"_"]) return;
        BOOL looksLikeChat = ([clsName rangeOfString:@"Chat" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"CSC" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"MessageView" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!looksLikeChat) return;

        gActiveChatVC = vc;
        ZXIndexDecryptedModelObject(vc);
        ZXFindChatInputView(vc.view);
        if (![ZXConfig boolForKey:ZXK_CHAT_LOCK_ENABLED]) return;

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
    } @catch (NSException *e) {
        ZXLog(@"ZXAttachLockShieldIfNeeded exception: %@", e.reason);
    }
}

// ---- Safe Deferred Feature Hooks (No startup class-scan or SQLite scan!) ---

static void ZXInstallExtendedFeatureHooks(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            ZXInitHiddenChatsStore();

            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onKeyboardWillShow:) name:UIKeyboardDidShowNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillChangeFrameNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onInputDidBeginEditing:) name:UITextViewTextDidBeginEditingNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onInputDidBeginEditing:) name:UITextFieldTextDidBeginEditingNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onAppWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];

            // 1. Hook UIViewController -viewDidAppear: for Chat Lock & tracking active chat VC
            Method vda = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
            if (vda) {
                IMP origVDA = method_getImplementation(vda);
                method_setImplementation(vda, imp_implementationWithBlock(^(UIViewController *self_, BOOL animated) {
                    @try {
                        ((void (*)(id, SEL, BOOL))origVDA)(self_, @selector(viewDidAppear:), animated);
                        if ([NSStringFromClass([self_ class]) hasPrefix:@"ZX"] && gSpamOverlayWindow) {
                            gSpamOverlayWindow.hidden = YES;
                        }
                        ZXAttachLockShieldIfNeeded(self_);
                    } @catch (NSException *e) {
                        ZXLog(@"viewDidAppear hook exception: %@", e.reason);
                    }
                }));
            }

            // 2. Hook UITableViewCell -didMoveToWindow for RAM Decrypted Profile indexing + long-press quick menu
            Method dmw = class_getInstanceMethod([UITableViewCell class], @selector(didMoveToWindow));
            if (dmw) {
                IMP origDMW = method_getImplementation(dmw);
                method_setImplementation(dmw, imp_implementationWithBlock(^(UITableViewCell *self_) {
                    @try {
                        ((void (*)(id, SEL))origDMW)(self_, @selector(didMoveToWindow));
                        if (!self_.window) return;
                        NSString *cn = NSStringFromClass([self_ class]);
                        if ([cn hasPrefix:@"ZX"]) return;
                        ZXIndexCellAndSubviews(self_);
                        static const char kLPKey;
                        if (!objc_getAssociatedObject(self_, &kLPKey)) {
                            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[ZXUIRuntimeHelper class] action:@selector(onCellLongPress:)];
                            lp.minimumPressDuration = 1.0;
                            lp.cancelsTouchesInView = NO;
                            [self_ addGestureRecognizer:lp];
                            objc_setAssociatedObject(self_, &kLPKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        }
                    } @catch (__unused NSException *e) {}
                }));
            }

            // 3. Hook AVAudioPlayer for Voice Message Playback Rate (1.0x / 1.5x / 2.0x) & audio URL capture
            Method avInitURL = class_getInstanceMethod([AVAudioPlayer class], @selector(initWithContentsOfURL:error:));
            if (avInitURL) {
                IMP origInitURL = method_getImplementation(avInitURL);
                method_setImplementation(avInitURL, imp_implementationWithBlock(^id(AVAudioPlayer *self_, NSURL *url, NSError **err) {
                    AVAudioPlayer *p = ((id (*)(id, SEL, NSURL *, NSError **))origInitURL)(self_, @selector(initWithContentsOfURL:error:), url, err);
                    @try {
                        if (url.isFileURL) gLastVoiceURL = url;
                        if (p && [ZXConfig boolForKey:ZXK_VOICE_MSG_TOOLS]) {
                            p.enableRate = YES;
                            p.rate = (float)[ZXConfig voicePlaybackRate];
                        }
                    } @catch (__unused NSException *e) {}
                    return p;
                }));
            }
            Method avPlay = class_getInstanceMethod([AVAudioPlayer class], @selector(play));
            if (avPlay) {
                IMP origPlay = method_getImplementation(avPlay);
                method_setImplementation(avPlay, imp_implementationWithBlock(^BOOL(AVAudioPlayer *self_) {
                    @try {
                        if (self_.url.isFileURL) gLastVoiceURL = self_.url;
                        if ([ZXConfig boolForKey:ZXK_VOICE_MSG_TOOLS]) {
                            self_.enableRate = YES;
                            self_.rate = (float)[ZXConfig voicePlaybackRate];
                        }
                    } @catch (__unused NSException *e) {}
                    return ((BOOL (*)(id, SEL))origPlay)(self_, @selector(play));
                }));
            }

            // 4. Hook AVAudioSession -setCategory:mode:options:error: to detect call start/stop for Auto Call Recording
            Method avCat = class_getInstanceMethod([AVAudioSession class], @selector(setCategory:mode:options:error:));
            if (avCat) {
                IMP origCat = method_getImplementation(avCat);
                method_setImplementation(avCat, imp_implementationWithBlock(^BOOL(AVAudioSession *self_, AVAudioSessionCategory cat, AVAudioSessionMode mode, AVAudioSessionCategoryOptions opts, NSError **err) {
                    BOOL ok = ((BOOL (*)(id, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionCategoryOptions, NSError **))origCat)(self_, @selector(setCategory:mode:options:error:), cat, mode, opts, err);
                    @try {
                        if ([cat isEqualToString:AVAudioSessionCategoryPlayAndRecord] && [mode isEqualToString:AVAudioSessionModeVoiceChat]) {
                            ZXStartCallRecordingIfNeeded();
                        } else if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient] || [cat isEqualToString:AVAudioSessionCategoryAmbient]) {
                            ZXStopCallRecordingIfActive();
                        }
                    } @catch (__unused NSException *e) {}
                    return ok;
                }));
            }
        } @catch (NSException *e) {
            ZXLog(@"ZXInstallExtendedFeatureHooks exception: %@", e.reason);
        }
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
    @try {
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
    } @catch (NSException *e) {
        ZXLog(@"ensureRulesFile exception: %@", e.reason);
    }
}

+ (NSArray *)loadRules
{
    @try {
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
    } @catch (NSException *e) {
        ZXLog(@"loadRules exception: %@", e.reason);
        return @[];
    }
}

+ (void)installFromRules
{
    @try {
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
    } @catch (NSException *e) {
        ZXLog(@"installFromRules exception: %@", e.reason);
    }
}

+ (void)retryPending
{
    @try {
        ZXInstallExtendedFeatureHooks();
        if (gPending.count == 0) return;
        NSArray *todo = [gPending copy];
        [gPending removeAllObjects];
        for (NSDictionary *r in todo)
            if (![self installRule:r]) [gPending addObject:r];
    } @catch (NSException *e) {
        ZXLog(@"retryPending exception: %@", e.reason);
    }
}

static BOOL ZXWordArgType(char c)
{
    return c != 0 && strchr("cCsSiIlLqQB@#^*:", c) != NULL;
}

+ (BOOL)installRule:(NSDictionary *)rule
{
    @try {
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
                @try {
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
                } @catch (__unused NSException *e) {}
                ((void (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
            };
        } else {
            block = ^ZXWord(id self_, ZXWord a1, ZXWord a2, ZXWord a3, ZXWord a4, ZXWord a5, ZXWord a6) {
                ZXWord args[6] = {a1, a2, a3, a4, a5, a6};
                @try {
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
                } @catch (__unused NSException *e) {}
                return ((ZXWord (*)(id, SEL, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord, ZXWord))orig)(self_, sel, args[0], args[1], args[2], args[3], args[4], args[5]);
            };
        }

        IMP newImp = imp_implementationWithBlock(block);
        if (!class_addMethod(target, sel, newImp, types))
            method_setImplementation(m, newImp);

        [gInstalled addObject:key];
        ZXLog(@"hooked %@ (%@) action=%@", key, ruleId, action);
        return YES;
    } @catch (NSException *e) {
        ZXLog(@"installRule exception: %@", e.reason);
        return YES;
    }
}

// ---- Extended Public API --------------------------------------------------

static void ZXReloadAllZaloTableViewsInView(UIView *v)
{
    if (!v) return;
    @try {
        if ([v isKindOfClass:[UITableView class]]) {
            [(UITableView *)v reloadData];
        }
        for (UIView *sub in v.subviews) {
            ZXReloadAllZaloTableViewsInView(sub);
        }
    } @catch (__unused NSException *e) {}
}

static UISearchBar *ZXFindSearchBarInView(UIView *v)
{
    if (!v || v.hidden || v.alpha < 0.05) return nil;
    if ([v isKindOfClass:[UISearchBar class]]) return (UISearchBar *)v;
    for (UIView *sub in v.subviews) {
        UISearchBar *found = ZXFindSearchBarInView(sub);
        if (found) return found;
    }
    return nil;
}

static UITextField *ZXFindSearchTextFieldInView(UIView *v)
{
    if (!v || v.hidden || v.alpha < 0.05) return nil;
    if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        NSString *ph = (tf.placeholder ?: tf.attributedPlaceholder.string ?: @"").lowercaseString;
        if ([ph containsString:@"tìm"] || [ph containsString:@"search"] || tf.bounds.origin.y < 180) {
            return tf;
        }
    }
    for (UIView *sub in v.subviews) {
        UITextField *found = ZXFindSearchTextFieldInView(sub);
        if (found) return found;
    }
    return nil;
}

static UIControl *ZXFindTopSearchTriggerButton(UIView *v, UIWindow *win)
{
    if (!v || !win || v.hidden || v.alpha < 0.05) return nil;
    CGRect r = [v convertRect:v.bounds toView:win];
    if (r.origin.y >= 18 && r.origin.y <= 145) {
        NSString *acc = (v.accessibilityLabel ?: @"").lowercaseString;
        BOOL hasSearchText = ([acc containsString:@"tìm"] || [acc containsString:@"search"]);
        if (!hasSearchText && [v isKindOfClass:[UILabel class]]) {
            NSString *lt = ([(UILabel *)v text] ?: @"").lowercaseString;
            hasSearchText = ([lt containsString:@"tìm"] || [lt containsString:@"search"]);
        }
        if (hasSearchText) {
            UIView *cur = v;
            while (cur && cur != win) {
                if ([cur isKindOfClass:[UIControl class]] || cur.gestureRecognizers.count > 0) {
                    return (UIControl *)cur;
                }
                cur = cur.superview;
            }
            return (UIControl *)v;
        }
        if (([v isKindOfClass:[UIControl class]] || v.gestureRecognizers.count > 0) && r.size.width >= 120 && r.size.height >= 24 && r.size.height <= 60) {
            return (UIControl *)v;
        }
    }
    for (UIView *sub in v.subviews) {
        UIControl *found = ZXFindTopSearchTriggerButton(sub, win);
        if (found) return found;
    }
    return nil;
}

static UIView *ZXFindFirstResponderInView(UIView *v)
{
    if (!v) return nil;
    if (v.isFirstResponder) return v;
    for (UIView *sub in v.subviews) {
        UIView *found = ZXFindFirstResponderInView(sub);
        if (found) return found;
    }
    return nil;
}

static void ZXShowBottomBannerOnWindow(UIWindow *win, NSString *msg)
{
    if (!win || msg.length == 0) return;
    @try {
        UIView *old = [win viewWithTag:0x544F4154];
        if (old) [old removeFromSuperview];

        CGFloat maxW = win.bounds.size.width - 36.0;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, maxW - 28, 38)];
        lbl.text = msg;
        lbl.textColor = UIColor.whiteColor;
        lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.numberOfLines = 2;

        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(18, win.bounds.size.height - 120.0, maxW, 54.0)];
        banner.tag = 0x544F4154;
        banner.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.14 alpha:0.96];
        banner.layer.cornerRadius = 14.0;
        banner.layer.borderWidth = 1.2;
        banner.layer.borderColor = [UIColor colorWithRed:0.898 green:0.224 blue:0.208 alpha:1.0].CGColor;
        banner.userInteractionEnabled = NO;
        [banner addSubview:lbl];
        [win addSubview:banner];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ banner.alpha = 0; } completion:^(BOOL d) {
                (void)d;
                [banner removeFromSuperview];
            }];
        });
    } @catch (__unused NSException *e) {}
}

+ (void)scanMemoryForHiddenChats
{
    if (gSQLiteScanInProgress) return;
    gSQLiteScanInProgress = YES;
    ZXInitHiddenChatsStore();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSArray<NSDictionary *> *sqlHits = [ZXScanner scanSQLiteForHiddenChats];
            @synchronized (gHiddenChatsMap) {
                [gHiddenChatsMap removeAllObjects];
                for (NSDictionary *item in sqlHits) {
                    NSString *uid = [item[@"uid"] description];
                    NSString *name = [item[@"name"] description];
                    if (uid.length == 0 || [ZXScanner isGarbageChatIdentifier:uid] || [ZXScanner isGarbageChatIdentifier:name]) {
                        continue;
                    }
                    if ([sUnhiddenThreadIDs containsObject:uid]) continue;
                    gHiddenChatsMap[uid] = item;
                }
                ZXSaveHiddenChatsStore();
            }
        } @catch (NSException *e) {
            ZXLog(@"background SQLite scan exception: %@", e.reason);
        }
        gSQLiteScanInProgress = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXHiddenChatsUpdatedNotification" object:nil];
        });
    });
}

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
        [sUnhiddenThreadIDs addObject:chatID];
        [[NSUserDefaults standardUserDefaults] setObject:sUnhiddenThreadIDs.allObjects forKey:@"nthe_unhidden_thread_ids"];
        [gHiddenChatsMap removeObjectForKey:chatID];
        ZXSaveHiddenChatsStore();
    }
    [ZXConfig setBool:YES forKey:ZXK_UNHIDE_CHATS];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [ZXScanner unhideChatInSQLiteWithID:chatID];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = ZXActiveWindow();
            if (win) ZXReloadAllZaloTableViewsInView(win);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXHiddenChatsUpdatedNotification" object:nil];
        });
    });
    return YES;
}

+ (BOOL)openChatWithID:(NSString *)chatID
{
    return [self openChatWithID:chatID displayName:nil];
}

+ (BOOL)openChatWithID:(NSString *)chatID displayName:(NSString *)displayName
{
    if (chatID.length == 0 && displayName.length == 0) return NO;
    @try {
        NSString *cleanDigits = [[(chatID ?: @"") componentsSeparatedByCharactersInSet:
                                 [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
        NSString *uidArg = (cleanDigits.length >= 5) ? cleanDigits : (chatID ?: @"");

        // Determine the best search query: use real human name if resolved, otherwise raw ID (e.g. 320193294)
        NSString *query = [displayName ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange idParen = [query rangeOfString:@" (ID:"];
        if (idParen.location != NSNotFound) {
            query = [query substringToIndex:idParen.location];
        }
        if (query.length == 0 || [query hasPrefix:@"Chưa giải mã"] || [query hasPrefix:@"UID:"] || [query hasPrefix:@"Hội thoại"]) {
            query = uidArg;
        }

        // Always copy query to generalPasteboard as an instant backup
        [UIPasteboard generalPasteboard].string = query;

        UIWindow *win = ZXActiveWindow();
        if (!win) return NO;

        // Step B: Switch Zalo's main UITabBarController to selectedIndex = 0 (Messages tab)
        UIViewController *root = win.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            ((UITabBarController *)root).selectedIndex = 0;
        } else if (root.tabBarController) {
            root.tabBarController.selectedIndex = 0;
        } else {
            for (UIViewController *child in root.childViewControllers) {
                if ([child isKindOfClass:[UITabBarController class]]) {
                    ((UITabBarController *)child).selectedIndex = 0;
                    break;
                }
            }
        }

        // Step C: Find Zalo's search bar / search trigger at the top of the main screen (y < 140pt) and activate it
        UISearchBar *initialSB = ZXFindSearchBarInView(win);
        UITextField *initialTF = ZXFindSearchTextFieldInView(win);
        if (initialSB) {
            [initialSB becomeFirstResponder];
        } else if (initialTF) {
            [initialTF becomeFirstResponder];
        } else {
            UIView *searchTrigger = ZXFindTopSearchTriggerButton(win, win);
            if (searchTrigger) {
                ZXFireTouchAndGesturesOnView(searchTrigger);
            }
        }

        // Step D: After 0.45s when the search input opens, fill in the query, notify delegate, and show Toast
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                UIView *firstResp = ZXFindFirstResponderInView(win);
                UISearchBar *sb = [firstResp isKindOfClass:[UISearchBar class]] ? (UISearchBar *)firstResp : ZXFindSearchBarInView(win);
                UITextField *tf = [firstResp isKindOfClass:[UITextField class]] ? (UITextField *)firstResp : ZXFindSearchTextFieldInView(win);

                if (sb) {
                    if (!sb.isFirstResponder) [sb becomeFirstResponder];
                    sb.text = query;
                    if ([sb.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
                        [sb.delegate searchBar:sb textDidChange:query];
                    }
                }
                if (tf) {
                    if (!tf.isFirstResponder) [tf becomeFirstResponder];
                    tf.text = @"";
                    [tf insertText:query];
                    if (tf.text.length == 0) tf.text = query;
                    if ([tf.delegate respondsToSelector:@selector(textField:shouldChangeCharactersInRange:replacementString:)]) {
                        [tf.delegate textField:tf shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:query];
                    }
                    [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                    [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
                }

                ZXShowBottomBannerOnWindow(win, @"Đã điền vào ô Tìm kiếm — chạm vào kết quả để mở chat");
            } @catch (NSException *e) {
                ZXLog(@"Step D search fill exception: %@", e.reason);
            }
        });
        return YES;
    } @catch (NSException *e) {
        ZXLog(@"openChatWithID exception: %@", e.reason);
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
    @try {
        if ([self isCallRecording]) {
            ZXStopCallRecordingIfActive();
        } else {
            BOOL prev = [ZXConfig boolForKey:ZXK_AUTO_CALL_RECORD];
            [ZXConfig setBool:YES forKey:ZXK_AUTO_CALL_RECORD];
            ZXStartCallRecordingIfNeeded();
            if (!prev) [ZXConfig setBool:prev forKey:ZXK_AUTO_CALL_RECORD];
        }
    } @catch (__unused NSException *e) {}
}

+ (BOOL)isSpamRunning
{
    return gSpamRunning;
}

+ (NSInteger)spamSentCount
{
    return gSpamSentCount;
}

+ (NSInteger)spamTotalCount
{
    return gSpamTotalCount;
}

+ (void)stopSpamNow
{
    gSpamGeneration++;
    gSpamRunning = NO;
    if (gKeyboardSpamButton) {
        [gKeyboardSpamButton setTitle:@"↻ xN" forState:UIControlStateNormal];
    }
}

+ (void)startSpamWithText:(NSString *)text count:(NSInteger)count delay:(double)delay
{
    if (text.length == 0 || count <= 0) return;
    gSpamGeneration++;
    NSInteger myGen = gSpamGeneration;
    gSpamRunning = YES;
    gSpamSentCount = 0;
    gSpamTotalCount = MIN(500, count);
    double interval = MAX(0.05, delay);
    gActiveSpamDelay = interval;
    [ZXConfig setSpamDelaySeconds:interval];

    ZXShowOrUpdateSpamOverlayButton(gLastKeyboardTopY);

    NSArray<NSString *> *emojis = @[@"✨", @"🔥", @"⚡", @"💫", @"🚀"];
    UIViewController *targetChat = gActiveChatVC;
    for (NSInteger i = 0; i < gSpamTotalCount; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (!gSpamRunning || gSpamGeneration != myGen) return;
                NSString *payload = text;
                if (sSpamAntiDuplicate && gSpamTotalCount > 1) {
                    NSString *em = emojis[(NSUInteger)i % emojis.count];
                    payload = [NSString stringWithFormat:@"%@ [%ld] %@", text, (long)(i + 1), em];
                }
                ZXSendSingleTextInChat(targetChat, payload);
                gSpamSentCount = i + 1;
                if (gKeyboardSpamButton) {
                    [gKeyboardSpamButton setTitle:[NSString stringWithFormat:@"⏹ %ld/%ld", (long)gSpamSentCount, (long)gSpamTotalCount] forState:UIControlStateNormal];
                }
                if (gSpamSentCount >= gSpamTotalCount) {
                    gSpamRunning = NO;
                    if (gKeyboardSpamButton) {
                        [gKeyboardSpamButton setTitle:@"↻ xN" forState:UIControlStateNormal];
                    }
                }
            } @catch (NSException *e) {
                ZXLog(@"spam tick exception: %@", e.reason);
            }
        });
    }
}

+ (void)presentRepeaterDialogFromVC:(UIViewController *)vc
{
    @try {
        UIViewController *host = vc ?: ZXTopPresentedVC();
        if (!host) return;
        ZXSpamPopupViewController *popup = [ZXSpamPopupViewController new];
        popup.modalPresentationStyle = UIModalPresentationOverFullScreen;
        popup.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [host presentViewController:popup animated:YES completion:nil];
    } @catch (NSException *e) {
        ZXLog(@"presentRepeaterDialog exception: %@", e.reason);
    }
}

@end
