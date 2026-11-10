// 起局自检（维护者 10-19，docs/研究/免费账号.md）：iOS 带「提高内存上限」权限时，iPhone 17 Pro Max 上有整块 64 GB 窗口 + 约 6144 MB 内存上限；
// 不带时地址顶只到 0x71_8000_0000（最大空洞约 6 GB）、内存上限约 3376 MB——游戏起不来。不过就报红、日志与 App 画面给提示，不起游戏。
// 10-23 E01（PR #81，iPad mini 6，4 GB 物理内存）：权限签了，可用内存仍只有 2865 MB、窗口申请 ENOMEM，旧提示一律说「缺权限」，与事实不符。
//   4500 MB 门槛原本只是「有没有签权限」的分界（6144 与 3376 之间），不是游戏的需求；所以现在先照实读权限、物理内存、地址上限，
//   提示按读到的事实给：真没签才叫重签；签了仍不够就说本机型的系统上限不够。读数一行「自检：…」进 host.log 供健康表读。
#if defined(__ANDROID__)
#include "../../android/native/runtime/platform/selfcheck_android.inc"
#else
#include "native.h"
#include "as_type.h"
#include "s2a_selfcheck_page.h"
#include "s2a_ui_lang.h"   // 上屏话术英文默认（S2A_TR）
#include <TargetConditionals.h>
#include <string.h>
#include <stdio.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#include <mach/mach.h>
#endif
// 默认门槛不变；实验构建可显式给出预算，不改变权限或系统上限。
#ifndef S2A_MEM_NEED_MB
#define S2A_MEM_NEED_MB 4500
#endif
#define MEM_NEED_MB S2A_MEM_NEED_MB
static char g_hint[640] = "安装时缺少『提高内存上限』权限，请用 AltStore / Xcode 个人团队重装或用 GetMoreRam 补开";
const char *s2a_selfcheck_hint(void) { return g_hint; }

// 权限 XML（签名里的 entitlements plist）里 key 是否为 <true/>：1 是、0 不是（没有这个 key 或值不是 true）
int s2a_ent_true(const char *xml, size_t n, const char *key) {
    size_t kl = strlen(key);
    for (size_t i = 0; i + kl + 10 < n; i++) {
        if (memcmp(xml + i, "<key>", 5) || memcmp(xml + i + 5, key, kl) || memcmp(xml + i + 5 + kl, "</key>", 6)) continue;
        size_t j = i + 11 + kl;
        while (j < n && (xml[j] == ' ' || xml[j] == '\t' || xml[j] == '\n' || xml[j] == '\r')) j++;
        return j + 7 <= n && !memcmp(xml + j, "<true/>", 7);
    }
    return 0;
}

