#import <UIKit/UIKit.h>
#import "ZXScanner.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import <objc/runtime.h>
#import <sqlite3.h>
#import <string.h>

/// Rejects empty strings, file paths, SQLite internal names, and pure runtime class names.
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
            [trim hasPrefix:@"NS"] || [trim hasPrefix:@"ZX"] || [trim hasPrefix:@"WK"] || [trim hasPrefix:@"CA"] ||
            [trim hasPrefix:@"GlobalSearchLogic."] || [trim hasPrefix:@"ZAGlobalSearch."]) {
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
        if (([trim hasPrefix:@"ZA"] || [trim hasPrefix:@"ZDS"] || [trim hasPrefix:@"UX"] || [trim hasPrefix:@"GS"]) && trim.length > 4) {
            NSRange digitRange = [trim rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet];
            if (digitRange.location == NSNotFound) return YES;
        }
    }
    return NO;
}

/// Checks if a candidate string is a valid human/group display name (1-80 chars, has letters, not system/status text).
static BOOL ZXIsValidHumanDisplayName(NSString *s, NSString *excludeUID)
{
    if (!s) return NO;
    NSString *trim = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length < 1 || trim.length > 80) return NO;
    if (excludeUID.length && [trim isEqualToString:excludeUID]) return NO;
    if (ZXIsSystemClassOrEmpty(trim)) return NO;

    NSString *lc = trim.lowercaseString;
    NSArray<NSString *> *badNamePhrases = @[
        @"ảnh đã hết hạn", @"video đã hết hạn", @"file đã hết hạn", @"tệp đã hết hạn",
        @"tin nhắn đã thu hồi", @"tin nhắn đã được thu hồi", @"đã thu hồi",
        @"hiddenchatentity", @"searchglobal.sqlite", @"search/global.sqlite", @"global.sqlite", @".sqlite",
        @"nhập pin", @"nhập mã pin", @"đổi mã pin", @"cài đặt trò chuyện ẩn", @"thiết lập mã pin",
        @"đang hoạt động", @"vừa xong", @"chạm để", @"xem thêm", @"thu gọn",
        @"hội thoại ẩn", @"trò chuyện ẩn", @"chưa giải mã", @"không tìm thấy",
        @"kết quả tìm kiếm", @"chưa có tin nhắn", @"tìm kiếm gần đây", @"liên hệ gần đây",
        @"từ khóa tìm kiếm", @"không có kết quả", @"vừa truy cập", @"đang nhập",
        @"thông tin này chưa được liên kết"
    ];
    for (NSString *bad in badNamePhrases) {
        if ([lc containsString:bad]) return NO;
    }
    if ([lc hasPrefix:@"uid:"] || [lc hasPrefix:@"id:"] || [lc hasPrefix:@"tin nhắn ("] ||
        [lc hasPrefix:@"liên hệ ("] || [lc hasPrefix:@"link ("] || [lc hasPrefix:@"file ("]) {
        return NO;
    }

    NSRange letterRange = [trim rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
    if (letterRange.location == NSNotFound) return NO;

    for (NSUInteger i = 0; i < trim.length; i++) {
        unichar c = [trim characterAtIndex:i];
        if (c < 32 || c == 0xFFFD) return NO;
    }
    return YES;
}

