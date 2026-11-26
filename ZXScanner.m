#import <UIKit/UIKit.h>
#import "ZXScanner.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import <objc/runtime.h>
#import <sqlite3.h>
#import <string.h>

/// Only rejects empty strings, file paths, SQLite internal names, and pure runtime class names (UIView, UITableViewCell, _TtC..., ZA...Cell).
/// NEVER rejects valid numeric IDs or display titles like "Hội thoại ẩn (ID: ...)".
static BOOL ZXIsSystemClassOrEmpty(NSString *s)
{
    if (!s || s.length == 0) return YES;
    NSString *trim = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length == 0) return YES;
    NSString *lc = trim.lowercaseString;

    if ([lc isEqualToString:@"sqlite_master"] || [lc isEqualToString:@"sqlite_sequence"] ||
        [lc isEqualToString:@"(null)"] || [lc isEqualToString:@"null"] || [lc isEqualToString:@"nil"]) {
        return YES;
    }
    if ([lc hasPrefix:@"/var/"] || [lc hasPrefix:@"/private/"] || [lc hasPrefix:@"http://"] || [lc hasPrefix:@"https://"] ||
        [lc hasSuffix:@".sqlite"] || [lc hasSuffix:@".png"] || [lc hasSuffix:@".jpg"]) {
        return YES;
    }
    if ([trim rangeOfString:@" "].location == NSNotFound) {
        if ([trim hasPrefix:@"_TtC"] || [trim hasPrefix:@"_TtG"] || [trim hasPrefix:@"_UI"] || [trim hasPrefix:@"UI"] ||
            [trim hasPrefix:@"NS"] || [trim hasPrefix:@"ZX"] || [trim hasPrefix:@"WK"] || [trim hasPrefix:@"CA"]) {
            return YES;
        }
        NSArray<NSString *> *clsSuffixes = @[
            @"viewcontroller", @"tableviewcell", @"collectionviewcell", @"tableview",
            @"collectionview", @"navigationbar", @"tabbar", @"scrollview", @"viewmodel",
            @"datasource", @"delegate", @"presenter"
        ];
        for (NSString *sfx in clsSuffixes) {
            if ([lc hasSuffix:sfx]) return YES;
        }
        if (([trim hasPrefix:@"ZA"] || [trim hasPrefix:@"ZDS"] || [trim hasPrefix:@"UX"]) && trim.length > 4) {
            NSRange digitRange = [trim rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet];
            if (digitRange.location == NSNotFound) return YES;
        }
    }
    return NO;
}

/// Checks if a candidate string is a valid human/group display name (1-60 chars, has letters, not placeholder/phone/time/status/class).
static BOOL ZXIsValidHumanDisplayName(NSString *s, NSString *excludeUID)
{
    if (!s) return NO;
    NSString *trim = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length < 1 || trim.length > 60) return NO;
    if (excludeUID.length && [trim isEqualToString:excludeUID]) return NO;
    if (ZXIsSystemClassOrEmpty(trim)) return NO;

    NSString *lc = trim.lowercaseString;
    NSArray<NSString *> *badNamePhrases = @[
        @"ảnh đã hết hạn", @"video đã hết hạn", @"file đã hết hạn", @"tệp đã hết hạn",
        @"tin nhắn đã thu hồi", @"tin nhắn đã được thu hồi", @"đã thu hồi",
        @"hiddenchatentity", @"search/global.sqlite", @"global.sqlite", @".sqlite",
        @"nhập pin", @"nhập mã pin", @"đang hoạt động", @"vừa xong", @"chạm để", @"xem thêm",
        @"hội thoại ẩn", @"trò chuyện ẩn", @"chưa giải mã", @"không tìm thấy",
        @"kết quả tìm kiếm", @"chưa có tin nhắn", @"tìm kiếm gần đây", @"liên hệ gần đây",
        @"từ khóa tìm kiếm", @"không có kết quả", @"vừa truy cập", @"đang nhập",
        @"cuộc gọi thoại", @"cuộc gọi video", @"cuộc gọi nhỡ", @"official account",
        @"đã xác thực tên", @"đã xóa tên cũ", @"đã xóa cache", @"đã lưu tên thật",
        @"thông tin này chưa được liên kết"
    ];
    for (NSString *bad in badNamePhrases) {
        if ([lc containsString:bad]) return NO;
    }
    if ([lc hasPrefix:@"bạn: "] || [lc hasPrefix:@"hoạt động "] || [lc hasPrefix:@"["] ||
        [lc hasPrefix:@"uid:"] || [lc hasPrefix:@"id:"] || [lc hasPrefix:@"tin nhắn ("] ||
        [lc hasPrefix:@"liên hệ ("] || [lc hasPrefix:@"link ("] || [lc hasPrefix:@"file ("] ||
        [lc isEqualToString:@"đã gửi"] || [lc isEqualToString:@"đã nhận"] || [lc isEqualToString:@"đã xem"]) {
        return NO;
    }
    NSArray<NSString *> *uiTitles = @[
        @"tùy chọn", @"cài đặt", @"ẩn trò chuyện", @"ẩn hội thoại", @"tin nhắn",
        @"danh bạ", @"khám phá", @"nhật ký", @"cá nhân", @"tìm kiếm",
        @"thông tin", @"liên hệ", @"trò chuyện ẩn", @"mã pin", @"tất cả",
        @"chưa đọc", @"phân loại", @"nhóm", @"bạn bè", @"gợi ý", @"oa",
        @"link", @"file", @"tệp", @"ảnh", @"video",
        @"options", @"settings", @"messages", @"contacts", @"search"
    ];
    for (NSString *t in uiTitles) {
        if ([lc isEqualToString:t]) return NO;
    }

    // Must contain at least one Unicode letter (Latin / Vietnamese, e.g. "MẸ", "Hồ Kiến Quốc")
    NSRange letterRange = [trim rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
    if (letterRange.location == NSNotFound) return NO;

    NSUInteger digitCount = 0;
    for (NSUInteger i = 0; i < trim.length; i++) {
        unichar c = [trim characterAtIndex:i];
        if (c >= '0' && c <= '9') digitCount++;
        if (c < 32 || c == 0xFFFD) return NO;
    }
    if (digitCount >= 7) {
        NSCharacterSet *phoneSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789+-(). "];
        if ([[trim stringByTrimmingCharactersInSet:phoneSet] length] <= 2) return NO;
    }
    if (trim.length <= 6 && ([trim containsString:@":"] || [trim containsString:@"/"])) return NO;

    if ([trim rangeOfString:@" "].location == NSNotFound && trim.length >= 22) {
        NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
        NSString *rem = [trim stringByTrimmingCharactersInSet:alnum];
        if (rem.length <= 2) return NO;
    }
    return YES;
}

