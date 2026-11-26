#import <Foundation/Foundation.h>

/// Lists Objective-C classes/methods of the host app and resolves HiddenChatEntity ground-truth IDs.
@interface ZXScanner : NSObject
+ (NSString *)runScan;   // returns path of scan.txt
+ (NSString *)scanPath;
+ (NSString *)hiddenIntrospectPath;
+ (NSString *)lastPinCellsDumpPath;
+ (NSString *)dumpObjectModelGraph:(id)rootObj maxDepth:(int)maxDepth;
+ (NSString *)dumpLiveSceneListModelsOnMainThread;
+ (NSString *)runHiddenIntrospectionWithPinSnapshot:(NSString *)pinSnapshot liveSceneDump:(NSString *)liveSceneDump;
+ (NSString *)resolvedProfilesPath;
+ (NSDictionary<NSString *, NSString *> *)currentHiddenChatDigitToUIDMap;
+ (NSArray<NSString *> *)currentHiddenChatEntityIDs;
+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats;
+ (BOOL)unhideChatInSQLiteWithID:(NSString *)chatID;
+ (BOOL)isGarbageChatIdentifier:(NSString *)str;
+ (BOOL)isValidHumanDisplayName:(NSString *)str excludeUID:(NSString *)excludeUID;
@end