static NSString *ZXExtractDigitCore(NSString *raw)
{
    if (!raw || raw.length == 0) return @"";
    return [[raw componentsSeparatedByCharactersInSet:
             [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
}

static BOOL ZXMatchesAnyOwnerUID(NSString *candidateID, NSSet<NSString *> *ownerUIDs)
{
    if (!candidateID || candidateID.length == 0) return YES;
    if ([ownerUIDs containsObject:candidateID]) return YES;
    NSString *digits = ZXExtractDigitCore(candidateID);
    if (digits.length > 0 && [ownerUIDs containsObject:digits]) return YES;
    NSString *cfgOwner = [ZXConfig currentUserID];
    if (cfgOwner.length > 0 && ([candidateID isEqualToString:cfgOwner] || (digits.length > 0 && [digits isEqualToString:cfgOwner]))) {
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

static void ZXCollectSQLiteFilesInDir(NSString *dir, NSMutableArray<NSString *> *outPaths, NSMutableSet<NSString *> *seen, int depth)
{
    if (!dir || depth > 6 || outPaths.count >= 400) return;
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
                // Prioritize Documents/searchglobal.sqlite & global.sqlite at index 0
                if ([lc hasSuffix:@"searchglobal.sqlite"] || [lc hasSuffix:@"global.sqlite"]) {
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
    NSFileManager *fm = [NSFileManager defaultManager];

    // Explicit fast check for Documents/searchglobal.sqlite first
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        for (NSString *directRel in @[@"searchglobal.sqlite", @"search/global.sqlite", @"global.sqlite"]) {
            NSString *p = [docs stringByAppendingPathComponent:directRel];
            if ([fm fileExistsAtPath:p] && ![seen containsObject:p]) {
                [seen addObject:p];
                [dbPaths addObject:p];
            }
        }
    }

    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [roots addObject:[home stringByAppendingPathComponent:@"Documents"]];
        [roots addObject:[home stringByAppendingPathComponent:@"Library"]];
    }
    for (NSNumber *dirType in @[@(NSDocumentDirectory), @(NSLibraryDirectory), @(NSCachesDirectory), @(NSApplicationSupportDirectory)]) {
        NSString *p = NSSearchPathForDirectoriesInDomains((NSSearchPathDirectory)dirType.unsignedIntegerValue, NSUserDomainMask, YES).firstObject;
        if (p.length && ![roots containsObject:p]) [roots addObject:p];
    }
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSMutableArray<NSString *> *groupIds = [NSMutableArray arrayWithArray:@[
        @"group.vn.com.vng.zingalo",
        @"group.com.vng.zalo"
    ]];
    if (bundleID.length > 0) {
        NSString *customGroup = [@"group." stringByAppendingString:bundleID];
        if (![groupIds containsObject:customGroup]) [groupIds addObject:customGroup];
    }
    for (NSString *gid in groupIds) {
        NSURL *gURL = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
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

/// Copies <db>.sqlite, <db>.sqlite-wal, and <db>.sqlite-shm simultaneously to an isolated directory in NSTemporaryDirectory()
/// so uncommitted WAL frames are safely read with SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX without locking Zalo's live DB.
static NSString *ZXCopySQLiteSnapshotToTemp(NSString *srcDbPath, NSString **outTempDir)
{
    if (!srcDbPath || srcDbPath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:srcDbPath]) return nil;

    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"zx_hchat_%@", [[NSUUID UUID] UUIDString]]];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:&err]) {
        return nil;
    }
    NSString *fileName = srcDbPath.lastPathComponent;
    NSString *dstDbPath = [tempDir stringByAppendingPathComponent:fileName];
    if (![fm copyItemAtPath:srcDbPath toPath:dstDbPath error:&err]) {
        [fm removeItemAtPath:tempDir error:nil];
        return nil;
    }

    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        NSString *srcSidecar = [srcDbPath stringByAppendingString:suffix];
        if ([fm fileExistsAtPath:srcSidecar]) {
            NSString *dstSidecar = [dstDbPath stringByAppendingString:suffix];
            [fm copyItemAtPath:srcSidecar toPath:dstSidecar error:nil];
        }
    }

    if (outTempDir) *outTempDir = tempDir;
    return dstDbPath;
}