static NSString *ZXExtractDigitCore(NSString *raw)
{
    if (!raw || raw.length == 0) return @"";
    return [[raw componentsSeparatedByCharactersInSet:
             [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
}

static BOOL ZXLooksLikeEpochTimestampNumber(long long num)
{
    // 10-digit seconds (2017..2039) or 13-digit milliseconds / 16-digit microseconds
    if (num >= 1500000000LL && num <= 2200000000LL) return YES;
    if (num >= 1500000000000LL && num <= 2200000000000LL) return YES;
    if (num >= 1500000000000000LL && num <= 2200000000000000LL) return YES;
    return NO;
}

/// Strictly rejects timestamp, PIN, flag, status, and sender/message metadata columns in SQLite.
static BOOL ZXIsTimestampOrMetaColumn(NSString *colName)
{
    if (!colName || colName.length == 0) return YES;
    NSString *lc = colName.lowercaseString;
    NSArray<NSString *> *badTokens = @[
        @"time", @"date", @"stamp", @"created", @"updated", @"modified",
        @"expire", @"ttl", @"pin", @"status", @"state", @"flag", @"type",
        @"version", @"ver", @"seq", @"order", @"sort", @"count", @"unread",
        @"deleted", @"sync", @"sender", @"owner", @"author", @"creator",
        @"from", @"msgid", @"messageid", @"clientid", @"globalmsg"
    ];
    for (NSString *tok in badTokens) {
        if ([lc containsString:tok]) return YES;
    }
    return NO;
}

static BOOL ZXIsSpecificChatIDColumn(NSString *colName)
{
    if (!colName || ZXIsTimestampOrMetaColumn(colName)) return NO;
    NSString *lc = colName.lowercaseString;
    return ([lc isEqualToString:@"uid"] ||
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
            [lc isEqualToString:@"chat_id"] ||
            [lc isEqualToString:@"zthreadid"] ||
            [lc isEqualToString:@"zuserid"]);
}

static BOOL ZXIsPreferredHiddenIDColumn(NSString *colName)
{
    if (!colName || ZXIsTimestampOrMetaColumn(colName)) return NO;
    NSString *lc = colName.lowercaseString;
    return ([lc containsString:@"uid"] ||
            [lc containsString:@"id"] ||
            [lc containsString:@"thread"] ||
            [lc containsString:@"target"] ||
            [lc containsString:@"user"] ||
            [lc containsString:@"group"] ||
            [lc containsString:@"chat"] ||
            [lc containsString:@"conv"] ||
            [lc containsString:@"peer"] ||
            [lc containsString:@"contact"] ||
            [lc containsString:@"entity"]);
}

static BOOL ZXIsExactEntityIDColumn(NSString *colName)
{
    return ZXIsSpecificChatIDColumn(colName) ||
           (!ZXIsTimestampOrMetaColumn(colName) && [colName.lowercaseString isEqualToString:@"id"]);
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
    if (!dir || depth > 8 || outPaths.count >= 600) return;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                ZXCollectSQLiteFilesInDir(full, outPaths, seen, depth + 1);
            } else if (![seen containsObject:full] && ZXIsSQLiteFileAtPath(full)) {
                [seen addObject:full];
                NSString *lc = full.lowercaseString;
                if ([lc hasSuffix:@"global.sqlite"] || [lc containsString:@"/search/"] || [lc containsString:@"hidden"]) {
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

    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [roots addObject:[home stringByAppendingPathComponent:@"Documents"]];
        [roots addObject:[home stringByAppendingPathComponent:@"Library"]];
        [roots addObject:[home stringByAppendingPathComponent:@"tmp"]];
        [roots addObject:home];
    }
    for (NSNumber *dirType in @[@(NSDocumentDirectory), @(NSLibraryDirectory), @(NSCachesDirectory), @(NSApplicationSupportDirectory)]) {
        NSString *p = NSSearchPathForDirectoriesInDomains((NSSearchPathDirectory)dirType.unsignedIntegerValue, NSUserDomainMask, YES).firstObject;
        if (p.length && ![roots containsObject:p]) [roots addObject:p];
    }
    // Support both stock and custom re-signed Bundle IDs (e.g. vn.com.vng.zingalo2 via ESign)
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSMutableArray<NSString *> *groupIds = [NSMutableArray arrayWithArray:@[
        @"group.vn.com.vng.zingalo",
        @"group.com.vng.zalo",
        @"group.vn.com.vng.zingalo.share",
        @"group.vn.com.vng.zingalo.notification",
        @"group.com.vng.zingalo"
    ]];
    if (bundleID.length > 0) {
        NSString *customGroup = [@"group." stringByAppendingString:bundleID];
        if (![groupIds containsObject:customGroup]) [groupIds addObject:customGroup];
    }
    for (NSString *gid in groupIds) {
        NSURL *gURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:gid];
        if (gURL.path.length && ![roots containsObject:gURL.path]) {
            [roots addObject:gURL.path];
        }
    }
    for (NSString *root in roots) {
        ZXCollectSQLiteFilesInDir(root, dbPaths, seen, 0);
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

static NSString *ZXColumnScalarString(sqlite3_stmt *stmt, int col)
{
    if (!stmt || col < 0 || col >= sqlite3_column_count(stmt)) return @"";
    int cType = sqlite3_column_type(stmt, col);
    if (cType == SQLITE_NULL) return @"";
    if (cType == SQLITE_INTEGER) {
        return [NSString stringWithFormat:@"%lld", sqlite3_column_int64(stmt, col)];
    }
    const unsigned char *txt = sqlite3_column_text(stmt, col);
    if (txt) {
        NSString *s = [NSString stringWithUTF8String:(const char *)txt];
        if (s.length > 0) return s;
    }
    if (cType == SQLITE_BLOB) {
        const void *blob = sqlite3_column_blob(stmt, col);
        int len = sqlite3_column_bytes(stmt, col);
        if (blob && len > 0 && len <= 128) {
            NSString *bs = [[NSString alloc] initWithBytes:blob length:(NSUInteger)len encoding:NSUTF8StringEncoding];
            if (bs.length > 0) return bs;
        }
    }
    return @"";
}

static BOOL ZXIsPlausibleHiddenIDValue(NSString *rawVal, int totalCols, BOOL isSpecificCol)
{
    if (!rawVal || rawVal.length == 0) return NO;
    NSString *val = [rawVal stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (val.length == 0 || [val isEqualToString:@"0"] || [val isEqualToString:@"-1"] || ZXIsSystemClassOrEmpty(val)) {
        return NO;
    }
    NSString *digits = ZXExtractDigitCore(val);
    if (digits.length < 4 || digits.length > 24) return NO;

    NSString *nonDigits = [val stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
    if (nonDigits.length == 0 && totalCols > 1 && !isSpecificCol) {
        long long num = [val longLongValue];
        if (ZXLooksLikeEpochTimestampNumber(num)) return NO;
    }
    return YES;
}

// Read Ground-Truth IDs S_hidden from HiddenChatEntity (checking sqlite3_column_name to prioritize uid/id/thread/target and exclude time/date/stamp).
static void ZXScanDatabaseForHiddenIDs(NSString *dbPath, NSMutableDictionary<NSString *, NSMutableDictionary *> *results)
{
    if (!dbPath || !results) return;
    @try {
        sqlite3 *db = NULL;
        int rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
        if (rc != SQLITE_OK || !db) {
            if (db) { sqlite3_close(db); db = NULL; }
            rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
        }
        if (rc != SQLITE_OK || !db) {
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
                    NSString *tlc = tName.lowercaseString;
                    if ([tlc containsString:@"hiddenchat"] || [tlc containsString:@"hidechat"] ||
                        [tlc containsString:@"hidden_chat"] || [tlc containsString:@"hiddenconversation"]) {
                        [tables addObject:tName];
                    }
                }
            }
        }
        if (tStmt) sqlite3_finalize(tStmt);

        for (NSString *table in tables) {
            NSString *query = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 500", table];
            sqlite3_stmt *qStmt = NULL;
            if (sqlite3_prepare_v2(db, query.UTF8String, -1, &qStmt, NULL) == SQLITE_OK) {
                int colCount = sqlite3_column_count(qStmt);
                NSUInteger tableRowHits = 0;

                while (sqlite3_step(qStmt) == SQLITE_ROW) {
                    BOOL skipDeleted = NO;
                    for (int c = 0; c < colCount; c++) {
                        const char *rcn = sqlite3_column_name(qStmt, c);
                        NSString *cn = rcn ? [NSString stringWithUTF8String:rcn] : @"";
                        NSString *lc = cn.lowercaseString;
                        if ([lc isEqualToString:@"isdeleted"] || [lc isEqualToString:@"is_deleted"] || [lc isEqualToString:@"deleted"]) {
                            NSString *v = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
                            if ([v isEqualToString:@"1"] || [v isEqualToString:@"true"]) {
                                skipDeleted = YES;
                                break;
                            }
                        }
                    }
                    if (skipDeleted) continue;

                    NSString *uid = @"";
                    // Pass 1: Specific chat/thread/user/target ID columns (uid, threadId, userId, targetId...)
                    for (int c = 0; c < colCount; c++) {
                        const char *rcn = sqlite3_column_name(qStmt, c);
                        NSString *cn = rcn ? [NSString stringWithUTF8String:rcn] : @"";
                        if (!ZXIsSpecificChatIDColumn(cn)) continue;
                        NSString *val = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        if (ZXIsPlausibleHiddenIDValue(val, colCount, YES)) {
                            uid = val;
                            break;
                        }
                    }
                    // Pass 2: Columns containing uid / id / thread / target and NOT time / date / stamp
                    if (uid.length == 0) {
                        for (int c = 0; c < colCount; c++) {
                            const char *rcn = sqlite3_column_name(qStmt, c);
                            NSString *cn = rcn ? [NSString stringWithUTF8String:rcn] : @"";
                            if (!ZXIsPreferredHiddenIDColumn(cn)) continue;
                            NSString *val = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            if (ZXIsPlausibleHiddenIDValue(val, colCount, NO)) {
                                uid = val;
                                break;
                            }
                        }
                    }
                    // Pass 3: Fallback ONLY on non-timestamp/non-meta columns
                    if (uid.length == 0) {
                        for (int c = 0; c < colCount; c++) {
                            const char *rcn = sqlite3_column_name(qStmt, c);
                            NSString *cn = rcn ? [NSString stringWithUTF8String:rcn] : @"";
                            if (ZXIsTimestampOrMetaColumn(cn)) continue;
                            NSString *val = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            if (ZXIsPlausibleHiddenIDValue(val, colCount, NO)) {
                                uid = val;
                                break;
                            }
                        }
                    }
                    if (uid.length == 0) continue;

                    tableRowHits++;
                    if (!results[uid]) {
                        results[uid] = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"uid": uid,
                            @"digitCore": ZXExtractDigitCore(uid),
                            @"rawName": @"",
                            @"lastMessage": @"",
                            @"hiddenSource": @"HiddenChatEntity",
                            @"sourceTable": [NSString stringWithFormat:@"%@ • %@", dbPath.lastPathComponent, table],
                            @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                        }];
                    }
                }
                ZXLog(@"Scanned %@.%@ -> %lu hidden IDs", dbPath.lastPathComponent, table, (unsigned long)tableRowHits);
            }
            if (qStmt) sqlite3_finalize(qStmt);
        }

        sqlite3_close(db);
    } @catch (NSException *e) {
        ZXLog(@"HiddenChatEntity scan exception on %@: %@", dbPath.lastPathComponent, e.reason);
    }
}

static NSArray<NSString *> *ZXCandidateJSONPathsForName(NSString *fileName)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    if (!fileName.length) return paths;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *home = NSHomeDirectory();

    NSMutableArray<NSString *> *dirs = [NSMutableArray new];
    if (docs.length) {
        [dirs addObject:docs];
        [dirs addObject:[docs stringByAppendingPathComponent:@"ZaloXposed"]];
    }
    if (caches.length) {
        [dirs addObject:caches];
        [dirs addObject:[caches stringByAppendingPathComponent:@"ZaloXposed"]];
    }
    if (home.length) {
        NSString *hDocs = [home stringByAppendingPathComponent:@"Documents"];
        NSString *hCaches = [[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
        if (![dirs containsObject:hDocs]) [dirs addObject:hDocs];
        if (![dirs containsObject:hCaches]) [dirs addObject:hCaches];
    }
    NSString *cfgDir = [ZXConfig dataDir];
    if (cfgDir.length && ![dirs containsObject:cfgDir]) [dirs addObject:cfgDir];

    for (NSString *d in dirs) {
        NSString *full = [d stringByAppendingPathComponent:fileName];
        if (![paths containsObject:full]) [paths addObject:full];
    }
    return paths;
}

// ============================================================================
// Runtime Introspection Helpers (arm64 Tagged-Pointer-safe & UIWindowScene-safe)
// ============================================================================

static BOOL ZXIsZaloBinaryClass(Class cls)
{
    if (!cls) return NO;
    const char *img = class_getImageName(cls);
    if (!img) return NO;
    return (strstr(img, ".app/") != NULL);
}

/// Tagged-Pointer-safe & alignment-safe Objective-C ivar reader on arm64/arm64e.
/// Preserves bit-63 Tagged Pointers (e.g. short strings like "MẸ" or NSNumber) without ARC crashes.
static id ZXScannerSafeReadObjectIvar(id obj, Ivar iv)
{
    if (!obj || !iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc || enc[0] != '@' || enc[1] == '?') return nil;

    ptrdiff_t offset = ivar_getOffset(iv);
    uintptr_t rawPtr = 0;
    memcpy(&rawPtr, (const uint8_t *)(__bridge const void *)obj + offset, sizeof(uintptr_t));
    if (rawPtr == 0) return nil;

    BOOL isTaggedPointer = ((rawPtr & (1ULL << 63)) != 0);
    if (!isTaggedPointer) {
        if ((rawPtr & 0x7ULL) != 0 || rawPtr < 0x10000ULL) return nil;
    }
    return object_getIvar(obj, iv);
}

static BOOL ZXScannerSafeReadIntegerIvar(id obj, Ivar iv, long long *outVal)
{
    if (!obj || !iv || !outVal) return NO;
    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc) return NO;
    ptrdiff_t offset = ivar_getOffset(iv);
    const uint8_t *ptr = (const uint8_t *)(__bridge const void *)obj + offset;
    if (enc[0] == 'q' || enc[0] == 'l') {
        int64_t v = 0;
        memcpy(&v, ptr, sizeof(v));
        *outVal = (long long)v;
        return YES;
    }
    if (enc[0] == 'Q' || enc[0] == 'L') {
        uint64_t v = 0;
        memcpy(&v, ptr, sizeof(v));
        *outVal = (long long)v;
        return YES;
    }
    if (enc[0] == 'i') {
        int32_t v = 0;
        memcpy(&v, ptr, sizeof(v));
        *outVal = (long long)v;
        return YES;
    }
    if (enc[0] == 'I') {
        uint32_t v = 0;
        memcpy(&v, ptr, sizeof(v));
        *outVal = (long long)v;
        return YES;
    }
    return NO;
}

static NSArray<UIWindow *> *ZXScannerAllSceneWindows(void)
{
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w && ![wins containsObject:w]) [wins addObject:w];
            }
        }
    }
    return wins;
}

