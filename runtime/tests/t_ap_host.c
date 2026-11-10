// 自动玩家宿主接口单测：
// ① 上屏帧数按 s2a_frame_presented 次数累加（期望 3）。
// ② 写跟踪计数：自动玩家打「S2A 标记 MARK」时跟一行计数快照；收局行给 MARK 后增量每秒（桩计数 MARK 时缺页 100、收局时 100 + 增量），
//    别的日志行不触发。期望值按桩手算：增量缺页 5000、mprotect 8000，除以 MARK 到收局的实耗秒数。
// ③ 同局交替开关（alt.c）从 MARK 起算：MARK 行调 s2a_alt_mark 1 次，别的行 0 次。
// ④ 出图停住看门（S2A_STALL_DUMP_S=1，桩线程表计次）：停 1.6 秒 → 打 1 次；继续停 → 不重打；上屏一帧后再停 → 2 次；
//    冻结中停 → 不打；解冻后停 → 3 次；再上屏再停 → 仍 3 次（每局至多 3 次）。
// ⑤ 标称帧率（s2a_nominal_fps_set → s2a_ap_nominal_fps）：没报过 = 0；报 0 / 负数不收仍 0、不打日志；报 60 → 60 并打一行「标称帧率：60 帧/秒」；
//    再报 60 → 不重打；报 30 → 30 并打一行带「运行中变了」；报 -5 不收仍 30。期望按函数约定手写（读 fps 与日志行）。
// ⑧ 开发设施开关：s2a_dev_on 桩 0（玩家口径）→ 首帧上屏后停住看门不起、停 1.6 秒现场 0 份；桩 1（开发包）→ 1 份。各在 fork 子进程里从零开始。
// ⑦ 永久卡住（最该救的那种局：n 恒 1、idle 一直涨）：只打 1 份现场 → 屏幕提示 1 次 → 到 lim+4s 秒走 _exit(86)。
//    在设 S2A_STALL_DUMP_S 之前 fork 出子进程（阈值是首次调用时缓存的 static），钩子把「退出码 + 现场份数 + 提示次数」带回父进程，
//    进程内不真死。负对照：把门槛改回 n>=3 时这一项必红（子进程到点不退）。
#include "../src/native.h"
#include "../src/dev_facilities.h"
#include "../include/s2a_hud.h"
#include "../../graphics/track/s2a_track.h"
#include <unistd.h>
#include <stdatomic.h>
#include <sys/wait.h>
void s2a_host_shutdown(const char *why) { (void)why; }
void s2a_dguard_frame(uint64_t now) { (void)now; }
void s2a_dguard_evidence(const char *why, int stall) { (void)why; (void)stall; }
void s2a_load_first_frame(uint64_t now) { (void)now; }   // loadprog.c 加载页：首帧调   // dguard.c 直连安全网：s2a_frame_presented 每帧调
void s2a_wg_frame(void) {}   // thread.c 帧间隔工作组（S2A_WORKGROUP）：s2a_frame_presented 每帧调
#include <time.h>
uint64_t now_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec; }
static s2a_track_stat g_stub; static int g_nstats;
void s2a_track_stats(s2a_track_stat *out) { *out = g_stub; g_nstats++; }
static int g_nalt;
void s2a_alt_mark(void) { g_nalt++; }
void s2a_ap_log(const char *fmt, ...); void s2a_track_stat_log(const char *when);
static _Atomic int g_ndump, g_fz;
// ⑦ 永久卡住的子进程里，把「走了退出」与「已打几份现场」带回父进程再退出（钩子替掉 _exit(86)）
static int g_rep_fd = -1;
static _Atomic int g_nnotice;
static _Atomic int g_nclear;   // ⑦b：帧又走了收掉提示（钩子收到 NULL）
static void hook_notice(const char *m) { if (!m) atomic_fetch_add(&g_nclear, 1); else if (strstr(m, "The game picture is stuck") && !strstr(m, "游戏画面卡住了")) atomic_fetch_add(&g_nnotice, 1); }   // 11-10 英文缺省（s2a_ui_zh = 0）
static void hook_exit(int code) {
    char b[3] = { (char)code, (char)atomic_load(&g_ndump), (char)atomic_load(&g_nnotice) };
    ssize_t w = write(g_rep_fd, b, 3); (void)w; _exit(0);
}
void s2a_ap_set_exit_hook(void (*fn)(int));
void s2a_ap_set_notice_hook(void (*fn)(const char *));
void s2a_thread_dump(void) { g_ndump++; }          // 桩：看门经 dlsym 取到它
static _Atomic int g_dev = 1;   // ⑧ 开发设施开关桩（os.c s2a_dev_on）：缺省 1 = 开发包，原有 ④ ⑦ 照旧
int s2a_dev_on(void) { return atomic_load(&g_dev); }
int s2a_guest_frozen(void) { return g_fz; }
static _Atomic int g_nhost;
int s2a_dump_threads(const char *why) { (void)why; g_nhost++; return 0; }   // 桩：宿主线程栈
static int capture(void (*fn)(void), char *out, size_t n) {
    int pfd[2]; if (pipe(pfd)) return 0;
    int keep = g_s2a_logfd; g_s2a_logfd = pfd[1]; fn(); g_s2a_logfd = keep; close(pfd[1]);
    ssize_t k = read(pfd[0], out, n - 1); out[k > 0 ? k : 0] = 0; close(pfd[0]); return 1;
}
static void other(void) { s2a_ap_log("自动玩家：导航 → 按 A（第 %d 下）", 1); }
static void mark(void) { g_stub.faults = 100; g_stub.mprotects = 200; s2a_ap_log("S2A 标记 MARK：帧 %d", 1870); }
static uint64_t g_t1, g_t2;
static void fin(void) { g_stub.faults = 5100; g_stub.mprotects = 8200; g_t1 = now_ns(); s2a_track_stat_log("收局"); g_t2 = now_ns(); }
void s2a_nominal_fps_set(int fps); int s2a_ap_nominal_fps(void);
static int g_nf_arg; static void nf_set(void) { s2a_nominal_fps_set(g_nf_arg); }
// ⑤：报 arg 后读到的 fps 要是 want；日志里「标称帧率」行要有 / 没有（want_log），有的话要含 sub（NULL = 不查）
static int nominal_case(int arg, int want, int want_log, const char *sub) {
    char b[1024]; g_nf_arg = arg; capture(nf_set, b, sizeof b); int got = s2a_ap_nominal_fps(), logged = strstr(b, "标称帧率") != NULL, ok = got == want && logged == want_log && (!sub || strstr(b, sub));
    printf("%s ⑤ 标称帧率 报 %d → %d（期望 %d）、日志%s（期望%s%s%s）\n", ok ? "✓" : "✗", arg, got, want, logged ? "有" : "无", want_log ? "有" : "无", sub ? "、含 " : "", sub ? sub : "");
    return !ok;
}
int main(void) {
    int bad = 0;
    extern _Atomic uint64_t g_s2a_hud_ft[2048], g_s2a_hud_fn;
    uint64_t before = now_ns(); s2a_hud_frame(); uint64_t after = now_ns();
    uint64_t stamp = atomic_load(&g_s2a_hud_ft[0]);
    if (atomic_load(&g_s2a_hud_fn) != 1 || stamp < before || stamp > after) {
        printf("✗ HUD 帧时间戳未使用宿主单调纳秒钟\n"); bad++;
    }
    {   // ⑧ 开发设施开关（11-07 质量线，cmdr/壳内开发设施盘点.md）：玩家口径（s2a_dev_on = 0）首帧上屏后不起停住看门线程，停 1.6 秒 → 现场 0 份；
        //    开发包（= 1）同样条件 → 1 份（同 ④ 第一步）。看门只在首帧上屏起一次（静态标记），所以各在一个 fork 出的子进程里从零开始；份数经管道带回
        for (int dev = 0; dev <= 1; dev++) {
            int pfd[2]; if (pipe(pfd)) { printf("✗ ⑧ pipe\n"); bad++; break; }
            pid_t pid = fork();
            if (pid == 0) { close(pfd[0]); atomic_store(&g_dev, dev); setenv("S2A_STALL_DUMP_S", "1", 1); s2a_frame_presented(); usleep(1600000);
                            char b = (char)atomic_load(&g_ndump); ssize_t w = write(pfd[1], &b, 1); (void)w; _exit(0); }
            close(pfd[1]); char b = -1; ssize_t r = read(pfd[0], &b, 1); close(pfd[0]); int st; waitpid(pid, &st, 0);
            int want = dev ? 1 : 0;
            if (r != 1 || b != want) { printf("✗ ⑧ 开发设施 %s：停住现场 %d 份（期望 %d）\n", dev ? "开（开发包）" : "关（玩家口径）", (int)b, want); bad++; }
            else printf("✓ ⑧ 开发设施 %s：停住看门%s，停 1.6 秒现场 %d 份\n", dev ? "开（开发包）" : "关（玩家口径）", dev ? "照起" : "不起", (int)b);
        }
    }
    {   // ⑧b 判定矩阵（native.h s2a_dev_decide）：环境变量 > Info.plist > 缺省开；期望按约定手写
        struct { const char *env; int has, on, want; const char *what; } dm[] = {
            {NULL, 0, 1, 1, "都没有 → 开（开发包缺省）"}, {NULL, 1, 0, 0, "plist 0 → 关（玩家包）"}, {NULL, 1, 1, 1, "plist 1 → 开"},
            {"1", 1, 0, 1, "环境变量 1 盖过 plist 0 → 开（排查玩家问题）"}, {"0", 0, 1, 0, "环境变量 0 → 关"}, {"", 1, 0, 0, "空环境变量不算 → 按 plist 0 关"} };
        for (unsigned i = 0; i < sizeof dm / sizeof *dm; i++) {
            int got = s2a_dev_decide(dm[i].env, dm[i].has, dm[i].on);
            if (got != dm[i].want) { printf("✗ ⑧b 判定 %s：%d\n", dm[i].what, got); bad++; } else printf("✓ ⑧b 判定 %s\n", dm[i].what);
        }
    }
    {   // ⑦ 永久卡住（n 恒 1、idle 一直涨）：只打 1 份现场，到 lim+4s 秒走退出路径。
        //    在设 S2A_STALL_DUMP_S 之前 fork，让子进程自己读阈值（阈值是首次调用时缓存的 static）；
        //    钩子把「退出码 + 现场份数」带回父进程，进程内不真死（同 graphics/metal/tests/t_gpuwd.c 的做法）
        int pfd[2]; pid_t pid = -1;
        if (!pipe(pfd)) {
            pid = fork();
            if (pid == 0) {
                close(pfd[0]); g_rep_fd = pfd[1];
                setenv("S2A_STALL_DUMP_S", "1", 1); setenv("S2A_STALL_EXIT_S", "3", 1); setenv("S2A_STALL_NOTICE_S", "1", 1);
                s2a_ap_set_exit_hook(hook_exit); s2a_ap_set_notice_hook(hook_notice);
                s2a_frame_presented();     // 首帧：看门线程在这里起
                usleep(5000000);           // lim=4 tick(1 s) 打现场；退出 lim+12=16 tick(4 s)，提示 16-4=12 tick(3 s) → 5 秒足够
                _exit(77);                 // 能走到这里 = 到点没退
            }
            close(pid > 0 ? pfd[1] : pfd[0]);
        }
        if (pid > 0) {
            char rb[3] = {0, 0, 0}; ssize_t k = read(pfd[0], rb, 3); close(pfd[0]);
            int st = 0; waitpid(pid, &st, 0);
            int ok = k == 3 && rb[0] == 86 && rb[1] == 1 && rb[2] == 1;   // 退出码 86、只打 1 份现场、提示过 1 次
            printf("%s ⑦ 永久卡住只打 1 份现场、先提示再退出（退出码 %d、现场 %d 份、提示 %d 次；期望 86 / 1 / 1）%s\n", ok ? "✓" : "✗",
                   k == 3 ? rb[0] : -1, k == 3 ? rb[1] : -1, k == 3 ? rb[2] : -1, k == 3 ? "" : "（子进程没回报：到点没退）");
            bad += !ok;
        } else { printf("✗ ⑦ 起不了子进程（fork/pipe 失败）\n"); bad++; }
    }
    {   // ⑦b 不退出（缺省 S2A_STALL_EXIT_S=0）：停满 NOTICE_IDLE_S 秒给提示、帧又走了收掉（钩子收 NULL），且不走退出路径。
        //    手算：DUMP_S=1 → lim 4 格（1 s）打现场；NOTICE_IDLE_S=1 → 4 格 = lim，现场那一刻即提示；停 2.5 秒后出一帧 → 收 1 次
        int pfd[2]; pid_t pid = -1;
        if (!pipe(pfd)) {
            pid = fork();
            if (pid == 0) {
                close(pfd[0]); g_rep_fd = pfd[1];
                setenv("S2A_STALL_DUMP_S", "1", 1); unsetenv("S2A_STALL_EXIT_S"); setenv("S2A_STALL_NOTICE_IDLE_S", "1", 1);
                s2a_ap_set_exit_hook(hook_exit); s2a_ap_set_notice_hook(hook_notice);
                s2a_frame_presented(); usleep(2500000); s2a_frame_presented(); usleep(600000);
                char b[3] = { 0, (char)atomic_load(&g_nnotice), (char)atomic_load(&g_nclear) };   // 0 = 没走退出（走了钩子会写 86）
                ssize_t w = write(g_rep_fd, b, 3); (void)w; _exit(0);
            }
            close(pid > 0 ? pfd[1] : pfd[0]);
        }
        if (pid > 0) {
            char rb[3] = {9, 0, 0}; ssize_t k = read(pfd[0], rb, 3); close(pfd[0]);
            int st = 0; waitpid(pid, &st, 0);
            int ok = k == 3 && rb[0] == 0 && rb[1] == 1 && rb[2] == 1;
            printf("%s ⑦b 不退出：停住给提示 1 次、帧走了收掉 1 次、不退出（退出码 %d、提示 %d、收 %d；期望 0 / 1 / 1）\n", ok ? "✓" : "✗",
                   k == 3 ? rb[0] : -1, k == 3 ? rb[1] : -1, k == 3 ? rb[2] : -1);
            bad += !ok;
        } else { printf("✗ ⑦b 起不了子进程（fork/pipe 失败）\n"); bad++; }
    }
    setenv("S2A_STALL_DUMP_S", "1", 1);   // 首帧前设：看门在首帧起线程时读阈值
    for (int i = 0; i < 3; i++) s2a_frame_presented();
    uint64_t s2a_ap_frames(void); if (s2a_ap_frames() != 3) { printf("✗ 上屏帧数 %llu，期望 3\n", (unsigned long long)s2a_ap_frames()); bad++; }
    char b[2048];
    capture(other, b, sizeof b); if (g_nstats || strstr(b, "写跟踪计数")) { printf("✗ 非 MARK 行触发了计数：%s\n", b); bad++; }
    if (g_nalt != 0) { printf("✗ 非 MARK 行调了交替起点 %d 次，期望 0\n", g_nalt); bad++; }
    uint64_t t0a = now_ns(); capture(mark, b, sizeof b); uint64_t t0b = now_ns();   // MARK 快照取于 [t0a, t0b] 之间
    if (!strstr(b, "S2A 标记 MARK：帧 1870") || !strstr(b, "写跟踪计数 [MARK]：缺页 100、mprotect 200")) { printf("✗ MARK 行后应跟计数快照：%s\n", b); bad++; }
    if (g_nalt != 1) { printf("✗ MARK 行调交替起点 %d 次，期望 1\n", g_nalt); bad++; }
    usleep(200000);
    capture(fin, b, sizeof b);
    // 期望：缺页 5000 / 秒数、mprotect 8000 / 秒数；秒数在 [g_t1 - t0b, g_t2 - t0a] 之间（快照与收局各自落在前后两次取时之间；负载高时两端都可能拉开）
    double lo = (g_t1 - t0b) / 1e9, hi = (g_t2 - t0a) / 1e9; double f = 0, m = 0, sec = 0;
    const char *p = strstr(b, "写跟踪计数 MARK 后 ");
    if (!p || sscanf(p, "写跟踪计数 MARK 后 %lf 秒每秒：缺页 %lf、mprotect %lf", &sec, &f, &m) != 3 || f < 5000 / hi - 1 || f > 5000 / lo + 1 || m < 8000 / hi - 1 || m > 8000 / lo + 1)
        { printf("✗ 收局行增量每秒不对（期望缺页 %.0f–%.0f、mprotect %.0f–%.0f）：%s\n", 5000 / hi, 5000 / lo, 8000 / hi, 8000 / lo, b); bad++; }
    struct { const char *what; int want; void (*act)(void); int fz; } st[] = {
        {"停 1.6 秒 → 打 1 次", 1, NULL, 0}, {"继续停 → 不重打", 1, NULL, 0}, {"上屏一帧后再停 → 2 次", 2, s2a_frame_presented, 0},
        {"冻结中停 → 不打", 2, s2a_frame_presented, 1}, {"解冻后停 → 3 次", 3, NULL, 0}, {"再上屏再停 → 仍 3 次（至多 3 次）", 3, s2a_frame_presented, 0} };
    for (unsigned i = 0; i < sizeof st / sizeof *st; i++) {
        g_fz = st[i].fz; if (st[i].act) st[i].act(); usleep(1600000);
        if (g_ndump != st[i].want) { printf("✗ ④ 停住看门 %s：打了 %d 次\n", st[i].what, (int)g_ndump); bad++; } else printf("✓ ④ 停住看门 %s\n", st[i].what);
    }
    {   // ⑥ 降级退出判定（S2A_STALL_EXIT_S，缺省关）：只打表，不起线程
        int s2a_ap_stall_exit_after(int, int, int, int);
        struct { int idle, n, lim, s, want; } ex[] = {
            {999, 3, 4, 0, 0},   // 缺省 s=0：永不退出（只打现场）
            {999, 0, 4, 2, 0},   // 一份现场都还没打：不退
            {11,  1, 4, 2, 0},   // 打了 1 份、又停 1.75 秒（阈值 2 秒）：不退
            {12,  1, 4, 2, 1},   // 打了 1 份、又停满 2 秒：退（永久卡住的局 n 只会是 1，不能等 n≥3）
            {12,  3, 4, 2, 1},   // 打过 3 份同样按停住时长判
        };
        for (unsigned i = 0; i < sizeof ex / sizeof *ex; i++) {
            int got = s2a_ap_stall_exit_after(ex[i].idle, ex[i].n, ex[i].lim, ex[i].s);
            if (got != ex[i].want) { printf("✗ ⑥ 降级退出 idle=%d n=%d lim=%d s=%d → %d（期望 %d）\n", ex[i].idle, ex[i].n, ex[i].lim, ex[i].s, got, ex[i].want); bad++; }
            else printf("✓ ⑥ 降级退出 idle=%d n=%d lim=%d s=%d → %d\n", ex[i].idle, ex[i].n, ex[i].lim, ex[i].s, got);
        }
        // ⑥b 第 2 档提示时刻：退出时退出前 NOTICE_S 秒，但不早于「打完现场」（钳位）；不退出（s=0，缺省）时停满 NOTICE_IDLE_S 秒（q）提示（审计 P1-4），q=0 关
        int s2a_ap_stall_notice_after(int, int, int, int, int, int);
        struct { int idle, n, lim, s, ns, q, want; } nt[] = {
            {119, 1, 40, 0,  20, 30, 0},   // 缺省 s=0、q=30：要停满 4×30=120 格，差一格不提示
            {120, 1, 40, 0,  20, 30, 1},   // 到 120 格（30 秒）提示——原先「不退出就不提示」这里是 0
            {120, 0, 40, 0,  20, 30, 0},   // 现场还没打：不提示
            {39,  1, 40, 0,  20, 5,  0},   // q=5 秒（20 格）早于打现场的 lim=40：钳到 lim，39 不提示
            {40,  1, 40, 0,  20, 5,  1},   //   到 lim 提示
            {999, 1, 4,  0,  20, 0,  0},   // q=0：不退出时提示关掉
            {999, 0, 4,  30, 20, 30, 0},   // 现场还没打：不提示
            {43,  1, 4,  30, 20, 30, 0},   // 退出 lim+120=124、提示 124-80=44：差一格不提示（q 不影响退出档）
            {44,  1, 4,  30, 20, 30, 1},   // 到 44 提示（停住 12 秒，退出前 20 秒）
            {4,   1, 4,  5,  20, 30, 1},   // 退出才 lim+20=24，提示 24-80<0 → 钳到 lim：现场那一刻就提示
            {11,  1, 4,  3,  1,  30, 0},   // 退出 lim+12=16、提示 12：差一格不提示
            {12,  1, 4,  3,  1,  30, 1},   // 到 12 提示，之后再 1 秒退出（线程级见 ⑦）
        };
        for (unsigned i = 0; i < sizeof nt / sizeof *nt; i++) {
            int got = s2a_ap_stall_notice_after(nt[i].idle, nt[i].n, nt[i].lim, nt[i].s, nt[i].ns, nt[i].q);
            if (got != nt[i].want) { printf("✗ ⑥b 提示时刻 idle=%d n=%d lim=%d s=%d ns=%d q=%d → %d（期望 %d）\n", nt[i].idle, nt[i].n, nt[i].lim, nt[i].s, nt[i].ns, nt[i].q, got, nt[i].want); bad++; }
            else printf("✓ ⑥b 提示时刻 idle=%d n=%d lim=%d s=%d ns=%d q=%d → %d\n", nt[i].idle, nt[i].n, nt[i].lim, nt[i].s, nt[i].ns, nt[i].q, got);
        }
    }
    if (g_nhost != g_ndump) { printf("✗ ④ 停住看门 宿主线程栈 %d 次，应与线程表同为 %d 次\n", (int)g_nhost, (int)g_ndump); bad++; } else printf("✓ ④ 停住看门 每次同时打宿主线程栈（%d 次）\n", (int)g_nhost);
    if (s2a_ap_nominal_fps() != 0) { printf("✗ ⑤ 标称帧率 没报过应为 0，实为 %d\n", s2a_ap_nominal_fps()); bad++; } else printf("✓ ⑤ 标称帧率 没报过 = 0\n");
    bad += nominal_case(0, 0, 0, NULL);
    bad += nominal_case(60, 60, 1, "标称帧率：60 帧/秒");
    bad += nominal_case(60, 60, 0, NULL);
    bad += nominal_case(30, 30, 1, "标称帧率：30 帧/秒（出图实际跟的节拍，运行中变了");
    bad += nominal_case(-5, 30, 0, NULL);
    printf("%s t_ap_host：%d 处不符\n", bad ? "✗" : "✓", bad); return bad;
}
