#import <Foundation/Foundation.h>

/// Lists Objective-C classes/methods of the host app whose names look related to
/// recall / seen / typing / ttl / ads, so you can write rules.json entries.
@interface ZXScanner : NSObject
+ (NSString *)runScan;   // returns path of scan.txt
+ (NSString *)scanPath;
+ (NSString *)resolvedProfilesPath;
+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats;
+ (BOOL)unhideChatInSQLiteWithID:(NSString *)chatID;
+ (BOOL)isGarbageChatIdentifier:(NSString *)str;
+ (BOOL)isValidHumanDisplayName:(NSString *)str excludeUID:(NSString *)excludeUID;
@end
