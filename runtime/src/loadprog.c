// 首次进游戏的加载页：进度模型（接口与口径见 runtime/include/s2a_loadprog.h）。
#include "native.h"
#include "s2a_loadprog.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include "s2a_ui_lang.h"   // 上屏话术英文默认（S2A_TR）
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>

#define S 1000000000ull
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_stage, g_first_run, g_go;            // 阶段、首次、为什么不再等
static _Atomic int g_skip;                        // 玩家点了「先开始玩」
static int g_ff;                                  // 首帧已到、但预热还在等（页面先不收，预热结束时再收）
static long g_done, g_total;
static uint64_t g_t0, g_warm_t0, g_last_up;       // 起局、预热开始、已编数最近一次上涨
static double g_rate;                             // 已编 / 秒，按 1 秒窗口指数平滑
static uint64_t g_rate_t; static long g_rate_done;
static double g_frac;                             // 显示过的最大进度
static double g_eta_shown = -1; static uint64_t g_eta_t, g_slow_since;   // 显示的剩余秒数、它的时刻、新估计持续偏高的起点
static char g_pack[24];
static _Atomic int g_begun;                       // s2a_load_begin 调过 = 有加载页前端（iOS）；Mac / 安卓宿主没有

static double env_s(const char *k, double d) { const char *e = getenv(k); double v = e && *e ? atof(e) : d; return v > 0 ? v : d; }

void s2a_load_begin(uint64_t now, int first_run) {
    pthread_mutex_lock(&g_mu);
    g_stage = S2A_LOAD_DATA; g_first_run = first_run; g_go = S2A_LOAD_GO_NONE; g_ff = 0; atomic_store(&g_skip, 0);
    g_done = g_total = 0; g_t0 = now; g_warm_t0 = g_last_up = 0; g_rate = 0; g_rate_t = 0; g_rate_done = 0;
    g_frac = 0; g_eta_shown = -1; g_eta_t = g_slow_since = 0;
    pthread_mutex_unlock(&g_mu);
    atomic_store(&g_begun, 1);
}

void s2a_load_user_skip(void) { atomic_store(&g_skip, 1); }

static void mark_warm_done(void);
static double prepare_cap_s(void) { const char *e = getenv("DM_PSO_PREPARE_MAX_MS"); return e && atof(e) > 0 ? atof(e) / 1000.0 : 30.0; }   // 直连层首帧上限（nvn_mtl.m prepare_max_ms，11-06 维护者 放宽到 30 秒）
static double page_cap_s(void) { return env_s("S2A_LOAD_MAX_S", prepare_cap_s()); }   // 页面到点进游戏的上限（同一个数：剩余时间也按它封顶）
int s2a_load_warm_tick(uint64_t now, long done, long total) {
    // 全部编完（直连层保证 (total, total) 只发一次：首帧前编完，或先进了游戏、后台编完时）：管线已进系统缓存，记本包已完整预热
    if (total > 0 && done >= total) mark_warm_done();
    pthread_mutex_lock(&g_mu);
    if (g_stage >= S2A_LOAD_ENTER) { pthread_mutex_unlock(&g_mu); return 0; }   // 已在进游戏 / 页面已收起：后台那次完成通知只记标记，不动阶段
    if (g_stage == S2A_LOAD_DATA) { g_stage = S2A_LOAD_OPTIMIZE; g_warm_t0 = g_last_up = g_rate_t = now; g_rate_done = done; }
    if (total > 0) g_total = total;
    if (done > g_done) { g_done = done; g_last_up = now; }
    if (now - g_rate_t >= S) {   // 1 秒窗口的速率，指数平滑（新窗口占 0.3）
        double r = (double)(g_done - g_rate_done) / ((double)(now - g_rate_t) / S);
        g_rate = g_rate > 0 ? 0.7 * g_rate + 0.3 * r : r; g_rate_t = now; g_rate_done = g_done;
    }
    int go = 0;
    // 编完按这一 tick 自己的参数判（done ≥ total）：直连层开头的 (0, n) 一定 n > 0（warm_announce / warm_prepare 只在有条目时发），done ≥ total 只出现在完成那一下——
    //   包括没有可预热的条目时的 (0, 0)（11-02 维护者 魔界战记5 首启：后台预热 0 条、0.6 ms 就收尾发了 (0, 0)，原先按「g_total 非 0」判，0 条永远不算编完，
    //   阶段停在「优化画面」、首帧来了也只记不收，之后再没有 tick、30 秒无进展护栏也跑不到，页面「已优化 0 / 0」卡死）
    if (done >= total) { g_go = S2A_LOAD_GO_DONE; go = 1; }
    else if (atomic_load(&g_skip)) { g_go = S2A_LOAD_GO_USER; go = 1; }
    else if (now - g_last_up >= (uint64_t)(env_s("S2A_LOAD_STALL_S", 30) * S)) { g_go = S2A_LOAD_GO_STALL; go = 1; }
    // 上限缺省跟直连层的首帧上限一致（DM_PSO_PREPARE_MAX_MS，缺省 30 秒；11-06 维护者：15 秒冷装编不完，放宽到 30 秒，8 秒后可「先开始玩」照旧）：11-06 马车8 测试设备1，直连层 15 秒放行、转后台后不再报进度，页面这道上限原先缺省 600 秒，
    //   页面停在「为你的设备优化画面 已优化 18,205 / 19,077」直到首帧（18.3 秒），维护者 看到的是卡住。到点页面自己转「正在进入游戏，剩余的优化在后台继续」
    else if (now - g_warm_t0 >= (uint64_t)(page_cap_s() * S)) { g_go = S2A_LOAD_GO_MAX; go = 1; }
    if (go) g_stage = g_ff ? S2A_LOAD_DONE : S2A_LOAD_ENTER;   // 首帧早已到过（直连层先过首帧回调、后在首次提交里等预热）：预热一结束就收页
    int reason = g_go; long d = g_done, t = g_total;
    pthread_mutex_unlock(&g_mu);
    if (go && reason != S2A_LOAD_GO_DONE)
        LOG("加载页：不再等预热（%s），已编 %ld / %ld，剩下的转后台", reason == S2A_LOAD_GO_USER ? "玩家点了先开始玩" : reason == S2A_LOAD_GO_STALL ? "长时间没有进展" : "超过宽松上限", d, t);
    return go && reason != S2A_LOAD_GO_DONE ? 1 : 0;   // 全部编完：直连层自己正常收尾（返回 0 不转后台）
}

