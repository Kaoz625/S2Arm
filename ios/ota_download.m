// OTA 资源包下载（无线装机）：容器 App 从私有 HTTPS 地址把一款游戏的资源包下到 Documents/games/<游戏号>/资源包，不用数据线。
//   服务端：tools/ota_pack.py export 出的目录（ota.json + tars/ + img/ + index.tsv + manifest.json，见 docs/OTA_DOWNLOAD.md）；
//   哪款在哪：下载目录 JSON（地址在 NSUserDefaults S2AOtaCatalogURL：设置 App 里填，或 s2arm://download?catalog=<url> 打开时记下）。
//   落点同推送契约（tools/push_pack.py 文件头）：tar → 资源包/.incoming/<名>.tar，直写镜像 → 资源包/<路径>（写前把 .applied 清空），index.tsv、manifest.json 最后；
//     每个文件先下到 games/<游戏号>/.ota/<序号>.part（分段 Range 续传），sha256 核对过才改名到落点——闸门永远看不到半截文件（pack_apply.c s2a_import_transferring）。
//   不解包：下完点 Play，现有的导入闸门（s2a_import_gate）照推送的口径解开、核对、写 .applied。
//   会话：后台会话（App 进后台 / 被系统挂起时系统接着下，下完一段唤醒 App 接下一段）；每段 ≤ 256 MB，断了从 .part 现有长度接着要（Range）。
//   下载期间关自动锁屏（s2a_ios_keep_awake）；开始前核剩余空间 ≥ 待下量 + 2 GB。认证头只来自下载目录 / 打开地址里的 key，不写死在代码里。
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import "notice.h"
#import "ota_download.h"
#import "ota_place.h"   // 落点 / 核对 ota.json / sha256：与随包资源包共用
#import "s2a_l10n.h"
#include "native.h"
#include "s2a_docs.h"

void s2a_ios_keep_awake(int on);   // app.m
int s2a_game_on_device(const char *proc_docs, const char *gid);   // pack_apply.c

static NSString *const kCatURL = @"S2AOtaCatalogURL", *const kCatKey = @"S2AOtaCatalogKey";
static const long long kChunk = 256ll << 20, kSpare = 2ll << 30;
static const int kMaxTries = 6;

// ---- 小工具 ----
static NSURL *support_dir(void) {   // Library/Application Support/S2ArmOTA：目录缓存与任务状态（不进「文件」App 可见的 Documents：里面可能有认证头）
    NSURL *u = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"S2ArmOTA" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
    return u;
}
static NSString *proc_docs(void) { char d[1024]; s2a_container_docs(d, sizeof d); return @(d); }
static NSString *game_docs(NSString *gid) { return [[proc_docs() stringByAppendingPathComponent:@"games"] stringByAppendingPathComponent:gid]; }
static BOOL valid_gid(NSString *g) { return [g isKindOfClass:NSString.class] && [g rangeOfString:@"^[0-9A-Fa-f]{16}$" options:NSRegularExpressionSearch].location != NSNotFound; }
static NSString *fmt_bytes(long long b) { return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile]; }
static long long file_size(NSString *p) { NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil]; return a ? (long long)a.fileSize : -1; }
static NSURL *join_url(NSURL *base, NSString *rel) {   // base 以 / 结尾；rel 已过 s2a_ota_check 的安全相对路径核对；结果必须同主机（认证头只发给目录给的主机）
    NSString *enc = [rel stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *u = [NSURL URLWithString:enc relativeToURL:base].absoluteURL;
    return u && [u.scheme isEqualToString:@"https"] && [u.host isEqualToString:base.host] ? u : nil;
}
static NSDictionary *read_json(NSURL *u) { NSData *d = [NSData dataWithContentsOfURL:u]; id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil; return [j isKindOfClass:NSDictionary.class] ? j : nil; }
static void write_json(NSURL *u, NSDictionary *j) { NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil]; [d writeToURL:u atomically:YES]; }

static UIViewController *top_vc(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.hidden || !w.rootViewController) continue;
            UIViewController *t = w.rootViewController;
            while (t.presentedViewController && !t.presentedViewController.isBeingDismissed) t = t.presentedViewController;
            return t;
        }
    }
    return nil;
}
static void alert(NSString *title, NSString *body) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:body preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"ota.button.ok") style:UIAlertActionStyleDefault handler:nil]];
    [top_vc() presentViewController:a animated:YES completion:nil];
}