/// Queries HiddenChatEntity (CREATE TABLE HiddenChatEntity (userid TEXT NOT NULL, threadid TEXT NOT NULL, timestamp DATETIME, threadtype INTEGER, ...)):
/// - Stores `userid` into ioOwnerUIDs (account owner ID, e.g. "320193294") so it is STRICTLY EXCLUDED.
/// - Queries ONLY `threadid` and `threadtype`: SELECT DISTINCT threadid, threadtype FROM HiddenChatEntity WHERE threadid IS NOT NULL AND length(threadid) > 0;
static void ZXScanHiddenChatEntityInDatabase(NSString *srcDbPath,
                                             NSMutableDictionary<NSString *, NSMutableDictionary *> *outThreads,
                                             NSMutableSet<NSString *> *ioOwnerUIDs,
                                             BOOL *outFoundHiddenTable)
{
    if (!srcDbPath || !outThreads || !ioOwnerUIDs) return;
    // Fast filter: only copy & inspect searchglobal.sqlite / global.sqlite / hidden* DBs unless checking all
    NSString *lcPath = srcDbPath.lowercaseString;
    if (![lcPath containsString:@"global"] && ![lcPath containsString:@"search"] && ![lcPath containsString:@"hidden"]) {
        return;
    }

    NSString *tempDir = nil;
    sqlite3 *db = NULL;
    @try {
        NSString *tempDbPath = ZXCopySQLiteSnapshotToTemp(srcDbPath, &tempDir);
        if (!tempDbPath) return;

        int rc = sqlite3_open_v2(tempDbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
        if (rc != SQLITE_OK || !db) {
            if (db) { sqlite3_close(db); db = NULL; }
            return;
        }
        sqlite3_busy_timeout(db, 200);

        BOOL hasHiddenTable = NO;
        sqlite3_stmt *chkStmt = NULL;
        int prepRC = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND lower(name)='hiddenchatentity' LIMIT 1;", -1, &chkStmt, NULL);
        if (prepRC != SQLITE_OK && tempDir.length > 0) {
            // If -wal was present without -shm, SQLITE_OPEN_READONLY cannot rebuild the WAL index; reopen our isolated temp copy READWRITE
            if (chkStmt) { sqlite3_finalize(chkStmt); chkStmt = NULL; }
            sqlite3_close(db);
            db = NULL;
            if (sqlite3_open_v2(tempDbPath.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK && db) {
                prepRC = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND lower(name)='hiddenchatentity' LIMIT 1;", -1, &chkStmt, NULL);
            }
        }
        if (prepRC == SQLITE_OK && chkStmt) {
            if (sqlite3_step(chkStmt) == SQLITE_ROW) {
                hasHiddenTable = YES;
            }
        }
        if (chkStmt) sqlite3_finalize(chkStmt);
        if (!hasHiddenTable) return;

        if (outFoundHiddenTable) *outFoundHiddenTable = YES;

        // Step A: Read `userid` column (ownerUID, e.g. "320193294") and persist so it is NEVER added to hidden chats!
        sqlite3_stmt *ownerStmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT DISTINCT userid FROM HiddenChatEntity WHERE userid IS NOT NULL AND length(userid) > 0;", -1, &ownerStmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(ownerStmt) == SQLITE_ROW) {
                NSString *ownerId = [ZXColumnText(ownerStmt, 0) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (ownerId.length > 0) {
                    [ioOwnerUIDs addObject:ownerId];
                    NSString *ownerDigits = ZXExtractDigitCore(ownerId);
                    if (ownerDigits.length > 0) [ioOwnerUIDs addObject:ownerDigits];
                }
            }
            sqlite3_finalize(ownerStmt);
        }
        if (ioOwnerUIDs.count > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:ioOwnerUIDs.allObjects forKey:@"zx_owner_uids_v5"];
        }

        // Step B: Strictly query ONLY `threadid` and `threadtype`
        sqlite3_stmt *qStmt = NULL;
        const char *sql = "SELECT DISTINCT threadid, threadtype FROM HiddenChatEntity WHERE threadid IS NOT NULL AND length(threadid) > 0;";
        if (sqlite3_prepare_v2(db, sql, -1, &qStmt, NULL) == SQLITE_OK) {
            NSUInteger rowHits = 0;
            while (sqlite3_step(qStmt) == SQLITE_ROW) {
                NSString *threadId = [ZXColumnText(qStmt, 0) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                int threadType = sqlite3_column_int(qStmt, 1);
                if (threadId.length == 0 || [threadId isEqualToString:@"0"] || ZXIsSystemClassOrEmpty(threadId)) {
                    continue;
                }
                // STRICT RULE: NEVER allow ownerUID ("320193294") into hidden chats!
                if (ZXMatchesAnyOwnerUID(threadId, ioOwnerUIDs)) {
                    continue;
                }

                rowHits++;
                if (!outThreads[threadId]) {
                    outThreads[threadId] = [NSMutableDictionary dictionaryWithDictionary:@{
                        @"uid": threadId,
                        @"threadId": threadId,
                        @"threadType": @(threadType),
                        @"digitCore": ZXExtractDigitCore(threadId),
                        @"rawName": @"",
                        @"subtitle": @"",
                        @"sourceTable": [NSString stringWithFormat:@"%@ • HiddenChatEntity", srcDbPath.lastPathComponent],
                        @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                    }];
                }
            }
            ZXLog(@"HiddenChatEntity (%@): %lu hidden threadids (ownerUIDs=%@)",
                  srcDbPath.lastPathComponent, (unsigned long)rowHits, [ioOwnerUIDs.allObjects componentsJoinedByString:@","]);
            sqlite3_finalize(qStmt);
        }
    } @catch (NSException *e) {
        ZXLog(@"ZXScanHiddenChatEntityInDatabase exception: %@", e.reason);
    } @finally {
        if (db) sqlite3_close(db);
        if (tempDir.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
        }
    }
}

static NSArray<NSString *> *ZXCandidateCacheFilePaths(NSString *fileName)
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
        NSString *full = [dir stringByAppendingPathComponent:fileName];
        if (![paths containsObject:full]) [paths addObject:full];
    }
    return paths;
}

