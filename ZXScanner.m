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

    NSArray<NSString *> *badSubstrings = @[
        @"viewcontroller", @"tableview", @"collectionview", @"pinboard",
        @"uiview", @"uilabel", @"uibutton", @"uicontrol", @"uiwindow",
        @"navigation", @"tabbar", @"scrollview", @"cell", @"delegate",
        @"datasource", @"manager", @"controller", @"presenter", @"viewmodel",
        @"helper", @"processor", @"entity", @"config", @"layout", @"adapter",
        @"sqlite_master", @"sqlite_sequence", @"http://", @"https://",
        @"/var/", @"/private/", @"/library/", @"/documents/", @".png", @".jpg", @".sqlite"
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

/// Checks if a candidate string is a valid human/group display name (2-60 chars, has letters, not a URL/path/UUID/number).
static BOOL ZXIsValidHumanDisplayName(NSString *s, NSString *excludeUID)
{
    if (!s) return NO;
    NSString *trim = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length < 2 || trim.length > 60) return NO;
    if (excludeUID.length && [trim isEqualToString:excludeUID]) return NO;
    if (ZXIsGarbageString(trim)) return NO;

    // Must contain at least one letter (Latin or Vietnamese Unicode letter)
    NSRange letterRange = [trim rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
    if (letterRange.location == NSNotFound) return NO;

    // Reject pure hex/UUID/base64-like tokens with no spaces and length >= 20
    if ([trim rangeOfString:@" "].location == NSNotFound && trim.length >= 20) {
        NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
        NSString *rem = [trim stringByTrimmingCharactersInSet:alnum];
        if (rem.length <= 2) return NO;
    }

    // Reject strings containing control characters or SQLite binary noise
    for (NSUInteger i = 0; i < trim.length; i++) {
        unichar c = [trim characterAtIndex:i];
        if (c < 32 || c == 0xFFFD) return NO;
    }
    return YES;
}

/// Extracts readable UTF-8 strings (e.g. from serialized JSON/Protobuf/plist blobs in SQLite BLOB columns).
static NSArray<NSString *> *ZXExtractReadableStringsFromBlob(const void *bytes, int length)
{
    if (!bytes || length <= 2) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    const uint8_t *buf = (const uint8_t *)bytes;
    int start = -1;
    for (int i = 0; i < length; i++) {
        uint8_t b = buf[i];
        BOOL printable = (b >= 32 && b != 127);
        if (printable) {
            if (start < 0) start = i;
        } else {
            if (start >= 0 && (i - start) >= 3 && (i - start) <= 200) {
                NSString *s = [[NSString alloc] initWithBytes:(buf + start) length:(NSUInteger)(i - start) encoding:NSUTF8StringEncoding];
                if (s.length >= 2) [out addObject:s];
            }
            start = -1;
        }
    }
    if (start >= 0 && (length - start) >= 3 && (length - start) <= 200) {
        NSString *s = [[NSString alloc] initWithBytes:(buf + start) length:(NSUInteger)(length - start) encoding:NSUTF8StringEncoding];
        if (s.length >= 2) [out addObject:s];
    }
    return out;
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

static void ZXCollectSQLiteFilesInDir(NSString *dir, NSMutableArray<NSString *> *outPaths, NSMutableSet<NSString *> *seen, int depth)
{
    if (!dir || depth > 5 || outPaths.count >= 80) return;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if ([name hasPrefix:@"."]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                ZXCollectSQLiteFilesInDir(full, outPaths, seen, depth + 1);
            } else if (![seen containsObject:full] && ZXIsSQLiteFileAtPath(full)) {
                [seen addObject:full];
                // Put global.sqlite / search / contact / message DBs first
                NSString *lc = name.lowercaseString;
                if ([lc containsString:@"global"] || [lc containsString:@"contact"] || [lc containsString:@"chat"] || [lc containsString:@"msg"]) {
                    [outPaths insertObject:full atIndex:0];
                } else {
                    [outPaths addObject:full];
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

static NSArray<NSString *> *ZXAllZaloSQLitePaths(void)
{
    NSMutableArray<NSString *> *dbPaths = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        ZXCollectSQLiteFilesInDir([home stringByAppendingPathComponent:@"Documents"], dbPaths, seen, 0);
        ZXCollectSQLiteFilesInDir([home stringByAppendingPathComponent:@"Library"], dbPaths, seen, 0);
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
            ZXCollectSQLiteFilesInDir(gURL.path, dbPaths, seen, 0);
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

static void ZXTryParseJSONText(NSString *raw, NSString *excludeUID, NSString **ioName, NSString **ioMsg)
{
    if (!raw || raw.length < 4) return;
    NSString *trim = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trim hasPrefix:@"{"] || ![trim hasSuffix:@"}"]) return;
    @try {
        NSData *d = [trim dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![dict isKindOfClass:[NSDictionary class]]) return;
        for (NSString *nk in @[@"displayName", @"dName", @"name", @"threadName", @"title", @"zaloName", @"fullName", @"userName", @"groupName", @"contactName"]) {
            id v = dict[nk];
            if ([v isKindOfClass:[NSString class]] && ZXIsValidHumanDisplayName(v, excludeUID)) {
                if (ioName && (*ioName).length == 0) *ioName = v;
                break;
            }
        }
        for (NSString *mk in @[@"message", @"msg", @"content", @"text", @"lastMessage", @"snippet", @"desc"]) {
            id v = dict[mk];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 && !ZXIsGarbageString(v)) {
                if (ioMsg && (*ioMsg).length == 0) *ioMsg = v;
                break;
            }
        }
    } @catch (__unused NSException *e) {}
}

/// Inspects all columns (TEXT and BLOB) of a statement row to extract the best human display name and message snippet.
static void ZXExtractNameAndMessageFromRow(sqlite3_stmt *stmt,
                                           NSString *uid,
                                           NSArray<NSString *> *preferredNameCols,
                                           NSArray<NSString *> *preferredMsgCols,
                                           NSString **ioName,
                                           NSString **ioMsg)
{
    int colCount = sqlite3_column_count(stmt);
    // 1. Check preferred name/message columns first
    for (int c = 0; c < colCount; c++) {
        const char *rawCol = sqlite3_column_name(stmt, c);
        NSString *cn = rawCol ? [NSString stringWithUTF8String:rawCol] : @"";
        int colType = sqlite3_column_type(stmt, c);
        if (colType == SQLITE_TEXT) {
            NSString *val = ZXColumnText(stmt, c);
            if (val.length == 0) continue;
            ZXTryParseJSONText(val, uid, ioName, ioMsg);
            if ([preferredNameCols containsObject:cn] && (*ioName).length == 0 && ZXIsValidHumanDisplayName(val, uid)) {
                *ioName = [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            }
            if ([preferredMsgCols containsObject:cn] && (*ioMsg).length == 0 && val.length >= 2 && !ZXIsGarbageString(val) && ![val isEqualToString:uid]) {
                NSString *nonDigits = [val stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
                if (nonDigits.length > 0 && ![val isEqualToString:*ioName]) {
                    *ioMsg = [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                }
            }
        } else if (colType == SQLITE_BLOB) {
            const void *blob = sqlite3_column_blob(stmt, c);
            int bytes = sqlite3_column_bytes(stmt, c);
            NSArray<NSString *> *strs = ZXExtractReadableStringsFromBlob(blob, bytes);
            for (NSString *s in strs) {
                ZXTryParseJSONText(s, uid, ioName, ioMsg);
                if ((*ioName).length == 0 && ZXIsValidHumanDisplayName(s, uid)) {
                    *ioName = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                }
            }
        }
    }

    // 2. Fallback: scan any remaining TEXT column on the exact-matched row for a valid human display name
    if ((*ioName).length == 0) {
        for (int c = 0; c < colCount; c++) {
            if (sqlite3_column_type(stmt, c) != SQLITE_TEXT) continue;
            NSString *val = ZXColumnText(stmt, c);
            if (ZXIsValidHumanDisplayName(val, uid)) {
                *ioName = [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                break;
            }
        }
    }
}

/// Checks if a column name is a primary entity/user/thread/group identifier (NOT senderId/ownerId/messageId).
static BOOL ZXIsExactEntityIDColumn(NSString *colName)
{
    NSString *lc = colName.lowercaseString;
    if ([lc containsString:@"sender"] || [lc containsString:@"owner"] || [lc containsString:@"from"] ||
        [lc containsString:@"creator"] || [lc containsString:@"author"] || [lc containsString:@"msgid"] ||
        [lc containsString:@"messageid"] || [lc containsString:@"clientid"] || [lc containsString:@"globalmsg"]) {
        return NO;
    }
    return ([lc isEqualToString:@"id"] ||
            [lc isEqualToString:@"uid"] ||
            [lc isEqualToString:@"userid"] ||
            [lc isEqualToString:@"user_id"] ||
            [lc isEqualToString:@"threadid"] ||
            [lc isEqualToString:@"thread_id"] ||
            [lc isEqualToString:@"conversationid"] ||
            [lc isEqualToString:@"conversation_id"] ||
            [lc isEqualToString:@"groupid"] ||
            [lc isEqualToString:@"group_id"] ||
            [lc isEqualToString:@"contactid"] ||
            [lc isEqualToString:@"contact_id"] ||
            [lc isEqualToString:@"friendid"] ||
            [lc isEqualToString:@"friend_id"] ||
            [lc isEqualToString:@"entityid"] ||
            [lc isEqualToString:@"entity_id"] ||
            [lc isEqualToString:@"targetid"] ||
            [lc isEqualToString:@"target_id"] ||
            [lc isEqualToString:@"peerid"] ||
            [lc isEqualToString:@"peer_id"] ||
            [lc isEqualToString:@"zaloid"] ||
            [lc isEqualToString:@"zalo_id"] ||
            [lc isEqualToString:@"chatid"] ||
            [lc isEqualToString:@"chat_id"]);
}

// Pass 1: Read HiddenChatEntity (and any table with explicit hidden chat flags)
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
            NSMutableArray<NSString *> *idCols = [NSMutableArray new];
            NSMutableArray<NSString *> *nameCols = [NSMutableArray new];
            NSMutableArray<NSString *> *msgCols = [NSMutableArray new];

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
                if (ZXIsExactEntityIDColumn(col)) {
                    [idCols addObject:col];
                }
                if ([lc containsString:@"name"] || [lc containsString:@"title"] || [lc containsString:@"alias"] || [lc containsString:@"nick"]) {
                    [nameCols addObject:col];
                }
                if ([lc containsString:@"lastmsg"] || [lc containsString:@"lastmessage"] ||
                    [lc containsString:@"snippet"] || [lc isEqualToString:@"content"] ||
                    [lc isEqualToString:@"message"] || [lc isEqualToString:@"summary"]) {
                    [msgCols addObject:col];
                }
            }
            sqlite3_finalize(cStmt);

            NSString *tlc = table.lowercaseString;
            BOOL tableIsDedicatedHidden = ([tlc containsString:@"hiddenchat"] || [tlc containsString:@"hidechat"] || [tlc isEqualToString:@"hidden_chats"]);
            if (hideCols.count == 0 && !tableIsDedicatedHidden) continue;

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
                    // Find UID from idCols first
                    for (int c = 0; c < colCount; c++) {
                        const char *rawColName = sqlite3_column_name(qStmt, c);
                        NSString *cn = rawColName ? [NSString stringWithUTF8String:rawColName] : @"";
                        if ([idCols containsObject:cn]) {
                            NSString *val = [ZXColumnText(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            if (val.length > 0 && !ZXIsGarbageString(val)) {
                                uid = val;
                                break;
                            }
                        }
                    }
                    // Fallback in dedicated HiddenChatEntity table: look for any numeric ID column (>= 5 digits)
                    if (uid.length == 0 && tableIsDedicatedHidden) {
                        for (int c = 0; c < colCount; c++) {
                            NSString *val = [ZXColumnText(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            NSString *rem = [val stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
                            if (val.length >= 5 && rem.length == 0) {
                                uid = val;
                                break;
                            }
                        }
                    }
                    if (uid.length == 0 || ZXIsGarbageString(uid)) continue;

                    NSString *name = @"";
                    NSString *msg = @"";
                    ZXExtractNameAndMessageFromRow(qStmt, uid, nameCols, msgCols, &name, &msg);

                    NSMutableDictionary *entry = results[uid];
                    if (!entry) {
                        entry = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"uid": uid,
                            @"rawName": name ?: @"",
                            @"lastMessage": msg ?: @"",
                            @"sourceDB": dbPath,
                            @"sourceTable": [NSString stringWithFormat:@"%@ • %@", dbPath.lastPathComponent, table],
                            @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                        }];
                        results[uid] = entry;
                    } else {
                        if ([entry[@"rawName"] length] == 0 && name.length > 0) entry[@"rawName"] = name;
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

// Pass 2: Strict Exact-ID Cross-Reference (`WHERE col = '320193294' OR col = 320193294` — NEVER LIKE '%...%')
static void ZXEnrichHiddenChatsInDatabase(NSString *dbPath, NSMutableDictionary<NSString *, NSMutableDictionary *> *hiddenChats)
{
    if (!dbPath || hiddenChats.count == 0) return;

    NSMutableArray<NSString *> *targetIDs = [NSMutableArray new];
    for (NSString *uid in hiddenChats) {
        NSMutableDictionary *entry = hiddenChats[uid];
        if ([entry[@"rawName"] length] == 0 || [entry[@"lastMessage"] length] == 0) {
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
                if (tName.length && ![tName hasPrefix:@"sqlite_"]) {
                    // Prioritize Contact / User / Friend / Group / Search / Conversation tables before Message tables
                    NSString *tlc = tName.lowercaseString;
                    if ([tlc containsString:@"contact"] || [tlc containsString:@"user"] ||
                        [tlc containsString:@"friend"] || [tlc containsString:@"group"] ||
                        [tlc containsString:@"profile"] || [tlc containsString:@"search"] ||
                        [tlc containsString:@"conversation"] || [tlc containsString:@"thread"]) {
                        [tables insertObject:tName atIndex:0];
                    } else {
                        [tables addObject:tName];
                    }
                }
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

            NSMutableArray<NSString *> *idCols = [NSMutableArray new];
            NSMutableArray<NSString *> *nameCols = [NSMutableArray new];
            NSMutableArray<NSString *> *msgCols = [NSMutableArray new];

            while (sqlite3_step(cStmt) == SQLITE_ROW) {
                NSString *col = ZXColumnText(cStmt, 1);
                if (!col.length) continue;
                NSString *lc = col.lowercaseString;

                if (ZXIsExactEntityIDColumn(col)) {
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
            }
            sqlite3_finalize(cStmt);

            if (idCols.count == 0) continue;

            for (NSString *uid in targetIDs) {
                NSMutableDictionary *entry = hiddenChats[uid];
                BOOL needName = ([entry[@"rawName"] length] == 0);
                BOOL needMsg = ([entry[@"lastMessage"] length] == 0);
                if (!needName && !needMsg) continue;

                NSString *cleanDigits = [[uid componentsSeparatedByCharactersInSet:
                                         [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
                BOOL isNumeric = (cleanDigits.length >= 4 && [cleanDigits isEqualToString:uid]);

                // Strict exact match ONLY: col = '320193294' OR col = 320193294
                NSMutableArray<NSString *> *whereParts = [NSMutableArray new];
                for (NSString *ic in idCols) {
                    [whereParts addObject:[NSString stringWithFormat:@"\"%@\" = '%@'", ic, uid]];
                    if (isNumeric) {
                        [whereParts addObject:[NSString stringWithFormat:@"\"%@\" = %@", ic, cleanDigits]];
                    } else if (cleanDigits.length >= 5) {
                        [whereParts addObject:[NSString stringWithFormat:@"\"%@\" = '%@'", ic, cleanDigits]];
                        [whereParts addObject:[NSString stringWithFormat:@"\"%@\" = %@", ic, cleanDigits]];
                    }
                }

                NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" WHERE %@ LIMIT 3",
                                 table, [whereParts componentsJoinedByString:@" OR "]];
                sqlite3_stmt *qStmt = NULL;
                if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &qStmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(qStmt) == SQLITE_ROW) {
                        NSString *foundName = entry[@"rawName"] ?: @"";
                        NSString *foundMsg = entry[@"lastMessage"] ?: @"";
                        ZXExtractNameAndMessageFromRow(qStmt, uid, nameCols, msgCols, &foundName, &foundMsg);
                        if (foundName.length > 0 && [entry[@"rawName"] length] == 0) {
                            entry[@"rawName"] = foundName;
                            ZXLog(@"Resolved exact name for UID %@ -> '%@' from %@.%@", uid, foundName, dbPath.lastPathComponent, table);
                        }
                        if (foundMsg.length > 0 && [entry[@"lastMessage"] length] == 0) {
                            entry[@"lastMessage"] = foundMsg;
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

+ (BOOL)isValidHumanDisplayName:(NSString *)str excludeUID:(NSString *)excludeUID
{
    return ZXIsValidHumanDisplayName(str, excludeUID);
}

+ (NSString *)scanPath
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"scan.txt"];
}

+ (NSString *)resolvedProfilesPath
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"zx_resolved_profiles.json"];
}

+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *found = [NSMutableDictionary new];
    @try {
        // Load RAM-indexed decrypted profiles from zx_resolved_profiles.json
        NSDictionary<NSString *, NSDictionary *> *ramProfiles = @{};
        NSData *ramData = [NSData dataWithContentsOfFile:[self resolvedProfilesPath]];
        if (ramData) {
            id obj = [NSJSONSerialization JSONObjectWithData:ramData options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                ramProfiles = (NSDictionary *)obj;
            }
        }

        // Include any profile that was flagged as hidden directly in RAM
        for (NSString *uid in ramProfiles) {
            if (ZXIsGarbageString(uid)) continue;
            NSDictionary *prof = ramProfiles[uid];
            if (![prof isKindOfClass:[NSDictionary class]]) continue;
            if ([prof[@"isHidden"] boolValue]) {
                NSString *rName = [prof[@"name"] description] ?: @"";
                NSString *rMsg = [prof[@"lastMessage"] description] ?: @"";
                found[uid] = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"uid": uid,
                    @"rawName": ZXIsValidHumanDisplayName(rName, uid) ? rName : @"",
                    @"lastMessage": rMsg,
                    @"sourceTable": @"RAM Cache (zx_resolved_profiles.json)",
                    @"updatedAt": prof[@"timestamp"] ?: @((long long)[[NSDate date] timeIntervalSince1970])
                }];
            }
        }

        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();

        // Pass 1: Discover all hidden chat IDs from HiddenChatEntity & hidden columns
        for (NSString *path in dbPaths) {
            ZXScanDatabaseForHiddenIDs(path, found);
        }

        // Overlay RAM-decrypted profile names & messages onto every discovered hidden chat ID
        for (NSString *uid in found) {
            NSMutableDictionary *entry = found[uid];
            NSDictionary *prof = ramProfiles[uid];
            if (!prof) {
                NSString *cleanDigits = [[uid componentsSeparatedByCharactersInSet:
                                         [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
                if (cleanDigits.length >= 5) prof = ramProfiles[cleanDigits];
            }
            if ([prof isKindOfClass:[NSDictionary class]]) {
                NSString *pName = [prof[@"name"] description] ?: @"";
                NSString *pMsg = [prof[@"lastMessage"] description] ?: @"";
                if (ZXIsValidHumanDisplayName(pName, uid)) {
                    entry[@"rawName"] = pName;
                }
                if (pMsg.length > 0 && !ZXIsGarbageString(pMsg)) {
                    entry[@"lastMessage"] = pMsg;
                }
            }
        }

        // Pass 2: First enrich inside the same DB where each hidden chat was found (e.g. search/global.sqlite), then across all other SQLite DBs
        if (found.count > 0) {
            NSMutableSet<NSString *> *sourceDBs = [NSMutableSet new];
            for (NSString *uid in found) {
                NSString *sDB = found[uid][@"sourceDB"];
                if (sDB.length) [sourceDBs addObject:sDB];
            }
            for (NSString *sDB in sourceDBs) {
                ZXEnrichHiddenChatsInDatabase(sDB, found);
            }
            for (NSString *path in dbPaths) {
                if (![sourceDBs containsObject:path]) {
                    ZXEnrichHiddenChatsInDatabase(path, found);
                }
            }
        }

        // Format final unambiguous display strings
        NSMutableArray<NSDictionary *> *finalList = [NSMutableArray new];
        for (NSString *uid in found) {
            NSMutableDictionary *entry = found[uid];
            NSString *rawName = entry[@"rawName"] ?: @"";
            NSString *displayTitle = rawName.length > 0
                ? [NSString stringWithFormat:@"%@ (ID: %@)", rawName, uid]
                : [NSString stringWithFormat:@"Chưa giải mã tên • ID: %@", uid];
            NSString *lastMsg = entry[@"lastMessage"] ?: @"";
            if (lastMsg.length == 0) {
                NSString *src = entry[@"sourceTable"] ?: @"SQLite";
                lastMsg = [NSString stringWithFormat:@"Tìm thấy trong %@", src];
            }
            [finalList addObject:@{
                @"uid": uid,
                @"rawName": rawName,
                @"name": displayTitle,
                @"lastMessage": lastMsg,
                @"updatedAt": entry[@"updatedAt"] ?: @0
            }];
        }

        ZXLog(@"SQLite+RAM exact-match scan inspected %lu DBs (%lu RAM profiles), resolved %lu hidden chats",
              (unsigned long)dbPaths.count, (unsigned long)ramProfiles.count, (unsigned long)finalList.count);
        return finalList;
    } @catch (NSException *e) {
        ZXLog(@"scanSQLiteForHiddenChats exception: %@", e.reason);
        return @[];
    }
}

+ (BOOL)unhideChatInSQLiteWithID:(NSString *)chatID
{
    if (!chatID || chatID.length == 0) return NO;
    BOOL modifiedAny = NO;
    @try {
        NSString *cleanDigits = [[chatID componentsSeparatedByCharactersInSet:
                                 [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
        BOOL isNumeric = (cleanDigits.length >= 4 && [cleanDigits isEqualToString:chatID]);

        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
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
                    if (ZXIsExactEntityIDColumn(col)) {
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
                    [whereParts addObject:[NSString stringWithFormat:@"\"%@\" = '%@'", ic, chatID]];
                    if (isNumeric) {
                        [whereParts addObject:[NSString stringWithFormat:@"\"%@\" = %@", ic, cleanDigits]];
                    }
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