static void ZXDumpObjectIvarsRecursive(id obj, int depth, int maxDepth, NSMutableString *outLog, NSMutableSet<NSValue *> *visited)
{
    if (!obj || depth > maxDepth || outLog.length > 180000) return;
    NSValue *ptrKey = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:ptrKey]) return;
    [visited addObject:ptrKey];

    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    Class curCls = object_getClass(obj);

    while (curCls && curCls != [NSObject class] && ZXIsZaloBinaryClass(curCls)) {
        unsigned int ivCount = 0;
        Ivar *ivars = class_copyIvarList(curCls, &ivCount);
        if (ivars) {
            for (unsigned int i = 0; i < ivCount; i++) {
                const char *nameC = ivar_getName(ivars[i]);
                const char *encC  = ivar_getTypeEncoding(ivars[i]);
                if (!nameC || !encC) continue;
                NSString *ivName = [NSString stringWithUTF8String:nameC];
                NSString *ivEnc  = [NSString stringWithUTF8String:encC];

                if (encC[0] == '@' && encC[1] != '?') {
                    @try {
                        id val = ZXScannerSafeReadObjectIvar(obj, ivars[i]);
                        if (!val) continue;
                        if ([val isKindOfClass:[UIView class]] || [val isKindOfClass:[CALayer class]] ||
                            [val isKindOfClass:[UIViewController class]] || [val isKindOfClass:[UIImage class]] ||
                            [val isKindOfClass:[UIColor class]] || [val isKindOfClass:[UIFont class]] ||
                            [val isKindOfClass:[NSLayoutConstraint class]] || [val isKindOfClass:[UIGestureRecognizer class]]) {
                            continue;
                        }
                        if ([val isKindOfClass:[NSString class]] || [val isKindOfClass:[NSNumber class]]) {
                            NSString *sVal = [[val description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                            if (sVal.length > 160) sVal = [[sVal substringToIndex:160] stringByAppendingString:@"..."];
                            [outLog appendFormat:@"%@• [%s] %@ (%@) = \"%@\"\n",
                                indent, class_getName(curCls), ivName, ivEnc, sVal];
                        } else if ([val isKindOfClass:[NSDictionary class]]) {
                            NSDictionary *dict = (NSDictionary *)val;
                            [outLog appendFormat:@"%@• [%s] %@ (NSDictionary keys=%@)\n",
                                indent, class_getName(curCls), ivName, [dict.allKeys componentsJoinedByString:@","]];
                        } else if ([val isKindOfClass:[NSArray class]]) {
                            NSArray *arr = (NSArray *)val;
                            [outLog appendFormat:@"%@• [%s] %@ (NSArray count=%lu first=%s)\n",
                                indent, class_getName(curCls), ivName, (unsigned long)arr.count,
                                arr.firstObject ? object_getClassName(arr.firstObject) : "nil"];
                        } else if (![val isKindOfClass:[NSSet class]] && ![val isKindOfClass:[NSData class]]) {
                            NSString *ivLC = ivName.lowercaseString;
                            if ([ivLC containsString:@"delegate"] || [ivLC containsString:@"datasource"] ||
                                [ivLC containsString:@"parent"] || [ivLC containsString:@"manager"] ||
                                [ivLC containsString:@"table"] || [ivLC containsString:@"collection"]) {
                                [outLog appendFormat:@"%@• [%s] %@ -> <%s: %p> (ref)\n",
                                    indent, class_getName(curCls), ivName, object_getClassName(val), (__bridge void *)val];
                            } else {
                                [outLog appendFormat:@"%@• [%s] %@ -> <%s: %p>\n",
                                    indent, class_getName(curCls), ivName, object_getClassName(val), (__bridge void *)val];
                                ZXDumpObjectIvarsRecursive(val, depth + 1, maxDepth, outLog, visited);
                            }
                        }
                    } @catch (__unused NSException *e) {}
                } else {
                    long long intVal = 0;
                    if (ZXScannerSafeReadIntegerIvar(obj, ivars[i], &intVal) && intVal != 0) {
                        NSString *ivLC = ivName.lowercaseString;
                        if ([ivLC containsString:@"id"] || [ivLC containsString:@"type"] ||
                            [ivLC containsString:@"section"] || [ivLC containsString:@"hidden"] ||
                            (intVal >= 10000 && intVal <= 999999999999999LL)) {
                            [outLog appendFormat:@"%@• [%s] %@ (%@) = %lld\n",
                                indent, class_getName(curCls), ivName, ivEnc, intVal];
                        }
                    }
                }
            }
            free(ivars);
        }

        // Log @objc declared property names on Swift/ObjC classes at depth <= 2 for complete visibility
        if (depth <= 2) {
            unsigned int pCount = 0;
            objc_property_t *props = class_copyPropertyList(curCls, &pCount);
            if (props && pCount > 0) {
                NSMutableArray<NSString *> *pList = [NSMutableArray array];
                for (unsigned int p = 0; p < pCount; p++) {
                    const char *pn = property_getName(props[p]);
                    const char *pa = property_getAttributes(props[p]);
                    if (pn && pa) {
                        NSString *paStr = [NSString stringWithUTF8String:pa];
                        NSString *shortAttr = [[paStr componentsSeparatedByString:@","] firstObject] ?: paStr;
                        [pList addObject:[NSString stringWithFormat:@"%s(%@)", pn, shortAttr]];
                    }
                }
                if (pList.count > 0) {
                    [outLog appendFormat:@"%@  [Props %s]: %@\n",
                        indent, class_getName(curCls), [pList componentsJoinedByString:@", "]];
                }
            }
            if (props) free(props);
        }

        curCls = class_getSuperclass(curCls);
    }
}

static void ZXCollectZaloViewControllers(UIViewController *vc, NSMutableArray<UIViewController *> *outVCs, NSMutableSet<NSValue *> *seen)
{
    if (!vc) return;
    NSValue *k = [NSValue valueWithPointer:(__bridge const void *)vc];
    if ([seen containsObject:k]) return;
    [seen addObject:k];

    NSString *clsName = NSStringFromClass([vc class]);
    if (![clsName hasPrefix:@"ZX"]) {
        [outVCs addObject:vc];
    }
    for (UIViewController *child in vc.childViewControllers) {
        ZXCollectZaloViewControllers(child, outVCs, seen);
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *sub in ((UINavigationController *)vc).viewControllers) {
            ZXCollectZaloViewControllers(sub, outVCs, seen);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *sub in ((UITabBarController *)vc).viewControllers) {
            ZXCollectZaloViewControllers(sub, outVCs, seen);
        }
    }
    if (vc.presentedViewController) {
        ZXCollectZaloViewControllers(vc.presentedViewController, outVCs, seen);
    }
}

