// OTA 资源包落点：下载与随包资源包共用（契约见 ota_place.h）。只用 Foundation：Mac 上单测直接编（tests/ota_bundled_test.py）。
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <errno.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>
#import "ota_place.h"
#include "native.h"

int s2a_import_state_game_quick(const char *proc_docs, const char *gid);   // runtime/src/pack_apply.c：0 = 就绪
static NSString *const kPackDir = @"资源包";   // 设备侧资源包目录名（推送契约 / pack_apply.c 同名），不是显示文字
static const long long kSmall = 64ll << 20;    // 这么大以内的随包文件放完核 sha256；更大的只核大小
static const long long kSpare = 2ll << 30;     // 要真拷（克隆不成）时另留的空间：解包 tar 用

static BOOL valid_gid(NSString *g) { return [g isKindOfClass:NSString.class] && [g rangeOfString:@"^[0-9A-Fa-f]{16}$" options:NSRegularExpressionSearch].location != NSNotFound; }
static BOOL safe_rel(id p) {   // 相对路径：非空、不以 / 开头、没有 .. / . 段、没有反斜杠 / 冒号（挡掉绝对地址）
    if (![p isKindOfClass:NSString.class] || ![p length] || [p hasPrefix:@"/"] || [p containsString:@"\\"] || [p containsString:@":"]) return NO;
    for (NSString *c in [p componentsSeparatedByString:@"/"]) if (!c.length || [c isEqualToString:@".."] || [c isEqualToString:@"."]) return NO;
    return YES;
}
static long long file_size(NSString *p) { struct stat st; return stat(p.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) ? -1 : (long long)st.st_size; }

NSString *s2a_ota_check(NSDictionary *o, NSString *gid) {
    if (![o isKindOfClass:NSDictionary.class]) return @"not a JSON object";
    if (![o[@"format"] isEqual:@"s2arm-ota"] || ![o[@"version"] isEqual:@1]) return @"not s2arm-ota v1";
    if (!valid_gid(gid) || ![[o[@"title_id"] description].uppercaseString isEqualToString:gid.uppercaseString]) return @"title id mismatch";
    NSArray *fs = o[@"files"]; if (![fs isKindOfClass:NSArray.class] || fs.count < 2) return @"no files";
    for (NSDictionary *f in fs) {
        if (![f isKindOfClass:NSDictionary.class] || !safe_rel(f[@"name"]) || !safe_rel(f[@"dest"]) || ![f[@"size"] isKindOfClass:NSNumber.class] || [f[@"size"] longLongValue] < 0) return @"bad file entry";
        if (![f[@"sha256"] isKindOfClass:NSString.class] || [f[@"sha256"] rangeOfString:@"^[0-9a-fA-F]{64}$" options:NSRegularExpressionSearch].location == NSNotFound) return @"bad sha256";
        NSString *d = f[@"dest"]; if ([d hasPrefix:@".incoming/"] && (![d hasSuffix:@".tar"] || [d substringFromIndex:10].pathComponents.count != 1)) return @"bad tar dest";
        if ([d hasPrefix:@"."] && ![d hasPrefix:@".incoming/"]) return @"dest is a bookkeeping file";
    }
    if (![[fs[fs.count - 2] objectForKey:@"dest"] isEqual:@"index.tsv"] || ![[fs.lastObject objectForKey:@"dest"] isEqual:@"manifest.json"]) return @"index.tsv / manifest.json not last";
    return nil;
}
BOOL s2a_ota_is_direct(NSString *d) { return ![d hasPrefix:@".incoming/"] && ![d isEqualToString:@"index.tsv"] && ![d isEqualToString:@"manifest.json"]; }
void s2a_ota_clear_applied(NSString *root) {
    NSString *ap = [root stringByAppendingPathComponent:@".applied"];
    if ([NSFileManager.defaultManager fileExistsAtPath:ap]) [[NSData data] writeToFile:ap atomically:YES];
}
NSString *s2a_ota_sha256(NSString *p) {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:p]; [in open]; if (in.streamStatus != NSStreamStatusOpen) return nil;
    CC_SHA256_CTX c; CC_SHA256_Init(&c); NSMutableData *buf = [NSMutableData dataWithLength:4 << 20]; NSInteger n;
    while ((n = [in read:buf.mutableBytes maxLength:buf.length]) > 0) CC_SHA256_Update(&c, buf.bytes, (CC_LONG)n);
    [in close]; if (n < 0) return nil;
    unsigned char md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(md, &c);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}