// 按事实写提示（给玩家看，也进日志）。ent：1 已签、0 未签、-1 读不到；va_top：系统给本进程的地址上限（0 = 读不到）
// 窗口：win_ok = 本款跨度占到；win_mb / need_mb = 本机 2^39 以下最大能放的一块 / 本款跨度（0 = 读不到）；
//   as_type = main.npdm 的地址空间类型（0–7，-1 = 没读到，vawin.c s2a_window_astype）
// 11-05 Minecraft: Story Mode：跨度为 0 不全是包坏了——类型 0 / 2（32 位）是布局暂不支持的地址宽度，与权限、机型无关，先于权限判；
//   类型 1（36 位）与 3（39 位）布局支持（as_type.h s2a_as_type_top），跨度为 0 就是读不到模块段 = 资源不完整
static int as_unsupported(int win_ok, uint64_t need_mb, int as_type) { return !win_ok && !need_mb && as_type >= 0 && as_type <= 2 && !s2a_as_type_top((uint32_t)as_type); }
void s2a_selfcheck_explain(char *out, size_t cap, int win_ok, int mem_ok, int ent, uint64_t avail_mb, uint64_t phys_mb, uint64_t va_top, uint64_t win_mb, uint64_t need_mb, int as_type) {
    if (win_ok && mem_ok) { snprintf(out, cap, "自检通过"); return; }
    if (as_unsupported(win_ok, need_mb, as_type)) { snprintf(out, cap, "本款 NPDM 地址空间类型 %d（%s）暂不支持（布局只支持类型 1 = 36 位、3 = 39 位），重装、补权限或换机型都不能解决", as_type, s2a_as_type_bits((uint32_t)as_type)); return; }
    if (ent == 0) { snprintf(out, cap, "安装时缺少『提高内存上限』权限，请用 AltStore / Xcode 个人团队重装或用 GetMoreRam 补开"); return; }
    char why[384] = ""; size_t k = 0;
    if (!win_ok) {
        // 10-24 维护者：按游戏申请的地址宽度判——本款要的跨度（main.npdm 定）本机给不给得出
        if (need_mb) k += (size_t)snprintf(why + k, sizeof why - k, "本款需要 %llu GB 地址空间，本机最多 %llu GB（系统给本进程的地址上限 %#llx）",
                                           (unsigned long long)((need_mb + 1023) >> 10), (unsigned long long)(win_mb >> 10), (unsigned long long)va_top);
        else k += (size_t)snprintf(why + k, sizeof why - k, "读不到本款的 main.npdm，不知道要多大的地址空间（包不完整）");
    }
    if (!mem_ok && k < sizeof why) k += (size_t)snprintf(why + k, sizeof why - k, "%s系统给本进程的内存上限 %llu MB，起局需要 ≥ %d MB", k ? "；" : "", (unsigned long long)avail_mb, MEM_NEED_MB);
    if (mem_ok) snprintf(out, cap, "%s，%s。重装或补权限不能解决", ent == 1 ? "已签『提高内存上限』权限" : "读不到本进程的权限（按已签处理）", why);
    else snprintf(out, cap, "%s，%s。这是本机型（物理内存 %llu MB）的系统上限，重装或补权限不能解决，本机型目前不支持",
                  ent == 1 ? "已签『提高内存上限』权限" : "读不到本进程的权限（按已签处理）", why, (unsigned long long)phys_mb);
}

// 屏上给玩家的标题与下一步（11-02 维护者：一句人话 + 下一步，地址上限 / main.npdm 这类细节只在上面的 g_hint 里进日志、随诊断包带走）：
//   地址空间类型暂不支持（32 位）→ 照实说不支持；没签权限 → 重装；读不到本款要多大地址（包不完整）→ 重装补资源；签了仍不够 → 本机型系统上限，重装也不行
//   文案宏在 runtime/include/s2a_selfcheck_page.h（登记于 launchers/shared/experience.v1.json selfcheck_page）
void s2a_selfcheck_screen(int win_ok, int mem_ok, int ent, uint64_t need_mb, int as_type, const char **title, const char **body) {
    if (win_ok && mem_ok) { *title = "自检通过"; *body = ""; return; }
    // 11-10 英文默认：<宏>_EN 是英文句（与规格 en 逐字一致），界面语言中文才取中文宏
#define SC_(m) S2A_TR(m##_EN, m)
    if (as_unsupported(win_ok, need_mb, as_type)) { *title = SC_(S2A_SELFCHECK_AS_TITLE); *body = SC_(S2A_SELFCHECK_AS32_BODY); return; }
    if (ent == 0) { *title = SC_(S2A_SELFCHECK_ENT_TITLE); *body = SC_(S2A_SELFCHECK_ENT_BODY); return; }
    if (!win_ok && !need_mb) { *title = SC_(S2A_SELFCHECK_PKG_TITLE); *body = SC_(S2A_SELFCHECK_PKG_BODY); return; }
    *title = SC_(S2A_SELFCHECK_DEVICE_TITLE); *body = SC_(S2A_SELFCHECK_DEVICE_BODY);
#undef SC_
}
// 内存门槛只拦没签权限的（#29：4500 MB 是「有没有签权限」的分界，不是游戏的需求；6 GB 机型签了权限也可能不到，不能因此把所有游戏挡住）
int s2a_selfcheck_mem_blocks(int mem_ok, int ent) { return !mem_ok && ent == 0; }
static const char *g_scr_title = "", *g_scr_body = "";
void s2a_selfcheck_page(const char **title, const char **body) { *title = g_scr_title; *body = g_scr_body; }

