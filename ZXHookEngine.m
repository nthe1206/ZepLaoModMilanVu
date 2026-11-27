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
#import <objc/message.h>
#import <string.h>

typedef uintptr_t ZXWord;

static NSMutableSet<NSString *> *gInstalled;
static NSMutableArray<NSDictionary *> *gPending;
static NSMutableDictionary<NSString *, NSDictionary *> *gHiddenChatsMap;
static NSMutableDictionary<NSString *, NSDictionary *> *gResolvedProfilesMap;
static NSString *sLastGSCaptureLog;
static NSMutableSet<NSString *> *sUnhiddenThreadIDs;
static NSMutableSet<NSString *> *sDismissedHiddenKeys;
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
static BOOL gSQLiteRescanRequested;

// GlobalSearchLogic & ZAGlobalSearch hook state (Zalo 26.11.02.1)
static BOOL sHookedGSMatchableSet = NO;
static BOOL sHookedGSMatchableGet = NO;
static BOOL sHookedGSSearchDataSet = NO;
static BOOL sHookedGSSearchDataGet = NO;
static BOOL sHookedGSEventUpdate = NO;
static BOOL sHookedGSEventReload = NO;
static uintptr_t sLastIngestedPayloadPtr = 0;
static double sLastIngestedPayloadTime = 0.0;
static NSMutableSet<NSString *> *sSwizzledSearchDelegates;
static NSString *sCandidateTypedPIN;
static double sCandidatePinTypedTime = 0.0;

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

// ---- Feature 1: Hidden Chats Store (Schema v5_gs_hidden_model) -------------

static NSArray<NSString *> *ZXAllStoreCandidatePaths(NSString *fileName)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    if (!fileName.length) return paths;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *cfgDir = [ZXConfig dataDir];
    for (NSString *dir in @[docs ?: @"", cfgDir ?: @"", caches ?: @"",
                            (docs.length ? [docs stringByAppendingPathComponent:@"ZaloXposed"] : @""),
                            (caches.length ? [caches stringByAppendingPathComponent:@"ZaloXposed"] : @"")]) {
        if (dir.length == 0) continue;
        NSString *p = [dir stringByAppendingPathComponent:fileName];
        if (![paths containsObject:p]) [paths addObject:p];
    }
    return paths;
}

