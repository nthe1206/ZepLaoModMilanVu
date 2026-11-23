#import "ZXConfig.h"

static NSString *const kTTL = @"msg_ttl_value";
static NSString *const kUID = @"current_user_id";
static NSString *const kTabBarIdle = @"tabbar_idle_seconds";

static NSUserDefaults *ZXDefaults(void)
{
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:@"com.electroheavenvn.zaloxposed.ios"];
    });
    return d;
}

@implementation ZXConfig

+ (void)registerDefaults
{
    [ZXDefaults() registerDefaults:@{
        ZXK_ANTI_RECALL: @YES,
        ZXK_ANTI_DELETE: @YES,
        ZXK_ANTI_RECALL_INCLUDE_ME: @NO,
        ZXK_ANTI_DELETE_INCLUDE_ME: @NO,
        ZXK_SHOW_CONTENT: @YES,
        ZXK_RECALL_NOTE: @YES,
        ZXK_BLOCK_SEEN: @NO,
        ZXK_SILENT_TYPING: @NO,
        ZXK_BLOCK_ADS: @YES,
        ZXK_DISABLE_TRACKING: @YES,
        ZXK_BLOCK_QOS: @YES,
        ZXK_DISABLE_FIREBASE: @YES,
        ZXK_TTL_OVERRIDE: @NO,
        ZXK_UNLIMITED_MEDIA: @NO,
        ZXK_DEFAULT_ORIGINAL: @YES,
        ZXK_VIDEO_ORIGINAL: @YES,
        ZXK_FLOATING_TABBAR: @NO,
        ZXK_CUSTOM_LOGO_MODE: @NO,
        ZXK_BUBBLE_SIZE: @58.0,
        ZXK_UNHIDE_CHATS: @NO,
        ZXK_CHAT_LOCK_ENABLED: @NO,
        ZXK_CHAT_LOCK_PIN: @"",
        ZXK_GHOST_STORY: @NO,
        ZXK_MSG_REPEATER: @NO,
        ZXK_CALL_FORCE_RELAY: @NO,
        ZXK_AUTO_CALL_RECORD: @NO,
        ZXK_VOICE_MSG_TOOLS: @NO,
        ZXK_VOICE_PLAYBACK_RATE: @1.0,
        kTTL: @0,
        kUID: @"",
        kTabBarIdle: @10,
    }];
}

+ (BOOL)boolForKey:(NSString *)key { return [ZXDefaults() boolForKey:key]; }
+ (void)setBool:(BOOL)value forKey:(NSString *)key { [ZXDefaults() setBool:value forKey:key]; }
+ (long long)ttl { return [[ZXDefaults() objectForKey:kTTL] longLongValue]; }
+ (void)setTTL:(long long)value { [ZXDefaults() setObject:@(value) forKey:kTTL]; }
+ (NSString *)currentUserID { return [ZXDefaults() stringForKey:kUID] ?: @""; }
+ (void)setCurrentUserID:(NSString *)value { [ZXDefaults() setObject:(value ?: @"") forKey:kUID]; }
+ (double)tabBarIdleSeconds { return [[ZXDefaults() objectForKey:kTabBarIdle] doubleValue]; }
+ (void)setTabBarIdleSeconds:(double)value { [ZXDefaults() setObject:@(value) forKey:kTabBarIdle]; }
+ (BOOL)customLogoMode { return [ZXDefaults() boolForKey:ZXK_CUSTOM_LOGO_MODE]; }
+ (void)setCustomLogoMode:(BOOL)value {
    [ZXDefaults() setBool:value forKey:ZXK_CUSTOM_LOGO_MODE];
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:ZXK_CUSTOM_LOGO_MODE];
}
+ (double)bubbleSize {
    double s = [[ZXDefaults() objectForKey:ZXK_BUBBLE_SIZE] doubleValue];
    if (s < 36.0 || s > 100.0) s = 58.0;
    return s;
}
+ (void)setBubbleSize:(double)value {
    double clamped = MAX(38.0, MIN(92.0, value));
    [ZXDefaults() setObject:@(clamped) forKey:ZXK_BUBBLE_SIZE];
    [[NSUserDefaults standardUserDefaults] setObject:@(clamped) forKey:ZXK_BUBBLE_SIZE];
}
+ (NSString *)customLogoPath
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"nthe_custom_logo.png"];
}

+ (NSString *)chatLockPIN
{
    return [ZXDefaults() stringForKey:ZXK_CHAT_LOCK_PIN] ?: @"";
}

+ (void)setChatLockPIN:(NSString *)pin
{
    [ZXDefaults() setObject:(pin ?: @"") forKey:ZXK_CHAT_LOCK_PIN];
}

+ (NSArray<NSDictionary *> *)lockedChats
{
    NSArray *arr = [ZXDefaults() objectForKey:ZXK_LOCKED_CHATS];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

+ (void)addLockedChatWithID:(NSString *)chatID name:(NSString *)name
{
    NSString *cid = [chatID ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *cname = [name ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (cid.length == 0 && cname.length == 0) return;
    if (cid.length == 0) cid = cname;
    if (cname.length == 0) cname = cid;

    NSMutableArray *list = [[self lockedChats] mutableCopy];
    for (NSDictionary *d in list) {
        if ([[d[@"id"] description] isEqualToString:cid]) return;
    }
    [list addObject:@{ @"id": cid, @"name": cname }];
    [ZXDefaults() setObject:list forKey:ZXK_LOCKED_CHATS];
}

+ (void)removeLockedChatWithID:(NSString *)chatID
{
    if (chatID.length == 0) return;
    NSMutableArray *list = [NSMutableArray new];
    for (NSDictionary *d in [self lockedChats]) {
        if (![[d[@"id"] description] isEqualToString:chatID] &&
            ![[d[@"name"] description] isEqualToString:chatID]) {
            [list addObject:d];
        }
    }
    [ZXDefaults() setObject:list forKey:ZXK_LOCKED_CHATS];
}

+ (BOOL)isChatLocked:(NSString *)chatIDOrName
{
    NSString *q = [chatIDOrName ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) return NO;
    for (NSDictionary *d in [self lockedChats]) {
        NSString *cid = [d[@"id"] description] ?: @"";
        NSString *cname = [d[@"name"] description] ?: @"";
        if ((cid.length && [cid caseInsensitiveCompare:q] == NSOrderedSame) ||
            (cname.length && [cname caseInsensitiveCompare:q] == NSOrderedSame)) {
            return YES;
        }
    }
    return NO;
}

+ (double)voicePlaybackRate
{
    double r = [[ZXDefaults() objectForKey:ZXK_VOICE_PLAYBACK_RATE] doubleValue];
    if (r != 1.0 && r != 1.5 && r != 2.0) r = 1.0;
    return r;
}

+ (void)setVoicePlaybackRate:(double)rate
{
    double valid = (rate == 1.5 || rate == 2.0) ? rate : 1.0;
    [ZXDefaults() setObject:@(valid) forKey:ZXK_VOICE_PLAYBACK_RATE];
}

+ (NSString *)callRecordsDir
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"NTHE_CallRecords"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)dataDir
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"ZaloXposed"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

@end