// ---- 下载目录（catalog）----
//   {"version":1,"headers":{"X-Blazing-Key":"…"},"games":[{"id":"<游戏号>","name":"…","base":"https://…/<游戏号>/","headers":{…}}]}
//   games 也可写成 {"<游戏号>":{…}}；base 可相对目录地址；没有 headers 时用打开地址给的 key（X-Blazing-Key）。只认 https
static NSDictionary *g_cat;   // 主线程：游戏号（大写）→ {name, base(NSURL), headers}
static BOOL g_cat_loading;
static NSDictionary *cat_parse(NSDictionary *j, NSURL *from) {
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:kCatKey];
    NSDictionary *h0 = [j[@"headers"] isKindOfClass:NSDictionary.class] ? j[@"headers"] : key.length ? @{@"X-Blazing-Key": key} : @{};
    id gs = j[@"games"]; NSMutableArray *list = [NSMutableArray array];
    if ([gs isKindOfClass:NSArray.class]) [list addObjectsFromArray:gs];
    else if ([gs isKindOfClass:NSDictionary.class]) for (NSString *k in gs) if ([gs[k] isKindOfClass:NSDictionary.class]) { NSMutableDictionary *e = [gs[k] mutableCopy]; e[@"id"] = k; [list addObject:e]; }
    for (NSDictionary *e in list) {
        if (![e isKindOfClass:NSDictionary.class] || !valid_gid(e[@"id"])) continue;
        NSString *b = [e[@"base"] isKindOfClass:NSString.class] ? e[@"base"] : [e[@"url"] isKindOfClass:NSString.class] ? e[@"url"] : nil; if (!b.length) continue;
        if (![b hasSuffix:@"/"]) b = [b stringByAppendingString:@"/"];
        NSURL *base = [NSURL URLWithString:b relativeToURL:from].absoluteURL;
        if (![base.scheme isEqualToString:@"https"] || !base.host.length) { LOG("OTA：下载目录里 %s 的地址不是 https，跳过", [e[@"id"] UTF8String]); continue; }
        NSMutableDictionary *h = [h0 mutableCopy]; if ([e[@"headers"] isKindOfClass:NSDictionary.class]) [h addEntriesFromDictionary:e[@"headers"]];
        for (id k in h.allKeys) if (![k isKindOfClass:NSString.class] || ![h[k] isKindOfClass:NSString.class]) [h removeObjectForKey:k];
        out[[e[@"id"] uppercaseString]] = @{@"name": [e[@"name"] isKindOfClass:NSString.class] ? e[@"name"] : e[@"id"], @"base": base, @"headers": h};
    }
    return out;
}
static NSURL *cat_url(void) {
    NSString *s = [[NSUserDefaults.standardUserDefaults stringForKey:kCatURL] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *u = s.length ? [NSURL URLWithString:s] : nil; return [u.scheme isEqualToString:@"https"] ? u : nil;
}
static void cat_load_cache(void) {
    if (g_cat || !cat_url()) return;
    g_cat = cat_parse(read_json([support_dir() URLByAppendingPathComponent:@"catalog.json"]), cat_url());
}
static NSURLSession *plain_session(void) {
    static NSURLSession *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration; c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 30; s = [NSURLSession sessionWithConfiguration:c]; });
    return s;
}
static void get_json(NSURL *u, NSDictionary *headers, void (^done)(NSDictionary *j, NSString *why)) {   // done 在主线程
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u]; [headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { (void)stop; [r setValue:v forHTTPHeaderField:k]; }];
    [[plain_session() dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id j = d && st == 200 ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *why = e ? e.localizedDescription : st != 200 ? [NSString stringWithFormat:@"HTTP %ld", (long)st] : ![j isKindOfClass:NSDictionary.class] ? @"not a JSON object" : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(why ? nil : j, why); });
    }] resume];
}
static void cat_fetch(void (^done)(BOOL ok)) {   // 主线程
    NSURL *u = cat_url(); if (!u) { if (done) done(NO); return; }
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:kCatKey];
    g_cat_loading = YES;
    get_json(u, key.length ? @{@"X-Blazing-Key": key} : @{}, ^(NSDictionary *j, NSString *why) {
        g_cat_loading = NO;
        if (j) { g_cat = cat_parse(j, u); write_json([support_dir() URLByAppendingPathComponent:@"catalog.json"], j); LOG("OTA：下载目录取到 %lu 款", (unsigned long)g_cat.count); }
        else LOG("OTA：下载目录取不到（%s），用缓存", why.UTF8String);
        if (done) done(j != nil);
    });
}

