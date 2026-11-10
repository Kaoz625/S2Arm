// 首启 IML 复核（D）：App 启动时进程内读自身签名里真实生效的权限，核实「提高内存上限」是否保留。
//   真值：进程自身生效的权限（SecTaskCopyValueForEntitlement(SecTaskCreateFromSelf)，内核按进程签名定档读的就是它）。
//     10-30 LiveContainer 实测：游戏以 dylib 跑在 LC 宿主进程里，权限按宿主签名定档（宿主带 IML → 6144 MB / 64 GB），而游戏可执行文件自己的签名里
//     没有权限槽（codesign 给改写后的 dylib 签权限会悄悄丢）——原先读主程序 Mach-O 签名（imlent.c s2a_ent_has）在 LC 下误报「丢了 IML」。
//     读进程权限失败（API 返回错误）时才退回读主程序签名；描述文件允许 ≠ 签名带上，iOS 沙盒也起不了 codesign / security，不读那两条路。
//   佐证：本次宿主实际拿到的地址上限（vawin.c s2a_va_top）与 2^39 以下最大一块（s2a_window_need 的 fit，构造函数占窗时已量好，这里不重新预留）。
//     带 IML 应是大地址档（上限 63 GiB、最大一块约 51 GiB）；不带约 15–17 GiB / 5.4 GiB（R02 布局_系统版本x权限.tsv）。大地址档 EVA 等权限也给，只作佐证。
//   结果写 Documents/diag/iml_probe.json（Mac 前端「拉回诊断」读 has_iml_ent，见 pack/jobs/diag.py）；丢了打日志一行【红】，游戏照常进（不中止）。
//   调用点：app.m s2a_front_run → s2a_iml_probe_check()（启动后立刻，不等进游戏）。
#import <Foundation/Foundation.h>
#import "s2a_l10n.h"
#include <mach-o/ldsyms.h>
#include "native.h"
#include <CoreFoundation/CoreFoundation.h>
// Security.framework 里有、iOS 公开头没声明（LiveContainer 同用法）。运行时取（UIKit 已把 Security 带进进程）：主程序链接行不另加框架
#include <dlfcn.h>
typedef struct __SecTask *SecTaskRef;
// 进程自身是否带某项权限：1 带、0 不带、-1 读不到（API 出错）
static int proc_ent_has(const char *key) {
    SecTaskRef (*create)(CFAllocatorRef) = (SecTaskRef (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copy)(SecTaskRef, CFStringRef, CFErrorRef *) = (CFTypeRef (*)(SecTaskRef, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return -1;   // 取不到：调用方退回读主程序签名
    SecTaskRef t = create(NULL); if (!t) return -1;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8); CFErrorRef err = NULL;
    CFTypeRef v = copy(t, k, &err);
    int r = err ? -1 : v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    if (v) CFRelease(v); if (err) CFRelease(err); CFRelease(k); CFRelease(t);
    return r;
}

#define IML_KEY "com.apple.developer.kernel.increased-memory-limit"
#define GIB (double)(1ull << 30)

static void _write_result(int ent, uint64_t fit, uint64_t top, int jumbo) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"diag"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *rec = @{
        @"has_iml_ent":  ent < 0 ? NSNull.null : @(ent == 1),   // null = 读不到签名里的权限（不当缺失）
        @"iml_key":      @(IML_KEY),
        @"window_gb":    fit ? @(round(fit / GIB * 10) / 10) : NSNull.null,   // 2^39 以下最大一块
        @"va_top_gb":    top ? @(round(top / GIB * 10) / 10) : NSNull.null,   // 地址上限
        @"va_jumbo":     jumbo < 0 ? NSNull.null : @(jumbo == 1),
        @"bundle_id":    NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"ios":          @((int)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion),
        @"ts":           @((long long)[[NSDate date] timeIntervalSince1970]),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:rec options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[dir stringByAppendingPathComponent:@"iml_probe.json"] atomically:YES];
}

void s2a_iml_probe_check(void) {
    @autoreleasepool {
        int ent = proc_ent_has(IML_KEY), from_proc = ent >= 0;
        if (!from_proc) ent = s2a_ent_has(&_mh_execute_header, IML_KEY);   // 进程权限读不到才退回读主程序签名
        uint64_t need = 0, fit = 0, top = s2a_va_top(); s2a_window_need(&need, &fit);
        int jumbo = s2a_va_jumbo(top);
        _write_result(ent, fit, top, jumbo);
        const char *va = jumbo < 0 ? "地址上限读不到" : jumbo ? "大地址档" : "小地址档";
        if (ent < 0)
            LOG("[IML] 首启复核：读不到自身签名里的权限（无签名段 / 无权限槽），不判；%s，上限 %.1f GB、最大一块 %.1f GB", va, top / GIB, fit / GIB);
        else if (ent)
            LOG("[IML] 首启复核：%s带提高内存上限权限；%s，上限 %.1f GB、最大一块 %.1f GB%s", from_proc ? "进程" : "签名", va, top / GIB, fit / GIB,
                jumbo == 0 ? "【黄】带权限却只拿到小地址档，与 R02 不符" : "");
        else
            LOG("【红】[IML] 首启复核：这台机上装的包签名丢了「提高内存上限」权限（%s）；%s，上限 %.1f GB、最大一块 %.1f GB。"
                "游戏继续运行，超出窗口走远端翻译；请用 Xcode / AltStore Classic v2.3 重签后重装（或 GetMoreRam 给 App ID 补权限后重装）",
                IML_KEY, va, top / GIB, fit / GIB);
        // 玩家也要知道（审计 P2-3：原先只写日志）：同一个包只提示一次，不挡操作（dprompt.m 顶部提示条，起局 3 秒后）
        if (ent == 0) {
            NSUserDefaults *u = NSUserDefaults.standardUserDefaults; NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ABuildID"] ?: @"-";
            if (![[u stringForKey:@"S2AIMLLostNoticeBuild"] isEqualToString:build]) {
                [u setObject:build forKey:@"S2AIMLLostNoticeBuild"];
                void s2a_dprompt_notice(NSString *title, NSString *body, double delay, double seconds);
                s2a_dprompt_notice(S2AL(@"iml.lost.title"), S2AL(@"iml.lost.body"), 3, 15);
            }
        }
    }
}
