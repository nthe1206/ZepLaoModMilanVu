#import <Foundation/Foundation.h>

// Config keys (same names as the Android module's config.json)
#define ZXK_ANTI_RECALL            @"enable_anti_recall"
#define ZXK_ANTI_DELETE            @"enable_anti_delete"
#define ZXK_ANTI_RECALL_INCLUDE_ME @"anti_recall_include_me"
#define ZXK_ANTI_DELETE_INCLUDE_ME @"anti_delete_include_my_deletion"
#define ZXK_SHOW_CONTENT           @"show_recalled_content"
#define ZXK_RECALL_NOTE            @"show_recall_note"
#define ZXK_BLOCK_SEEN             @"block_send_seen"
#define ZXK_SILENT_TYPING          @"enable_silent_typing"
#define ZXK_BLOCK_ADS              @"block_ads_endpoints"
#define ZXK_DISABLE_TRACKING       @"logging_disable_zalo_tracking"
#define ZXK_BLOCK_QOS              @"logging_block_zalo_qos"
#define ZXK_DISABLE_FIREBASE       @"logging_disable_firebase"
#define ZXK_UNLIMITED_MEDIA        @"enable_unlimited_media"
#define ZXK_DEFAULT_ORIGINAL       @"default_original_quality"
#define ZXK_VIDEO_ORIGINAL         @"video_original"
#define ZXK_TTL_OVERRIDE           @"enable_msg_ttl_override"
#define ZXK_FLOATING_TABBAR        @"floating_tabbar_glass"
#define ZXK_CUSTOM_LOGO_MODE       @"NTHE_CustomLogoMode"
#define ZXK_BUBBLE_SIZE            @"NTHE_BubbleSize"

// 6 new feature keys
#define ZXK_UNHIDE_CHATS           @"nthe_unhide_hidden_chats"
#define ZXK_CHAT_LOCK_ENABLED      @"nthe_chat_lock_enabled"
#define ZXK_CHAT_LOCK_PIN          @"nthe_chat_lock_pin"
#define ZXK_LOCKED_CHATS           @"nthe_locked_chats_list"
#define ZXK_GHOST_STORY            @"nthe_ghost_story_seen"
#define ZXK_MSG_REPEATER           @"nthe_message_repeater"
#define ZXK_CALL_FORCE_RELAY       @"nthe_call_force_relay"
#define ZXK_AUTO_CALL_RECORD       @"nthe_auto_call_record"
#define ZXK_VOICE_MSG_TOOLS        @"nthe_voice_msg_tools"
#define ZXK_VOICE_PLAYBACK_RATE    @"nthe_voice_playback_rate"
#define ZXK_SPAM_DELAY_SEC         @"zx_spam_delay_sec"
#define ZXK_KEEP_ALIVE_BG          @"zx_keep_alive_bg"

@interface ZXConfig : NSObject
+ (void)registerDefaults;
+ (BOOL)boolForKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (long long)ttl;
+ (void)setTTL:(long long)value;
/// Seconds of no touch on the floating tab bar before it auto-collapses to the small round
/// button. 0 means "never collapse".
+ (double)tabBarIdleSeconds;
+ (void)setTabBarIdleSeconds:(double)value;
+ (NSString *)currentUserID;
+ (void)setCurrentUserID:(NSString *)value;
+ (BOOL)customLogoMode;
+ (void)setCustomLogoMode:(BOOL)value;
+ (double)bubbleSize;
+ (void)setBubbleSize:(double)value;
/// Delay between repeated messages in seconds (default 0.5, min 0.05)
+ (double)spamDelaySeconds;
+ (void)setSpamDelaySeconds:(double)sec;
/// Documents/nthe_custom_logo.png
+ (NSString *)customLogoPath;
/// PIN 4 digits for locked chats & hidden chats viewer
+ (NSString *)chatLockPIN;
+ (void)setChatLockPIN:(NSString *)pin;
/// Array of @{ @"id": @"...", @"name": @"..." }
+ (NSArray<NSDictionary *> *)lockedChats;
+ (void)addLockedChatWithID:(NSString *)chatID name:(NSString *)name;
+ (void)removeLockedChatWithID:(NSString *)chatID;
+ (BOOL)isChatLocked:(NSString *)chatIDOrName;
/// Voice playback speed (1.0, 1.5, 2.0)
+ (double)voicePlaybackRate;
+ (void)setVoicePlaybackRate:(double)rate;
/// Documents/NTHE_CallRecords (created on demand)
+ (NSString *)callRecordsDir;
/// Documents/ZaloXposed (created on demand)
+ (NSString *)dataDir;
@end
