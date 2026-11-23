#import "ZXScanner.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import <objc/runtime.h>
#import <sqlite3.h>

static BOOL ZXIsGarbageString(NSString *s)
{
    if (!s || s.length == 0) return YES;
    NSString *trim = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length == 0) return YES;
    NSString *lc = trim.lowercaseString;

    // Reject UIKit / Zalo Objective-C & Swift class names or UI component names
    NSArray<NSString *> *badSubstrings = @[
        @"viewcontroller", @"tableview", @"collectionview", @"pinboard",
        @"uiview", @"uilabel", @"uibutton", @"uicontrol", @"uiwindow",
        @"navigation", @"tabbar", @"scrollview", @"cell", @"delegate",
        @"datasource", @"manager", @"controller", @"presenter", @"viewmodel",
        @"helper", @"processor", @"entity", @"config", @"layout", @"adapter",
        @"sqlite_master", @"sqlite_sequence"
    ];
    for (NSString *bad in badSubstrings) {
        if ([lc containsString:bad]) return YES;
    }
    if (([trim hasPrefix:@"ZA"] || [trim hasPrefix:@"UI"] || [trim hasPrefix:@"NS"] ||
         [trim hasPrefix:@"ZX"] || [trim hasPrefix:@"ZDS"] || [trim hasPrefix:@"UX"] ||
         [trim hasPrefix:@"_"]) && [trim rangeOfString:@" "].location == NSNotFound) {
        return YES;
    }
    return NO;
}

static BOOL ZXIsSQLiteFileAtPath(NSString *path)
{
    if (!path) return NO;
    @try {
        NSString *lower = path.lowercaseString;
        if ([lower hasSuffix:@"-wal"] || [lower hasSuffix:@"-shm"] || [lower hasSuffix:@"-journal"] ||
            [lower hasSuffix:@".plist"] || [lower hasSuffix:@".json"] || [lower hasSuffix:@".png"] ||
            [lower hasSuffix:@".jpg"] || [lower hasSuffix:@".m4a"] || [lower hasSuffix:@".txt"]) {
            return NO;
        }
        if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"] || [lower hasSuffix:@".sqlitedb"]) {
            return YES;
        }
        NSFileHandle *fh = [NSFileManager.defaultManager isReadableFileAtPath:path] ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
        if (!fh) return NO;
        NSData *head = [fh readDataOfLength:16];
        [fh closeFile];
        if (head.length < 16) return NO;
        return memcmp(head.bytes, "SQLite format 3", 15) == 0;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static void ZXCollectSQLiteFilesInDir(NSString *dir, NSMutableSet<NSString *> *outPaths, int depth)
{
    if (!dir || depth > 5 || outPaths.count >= 60) return;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if ([name hasPrefix:@"."]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                ZXCollectSQLiteFilesInDir(full, outPaths, depth + 1);
            } else if (ZXIsSQLiteFileAtPath(full)) {
                [outPaths addObject:full];
            }
        }
    } @catch (__unused NSException *e) {}
}

static NSSet<NSString *> *ZXAllZaloSQLitePaths(void)
{
    NSMutableSet<NSString *> *dbPaths = [NSMutableSet new];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        ZXCollectSQLiteFilesInDir([home stringByAppendingPathComponent:@"Documents"], dbPaths, 0);
        ZXCollectSQLiteFilesInDir([home stringByAppendingPathComponent:@"Library"], dbPaths, 0);
    }
    NSArray<NSString *> *groupIds = @[
        @"group.vn.com.vng.zingalo",
        @"group.com.vng.zalo",
        @"group.vn.com.vng.zingalo.share",
        @"group.vn.com.vng.zingalo.notification"
    ];
    for (NSString *gid in groupIds) {
        NSURL *gURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:gid];
        if (gURL.path.length) {
            ZXCollectSQLiteFilesInDir(gURL.path, dbPaths, 0);
        }
    }
    return dbPaths;
}

static NSString *ZXColumnText(sqlite3_stmt *stmt, int col)
{
    if (!stmt || col < 0 || col >= sqlite3_column_count(stmt)) return @"";
    const unsigned char *txt = sqlite3_column_text(stmt, col);
    if (!txt) return @"";
    return [NSString stringWithUTF8String:(const char *)txt] ?: @"";
}