NSString *s2a_ota_place_file(NSString *src, NSString *root, NSString *dest, long long size, BOOL clone, NSString *tmp_dir, BOOL *cloned) {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *dst = [root stringByAppendingPathComponent:dest]; NSError *e = nil;
    if (cloned) *cloned = NO;
    if (!safe_rel(dest)) return [NSString stringWithFormat:@"unsafe dest %@", dest];
    if (![fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&e]) return [NSString stringWithFormat:@"mkdir for %@: %@", dest, e.localizedDescription];
    NSString *from = src;
    if (clone) {   // 先放到临时名：克隆 / 拷贝中途被杀，落点上不会有半截文件
        if (![fm createDirectoryAtPath:tmp_dir withIntermediateDirectories:YES attributes:nil error:&e]) return [NSString stringWithFormat:@"mkdir %@: %@", tmp_dir, e.localizedDescription];
        NSString *tmp = [tmp_dir stringByAppendingPathComponent:@"placing.tmp"];
        unlink(tmp.fileSystemRepresentation);
        if (!clonefile(src.fileSystemRepresentation, tmp.fileSystemRepresentation, CLONE_NOOWNERCOPY)) { if (cloned) *cloned = YES; }
        else {
            int ce = errno; unlink(tmp.fileSystemRepresentation);
            LOG("OTA 落点：%s 克隆不成（%s），改拷贝", dest.UTF8String, strerror(ce));
            if (copyfile(src.fileSystemRepresentation, tmp.fileSystemRepresentation, NULL, COPYFILE_CLONE | COPYFILE_DATA)) {
                int pe = errno; unlink(tmp.fileSystemRepresentation);
                if (![fm copyItemAtPath:src toPath:tmp error:&e]) return [NSString stringWithFormat:@"copy %@: %s / %@", dest, strerror(pe), e.localizedDescription];
            }
        }
        chmod(tmp.fileSystemRepresentation, 0644);   // 包里的文件是只读的；落点要能被闸门删（tar 解完即删）/ 覆盖
        from = tmp;
    }
    long long got = file_size(from);
    if (size >= 0 && got != size) { if (clone) unlink(from.fileSystemRepresentation); return [NSString stringWithFormat:@"%@ size %lld != %lld", dest, got, size]; }
    if (rename(from.fileSystemRepresentation, dst.fileSystemRepresentation)) {   // 同卷改名：原子换上（落点上的旧文件一并顶掉）
        int re = errno; if (clone) unlink(from.fileSystemRepresentation);
        return [NSString stringWithFormat:@"rename to %@: %s", dest, strerror(re)];
    }
    return nil;
}