static BOOL ZXIsExcludedOwnerThreadID(NSString *candidateID)
{
    if (!candidateID || candidateID.length == 0) return YES;
    NSSet<NSString *> *owners = [ZXScanner discoveredOwnerUIDs];
    if ([owners containsObject:candidateID]) return YES;
    NSString *digits = [[candidateID componentsSeparatedByCharactersInSet:
                        [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (digits.length > 0 && [owners containsObject:digits]) return YES;
    NSString *cfgOwner = [ZXConfig currentUserID];
    if (cfgOwner.length > 0 && ([candidateID isEqualToString:cfgOwner] || (digits.length > 0 && [digits isEqualToString:cfgOwner]))) {
        return YES;
    }
    return NO;
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
        NSArray *savedDismissed = [[NSUserDefaults standardUserDefaults] arrayForKey:@"zx_dismissed_hidden_keys"];
        sDismissedHiddenKeys = [NSMutableSet setWithArray:(savedDismissed ?: @[])];

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *oldHC in ZXAllStoreCandidatePaths(@"hidden_chats.json")) {
            if ([fm fileExistsAtPath:oldHC]) [fm removeItemAtPath:oldHC error:nil];
        }

        @try {
            NSString *primaryPath = [ZXScanner resolvedProfilesPath];
            for (NSString *profPath in ZXAllStoreCandidatePaths(@"zx_resolved_profiles.json")) {
                if (![fm fileExistsAtPath:profPath]) continue;
                NSData *pData = [NSData dataWithContentsOfFile:profPath];
                if (!pData) {
                    [fm removeItemAtPath:profPath error:nil];
                    continue;
                }
                id pObj = [NSJSONSerialization JSONObjectWithData:pData options:0 error:nil];
                NSDictionary *root = [pObj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)pObj : nil;
                NSString *ver = [root[@"schema_version"] isKindOfClass:[NSString class]] ? root[@"schema_version"] : @"";
                if (![ver isEqualToString:ZX_HIDDEN_CACHE_SCHEMA_VERSION]) {
                    // Auto-delete outdated cache missing v5_gs_hidden_model
                    [fm removeItemAtPath:profPath error:nil];
                    continue;
                }
                if (![profPath isEqualToString:primaryPath]) continue;
                NSDictionary *profiles = [root[@"profiles"] isKindOfClass:[NSDictionary class]] ? root[@"profiles"] : @{};
                for (NSString *k in profiles) {
                    NSDictionary *val = [profiles[k] isKindOfClass:[NSDictionary class]] ? profiles[k] : nil;
                    if (!val) continue;
                    NSString *tid = [[val[@"threadId"] ?: val[@"uid"] ?: k description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    NSString *nm = [[val[@"displayName"] ?: val[@"name"] ?: @"" description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (tid.length == 0 || ZXIsExcludedOwnerThreadID(tid) || [sDismissedHiddenKeys containsObject:tid]) continue;
                    if (![ZXScanner isValidHumanDisplayName:nm excludeUID:tid]) continue;
                    gResolvedProfilesMap[tid] = val;
                }
            }
        } @catch (__unused NSException *e) {}
    });
}

static void ZXSaveResolvedProfilesNow(void)
{
    @try {
        ZXInitHiddenChatsStore();
        NSDictionary *snap = nil;
        @synchronized (gResolvedProfilesMap) {
            snap = [gResolvedProfilesMap copy];
        }
        NSDictionary *payload = @{
            @"schema_version": ZX_HIDDEN_CACHE_SCHEMA_VERSION,
            @"updated_at": @((long long)[[NSDate date] timeIntervalSince1970]),
            @"profiles": (snap ?: @{})
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (d) [d writeToFile:[ZXScanner resolvedProfilesPath] atomically:YES];
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

// ---- Direct GlobalSearchLogic & ZAGlobalSearch Hidden Model Hooks (Zalo 26.11.02.1) ----

static UIViewController *ZXNearestViewControllerForView(UIView *view);
static void ZXTryInstallGlobalSearchHiddenHooks(void);

static BOOL ZXIsPinCodeString(NSString *raw)
{
    if (!raw) return NO;
    NSString *trim = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length < 4 || trim.length > 6) return NO;
    for (NSUInteger i = 0; i < trim.length; i++) {
        unichar c = [trim characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static BOOL ZXShouldSkipSwizzleForClassName(NSString *clsName)
{
    if (!clsName || clsName.length == 0) return YES;
    if ([clsName hasPrefix:@"ZX"] || [clsName hasPrefix:@"UI"] || [clsName hasPrefix:@"_UI"] || [clsName hasPrefix:@"__UI"] || [clsName hasPrefix:@"NS"]) {
        return YES;
    }
    return NO;
}

static void ZXNotePotentialSearchText(NSString *text, UIView *sourceView)
{
    @try {
        if (sourceView) {
            UIViewController *vc = ZXNearestViewControllerForView(sourceView);
            if (vc && [NSStringFromClass([vc class]) hasPrefix:@"ZX"]) return;
        }
        ZXTryInstallGlobalSearchHiddenHooks();
        NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ZXIsPinCodeString(trim)) {
            sCandidateTypedPIN = trim;
            sCandidatePinTypedTime = CFAbsoluteTimeGetCurrent();
        } else if (trim.length > 6) {
            sCandidateTypedPIN = nil;
            sCandidatePinTypedTime = 0.0;
        }
    } @catch (__unused NSException *e) {}
}

/// Safely invokes a zero-argument Objective-C object getter via explicit function-pointer-cast objc_msgSend.
static NSString *ZXSafeCallZeroArgStringSelector(id target, SEL sel)
{
    if (!target || !sel) return @"";
    @try {
        if (![target respondsToSelector:sel]) return @"";
        Method m = class_getInstanceMethod(object_getClass(target), sel);
        if (!m || method_getNumberOfArguments(m) != 2) return @"";
        char ret[16] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        if (ret[0] != '@') return @"";

        id (*msgSendObj)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id val = msgSendObj(target, sel);
        if (!val) return @"";
        if ([val isKindOfClass:[NSString class]]) {
            return [(NSString *)val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        if ([val isKindOfClass:[NSNumber class]]) {
            return [[(NSNumber *)val stringValue] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        if ([val isKindOfClass:[NSAttributedString class]]) {
            return [[(NSAttributedString *)val string] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    } @catch (__unused NSException *e) {}
    return @"";
}

/// Extracts 1-to-1 (threadId, displayName, subtitle) from GlobalSearchLogic.GSContact / GSContactSingle / GSContactGroup / GSAsset / GSUtility.
static BOOL ZXExtractVerifiedGSModelItem(id item, NSString **outThreadId, NSString **outDisplayName, NSString **outSubtitle)
{
    if (!item) return NO;
    @try {
        NSString *clsName = NSStringFromClass([item class]) ?: @"";
        // Skip non-conversation utility actions if any appear in listResultHiddenChat
        if ([clsName rangeOfString:@"GSUtility" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return NO;
        }

        static NSArray<NSString *> *sThreadIdSelectors = nil;
        static NSArray<NSString *> *sNameSelectors = nil;
        static dispatch_once_t onceSels;
        dispatch_once(&onceSels, ^{
            sThreadIdSelectors = @[@"contactUid", @"threadId", @"uid", @"objectIdentifier", @"identifier"];
            sNameSelectors = @[@"contactName", @"title"];
        });

        NSString *threadId = @"";
        for (NSString *selStr in sThreadIdSelectors) {
            NSString *val = ZXSafeCallZeroArgStringSelector(item, sel_registerName(selStr.UTF8String));
            if (val.length > 0 && ![val isEqualToString:@"0"] && ![ZXScanner isGarbageChatIdentifier:val]) {
                threadId = val;
                break;
            }
        }
        if (threadId.length == 0 || ZXIsExcludedOwnerThreadID(threadId)) {
            return NO;
        }
        // Ensure threadId contains digits (real Zalo thread/user/group ID, not a static UI action key)
        NSString *digitCore = [[threadId componentsSeparatedByCharactersInSet:
                               [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
        if (digitCore.length < 4) {
            return NO;
        }

        NSString *displayName = @"";
        for (NSString *selStr in sNameSelectors) {
            NSString *val = ZXSafeCallZeroArgStringSelector(item, sel_registerName(selStr.UTF8String));
            if (val.length > 0 && [ZXScanner isValidHumanDisplayName:val excludeUID:threadId]) {
                displayName = val;
                break;
            }
        }
        if (displayName.length == 0) {
            return NO;
        }

        NSString *subtitle = ZXSafeCallZeroArgStringSelector(item, sel_registerName("subtitle"));
        if ([ZXScanner isGarbageChatIdentifier:subtitle]) subtitle = @"";

        if (outThreadId) *outThreadId = threadId;
        if (outDisplayName) *outDisplayName = displayName;
        if (outSubtitle) *outSubtitle = subtitle;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static void ZXIngestGlobalSearchHiddenPayload(id payload, NSString *hookTag)
{
    if (!payload) return;
    @try {
        uintptr_t ptr = (uintptr_t)(__bridge void *)payload;
        double now = CFAbsoluteTimeGetCurrent();
        if (ptr == sLastIngestedPayloadPtr && (now - sLastIngestedPayloadTime) < 0.25) {
            return;
        }
        sLastIngestedPayloadPtr = ptr;
        sLastIngestedPayloadTime = now;

        NSMutableArray *items = [NSMutableArray array];
        SEL selListHidden = sel_registerName("listResultHiddenChat");

        if ([payload isKindOfClass:[NSArray class]]) {
            [items addObjectsFromArray:(NSArray *)payload];
        } else if ([payload isKindOfClass:[NSOrderedSet class]]) {
            [items addObjectsFromArray:[(NSOrderedSet *)payload array]];
        } else if ([payload isKindOfClass:[NSSet class]]) {
            [items addObjectsFromArray:[(NSSet *)payload allObjects]];
        } else if ([payload respondsToSelector:selListHidden]) {
            Method m = class_getInstanceMethod(object_getClass(payload), selListHidden);
            if (m && method_getNumberOfArguments(m) == 2) {
                id (*msgSendObj)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id subList = msgSendObj(payload, selListHidden);
                if ([subList isKindOfClass:[NSArray class]]) {
                    [items addObjectsFromArray:(NSArray *)subList];
                }
            }
        } else {
            [items addObject:payload];
        }

        if (items.count == 0) return;

        ZXInitHiddenChatsStore();
        long long nowTs = (long long)[[NSDate date] timeIntervalSince1970];
        NSUInteger validAdded = 0;
        NSMutableString *diag = [NSMutableString stringWithFormat:@"[%@] count=%lu at %@\n",
                                 hookTag, (unsigned long)items.count, [NSDate date]];

        @synchronized (gResolvedProfilesMap) {
            for (id elem in items) {
                // Unwrap nested GSMatchableResultObject if present inside GSSearchData
                if ([elem respondsToSelector:selListHidden] && ![elem isKindOfClass:[NSArray class]]) {
                    Method m = class_getInstanceMethod(object_getClass(elem), selListHidden);
                    if (m && method_getNumberOfArguments(m) == 2) {
                        id (*msgSendObj)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                        id inner = msgSendObj(elem, selListHidden);
                        if ([inner isKindOfClass:[NSArray class]]) {
                            for (id subItem in (NSArray *)inner) {
                                NSString *tid = nil, *dName = nil, *sub = nil;
                                if (ZXExtractVerifiedGSModelItem(subItem, &tid, &dName, &sub)) {
                                    [sDismissedHiddenKeys removeObject:tid];
                                    [sUnhiddenThreadIDs removeObject:tid];
                                    gResolvedProfilesMap[tid] = @{
                                        @"uid": tid,
                                        @"threadId": tid,
                                        @"displayName": dName,
                                        @"name": dName,
                                        @"subtitle": sub ?: @"",
                                        @"itemClass": NSStringFromClass([subItem class]) ?: @"",
                                        @"source": @"GlobalSearchLogic",
                                        @"updatedAt": @(nowTs)
                                    };
                                    validAdded++;
                                    [diag appendFormat:@"  + [%@] threadId=%@ name='%@'\n",
                                     NSStringFromClass([subItem class]), tid, dName];
                                }
                            }
                            continue;
                        }
                    }
                }

                NSString *tid = nil;
                NSString *dName = nil;
                NSString *sub = nil;
                if (ZXExtractVerifiedGSModelItem(elem, &tid, &dName, &sub)) {
                    [sDismissedHiddenKeys removeObject:tid];
                    [sUnhiddenThreadIDs removeObject:tid];
                    gResolvedProfilesMap[tid] = @{
                        @"uid": tid,
                        @"threadId": tid,
                        @"displayName": dName,
                        @"name": dName,
                        @"subtitle": sub ?: @"",
                        @"itemClass": NSStringFromClass([elem class]) ?: @"",
                        @"source": @"GlobalSearchLogic",
                        @"updatedAt": @(nowTs)
                    };
                    validAdded++;
                    [diag appendFormat:@"  + [%@] threadId=%@ name='%@'\n",
                     NSStringFromClass([elem class]), tid, dName];
                }
            }
        }

        if (validAdded > 0) {
            sLastGSCaptureLog = [diag copy];
            // Save confirmed hidden PIN if the user just typed a 4-6 digit PIN in Search
            if (ZXIsPinCodeString(sCandidateTypedPIN) && (CFAbsoluteTimeGetCurrent() - sCandidatePinTypedTime) <= 20.0) {
                [[NSUserDefaults standardUserDefaults] setObject:sCandidateTypedPIN forKey:@"zx_saved_hidden_pin"];
            }
            ZXSaveResolvedProfilesNow();
            [ZXHookEngine scanMemoryForHiddenChats];
            ZXLog(@"GlobalSearchLogic captured %lu hidden chats via %@", (unsigned long)validAdded, hookTag);
        }
    } @catch (NSException *e) {
        ZXLog(@"ZXIngestGlobalSearchHiddenPayload exception: %@", e.reason);
    }
}

static Class ZXResolveZaloRuntimeClass(const char *dotName, const char *mangledName, const char *shortName)
{
    Class cls = NULL;
    if (dotName) cls = objc_getClass(dotName);
    if (!cls && dotName) cls = NSClassFromString([NSString stringWithUTF8String:dotName]);
    if (!cls && mangledName) cls = objc_getClass(mangledName);
    if (!cls && shortName) cls = objc_getClass(shortName);
    return cls;
}

static void ZXTryInstallGlobalSearchHiddenHooks(void)
{
    if (sHookedGSMatchableSet && sHookedGSSearchDataSet && sHookedGSEventUpdate && sHookedGSEventReload) {
        return;
    }
    @try {
        // (A) Class "GlobalSearchLogic.GSMatchableResultObject"
        Class clsMatchable = ZXResolveZaloRuntimeClass("GlobalSearchLogic.GSMatchableResultObject",
                                                       "_TtC17GlobalSearchLogic23GSMatchableResultObject",
                                                       "GSMatchableResultObject");
        if (clsMatchable) {
            if (!sHookedGSMatchableSet) {
                SEL selSet = sel_registerName("setListResultHiddenChat:");
                Method mSet = class_getInstanceMethod(clsMatchable, selSet);
                if (mSet) {
                    IMP origSet = method_getImplementation(mSet);
                    method_setImplementation(mSet, imp_implementationWithBlock(^(id self_, id listObj) {
                        ((void (*)(id, SEL, id))origSet)(self_, selSet, listObj);
                        ZXIngestGlobalSearchHiddenPayload(listObj, @"GSMatchableResultObject.setListResultHiddenChat:");
                    }));
                    sHookedGSMatchableSet = YES;
                    ZXLog(@"Hooked GlobalSearchLogic.GSMatchableResultObject -setListResultHiddenChat:");
                }
            }
            if (!sHookedGSMatchableGet) {
                SEL selGet = sel_registerName("listResultHiddenChat");
                Method mGet = class_getInstanceMethod(clsMatchable, selGet);
                if (mGet) {
                    IMP origGet = method_getImplementation(mGet);
                    method_setImplementation(mGet, imp_implementationWithBlock(^id(id self_) {
                        id res = ((id (*)(id, SEL))origGet)(self_, selGet);
                        if (res) ZXIngestGlobalSearchHiddenPayload(res, @"GSMatchableResultObject.listResultHiddenChat");
                        return res;
                    }));
                    sHookedGSMatchableGet = YES;
                    ZXLog(@"Hooked GlobalSearchLogic.GSMatchableResultObject -listResultHiddenChat");
                }
            }
        }

        // (B) Class "GlobalSearchLogic.GSSearchData"
        Class clsSearchData = ZXResolveZaloRuntimeClass("GlobalSearchLogic.GSSearchData",
                                                        "_TtC17GlobalSearchLogic12GSSearchData",
                                                        "GSSearchData");
        if (clsSearchData) {
            if (!sHookedGSSearchDataSet) {
                SEL selSet = sel_registerName("setDataSearchHidden:");
                Method mSet = class_getInstanceMethod(clsSearchData, selSet);
                if (mSet) {
                    IMP origSet = method_getImplementation(mSet);
                    method_setImplementation(mSet, imp_implementationWithBlock(^(id self_, id dataObj) {
                        ((void (*)(id, SEL, id))origSet)(self_, selSet, dataObj);
                        ZXIngestGlobalSearchHiddenPayload(dataObj, @"GSSearchData.setDataSearchHidden:");
                    }));
                    sHookedGSSearchDataSet = YES;
                    ZXLog(@"Hooked GlobalSearchLogic.GSSearchData -setDataSearchHidden:");
                }
            }
            if (!sHookedGSSearchDataGet) {
                SEL selGet = sel_registerName("dataSearchHidden");
                Method mGet = class_getInstanceMethod(clsSearchData, selGet);
                if (mGet) {
                    IMP origGet = method_getImplementation(mGet);
                    method_setImplementation(mGet, imp_implementationWithBlock(^id(id self_) {
                        id res = ((id (*)(id, SEL))origGet)(self_, selGet);
                        if (res) ZXIngestGlobalSearchHiddenPayload(res, @"GSSearchData.dataSearchHidden");
                        return res;
                    }));
                    sHookedGSSearchDataGet = YES;
                    ZXLog(@"Hooked GlobalSearchLogic.GSSearchData -dataSearchHidden");
                }
            }
        }

        // (C) Class "ZAGlobalSearch.ZAGlobalSearchEvent"
        Class clsEvent = ZXResolveZaloRuntimeClass("ZAGlobalSearch.ZAGlobalSearchEvent",
                                                   "_TtC14ZAGlobalSearch19ZAGlobalSearchEvent",
                                                   "ZAGlobalSearchEvent");
        if (clsEvent) {
            Class metaEvent = object_getClass(clsEvent);
            if (!sHookedGSEventUpdate && metaEvent) {
                SEL selUpd = sel_registerName("emitUpdateHiddenConversationWithThreadId:isGroup:");
                Method mUpd = class_getInstanceMethod(metaEvent, selUpd);
                if (mUpd) {
                    IMP origUpd = method_getImplementation(mUpd);
                    method_setImplementation(mUpd, imp_implementationWithBlock(^(id self_, id threadIdObj, BOOL isGroup) {
                        ((void (*)(id, SEL, id, BOOL))origUpd)(self_, selUpd, threadIdObj, isGroup);
                        @try {
                            NSString *tid = [threadIdObj description] ?: @"";
                            if (tid.length > 0) [sUnhiddenThreadIDs removeObject:tid];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                [ZXHookEngine scanMemoryForHiddenChats];
                            });
                        } @catch (__unused NSException *e) {}
                    }));
                    sHookedGSEventUpdate = YES;
                    ZXLog(@"Hooked ZAGlobalSearchEvent +emitUpdateHiddenConversationWithThreadId:isGroup:");
                }
            }
            if (!sHookedGSEventReload && metaEvent) {
                SEL selRel = sel_registerName("emitReloadHiddenConversations");
                Method mRel = class_getInstanceMethod(metaEvent, selRel);
                if (mRel) {
                    IMP origRel = method_getImplementation(mRel);
                    method_setImplementation(mRel, imp_implementationWithBlock(^(id self_) {
                        ((void (*)(id, SEL))origRel)(self_, selRel);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                            [ZXHookEngine scanMemoryForHiddenChats];
                        });
                    }));
                    sHookedGSEventReload = YES;
                    ZXLog(@"Hooked ZAGlobalSearchEvent +emitReloadHiddenConversations");
                }
            }
        }
    } @catch (NSException *e) {
        ZXLog(@"ZXTryInstallGlobalSearchHiddenHooks exception: %@", e.reason);
    }
}

static void ZXSwizzleSearchDelegateClassIfNeeded(id delegate)
{
    if (!delegate) return;
    @try {
        Class cls = [delegate class];
        NSString *clsName = NSStringFromClass(cls);
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        if (!sSwizzledSearchDelegates) sSwizzledSearchDelegates = [NSMutableSet new];
        @synchronized (sSwizzledSearchDelegates) {
            if ([sSwizzledSearchDelegates containsObject:clsName]) return;
            [sSwizzledSearchDelegates addObject:clsName];
        }

        SEL selSBChange = @selector(searchBar:textDidChange:);
        Method mSBChange = class_getInstanceMethod(cls, selSBChange);
        if (mSBChange) {
            IMP origSBChange = method_getImplementation(mSBChange);
            method_setImplementation(mSBChange, imp_implementationWithBlock(^(id self_, UISearchBar *sb, NSString *searchText) {
                @try {
                    ZXNotePotentialSearchText(searchText ?: sb.text, sb);
                } @catch (__unused NSException *e) {}
                ((void (*)(id, SEL, UISearchBar *, NSString *))origSBChange)(self_, selSBChange, sb, searchText);
            }));
        }

        SEL selSBClick = @selector(searchBarSearchButtonClicked:);
        Method mSBClick = class_getInstanceMethod(cls, selSBClick);
        if (mSBClick) {
            IMP origSBClick = method_getImplementation(mSBClick);
            method_setImplementation(mSBClick, imp_implementationWithBlock(^(id self_, UISearchBar *sb) {
                @try {
                    ZXNotePotentialSearchText(sb.text, sb);
                } @catch (__unused NSException *e) {}
                ((void (*)(id, SEL, UISearchBar *))origSBClick)(self_, selSBClick, sb);
            }));
        }

        SEL selTFReturn = @selector(textFieldShouldReturn:);
        Method mTFReturn = class_getInstanceMethod(cls, selTFReturn);
        if (mTFReturn) {
            IMP origTFReturn = method_getImplementation(mTFReturn);
            method_setImplementation(mTFReturn, imp_implementationWithBlock(^BOOL(id self_, UITextField *tf) {
                @try {
                    ZXNotePotentialSearchText(tf.text, tf);
                } @catch (__unused NSException *e) {}
                return ((BOOL (*)(id, SEL, UITextField *))origTFReturn)(self_, selTFReturn, tf);
            }));
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

static NSArray<UIWindow *> *ZXAllSceneWindows(void)
{
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        @try {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w && ![wins containsObject:w]) [wins addObject:w];
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return wins;
}

static UIWindow *ZXActiveWindow(void)
{
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                if (s.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w.isKeyWindow && w != gSpamOverlayWindow) return w;
                }
            }
            for (UIWindow *win in ZXAllSceneWindows()) {
                if (win != gSpamOverlayWindow && !win.hidden && win.isKeyWindow) return win;
            }
            for (UIWindow *win in ZXAllSceneWindows()) {
                if (win != gSpamOverlayWindow && !win.hidden) return win;
            }
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
+ (void)onSearchInputChanged:(NSNotification *)n;
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
        for (UIWindow *w in ZXAllSceneWindows()) {
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

+ (void)onSearchInputChanged:(NSNotification *)n
{
    @try {
        id obj = n.object;
        if ([obj isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)obj;
            ZXNotePotentialSearchText(tf.text, tf);
        }
    } @catch (NSException *e) {
        ZXLog(@"onSearchInputChanged exception: %@", e.reason);
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
        BOOL hasVoice = [ZXConfig boolForKey:ZXK_VOICE_MSG_TOOLS] && gLastVoiceURL != nil;
        BOOL hasLock = [ZXConfig boolForKey:ZXK_CHAT_LOCK_ENABLED];
        if (!hasVoice && !hasLock) return;

        NSString *chatTitle = @"Hội thoại";

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
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        BOOL looksLikeChat = ([clsName rangeOfString:@"Chat" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"CSC" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"MessageView" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!looksLikeChat) return;

        gActiveChatVC = vc;
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
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onSearchInputChanged:) name:UITextFieldTextDidChangeNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
            [nc addObserver:[ZXUIRuntimeHelper class] selector:@selector(onAppWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];

            ZXTryInstallGlobalSearchHiddenHooks();
            for (NSNumber *delaySec in @[@0.5, @2.0, @5.0]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ZXTryInstallGlobalSearchHiddenHooks();
                });
            }

            // 1. Hook UIViewController -viewDidAppear: for Chat Lock Shield & Spam Overlay hiding
            Method vda = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
            if (vda) {
                IMP origVDA = method_getImplementation(vda);
                method_setImplementation(vda, imp_implementationWithBlock(^(UIViewController *self_, BOOL animated) {
                    @try {
                        ((void (*)(id, SEL, BOOL))origVDA)(self_, @selector(viewDidAppear:), animated);
                        if ([NSStringFromClass([self_ class]) hasPrefix:@"ZX"] && gSpamOverlayWindow) {
                            gSpamOverlayWindow.hidden = YES;
                        }
                        ZXTryInstallGlobalSearchHiddenHooks();
                        ZXAttachLockShieldIfNeeded(self_);
                    } @catch (NSException *e) {
                        ZXLog(@"viewDidAppear hook exception: %@", e.reason);
                    }
                }));
            }

            // 1b. Hook UISearchBar / UITextField ONLY to remember typed 4-6 digit PIN when GlobalSearchLogic confirms hidden results
            Method sbSetDel = class_getInstanceMethod([UISearchBar class], @selector(setDelegate:));
            if (sbSetDel) {
                IMP origSBSetDel = method_getImplementation(sbSetDel);
                method_setImplementation(sbSetDel, imp_implementationWithBlock(^(UISearchBar *self_, id delegate) {
                    ((void (*)(id, SEL, id))origSBSetDel)(self_, @selector(setDelegate:), delegate);
                    @try {
                        if (delegate) ZXSwizzleSearchDelegateClassIfNeeded(delegate);
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method tfSetDel = class_getInstanceMethod([UITextField class], @selector(setDelegate:));
            if (tfSetDel) {
                IMP origTFSetDel = method_getImplementation(tfSetDel);
                method_setImplementation(tfSetDel, imp_implementationWithBlock(^(UITextField *self_, id delegate) {
                    ((void (*)(id, SEL, id))origTFSetDel)(self_, @selector(setDelegate:), delegate);
                    @try {
                        if (delegate) ZXSwizzleSearchDelegateClassIfNeeded(delegate);
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method sbSetText = class_getInstanceMethod([UISearchBar class], @selector(setText:));
            if (sbSetText) {
                IMP origSBSetText = method_getImplementation(sbSetText);
                method_setImplementation(sbSetText, imp_implementationWithBlock(^(UISearchBar *self_, NSString *text) {
                    ((void (*)(id, SEL, NSString *))origSBSetText)(self_, @selector(setText:), text);
                    @try {
                        ZXNotePotentialSearchText(text, self_);
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method tfSetText = class_getInstanceMethod([UITextField class], @selector(setText:));
            if (tfSetText) {
                IMP origTFSetText = method_getImplementation(tfSetText);
                method_setImplementation(tfSetText, imp_implementationWithBlock(^(UITextField *self_, NSString *text) {
                    ((void (*)(id, SEL, NSString *))origTFSetText)(self_, @selector(setText:), text);
                    @try {
                        ZXNotePotentialSearchText(text, self_);
                    } @catch (__unused NSException *e) {}
                }));
            }

            // 2. Hook UITableViewCell -didMoveToWindow ONLY for Chat Lock / Voice Speed long-press quick menu (NO hidden-chat cell scraping!)
            Method dmw = class_getInstanceMethod([UITableViewCell class], @selector(didMoveToWindow));
            if (dmw) {
                IMP origDMW = method_getImplementation(dmw);
                method_setImplementation(dmw, imp_implementationWithBlock(^(UITableViewCell *self_) {
                    @try {
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

+ (NSString *)lastPinSearchIntrospectSnapshot
{
    return sLastGSCaptureLog ?: @"";
}

+ (void)scanMemoryForHiddenChats
{
    if (gSQLiteScanInProgress) {
        gSQLiteRescanRequested = YES;
        return;
    }
    gSQLiteScanInProgress = YES;
    gSQLiteRescanRequested = NO;
    ZXInitHiddenChatsStore();
    ZXTryInstallGlobalSearchHiddenHooks();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSArray<NSDictionary *> *mergedHits = [ZXScanner scanSQLiteForHiddenChats];
            NSMutableSet<NSString *> *activeSQLiteIDs = [NSMutableSet set];
            @synchronized (gHiddenChatsMap) {
                [gHiddenChatsMap removeAllObjects];
                for (NSDictionary *item in mergedHits) {
                    NSString *uid = [item[@"uid"] description] ?: @"";
                    if (uid.length == 0 || ZXIsExcludedOwnerThreadID(uid) ||
                        [ZXScanner isGarbageChatIdentifier:uid] || [sDismissedHiddenKeys containsObject:uid]) {
                        continue;
                    }
                    gHiddenChatsMap[uid] = item;
                    [activeSQLiteIDs addObject:uid];
                }
            }
            // Remove any ownerUID or dismissed entry from v5 cache
            BOOL prunedCache = NO;
            @synchronized (gResolvedProfilesMap) {
                for (NSString *k in [gResolvedProfilesMap allKeys]) {
                    if (ZXIsExcludedOwnerThreadID(k) || [sDismissedHiddenKeys containsObject:k]) {
                        [gResolvedProfilesMap removeObjectForKey:k];
                        prunedCache = YES;
                    } else if (activeSQLiteIDs.count > 0 && ![activeSQLiteIDs containsObject:k]) {
                        // Prune unhidden threadId from v5 cache if older than 30s and no longer in HiddenChatEntity
                        long long ts = [gResolvedProfilesMap[k][@"updatedAt"] longLongValue];
                        long long nowTs = (long long)[[NSDate date] timeIntervalSince1970];
                        if ((nowTs - ts) > 30) {
                            [gResolvedProfilesMap removeObjectForKey:k];
                            prunedCache = YES;
                        }
                    }
                }
            }
            if (prunedCache) {
                ZXSaveResolvedProfilesNow();
            }
        } @catch (NSException *e) {
            ZXLog(@"background SQLite scan exception: %@", e.reason);
        }
        BOOL needAnotherPass = gSQLiteRescanRequested;
        gSQLiteScanInProgress = NO;
        gSQLiteRescanRequested = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXHiddenChatsUpdatedNotification" object:nil];
            if (needAnotherPass) {
                [ZXHookEngine scanMemoryForHiddenChats];
            }
        });
    });
}

+ (void)pruneAndRescanHiddenChats
{
    @try {
        ZXInitHiddenChatsStore();
        NSSet<NSString *> *sqlIDs = [NSSet setWithArray:([ZXScanner currentHiddenChatEntityIDs] ?: @[])];
        @synchronized (gResolvedProfilesMap) {
            for (NSString *k in [gResolvedProfilesMap allKeys]) {
                NSDictionary *prof = [gResolvedProfilesMap[k] isKindOfClass:[NSDictionary class]] ? gResolvedProfilesMap[k] : nil;
                NSString *pName = [prof[@"displayName"] ?: prof[@"name"] ?: @"" description];
                BOOL notInSQL = (sqlIDs.count > 0 && ![sqlIDs containsObject:k]);
                if (!prof || ZXIsExcludedOwnerThreadID(k) || notInSQL ||
                    ![ZXScanner isValidHumanDisplayName:pName excludeUID:k]) {
                    [gResolvedProfilesMap removeObjectForKey:k];
                }
            }
        }
        ZXSaveResolvedProfilesNow();
        [self scanMemoryForHiddenChats];
    } @catch (NSException *e) {
        ZXLog(@"pruneAndRescanHiddenChats exception: %@", e.reason);
    }
}

+ (NSArray<NSDictionary *> *)discoveredHiddenChats
{
    ZXInitHiddenChatsStore();
    @synchronized (gHiddenChatsMap) {
        NSMutableArray<NSDictionary *> *filtered = [NSMutableArray new];
        for (NSDictionary *it in gHiddenChatsMap.allValues) {
            NSString *uid = [it[@"uid"] description] ?: @"";
            if (uid.length == 0 || ZXIsExcludedOwnerThreadID(uid) ||
                [ZXScanner isGarbageChatIdentifier:uid] || [sDismissedHiddenKeys containsObject:uid]) {
                continue;
            }
            [filtered addObject:it];
        }
        [filtered sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL va = [a[@"verified"] boolValue];
            BOOL vb = [b[@"verified"] boolValue];
            if (va != vb) return va ? NSOrderedAscending : NSOrderedDescending;
            return [(a[@"name"] ?: @"") localizedCaseInsensitiveCompare:(b[@"name"] ?: @"")];
        }];
        return filtered;
    }
}

+ (void)removeHiddenChatEntryWithID:(NSString *)chatID
{
    if (chatID.length == 0) return;
    @try {
        ZXInitHiddenChatsStore();
        @synchronized (gHiddenChatsMap) {
            [sDismissedHiddenKeys addObject:chatID];
            [[NSUserDefaults standardUserDefaults] setObject:sDismissedHiddenKeys.allObjects forKey:@"zx_dismissed_hidden_keys"];
            [gHiddenChatsMap removeObjectForKey:chatID];
        }
        @synchronized (gResolvedProfilesMap) {
            [gResolvedProfilesMap removeObjectForKey:chatID];
        }
        ZXSaveResolvedProfilesNow();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXHiddenChatsUpdatedNotification" object:nil];
        });
    } @catch (NSException *e) {
        ZXLog(@"removeHiddenChatEntryWithID exception: %@", e.reason);
    }
}

+ (void)clearResolvedNamesCache
{
    @try {
        ZXInitHiddenChatsStore();
        @synchronized (gResolvedProfilesMap) {
            [gResolvedProfilesMap removeAllObjects];
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in ZXAllStoreCandidatePaths(@"zx_resolved_profiles.json")) {
            if (p.length && [fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:nil];
        }
        for (NSString *hp in ZXAllStoreCandidatePaths(@"hidden_chats.json")) {
            if (hp.length && [fm fileExistsAtPath:hp]) [fm removeItemAtPath:hp error:nil];
        }

        @synchronized (gHiddenChatsMap) {
            [sUnhiddenThreadIDs removeAllObjects];
            [sDismissedHiddenKeys removeAllObjects];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"nthe_unhidden_thread_ids"];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"zx_dismissed_hidden_keys"];
            [gHiddenChatsMap removeAllObjects];
        }
        [self scanMemoryForHiddenChats];
    } @catch (NSException *e) {
        ZXLog(@"clearResolvedNamesCache exception: %@", e.reason);
    }
}

+ (void)clearResolvedNameForID:(NSString *)chatID
{
    if (chatID.length == 0) return;
    @try {
        ZXInitHiddenChatsStore();
        @synchronized (gResolvedProfilesMap) {
            [gResolvedProfilesMap removeObjectForKey:chatID];
        }
        ZXSaveResolvedProfilesNow();

        @synchronized (gHiddenChatsMap) {
            if (gHiddenChatsMap[chatID]) {
                gHiddenChatsMap[chatID] = @{
                    @"uid": chatID,
                    @"threadId": chatID,
                    @"rawName": @"",
                    @"name": [NSString stringWithFormat:@"Hội thoại ẩn (ID: %@)", chatID],
                    @"subtitle": @"",
                    @"lastMessage": @"Gõ mã PIN ẩn 1 lần trên thanh Tìm kiếm Zalo để tự động hiện đủ 100% tên thật",
                    @"hiddenSource": @"HiddenChatEntity",
                    @"verified": @NO,
                    @"modelVerified": @NO,
                    @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                };
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXHiddenChatsUpdatedNotification" object:nil];
        });
    } @catch (NSException *e) {
        ZXLog(@"clearResolvedNameForID exception: %@", e.reason);
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
    }
    @synchronized (gResolvedProfilesMap) {
        [gResolvedProfilesMap removeObjectForKey:chatID];
    }
    ZXSaveResolvedProfilesNow();
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

    void (^performOpenOnMain)(void) = ^{
        @try {
            ZXInitHiddenChatsStore();
            ZXTryInstallGlobalSearchHiddenHooks();

            NSString *cleanName = [displayName ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            BOOL hasRealName = [ZXScanner isValidHumanDisplayName:cleanName excludeUID:chatID];

            UIWindow *win = ZXActiveWindow();
            if (!win) return;

            // 1. Switch Zalo's main UITabBarController to selectedIndex = 0 (Messages tab)
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

            // 2. Activate Zalo's Search bar at top of Messages tab
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

            // 3. STRICT RULE: ONLY fill saved hidden PIN (`zx_saved_hidden_pin`) or leave empty — NEVER fill threadid!
            NSString *savedPin = [[[NSUserDefaults standardUserDefaults] stringForKey:@"zx_saved_hidden_pin"]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            BOOL hasSavedPin = ZXIsPinCodeString(savedPin);
            if (hasSavedPin) {
                sCandidateTypedPIN = savedPin;
                sCandidatePinTypedTime = CFAbsoluteTimeGetCurrent();
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    UIWindow *curWin = ZXActiveWindow() ?: win;
                    if (!curWin) return;

                    UIView *firstResp = ZXFindFirstResponderInView(curWin);
                    UISearchBar *sb = [firstResp isKindOfClass:[UISearchBar class]] ? (UISearchBar *)firstResp : ZXFindSearchBarInView(curWin);
                    UITextField *tf = [firstResp isKindOfClass:[UITextField class]] ? (UITextField *)firstResp : ZXFindSearchTextFieldInView(curWin);

                    NSString *pinToFill = hasSavedPin ? savedPin : nil;
                    NSString *toastMessage = hasSavedPin
                        ? (hasRealName
                            ? [NSString stringWithFormat:@"Đã điền mã PIN ẩn — chạm vào \"%@\" để mở chat", cleanName]
                            : @"Đã điền mã PIN ẩn — chạm vào cuộc trò chuyện để mở")
                        : @"Nhập mã PIN ẩn 1 lần tại đây để mở khóa & tự động điền tên thật";

                    if (sb) {
                        if (!sb.isFirstResponder) [sb becomeFirstResponder];
                        if (pinToFill != nil) {
                            sb.text = pinToFill;
                            if ([sb.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
                                [sb.delegate searchBar:sb textDidChange:pinToFill];
                            }
                        } else {
                            sb.text = @"";
                        }
                    }
                    if (tf) {
                        if (!tf.isFirstResponder) [tf becomeFirstResponder];
                        tf.text = @"";
                        if (pinToFill != nil) {
                            [tf insertText:pinToFill];
                            if (tf.text.length == 0) tf.text = pinToFill;
                            if ([tf.delegate respondsToSelector:@selector(textField:shouldChangeCharactersInRange:replacementString:)]) {
                                [tf.delegate textField:tf shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:pinToFill];
                            }
                            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                            [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
                        }
                    }

                    ZXShowBottomBannerOnWindow(curWin, toastMessage);
                } @catch (NSException *ex) {
                    ZXLog(@"openChatWithID search fill exception: %@", ex.reason);
                }
            });
        } @catch (NSException *ex) {
            ZXLog(@"openChatWithID exception: %@", ex.reason);
        }
    };

    if ([NSThread isMainThread]) {
        performOpenOnMain();
    } else {
        dispatch_async(dispatch_get_main_queue(), performOpenOnMain);
    }
    return YES;
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
