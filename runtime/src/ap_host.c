// 测试层（通用自动玩家，tests/autoplay/autoplay_host.h）要原生层提供的四项：上屏帧数、标称帧率、收局、写一行 host.log。
// 上屏帧数由渲染器每上屏一帧调 s2a_frame_presented() 累加；标称帧率由各出图路径报进 s2a_nominal_fps_set()（见该函数）。s2a_ap_draws 归帧率能耗线、s2a_ap_audio_mark 归服务接入线，frames.tsv 由渲染器写。
#include "native.h"
#include "s2a_ui_lang.h"   // 上屏话术英文默认（S2A_TR）
#include "dev_facilities.h"
#include "../include/s2a_hud.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include "../../graphics/track/s2a_track.h"
static _Atomic uint64_t g_frames;
static _Atomic int g_stall_stop;
static pthread_t g_stall_thread;
static int g_stall_started;
static _Atomic int g_nominal_fps, g_nominal_n;   // 标称帧率（见 s2a_nominal_fps_set）；上屏时给帧间隔工作组定截止
void s2a_wg_frame(int fps);   // thread.c 帧间隔工作组（缺省关，S2A_WORKGROUP=1/render/all 可开）；fps = 标称帧率定本帧截止
// 开发浮层（runtime/src/hud.c，S2A_HUD=1）：开着时每上屏一帧记一个单调时间戳进环（容量够 120 帧/秒 × 10 秒），浮层据此算帧率与慢帧；关着时只读缓存的开关
static _Atomic int g_hud_on = -1;
int s2a_hud_on(void) { int v = atomic_load(&g_hud_on); if (v < 0) { const char *e = getenv("S2A_HUD"); v = e && !strcmp(e, "1"); atomic_store(&g_hud_on, v); } return v; }
_Atomic uint64_t g_s2a_hud_ft[2048], g_s2a_hud_fn;
// 简版性能浮层（11-09 B 方案，齿轮菜单「性能浮层」，玩家随时开关）：开着时同样记上屏时间戳，跨局保留（界面按偏好设）
static _Atomic int g_hud_brief;
void s2a_hud_brief_set(int on) { atomic_store(&g_hud_brief, on ? 1 : 0); }
void s2a_hud_frame(void) {
    uint64_t n = atomic_load_explicit(&g_s2a_hud_fn, memory_order_relaxed);
    atomic_store_explicit(&g_s2a_hud_ft[n % 2048], now_ns(), memory_order_relaxed);
    atomic_store_explicit(&g_s2a_hud_fn, n + 1, memory_order_release);
}
// S2A_THREAD_DUMP_FRAME=<帧号>（诊断，缺省关）：上屏到这一帧时打一次全线程表——正常局也在停住局出事的同一帧附近留一张表，两边比第一处不同
static uint64_t dump_frame(void) { static long long v = -1; if (v < 0) { const char *e = getenv("S2A_THREAD_DUMP_FRAME"); v = e && *e ? atoll(e) : 0; } return (uint64_t)v; }
static int stall_s(void); static void *stall_watch(void *a);   // 出图停住看门，定义在文件后部
// 回前台恢复时间线（#495「回前台卡几秒」定因）：iOS 壳回前台时交来各阶段时刻，之后每上屏一帧推进；连续 30 帧间隔都 ≤ 50 ms 算稳定，
//   打一行逐段毫秒数（到稳定或 20 秒为止）。只在渲染线程推进，起点用原子量交接
static struct { uint64_t note, ds, gpu, thr, done; } g_rs_in;
static _Atomic int g_rs_on;
static uint64_t g_rs_first, g_rs_last, g_rs_maxgap, g_rs_f0; static int g_rs_run;
void s2a_resume_timeline(uint64_t t_note, uint64_t t_ds, uint64_t t_gpu, uint64_t t_thr, uint64_t t_done) {
    if (atomic_load(&g_rs_on)) return;   // 上一次还没测完
    g_rs_in.note = t_note; g_rs_in.ds = t_ds; g_rs_in.gpu = t_gpu; g_rs_in.thr = t_thr; g_rs_in.done = t_done;
    atomic_store_explicit(&g_rs_on, 1, memory_order_release);
}
static void resume_frame(uint64_t f) {
    if (!atomic_load_explicit(&g_rs_on, memory_order_acquire)) return;
    uint64_t t = now_ns();
    if (!g_rs_first) { g_rs_first = t; g_rs_last = t; g_rs_maxgap = 0; g_rs_run = 0; g_rs_f0 = f; return; }
    uint64_t gap = t - g_rs_last; g_rs_last = t;
    if (gap > g_rs_maxgap) g_rs_maxgap = gap;
    g_rs_run = gap <= 50000000ull ? g_rs_run + 1 : 0;
    int stable = g_rs_run >= 30, late = t - g_rs_in.note > 20000000000ull;
    if (!stable && !late) return;
    double ms = 1e-6;
    LOG("回前台时间线：通知（绝对 %.3f ms，CLOCK_UPTIME_RAW，可与 [声] t_audio 直接对时）→ 主线程处理 %.0f ms → 直连层恢复 %.0f ms → 放开 GPU %.0f ms → 解冻线程 + 时钟 %.0f ms → 首帧上屏 %.0f ms → %s %.0f ms（共 %.0f ms；期间最长帧间隔 %.0f ms，%llu 帧）",
        g_rs_in.note * ms, (g_rs_in.ds - g_rs_in.note) * ms, (g_rs_in.gpu - g_rs_in.ds) * ms, (g_rs_in.thr - g_rs_in.gpu) * ms, (g_rs_in.done - g_rs_in.thr) * ms,
        (g_rs_first - g_rs_in.done) * ms, stable ? "稳定出帧（连续 30 帧 ≤ 50 ms）" : "20 秒仍未稳定", (t - g_rs_first) * ms,
        (t - g_rs_in.note) * ms, g_rs_maxgap * ms, (unsigned long long)(f - g_rs_f0));
    g_rs_first = 0; atomic_store(&g_rs_on, 0);
}
void s2a_dguard_frame(uint64_t now); void s2a_dguard_evidence(const char *why, int stall);
void s2a_load_first_frame(uint64_t now);   // loadprog.c：首帧上屏 → 加载页收起、全部编完的记下已完整预热   // dguard.c：直连安全网（首帧后前台满 60 秒清零连续失败）；没 arm 时一次原子读
void s2a_frame_presented(void) { s2a_wg_frame(atomic_load_explicit(&g_nominal_fps, memory_order_relaxed)); s2a_dguard_frame(now_ns()); if (s2a_hud_on() || atomic_load_explicit(&g_hud_brief, memory_order_relaxed)) s2a_hud_frame(); uint64_t f = atomic_fetch_add_explicit(&g_frames, 1, memory_order_relaxed);
    resume_frame(f);
    if (!f) { BOOT_MARK("nnMain → 首帧上屏（游戏自身加载 + 渲染器首帧）"); s2a_load_first_frame(now_ns()); }
    if (!f && stall_s() > 0 && !g_stall_started && s2a_dev_on()) { atomic_store(&g_stall_stop, 0); if (!pthread_create(&g_stall_thread, NULL, stall_watch, NULL)) g_stall_started = 1; }
    if (dump_frame() && f + 1 == dump_frame()) { void (*td)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "s2a_thread_dump");   // 线程表在 thread.c；只链 ap_host 的单测里取不到就不打
        if (td) { LOG("线程表 [S2A_THREAD_DUMP_FRAME=%llu]：", (unsigned long long)(f + 1)); td(); } } }