NSString *s2a_ota_bundled_dir(NSString *bundle, NSString *gid) {
    if (!bundle.length || !valid_gid(gid)) return nil;
    NSString *d = [[[bundle stringByAppendingPathComponent:@"Games"] stringByAppendingPathComponent:gid.uppercaseString] stringByAppendingPathComponent:@"ota"];
    return file_size([d stringByAppendingPathComponent:@"ota.json"]) > 0 ? d : nil;
}
NSString *s2a_ota_place_bundled(NSString *ota_dir, NSString *game_docs, NSString *gid, long long (^free_bytes)(void), s2a_ota_place_progress progress, BOOL *cloned_all) {
    if (cloned_all) *cloned_all = YES;
    NSData *jd = [NSData dataWithContentsOfFile:[ota_dir stringByAppendingPathComponent:@"ota.json"]];
    NSDictionary *o = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil] : nil;
    NSString *bad = o ? s2a_ota_check(o, gid) : @"bundled ota.json unreadable"; if (bad) return bad;
    NSArray *fs = [o[@"files"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"order"] compare:b[@"order"]]; }];
    NSString *proc = game_docs.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;   // game_docs = <进程级 Documents>/games/<游戏号>
    if (s2a_import_state_game_quick(proc.fileSystemRepresentation, gid.uppercaseString.UTF8String) == 0) { LOG("OTA 随包：%s 资源包已就绪，不再放", gid.UTF8String); return nil; }
    NSString *root = [game_docs stringByAppendingPathComponent:kPackDir], *tmp = [game_docs stringByAppendingPathComponent:@".ota-bundled"];
    NSFileManager *fm = NSFileManager.defaultManager; NSError *e = nil;
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&e]) return [NSString stringWithFormat:@"mkdir %@: %@", root, e.localizedDescription];
    // 上次放到一半被杀：manifest.json 是最后放的，它在 = 上次放完了（调用方只在库判「不在 / 不完整」时才调）；不完整时先拿掉，免得放到一半的样子被当成「传完了」
    unlink([root stringByAppendingPathComponent:@"manifest.json"].fileSystemRepresentation);
    if ([o[@"clear_applied"] boolValue]) s2a_ota_clear_applied(root);
    long long total = 0, done = 0; for (NSDictionary *f in fs) total += [f[@"size"] longLongValue];
    // 克隆探路：拿 ota.json 试一次 clonefile。包与 Documents 不在同一个 APFS 卷（或系统不让克隆）时后面全是真拷，先核剩余空间，别拷到一半把机器塞满
    BOOL space_checked = NO; NSUInteger placed = 0, skipped = 0;
    {
        [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *probe = [tmp stringByAppendingPathComponent:@"probe.tmp"]; unlink(probe.fileSystemRepresentation);
        BOOL can = !clonefile([ota_dir stringByAppendingPathComponent:@"ota.json"].fileSystemRepresentation, probe.fileSystemRepresentation, CLONE_NOOWNERCOPY);
        int ce = errno; unlink(probe.fileSystemRepresentation);
        if (!can && free_bytes) {
            space_checked = YES; long long fr = free_bytes(), need = kSpare;
            for (NSDictionary *f in fs) if (file_size([root stringByAppendingPathComponent:f[@"dest"]]) != [f[@"size"] longLongValue]) need += [f[@"size"] longLongValue];
            LOG("OTA 随包：克隆不成（%s），按真拷核空间：要 %lld，可用 %lld", strerror(ce), need, fr);
            if (fr >= 0 && fr < need) return [NSString stringWithFormat:@"nospace: need %lld, free %lld", need, fr];
        }
    }
    for (NSUInteger i = 0; i < fs.count; i++) {
        NSDictionary *f = fs[i]; NSString *name = f[@"name"], *dest = f[@"dest"], *want = [f[@"sha256"] lowercaseString];
        long long size = [f[@"size"] longLongValue]; NSString *src = [ota_dir stringByAppendingPathComponent:name], *dst = [root stringByAppendingPathComponent:dest];
        if (progress) progress(done, total, i, fs.count);
        if (file_size(src) != size) return [NSString stringWithFormat:@"bundled %@ size %lld != %lld", name, file_size(src), size];
        BOOL small = size <= kSmall;
        if (file_size(dst) == size && (!small || [s2a_ota_sha256(dst) isEqualToString:want])) { done += size; skipped++; continue; }   // 上次已放好
        BOOL cl = NO; NSString *why = s2a_ota_place_file(src, root, dest, size, YES, tmp, &cl);
        if (why) return why;
        if (!cl) {
            if (cloned_all) *cloned_all = NO;
            if (!space_checked && free_bytes) {   // 第一次落成真拷贝：后面多半也克隆不成，核一次剩余空间（剩下的 + 2 GB 解包）
                space_checked = YES; long long fr = free_bytes(), need = total - done - size + kSpare;
                if (fr >= 0 && fr < need) return [NSString stringWithFormat:@"nospace: need %lld, free %lld", need, fr];
            }
        }
        if (small && ![s2a_ota_sha256(dst) isEqualToString:want]) { unlink(dst.fileSystemRepresentation); return [NSString stringWithFormat:@"%@ sha256 mismatch", name]; }
        done += size; placed++;
        LOG("OTA 随包：落地 %s（%lld 字节，%lu/%lu，%s）", dest.UTF8String, size, (unsigned long)i + 1, (unsigned long)fs.count, cl ? "克隆" : "拷贝");
    }
    // 全部放好（manifest.json 已在）：开头清空的 .applied 拿掉，回到「新装、待解开」的样子。空 .applied 在库判据里是「上次传镜像被打断」
    //   （pack_apply.c s2a_game_on_device），这次是放完了的，留着会让库把这款当成不在机上
    { NSString *ap = [root stringByAppendingPathComponent:@".applied"]; if (file_size(ap) == 0) unlink(ap.fileSystemRepresentation); }
    [fm removeItemAtPath:tmp error:nil];
    if (progress) progress(total, total, fs.count, fs.count);
    LOG("OTA 随包：%s 放好 %lu 个文件、跳过已在的 %lu 个，共 %lld 字节；点开始时导入闸门解开", gid.UTF8String, (unsigned long)placed, (unsigned long)skipped, total);
    return nil;
}