/// Try to extract a human-readable name or message snippet from a JSON string if the column stores serialized JSON.
static void ZXTryParseJSONText(NSString *raw, NSString **ioName, NSString **ioMsg)
{
    if (!raw || raw.length < 4) return;
    NSString *trim = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trim hasPrefix:@"{"] || ![trim hasSuffix:@"}"]) return;
    @try {
        NSData *d = [trim dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![dict isKindOfClass:[NSDictionary class]]) return;
        for (NSString *nk in @[@"displayName", @"dName", @"name", @"threadName", @"title", @"zaloName", @"fullName", @"userName", @"groupName"]) {
            id v = dict[nk];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 && !ZXIsGarbageString(v)) {
                if (ioName && (*ioName).length == 0) *ioName = v;
                break;
            }
        }
        for (NSString *mk in @[@"message", @"msg", @"content", @"text", @"lastMessage", @"snippet", @"title", @"desc"]) {
            id v = dict[mk];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 && !ZXIsGarbageString(v)) {
                if (ioMsg && (*ioMsg).length == 0) *ioMsg = v;
                break;
            }
        }
    } @catch (__unused NSException *e) {}
}

// Pass 1: Find all hidden chat IDs (and any directly available name/message) across all databases
static void ZXScanDatabaseForHiddenIDs(NSString *dbPath, NSMutableDictionary<NSString *, NSMutableDictionary *> *results)
{
    if (!dbPath || !results) return;
    @try {
        sqlite3 *db = NULL;
        int flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX;
        if (sqlite3_open_v2(dbPath.UTF8String, &db, flags, NULL) != SQLITE_OK || !db) {
            if (db) sqlite3_close(db);
            return;
        }
        sqlite3_busy_timeout(db, 250);

        NSMutableArray<NSString *> *tables = [NSMutableArray new];
        sqlite3_stmt *tStmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &tStmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(tStmt) == SQLITE_ROW) {
                NSString *tName = ZXColumnText(tStmt, 0);
                if (tName.length && ![tName hasPrefix:@"sqlite_"]) [tables addObject:tName];
            }
        }
        if (tStmt) sqlite3_finalize(tStmt);

        for (NSString *table in tables) {
            NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", table];
            sqlite3_stmt *cStmt = NULL;
            if (sqlite3_prepare_v2(db, pragma.UTF8String, -1, &cStmt, NULL) != SQLITE_OK) {
                if (cStmt) sqlite3_finalize(cStmt);
                continue;
            }

            NSMutableArray<NSString *> *allCols = [NSMutableArray new];
            NSMutableArray<NSString *> *hideCols = [NSMutableArray new];
            NSString *idCol = nil;
            NSString *nameCol = nil;
            NSString *msgCol = nil;

            while (sqlite3_step(cStmt) == SQLITE_ROW) {
                NSString *col = ZXColumnText(cStmt, 1);
                if (!col.length) continue;
                [allCols addObject:col];
                NSString *lc = col.lowercaseString;
                if ([lc containsString:@"hidden"] || [lc containsString:@"hide"] || [lc isEqualToString:@"is_pin"] || [lc isEqualToString:@"pin_chat"]) {
                    if (![lc containsString:@"time"] && ![lc containsString:@"date"]) {
                        [hideCols addObject:col];
                    }
                }
                if (!idCol && ([lc isEqualToString:@"threadid"] || [lc isEqualToString:@"thread_id"] ||
                               [lc isEqualToString:@"conversationid"] || [lc isEqualToString:@"conversation_id"] ||
                               [lc isEqualToString:@"userid"] || [lc isEqualToString:@"user_id"] ||
                               [lc isEqualToString:@"uid"] || [lc isEqualToString:@"id"] ||
                               [lc isEqualToString:@"chatid"] || [lc isEqualToString:@"targetid"] ||
                               [lc isEqualToString:@"entityid"] || [lc isEqualToString:@"groupid"])) {
                    idCol = col;
                }
                if (!nameCol && ([lc containsString:@"displayname"] || [lc containsString:@"threadname"] ||
                                 [lc isEqualToString:@"name"] || [lc isEqualToString:@"title"] ||
                                 [lc containsString:@"username"] || [lc containsString:@"contactname"] ||
                                 [lc containsString:@"zaloname"] || [lc containsString:@"fullname"])) {
                    nameCol = col;
                }
                if (!msgCol && ([lc containsString:@"lastmsg"] || [lc containsString:@"lastmessage"] ||
                                [lc containsString:@"snippet"] || [lc isEqualToString:@"content"] ||
                                [lc isEqualToString:@"message"] || [lc isEqualToString:@"summary"])) {
                    msgCol = col;
                }
            }
            sqlite3_finalize(cStmt);

            NSString *tlc = table.lowercaseString;
            BOOL tableIsDedicatedHidden = ([tlc containsString:@"hiddenchat"] || [tlc containsString:@"hidechat"] || [tlc isEqualToString:@"hidden_chats"]);
            if (hideCols.count == 0 && !tableIsDedicatedHidden) continue;

            if (!idCol && allCols.count > 0) {
                idCol = allCols.firstObject;
            }

            NSMutableString *whereClause = [NSMutableString new];
            if (!tableIsDedicatedHidden && hideCols.count > 0) {
                NSMutableArray *conds = [NSMutableArray new];
                for (NSString *hc in hideCols) {
                    [conds addObject:[NSString stringWithFormat:@"(\"%@\" > 0 AND \"%@\" != '0' AND \"%@\" != '')", hc, hc, hc]];
                }
                [whereClause appendFormat:@" WHERE %@", [conds componentsJoinedByString:@" OR "]];
            }

            NSString *query = [NSString stringWithFormat:@"SELECT * FROM \"%@\"%@ LIMIT 150", table, whereClause];
            sqlite3_stmt *qStmt = NULL;
            if (sqlite3_prepare_v2(db, query.UTF8String, -1, &qStmt, NULL) == SQLITE_OK) {
                int colCount = sqlite3_column_count(qStmt);
                while (sqlite3_step(qStmt) == SQLITE_ROW) {
                    NSString *uid = @"";
                    NSString *name = @"";
                    NSString *msg = @"";

                    for (int c = 0; c < colCount; c++) {
                        const char * rawColName = sqlite3_column_name(qStmt, c);
                        NSString *cn = rawColName ? [NSString stringWithUTF8String:rawColName] : @"";
                        NSString *val = ZXColumnText(qStmt, c);
                        if (val.length == 0) continue;

                        if (idCol && [cn isEqualToString:idCol] && uid.length == 0) {
                            uid = val;
                        } else if (nameCol && [cn isEqualToString:nameCol] && name.length == 0 && !ZXIsGarbageString(val)) {
                            name = val;
                        } else if (msgCol && [cn isEqualToString:msgCol] && msg.length == 0 && !ZXIsGarbageString(val)) {
                            msg = val;
                        }
                        ZXTryParseJSONText(val, &name, &msg);
                    }

                    // Fallback if idCol was empty or numeric ID is in another column
                    if (uid.length == 0) {
                        for (int c = 0; c < colCount; c++) {
                            NSString *val = ZXColumnText(qStmt, c);
                            if (val.length >= 4 && !ZXIsGarbageString(val)) {
                                uid = val;
                                break;
                            }
                        }
                    }

                    if (uid.length == 0 || ZXIsGarbageString(uid)) continue;
                    if (ZXIsGarbageString(name)) name = @"";

                    NSMutableDictionary *entry = results[uid];
                    if (!entry) {
                        entry = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"uid": uid,
                            @"name": name,
                            @"lastMessage": msg,
                            @"sourceTable": [NSString stringWithFormat:@"%@ • %@", dbPath.lastPathComponent, table],
                            @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                        }];
                        results[uid] = entry;
                    } else {
                        if ([entry[@"name"] length] == 0 && name.length > 0) entry[@"name"] = name;
                        if ([entry[@"lastMessage"] length] == 0 && msg.length > 0) entry[@"lastMessage"] = msg;
                    }
                }
            }
            if (qStmt) sqlite3_finalize(qStmt);
        }

        sqlite3_close(db);
    } @catch (NSException *e) {
        ZXLog(@"Pass 1 SQLite scan exception on %@: %@", dbPath.lastPathComponent, e.reason);
    }
}