/// Loads `Documents/zx_resolved_profiles.json`. If `schema_version` is missing or != `"v5_gs_hidden_model"`,
/// automatically deletes ALL legacy cache files so corrupted old entries ("Ivory", "320193294", "Ảnh đã hết hạn") are wiped clean!
static NSDictionary<NSString *, NSDictionary *> *ZXLoadVerifiedV5Profiles(NSSet<NSString *> *ownerUIDs)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *primaryPath = [ZXScanner resolvedProfilesPath];

    // Purge any legacy hidden_chats.json files from older schemas
    static dispatch_once_t onceCleanLegacy;
    dispatch_once(&onceCleanLegacy, ^{
        if (![[NSUserDefaults standardUserDefaults] boolForKey:@"zx_migrated_v5_gs_hidden_model"]) {
            for (NSString *oldHC in ZXCandidateCacheFilePaths(@"hidden_chats.json")) {
                if ([fm fileExistsAtPath:oldHC]) [fm removeItemAtPath:oldHC error:nil];
            }
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"zx_dismissed_hidden_keys"];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"zx_migrated_v5_gs_hidden_model"];
        }
    });

    for (NSString *candPath in ZXCandidateCacheFilePaths(@"zx_resolved_profiles.json")) {
        if (![fm fileExistsAtPath:candPath]) continue;
        NSData *d = [NSData dataWithContentsOfFile:candPath];
        if (!d) {
            [fm removeItemAtPath:candPath error:nil];
            continue;
        }
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? (NSDictionary *)json : nil;
        NSString *ver = [root[@"schema_version"] isKindOfClass:[NSString class]] ? root[@"schema_version"] : @"";
        if (![ver isEqualToString:ZX_HIDDEN_CACHE_SCHEMA_VERSION]) {
            ZXLog(@"Purging outdated cache at %@ (schema_version='%@' != '%@')", candPath.lastPathComponent, ver, ZX_HIDDEN_CACHE_SCHEMA_VERSION);
            [fm removeItemAtPath:candPath error:nil];
            continue;
        }
        if (![candPath isEqualToString:primaryPath]) continue;

        NSDictionary *rawProfiles = [root[@"profiles"] isKindOfClass:[NSDictionary class]] ? root[@"profiles"] : @{};
        NSMutableDictionary<NSString *, NSDictionary *> *valid = [NSMutableDictionary new];
        BOOL dirty = NO;

        for (NSString *k in rawProfiles) {
            NSDictionary *item = [rawProfiles[k] isKindOfClass:[NSDictionary class]] ? rawProfiles[k] : nil;
            if (!item) { dirty = YES; continue; }
            NSString *tid = [[item[@"threadId"] ?: item[@"uid"] ?: k description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *dName = [[item[@"displayName"] ?: item[@"name"] ?: @"" description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (tid.length == 0 || ZXMatchesAnyOwnerUID(tid, ownerUIDs) || !ZXIsValidHumanDisplayName(dName, tid)) {
                dirty = YES;
                continue;
            }
            valid[tid] = item;
        }

        if (dirty) {
            NSDictionary *rewritten = @{
                @"schema_version": ZX_HIDDEN_CACHE_SCHEMA_VERSION,
                @"updated_at": @((long long)[[NSDate date] timeIntervalSince1970]),
                @"profiles": valid
            };
            NSData *outData = [NSJSONSerialization dataWithJSONObject:rewritten options:0 error:nil];
            if (outData) [outData writeToFile:primaryPath atomically:YES];
        }
        return valid;
    }
    return @{};
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
    if (!obj || depth > maxDepth || outLog.length > 160000) return;
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
                if (!nameC || !encC || encC[0] != '@' || encC[1] == '?') continue;
                @try {
                    id val = ZXScannerSafeReadObjectIvar(obj, ivars[i]);
                    if (!val) continue;
                    if ([val isKindOfClass:[UIView class]] || [val isKindOfClass:[CALayer class]] ||
                        [val isKindOfClass:[UIViewController class]] || [val isKindOfClass:[UIImage class]]) {
                        continue;
                    }
                    NSString *ivName = [NSString stringWithUTF8String:nameC];
                    if ([val isKindOfClass:[NSString class]] || [val isKindOfClass:[NSNumber class]]) {
                        [outLog appendFormat:@"%@• [%s] %@ = \"%@\"\n", indent, class_getName(curCls), ivName, val];
                    } else if ([val isKindOfClass:[NSArray class]]) {
                        [outLog appendFormat:@"%@• [%s] %@ (NSArray count=%lu)\n", indent, class_getName(curCls), ivName, (unsigned long)[(NSArray *)val count]];
                    } else if (![val isKindOfClass:[NSSet class]] && ![val isKindOfClass:[NSData class]]) {
                        [outLog appendFormat:@"%@• [%s] %@ -> <%s: %p>\n", indent, class_getName(curCls), ivName, object_getClassName(val), (__bridge void *)val];
                        ZXDumpObjectIvarsRecursive(val, depth + 1, maxDepth, outLog, visited);
                    }
                } @catch (__unused NSException *e) {}
            }
            free(ivars);
        }
        curCls = class_getSuperclass(curCls);
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

+ (NSSet<NSString *> *)discoveredOwnerUIDs
{
    NSMutableSet<NSString *> *owners = [NSMutableSet setWithArray:
        ([[NSUserDefaults standardUserDefaults] arrayForKey:@"zx_owner_uids_v5"] ?: @[])];
    NSString *cfgUID = [ZXConfig currentUserID];
    if (cfgUID.length > 0) [owners addObject:cfgUID];
    return owners;
}

+ (NSDictionary<NSString *, NSString *> *)currentHiddenChatDigitToUIDMap
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *threads = [NSMutableDictionary new];
    NSMutableSet<NSString *> *owners = [NSMutableSet setWithSet:[self discoveredOwnerUIDs]];
    NSMutableDictionary<NSString *, NSString *> *digitMap = [NSMutableDictionary new];
    @try {
        for (NSString *path in ZXAllZaloSQLitePaths()) {
            ZXScanHiddenChatEntityInDatabase(path, threads, owners, NULL);
        }
        for (NSString *tid in threads) {
            if (ZXMatchesAnyOwnerUID(tid, owners)) continue;
            NSString *digits = ZXExtractDigitCore(tid);
            if (digits.length >= 4) digitMap[digits] = tid;
            digitMap[tid] = tid;
        }
    } @catch (NSException *e) {
        ZXLog(@"currentHiddenChatDigitToUIDMap exception: %@", e.reason);
    }
    return digitMap;
}

+ (NSArray<NSString *> *)currentHiddenChatEntityIDs
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *threads = [NSMutableDictionary new];
    NSMutableSet<NSString *> *owners = [NSMutableSet setWithSet:[self discoveredOwnerUIDs]];
    @try {
        for (NSString *path in ZXAllZaloSQLitePaths()) {
            ZXScanHiddenChatEntityInDatabase(path, threads, owners, NULL);
        }
    } @catch (NSException *e) {
        ZXLog(@"currentHiddenChatEntityIDs exception: %@", e.reason);
    }
    return threads.allKeys ?: @[];
}