static void docs_path(char *out, size_t n, const char *name) {
    s2a_docs_path(out, n, "wire%s%s", name ? "/" : "", name ? name : "");
}
int s2a_load_first_run(const char *pack) {
    snprintf(g_pack, sizeof g_pack, "%s", pack && *pack ? pack : "-");
    char p[1200], w[64] = ""; docs_path(p, sizeof p, "warm_done");
    FILE *f = fopen(p, "r"); if (!f) return 1;
    int ok = fgets(w, sizeof w, f) != NULL; fclose(f);
    w[strcspn(w, " \t\r\n")] = 0;
    return !(ok && !strcmp(w, g_pack) && strcmp(g_pack, "-"));
}
// 首帧回调（ap_host.c s2a_frame_presented）在直连层首次提交之前就来了，预热等待发生在首次提交里：此时还在「优化画面」= 屏上其实没有画面，
//   页面不收、只记首帧已到，等预热结束（全部编完或不再等）再收。10-30 真机怪猎崛起冷首启：首帧回调 0.96 秒就收了页，之后预热等了 15 秒黑屏
void s2a_load_first_frame(uint64_t now) {
    (void)now;
    pthread_mutex_lock(&g_mu);
    if (g_stage == S2A_LOAD_OPTIMIZE) g_ff = 1; else g_stage = S2A_LOAD_DONE;
    pthread_mutex_unlock(&g_mu);
}
static void mark_warm_done(void) {
    static _Atomic int done; if (atomic_exchange(&done, 1) || !strcmp(g_pack, "-") || !g_pack[0]) return;
    char d[1200], p[1300], t[1400]; docs_path(d, sizeof d, NULL);
    if (mkdir(d, 0755) && errno != EEXIST) return;
    snprintf(p, sizeof p, "%s/warm_done", d); snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w"); if (!f) return;
    fprintf(f, "%s\n", g_pack);
    if (fclose(f) || rename(t, p)) LOG("【红】加载页：写 %s 失败（errno %d）", p, errno);
    else LOG("加载页：本包预热已全部编完，之后的启动只显示简短启动画面");
}