static void ZXDumpListViewsInViewHierarchy(UIView *rootView, NSMutableString *log, NSMutableSet<NSValue *> *seenLists)
{
    if (!rootView || log.length > 180000) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass([v class]) hasPrefix:@"ZX"]) continue;

        if ([v isKindOfClass:[UITableView class]]) {
            NSValue *lk = [NSValue valueWithPointer:(__bridge const void *)v];
            if (![seenLists containsObject:lk]) {
                [seenLists addObject:lk];
                UITableView *tv = (UITableView *)v;
                [log appendFormat:@"\n[TABLEVIEW] %s | hidden=%d | sections=%ld | visibleCells=%lu\n  dataSource=%s | delegate=%s\n",
                    object_getClassName(tv), tv.hidden, (long)tv.numberOfSections, (unsigned long)tv.visibleCells.count,
                    tv.dataSource ? object_getClassName(tv.dataSource) : "nil",
                    tv.delegate ? object_getClassName(tv.delegate) : "nil"];
                if (tv.dataSource) {
                    [log appendString:@"  [DataSource Ivars]:\n"];
                    ZXDumpObjectIvarsRecursive(tv.dataSource, 2, 3, log, [NSMutableSet set]);
                }
                NSUInteger cellIdx = 0;
                for (UITableViewCell *cell in tv.visibleCells) {
                    if (++cellIdx > 12) break;
                    NSIndexPath *ip = [tv indexPathForCell:cell];
                    [log appendFormat:@"  [CELL sec=%ld row=%ld] Class=%s\n",
                        (long)(ip ? ip.section : -1), (long)(ip ? ip.row : -1), object_getClassName(cell)];
                    ZXDumpObjectIvarsRecursive(cell, 2, 4, log, [NSMutableSet set]);
                }
            }
        } else if ([v isKindOfClass:[UICollectionView class]]) {
            NSValue *lk = [NSValue valueWithPointer:(__bridge const void *)v];
            if (![seenLists containsObject:lk]) {
                [seenLists addObject:lk];
                UICollectionView *cv = (UICollectionView *)v;
                [log appendFormat:@"\n[COLLECTIONVIEW] %s | hidden=%d | sections=%ld | visibleCells=%lu\n  dataSource=%s | delegate=%s\n",
                    object_getClassName(cv), cv.hidden, (long)cv.numberOfSections, (unsigned long)cv.visibleCells.count,
                    cv.dataSource ? object_getClassName(cv.dataSource) : "nil",
                    cv.delegate ? object_getClassName(cv.delegate) : "nil"];
                if (cv.dataSource) {
                    [log appendString:@"  [DataSource Ivars]:\n"];
                    ZXDumpObjectIvarsRecursive(cv.dataSource, 2, 3, log, [NSMutableSet set]);
                }
                NSUInteger cellIdx = 0;
                for (UICollectionViewCell *cell in cv.visibleCells) {
                    if (++cellIdx > 12) break;
                    NSIndexPath *ip = [cv indexPathForCell:cell];
                    [log appendFormat:@"  [ITEM sec=%ld item=%ld] Class=%s\n",
                        (long)(ip ? ip.section : -1), (long)(ip ? ip.item : -1), object_getClassName(cell)];
                    ZXDumpObjectIvarsRecursive(cell, 2, 4, log, [NSMutableSet set]);
                }
            }
        }
        if (v.subviews.count > 0) {
            [queue addObjectsFromArray:v.subviews];
        }
    }
}