// ---- 进度页（notice.m 同一套样子，盖在游戏库上）----
@interface S2AOtaPage : UIViewController
@property(copy) NSArray *args;   // @[符号, 标题, 正文, 进度, 小字, 按钮块数组 @[@[标题, @(主), block]…]]
@end
@implementation S2AOtaPage { UIView *_page; }
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor; [self render]; }
- (void)render {
    if (!self.isViewLoaded || !self.args) return;
    [_page removeFromSuperview];
    NSMutableArray *bs = [NSMutableArray array];
    for (NSArray *b in self.args[5]) { void (^blk)(void) = b[2]; [bs addObject:s2a_notice_button(b[0], [b[1] boolValue], ^(UIButton *x) { (void)x; blk(); })]; }
    _page = s2a_notice_page(self.view.bounds, self.args[0], self.args[1], self.args[2], [self.args[3] floatValue], [self.args[4] length] ? self.args[4] : nil, bs);
    [self.view addSubview:_page];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
static S2AOtaPage *g_page;
static void page_show(NSString *sym, NSString *title, NSString *body, float progress, NSString *caption, NSArray *buttons) {   // 主线程
    NSArray *a = @[sym, title, body, @(progress), caption ?: @"", buttons ?: @[]];
    if (g_page && g_page.presentingViewController) { g_page.args = a; [g_page render]; return; }
    g_page = [S2AOtaPage new]; g_page.args = a; g_page.modalPresentationStyle = UIModalPresentationOverFullScreen;
    UIViewController *t = top_vc(); if (!t) { LOG("【红】OTA：没有窗口，进度页画不出来"); return; }
    [t presentViewController:g_page animated:YES completion:nil];
}
static void page_hide(void) { [g_page.presentingViewController dismissViewControllerAnimated:YES completion:nil]; g_page = nil; }
static NSArray *btn(NSString *title, BOOL primary, void (^b)(void)) { return @[title, @(primary), [b copy]]; }

// ---- 下载任务 ----
//   状态（Application Support/S2ArmOTA/job.json）：{gid, base, headers, ota, next, cleared}；next = 下一个没落地的文件序号（ota.files 按 order 排）
@interface S2AOtaJob : NSObject <NSURLSessionDownloadDelegate>
@end
static S2AOtaJob *g_job_obj;
static NSURLSession *g_bg;
static NSOperationQueue *g_q;   // 任务状态只在这条串行队列上改
static NSMutableDictionary *g_job;   // g_q 上
static long long g_inflight; static int g_tries; static BOOL g_pausing, g_running, g_chunk_ok; static NSString *g_chunk_err;
static CFAbsoluteTime g_last_ui;
static BOOL g_quiet;   // 主线程：玩家点了「收起」，下载中不再弹进度页（结束 / 失败 / 暂停照弹）
static void (^g_bg_done)(void);
static NSString *session_id(void) { return [NSBundle.mainBundle.bundleIdentifier ?: @"dev.s2arm" stringByAppendingString:@".ota"]; }
static NSURL *job_url(void) { return [support_dir() URLByAppendingPathComponent:@"job.json"]; }
static void job_save(void) { if (g_job) write_json(job_url(), g_job); else [NSFileManager.defaultManager removeItemAtURL:job_url() error:nil]; }
static NSArray *job_files(void) { return g_job[@"ota"][@"files"]; }
static NSString *part_dir(void) { return [game_docs(g_job[@"gid"]) stringByAppendingPathComponent:@".ota"]; }
static NSString *part_path(NSUInteger i) { return [part_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.part", (unsigned long)i]]; }
static NSString *const kPackDir = @"资源包";   // 设备侧资源包目录名（推送契约 / pack_apply.c 同名），不是显示文字
static NSString *pack_root(void) { return [game_docs(g_job[@"gid"]) stringByAppendingPathComponent:kPackDir]; }
static void ensure_session(void) {
    if (g_bg) return;
    g_q = [NSOperationQueue new]; g_q.maxConcurrentOperationCount = 1; g_q.name = @"s2a.ota";
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:session_id()];
    c.sessionSendsLaunchEvents = YES; c.discretionary = NO; c.allowsCellularAccess = YES; c.timeoutIntervalForResource = 24 * 3600;
    g_job_obj = [S2AOtaJob new]; g_bg = [NSURLSession sessionWithConfiguration:c delegate:g_job_obj delegateQueue:g_q];
}

static void ui_paused(NSString *gid) {   // 任意线程
    dispatch_async(dispatch_get_main_queue(), ^{ g_quiet = NO; page_show(@"pause.circle.fill", S2AL(@"ota.title.paused"), S2AL(@"ota.body.paused"), -1, nil, @[
        btn(S2AL(@"ota.button.resume"), YES, ^{ s2a_ota_start(gid); }), btn(S2AL(@"ota.button.close"), NO, ^{ page_hide(); })]); });
}
static void job_pause(void) {   // 主线程点「暂停」：取消在下的段（.part 与 job.json 留着），回调里显示已暂停；没有在下的段就当场显示
    [g_q addOperationWithBlock:^{
        if (!g_job) return;
        g_pausing = YES; NSString *gid = g_job[@"gid"];
        [g_bg getTasksWithCompletionHandler:^(NSArray *d, NSArray *u, NSArray *dl) { (void)d; (void)u;
            for (NSURLSessionTask *t in dl) [t cancel];
            if (!dl.count) [g_q addOperationWithBlock:^{ g_running = NO; s2a_ios_keep_awake(0); ui_paused(gid); }]; }];
    }];
}
static void ui_progress(BOOL force) {   // g_q 上调
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); if (!force && now - g_last_ui < 0.5) return; g_last_ui = now;
    NSArray *fs = job_files(); NSUInteger next = [g_job[@"next"] unsignedIntegerValue]; long long total = 0, done = 0;
    for (NSUInteger i = 0; i < fs.count; i++) { long long s = [fs[i][@"size"] longLongValue]; total += s; if (i < next) done += s; }
    if (next < fs.count) done += MAX(file_size(part_path(next)), 0) + g_inflight;
    NSString *cap = [NSString stringWithFormat:S2AL(@"ota.caption"), fmt_bytes(done), fmt_bytes(total), (int)MIN(next + 1, fs.count), (int)fs.count];
    float p = total > 0 ? (float)((double)done / (double)total) : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_quiet) return;
        page_show(@"arrow.down.circle.fill", S2AL(@"ota.title.downloading"), S2AL(@"ota.body.downloading"), p, cap, @[
            btn(S2AL(@"ota.button.pause"), NO, ^{ job_pause(); }), btn(S2AL(@"ota.button.hide"), YES, ^{ g_quiet = YES; page_hide(); })]);
    });
}
static void job_fail(NSString *why) {   // g_q 上：保留 .part 与 job.json，「再试一次」从断点接着
    LOG("【红】OTA：%s 下载失败：%s", [g_job[@"gid"] UTF8String], why.UTF8String);
    g_running = NO; s2a_ios_keep_awake(0); NSString *gid = g_job[@"gid"];
    dispatch_async(dispatch_get_main_queue(), ^{ g_quiet = NO; page_show(@"exclamationmark.triangle.fill", S2AL(@"ota.title.failed"), S2AL(@"ota.body.failed"), -1, nil, @[
        btn(S2AL(@"ota.button.retry"), YES, ^{ s2a_ota_start(gid); }), btn(S2AL(@"ota.button.close"), NO, ^{ page_hide(); })]); });
}
static void job_step(void);
static void job_finish(void) {   // g_q 上：全部落地（manifest.json 最后），交给导入闸门
    NSString *gid = g_job[@"gid"];
    [NSFileManager.defaultManager removeItemAtPath:part_dir() error:nil];
    LOG("OTA：%s 下载完成（%lu 个文件），点 Play 时导入闸门解开", gid.UTF8String, (unsigned long)job_files().count);
    g_job = nil; job_save(); g_running = NO; s2a_ios_keep_awake(0);
    dispatch_async(dispatch_get_main_queue(), ^{ s2a_ota_library_refresh(); g_quiet = NO;
        page_show(@"checkmark.circle.fill", S2AL(@"ota.title.done"), S2AL(@"ota.body.done"), -1, nil, @[btn(S2AL(@"ota.button.ok"), YES, ^{ page_hide(); })]); });
}
// 当前文件 .part 已够长：核 sha256 → 改名到落点 → 下一个
static void job_land(NSUInteger i) {
    NSDictionary *f = job_files()[i]; NSString *pp = part_path(i); NSFileManager *fm = NSFileManager.defaultManager;
    NSString *got = s2a_ota_sha256(pp);
    if (![got isEqualToString:[f[@"sha256"] lowercaseString]]) {
        [fm removeItemAtPath:pp error:nil];
        LOG("【红】OTA：%s sha256 不对（%s），删掉重下", [f[@"name"] UTF8String], got.UTF8String ?: "读不了");
        if (++g_tries >= 3) { job_fail(@"sha256 mismatch 3 times"); return; }
        job_step(); return;
    }
    // 直写镜像（不是 tar、不是清单）落地前把 .applied 清空：同 push_pack.send，镜像写到一半时库里不能判成就绪（pack_apply.c s2a_game_on_device）
    NSString *d = f[@"dest"], *root = pack_root();
    if (s2a_ota_is_direct(d) && ![g_job[@"cleared"] boolValue]) { s2a_ota_clear_applied(root); g_job[@"cleared"] = @YES; }
    NSString *why = s2a_ota_place_file(pp, root, d, [f[@"size"] longLongValue], NO, nil, NULL);   // 同卷改名（ota_place.m，与随包资源包同一条落点）
    if (why) { job_fail([NSString stringWithFormat:@"placing %@ failed: %@", d, why]); return; }
    g_job[@"next"] = @(i + 1); g_tries = 0; job_save();
    LOG("OTA：落地 %s（%lld 字节，%lu/%lu）", d.UTF8String, [f[@"size"] longLongValue], (unsigned long)i + 1, (unsigned long)job_files().count);
    job_step();
}
static void job_step(void) {   // g_q 上：下一个文件 / 下一段
    if (!g_job || g_pausing) return;
    NSArray *fs = job_files(); NSUInteger i = [g_job[@"next"] unsignedIntegerValue];
    if (i >= fs.count) { job_finish(); return; }
    NSDictionary *f = fs[i]; long long size = [f[@"size"] longLongValue], have = MAX(file_size(part_path(i)), 0);
    [NSFileManager.defaultManager createDirectoryAtPath:part_dir() withIntermediateDirectories:YES attributes:nil error:nil];
    if (have > size) { [NSFileManager.defaultManager removeItemAtPath:part_path(i) error:nil]; have = 0; }
    if (have == size) { if (!size) [[NSData data] writeToFile:part_path(i) atomically:YES]; job_land(i); return; }
    NSURL *u = join_url([NSURL URLWithString:g_job[@"base"]], f[@"name"]); if (!u) { job_fail(@"bad file URL"); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    [g_job[@"headers"] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { (void)stop; [r setValue:v forHTTPHeaderField:k]; }];
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", have, MIN(have + kChunk, size) - 1] forHTTPHeaderField:@"Range"];
    g_inflight = 0; g_chunk_ok = NO; g_chunk_err = nil;
    [[g_bg downloadTaskWithRequest:r] resume];
    ui_progress(YES);
}

@implementation S2AOtaJob
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)w totalBytesWritten:(int64_t)tw totalBytesExpectedToWrite:(int64_t)te {
    (void)s; (void)t; (void)w; (void)te; g_inflight = tw; if (g_job) ui_progress(NO);
}
// 一段下完（系统删临时文件前，必须在这里同步收走）：206 且起点 = .part 现长 → 接到尾上；200 = 服务端不认 Range、给了整份 → 长度对就整份换掉
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)loc {
    (void)s; g_inflight = 0; g_chunk_ok = NO;
    if (!g_job) { g_chunk_err = @"no job"; return; }
    NSUInteger i = [g_job[@"next"] unsignedIntegerValue]; if (i >= job_files().count) { g_chunk_err = @"no pending file"; return; }
    NSHTTPURLResponse *h = [t.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)t.response : nil; NSString *pp = part_path(i); long long have = MAX(file_size(pp), 0), size = [job_files()[i][@"size"] longLongValue];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (h.statusCode == 206) {
        long long a = -1; NSString *cr = [h valueForHTTPHeaderField:@"Content-Range"];
        if (cr) sscanf(cr.UTF8String, "bytes %lld-", &a);
        if (a != have) { g_chunk_err = [NSString stringWithFormat:@"Content-Range start %lld != have %lld", a, have]; return; }
        if (!have) { [fm removeItemAtPath:pp error:nil]; g_chunk_ok = [fm moveItemAtURL:loc toURL:[NSURL fileURLWithPath:pp] error:nil]; if (!g_chunk_ok) g_chunk_err = @"saving chunk failed"; return; }
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:pp]; NSFileHandle *in = [NSFileHandle fileHandleForReadingFromURL:loc error:nil];
        if (!out || !in) { g_chunk_err = @"cannot open chunk files"; return; }
        NSError *e = nil; [out seekToEndReturningOffset:nil error:&e];
        for (NSData *d; !e && (d = [in readDataUpToLength:8 << 20 error:&e]) && d.length; ) [out writeData:d error:&e];
        if (e) [out truncateAtOffset:(unsigned long long)have error:nil];   // 接到一半失败：退回原长，下次从同一起点要
        [out closeAndReturnError:nil]; [in closeAndReturnError:nil];
        if (e) { g_chunk_err = [NSString stringWithFormat:@"appending chunk failed: %@", e.localizedDescription]; return; }
        g_chunk_ok = YES; return;
    }
    if (h.statusCode == 200) {
        long long n = file_size(loc.path);
        if (n != size) { g_chunk_err = [NSString stringWithFormat:@"full body length %lld != %lld", n, size]; return; }
        [fm removeItemAtPath:pp error:nil]; g_chunk_ok = [fm moveItemAtURL:loc toURL:[NSURL fileURLWithPath:pp] error:nil]; if (!g_chunk_ok) g_chunk_err = @"saving full body failed"; return;
    }
    g_chunk_err = [NSString stringWithFormat:@"HTTP %ld", (long)h.statusCode];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)err {
    (void)s; (void)t;
    if (!g_job) return;
    if (g_pausing) { g_running = NO; s2a_ios_keep_awake(0); LOG("OTA：已暂停（已下的段留着）"); ui_paused(g_job[@"gid"]); return; }
    if (!err && g_chunk_ok) { g_tries = 0; job_step(); return; }
    NSString *why = err ? err.localizedDescription : g_chunk_err ?: @"unknown";
    NSInteger st = [t.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)t.response).statusCode : 0;
    if (st == 401 || st == 403 || st == 404) { job_fail([NSString stringWithFormat:@"HTTP %ld", (long)st]); return; }   // 认证 / 地址不对：重试没用
    if (++g_tries >= kMaxTries) { job_fail(why); return; }
    double wait = MIN(60, 2 << g_tries); LOG("OTA：这段没下成（%s），%.0f 秒后第 %d 次重试", why.UTF8String, wait, g_tries);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [g_q addOperationWithBlock:^{ job_step(); }]; });
}
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)s {
    (void)s; dispatch_async(dispatch_get_main_queue(), ^{ void (^c)(void) = g_bg_done; g_bg_done = nil; if (c) c(); });
}
@end

