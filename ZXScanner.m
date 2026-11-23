#import "ZXScanner.h"
#import "ZXConfig.h"
#import "ZXLog.h"
#import <objc/runtime.h>
#import <sqlite3.h>

static BOOL ZXIsSQLiteFileAtPath(NSString *path)
{
    NSString *lower = path.lowercaseString;
    if ([lower hasSuffix:@"-wal"] || [lower hasSuffix:@"-shm"] || [lower hasSuffix:@"-journal"]) return NO;
    if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"] || [lower hasSuffix:@".sqlitedb"]) {
        return YES;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:16];
    [fh closeFile];
    if (head.length < 16) return NO;
    return memcmp(head.bytes, "SQLite format 3", 15) == 0;
}

static void ZXCollectSQLiteFilesInDir(NSString *dir, NSMutableSet<NSString *> *outPaths, int depth)
{
    if (!dir || depth > 5) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in items) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            ZXCollectSQLiteFilesInDir(full, outPaths, depth + 1);
        } else if (ZXIsSQLiteFileAtPath(full)) {
            [outPaths addObject:full];
        }
    }
}

static NSString *ZXColumnText(sqlite3_stmt *stmt, int col)
{
    if (col < 0) return @"";
    const unsigned char *txt = sqlite3_column_text(stmt, col);
    if (!txt) return @"";
    return [NSString stringWithUTF8String:(const char *)txt] ?: @"";
}

static void ZXScanSingleDatabase(NSString *dbPath, NSMutableDictionary<NSString *, NSDictionary *> *results)
{
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 400);

    NSMutableArray<NSString *> *tables = [NSMutableArray new];
    sqlite3_stmt *tStmt = NULL;
    const char *tSql = "SELECT name FROM sqlite_master WHERE type='table'";
    if (sqlite3_prepare_v2(db, tSql, -1, &tStmt, NULL) == SQLITE_OK) {
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

        NSMutableArray<NSString *> *hideCols = [NSMutableArray new];
        NSString *idCol = nil;
        NSString *nameCol = nil;
        NSString *msgCol = nil;

        while (sqlite3_step(cStmt) == SQLITE_ROW) {
            NSString *col = ZXColumnText(cStmt, 1);
            NSString *lc = col.lowercaseString;
            if ([lc containsString:@"hidden"] || [lc containsString:@"hide"] || [lc isEqualToString:@"is_pin"] || [lc isEqualToString:@"pin_chat"]) {
                [hideCols addObject:col];
            }
            if (!idCol && ([lc isEqualToString:@"threadid"] || [lc isEqualToString:@"thread_id"] ||
                           [lc isEqualToString:@"conversationid"] || [lc isEqualToString:@"conversation_id"] ||
                           [lc isEqualToString:@"userid"] || [lc isEqualToString:@"user_id"] ||
                           [lc isEqualToString:@"uid"] || [lc isEqualToString:@"id"] || [lc isEqualToString:@"chatid"])) {
                idCol = col;
            }
            if (!nameCol && ([lc containsString:@"displayname"] || [lc containsString:@"threadname"] ||
                             [lc isEqualToString:@"name"] || [lc isEqualToString:@"title"] ||
                             [lc containsString:@"username"] || [lc containsString:@"contactname"])) {
                nameCol = col;
            }
            if (!msgCol && ([lc containsString:@"lastmsg"] || [lc containsString:@"lastmessage"] ||
                            [lc containsString:@"snippet"] || [lc isEqualToString:@"content"] ||
                            [lc isEqualToString:@"message"] || [lc isEqualToString:@"summary"])) {
                msgCol = col;
            }
        }
        sqlite3_finalize(cStmt);

        BOOL tableLooksHidden = ([table.lowercaseString containsString:@"hidden"] || [table.lowercaseString containsString:@"hidechat"]);
        if (hideCols.count == 0 && !tableLooksHidden) continue;

        NSMutableString *whereClause = [NSMutableString new];
        if (hideCols.count > 0) {
            NSMutableArray *conds = [NSMutableArray new];
            for (NSString *hc in hideCols) {
                [conds addObject:[NSString stringWithFormat:@"(\"?\" IS NOT NULL)", hc]];
                [conds removeLastObject];
                [conds addObject:[NSString stringWithFormat:@"(\"%@\" > 0 AND \"%@\" != '0' AND \"%@\" != '')", hc, hc, hc]];
            }
            [whereClause appendFormat:@" WHERE %@", [conds componentsJoinedByString:@" OR "]];
        }

        NSString *selId = idCol ? [NSString stringWithFormat:@"\"%@\"", idCol] : @"rowid";
        NSString *selName = nameCol ? [NSString stringWithFormat:@"\"%@\"", nameCol] : @"''";
        NSString *selMsg = msgCol ? [NSString stringWithFormat:@"\"%@\"", msgCol] : @"''";
        NSString *query = [NSString stringWithFormat:@"SELECT %@, %@, %@ FROM \"%@\"%@ LIMIT 200",
                           selId, selName, selMsg, table, whereClause];

        sqlite3_stmt *qStmt = NULL;
        if (sqlite3_prepare_v2(db, query.UTF8String, -1, &qStmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(qStmt) == SQLITE_ROW) {
                NSString *uid = ZXColumnText(qStmt, 0);
                NSString *name = ZXColumnText(qStmt, 1);
                NSString *msg = ZXColumnText(qStmt, 2);
                if (uid.length == 0 && name.length == 0) continue;
                if (uid.length == 0) uid = name;
                if (name.length == 0) name = [NSString stringWithFormat:@"Hội thoại ẩn #%@", uid];
                if (msg.length == 0) msg = [NSString stringWithFormat:@"(Tìm thấy trong %@ • %@)", dbPath.lastPathComponent, table];
                results[uid] = @{
                    @"uid": uid,
                    @"name": name,
                    @"lastMessage": msg,
                    @"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970])
                };
            }
        }
        if (qStmt) sqlite3_finalize(qStmt);
    }

    sqlite3_close(db);
}