@implementation ZXScanner

+ (BOOL)isGarbageChatIdentifier:(NSString *)str
{
    return ZXIsSystemClassOrEmpty(str);
}

+ (BOOL)isValidHumanDisplayName:(NSString *)str excludeUID:(NSString *)excludeUID
{
    return ZXIsValidHumanDisplayName(str, excludeUID);
}

+ (NSString *)scanPath
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"scan.txt"];
}

+ (NSString *)hiddenIntrospectPath
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        return [docs stringByAppendingPathComponent:@"zalo_26_introspect.txt"];
    }
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"zalo_26_introspect.txt"];
}

+ (NSString *)lastPinCellsDumpPath
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        return [docs stringByAppendingPathComponent:@"zx_last_pin_cells_dump.txt"];
    }
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"zx_last_pin_cells_dump.txt"];
}

+ (NSString *)dumpObjectModelGraph:(id)rootObj maxDepth:(int)maxDepth
{
    if (!rootObj) return @"";
    NSMutableString *out = [NSMutableString stringWithFormat:@"<%s: %p>\n",
                            object_getClassName(rootObj), (__bridge void *)rootObj];
    @try {
        ZXDumpObjectIvarsRecursive(rootObj, 1, maxDepth, out, [NSMutableSet set]);
    } @catch (__unused NSException *e) {}
    return out;
}

