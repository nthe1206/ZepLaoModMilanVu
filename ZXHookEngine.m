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
static NSMutableDictionary<NSString *, NSDictionary *> *sSessionHiddenChatsMap;
static BOOL gProfilesSaveScheduled;
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

// Hide-chat real name capture state (Cách 1: Swipe/LongPress, Cách 2: Chat Options Switch, Cách 3: PIN Search Capture)
static NSString *sCandidateChatName;
static NSString *sCandidateLastMsg;
static NSString *sCandidateChatUID;
static NSString *sCurrentOpenChatName;
static NSString *sCurrentOpenChatUID;
static NSSet<NSString *> *sHiddenIDsBeforeAction;
static NSMutableSet<NSString *> *sSwizzledTableDelegates;
static NSMutableSet<NSString *> *sSwizzledTableDataSources;
static NSMutableSet<NSString *> *sSwizzledCollectionDelegates;
static NSMutableSet<NSString *> *sSwizzledCollectionDataSources;
static NSMutableSet<NSString *> *sSwizzledSearchDelegates;
static NSString *sCandidateTypedPIN;
static double sCandidatePinTypedTime = 0.0;
static NSString *sPendingResolveTargetUID;
static BOOL sAwaitingPinSearchResult = NO;
static NSInteger sPinVerifyGen = 0;

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

static BOOL ZXIsAllowedHiddenSource(NSString *src)
{
    if (!src || src.length == 0) return YES;
    return ([src isEqualToString:@"HiddenChatEntity"] ||
            [src isEqualToString:@"HideAction"] ||
            [src isEqualToString:@"PinSearch"] ||
            [src isEqualToString:@"SavedHiddenStore"]);
}

static NSArray<NSString *> *ZXAllStoreCandidatePaths(NSString *fileName)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    if (!fileName.length) return paths;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *cfgDir = [ZXConfig dataDir];
    for (NSString *dir in @[docs ?: @"", cfgDir ?: @"", caches ?: @"", (caches.length ? [caches stringByAppendingPathComponent:@"ZaloXposed"] : @"")]) {
        if (dir.length == 0) continue;
        NSString *p = [dir stringByAppendingPathComponent:fileName];
        if (![paths containsObject:p]) [paths addObject:p];
    }
    return paths;
}