// ---- 开始 / 接着 ----
static void start_with(NSString *gid, NSDictionary *entry) {   // 主线程：取 ota.json → 核 → 核空间 → 开下
    page_show(@"arrow.down.circle.fill", S2AL(@"ota.title.preparing"), S2AL(@"ota.body.preparing"), -1, nil, @[btn(S2AL(@"ota.button.close"), NO, ^{ page_hide(); })]);
    NSURL *base = entry[@"base"]; NSDictionary *hd = entry[@"headers"];
    get_json(join_url(base, @"ota.json") ?: base, hd, ^(NSDictionary *o, NSString *why) {
        NSString *bad = o ? s2a_ota_check(o, gid) : why;
        if (bad) { LOG("【红】OTA：%s 的 ota.json 不能用：%s", gid.UTF8String, bad.UTF8String);
            page_show(@"exclamationmark.triangle.fill", S2AL(@"ota.title.failed"), S2AL(@"ota.body.failed"), -1, nil, @[btn(S2AL(@"ota.button.retry"), YES, ^{ s2a_ota_start(gid); }), btn(S2AL(@"ota.button.close"), NO, ^{ page_hide(); })]); return; }
        ensure_session();
        [g_q addOperationWithBlock:^{
            NSDictionary *old = g_job ?: read_json(job_url());
            BOOL same = [old[@"gid"] isEqual:gid] && [old[@"ota"][@"index_sha256"] isEqual:o[@"index_sha256"]] && [old[@"ota"][@"files"] isEqual:o[@"files"]];
            if (!same && old[@"gid"]) [NSFileManager.defaultManager removeItemAtPath:[game_docs(old[@"gid"]) stringByAppendingPathComponent:@".ota"] error:nil];
            g_job = same ? [old mutableCopy] : [@{@"gid": gid, @"next": @0, @"cleared": @NO} mutableCopy];
            g_job[@"base"] = base.absoluteString; g_job[@"headers"] = hd; g_job[@"ota"] = o;
            // 剩余空间：待下量（减去已落地的、已下的段）+ 2 GB；读不到照下
            NSArray *fs = job_files(); NSUInteger nx = [g_job[@"next"] unsignedIntegerValue]; long long need = 0;
            for (NSUInteger i = nx; i < fs.count; i++) need += [fs[i][@"size"] longLongValue];
            if (nx < fs.count) need -= MAX(file_size(part_path(nx)), 0);
            NSNumber *free = nil; [[NSURL fileURLWithPath:proc_docs()] getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
            if (free && free.longLongValue < need + kSpare) {
                LOG("【红】OTA：%s 空间不够：可用 %lld < 要 %lld（待下 + 2 GB）", gid.UTF8String, free.longLongValue, need + kSpare);
                NSString *body = [NSString stringWithFormat:S2AL(@"ota.body.nospace"), fmt_bytes(need + kSpare), fmt_bytes(free.longLongValue)];
                g_job = nil;
                dispatch_async(dispatch_get_main_queue(), ^{ page_show(@"externaldrive.fill.badge.exclamationmark", S2AL(@"ota.title.nospace"), body, -1, nil, @[btn(S2AL(@"ota.button.close"), YES, ^{ page_hide(); })]); });
                return;
            }
            job_save(); g_pausing = NO; g_tries = 0; g_running = YES; s2a_ios_keep_awake(1);
            LOG("OTA：开始 %s：%lu 个文件，从第 %lu 个起，待下 %lld 字节", gid.UTF8String, (unsigned long)fs.count, (unsigned long)nx + 1, need);
            job_step();
        }];
    });
}
void s2a_ota_start(NSString *gid) {
    gid = gid.uppercaseString; if (!valid_gid(gid)) return;
    g_quiet = NO;
    if (g_running) { if ([g_job[@"gid"] isEqual:gid]) [g_q addOperationWithBlock:^{ ui_progress(YES); }]; else alert(S2AL(@"ota.title.busy"), S2AL(@"ota.body.busy")); return; }
    void (^go)(BOOL) = ^(BOOL ok) { (void)ok; NSDictionary *e = g_cat[gid];
        if (e) start_with(gid, e); else { if (g_page) page_hide(); alert(S2AL(@"ota.title.noentry"), S2AL(@"ota.body.noentry")); } };
    cat_load_cache(); cat_fetch(go);   // 每次开始都重取一次目录（地址 / 认证头可能换了）；取不到用缓存
}
void s2a_ota_add_download_action(UIAlertController *a, NSString *gid) {
    cat_load_cache();
    if (!cat_url() || (!g_cat[gid.uppercaseString] && g_cat && !g_cat_loading)) return;
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"ota.button.download") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ s2a_ota_start(gid); }); }]];   // 等提示框收完再盖进度页
}
static void pick_game(void) {   // 列出目录里本机还没有的款
    NSMutableArray *miss = [NSMutableArray array];
    for (NSString *gid in [g_cat.allKeys sortedArrayUsingSelector:@selector(compare:)]) if (!s2a_game_on_device(proc_docs().UTF8String, gid.UTF8String)) [miss addObject:gid];
    if (!miss.count) { alert(S2AL(@"ota.title.pick"), S2AL(@"ota.body.pick.none")); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"ota.title.pick") message:S2AL(@"ota.body.pick") preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *gid in miss) [a addAction:[UIAlertAction actionWithTitle:g_cat[gid][@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ s2a_ota_start(gid); }); }]];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"ota.button.close") style:UIAlertActionStyleCancel handler:nil]];
    [top_vc() presentViewController:a animated:YES completion:nil];
}
BOOL s2a_ota_open_url(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:@"s2arm"] || ![url.host.lowercaseString isEqualToString:@"download"]) return NO;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO]; NSString *cat = nil, *key = nil, *game = nil;
    for (NSURLQueryItem *q in c.queryItems) { if ([q.name isEqualToString:@"catalog"]) cat = q.value; else if ([q.name isEqualToString:@"key"]) key = q.value; else if ([q.name isEqualToString:@"game"]) game = q.value; }
    NSURL *cu = cat.length ? [NSURL URLWithString:cat] : nil;
    if (cat.length && ![cu.scheme isEqualToString:@"https"]) { LOG("【红】OTA：打开地址里的下载目录不是 https，不收"); alert(S2AL(@"ota.title.failed"), S2AL(@"ota.body.catalog")); return YES; }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (cu) { [ud setObject:cu.absoluteString forKey:kCatURL]; if (key.length) [ud setObject:key forKey:kCatKey]; else [ud removeObjectForKey:kCatKey]; g_cat = nil; }
    LOG("OTA：打开地址 %s（%s）", cu ? "换了下载目录" : "沿用下载目录", game.length ? "指定了游戏" : "列目录");
    cat_fetch(^(BOOL ok) {
        if (!ok && !g_cat) { alert(S2AL(@"ota.title.failed"), S2AL(@"ota.body.catalog")); return; }
        if (game.length) s2a_ota_start(game); else pick_game();
    });
    return YES;
}
BOOL s2a_ota_background_events(NSString *identifier, void (^completion)(void)) {
    if (![identifier isEqualToString:session_id()]) return NO;
    g_bg_done = completion; ensure_session();   // 重建同名会话，系统把这段的回调交过来
    [g_q addOperationWithBlock:^{ if (!g_job) { NSDictionary *j = read_json(job_url()); if (j) { g_job = [j mutableCopy]; g_running = YES; } } }];
    return YES;
}
void s2a_ota_library_appeared(void) {
    cat_load_cache(); if (cat_url()) cat_fetch(nil);
    if (!read_json(job_url())) return;
    ensure_session();   // 接上系统后台会话里还在跑的段：有就显示进度；没有（被划掉过）等玩家点「下载」接着
    [g_q addOperationWithBlock:^{
        if (!g_job) g_job = [read_json(job_url()) mutableCopy];
        [g_bg getTasksWithCompletionHandler:^(NSArray *d, NSArray *u, NSArray *dl) { (void)d; (void)u;
            [g_q addOperationWithBlock:^{ if (dl.count && g_job) { g_running = YES; s2a_ios_keep_awake(1); LOG("OTA：接上后台在下的 %s", [g_job[@"gid"] UTF8String]); ui_progress(YES); } }]; }];
    }];
}