+ (NSString *)resolvedProfilesPath
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        return [docs stringByAppendingPathComponent:@"zx_resolved_profiles.json"];
    }
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"zx_resolved_profiles.json"];
}

+ (NSDictionary<NSString *, NSString *> *)currentHiddenChatDigitToUIDMap
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *found = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *digitMap = [NSMutableDictionary new];
    @try {
        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        for (NSString *path in dbPaths) {
            ZXScanDatabaseForHiddenIDs(path, found);
        }
        for (NSString *uid in found) {
            NSString *digits = ZXExtractDigitCore(uid);
            if (digits.length >= 4) {
                digitMap[digits] = uid;
            }
            digitMap[uid] = uid;
        }
    } @catch (NSException *e) {
        ZXLog(@"currentHiddenChatDigitToUIDMap exception: %@", e.reason);
    }
    return digitMap;
}

+ (NSArray<NSString *> *)currentHiddenChatEntityIDs
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *found = [NSMutableDictionary new];
    @try {
        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        for (NSString *path in dbPaths) {
            ZXScanDatabaseForHiddenIDs(path, found);
        }
    } @catch (NSException *e) {
        ZXLog(@"currentHiddenChatEntityIDs exception: %@", e.reason);
    }
    return found.allKeys ?: @[];
}