static void ZXInitHiddenChatsStore(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gBgTask = UIBackgroundTaskInvalid;
        gHiddenChatsMap = [NSMutableDictionary new];
        gResolvedProfilesMap = [NSMutableDictionary new];
        sSessionHiddenChatsMap = [NSMutableDictionary new];
        gUnlockedSessionChats = [NSMutableSet new];
        NSArray *savedUnhidden = [[NSUserDefaults standardUserDefaults] arrayForKey:@"nthe_unhidden_thread_ids"];
        sUnhiddenThreadIDs = [NSMutableSet setWithArray:(savedUnhidden ?: @[])];
        NSArray *savedDismissed = [[NSUserDefaults standardUserDefaults] arrayForKey:@"zx_dismissed_hidden_keys"];
        sDismissedHiddenKeys = [NSMutableSet setWithArray:(savedDismissed ?: @[])];
        @try {
            for (NSString *profPath in ZXAllStoreCandidatePaths(@"zx_resolved_profiles.json")) {
                NSData *pData = [NSData dataWithContentsOfFile:profPath];
                if (!pData) continue;
                id pDict = [NSJSONSerialization JSONObjectWithData:pData options:0 error:nil];
                if ([pDict isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *rawMap = (NSDictionary *)pDict;
                    for (NSString *k in rawMap) {
                        if ([k hasPrefix:@"_"] || [sDismissedHiddenKeys containsObject:k] || [ZXScanner isGarbageChatIdentifier:k]) continue;
                        NSDictionary *val = [rawMap[k] isKindOfClass:[NSDictionary class]] ? rawMap[k] : nil;
                        if (!val) continue;
                        if ([k hasPrefix:@"pin:"] && ![val[@"inHiddenSection"] boolValue]) continue;
                        NSString *nm = [val[@"name"] description] ?: @"";
                        if (nm.length > 0 && ![ZXScanner isValidHumanDisplayName:nm excludeUID:k]) continue;
                        gResolvedProfilesMap[k] = val;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
        @try {
            for (NSString *hcPath in ZXAllStoreCandidatePaths(@"hidden_chats.json")) {
                NSData *d = [NSData dataWithContentsOfFile:hcPath];
                if (!d) continue;
                id arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([arr isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *item in arr) {
                        if (![item isKindOfClass:[NSDictionary class]]) continue;
                        NSString *uid = [item[@"uid"] description];
                        if (uid.length == 0 || [ZXScanner isGarbageChatIdentifier:uid] || [sDismissedHiddenKeys containsObject:uid]) continue;
                        if ([uid hasPrefix:@"pin:"] && ![item[@"inHiddenSection"] boolValue]) continue;
                        NSString *rName = [item[@"rawName"] description] ?: @"";
                        if (rName.length > 0 && ![ZXScanner isValidHumanDisplayName:rName excludeUID:uid]) continue;
                        if ([sUnhiddenThreadIDs containsObject:uid]) continue;
                        gHiddenChatsMap[uid] = item;
                    }
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
        NSData *d = [NSJSONSerialization dataWithJSONObject:(snap ?: @{}) options:0 error:nil];
        if (d) [d writeToFile:[ZXScanner resolvedProfilesPath] atomically:YES];
    } @catch (__unused NSException *e) {}
}

static void ZXScheduleSaveResolvedProfiles(void)
{
    if (gProfilesSaveScheduled) return;
    gProfilesSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized (gResolvedProfilesMap) {
            gProfilesSaveScheduled = NO;
        }
        ZXSaveResolvedProfilesNow();
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

/// Records a STRICTLY VERIFIED hidden chat profile with an explicit source tag ("HiddenChatEntity" | "HideAction" | "PinSearch").
static void ZXRecordVerifiedHiddenProfile(NSString *uid, NSString *name, NSString *lastMsg, NSString *sourceTag)
{
    if (uid.length < 4 || [ZXScanner isGarbageChatIdentifier:uid]) return;
    if (![ZXScanner isValidHumanDisplayName:name excludeUID:uid]) return;
    if ([ZXScanner isGarbageChatIdentifier:lastMsg]) lastMsg = @"";
    NSString *validSource = ZXIsAllowedHiddenSource(sourceTag) ? sourceTag : @"PinSearch";
    BOOL inHiddenSec = [validSource isEqualToString:@"PinSearch"];

    ZXInitHiddenChatsStore();
    if ([sDismissedHiddenKeys containsObject:uid] && ![validSource isEqualToString:@"HideAction"]) {
        return;
    }
    if ([validSource isEqualToString:@"HideAction"] && [sDismissedHiddenKeys containsObject:uid]) {
        [sDismissedHiddenKeys removeObject:uid];
        [[NSUserDefaults standardUserDefaults] setObject:sDismissedHiddenKeys.allObjects forKey:@"zx_dismissed_hidden_keys"];
    }

    NSString *cleanDigits = [[uid componentsSeparatedByCharactersInSet:
                             [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    NSString *mergedMsg = lastMsg ?: @"";
    long long nowTs = (long long)[[NSDate date] timeIntervalSince1970];

    @synchronized (gResolvedProfilesMap) {
        NSDictionary *old = gResolvedProfilesMap[uid] ?: (cleanDigits.length >= 5 ? gResolvedProfilesMap[cleanDigits] : nil);
        if (mergedMsg.length == 0 && [old isKindOfClass:[NSDictionary class]]) {
            mergedMsg = old[@"lastMessage"] ?: @"";
        }

        NSDictionary *entry = @{
            @"uid": uid,
            @"name": name,
            @"lastMessage": mergedMsg,
            @"isHidden": @YES,
            @"verified": @YES,
            @"inHiddenSection": @(inHiddenSec),
            @"hiddenSource": validSource,
            @"timestamp": @(nowTs)
        };
        gResolvedProfilesMap[uid] = entry;
        if (cleanDigits.length >= 5 && ![cleanDigits isEqualToString:uid]) {
            gResolvedProfilesMap[cleanDigits] = entry;
        }
    }
    ZXScheduleSaveResolvedProfiles();

    BOOL updatedHiddenStore = NO;
    @synchronized (gHiddenChatsMap) {
        NSString *matchedKey = nil;
        if (gHiddenChatsMap[uid]) matchedKey = uid;
        else if (cleanDigits.length >= 5 && gHiddenChatsMap[cleanDigits]) matchedKey = cleanDigits;

        if (![sUnhiddenThreadIDs containsObject:uid]) {
            NSString *storeKey = matchedKey ?: uid;
            BOOL isSynthetic = ([storeKey hasPrefix:@"pin:"] || [storeKey hasPrefix:@"hide:"]);
            NSString *displayTitle = isSynthetic ? name : [NSString stringWithFormat:@"%@ (ID: %@)", name, storeKey];
            NSDictionary *hiddenEntry = @{
                @"uid": storeKey,
                @"rawName": name,
                @"name": displayTitle,
                @"lastMessage": mergedMsg.length > 0 ? mergedMsg : @"Đã xác thực tên thật",
                @"hiddenSource": validSource,
                @"inHiddenSection": @(inHiddenSec),
                @"verified": @YES,
                @"updatedAt": @(nowTs)
            };
            if (!isSynthetic) {
                NSString *synPin = [NSString stringWithFormat:@"pin:%@", name];
                NSString *synHide = [NSString stringWithFormat:@"hide:%@", name];
                [gHiddenChatsMap removeObjectForKey:synPin];
                [gHiddenChatsMap removeObjectForKey:synHide];
                [sSessionHiddenChatsMap removeObjectForKey:synPin];
                [sSessionHiddenChatsMap removeObjectForKey:synHide];
            }
            gHiddenChatsMap[storeKey] = hiddenEntry;
            if ([validSource isEqualToString:@"HideAction"] || [validSource isEqualToString:@"PinSearch"]) {
                sSessionHiddenChatsMap[storeKey] = hiddenEntry;
            }
            ZXSaveHiddenChatsStore();
            updatedHiddenStore = YES;
        }
    }
    if (updatedHiddenStore) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXHiddenChatsUpdatedNotification" object:nil];
        });
    }
}

// ---- Hide-Chat Real Name Capture (Cách 1: Swipe/LongPress, Cách 2: Chat Options Switch, Cách 3: PIN Search Capture) ----

static UIViewController *ZXNearestViewControllerForView(UIView *view);
static UISearchBar *ZXFindSearchBarInView(UIView *v);
static UITextField *ZXFindSearchTextFieldInView(UIView *v);

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

static BOOL ZXIsPureDigitsString(NSString *raw)
{
    if (!raw) return NO;
    NSString *trim = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length == 0) return NO;
    NSString *rem = [trim stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
    return (rem.length == 0);
}

static BOOL ZXIsLikelyTimestampOrBadge(NSString *text)
{
    if (text.length == 0) return YES;
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length == 0) return YES;
    if (ZXIsPureDigitsString(trim)) return YES;
    NSString *lc = trim.lowercaseString;
    if (trim.length <= 6 && ([lc containsString:@":"] || [lc hasSuffix:@"p"] || [lc hasSuffix:@"g"] || [lc hasSuffix:@"+"])) {
        return YES;
    }
    // Date formats like 12/11, 12/11/2026, 12-11
    if (trim.length <= 10 && ([trim containsString:@"/"] || [trim containsString:@"-"])) {
        NSCharacterSet *dateChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789/- "];
        if ([[trim stringByTrimmingCharactersInSet:dateChars] length] == 0) return YES;
    }
    if ([lc hasSuffix:@" phút"] || [lc hasSuffix:@" giờ"] || [lc hasSuffix:@" ngày"] || [lc hasSuffix:@" tuần"] ||
        [lc isEqualToString:@"vừa xong"] || [lc isEqualToString:@"hôm qua"] || [lc isEqualToString:@"hôm nay"] ||
        [lc isEqualToString:@"yesterday"] || [lc isEqualToString:@"today"]) {
        return YES;
    }
    return NO;
}

static CGFloat ZXLabelProminenceScore(UILabel *lbl)
{
    if (!lbl || !lbl.font) return 14.0;
    CGFloat score = lbl.font.pointSize;
    UIFontDescriptorSymbolicTraits traits = lbl.font.fontDescriptor.symbolicTraits;
    if ((traits & UIFontDescriptorTraitBold) != 0) {
        score += 2.5;
    } else {
        NSString *fn = (lbl.font.fontName ?: @"").lowercaseString;
        if ([fn containsString:@"bold"] || [fn containsString:@"heavy"] || [fn containsString:@"black"]) score += 2.5;
        else if ([fn containsString:@"semibold"] || [fn containsString:@"demi"] || [fn containsString:@"medium"]) score += 1.2;
    }
    return score;
}

static void ZXCollectRankedLabels(UIView *v, NSMutableArray<UILabel *> *outLabels, int depth)
{
    if (!v || v.hidden || v.alpha < 0.05 || depth > 6 || outLabels.count >= 20) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *t = [lbl.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length >= 2 && !ZXIsLikelyTimestampOrBadge(t) && ![ZXScanner isGarbageChatIdentifier:t]) {
            [outLabels addObject:lbl];
        }
    }
    for (UIView *sub in v.subviews) {
        ZXCollectRankedLabels(sub, outLabels, depth + 1);
    }
}

static void ZXExtractBestNameAndMsgFromCell(UIView *cell, NSString **outName, NSString **outMsg, NSString **outUID)
{
    if (!cell) return;
    NSString *foundUID = @"";
    @try {
        for (NSString *prop in @[@"chatEntity", @"item", @"chatItem", @"entity", @"model", @"contact", @"user", @"thread", @"conversation", @"viewModel", @"data", @"chatObject", @"searchResult", @"result", @"profile"]) {
            if ([cell respondsToSelector:NSSelectorFromString(prop)]) {
                id m = [cell valueForKey:prop];
                if (!m) continue;
                NSString *u = ZXReadStringKVC(m, @[@"userId", @"uid", @"threadId", @"conversationId", @"contactId", @"friendId", @"groupId", @"chatId", @"targetId", @"zaloId", @"entityId"]);
                if (u.length >= 4 && ![ZXScanner isGarbageChatIdentifier:u]) {
                    foundUID = u;
                    break;
                }
                for (NSString *subProp in @[@"contact", @"user", @"thread", @"chatEntity", @"conversation", @"entity", @"item", @"model"]) {
                    if ([m respondsToSelector:NSSelectorFromString(subProp)]) {
                        id sm = [m valueForKey:subProp];
                        if (sm) {
                            NSString *u2 = ZXReadStringKVC(sm, @[@"userId", @"uid", @"threadId", @"conversationId", @"contactId", @"friendId", @"groupId", @"chatId"]);
                            if (u2.length >= 4 && ![ZXScanner isGarbageChatIdentifier:u2]) {
                                foundUID = u2;
                                break;
                            }
                        }
                    }
                }
                if (foundUID.length >= 4) break;
            }
        }

        UIView *scanRoot = cell;
        if ([cell isKindOfClass:[UITableViewCell class]] && ((UITableViewCell *)cell).contentView.subviews.count > 0) {
            scanRoot = ((UITableViewCell *)cell).contentView;
        } else if ([cell isKindOfClass:[UICollectionViewCell class]] && ((UICollectionViewCell *)cell).contentView.subviews.count > 0) {
            scanRoot = ((UICollectionViewCell *)cell).contentView;
        }

        NSMutableArray<UILabel *> *labels = [NSMutableArray new];
        ZXCollectRankedLabels(scanRoot, labels, 0);
        if (labels.count == 0 && scanRoot != cell) {
            ZXCollectRankedLabels(cell, labels, 0);
        }

        CGFloat cellH = MAX(1.0, cell.bounds.size.height);
        [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
            CGFloat ya = [a convertPoint:CGPointZero toView:cell].y;
            CGFloat yb = [b convertPoint:CGPointZero toView:cell].y;
            BOOL aTopHalf = (ya <= cellH * 0.56);
            BOOL bTopHalf = (yb <= cellH * 0.56);
            if (aTopHalf != bTopHalf) return aTopHalf ? NSOrderedAscending : NSOrderedDescending;
            CGFloat sa = ZXLabelProminenceScore(a);
            CGFloat sb = ZXLabelProminenceScore(b);
            if (fabs(sa - sb) >= 0.7) return (sa > sb) ? NSOrderedAscending : NSOrderedDescending;
            return (ya < yb) ? NSOrderedAscending : NSOrderedDescending;
        }];

        NSString *bestName = @"";
        NSString *bestMsg = @"";
        for (UILabel *lbl in labels) {
            NSString *t = [lbl.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (bestName.length == 0 && [ZXScanner isValidHumanDisplayName:t excludeUID:foundUID]) {
                bestName = t;
            } else if (bestName.length > 0 && bestMsg.length == 0 && ![t isEqualToString:bestName] && !ZXIsLikelyTimestampOrBadge(t)) {
                bestMsg = t;
                break;
            }
        }

        if (outName) *outName = bestName;
        if (outMsg) *outMsg = bestMsg;
        if (outUID) *outUID = foundUID;
    } @catch (__unused NSException *e) {}
}

static void ZXCaptureCandidateFromCell(UIView *cell)
{
    if (!cell) return;
    @try {
        NSString *candName = @"";
        NSString *candMsg = @"";
        NSString *foundUID = @"";
        ZXExtractBestNameAndMsgFromCell(cell, &candName, &candMsg, &foundUID);

        if (candName.length > 0) {
            sCandidateChatName = candName;
            sCandidateLastMsg = candMsg;
            sCandidateChatUID = foundUID;
            ZXLog(@"Captured swipe/longpress candidate: '%@' (uid=%@)", candName, foundUID);

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSArray<NSString *> *ids = [ZXScanner currentHiddenChatEntityIDs];
                sHiddenIDsBeforeAction = [NSSet setWithArray:ids ?: @[]];
            });
        }
    } @catch (__unused NSException *e) {}
}

static void ZXNotePotentialSearchText(NSString *text, UIView *sourceView)
{
    @try {
        if (sourceView) {
            UIViewController *vc = ZXNearestViewControllerForView(sourceView);
            if (vc && [NSStringFromClass([vc class]) hasPrefix:@"ZX"]) return;
        }
        NSString *trim = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ZXIsPinCodeString(trim)) {
            sCandidateTypedPIN = trim;
            sCandidatePinTypedTime = CFAbsoluteTimeGetCurrent();
        } else if (trim.length > 6) {
            // Normal non-PIN text search -> clear PIN candidate immediately so normal search rows are never treated as PIN results!
            sCandidateTypedPIN = nil;
            sCandidatePinTypedTime = 0.0;
        }
    } @catch (__unused NSException *e) {}
}

static NSString *ZXCurrentPinInWindow(UIWindow *win)
{
    if (!win) return @"";
    @try {
        UISearchBar *sb = ZXFindSearchBarInView(win);
        if (sb && ZXIsPinCodeString(sb.text)) {
            return [sb.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        UITextField *tf = ZXFindSearchTextFieldInView(win);
        if (tf && ZXIsPinCodeString(tf.text)) {
            return [tf.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    } @catch (__unused NSException *e) {}
    return @"";
}

static BOOL ZXShouldSkipSwizzleForClassName(NSString *clsName)
{
    if (!clsName || clsName.length == 0) return YES;
    if ([clsName hasPrefix:@"ZX"] || [clsName hasPrefix:@"UI"] || [clsName hasPrefix:@"_UI"] || [clsName hasPrefix:@"__UI"] || [clsName hasPrefix:@"NS"]) {
        return YES;
    }
    // IMPORTANT: Do NOT skip "_TtC..." / "_TtGC..." Swift classes in Zalo iOS 26.11!
    return NO;
}

static BOOL ZXIsSearchListContainer(UIView *listView)
{
    if (!listView || !listView.window || listView.hidden || listView.alpha < 0.05) return NO;
    @try {
        UIViewController *vc = ZXNearestViewControllerForView(listView);
        while (vc) {
            NSString *cls = NSStringFromClass([vc class]);
            if ([cls hasPrefix:@"ZX"]) return NO;
            if ([cls rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [cls rangeOfString:@"Find" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [cls rangeOfString:@"Pin" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [cls rangeOfString:@"Hidden" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
            vc = vc.parentViewController;
        }
        // Support Swift / custom Zalo search overlays: if a 4-6 digit PIN is actively in the window's Search input right now,
        // verify listView is the topmost visible table/collection view in the window (above the underlying main tab list).
        if (ZXIsPinCodeString(ZXCurrentPinInWindow(listView.window))) {
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

/// Classifies section header titles in Zalo Search:
/// 1 = "Trò chuyện ẩn" / "Hidden chats" header
/// 2 = Other section header ("Tin nhắn (x)", "Liên hệ", "Gợi ý", "Link", "File", "Bạn bè", "Nhóm", "OA"...)
/// 0 = Normal cell content
static int ZXClassifySearchSectionHeader(NSString *raw)
{
    if (!raw || raw.length < 2 || raw.length > 42) return 0;
    NSString *lc = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (lc.length == 0) return 0;

    if ([lc isEqualToString:@"trò chuyện ẩn"] || [lc hasPrefix:@"trò chuyện ẩn ("] || [lc hasPrefix:@"trò chuyện ẩn:"] ||
        [lc isEqualToString:@"hội thoại ẩn"] || [lc hasPrefix:@"hội thoại ẩn ("] ||
        [lc isEqualToString:@"hidden chats"] || [lc hasPrefix:@"hidden chats ("] ||
        [lc isEqualToString:@"hidden conversations"] || [lc hasPrefix:@"hidden chat"]) {
        return 1;
    }

    NSArray<NSString *> *otherPrefixes = @[
        @"tin nhắn", @"messages", @"liên hệ", @"danh bạ", @"contacts",
        @"gợi ý", @"tìm kiếm gần đây", @"liên hệ gần đây",
        @"bạn bè", @"nhóm", @"link", @"liên kết", @"file", @"tệp",
        @"ảnh & video", @"khám phá", @"official account", @"mini app"
    ];
    for (NSString *pfx in otherPrefixes) {
        if ([lc isEqualToString:pfx] ||
            [lc hasPrefix:[pfx stringByAppendingString:@" ("]] ||
            [lc hasPrefix:[pfx stringByAppendingString:@":"]]) {
            return 2;
        }
    }
    if ([lc isEqualToString:@"oa"] || [lc hasPrefix:@"oa ("]) return 2;
    return 0;
}

static void ZXCollectSectionHeaderAnchors(UIView *v, UIView *listView, NSMutableArray<NSDictionary *> *outAnchors, int depth)
{
    if (!v || v.hidden || v.alpha < 0.05 || depth > 5 || outAnchors.count >= 40) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        int kind = ZXClassifySearchSectionHeader(lbl.text);
        if (kind > 0) {
            CGRect r = [lbl convertRect:lbl.bounds toView:listView];
            // Header titles sit near the left margin of the table/collection view
            if (r.origin.x <= listView.bounds.size.width * 0.45 && r.size.height > 0) {
                [outAnchors addObject:@{
                    @"kind": @(kind),
                    @"topY": @(r.origin.y),
                    @"bottomY": @(CGRectGetMaxY(r))
                }];
            }
        }
        return;
    }
    for (UIView *sub in v.subviews) {
        ZXCollectSectionHeaderAnchors(sub, listView, outAnchors, depth + 1);
    }
}

/// Computes the exact [minY, maxY] coordinate band in listView belonging strictly to the "Trò chuyện ẩn" section.
/// Returns NO if no "Trò chuyện ẩn" section header exists on screen (preventing "Tin nhắn (x)" with "1206" from ever leaking in!).
static BOOL ZXFindHiddenChatsSectionYBounds(UIView *listView, CGFloat *outMinY, CGFloat *outMaxY)
{
    if (!listView) return NO;
    @try {
        // 1. Check UITableView dataSource titleForHeaderInSection: if implemented
        if ([listView isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)listView;
            id<UITableViewDataSource> ds = tv.dataSource;
            if (ds && [ds respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
                NSInteger secs = [tv numberOfSections];
                for (NSInteger s = 0; s < secs; s++) {
                    NSString *hTitle = [ds tableView:tv titleForHeaderInSection:s];
                    if (ZXClassifySearchSectionHeader(hTitle) == 1) {
                        CGRect secRect = [tv rectForSection:s];
                        if (secRect.size.height > 0) {
                            if (outMinY) *outMinY = secRect.origin.y;
                            if (outMaxY) *outMaxY = CGRectGetMaxY(secRect);
                            return YES;
                        }
                    }
                }
            }
        }

        // 2. Scan all visible header views & header cells inside listView by Y coordinate
        NSMutableArray<NSDictionary *> *anchors = [NSMutableArray new];
        for (UIView *sub in listView.subviews) {
            ZXCollectSectionHeaderAnchors(sub, listView, anchors, 0);
        }
        if (anchors.count == 0) return NO;

        [anchors sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            CGFloat ya = [a[@"topY"] doubleValue];
            CGFloat yb = [b[@"topY"] doubleValue];
            return (ya < yb) ? NSOrderedAscending : ((ya > yb) ? NSOrderedDescending : NSOrderedSame);
        }];

        BOOL foundHiddenHeader = NO;
        CGFloat hiddenBottomY = 0.0;
        CGFloat nextSectionTopY = CGFLOAT_MAX;

        for (NSDictionary *anc in anchors) {
            int kind = [anc[@"kind"] intValue];
            CGFloat topY = [anc[@"topY"] doubleValue];
            CGFloat bottomY = [anc[@"bottomY"] doubleValue];
            if (!foundHiddenHeader) {
                if (kind == 1) {
                    foundHiddenHeader = YES;
                    hiddenBottomY = bottomY;
                }
            } else {
                // Stop immediately at the next section header ("Tin nhắn (x)", "Liên hệ", "Link", "File"...)
                if (kind == 2 && topY > hiddenBottomY + 2.0) {
                    nextSectionTopY = topY;
                    break;
                }
            }
        }

        if (!foundHiddenHeader) return NO;
        if (outMinY) *outMinY = hiddenBottomY - 2.0;
        if (outMaxY) *outMaxY = nextSectionTopY;
        return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

static BOOL ZXIsCellStrictlyInsideHiddenSection(UIView *cell, UIView *listView, CGFloat minY, CGFloat maxY)
{
    if (!cell || !listView) return NO;
    // Reject if the cell itself is a section header cell ("Trò chuyện ẩn (x)", "Tin nhắn (x)"...)
    NSMutableArray<NSDictionary *> *selfHeaders = [NSMutableArray new];
    ZXCollectSectionHeaderAnchors(cell, listView, selfHeaders, 0);
    if (selfHeaders.count > 0) return NO;

    CGRect cellRect = [cell convertRect:cell.bounds toView:listView];
    CGFloat midY = CGRectGetMidY(cellRect);
    return (midY > minY && midY < maxY);
}

/// Strictly handles ONLY a cell tapped inside the "Trò chuyện ẩn" section after entering a 4-6 digit PIN.
static void ZXHandleSelectedPinResultCell(UIView *cell, UIView *listView)
{
    if (!cell || !listView) return;
    @try {
        if (!ZXIsSearchListContainer(listView)) return;

        NSString *activeWindowPin = ZXCurrentPinInWindow(listView.window);
        double elapsedSincePin = CFAbsoluteTimeGetCurrent() - sCandidatePinTypedTime;
        BOOL verifiedPinActive = (activeWindowPin.length >= 4) || (sCandidateTypedPIN.length >= 4 && elapsedSincePin >= 0.0 && elapsedSincePin <= 15.0);
        if (!verifiedPinActive) return;

        // STRICT SECTION ISOLATION: cell MUST lie inside the "Trò chuyện ẩn" section (never under "Tin nhắn (x)"!)
        CGFloat secMinY = 0.0, secMaxY = 0.0;
        if (!ZXFindHiddenChatsSectionYBounds(listView, &secMinY, &secMaxY)) return;
        if (!ZXIsCellStrictlyInsideHiddenSection(cell, listView, secMinY, secMaxY)) return;

        NSString *displayName = @"";
        NSString *lastMsg = @"";
        NSString *cellUID = @"";
        ZXExtractBestNameAndMsgFromCell(cell, &displayName, &lastMsg, &cellUID);
        if (![ZXScanner isValidHumanDisplayName:displayName excludeUID:cellUID]) return;

        NSString *confirmedPin = activeWindowPin.length >= 4 ? activeWindowPin : sCandidateTypedPIN;
        if (ZXIsPinCodeString(confirmedPin)) {
            [[NSUserDefaults standardUserDefaults] setObject:confirmedPin forKey:@"zx_saved_hidden_pin"];
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @try {
                NSArray<NSString *> *hiddenIDs = [ZXScanner currentHiddenChatEntityIDs];
                NSSet<NSString *> *hiddenSet = [NSSet setWithArray:hiddenIDs ?: @[]];

                // Only attach to a numeric ID if cellUID genuinely matches HiddenChatEntity (NEVER blind force-link an old lone ID!)
                if (cellUID.length >= 4 && ([hiddenSet containsObject:cellUID] || ![ZXScanner isGarbageChatIdentifier:cellUID])) {
                    ZXRecordVerifiedHiddenProfile(cellUID, displayName, lastMsg, @"PinSearch");
                } else {
                    NSString *pinKey = [NSString stringWithFormat:@"pin:%@", displayName];
                    ZXRecordVerifiedHiddenProfile(pinKey, displayName, lastMsg, @"PinSearch");
                }
                sPendingResolveTargetUID = nil;
                sAwaitingPinSearchResult = NO;
                ZXSaveResolvedProfilesNow();
            } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
}

/// Debounced check AFTER Search table/collection finishes rendering when a 4-6 digit PIN is actively in the Search bar.
/// STRICTLY collects ONLY cells inside the "Trò chuyện ẩn" section (after "Trò chuyện ẩn" and before "Tin nhắn"/"Liên hệ"/"Link"/"File").
static void ZXScheduleVerifySinglePinResultInList(UIView *listView)
{
    if (!listView || !listView.window) return;
    @try {
        if (!ZXIsSearchListContainer(listView)) return;
        NSString *activePin = ZXCurrentPinInWindow(listView.window);
        if (!ZXIsPinCodeString(activePin)) return;

        NSInteger myGen = ++sPinVerifyGen;
        __weak UIView *weakList = listView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (myGen != sPinVerifyGen) return;
                UIView *strongList = weakList;
                if (!strongList || !strongList.window) return;

                // Re-verify the 4-6 digit PIN is STILL in Zalo's search input right now!
                NSString *stillPin = ZXCurrentPinInWindow(strongList.window);
                if (!ZXIsPinCodeString(stillPin)) return;

                // Locate exact Y boundaries of the "Trò chuyện ẩn" section — abort immediately if absent!
                CGFloat secMinY = 0.0, secMaxY = 0.0;
                if (!ZXFindHiddenChatsSectionYBounds(strongList, &secMinY, &secMaxY)) {
                    return;
                }

                NSArray<UIView *> *visCells = nil;
                if ([strongList isKindOfClass:[UITableView class]]) {
                    visCells = ((UITableView *)strongList).visibleCells;
                } else if ([strongList isKindOfClass:[UICollectionView class]]) {
                    visCells = ((UICollectionView *)strongList).visibleCells;
                }

                // Collect ONLY valid chat cells strictly inside [secMinY, secMaxY] ("Trò chuyện ẩn")
                NSMutableArray<NSDictionary *> *validHiddenSectionResults = [NSMutableArray new];
                for (UIView *c in visCells) {
                    if (!ZXIsCellStrictlyInsideHiddenSection(c, strongList, secMinY, secMaxY)) continue;
                    NSString *cName = @"";
                    NSString *cMsg = @"";
                    NSString *cUID = @"";
                    ZXExtractBestNameAndMsgFromCell(c, &cName, &cMsg, &cUID);
                    if ([ZXScanner isValidHumanDisplayName:cName excludeUID:cUID]) {
                        [validHiddenSectionResults addObject:@{
                            @"name": cName,
                            @"msg": cMsg ?: @"",
                            @"uid": cUID ?: @""
                        }];
                    }
                }

                if (validHiddenSectionResults.count == 0) return;

                // Confirmed real "Trò chuyện ẩn" section under this PIN!
                [[NSUserDefaults standardUserDefaults] setObject:stillPin forKey:@"zx_saved_hidden_pin"];
                NSArray<NSDictionary *> *captured = [validHiddenSectionResults copy];

                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    @try {
                        NSArray<NSString *> *hiddenIDs = [ZXScanner currentHiddenChatEntityIDs];
                        NSSet<NSString *> *hiddenSet = [NSSet setWithArray:hiddenIDs ?: @[]];
                        for (NSDictionary *hit in captured) {
                            NSString *hName = hit[@"name"];
                            NSString *hMsg = hit[@"msg"];
                            NSString *hUID = hit[@"uid"];
                            // Only attach to numeric ID if hUID matches; never force-link onto an unrelated old ID!
                            if (hUID.length >= 4 && ([hiddenSet containsObject:hUID] || ![ZXScanner isGarbageChatIdentifier:hUID])) {
                                ZXRecordVerifiedHiddenProfile(hUID, hName, hMsg, @"PinSearch");
                            } else {
                                NSString *pinKey = [NSString stringWithFormat:@"pin:%@", hName];
                                ZXRecordVerifiedHiddenProfile(pinKey, hName, hMsg, @"PinSearch");
                            }
                        }
                        ZXSaveResolvedProfilesNow();
                    } @catch (__unused NSException *e) {}
                });
            } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
}

static BOOL ZXTextIndicatesExplicitHideChatOption(NSString *raw)
{
    if (raw.length == 0) return NO;
    NSString *lc = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if ([lc containsString:@"bỏ ẩn"] || [lc containsString:@"unhide"] || [lc containsString:@"hiện lại"] || [lc containsString:@"tạm hiện"]) {
        return NO;
    }
    return ([lc containsString:@"ẩn trò chuyện"] ||
            [lc containsString:@"ẩn hội thoại"] ||
            [lc containsString:@"ẩn chat"] ||
            [lc containsString:@"hide conversation"] ||
            [lc containsString:@"hide chat"]);
}

static BOOL ZXTextIndicatesHideAction(NSString *raw)
{
    if (raw.length == 0) return NO;
    NSString *lc = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if ([lc containsString:@"bỏ ẩn"] || [lc containsString:@"unhide"] || [lc containsString:@"hiện lại"] || [lc containsString:@"tạm hiện"]) {
        return NO;
    }
    return ([lc isEqualToString:@"ẩn"] ||
            [lc isEqualToString:@"hide"] ||
            ZXTextIndicatesExplicitHideChatOption(lc));
}

static BOOL ZXViewContainsHideText(UIView *v, int depth)
{
    if (!v || v.hidden || v.alpha < 0.05 || depth > 5) return NO;
    if (ZXTextIndicatesExplicitHideChatOption(v.accessibilityLabel)) return YES;
    if ([v isKindOfClass:[UILabel class]] && ZXTextIndicatesExplicitHideChatOption([(UILabel *)v text])) return YES;
    if ([v isKindOfClass:[UIButton class]] && ZXTextIndicatesExplicitHideChatOption([(UIButton *)v currentTitle])) return YES;
    for (UIView *sub in v.subviews) {
        if (ZXViewContainsHideText(sub, depth + 1)) return YES;
    }
    return NO;
}

static void ZXCommitHideChatWithName(NSString *chatName, NSString *lastMsg, NSString *knownUID)
{
    @try {
        NSString *cleanName = [chatName ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![ZXScanner isValidHumanDisplayName:cleanName excludeUID:knownUID]) return;
        NSString *cleanMsg = [lastMsg ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([ZXScanner isGarbageChatIdentifier:cleanMsg]) cleanMsg = @"";

        ZXLog(@"Commit hide chat detected: name='%@' knownUID='%@'", cleanName, knownUID ?: @"");

        if (knownUID.length >= 4 && ![ZXScanner isGarbageChatIdentifier:knownUID]) {
            [sUnhiddenThreadIDs removeObject:knownUID];
            ZXRecordVerifiedHiddenProfile(knownUID, cleanName, cleanMsg, @"HideAction");
        } else {
            NSString *synHideKey = [NSString stringWithFormat:@"hide:%@", cleanName];
            [sUnhiddenThreadIDs removeObject:synHideKey];
            ZXRecordVerifiedHiddenProfile(synHideKey, cleanName, cleanMsg, @"HideAction");
        }
        ZXSaveResolvedProfilesNow();

        NSSet<NSString *> *beforeSnap = sHiddenIDsBeforeAction;
        // Poll HiddenChatEntity twice (0.6s and 1.8s) to catch ONLY a newly inserted ID (strict diff: afterIDs - beforeSnap == 1 ID)
        for (NSNumber *delaySec in @[@0.6, @1.8]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @try {
                    NSArray<NSString *> *afterIDs = [ZXScanner currentHiddenChatEntityIDs];
                    if (knownUID.length >= 4 && [afterIDs containsObject:knownUID]) {
                        ZXRecordVerifiedHiddenProfile(knownUID, cleanName, cleanMsg, @"HideAction");
                        sHiddenIDsBeforeAction = [NSSet setWithArray:afterIDs ?: @[]];
                        return;
                    }
                    if (!beforeSnap) return; // Never guess without a pre-hide snapshot!
                    NSMutableArray<NSString *> *added = [NSMutableArray new];
                    for (NSString *cid in afterIDs) {
                        if (![beforeSnap containsObject:cid]) {
                            [added addObject:cid];
                        }
                    }
                    if (added.count == 1) {
                        NSString *matchedNewID = added.firstObject;
                        [sUnhiddenThreadIDs removeObject:matchedNewID];
                        ZXRecordVerifiedHiddenProfile(matchedNewID, cleanName, cleanMsg, @"HideAction");
                        sHiddenIDsBeforeAction = [NSSet setWithArray:afterIDs ?: @[]];
                        ZXLog(@"Mapped newly hidden ID %@ -> '%@'", matchedNewID, cleanName);
                    }
                } @catch (__unused NSException *e) {}
            });
        }
    } @catch (__unused NSException *e) {}
}

static NSString *ZXExtractChatTitleFromVC(UIViewController *vc)
{
    if (!vc) return @"";
    @try {
        NSString *t1 = [vc.navigationItem.title ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([ZXScanner isValidHumanDisplayName:t1 excludeUID:nil]) return t1;

        NSString *t2 = [vc.title ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([ZXScanner isValidHumanDisplayName:t2 excludeUID:nil]) return t2;

        if (vc.navigationItem.titleView) {
            NSMutableArray<UILabel *> *tvLabels = [NSMutableArray new];
            ZXCollectRankedLabels(vc.navigationItem.titleView, tvLabels, 0);
            for (UILabel *lbl in tvLabels) {
                NSString *t = [lbl.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([ZXScanner isValidHumanDisplayName:t excludeUID:nil]) return t;
            }
        }

        // Fallback: inspect top custom header bar (y < 120pt) inside chat VC's view
        if (vc.view) {
            NSMutableArray<UILabel *> *topLabels = [NSMutableArray new];
            ZXCollectRankedLabels(vc.view, topLabels, 0);
            for (UILabel *lbl in topLabels) {
                CGRect r = [lbl convertRect:lbl.bounds toView:vc.view];
                if (r.origin.y >= 16.0 && r.origin.y <= 115.0) {
                    NSString *t = [lbl.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if ([ZXScanner isValidHumanDisplayName:t excludeUID:nil]) return t;
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return @"";
}

static void ZXCaptureOpenChatInfo(UIViewController *vc)
{
    if (!vc) return;
    @try {
        NSString *clsName = NSStringFromClass([vc class]);
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        BOOL looksLikeChat = ([clsName rangeOfString:@"Chat" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"CSC" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"MessageView" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                              [clsName rangeOfString:@"Conversation" options:NSCaseInsensitiveSearch].location != NSNotFound);
        BOOL looksLikeOptions = ([clsName rangeOfString:@"Option" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                 [clsName rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                 [clsName rangeOfString:@"Info" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!looksLikeChat || looksLikeOptions) return;

        NSString *uid = ZXReadStringKVC(vc, @[@"threadId", @"chatId", @"targetUserId", @"conversationId", @"userId", @"peerId", @"groupId"]);
        NSString *name = ZXExtractChatTitleFromVC(vc);
        if (name.length > 0) {
            sCurrentOpenChatName = name;
            if (uid.length >= 4 && ![ZXScanner isGarbageChatIdentifier:uid]) {
                sCurrentOpenChatUID = uid;
            }
            ZXLog(@"Captured open chat info: '%@' (uid=%@)", name, uid ?: @"");
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSArray<NSString *> *ids = [ZXScanner currentHiddenChatEntityIDs];
                sHiddenIDsBeforeAction = [NSSet setWithArray:ids ?: @[]];
                // If this opened chat VC has an exact threadId/uid present in HiddenChatEntity, verify & save its real title!
                if (uid.length >= 4 && [sHiddenIDsBeforeAction containsObject:uid]) {
                    ZXRecordVerifiedHiddenProfile(uid, name, @"", @"HiddenChatEntity");
                    ZXSaveResolvedProfilesNow();
                }
            });
        }
    } @catch (__unused NSException *e) {}
}

static void ZXSwizzleTableViewDelegateClassIfNeeded(id delegate)
{
    if (!delegate) return;
    @try {
        Class cls = [delegate class];
        NSString *clsName = NSStringFromClass(cls);
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        if (!sSwizzledTableDelegates) sSwizzledTableDelegates = [NSMutableSet new];
        @synchronized (sSwizzledTableDelegates) {
            if ([sSwizzledTableDelegates containsObject:clsName]) return;
            [sSwizzledTableDelegates addObject:clsName];
        }

        // Hook trailingSwipeActionsConfigurationForRowAtIndexPath:
        SEL selTrail = @selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:);
        Method mTrail = class_getInstanceMethod(cls, selTrail);
        if (mTrail) {
            IMP origTrail = method_getImplementation(mTrail);
            method_setImplementation(mTrail, imp_implementationWithBlock(^id(id self_, UITableView *tv, NSIndexPath *ip) {
                @try {
                    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                    if (cell) ZXCaptureCandidateFromCell(cell);
                } @catch (__unused NSException *e) {}
                return ((id (*)(id, SEL, UITableView *, NSIndexPath *))origTrail)(self_, selTrail, tv, ip);
            }));
        }

        // Hook editActionsForRowAtIndexPath:
        SEL selEdit = @selector(tableView:editActionsForRowAtIndexPath:);
        Method mEdit = class_getInstanceMethod(cls, selEdit);
        if (mEdit) {
            IMP origEdit = method_getImplementation(mEdit);
            method_setImplementation(mEdit, imp_implementationWithBlock(^id(id self_, UITableView *tv, NSIndexPath *ip) {
                @try {
                    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                    if (cell) ZXCaptureCandidateFromCell(cell);
                } @catch (__unused NSException *e) {}
                return ((id (*)(id, SEL, UITableView *, NSIndexPath *))origEdit)(self_, selEdit, tv, ip);
            }));
        }

        // Hook tableView:didSelectRowAtIndexPath: (capture ONLY tapped hidden result after PIN entry)
        SEL selSelect = @selector(tableView:didSelectRowAtIndexPath:);
        Method mSelect = class_getInstanceMethod(cls, selSelect);
        if (mSelect) {
            IMP origSelect = method_getImplementation(mSelect);
            method_setImplementation(mSelect, imp_implementationWithBlock(^(id self_, UITableView *tv, NSIndexPath *ip) {
                @try {
                    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                    if (cell) ZXHandleSelectedPinResultCell(cell, tv);
                } @catch (__unused NSException *e) {}
                ((void (*)(id, SEL, UITableView *, NSIndexPath *))origSelect)(self_, selSelect, tv, ip);
            }));
        }
    } @catch (__unused NSException *e) {}
}

static void ZXSwizzleTableViewDataSourceClassIfNeeded(id dataSource)
{
    if (!dataSource) return;
    @try {
        Class cls = [dataSource class];
        NSString *clsName = NSStringFromClass(cls);
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        if (!sSwizzledTableDataSources) sSwizzledTableDataSources = [NSMutableSet new];
        @synchronized (sSwizzledTableDataSources) {
            if ([sSwizzledTableDataSources containsObject:clsName]) return;
            [sSwizzledTableDataSources addObject:clsName];
        }

        SEL selCell = @selector(tableView:cellForRowAtIndexPath:);
        Method mCell = class_getInstanceMethod(cls, selCell);
        if (mCell) {
            IMP origCell = method_getImplementation(mCell);
            method_setImplementation(mCell, imp_implementationWithBlock(^UITableViewCell *(id self_, UITableView *tv, NSIndexPath *ip) {
                UITableViewCell *cell = ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))origCell)(self_, selCell, tv, ip);
                @try {
                    if (cell) ZXScheduleVerifySinglePinResultInList(tv);
                } @catch (__unused NSException *e) {}
                return cell;
            }));
        }
    } @catch (__unused NSException *e) {}
}

static void ZXSwizzleCollectionViewDelegateClassIfNeeded(id delegate)
{
    if (!delegate) return;
    @try {
        Class cls = [delegate class];
        NSString *clsName = NSStringFromClass(cls);
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        if (!sSwizzledCollectionDelegates) sSwizzledCollectionDelegates = [NSMutableSet new];
        @synchronized (sSwizzledCollectionDelegates) {
            if ([sSwizzledCollectionDelegates containsObject:clsName]) return;
            [sSwizzledCollectionDelegates addObject:clsName];
        }

        SEL selSelect = @selector(collectionView:didSelectItemAtIndexPath:);
        Method mSelect = class_getInstanceMethod(cls, selSelect);
        if (mSelect) {
            IMP origSelect = method_getImplementation(mSelect);
            method_setImplementation(mSelect, imp_implementationWithBlock(^(id self_, UICollectionView *cv, NSIndexPath *ip) {
                @try {
                    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                    if (cell) ZXHandleSelectedPinResultCell(cell, cv);
                } @catch (__unused NSException *e) {}
                ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))origSelect)(self_, selSelect, cv, ip);
            }));
        }
    } @catch (__unused NSException *e) {}
}

static void ZXSwizzleCollectionViewDataSourceClassIfNeeded(id dataSource)
{
    if (!dataSource) return;
    @try {
        Class cls = [dataSource class];
        NSString *clsName = NSStringFromClass(cls);
        if (ZXShouldSkipSwizzleForClassName(clsName)) return;
        if (!sSwizzledCollectionDataSources) sSwizzledCollectionDataSources = [NSMutableSet new];
        @synchronized (sSwizzledCollectionDataSources) {
            if ([sSwizzledCollectionDataSources containsObject:clsName]) return;
            [sSwizzledCollectionDataSources addObject:clsName];
        }

        SEL selCell = @selector(collectionView:cellForItemAtIndexPath:);
        Method mCell = class_getInstanceMethod(cls, selCell);
        if (mCell) {
            IMP origCell = method_getImplementation(mCell);
            method_setImplementation(mCell, imp_implementationWithBlock(^UICollectionViewCell *(id self_, UICollectionView *cv, NSIndexPath *ip) {
                UICollectionViewCell *cell = ((UICollectionViewCell *(*)(id, SEL, UICollectionView *, NSIndexPath *))origCell)(self_, selCell, cv, ip);
                @try {
                    if (cell) ZXScheduleVerifySinglePinResultInList(cv);
                } @catch (__unused NSException *e) {}
                return cell;
            }));
        }
    } @catch (__unused NSException *e) {}
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
        ZXCaptureCandidateFromCell(cell);

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

            // 1. Hook UIViewController -viewDidAppear: & UINavigationController -pushViewController:animated: for Chat Lock & Cách 2 Open Chat Title Capture
            Method vda = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
            if (vda) {
                IMP origVDA = method_getImplementation(vda);
                method_setImplementation(vda, imp_implementationWithBlock(^(UIViewController *self_, BOOL animated) {
                    @try {
                        ((void (*)(id, SEL, BOOL))origVDA)(self_, @selector(viewDidAppear:), animated);
                        if ([NSStringFromClass([self_ class]) hasPrefix:@"ZX"] && gSpamOverlayWindow) {
                            gSpamOverlayWindow.hidden = YES;
                        }
                        ZXCaptureOpenChatInfo(self_);
                        ZXAttachLockShieldIfNeeded(self_);
                    } @catch (NSException *e) {
                        ZXLog(@"viewDidAppear hook exception: %@", e.reason);
                    }
                }));
            }
            Method navPush = class_getInstanceMethod([UINavigationController class], @selector(pushViewController:animated:));
            if (navPush) {
                IMP origNavPush = method_getImplementation(navPush);
                method_setImplementation(navPush, imp_implementationWithBlock(^(UINavigationController *self_, UIViewController *vc, BOOL animated) {
                    @try {
                        ZXCaptureOpenChatInfo(self_.topViewController);
                        ZXCaptureOpenChatInfo(vc);
                    } @catch (__unused NSException *e) {}
                    ((void (*)(id, SEL, UIViewController *, BOOL))origNavPush)(self_, @selector(pushViewController:animated:), vc, animated);
                }));
            }

            // 1b. Hook UITableView / UICollectionView / UISearchBar / UITextField delegates & dataSources for Hide & PIN Search Detection
            Method tvSetDel = class_getInstanceMethod([UITableView class], @selector(setDelegate:));
            if (tvSetDel) {
                IMP origTVSetDel = method_getImplementation(tvSetDel);
                method_setImplementation(tvSetDel, imp_implementationWithBlock(^(UITableView *self_, id delegate) {
                    ((void (*)(id, SEL, id))origTVSetDel)(self_, @selector(setDelegate:), delegate);
                    @try {
                        if (delegate) ZXSwizzleTableViewDelegateClassIfNeeded(delegate);
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method tvSetDS = class_getInstanceMethod([UITableView class], @selector(setDataSource:));
            if (tvSetDS) {
                IMP origTVSetDS = method_getImplementation(tvSetDS);
                method_setImplementation(tvSetDS, imp_implementationWithBlock(^(UITableView *self_, id dataSource) {
                    ((void (*)(id, SEL, id))origTVSetDS)(self_, @selector(setDataSource:), dataSource);
                    @try {
                        if (dataSource) ZXSwizzleTableViewDataSourceClassIfNeeded(dataSource);
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method cvSetDel = class_getInstanceMethod([UICollectionView class], @selector(setDelegate:));
            if (cvSetDel) {
                IMP origCVSetDel = method_getImplementation(cvSetDel);
                method_setImplementation(cvSetDel, imp_implementationWithBlock(^(UICollectionView *self_, id delegate) {
                    ((void (*)(id, SEL, id))origCVSetDel)(self_, @selector(setDelegate:), delegate);
                    @try {
                        if (delegate) ZXSwizzleCollectionViewDelegateClassIfNeeded(delegate);
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method cvSetDS = class_getInstanceMethod([UICollectionView class], @selector(setDataSource:));
            if (cvSetDS) {
                IMP origCVSetDS = method_getImplementation(cvSetDS);
                method_setImplementation(cvSetDS, imp_implementationWithBlock(^(UICollectionView *self_, id dataSource) {
                    ((void (*)(id, SEL, id))origCVSetDS)(self_, @selector(setDataSource:), dataSource);
                    @try {
                        if (dataSource) ZXSwizzleCollectionViewDataSourceClassIfNeeded(dataSource);
                    } @catch (__unused NSException *e) {}
                }));
            }
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
            if (@available(iOS 11.0, *)) {
                Method ctxAct = class_getClassMethod([UIContextualAction class], @selector(contextualActionWithStyle:title:handler:));
                if (ctxAct) {
                    IMP origCtxAct = method_getImplementation(ctxAct);
                    method_setImplementation(ctxAct, imp_implementationWithBlock(^id(id self_, UIContextualActionStyle style, NSString *title, UIContextualActionHandler handler) {
                        UIContextualActionHandler wrapped = handler;
                        if (ZXTextIndicatesHideAction(title) && handler) {
                            wrapped = ^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
                                @try {
                                    ZXCommitHideChatWithName(sCandidateChatName ?: sCurrentOpenChatName, sCandidateLastMsg, sCandidateChatUID ?: sCurrentOpenChatUID);
                                } @catch (__unused NSException *e) {}
                                handler(action, sourceView, completionHandler);
                            };
                        }
                        return ((id (*)(id, SEL, UIContextualActionStyle, NSString *, UIContextualActionHandler))origCtxAct)(self_, @selector(contextualActionWithStyle:title:handler:), style, title, wrapped);
                    }));
                }
            }
            Method alertAct = class_getClassMethod([UIAlertAction class], @selector(actionWithTitle:style:handler:));
            if (alertAct) {
                IMP origAlertAct = method_getImplementation(alertAct);
                method_setImplementation(alertAct, imp_implementationWithBlock(^id(id self_, NSString *title, UIAlertActionStyle style, void (^handler)(UIAlertAction *)) {
                    void (^wrapped)(UIAlertAction *) = handler;
                    if (ZXTextIndicatesHideAction(title)) {
                        wrapped = ^(UIAlertAction *act) {
                            @try {
                                ZXCommitHideChatWithName(sCandidateChatName ?: sCurrentOpenChatName, sCandidateLastMsg, sCandidateChatUID ?: sCurrentOpenChatUID);
                            } @catch (__unused NSException *e) {}
                            if (handler) handler(act);
                        };
                    }
                    return ((id (*)(id, SEL, NSString *, UIAlertActionStyle, void (^)(UIAlertAction *)))origAlertAct)(self_, @selector(actionWithTitle:style:handler:), title, style, wrapped);
                }));
            }
            Method ctrlSend = class_getInstanceMethod([UIControl class], @selector(sendAction:to:forEvent:));
            if (ctrlSend) {
                IMP origCtrlSend = method_getImplementation(ctrlSend);
                method_setImplementation(ctrlSend, imp_implementationWithBlock(^(UIControl *self_, SEL action, id target, UIEvent *event) {
                    @try {
                        UIViewController *ownerVC = ZXNearestViewControllerForView(self_);
                        NSString *vcCls = ownerVC ? NSStringFromClass([ownerVC class]) : @"";
                        if (![vcCls hasPrefix:@"ZX"]) {
                            if ([self_ isKindOfClass:[UISwitch class]] && [(UISwitch *)self_ isOn]) {
                                // Check parent cell or row container for "Ẩn trò chuyện" / "Hide"
                                UIView *container = self_.superview;
                                for (int up = 0; up < 4 && container; up++) {
                                    if ([container isKindOfClass:[UITableViewCell class]] || [container isKindOfClass:[UICollectionViewCell class]]) break;
                                    container = container.superview;
                                }
                                if (container && ZXViewContainsHideText(container, 0)) {
                                    ZXCommitHideChatWithName(sCurrentOpenChatName ?: sCandidateChatName, @"", sCurrentOpenChatUID ?: sCandidateChatUID);
                                }
                            } else if ([self_ isKindOfClass:[UIButton class]]) {
                                if (ZXViewContainsHideText(self_, 0)) {
                                    ZXCommitHideChatWithName(sCandidateChatName ?: sCurrentOpenChatName, sCandidateLastMsg, sCandidateChatUID ?: sCurrentOpenChatUID);
                                }
                            }
                        }
                    } @catch (__unused NSException *e) {}
                    ((void (*)(id, SEL, SEL, id, UIEvent *))origCtrlSend)(self_, @selector(sendAction:to:forEvent:), action, target, event);
                }));
            }

            // 2. Hook UITableViewCell -didMoveToWindow for long-press quick menu + DiffableDataSource PIN result trigger
            Method dmw = class_getInstanceMethod([UITableViewCell class], @selector(didMoveToWindow));
            if (dmw) {
                IMP origDMW = method_getImplementation(dmw);
                method_setImplementation(dmw, imp_implementationWithBlock(^(UITableViewCell *self_) {
                    @try {
                        ((void (*)(id, SEL))origDMW)(self_, @selector(didMoveToWindow));
                        if (!self_.window) return;
                        NSString *cn = NSStringFromClass([self_ class]);
                        if ([cn hasPrefix:@"ZX"]) return;
                        if (ZXIsPinCodeString(ZXCurrentPinInWindow(self_.window))) {
                            UIView *sup = self_.superview;
                            while (sup && ![sup isKindOfClass:[UITableView class]]) sup = sup.superview;
                            if (sup) ZXScheduleVerifySinglePinResultInList(sup);
                        }
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
            Method tvReload = class_getInstanceMethod([UITableView class], @selector(reloadData));
            if (tvReload) {
                IMP origTVReload = method_getImplementation(tvReload);
                method_setImplementation(tvReload, imp_implementationWithBlock(^(UITableView *self_) {
                    @try {
                        if (self_.delegate) ZXSwizzleTableViewDelegateClassIfNeeded(self_.delegate);
                        if (self_.dataSource) ZXSwizzleTableViewDataSourceClassIfNeeded(self_.dataSource);
                        ((void (*)(id, SEL))origTVReload)(self_, @selector(reloadData));
                    } @catch (__unused NSException *e) {}
                }));
            }
            Method cvReload = class_getInstanceMethod([UICollectionView class], @selector(reloadData));
            if (cvReload) {
                IMP origCVReload = method_getImplementation(cvReload);
                method_setImplementation(cvReload, imp_implementationWithBlock(^(UICollectionView *self_) {
                    @try {
                        if (self_.delegate) ZXSwizzleCollectionViewDelegateClassIfNeeded(self_.delegate);
                        if (self_.dataSource) ZXSwizzleCollectionViewDataSourceClassIfNeeded(self_.dataSource);
                        ((void (*)(id, SEL))origCVReload)(self_, @selector(reloadData));
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
    if (gSQLiteScanInProgress) {
        gSQLiteRescanRequested = YES;
        return;
    }
    gSQLiteScanInProgress = YES;
    gSQLiteRescanRequested = NO;
    ZXInitHiddenChatsStore();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            // Merge (a) HiddenChatEntity in global.sqlite + (b) zx_resolved_profiles.json & hidden_chats.json + (c) session PIN/Hide items
            NSArray<NSDictionary *> *mergedHits = [ZXScanner scanSQLiteForHiddenChats];
            @synchronized (gHiddenChatsMap) {
                [gHiddenChatsMap removeAllObjects];
                for (NSDictionary *item in mergedHits) {
                    NSString *uid = [item[@"uid"] description];
                    if (uid.length == 0 || [ZXScanner isGarbageChatIdentifier:uid] || [sDismissedHiddenKeys containsObject:uid]) {
                        continue;
                    }
                    NSString *src = [item[@"hiddenSource"] description] ?: @"";
                    if (![src isEqualToString:@"HiddenChatEntity"] && [sUnhiddenThreadIDs containsObject:uid]) {
                        continue;
                    }
                    if ([src isEqualToString:@"HiddenChatEntity"] && [sUnhiddenThreadIDs containsObject:uid]) {
                        [sUnhiddenThreadIDs removeObject:uid];
                    }
                    gHiddenChatsMap[uid] = item;
                }
                for (NSString *sKey in [sSessionHiddenChatsMap allKeys]) {
                    if ([sUnhiddenThreadIDs containsObject:sKey] || [sDismissedHiddenKeys containsObject:sKey]) continue;
                    NSDictionary *sItem = sSessionHiddenChatsMap[sKey];
                    NSString *sName = [sItem[@"rawName"] description] ?: @"";
                    if (sName.length > 0 && ![ZXScanner isValidHumanDisplayName:sName excludeUID:sKey]) {
                        [sSessionHiddenChatsMap removeObjectForKey:sKey];
                        continue;
                    }
                    if ([sKey hasPrefix:@"pin:"] && ![sItem[@"inHiddenSection"] boolValue]) {
                        [sSessionHiddenChatsMap removeObjectForKey:sKey];
                        continue;
                    }
                    if (!gHiddenChatsMap[sKey]) {
                        gHiddenChatsMap[sKey] = sItem;
                    } else if ([gHiddenChatsMap[sKey][@"rawName"] length] == 0 && sName.length > 0) {
                        gHiddenChatsMap[sKey] = sItem;
                    }
                }
                ZXSaveHiddenChatsStore();
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
        NSArray<NSString *> *sqlEntityIDs = [ZXScanner currentHiddenChatEntityIDs];
        NSSet<NSString *> *sqlSet = [NSSet setWithArray:sqlEntityIDs ?: @[]];

        @synchronized (gHiddenChatsMap) {
            for (NSString *uid in [gHiddenChatsMap allKeys]) {
                NSDictionary *it = gHiddenChatsMap[uid];
                NSString *rName = [it[@"rawName"] description] ?: @"";
                NSString *src = [it[@"hiddenSource"] description] ?: @"";
                BOOL badName = (rName.length > 0 && ![ZXScanner isValidHumanDisplayName:rName excludeUID:uid]);
                BOOL unsectionedPin = ([uid hasPrefix:@"pin:"] && ![it[@"inHiddenSection"] boolValue]);
                BOOL notHiddenAnywhere = (![sqlSet containsObject:uid] && ![src isEqualToString:@"HideAction"] && ![it[@"inHiddenSection"] boolValue]);
                if ([ZXScanner isGarbageChatIdentifier:uid] || [sDismissedHiddenKeys containsObject:uid] || badName || unsectionedPin || notHiddenAnywhere) {
                    [gHiddenChatsMap removeObjectForKey:uid];
                    [sSessionHiddenChatsMap removeObjectForKey:uid];
                }
            }
            ZXSaveHiddenChatsStore();
        }
        @synchronized (gResolvedProfilesMap) {
            for (NSString *k in [gResolvedProfilesMap allKeys]) {
                NSDictionary *prof = [gResolvedProfilesMap[k] isKindOfClass:[NSDictionary class]] ? gResolvedProfilesMap[k] : nil;
                NSString *pName = [prof[@"name"] description] ?: @"";
                BOOL badName = (!prof || (pName.length > 0 && ![ZXScanner isValidHumanDisplayName:pName excludeUID:k]));
                BOOL unsectionedPin = ([k hasPrefix:@"pin:"] && ![prof[@"inHiddenSection"] boolValue]);
                if ([ZXScanner isGarbageChatIdentifier:k] || [k hasPrefix:@"_"] || [sDismissedHiddenKeys containsObject:k] || badName || unsectionedPin) {
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
            if (uid.length == 0 || [ZXScanner isGarbageChatIdentifier:uid] || [sDismissedHiddenKeys containsObject:uid]) continue;
            NSString *rName = [it[@"rawName"] description] ?: @"";
            if (rName.length > 0 && ![ZXScanner isValidHumanDisplayName:rName excludeUID:uid]) continue;
            if ([uid hasPrefix:@"pin:"] && ![it[@"inHiddenSection"] boolValue]) continue;
            [filtered addObject:it];
        }
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
            [sSessionHiddenChatsMap removeObjectForKey:chatID];
            [gHiddenChatsMap removeObjectForKey:chatID];
            ZXSaveHiddenChatsStore();
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
            if (p.length) [fm removeItemAtPath:p error:nil];
        }
        for (NSString *hp in ZXAllStoreCandidatePaths(@"hidden_chats.json")) {
            if (hp.length) [fm removeItemAtPath:hp error:nil];
        }

        @synchronized (gHiddenChatsMap) {
            [sUnhiddenThreadIDs removeAllObjects];
            [sDismissedHiddenKeys removeAllObjects];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"nthe_unhidden_thread_ids"];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"zx_dismissed_hidden_keys"];
            [sSessionHiddenChatsMap removeAllObjects];
            [gHiddenChatsMap removeAllObjects];
            ZXSaveHiddenChatsStore();
        }
        sPendingResolveTargetUID = nil;
        sAwaitingPinSearchResult = NO;
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
        NSString *cleanDigits = [[chatID componentsSeparatedByCharactersInSet:
                                 [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
        @synchronized (gResolvedProfilesMap) {
            [gResolvedProfilesMap removeObjectForKey:chatID];
            if (cleanDigits.length >= 5) [gResolvedProfilesMap removeObjectForKey:cleanDigits];
            [gResolvedProfilesMap removeObjectForKey:@"_verified_single_pin_result"];
        }
        ZXSaveResolvedProfilesNow();

        @synchronized (gHiddenChatsMap) {
            for (NSString *key in @[chatID, (cleanDigits.length >= 5 ? cleanDigits : chatID)]) {
                [sSessionHiddenChatsMap removeObjectForKey:key];
                if (gHiddenChatsMap[key]) {
                    NSString *origSrc = [gHiddenChatsMap[key][@"hiddenSource"] description];
                    gHiddenChatsMap[key] = @{
                        @"uid": key,
                        @"rawName": @"",
                        @"name": [NSString stringWithFormat:@"Hội thoại ẩn (ID: %@)", key],
                        @"lastMessage": @"Đã xóa tên cũ • Bấm Mở thẳng khung chat & nhập PIN để lưu đúng tên",
                        @"hiddenSource": ZXIsAllowedHiddenSource(origSrc) ? origSrc : @"HiddenChatEntity",
                        @"verified": @NO,
                        @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                    };
                }
            }
            ZXSaveHiddenChatsStore();
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
        [sSessionHiddenChatsMap removeObjectForKey:chatID];
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

    void (^performOpenOnMain)(void) = ^{
        @try {
            ZXInitHiddenChatsStore();

            NSString *cleanDigits = [[(chatID ?: @"") componentsSeparatedByCharactersInSet:
                                     [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
            NSString *targetUID = (cleanDigits.length >= 5) ? cleanDigits : (chatID ?: @"");

            // Strip any " (ID: ...)" suffix from displayName
            NSString *candidateName = [displayName ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSRange idParen = [candidateName rangeOfString:@" (ID:"];
            if (idParen.location != NSNotFound) {
                candidateName = [candidateName substringToIndex:idParen.location];
            }

            // Priority check: verify candidateName or look up resolved real name in zx_resolved_profiles.json
            // STRICT RULE: NEVER allow numeric IDs (threadId/uid/chatId) or placeholder strings ("Hội thoại ẩn cũ...")!
            NSString *validRealName = @"";
            if ([ZXScanner isValidHumanDisplayName:candidateName excludeUID:targetUID] && !ZXIsPureDigitsString(candidateName)) {
                validRealName = candidateName;
            } else if (targetUID.length > 0) {
                @synchronized (gResolvedProfilesMap) {
                    NSDictionary *prof = [gResolvedProfilesMap[targetUID] isKindOfClass:[NSDictionary class]]
                        ? gResolvedProfilesMap[targetUID]
                        : ([gResolvedProfilesMap[chatID ?: @""] isKindOfClass:[NSDictionary class]] ? gResolvedProfilesMap[chatID ?: @""] : nil);
                    if ([prof[@"verified"] boolValue]) {
                        NSString *cachedName = [prof[@"name"] description] ?: @"";
                        if ([ZXScanner isValidHumanDisplayName:cachedName excludeUID:targetUID] && !ZXIsPureDigitsString(cachedName)) {
                            validRealName = cachedName;
                        }
                    }
                }
            }

            UIWindow *win = ZXActiveWindow();
            if (!win) return;

            // Switch Zalo's main UITabBarController to selectedIndex = 0 (Messages tab)
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

            // Open Zalo's Search bar at top of Messages tab
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

            // Determine Case A (has valid human name) vs Case B (unresolved ID -> check zx_saved_hidden_pin)
            BOOL hasValidName = (validRealName.length > 0);
            NSString *savedPin = [[[NSUserDefaults standardUserDefaults] stringForKey:@"zx_saved_hidden_pin"]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            BOOL hasSavedPin = ZXIsPinCodeString(savedPin);

            if (!hasValidName) {
                sPendingResolveTargetUID = targetUID;
                sAwaitingPinSearchResult = YES;
                if (hasSavedPin) {
                    sCandidateTypedPIN = savedPin;
                    sCandidatePinTypedTime = CFAbsoluteTimeGetCurrent();
                }
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    UIWindow *curWin = ZXActiveWindow() ?: win;
                    if (!curWin) return;

                    UIView *firstResp = ZXFindFirstResponderInView(curWin);
                    UISearchBar *sb = [firstResp isKindOfClass:[UISearchBar class]] ? (UISearchBar *)firstResp : ZXFindSearchBarInView(curWin);
                    UITextField *tf = [firstResp isKindOfClass:[UITextField class]] ? (UITextField *)firstResp : ZXFindSearchTextFieldInView(curWin);

                    NSString *textToFill = nil; // nil means keep empty (Case B without saved PIN)
                    NSString *toastMessage = nil;

                    if (hasValidName) {
                        // Trường hợp A: Đã có tên thật hợp lệ -> điền CHÍNH XÁC tên thật (không bao giờ điền ID!)
                        textToFill = validRealName;
                        toastMessage = @"Đã điền tên vào ô Tìm kiếm — chạm vào kết quả để mở";
                    } else if (hasSavedPin) {
                        // Trường hợp B1: Chưa có tên thật nhưng ĐÃ lưu mã PIN ẩn -> điền mã PIN ẩn để Zalo hiện đoạn chat & tự lưu tên
                        textToFill = savedPin;
                        toastMessage = @"Đã điền mã PIN ẩn — chọn đoạn chat để xem & lưu tên";
                    } else {
                        // Trường hợp B2: Chưa có tên thật & CHƯA có mã PIN -> để trống hoàn toàn ô tìm kiếm
                        textToFill = nil;
                        toastMessage = @"Nhập mã PIN ẩn tại đây để Zalo hiện đoạn chat & tự lưu tên";
                    }

                    if (sb) {
                        if (!sb.isFirstResponder) [sb becomeFirstResponder];
                        if (textToFill != nil) {
                            sb.text = textToFill;
                            if ([sb.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
                                [sb.delegate searchBar:sb textDidChange:textToFill];
                            }
                        } else {
                            sb.text = @"";
                        }
                    }
                    if (tf) {
                        if (!tf.isFirstResponder) [tf becomeFirstResponder];
                        tf.text = @"";
                        if (textToFill != nil) {
                            [tf insertText:textToFill];
                            if (tf.text.length == 0) tf.text = textToFill;
                            if ([tf.delegate respondsToSelector:@selector(textField:shouldChangeCharactersInRange:replacementString:)]) {
                                [tf.delegate textField:tf shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:textToFill];
                            }
                            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                            [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
                        }
                    }

                    if (toastMessage.length > 0) {
                        ZXShowBottomBannerOnWindow(curWin, toastMessage);
                    }
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