#ifndef S2A_UNIT_TEST
#include <sys/sysctl.h>
#include <unistd.h>
#include <stdlib.h>
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
static const char k_key_iml[] = "com.apple.developer.kernel.increased-memory-limit";
// 读本进程签名里的权限：1 已签 true、0 没有、-1 读不到（CS_OPS_ENTITLEMENTS_BLOB = 7：8 字节头 = 魔数 0xfade7171 + 总长，大端，之后是 XML）
static int ent_state(const char *key) {
    uint8_t h[8] = {0};
    if (csops(getpid(), 7, h, sizeof h) == 0) return 0;   // 头装得下 = 没有权限块
    uint32_t len = (uint32_t)h[4] << 24 | (uint32_t)h[5] << 16 | (uint32_t)h[6] << 8 | h[7];
    if (len <= 8 || len > (1u << 20)) return -1;
    uint8_t *b = malloc(len); if (!b) return -1;
    int r = csops(getpid(), 7, b, len) ? -1 : s2a_ent_true((const char *)b + 8, len - 8, key);
    free(b); return r;
}
static uint64_t phys_mb(void) { uint64_t m = 0; size_t s = sizeof m; return sysctlbyname("hw.memsize", &m, &s, NULL, 0) ? 0 : m >> 20; }
int s2a_selfcheck(void) {
    uint64_t wb, ws; s2a_window_get(&wb, &ws); int ok = 1;
    int ent = ent_state(k_key_iml); uint64_t top = s2a_va_top(), pm = phys_mb();
    const char *es = ent == 1 ? "已签" : ent == 0 ? "未签" : "读不到";
#if TARGET_OS_IPHONE
    uint64_t avail = os_proc_available_memory() >> 20;
    // 系统给本 App 的内存上限 = 本进程物理占用（phys_footprint，iOS 判杀同口径）+ os_proc_available_memory（同 hud.c）。11-05 时之笛：带「提高内存上限」权限的测试设备2
    //   上限约 7.5 GB，进游戏场景加载时顶到上限被系统终止；把上限写进自检行，开局就看得到
    uint64_t foot = 0; { task_vm_info_data_t vi; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) == KERN_SUCCESS) foot = vi.phys_footprint >> 20; }
    uint64_t need, fit; s2a_window_need(&need, &fit);   // 本款要的跨度（包里 main.npdm 定）、本机 2^39 以下最大能放的一块（vawin.c 起局时量）
    int win_ok = s2a_window_ok(), mem_ok = avail >= MEM_NEED_MB;
    // 「自检：窗口 <状态>（」格式下游在解析（tools/health_table.py、score_cells.py）：占到 / 不够
    LOG("自检：窗口 %s（%#llx +%llu MB，本款要 %llu MB，本机最多 %llu MB）｜可用内存 %llu MB（需 ≥ %d MB）｜物理内存 %llu MB｜地址上限 %#llx｜『提高内存上限』权限 %s｜系统给本 App 的上限约 %llu MB（占用 %llu + 可用 %llu）",
        win_ok ? "占到" : "不够", (unsigned long long)wb, (unsigned long long)(ws >> 20), (unsigned long long)(need >> 20), (unsigned long long)(fit >> 20), (unsigned long long)avail, MEM_NEED_MB, (unsigned long long)pm, (unsigned long long)top, es, (unsigned long long)(foot + avail), (unsigned long long)foot, (unsigned long long)avail);
    int mem_block = s2a_selfcheck_mem_blocks(mem_ok, ent);
    if (!mem_ok && !mem_block)
        LOG("【黄】这台手机内存偏小（系统给本 App 约 %llu MB，可用 %llu MB），大游戏可能被系统结束；已放行起局", (unsigned long long)(foot + avail), (unsigned long long)avail);
    if (!win_ok || mem_block) {
        int ast = s2a_window_astype();   // main.npdm 的地址空间类型（跨度为 0 时 vawin.c 读的，-1 = 没读到）
        s2a_selfcheck_explain(g_hint, sizeof g_hint, win_ok, !mem_block, ent, avail, pm, top, fit >> 20, need >> 20, ast);
        s2a_selfcheck_screen(win_ok, !mem_block, ent, need >> 20, ast, &g_scr_title, &g_scr_body);
        LOG("【红】自检不过：%s", g_hint); ok = 0;
    }
#else
    LOG("自检：窗口 %s（%#llx +%llu MB）｜Mac 不查内存上限｜物理内存 %llu MB｜地址上限 %#llx｜『提高内存上限』权限 %s",
        s2a_window_ok() ? "占到" : "不够", (unsigned long long)wb, (unsigned long long)(ws >> 20), (unsigned long long)pm, (unsigned long long)top, es);
#endif
    return ok;
}
#endif
#endif // Android / Apple 自检