+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *found = [NSMutableDictionary new];
    @try {
        NSSet<NSString *> *dismissedKeys = [NSSet setWithArray:([[NSUserDefaults standardUserDefaults] arrayForKey:@"zx_dismissed_hidden_keys"] ?: @[])];

        // 1. STRICT GROUND TRUTH S_hidden: ONLY IDs present in HiddenChatEntity (search/global.sqlite)
        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        for (NSString *path in dbPaths) {
            ZXScanDatabaseForHiddenIDs(path, found);
        }
        for (NSString *dk in dismissedKeys) {
            [found removeObjectForKey:dk];
        }

        // Build exact S_hidden lookup map (digitCore -> canonicalUID)
        NSMutableDictionary<NSString *, NSString *> *sHiddenDigitsToUID = [NSMutableDictionary new];
        for (NSString *uid in found) {
            NSString *dCore = ZXExtractDigitCore(uid);
            if (dCore.length >= 4) sHiddenDigitsToUID[dCore] = uid;
            sHiddenDigitsToUID[uid] = uid;
        }

        // 2. Load 1-to-1 resolved names from zx_resolved_profiles.json (purging any synthetic pin:/hide: or non-S_hidden entries)
        NSMutableDictionary<NSString *, id> *ramProfiles = [NSMutableDictionary new];
        NSString *primaryPath = [self resolvedProfilesPath];
        for (NSString *p in ZXCandidateJSONPathsForName(@"zx_resolved_profiles.json")) {
            NSData *d = [NSData dataWithContentsOfFile:p];
            if (!d) continue;
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                [ramProfiles addEntriesFromDictionary:(NSDictionary *)obj];
            }
        }

        BOOL cleanedProfiles = NO;
        for (NSString *k in [ramProfiles allKeys]) {
            if ([dismissedKeys containsObject:k] || [k hasPrefix:@"_"] || [k hasPrefix:@"pin:"] || [k hasPrefix:@"hide:"]) {
                [ramProfiles removeObjectForKey:k];
                cleanedProfiles = YES;
                continue;
            }
            NSDictionary *prof = [ramProfiles[k] isKindOfClass:[NSDictionary class]] ? ramProfiles[k] : nil;
            if (!prof) {
                [ramProfiles removeObjectForKey:k];
                cleanedProfiles = YES;
                continue;
            }
            NSString *pName = [prof[@"name"] description] ?: @"";
            if (pName.length > 0 && !ZXIsValidHumanDisplayName(pName, k)) {
                [ramProfiles removeObjectForKey:k];
                cleanedProfiles = YES;
                continue;
            }
            // Purge non-hidden accounts if S_hidden is non-empty and this key isn't in S_hidden
            NSString *kDigits = ZXExtractDigitCore(k);
            if (found.count > 0 && !sHiddenDigitsToUID[k] && !(kDigits.length >= 4 && sHiddenDigitsToUID[kDigits])) {
                [ramProfiles removeObjectForKey:k];
                cleanedProfiles = YES;
            }
        }
        if (cleanedProfiles && primaryPath.length > 0) {
            NSData *cleanOut = [NSJSONSerialization dataWithJSONObject:ramProfiles options:0 error:nil];
            if (cleanOut) [cleanOut writeToFile:primaryPath atomically:YES];
        }

        // 3. Strictly 1-to-1 overlay: match ONLY exact uid or exact digitCore for uid ∈ S_hidden (NEVER blind-pair!)
        for (NSString *uid in found) {
            NSMutableDictionary *entry = found[uid];
            NSString *dCore = ZXExtractDigitCore(uid);
            NSDictionary *prof = [ramProfiles[uid] isKindOfClass:[NSDictionary class]] ? ramProfiles[uid] : nil;
            if (!prof && dCore.length >= 4 && [ramProfiles[dCore] isKindOfClass:[NSDictionary class]]) {
                prof = ramProfiles[dCore];
            }
            if (prof) {
                NSString *pName = [prof[@"name"] description] ?: @"";
                NSString *pMsg = [prof[@"lastMessage"] description] ?: @"";
                if (ZXIsValidHumanDisplayName(pName, uid)) {
                    entry[@"rawName"] = pName;
                    entry[@"modelVerified"] = @([prof[@"modelVerified"] boolValue]);
                }
                if (pMsg.length > 0 && !ZXIsSystemClassOrEmpty(pMsg)) {
                    entry[@"lastMessage"] = pMsg;
                }
            }
        }

        // 4. Format exact S_hidden list: 1 row per HiddenChatEntity ID
        NSMutableArray<NSDictionary *> *finalList = [NSMutableArray arrayWithCapacity:found.count];
        NSArray<NSString *> *sortedUIDs = [found.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *uid in sortedUIDs) {
            NSMutableDictionary *entry = found[uid];
            NSString *rawName = entry[@"rawName"] ?: @"";
            if (rawName.length > 0 && !ZXIsValidHumanDisplayName(rawName, uid)) {
                rawName = @"";
            }
            NSString *displayTitle = rawName.length > 0
                ? [NSString stringWithFormat:@"%@ (ID: %@)", rawName, uid]
                : [NSString stringWithFormat:@"Chưa giải mã tên (ID: %@)", uid];

            NSString *lastMsg = entry[@"lastMessage"] ?: @"";
            if (lastMsg.length == 0) {
                NSString *src = entry[@"sourceTable"] ?: @"HiddenChatEntity";
                lastMsg = rawName.length > 0
                    ? [NSString stringWithFormat:@"Khớp 1-1 Model • %@", src]
                    : [NSString stringWithFormat:@"%@ • Nhập mã PIN ẩn ở Tìm kiếm Zalo để tự bắt tên 1-1", src];
            }
            [finalList addObject:@{
                @"uid": uid,
                @"rawName": rawName,
                @"name": displayTitle,
                @"lastMessage": lastMsg,
                @"hiddenSource": @"HiddenChatEntity",
                @"verified": @(rawName.length > 0),
                @"modelVerified": @([entry[@"modelVerified"] boolValue]),
                @"updatedAt": entry[@"updatedAt"] ?: @0
            }];
        }

        ZXLog(@"S_hidden scan complete: %lu DBs -> %lu strict HiddenChatEntity rows",
              (unsigned long)dbPaths.count, (unsigned long)finalList.count);
        return finalList;
    } @catch (NSException *e) {
        ZXLog(@"scanSQLiteForHiddenChats exception: %@", e.reason);
        return @[];
    }
}

+ (NSString *)dumpLiveSceneListModelsOnMainThread
{
    if (![NSThread isMainThread]) return @"";
    NSMutableString *log = [NSMutableString string];
    @try {
        NSMutableSet<NSValue *> *seenVCs = [NSMutableSet set];
        NSMutableSet<NSValue *> *seenLists = [NSMutableSet set];
        NSArray<UIWindow *> *wins = ZXScannerAllSceneWindows();
        for (UIWindow *win in wins) {
            if ([NSStringFromClass([win class]) hasPrefix:@"ZX"]) continue;
            NSMutableArray<UIViewController *> *vcs = [NSMutableArray array];
            if (win.rootViewController) {
                ZXCollectZaloViewControllers(win.rootViewController, vcs, seenVCs);
            }
            for (UIViewController *vc in vcs) {
                if (vc.isViewLoaded && vc.view) {
                    ZXDumpListViewsInViewHierarchy(vc.view, log, seenLists);
                }
            }
            ZXDumpListViewsInViewHierarchy(win, log, seenLists);
        }
    } @catch (__unused NSException *e) {}
    return log;
}