void s2a_load_snapshot(uint64_t now, s2a_load_view *v) {
    pthread_mutex_lock(&g_mu);
    v->stage = g_stage; v->first_run = g_first_run; v->done = g_done; v->total = g_total; v->go_reason = g_go;
    // 进度：准备数据 0–5%（按 10 秒渐近，不到 5%）、优化画面 5–95%（已编 / 总数）、进入游戏 95–100%
    double f = g_stage == S2A_LOAD_DATA ? 0.05 * (1.0 - 1.0 / (1.0 + (double)(now - g_t0) / (10.0 * S)))
             : g_stage == S2A_LOAD_OPTIMIZE ? 0.05 + 0.90 * (g_total ? (double)g_done / (double)g_total : 0)
             : g_stage == S2A_LOAD_ENTER ? 0.95 : 1.0;
    if (f > g_frac) g_frac = f;
    v->frac = g_frac;
    // 剩余时间：只在优化画面段、测了 ≥ 2 秒且速率 > 0 时给
    v->eta_s = -1;
    if (g_stage == S2A_LOAD_OPTIMIZE && g_rate > 0 && now - g_warm_t0 >= 2 * S && g_total > g_done) {
        double est = (double)(g_total - g_done) / g_rate;
        if (g_eta_shown < 0) g_eta_shown = est;
        else {
            double down = g_eta_shown - (double)(now - g_eta_t) / S;   // 按流逝时间往下走
            if (down < 0) down = 0;
            if (est > g_eta_shown * 1.25) { if (!g_slow_since) g_slow_since = now; }   // 实测变慢
            else g_slow_since = 0;
            g_eta_shown = g_slow_since && now - g_slow_since >= 3 * S ? est : (est < down ? est : down);
            if (g_slow_since && now - g_slow_since >= 3 * S) g_slow_since = 0;
        }
        g_eta_t = now;
        // 页面到上限就进游戏（剩下的转后台）：剩余时间不超过离上限还剩的秒数（11-06 维护者：原先冷装估算四五十秒、15 秒就进了游戏，显示的数对不上）
        double cap_left = page_cap_s() - (double)(now - g_warm_t0) / S;
        if (cap_left < 0) cap_left = 0;
        double shown = g_eta_shown < cap_left ? g_eta_shown : cap_left;
        v->eta_s = (int)(shown + 0.999);
    }
    v->can_skip = g_stage == S2A_LOAD_OPTIMIZE && g_first_run && now - g_warm_t0 >= (uint64_t)(env_s("S2A_LOAD_SKIP_S", 8) * S) && !(v->eta_s >= 0 && v->eta_s < 5) && !atomic_load(&g_skip);
    pthread_mutex_unlock(&g_mu);
}

void s2a_load_eta_text(int s, char *out, size_t n) {
    // 11-10 英文默认（S2A_TR）：加载页外面再套「剩余%@」/「%@ left」（ios/loadpage.m loadpage.eta）
    if (s < 0) snprintf(out, n, "%s", S2A_TR("Estimating time left", "正在估算剩余时间"));
    else if (s < 5) snprintf(out, n, "%s", S2A_TR("Under 5 s", "不到 5 秒"));
    else if (s < 60) snprintf(out, n, S2A_TR("%d s", "%d 秒"), s);   // 逐秒倒数（11-06 维护者：原先按 5 秒一档取整，看着像写死的）
    else if (s % 60) snprintf(out, n, S2A_TR("%d min %d s", "%d 分 %d 秒"), s / 60, s % 60);
    else snprintf(out, n, S2A_TR("%d min", "%d 分钟"), s / 60);
}

// 没有加载页前端（没调过 s2a_load_begin：Mac / 安卓宿主）回 -1：直连层用自己的护栏（DM_PSO_PREPARE_STALL_MS / DM_PSO_PREPARE_MAX_MS），同弱定义
int s2a_front_warm_tick(long done, long total) { return atomic_load(&g_begun) ? s2a_load_warm_tick(now_ns(), done, total) : -1; }
void s2a_front_warm_released(void) {
    if (!atomic_load(&g_begun)) return;
    pthread_mutex_lock(&g_mu);
    int go = g_stage < S2A_LOAD_ENTER; long d = g_done, t = g_total;
    if (go) { g_go = S2A_LOAD_GO_HOST; g_stage = g_ff ? S2A_LOAD_DONE : S2A_LOAD_ENTER; }
    pthread_mutex_unlock(&g_mu);
    if (go) LOG("加载页：直连层已放行（清单全部领走只剩在编的几条，或到上限），已编 %ld / %ld，剩下的转后台", d, t);
}