// Pass 2: Cross-reference discovered hidden chat IDs (e.g. 320193294) across all Contact/Friend/Group/Conversation/Message/Search tables in all SQLite DBs!
static void ZXEnrichHiddenChatsInDatabase(NSString *dbPath, NSMutableDictionary<NSString *, NSMutableDictionary *> *hiddenChats)
{
    if (!dbPath || hiddenChats.count == 0) return;

    // Check if any hidden chat still needs a real display name or last message
    NSMutableArray<NSString *> *targetIDs = [NSMutableArray new];
    for (NSString *uid in hiddenChats) {
        NSMutableDictionary *entry = hiddenChats[uid];
        if ([entry[@"name"] length] == 0 || [entry[@"lastMessage"] length] == 0) {
            [targetIDs addObject:uid];
        }
    }
    if (targetIDs.count == 0) return;

    @try {
        sqlite3 *db = NULL;
        int flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX;
        if (sqlite3_open_v2(dbPath.UTF8String, &db, flags, NULL) != SQLITE_OK || !db) {
            if (db) sqlite3_close(db);
            return;
        }
        sqlite3_busy_timeout(db, 250);

        NSMutableArray<NSString *> *tables = [NSMutableArray new];
        sqlite3_stmt *tStmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &tStmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(tStmt) == SQLITE_ROW) {
                NSString *tName = ZXColumnText(tStmt, 0);
                if (tName.length && ![tName hasPrefix:@"sqlite_"]) [tables addObject:tName];
            }
        }
        if (tStmt) sqlite3_finalize(tStmt);

        for (NSString *table in tables) {
            NSString *tlc = table.lowercaseString;
            if ([tlc containsString:@"hiddenchat"]) continue; // already scanned in pass 1

            NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", table];
            sqlite3_stmt *cStmt = NULL;
            if (sqlite3_prepare_v2(db, pragma.UTF8String, -1, &cStmt, NULL) != SQLITE_OK) {
                if (cStmt) sqlite3_finalize(cStmt);
                continue;
            }

            NSMutableArray<NSString *> *idCols = [NSMutableArray new];
            NSMutableArray<NSString *> *nameCols = [NSMutableArray new];
            NSMutableArray<NSString *> *msgCols = [NSMutableArray new];
            NSMutableArray<NSString *> *jsonCols = [NSMutableArray new];

            while (sqlite3_step(cStmt) == SQLITE_ROW) {
                NSString *col = ZXColumnText(cStmt, 1);
                if (!col.length) continue;
                NSString *lc = col.lowercaseString;

                if ([lc containsString:@"id"] || [lc isEqualToString:@"uid"] || [lc containsString:@"thread"] ||
                    [lc containsString:@"user"] || [lc containsString:@"group"] || [lc containsString:@"peer"] ||
                    [lc containsString:@"target"] || [lc containsString:@"owner"] || [lc containsString:@"sender"]) {
                    [idCols addObject:col];
                }
                if ([lc containsString:@"name"] || [lc containsString:@"title"] || [lc containsString:@"alias"] ||
                    [lc containsString:@"nick"] || [lc isEqualToString:@"keyword"] || [lc containsString:@"label"]) {
                    [nameCols addObject:col];
                }
                if ([lc containsString:@"msg"] || [lc containsString:@"message"] || [lc containsString:@"content"] ||
                    [lc containsString:@"snippet"] || [lc containsString:@"text"] || [lc containsString:@"body"] ||
                    [lc containsString:@"summary"] || [lc containsString:@"desc"] || [lc containsString:@"subtitle"]) {
                    [msgCols addObject:col];
                }
                if ([lc containsString:@"data"] || [lc containsString:@"json"] || [lc containsString:@"info"] ||
                    [lc containsString:@"ext"] || [lc containsString:@"payload"]) {
                    [jsonCols addObject:col];
                }
            }
            sqlite3_finalize(cStmt);

            if (idCols.count == 0 || (nameCols.count == 0 && msgCols.count == 0 && jsonCols.count == 0)) continue;

            for (NSString *uid in targetIDs) {
                NSMutableDictionary *entry = hiddenChats[uid];
                BOOL needName = ([entry[@"name"] length] == 0);
                BOOL needMsg = ([entry[@"lastMessage"] length] == 0);
                if (!needName && !needMsg) continue;

                // Extract core numeric digits if uid has a prefix (e.g. "u_320193294" -> "320193294")
                NSString *cleanDigits = [[uid componentsSeparatedByCharactersInSet:
                                         [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
                NSString *matchToken = (cleanDigits.length >= 5) ? cleanDigits : uid;

                NSMutableArray<NSString *> *whereParts = [NSMutableArray new];
                for (NSString *ic in idCols) {
                    [whereParts addObject:[NSString stringWithFormat:@"CAST(\"%@\" AS TEXT) = '%@'", ic, uid]];
                    if (![matchToken isEqualToString:uid]) {
                        [whereParts addObject:[NSString stringWithFormat:@"CAST(\"%@\" AS TEXT) = '%@'", ic, matchToken]];
                    }
                    [whereParts addObject:[NSString stringWithFormat:@"CAST(\"%@\" AS TEXT) LIKE '%%%@%%'", ic, matchToken]];
                }

                NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" WHERE %@ LIMIT 5",
                                 table, [whereParts componentsJoinedByString:@" OR "]];
                sqlite3_stmt *qStmt = NULL;
                if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &qStmt, NULL) == SQLITE_OK) {
                    int colCount = sqlite3_column_count(qStmt);
                    while (sqlite3_step(qStmt) == SQLITE_ROW) {
                        for (int c = 0; c < colCount; c++) {
                            const char *rawCol = sqlite3_column_name(qStmt, c);
                            NSString *cn = rawCol ? [NSString stringWithUTF8String:rawCol] : @"";
                            NSString *val = ZXColumnText(qStmt, c);
                            if (val.length == 0 || [val isEqualToString:uid] || [val isEqualToString:matchToken]) continue;

                            NSString *parsedName = @"";
                            NSString *parsedMsg = @"";
                            ZXTryParseJSONText(val, &parsedName, &parsedMsg);
                            if (parsedName.length > 0 && [entry[@"name"] length] == 0) {
                                entry[@"name"] = parsedName;
                            }
                            if (parsedMsg.length > 0 && [entry[@"lastMessage"] length] == 0) {
                                entry[@"lastMessage"] = parsedMsg;
                            }

                            if ([nameCols containsObject:cn] && [entry[@"name"] length] == 0 && !ZXIsGarbageString(val)) {
                                // Ensure it's not a pure numeric timestamp/ID
                                NSString *nonDigits = [val stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
                                if (nonDigits.length > 0) {
                                    entry[@"name"] = val;
                                }
                            }
                            if ([msgCols containsObject:cn] && [entry[@"lastMessage"] length] == 0 && !ZXIsGarbageString(val)) {
                                NSString *nonDigits = [val stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
                                if (nonDigits.length > 0 && ![val isEqualToString:entry[@"name"]]) {
                                    entry[@"lastMessage"] = val;
                                }
                            }
                        }
                    }
                }
                if (qStmt) sqlite3_finalize(qStmt);
            }
        }

        sqlite3_close(db);
    } @catch (NSException *e) {
        ZXLog(@"Pass 2 SQLite enrich exception on %@: %@", dbPath.lastPathComponent, e.reason);
    }
}