+ (NSString *)runHiddenIntrospectionWithPinSnapshot:(NSString *)pinSnapshot liveSceneDump:(NSString *)liveSceneDump
{
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"=== ZALO 26.11.02.1 HIDDEN CHAT & MODEL INTROSPECTION ===\nBundleID: %@\nTime: %@\n\n",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?", [NSDate date]];

    @try {
        // [PHẦN 1] Exact HiddenChatEntity SQLite Schema & Raw Rows
        [log appendString:@"==========================================================\n"];
        [log appendString:@"[PHẦN 1] SCHEMA & DỮ LIỆU GỐC BẢNG HiddenChatEntity (SQLite)\n"];
        [log appendString:@"==========================================================\n"];
        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        [log appendFormat:@"Total SQLite files discovered in Sandbox: %lu\n", (unsigned long)dbPaths.count];
        for (NSString *dbPath in dbPaths) {
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK || !db) {
                if (db) sqlite3_close(db);
                continue;
            }
            sqlite3_busy_timeout(db, 150);
            sqlite3_stmt *tStmt = NULL;
            if (sqlite3_prepare_v2(db, "SELECT name, sql FROM sqlite_master WHERE type='table'", -1, &tStmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(tStmt) == SQLITE_ROW) {
                    NSString *tName = ZXColumnText(tStmt, 0);
                    NSString *tSQL = ZXColumnText(tStmt, 1);
                    NSString *tlc = tName.lowercaseString;
                    if ([tlc containsString:@"hidden"] || [tlc containsString:@"hide"] || [tlc containsString:@"pin"]) {
                        [log appendFormat:@"\nDB: %@\nTable: %@\nDDL: %@\n", dbPath, tName, tSQL];
                        NSString *q = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 50", tName];
                        sqlite3_stmt *rStmt = NULL;
                        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &rStmt, NULL) == SQLITE_OK) {
                            int cols = sqlite3_column_count(rStmt);
                            int rowIdx = 0;
                            while (sqlite3_step(rStmt) == SQLITE_ROW) {
                                NSMutableArray<NSString *> *pairs = [NSMutableArray array];
                                for (int c = 0; c < cols; c++) {
                                    const char *cn = sqlite3_column_name(rStmt, c);
                                    [pairs addObject:[NSString stringWithFormat:@"%s='%@'", cn ?: "?", ZXColumnScalarString(rStmt, c)]];
                                }
                                [log appendFormat:@"  Row[%d]: %@\n", rowIdx++, [pairs componentsJoinedByString:@" | "]];
                            }
                            sqlite3_finalize(rStmt);
                        }
                    }
                }
            }
            if (tStmt) sqlite3_finalize(tStmt);
            sqlite3_close(db);
        }

        // [PHẦN 2] Snapshot Cell Backing Models captured when typing 4-6 digit PIN in Search
        [log appendString:@"\n==========================================================\n"];
        [log appendString:@"[PHẦN 2] SNAPSHOT CELL BACKING MODELS KHI NHẬP MÃ PIN TÌM KIẾM\n"];
        [log appendString:@"==========================================================\n"];
        NSString *snapText = pinSnapshot;
        if (snapText.length == 0) {
            snapText = [NSString stringWithContentsOfFile:[self lastPinCellsDumpPath] encoding:NSUTF8StringEncoding error:nil];
        }
        if (snapText.length > 0) {
            [log appendString:snapText];
            [log appendString:@"\n"];
        } else {
            [log appendString:@"(Chưa có snapshot PIN — Hãy ra ô Tìm kiếm Zalo gõ mã PIN ẩn ví dụ '1206' để hiện kết quả rồi bấm Dump lại!)\n"];
        }

        // [PHẦN 3] Live UITableView / UICollectionView Backing Models (captured on Main Thread, zero dispatch_sync!)
        [log appendString:@"\n==========================================================\n"];
        [log appendString:@"[PHẦN 3] LIVE TABLEVIEW / COLLECTIONVIEW TRONG BỘ NHỚ HIỆN TẠI\n"];
        [log appendString:@"==========================================================\n"];
        if (liveSceneDump.length > 0) {
            [log appendString:liveSceneDump];
            [log appendString:@"\n"];
        } else {
            [log appendString:@"(Không có TableView/CollectionView nào đang mở)\n"];
        }

        // [PHẦN 4] Zalo Binary Classes & Selectors for HiddenChat / ContactManager / Thread / Search
        [log appendString:@"\n==========================================================\n"];
        [log appendString:@"[PHẦN 4] ZALO 26.11.02.1 CLASSES & METHODS (MANAGER / MODEL / SEARCH)\n"];
        [log appendString:@"==========================================================\n"];
        NSArray<NSString *> *clsKeywords = @[
            @"HiddenChat", @"HideChat", @"PinChat", @"SecretChat",
            @"ContactManager", @"ProfileManager", @"GroupManager",
            @"ConversationManager", @"ThreadManager", @"ChatDataManager",
            @"GlobalSearch", @"SearchSection", @"SearchResult"
        ];
        unsigned int clsCount = 0;
        Class *allClasses = objc_copyClassList(&clsCount);
        if (allClasses) {
            NSUInteger dumpedClasses = 0;
            for (unsigned int i = 0; i < clsCount && dumpedClasses < 120; i++) {
                Class cls = allClasses[i];
                if (!ZXIsZaloBinaryClass(cls)) continue;
                const char *rawName = class_getName(cls);
                if (!rawName) continue;
                NSString *clsName = [NSString stringWithUTF8String:rawName];
                BOOL hit = NO;
                for (NSString *kw in clsKeywords) {
                    if ([clsName rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        hit = YES;
                        break;
                    }
                }
                if (!hit) continue;
                dumpedClasses++;

                Class sup = class_getSuperclass(cls);
                [log appendFormat:@"\n[CLASS] %@ : %s\n", clsName, sup ? class_getName(sup) : "nil"];

                unsigned int cmCount = 0;
                Method *cMethods = class_copyMethodList(object_getClass(cls), &cmCount);
                if (cMethods) {
                    for (unsigned int m = 0; m < cmCount && m < 40; m++) {
                        char *rt = method_copyReturnType(cMethods[m]);
                        [log appendFormat:@"  + (%s)%s\n", rt ?: "?", sel_getName(method_getName(cMethods[m]))];
                        if (rt) free(rt);
                    }
                    free(cMethods);
                }

                unsigned int imCount = 0;
                Method *iMethods = class_copyMethodList(cls, &imCount);
                if (iMethods) {
                    for (unsigned int m = 0; m < imCount && m < 60; m++) {
                        char *rt = method_copyReturnType(iMethods[m]);
                        [log appendFormat:@"  - (%s)%s\n", rt ?: "?", sel_getName(method_getName(iMethods[m]))];
                        if (rt) free(rt);
                    }
                    free(iMethods);
                }
            }
            free(allClasses);
        }
    } @catch (NSException *e) {
        [log appendFormat:@"\n[EXCEPTION] %@\n", e.reason];
    }

    NSString *outPath = [self hiddenIntrospectPath];
    [log writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return outPath;
}

+ (BOOL)unhideChatInSQLiteWithID:(NSString *)chatID
{
    if (!chatID || chatID.length == 0) return NO;
    BOOL modifiedAny = NO;
    @try {
        NSString *cleanDigits = ZXExtractDigitCore(chatID);
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
                    if (ZXIsExactEntityIDColumn(col) || (isDedicatedHiddenTable && ZXIsPreferredHiddenIDColumn(col))) {
                        [idCols addObject:col];
                    }
                    if ([lc containsString:@"hidden"] || [lc containsString:@"hide"] || [lc isEqualToString:@"is_pin"]) {
                        if (![lc containsString:@"time"] && ![lc containsString:@"date"] && ![lc containsString:@"stamp"]) {
                            [hideCols addObject:col];
                        }
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