// ---- 随包资源包（单款游戏 App：包里 Games/<游戏号>/ota/ 带着 tools/ota_pack.py export 的原样输出）----
//   首次打开时把它按下载同一套落点放进 Documents/games/<游戏号>/资源包（ota_place.m：同卷 APFS 克隆，几乎不占空间、几秒放完），之后照常由导入闸门解开。
//   可重入：放到一半被杀，下次打开再放（已放好的跳过）
BOOL s2a_ota_bundled_available(NSString *gid) { return s2a_ota_bundled_dir(NSBundle.mainBundle.bundlePath, gid) != nil; }
void s2a_ota_bundled_install(NSString *gid, void (^done)(BOOL ok)) {
    gid = gid.uppercaseString; NSString *dir = s2a_ota_bundled_dir(NSBundle.mainBundle.bundlePath, gid);
    if (!dir) { done(NO); return; }
    NSString *gd = game_docs(gid), *docs = proc_docs();
    LOG("OTA 随包：%s 的资源包在包里（%s），放进 %s", gid.UTF8String, dir.UTF8String, gd.UTF8String);
    page_show(@"shippingbox.fill", S2AL(@"ota.title.bundled"), S2AL(@"ota.body.bundled"), 0, nil, @[]);
    s2a_ios_keep_awake(1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block CFAbsoluteTime last = 0; BOOL cloned = YES; CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        NSString *why = s2a_ota_place_bundled(dir, gd, gid, ^long long {
            NSNumber *f = nil; [[NSURL fileURLWithPath:docs] getResourceValue:&f forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]; return f ? f.longLongValue : -1;
        }, ^(long long d, long long t, NSUInteger i, NSUInteger n) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); if (now - last < 0.25 && i < n) return; last = now;
            NSString *cap = [NSString stringWithFormat:S2AL(@"ota.caption"), fmt_bytes(d), fmt_bytes(t), (int)MIN(i + 1, n), (int)n];
            float p = t > 0 ? (float)((double)d / (double)t) : 1;
            dispatch_async(dispatch_get_main_queue(), ^{ page_show(@"shippingbox.fill", S2AL(@"ota.title.bundled"), S2AL(@"ota.body.bundled"), p, cap, @[]); });
        }, &cloned);
        double secs = CFAbsoluteTimeGetCurrent() - t0;
        dispatch_async(dispatch_get_main_queue(), ^{
            s2a_ios_keep_awake(0);
            if (!why) {
                LOG("OTA 随包：%s 放好（%.1f 秒，%s），交给导入闸门", gid.UTF8String, secs, cloned ? "全程 APFS 克隆" : "有文件是真拷贝");
                UIViewController *p = g_page.presentingViewController; g_page = nil;
                if (p) [p dismissViewControllerAnimated:NO completion:^{ done(YES); }]; else done(YES);
                return;
            }
            LOG("【红】OTA 随包：%s 放不进去：%s", gid.UTF8String, why.UTF8String);
            BOOL nospace = [why hasPrefix:@"nospace"];
            page_show(nospace ? @"externaldrive.fill.badge.exclamationmark" : @"exclamationmark.triangle.fill",
                      nospace ? S2AL(@"ota.title.nospace") : S2AL(@"ota.title.bundled.failed"), nospace ? S2AL(@"ota.body.bundled.nospace") : S2AL(@"ota.body.bundled.failed"), -1, nil, @[
                btn(S2AL(@"ota.button.retry"), YES, ^{ s2a_ota_bundled_install(gid, done); }),
                btn(S2AL(@"ota.button.close"), NO, ^{ UIViewController *p = g_page.presentingViewController; g_page = nil;
                    if (p) [p dismissViewControllerAnimated:NO completion:^{ done(NO); }]; else done(NO); })]);
        });
    });
}