@implementation ZXScanner

+ (BOOL)isGarbageChatIdentifier:(NSString *)str
{
    return ZXIsGarbageString(str);
}

+ (NSString *)scanPath
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"scan.txt"];
}

+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *found = [NSMutableDictionary new];
    @try {
        NSSet<NSString *> *dbPaths = ZXAllZaloSQLitePaths();

        // Pass 1: Discover all hidden chat IDs from HiddenChatEntity & hidden columns
        for (NSString *path in dbPaths) {
            ZXScanDatabaseForHiddenIDs(path, found);
        }

        // Pass 2: Cross-query all databases to enrich every discovered ID with real Display Name & Last Message
        if (found.count > 0) {
            for (NSString *path in dbPaths) {
                ZXEnrichHiddenChatsInDatabase(path, found);
            }
        }

        // Finalize display strings for any entry where name or message wasn't in a separate table
        for (NSString *uid in found) {
            NSMutableDictionary *entry = found[uid];
            if ([entry[@"name"] length] == 0) {
                entry[@"name"] = [NSString stringWithFormat:@"UID: %@", uid];
            }
            if ([entry[@"lastMessage"] length] == 0) {
                NSString *src = entry[@"sourceTable"] ?: @"SQLite";
                entry[@"lastMessage"] = [NSString stringWithFormat:@"Hội thoại đang ẩn (%@)", src];
            }
        }

        ZXLog(@"SQLite hidden chat 2-pass scan inspected %lu DBs, resolved %lu hidden chats",
              (unsigned long)dbPaths.count, (unsigned long)found.count);
    } @catch (NSException *e) {
        ZXLog(@"scanSQLiteForHiddenChats exception: %@", e.reason);
    }
    return found.allValues ?: @[];
}