+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *merged = [NSMutableDictionary new];
    @try {
        NSSet<NSString *> *dismissedKeys = [NSSet setWithArray:([[NSUserDefaults standardUserDefaults] arrayForKey:@"zx_dismissed_hidden_keys"] ?: @[])];
        NSSet<NSString *> *unhiddenIDs = [NSSet setWithArray:([[NSUserDefaults standardUserDefaults] arrayForKey:@"nthe_unhidden_thread_ids"] ?: @[])];
        NSMutableSet<NSString *> *ownerUIDs = [NSMutableSet setWithSet:[self discoveredOwnerUIDs]];

        // 1. Scan HiddenChatEntity (via WAL-safe temp copy): collects ownerUIDs from `userid` and hidden `threadid`s
        BOOL foundHiddenEntityTable = NO;
        NSArray<NSString *> *dbPaths = ZXAllZaloSQLitePaths();
        for (NSString *path in dbPaths) {
            ZXScanHiddenChatEntityInDatabase(path, merged, ownerUIDs, &foundHiddenEntityTable);
        }

        // Remove dismissed or explicitly unhidden IDs & ownerUIDs
        for (NSString *tid in [merged allKeys]) {
            if ([dismissedKeys containsObject:tid] || [unhiddenIDs containsObject:tid] || ZXMatchesAnyOwnerUID(tid, ownerUIDs)) {
                [merged removeObjectForKey:tid];
            }
        }

        // Build digit-core index for SQLite threadIds so e.g. "g_330571633" and "330571633" merge cleanly without duplicating
        NSMutableDictionary<NSString *, NSString *> *digitToCanonicalThreadID = [NSMutableDictionary new];
        for (NSString *tid in merged) {
            NSString *dCore = ZXExtractDigitCore(tid);
            if (dCore.length >= 4) digitToCanonicalThreadID[dCore] = tid;
            digitToCanonicalThreadID[tid] = tid;
        }

        // 2. Load verified v5 profiles (`schema_version == "v5_gs_hidden_model"` — auto-purges older schemas!)
        NSDictionary<NSString *, NSDictionary *> *v5Profiles = ZXLoadVerifiedV5Profiles(ownerUIDs);
        long long nowTs = (long long)[[NSDate date] timeIntervalSince1970];

        // 3. Merge v5 profiles with HiddenChatEntity threadIds
        for (NSString *pKey in v5Profiles) {
            NSDictionary *prof = v5Profiles[pKey];
            NSString *pTid = [[prof[@"threadId"] ?: prof[@"uid"] ?: pKey description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (pTid.length == 0 || ZXMatchesAnyOwnerUID(pTid, ownerUIDs) ||
                [dismissedKeys containsObject:pTid] || [unhiddenIDs containsObject:pTid]) {
                continue;
            }
            NSString *dName = [[prof[@"displayName"] ?: prof[@"name"] ?: @"" description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!ZXIsValidHumanDisplayName(dName, pTid)) continue;
            NSString *sub = [[prof[@"subtitle"] ?: @"" description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (ZXIsSystemClassOrEmpty(sub)) sub = @"";

            NSString *pDigits = ZXExtractDigitCore(pTid);
            NSString *matchedSQLThread = digitToCanonicalThreadID[pTid] ?: (pDigits.length >= 4 ? digitToCanonicalThreadID[pDigits] : nil);

            if (matchedSQLThread) {
                NSMutableDictionary *entry = merged[matchedSQLThread];
                entry[@"rawName"] = dName;
                entry[@"subtitle"] = sub;
                entry[@"resolved"] = @YES;
            } else {
                // If HiddenChatEntity table exists on disk, only include a standalone v5 entry if it was just captured (< 30s) or table wasn't found,
                // otherwise if HiddenChatEntity was read and doesn't contain pTid, check if user unhid it in Zalo
                long long updated = [prof[@"updatedAt"] longLongValue];
                if (!foundHiddenEntityTable || (nowTs - updated) <= 30 || merged.count == 0) {
                    merged[pTid] = [NSMutableDictionary dictionaryWithDictionary:@{
                        @"uid": pTid,
                        @"threadId": pTid,
                        @"threadType": prof[@"threadType"] ?: @0,
                        @"rawName": dName,
                        @"subtitle": sub,
                        @"resolved": @YES,
                        @"updatedAt": @(updated > 0 ? updated : nowTs)
                    }];
                    if (pDigits.length >= 4) digitToCanonicalThreadID[pDigits] = pTid;
                    digitToCanonicalThreadID[pTid] = pTid;
                }
            }
        }

        // 4. Build final output list sorted cleanly (resolved names first, then unresolved threadIds)
        NSMutableArray<NSDictionary *> *finalList = [NSMutableArray arrayWithCapacity:merged.count];
        NSArray<NSString *> *sortedKeys = [merged.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *tid in sortedKeys) {
            if (ZXMatchesAnyOwnerUID(tid, ownerUIDs)) continue;
            NSDictionary *entry = merged[tid];
            NSString *rawName = entry[@"rawName"] ?: @"";
            BOOL hasName = ZXIsValidHumanDisplayName(rawName, tid);
            if (!hasName) rawName = @"";

            NSString *subtitle = entry[@"subtitle"] ?: @"";
            NSString *displayTitle = hasName
                ? rawName
                : [NSString stringWithFormat:@"Hội thoại ẩn (ID: %@)", tid];
            NSString *detailLine = hasName
                ? (subtitle.length > 0
                    ? [NSString stringWithFormat:@"ID: %@ • GlobalSearchLogic • %@", tid, subtitle]
                    : [NSString stringWithFormat:@"ID: %@ • GlobalSearchLogic", tid])
                : @"Gõ mã PIN ẩn 1 lần trên thanh Tìm kiếm Zalo để tự động hiện đủ 100% tên thật";

            [finalList addObject:@{
                @"uid": tid,
                @"threadId": tid,
                @"threadType": entry[@"threadType"] ?: @0,
                @"rawName": rawName,
                @"name": displayTitle,
                @"subtitle": subtitle,
                @"lastMessage": detailLine,
                @"hiddenSource": hasName ? @"GlobalSearchLogic" : @"HiddenChatEntity",
                @"verified": @(hasName),
                @"modelVerified": @(hasName),
                @"updatedAt": entry[@"updatedAt"] ?: @0
            }];
        }

        [finalList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL va = [a[@"verified"] boolValue];
            BOOL vb = [b[@"verified"] boolValue];
            if (va != vb) return va ? NSOrderedAscending : NSOrderedDescending;
            return [(a[@"name"] ?: @"") localizedCaseInsensitiveCompare:(b[@"name"] ?: @"")];
        }];

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
        for (UIWindow *win in ZXScannerAllSceneWindows()) {
            if ([NSStringFromClass([win class]) hasPrefix:@"ZX"]) continue;
            [log appendFormat:@"Window: %s key=%d hidden=%d rootVC=%s\n",
                object_getClassName(win), win.isKeyWindow, win.hidden,
                win.rootViewController ? object_getClassName(win.rootViewController) : "nil"];
        }
    } @catch (__unused NSException *e) {}
    return log;
}

+ (NSString *)runHiddenIntrospectionWithPinSnapshot:(NSString *)pinSnapshot liveSceneDump:(NSString *)liveSceneDump
{
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"=== ZALO 26.11.02.1 v5_gs_hidden_model DIAGNOSTICS ===\nBundleID: %@\nOwnerUIDs: %@\nTime: %@\n\n",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
        [[self discoveredOwnerUIDs].allObjects componentsJoinedByString:@","],
        [NSDate date]];

    @try {
        [log appendString:@"[1] HiddenChatEntity (WAL-safe Temp Copy):\n"];
        NSArray<NSDictionary *> *rows = [self scanSQLiteForHiddenChats];
        for (NSDictionary *r in rows) {
            [log appendFormat:@"  • threadId=%@ | name='%@' | verified=%@ | source=%@\n",
                r[@"threadId"], r[@"rawName"], r[@"verified"], r[@"hiddenSource"]];
        }
        if (pinSnapshot.length > 0) {
            [log appendFormat:@"\n[2] GlobalSearchLogic Capture Log:\n%@\n", pinSnapshot];
        }
        if (liveSceneDump.length > 0) {
            [log appendFormat:@"\n[3] Active Windows:\n%@\n", liveSceneDump];
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
        NSSet<NSString *> *owners = [self discoveredOwnerUIDs];
        if (ZXMatchesAnyOwnerUID(chatID, owners)) return NO;

        NSString *cleanDigits = ZXExtractDigitCore(chatID);
        BOOL isNumeric = (cleanDigits.length >= 4 && [cleanDigits isEqualToString:chatID]);

        for (NSString *dbPath in ZXAllZaloSQLitePaths()) {
            NSString *lcPath = dbPath.lowercaseString;
            if (![lcPath containsString:@"global"] && ![lcPath containsString:@"search"] && ![lcPath containsString:@"hidden"]) {
                continue;
            }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK || !db) {
                if (db) sqlite3_close(db);
                continue;
            }
            sqlite3_busy_timeout(db, 300);

            // Strictly delete ONLY by `threadid` (NEVER by `userid`!)
            NSString *delSQL = isNumeric
                ? [NSString stringWithFormat:@"DELETE FROM HiddenChatEntity WHERE threadid = '%@' OR threadid = %@;", chatID, cleanDigits]
                : [NSString stringWithFormat:@"DELETE FROM HiddenChatEntity WHERE threadid = '%@';",
                   [chatID stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
            if (sqlite3_exec(db, delSQL.UTF8String, NULL, NULL, NULL) == SQLITE_OK && sqlite3_changes(db) > 0) {
                modifiedAny = YES;
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