uint64_t s2a_ap_frames(void) { return atomic_load_explicit(&g_frames, memory_order_relaxed); }
// 标称帧率（autoplay_host.h s2a_ap_nominal_fps）= 出图实际跟的节拍（30 / 60）：自动玩家的路线 / 录手柄帧数按 30 帧写，按它折算（10-28 名单线：原先恒回 0，
//   60 帧局在同一帧号按键、墙钟上提前一半，暗黑2 / 八方2 同路线两局 WAIT:frame 50 锚 3.7 秒 vs 2.0 秒）。
//   语义：游戏逻辑帧每秒出几帧——60 帧表开且出图间隔放开 = 显示节拍 60；否则 = 游戏自己设的交换间隔对应的帧率；运行中切换（设置页关 60 帧、过热封顶、帧步进换 hold）跟着变。
//   不是实测上屏率：机器负载高时实测掉到几帧，路线帧数不该跟着缩。
//   各出图路径每次上屏 / 节拍变化时报进来：直连（NVN / Vulkan / OpenGL）graphics/nvn/host_adapt.m dm_guest_frame_tick → present_fps（NVN 按 hle_nvn.c nvn_present_fps：
//   帧步进 hold / display 模式 / 这一帧退回游戏间隔；GL 按 eglSwapInterval；Vulkan 按目标帧率）；通用模式 graphics/loop/RenderLoop.cs FrameInterval（SurfaceFlinger 生效交换间隔，含 S2A_FPS 地板）。
//   0 = 还没上过屏（自动玩家按 30）。变了打一行（前 32 次逐次、之后每 1000 次一次，同 RenderLoop 帧节拍行的限频），tools/fps_speed_judge.py 等离线工具据此知道这局的折算口径
void s2a_nominal_fps_set(int fps) {
    if (fps <= 0) return;
    int was = atomic_exchange_explicit(&g_nominal_fps, fps, memory_order_relaxed); if (was == fps) return;
    int n = atomic_fetch_add_explicit(&g_nominal_n, 1, memory_order_relaxed) + 1;
    if (n <= 32 || n % 1000 == 0) LOG("标称帧率：%d 帧/秒（出图实际跟的节拍%s；自动玩家按它折算按 30 帧写的路线 / 录手柄帧数）", fps, was ? "，运行中变了" : "");
}
int s2a_ap_nominal_fps(void) { return atomic_load_explicit(&g_nominal_fps, memory_order_relaxed); }
void s2a_host_shutdown(const char *why);
void s2a_ap_shutdown(const char *why) { s2a_host_shutdown(why); }
// 出图停住看门（正式包缺省开；S2A_STALL_DUMP_S=<秒>，缺省 10，0 = 关）：首帧上屏后起一条线程，每 250 ms 读一次上屏帧数，平时只读这一个计数。
//   帧数 ≥ 阈值秒没动、且游戏线程不在挂起冻结中（iOS 进后台）时打一次游戏线程表（含已等多久、条件键最近被谁发信号）+ 宿主线程调用栈，
//   帧数前进后才重新武装，每局至多 3 次。玩家手里的包停住时，host.log 里就带着现场（10-24 维护者：xc3 第 1300 帧偶发停住要正式局现场）
static int stall_s(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_STALL_DUMP_S"); v = e && *e ? atoi(e) : 10; } return v; }
// 停住后的降级动作（S2A_STALL_EXIT_S=<秒>，缺省 0 = 只打现场、不退出）：打完第一份现场后又继续停住这么多秒，这局不会自己回来了
//   （现场里等的是游戏自己的 SDK 事件，信号方那一路根本没跑），此时主动 _exit(86)——与执行器 / gfx 的 GPU 挂死看门狗同一个退出码口径，
//   跑局方据此记 fail、玩家看到的是「重开」而不是永远黑屏。缺省关：有局 60–90 秒后自己活，翻缺省要真机 A/B
// 单测把 _exit(86) 换成钩子，验「到点真走这条路径」而不真死（同 graphics/metal/gal_gpuwd.h:45 的口径）
static void (*g_exit_hook)(int);
void s2a_ap_set_exit_hook(void (*fn)(int)) { g_exit_hook = fn; }
static int stall_exit_s(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_STALL_EXIT_S"); v = e && *e ? atoi(e) : 0; } return v; }
// 判定分离成纯函数（单测直接打表，不走时钟）：idle = 已停的 250 ms 次数，n = 已打过的现场份数，lim = 打现场的阈值次数
//   （= 4 × S2A_STALL_DUMP_S），s = S2A_STALL_EXIT_S。条件用「现场已打 ≥1 份、且又停了 s 秒」而不是「n ≥ 3」：
//   永久卡住的局 armed 一直不重新武装，n 只会是 1，等 n ≥ 3 就永远等不到——正是要救的那种局
int s2a_ap_stall_exit_after(int idle, int n, int lim, int s);
int s2a_ap_stall_exit_after(int idle, int n, int lim, int s) { return s > 0 && n >= 1 && idle >= lim + 4 * s; }
int s2a_ap_stall_exit_due(int idle, int n, int lim) { return s2a_ap_stall_exit_after(idle, n, lim, stall_exit_s()); }
// 第 2 档：退出前给玩家一句人话。S2A_STALL_NOTICE_S=<秒>（缺省 20）＝「退出前多久提示」，不是「折半」——
//   玩家看到提示要经过「读（2–3 s）→ 试按键（1–2 s）→ 决定要不要重开（3–5 s）→ 确认存档在不在（5–10 s）」，
//   折半会让 S2A_STALL_EXIT_S=30 时只给 15 秒，刚看完就被踢。S2A_STALL_EXIT_S = 0 时不退出，提示改按 S2A_STALL_NOTICE_IDLE_S 给（见下）。
//   看门线程不能弹 UI，但 s2a_ios_show_message 已从任意线程可调（ios/app.m:73「主线程上直接改，别的线程派回主线程」，
//   dispatch_async 不阻塞），所以直接调；别的平台取不到这个符号就只打日志，不引入新依赖
static int stall_notice_s(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_STALL_NOTICE_S"); v = e && *e ? atoi(e) : 20; } return v; }
// 不退出（S2A_STALL_EXIT_S=0，缺省）也要提示（审计 P1-4：原先「不退出就不提示」，生产包永远走不到这句人话，玩家分不清还在加载还是已经死了）：
//   停满 S2A_STALL_NOTICE_IDLE_S 秒（缺省 30，0 = 关）给一句「可能还在加载、一直不动再重开」，帧又走了就把这句收掉（有局 60–90 秒后自己活）
static int stall_notice_idle_s(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_STALL_NOTICE_IDLE_S"); v = e && *e ? atoi(e) : 30; } return v; }
int s2a_ap_stall_notice_after(int idle, int n, int lim, int s, int ns, int quiet);
int s2a_ap_stall_notice_after(int idle, int n, int lim, int s, int ns, int quiet) {
    if (n < 1) return 0;                    // 现场还没留，不提示
    if (s <= 0) return quiet > 0 && idle >= (4 * quiet > lim ? 4 * quiet : lim);
    int nt = (lim + 4 * s) - 4 * ns;        // 退出前 ns 秒
    if (nt < lim) nt = lim;                 // 钳位：不早于「打完现场」那一刻（现场还没留就先喊重开没道理）
    return idle >= nt;
}
int s2a_ap_stall_notice_due(int idle, int n, int lim) { return s2a_ap_stall_notice_after(idle, n, lim, stall_exit_s(), stall_notice_s(), stall_notice_idle_s()); }
static void (*g_notice_hook)(const char *);
void s2a_ap_set_notice_hook(void (*fn)(const char *)) { g_notice_hook = fn; }
static void *stall_watch(void *a) { s2a_thread_name("s2a-ap-stall");
    (void)a; int (*frozen)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_guest_frozen");   // 两者都在 thread.c；只链 ap_host 的单测由桩提供
    void (*td)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "s2a_thread_dump");
    int (*hd)(const char *) = (int (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_dump_threads");   // tdump.c：宿主线程调用栈（10-24 xc3 停住靠它定出实化互等）
    void (*msg)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_ios_show_message");   // 第 2 档：屏幕上给玩家一句话（见 s2a_ap_stall_notice_after）
    void (*clr)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_ios_clear_message");   // 帧又走了收掉提示（只收这条，别的提示不动）
    char shown[512] = "";   // 正在屏幕上的那句提示（收的时候按它认）
    uint64_t last = s2a_ap_frames(); int idle = 0, armed = 1, n = 0, noticed = 0, lim = 4 * stall_s();
    while (!atomic_load(&g_stall_stop)) {
        usleep(250000); uint64_t f = s2a_ap_frames();
        if (atomic_load(&g_stall_stop)) break;
        if (f != last) {   // 帧又走了：收掉提示，下一次停住重新给
            if (noticed) { LOG("出图停住看门：帧又走了（第 %llu 帧），收掉屏幕提示", (unsigned long long)f); if (g_notice_hook) g_notice_hook(NULL); else if (clr) clr(shown); }
            if (n) s2a_dguard_evidence(NULL, 1);   // 直连安全网：停住的证据撤回（自己活过来了）
            last = f; idle = 0; armed = 1; noticed = 0; continue;
        }
        if (frozen && frozen()) { idle = 0; continue; }
        ++idle;
        // 第 2 档先于第 3 档：退出前让用户知道「是卡住了要重开」，而不是看到闪退去猜是不是 bug。
        //   不阻塞（dispatch_async 回主线程），所以卡住的是游戏线程也不影响它显示
        if (!noticed && s2a_ap_stall_notice_due(idle, n, lim)) {
            noticed = 1;
            // 停了多久按 idle 算（每格 250 ms），不是打现场的阈值秒数
            // 屏上只给人话（第几帧、停了几秒在下一行日志里，11-02 维护者：内部读数不上屏）；第一段当提示页标题
            if (stall_exit_s() > 0) snprintf(shown, sizeof shown, "%s", S2A_TR("The game picture is stuck\n\nSwipe this app away in the app switcher and open it again. If it’s still stuck, long-press the screen with four fingers to open Settings, export the diagnostics and send them to us.",
                                                                                "游戏画面卡住了\n\n请从后台划掉本 App，再重新打开。还是卡住的话，四指长按屏幕打开设置，导出诊断包发给我们。"));
            else snprintf(shown, sizeof shown, "%s", S2A_TR("The game picture is stuck\n\nIt may still be loading, so you can wait a little longer. If nothing changes, swipe this app away in the app switcher and open it again.",
                                                           "游戏画面卡住了\n\n可能还在加载，可以再等一会儿；一直不动的话，请从后台划掉本 App，再重新打开。"));
            LOG("出图停住看门：停在第 %llu 帧已 %d 秒，屏幕上提示玩家（S2A_STALL_EXIT_S=%d%s）", (unsigned long long)f, idle / 4, stall_exit_s(), stall_exit_s() > 0 ? " 秒后退出" : "，不退出，帧走了就收掉提示");
            if (g_notice_hook) g_notice_hook(shown); else if (msg) msg(shown);
        }
        if (idle >= lim && armed && n < 3) {
            armed = 0; n++; s2a_dguard_evidence("画面停住", 1);   // 直连安全网：前台停住满 S2A_STALL_DUMP_S 秒算失败证据，帧又走了撤回
            LOG("出图停住看门：上屏帧数停在 %llu 已 %d 秒（第 %d 次，每局至多 3 次；S2A_STALL_DUMP_S=0 关），游戏线程表 + 宿主线程栈：", (unsigned long long)f, stall_s(), n);
            if (td) td();
            if (hd) { char w[96]; snprintf(w, sizeof w, "出图停住看门：停在第 %llu 帧已 %d 秒", (unsigned long long)f, stall_s()); hd(w); }
            continue;
        }
        if (s2a_ap_stall_exit_due(idle, n, lim)) {   // 降级：现场已留 ≥1 份、又停了 S2A_STALL_EXIT_S 秒 → 主动退出，不再无限等
            LOG("【红】出图停住看门：上屏帧数停在 %llu 已 %d 秒，现场已打 %d 次仍不前进，主动退出（退出码 86；S2A_STALL_EXIT_S=%d）",
                (unsigned long long)f, stall_s(), n, stall_exit_s());
            fflush(NULL);
            if (g_exit_hook) g_exit_hook(86);
            _exit(86);   // 钩子返回也不许再转：卡住的局宁可多退一次，也不能让看门线程继续空转
        }
    }
    return NULL;
}
// 写跟踪计数（维护者 10-20 动森能耗：iPhone 比旧库多约 3 W 在 CPU 侧，要「陷入 / mprotect 每秒多少次」）：MARK 时存快照打一行，
// 收局打全量与 MARK 后增量折每秒——真机正式局 / Mac 局都自带，不另起局
static s2a_track_stat g_ts_mark; static uint64_t g_ts_mark_ns;
int s2a_ap_session_stop(void) {
    atomic_store(&g_stall_stop, 1);
    if (g_stall_started) {
        int error = pthread_join(g_stall_thread, NULL);
        if (error) { LOG("【红】停帧监视线程 join 失败：%d", error); return -1; }
        g_stall_started = 0;
    }
    return 0;
}
int s2a_ap_session_reset(void) {
    if (s2a_ap_session_stop()) return -1;
    atomic_store(&g_frames, 0); atomic_store(&g_s2a_hud_fn, 0);
    atomic_store(&g_hud_on, -1);
    atomic_store(&g_nominal_fps, 0); atomic_store(&g_nominal_n, 0);
    for (int i = 0; i < 2048; i++) atomic_store(&g_s2a_hud_ft[i], 0);
    g_ts_mark = (s2a_track_stat){0}; g_ts_mark_ns = 0;
    g_rs_first = g_rs_last = g_rs_maxgap = g_rs_f0 = 0; g_rs_run = 0;
    atomic_store(&g_rs_on, 0);
    return 0;
}
void s2a_track_stat_log(const char *when) {
    s2a_track_stat s; s2a_track_stats(&s); uint64_t t = now_ns();
    LOG("写跟踪计数 [%s]：缺页 %llu、mprotect %llu、预解保护 %llu、脏区间 %llu、子页快照 %llu、重保护 %llu、自愈 %llu、竞争 %llu、环溢出 %llu、快照槽满退回 %llu、快照槽峰值 %llu（%llu 块，每块 8192）",
        when, (unsigned long long)s.faults, (unsigned long long)s.mprotects, (unsigned long long)s.preps, (unsigned long long)s.ranges,
        (unsigned long long)s.psnaps, (unsigned long long)s.rearms, (unsigned long long)s.heals, (unsigned long long)s.races, (unsigned long long)s.overflows,
        (unsigned long long)s.pfull, (unsigned long long)s.snap_peak, (unsigned long long)s.snap_chunks);
    if (!strcmp(when, "MARK")) { g_ts_mark = s; g_ts_mark_ns = t; return; }
    if (!g_ts_mark_ns || t <= g_ts_mark_ns) return;
    double sec = (t - g_ts_mark_ns) / 1e9;
    LOG("写跟踪计数 MARK 后 %.1f 秒每秒：缺页 %.0f、mprotect %.0f、预解保护 %.0f、脏区间 %.0f、子页快照 %.0f、重保护 %.0f", sec,
        (s.faults - g_ts_mark.faults) / sec, (s.mprotects - g_ts_mark.mprotects) / sec, (s.preps - g_ts_mark.preps) / sec,
        (s.ranges - g_ts_mark.ranges) / sec, (s.psnaps - g_ts_mark.psnaps) / sec, (s.rearms - g_ts_mark.rearms) / sec);
}
// 本局过没过 MARK（自动玩家第一次打「S2A 标记 MARK」之后为 1）：直连图形层的首遇现建读数按它分口径（graphics/nvn/fe_stat.h，nvn_mtl.m 里有返回 0 的弱缺省）
static _Atomic int g_ap_marked;
int s2a_ap_marked(void) { return atomic_load_explicit(&g_ap_marked, memory_order_relaxed); }
void s2a_ap_log(const char *fmt, ...) {
    char b[1024]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    s2a_log_line("%s", b);   // 不加 [s2a] 前缀：标记按字面匹配（如「S2A 标记 MARK：帧 N」）
    if (!strncmp(b, "S2A 标记 MARK", strlen("S2A 标记 MARK"))) { atomic_store_explicit(&g_ap_marked, 1, memory_order_relaxed); s2a_track_stat_log("MARK"); s2a_alt_mark(); }   // 同局交替开关（alt.c）从 MARK 起算
}