+ (BOOL)unhideChatInSQLiteWithID:(NSString *)chatID
{
    if (!chatID || chatID.length == 0) return NO;
    BOOL modifiedAny = NO;
    @try {
        NSString *cleanDigits = [[chatID componentsSeparatedByCharactersInSet:
                                 [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
        NSString *matchToken = (cleanDigits.length >= 5) ? cleanDigits : chatID;

        NSSet<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        for (NSString *dbPath in dbPaths) {
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK || !db) {
                if (db) sqlite3_close(db);
                continue;
            }
            sqlite3_busy_timeout(db, 300);

            NSMutableArray<NSString *> *tables = [NSMutableArray new];
            sqlite3_stmt *tStmt = NULL;
            if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &tStmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(tStmt) == SQLITE_ROW) {
                    NSString *tName = ZXColumnText(tStmt, 0);
                    if (tName.length && ![tName hasPrefix:@"sqlite_"]) [tables addObject:tName];
                }
            }
            if (tStmt) sqlite3_finalize(tStmt);

            for (NSString *table in tables) {
                NSString *tlc = table.lowercaseString;
                BOOL isDedicatedHiddenTable = ([tlc containsString:@"hiddenchat"] || [tlc containsString:@"hidechat"] || [tlc isEqualToString:@"hidden_chats"]);

                NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", table];
                sqlite3_stmt *cStmt = NULL;
                if (sqlite3_prepare_v2(db, pragma.UTF8String, -1, &cStmt, NULL) != SQLITE_OK) {
                    if (cStmt) sqlite3_finalize(cStmt);
                    continue;
                }
                NSMutableArray<NSString *> *idCols = [NSMutableArray new];
                NSMutableArray<NSString *> *hideCols = [NSMutableArray new];
                while (sqlite3_step(cStmt) == SQLITE_ROW) {
                    NSString *col = ZXColumnText(cStmt, 1);
                    if (!col.length) continue;
                    NSString *lc = col.lowercaseString;
                    if ([lc containsString:@"id"] || [lc isEqualToString:@"uid"] || [lc containsString:@"thread"] || [lc containsString:@"user"]) {
                        [idCols addObject:col];
                    }
                    if ([lc containsString:@"hidden"] || [lc containsString:@"hide"] || [lc isEqualToString:@"is_pin"]) {
                        if (![lc containsString:@"time"] && ![lc containsString:@"date"]) [hideCols addObject:col];
                    }
                }
                sqlite3_finalize(cStmt);

                if (idCols.count == 0) continue;
                NSMutableArray<NSString *> *whereParts = [NSMutableArray new];
                for (NSString *ic in idCols) {
                    [whereParts addObject:[NSString stringWithFormat:@"CAST(\"%@\" AS TEXT) = '%@'", ic, chatID]];
                    [whereParts addObject:[NSString stringWithFormat:@"CAST(\"%@\" AS TEXT) LIKE '%%%@%%'", ic, matchToken]];
                }
                NSString *whereSQL = [whereParts componentsJoinedByString:@" OR "];

                if (isDedicatedHiddenTable) {
                    NSString *delSQL = [NSString stringWithFormat:@"DELETE FROM \"%@\" WHERE %@", table, whereSQL];
                    if (sqlite3_exec(db, delSQL.UTF8String, NULL, NULL, NULL) == SQLITE_OK && sqlite3_changes(db) > 0) {
                        modifiedAny = YES;
                    }
                }
                if (hideCols.count > 0) {
                    for (NSString *hc in hideCols) {
                        NSString *updSQL = [NSString stringWithFormat:@"UPDATE \"%@\" SET \"%@\" = 0 WHERE %@", table, hc, whereSQL];
                        if (sqlite3_exec(db, updSQL.UTF8String, NULL, NULL, NULL) == SQLITE_OK && sqlite3_changes(db) > 0) {
                            modifiedAny = YES;
                        }
                    }
                }
            }
            sqlite3_close(db);
        }
    } @catch (NSException *e) {
        ZXLog(@"unhideChatInSQLiteWithID exception: %@", e.reason);
    }
    return modifiedAny;
}

