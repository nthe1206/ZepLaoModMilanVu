#import "ZXScanner.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import <objc/runtime.h>
#import <sqlite3.h>

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
    // Pure single-token class names: UI..., _TtC..., NS..., ZX..., or CamelCase ending in ViewController/TableViewCell/View/Controller/Delegate
    if ([trim rangeOfString:@" "].location == NSNotFound) {
        if ([trim hasPrefix:@"_TtC"] || [trim hasPrefix:@"_UI"] || [trim hasPrefix:@"UI"] ||
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
            // Reject ZA... identifiers that have no digits (pure class names like ZAPinBoardView)
            NSRange digitRange = [trim rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet];
            if (digitRange.location == NSNotFound) return YES;
        }
    }
    return NO;
}

/// Checks if a candidate string is a valid human/group display name (2-50 chars, has letters, not placeholder/phone/time/status/class).
static BOOL ZXIsValidHumanDisplayName(NSString *s, NSString *excludeUID)
{
    if (!s) return NO;
    NSString *trim = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length < 2 || trim.length > 50) return NO;
    if (excludeUID.length && [trim isEqualToString:excludeUID]) return NO;
    if (ZXIsSystemClassOrEmpty(trim)) return NO;

    NSString *lc = trim.lowercaseString;
    NSArray<NSString *> *badNamePhrases = @[
        @"ảnh đã hết hạn", @"tin nhắn đã thu hồi", @"tin nhắn đã được thu hồi", @"đã thu hồi",
        @"hiddenchatentity", @"search/global.sqlite", @"global.sqlite", @".sqlite",
        @"nhập pin", @"nhập mã pin", @"đang hoạt động", @"vừa xong", @"chạm để", @"xem thêm",
        @"coca", @"bulla", @"hội thoại ẩn", @"trò chuyện ẩn", @"chưa giải mã", @"không tìm thấy",
        @"kết quả tìm kiếm", @"chưa có tin nhắn", @"tìm kiếm gần đây", @"liên hệ gần đây",
        @"từ khóa tìm kiếm", @"không có kết quả", @"vừa truy cập", @"đang nhập",
        @"cuộc gọi thoại", @"cuộc gọi video", @"cuộc gọi nhỡ", @"official account",
        @"đã xác thực tên", @"đã xóa tên cũ", @"đã xóa cache", @"đã lưu tên thật"
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

    // Must contain at least one letter (Latin or Vietnamese Unicode letter)
    NSRange letterRange = [trim rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
    if (letterRange.location == NSNotFound) return NO;

    // Reject phone numbers or strings dominated by digits (e.g. +84..., 0912..., timestamps)
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

    // Reject pure hex/UUID/base64-like tokens with no spaces and length >= 20
    if ([trim rangeOfString:@" "].location == NSNotFound && trim.length >= 20) {
        NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
        NSString *rem = [trim stringByTrimmingCharactersInSet:alnum];
        if (rem.length <= 2) return NO;
    }
    return YES;
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
                // Always prioritize global.sqlite / search/global.sqlite at index 0
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
    NSArray<NSString *> *groupIds = @[
        @"group.vn.com.vng.zingalo",
        @"group.com.vng.zalo",
        @"group.vn.com.vng.zingalo.share",
        @"group.vn.com.vng.zingalo.notification",
        @"group.com.vng.zingalo"
    ];
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

/// Checks if a column name is a specific chat/user/thread/group identifier (preferring specific IDs over generic row 'id').
static BOOL ZXIsSpecificChatIDColumn(NSString *colName)
{
    NSString *lc = colName.lowercaseString;
    if ([lc containsString:@"sender"] || [lc containsString:@"owner"] || [lc containsString:@"from"] ||
        [lc containsString:@"creator"] || [lc containsString:@"author"] || [lc containsString:@"msgid"] ||
        [lc containsString:@"messageid"] || [lc containsString:@"clientid"] || [lc containsString:@"globalmsg"]) {
        return NO;
    }
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

static BOOL ZXIsExactEntityIDColumn(NSString *colName)
{
    return ZXIsSpecificChatIDColumn(colName) || [colName.lowercaseString isEqualToString:@"id"];
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

// Read ALL IDs from HiddenChatEntity (in global.sqlite / search/global.sqlite across Documents, Library, App Groups).
// Opens with READWRITE fallback to READONLY so live WAL (-wal / -shm) frames are always visible!
static void ZXScanDatabaseForHiddenIDs(NSString *dbPath, NSMutableDictionary<NSString *, NSMutableDictionary *> *results)
{
    if (!dbPath || !results) return;
    @try {
        sqlite3 *db = NULL;
        // Open READWRITE first so SQLite maps the live -wal/-shm shared memory index and sees newly hidden chats before checkpoint
        int rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
        if (rc != SQLITE_OK || !db) {
            if (db) { sqlite3_close(db); db = NULL; }
            rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
        }
        if (rc != SQLITE_OK || !db) {
            if (db) sqlite3_close(db);
            return;
        }
        sqlite3_busy_timeout(db, 300);

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
            NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", table];
            sqlite3_stmt *cStmt = NULL;
            if (sqlite3_prepare_v2(db, pragma.UTF8String, -1, &cStmt, NULL) != SQLITE_OK) {
                if (cStmt) sqlite3_finalize(cStmt);
                continue;
            }

            NSMutableArray<NSString *> *specificIDCols = [NSMutableArray new];
            NSMutableArray<NSString *> *genericIDCols = [NSMutableArray new];
            NSMutableArray<NSString *> *explicitDeleteCols = [NSMutableArray new];

            while (sqlite3_step(cStmt) == SQLITE_ROW) {
                NSString *col = ZXColumnText(cStmt, 1);
                if (!col.length) continue;
                NSString *lc = col.lowercaseString;
                if (ZXIsSpecificChatIDColumn(col)) {
                    [specificIDCols addObject:col];
                } else if ([lc isEqualToString:@"id"] || [lc isEqualToString:@"key"] || [lc isEqualToString:@"pk"] || [lc hasSuffix:@"id"]) {
                    [genericIDCols addObject:col];
                } else if ([lc isEqualToString:@"isdeleted"] || [lc isEqualToString:@"is_deleted"] || [lc isEqualToString:@"deleted"]) {
                    [explicitDeleteCols addObject:col];
                }
            }
            sqlite3_finalize(cStmt);

            NSString *query = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 500", table];
            sqlite3_stmt *qStmt = NULL;
            if (sqlite3_prepare_v2(db, query.UTF8String, -1, &qStmt, NULL) == SQLITE_OK) {
                int colCount = sqlite3_column_count(qStmt);
                NSUInteger tableRowHits = 0;
                while (sqlite3_step(qStmt) == SQLITE_ROW) {
                    BOOL skipRow = NO;
                    for (int c = 0; c < colCount; c++) {
                        const char *rcn = sqlite3_column_name(qStmt, c);
                        NSString *cn = rcn ? [NSString stringWithUTF8String:rcn] : @"";
                        if ([explicitDeleteCols containsObject:cn] && sqlite3_column_type(qStmt, c) != SQLITE_NULL) {
                            NSString *v = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
                            if ([v isEqualToString:@"1"] || [v isEqualToString:@"true"]) { skipRow = YES; break; }
                        }
                    }
                    if (skipRow) continue;

                    NSString *uid = @"";
                    // 1. Check specific ID columns (threadId, userId, uid, conversationId, chatId, entityId...)
                    for (int c = 0; c < colCount; c++) {
                        const char *rawColName = sqlite3_column_name(qStmt, c);
                        NSString *cn = rawColName ? [NSString stringWithUTF8String:rawColName] : @"";
                        if ([specificIDCols containsObject:cn]) {
                            NSString *val = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            if (val.length > 0 && !ZXIsSystemClassOrEmpty(val) && ![val isEqualToString:@"0"]) {
                                uid = val;
                                break;
                            }
                        }
                    }
                    // 2. Check generic id/key/*id columns
                    if (uid.length == 0) {
                        for (int c = 0; c < colCount; c++) {
                            const char *rawColName = sqlite3_column_name(qStmt, c);
                            NSString *cn = rawColName ? [NSString stringWithUTF8String:rawColName] : @"";
                            if ([genericIDCols containsObject:cn]) {
                                NSString *val = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                                if (val.length >= 2 && !ZXIsSystemClassOrEmpty(val) && ![val isEqualToString:@"0"]) {
                                    uid = val;
                                    break;
                                }
                            }
                        }
                    }
                    // 3. Fallback: any non-empty scalar column in HiddenChatEntity
                    if (uid.length == 0) {
                        for (int c = 0; c < colCount; c++) {
                            NSString *val = [ZXColumnScalarString(qStmt, c) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            if (val.length == 0 || [val isEqualToString:@"0"] || ZXIsSystemClassOrEmpty(val)) continue;
                            NSString *rem = [val stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
                            if (rem.length == 0) {
                                long long num = [val longLongValue];
                                if (num >= 1500000000LL && num <= 2100000000LL && colCount > 1) continue;
                                uid = val;
                                break;
                            } else if (val.length <= 80) {
                                uid = val;
                                break;
                            }
                        }
                    }
                    if (uid.length == 0 || ZXIsSystemClassOrEmpty(uid)) continue;

                    tableRowHits++;
                    if (!results[uid]) {
                        results[uid] = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"uid": uid,
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

+ (NSString *)resolvedProfilesPath
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        return [docs stringByAppendingPathComponent:@"zx_resolved_profiles.json"];
    }
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"zx_resolved_profiles.json"];
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

        // 1. Source (a): Scan ALL SQLite databases (prioritizing global.sqlite / search/global.sqlite) across Documents, Library, App Groups for HiddenChatEntity
        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        for (NSString *path in dbPaths) {
            ZXScanDatabaseForHiddenIDs(path, found);
        }
        for (NSString *dk in dismissedKeys) {
            [found removeObjectForKey:dk];
        }

        // 2. Source (b): Load verified records from zx_resolved_profiles.json & hidden_chats.json (strictly rejecting non-section PIN hits & forbidden names)
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

        // Sanitize ramProfiles: purge any entry with forbidden displayName or old un-sectioned pin: search hits
        BOOL cleanedProfiles = NO;
        for (NSString *k in [ramProfiles allKeys]) {
            if ([dismissedKeys containsObject:k] || [k hasPrefix:@"_"]) {
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
            // Any synthetic pin: item MUST have been captured strictly inside the "Trò chuyện ẩn" section (inHiddenSection == YES)
            if ([k hasPrefix:@"pin:"] && ![prof[@"inHiddenSection"] boolValue]) {
                [ramProfiles removeObjectForKey:k];
                cleanedProfiles = YES;
                continue;
            }
        }
        if (cleanedProfiles && primaryPath.length > 0) {
            NSData *cleanOut = [NSJSONSerialization dataWithJSONObject:ramProfiles options:0 error:nil];
            if (cleanOut) [cleanOut writeToFile:primaryPath atomically:YES];
        }

        for (NSString *hcPath in ZXCandidateJSONPathsForName(@"hidden_chats.json")) {
            NSData *hd = [NSData dataWithContentsOfFile:hcPath];
            if (!hd) continue;
            id hArr = [NSJSONSerialization JSONObjectWithData:hd options:0 error:nil];
            if ([hArr isKindOfClass:[NSArray class]]) {
                for (NSDictionary *item in (NSArray *)hArr) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSString *uid = [[item[@"uid"] description] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (uid.length == 0 || ZXIsSystemClassOrEmpty(uid) || [dismissedKeys containsObject:uid]) continue;
                    NSString *src = [item[@"hiddenSource"] description] ?: @"";
                    // Reject old un-sectioned PinSearch synthetic rows from previous builds!
                    if ([uid hasPrefix:@"pin:"] && ![item[@"inHiddenSection"] boolValue]) continue;
                    if (!found[uid] && ![src isEqualToString:@"HideAction"] && ![item[@"inHiddenSection"] boolValue]) {
                        continue;
                    }
                    NSString *rName = [[item[@"rawName"] description] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (!ZXIsValidHumanDisplayName(rName, uid)) {
                        if ([uid hasPrefix:@"pin:"] || [uid hasPrefix:@"hide:"]) continue;
                        rName = @"";
                    }
                    NSString *lMsg = [item[@"lastMessage"] description] ?: @"";
                    if (ZXIsSystemClassOrEmpty(lMsg)) lMsg = @"";

                    if (!found[uid]) {
                        found[uid] = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"uid": uid,
                            @"rawName": rName,
                            @"lastMessage": lMsg,
                            @"hiddenSource": src.length ? src : @"PinSearch",
                            @"inHiddenSection": @([item[@"inHiddenSection"] boolValue]),
                            @"sourceTable": @"hidden_chats.json",
                            @"updatedAt": item[@"updatedAt"] ?: @((long long)[[NSDate date] timeIntervalSince1970])
                        }];
                    } else {
                        if ([found[uid][@"rawName"] length] == 0 && rName.length > 0) found[uid][@"rawName"] = rName;
                        if ([found[uid][@"lastMessage"] length] == 0 && lMsg.length > 0) found[uid][@"lastMessage"] = lMsg;
                    }
                }
            }
        }

        // Merge verified hidden-section items from zx_resolved_profiles.json
        for (NSString *key in ramProfiles.allKeys) {
            if ([key hasPrefix:@"_"] || ZXIsSystemClassOrEmpty(key) || [dismissedKeys containsObject:key]) continue;
            NSDictionary *prof = [ramProfiles[key] isKindOfClass:[NSDictionary class]] ? ramProfiles[key] : nil;
            if (!prof) continue;
            NSString *src = [prof[@"hiddenSource"] description] ?: @"";
            BOOL allowedStandalone = [src isEqualToString:@"HideAction"] || ([src isEqualToString:@"PinSearch"] && [prof[@"inHiddenSection"] boolValue]);
            if (allowedStandalone && !found[key]) {
                NSString *pName = [prof[@"name"] description] ?: @"";
                if (!ZXIsValidHumanDisplayName(pName, key)) continue;
                NSString *pMsg = [prof[@"lastMessage"] description] ?: @"";
                if (ZXIsSystemClassOrEmpty(pMsg)) pMsg = @"";
                found[key] = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"uid": key,
                    @"rawName": pName,
                    @"lastMessage": pMsg,
                    @"hiddenSource": src,
                    @"inHiddenSection": @([prof[@"inHiddenSection"] boolValue]),
                    @"sourceTable": @"zx_resolved_profiles.json",
                    @"updatedAt": prof[@"timestamp"] ?: @((long long)[[NSDate date] timeIntervalSince1970])
                }];
            }
        }

        // 3. Overlay resolved human names from zx_resolved_profiles.json ONLY by exact matching ID (NEVER blind force-link lone old ID!)
        for (NSString *uid in found) {
            NSMutableDictionary *entry = found[uid];
            NSDictionary *prof = [ramProfiles[uid] isKindOfClass:[NSDictionary class]] ? ramProfiles[uid] : nil;
            if (!prof) {
                NSString *cleanDigits = [[uid componentsSeparatedByCharactersInSet:
                                         [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
                if (cleanDigits.length >= 4 && [ramProfiles[cleanDigits] isKindOfClass:[NSDictionary class]]) {
                    prof = ramProfiles[cleanDigits];
                }
            }
            if (prof) {
                NSString *pName = [prof[@"name"] description] ?: @"";
                NSString *pMsg = [prof[@"lastMessage"] description] ?: @"";
                if (ZXIsValidHumanDisplayName(pName, uid)) {
                    entry[@"rawName"] = pName;
                }
                if (pMsg.length > 0 && !ZXIsSystemClassOrEmpty(pMsg)) {
                    entry[@"lastMessage"] = pMsg;
                }
            }
        }

        // 4. Format final list: NEVER drop an unresolved HiddenChatEntity ID! Always show "Hội thoại ẩn (ID: <id>)"
        NSMutableArray<NSDictionary *> *finalList = [NSMutableArray new];
        for (NSString *uid in found) {
            NSMutableDictionary *entry = found[uid];
            NSString *rawName = entry[@"rawName"] ?: @"";
            if (rawName.length > 0 && !ZXIsValidHumanDisplayName(rawName, uid)) {
                rawName = @"";
            }
            BOOL isSyntheticKey = ([uid hasPrefix:@"pin:"] || [uid hasPrefix:@"hide:"]);
            if (isSyntheticKey && rawName.length == 0) continue;

            NSString *displayTitle = nil;
            if (rawName.length > 0) {
                displayTitle = isSyntheticKey ? rawName : [NSString stringWithFormat:@"%@ (ID: %@)", rawName, uid];
            } else {
                displayTitle = [NSString stringWithFormat:@"Hội thoại ẩn (ID: %@)", uid];
            }
            NSString *lastMsg = entry[@"lastMessage"] ?: @"";
            if (lastMsg.length == 0) {
                NSString *src = entry[@"sourceTable"] ?: @"HiddenChatEntity";
                lastMsg = rawName.length > 0
                    ? [NSString stringWithFormat:@"Đã lưu tên thật • %@", src]
                    : [NSString stringWithFormat:@"%@ • Bấm Mở thẳng khung chat & nhập PIN để xem", src];
            }
            [finalList addObject:@{
                @"uid": uid,
                @"rawName": rawName,
                @"name": displayTitle,
                @"lastMessage": lastMsg,
                @"hiddenSource": entry[@"hiddenSource"] ?: @"HiddenChatEntity",
                @"inHiddenSection": @([entry[@"inHiddenSection"] boolValue]),
                @"verified": @(rawName.length > 0),
                @"updatedAt": entry[@"updatedAt"] ?: @0
            }];
        }

        ZXLog(@"HiddenChats scan inspected %lu DBs (%lu RAM entries) -> %lu hidden chats",
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