@implementation ZXScanner

+ (NSString *)scanPath
{
    return [[ZXConfig dataDir] stringByAppendingPathComponent:@"scan.txt"];
}

+ (NSArray<NSDictionary *> *)scanSQLiteForHiddenChats
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

    NSMutableDictionary<NSString *, NSDictionary *> *found = [NSMutableDictionary new];
    for (NSString *path in dbPaths) {
        ZXScanSingleDatabase(path, found);
    }
    ZXLog(@"SQLite hidden chat scan inspected %lu DBs, found %lu hidden chats",
          (unsigned long)dbPaths.count, (unsigned long)found.count);
    return found.allValues ?: @[];
}

+ (NSString *)runScan
{
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

    {
        NSArray<NSString *> *menuClasses = @[@"contextmenu", @"zcamenu", @"messagemenu", @"chatmenu", @"menuitem", @"longpressmenu"];
        NSArray<NSString *> *skipClasses = @[@"tracking", @"inbox", @"zds", @"lottie"];
        [out appendString:@"# ---- menu classes (full dump) ----\n"];
        NSUInteger menuLines = 0;
        for (unsigned i = 0; i < count && menuLines < 900; i++) {
            Class c = classes[i];
            const char *image = class_getImageName(c);
            if (!image || strncmp(image, appPath.UTF8String, appPath.length) != 0) continue;
            NSString *cname = NSStringFromClass(c);
            NSString *lc = cname.lowercaseString;
            BOOL isMenu = NO, skip = NO;
            for (NSString *m in menuClasses) if ([lc containsString:m]) { isMenu = YES; break; }
            for (NSString *k in skipClasses) if ([lc containsString:k]) { skip = YES; break; }
            if (!isMenu || skip) continue;
            for (int meta = 0; meta < 2; meta++) {
                Class k = meta ? object_getClass(c) : c;
                unsigned mc = 0;
                Method *ms = class_copyMethodList(k, &mc);
                for (unsigned j = 0; j < mc; j++) {
                    NSString *sel = NSStringFromSelector(method_getName(ms[j]));
                    if ([sel hasPrefix:@".cxx"] || [sel.lowercaseString containsString:@"tracking"]) continue;
                    char *ret = method_copyReturnType(ms[j]);
                    NSMutableString *args = [NSMutableString new];
                    for (unsigned a = 2; a < method_getNumberOfArguments(ms[j]); a++) {
                        char *t = method_copyArgumentType(ms[j], a);
                        [args appendFormat:@"%s ", t ?: "?"];
                        free(t);
                    }
                    [out appendFormat:@"%c[%@ %@] ret=%s args=%@\n", meta ? '+' : '-', cname, sel, ret ?: "?", args];
                    free(ret);
                    menuLines++;
                }
                free(ms);
            }
        }
        [out appendString:@"# ---- keyword matches ----\n"];
    }

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
                    free(t);
                }
                [out appendFormat:@"%c[%@ %@] ret=%s args=%@| %@\n", meta ? '+' : '-', cname, sel, ret ?: "?", args, imageName];
                free(ret);
                lines++;
            }
            free(ms);
        }
    }
    free(classes);
    [out writeToFile:[self scanPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ZXLog(@"scan done: %lu matches", (unsigned long)lines);
    return [self scanPath];
}

@end