+ (NSString *)runScan
{
    @try {
        NSArray<NSString *> *keywords = @[@"emitter", @"particle", @"lottie", @"magicword", @"keywordeffect", @"texteffect",
                                          @"chateffect", @"messageeffect", @"effectview", @"snow", @"firework", @"confetti",
                                          @"wallpaper", @"chatskin", @"chatbackground", @"chatbg", @"backgroundimage", @"themeitem",
                                          @"filesizelimit", @"maxfilesize", @"filelimit", @"maxsizefile", @"limitsend", @"checkfilesize",
                                          @"maxupload", @"sendfile", @"uploadlimit", @"qualitypicker", @"sendhd", @"originalquality",
                                          @"customfont", @"fontstyle", @"profilemusic", @"musicprofile",
                                          @"sendsticker", @"stickersend", @"sendgif", @"sendstickerto", @"stickermessage",
                                          @"hiddenchat", @"ishidden", @"hiddenconversation", @"filterhidden", @"unhide",
                                          @"hiddentype", @"ishide", @"hidestatus", @"hidechat", @"pinchat",
                                          @"storyseen", @"markstory", @"viewstory", @"sendseenstory",
                                          @"icecandidate", @"icetransport", @"forcerelay", @"webrtc",
                                          @"voicemessage", @"audiomessage", @"sendtext", @"sendmessage"];
        NSArray<NSString *> *videoWords = @[@"quality", @"compress", @"export", @"preset", @"bitrate", @"resolution", @"hd", @"original",
                                            @"maxsize", @"upload", @"encode", @"convert", @"transcode", @"send", @"pickerquality"];
        NSArray<NSString *> *noise = @[@"tracking", @"banner", @"constraint", @"analytics", @"reddot"];
        NSString *appPath = [[NSBundle mainBundle] bundlePath];
        unsigned count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableString *out = [NSMutableString stringWithFormat:@"# ZaloXposed scan - %u classes total\n# format: [+/-][Class sel] returnType args | image\n", count];
        NSUInteger lines = 0;

        for (unsigned i = 0; i < count && lines < 2500; i++) {
            Class c = classes[i];
            const char *image = class_getImageName(c);
            if (!image || strncmp(image, appPath.UTF8String, appPath.length) != 0) continue;
            NSString *cname = NSStringFromClass(c);
            NSString *imageName = [[NSString stringWithUTF8String:image] lastPathComponent];

            for (int meta = 0; meta < 2; meta++) {
                Class k = meta ? object_getClass(c) : c;
                unsigned mc = 0;
                Method *ms = class_copyMethodList(k, &mc);
                for (unsigned j = 0; j < mc; j++) {
                    NSString *sel = NSStringFromSelector(method_getName(ms[j]));
                    NSString *lower = sel.lowercaseString;
                    NSString *lowerClass = cname.lowercaseString;
                    BOOL hit = NO;
                    for (NSString *kw in keywords)
                        if ([lower containsString:kw] || [lowerClass containsString:kw]) { hit = YES; break; }
                    if (!hit && ([lower containsString:@"video"] || [lower containsString:@"pickerquality"])) {
                        for (NSString *vw in videoWords)
                            if ([lower containsString:vw]) { hit = YES; break; }
                    }
                    if (!hit) continue;
                    for (NSString *nz in noise)
                        if ([lower containsString:nz] || [lowerClass containsString:nz]) { hit = NO; break; }
                    if (!hit) continue;
                    char *ret = method_copyReturnType(ms[j]);
                    NSMutableString *args = [NSMutableString new];
                    for (unsigned a = 2; a < method_getNumberOfArguments(ms[j]); a++) {
                        char *t = method_copyArgumentType(ms[j], a);
                        [args appendFormat:@"%s ", t ?: "?"];
                        if (t) free(t);
                    }
                    [out appendFormat:@"%c[%@ %@] ret=%s args=%@| %@\n", meta ? '+' : '-', cname, sel, ret ?: "?", args, imageName];
                    if (ret) free(ret);
                    lines++;
                }
                if (ms) free(ms);
            }
        }
        if (classes) free(classes);
        [out writeToFile:[self scanPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        ZXLog(@"scan done: %lu matches", (unsigned long)lines);
    } @catch (NSException *e) {
        ZXLog(@"runScan exception: %@", e.reason);
    }
    return [self scanPath];
}

@end
