// 加载页进度模型单测（runtime/include/s2a_loadprog.h）：期望值按口径手算。每例 fork 一个子进程（模型的静态量从零开始），S2A_DOCS 指临时目录。
#include "../src/native.h"
#include "s2a_ui_lang.h"
#include "s2a_loadprog.h"
#include <sys/wait.h>
#include <unistd.h>

#define S 1000000000ull
uint64_t now_ns(void) { return 0; }
static int fails;
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); _exit(1); } } while (0)
#define CASE(name, body) do { char d[] = "/tmp/t_loadprog.XXXXXX"; if (!mkdtemp(d)) return 1; setenv("S2A_DOCS", d, 1); \
    pid_t p = fork(); if (!p) { body; _exit(0); } int st; waitpid(p, &st, 0); \
    if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("✗ %s\n", name); } else printf("  ✓ %s\n", name); } while (0)
static s2a_load_view V(uint64_t t) { s2a_load_view v; s2a_load_snapshot(t, &v); return v; }
static int eq(int s, const char *want) { char b[64]; s2a_load_eta_text(s, b, sizeof b); return !strcmp(b, want); }

int main(void) {
    unsetenv("S2A_LOAD_SKIP_S"); unsetenv("S2A_LOAD_STALL_S"); unsetenv("S2A_LOAD_MAX_S");
    CASE("剩余时间文案逐秒：-1 估算中、3 不到 5 秒、42 → 42 秒、61 → 1 分 1 秒、80 → 1 分 20 秒、120 → 2 分钟", {
        s2a_ui_zh = 1;   // 界面语言中文
        WANT(eq(-1, "正在估算剩余时间")); WANT(eq(3, "不到 5 秒")); WANT(eq(42, "42 秒")); WANT(eq(61, "1 分 1 秒"));
        WANT(eq(80, "1 分 20 秒")); WANT(eq(120, "2 分钟"));
        s2a_ui_zh = 0;   // 缺省英文（11-10）
        WANT(eq(-1, "Estimating time left")); WANT(eq(3, "Under 5 s")); WANT(eq(42, "42 s")); WANT(eq(61, "1 min 1 s"));
        WANT(eq(80, "1 min 20 s")); WANT(eq(120, "2 min")); });
    CASE("阶段：起局 = 准备数据，第一次 tick = 优化画面，编完 = 进入游戏，首帧 = 收起", {
        s2a_load_begin(0, 1); WANT(V(1 * S).stage == S2A_LOAD_DATA);
        WANT(s2a_load_warm_tick(2 * S, 0, 100) == 0); WANT(V(2 * S).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(3 * S, 100, 100) == 0); { s2a_load_view v = V(3 * S); WANT(v.stage == S2A_LOAD_ENTER && v.go_reason == S2A_LOAD_GO_DONE); }
        s2a_load_first_frame(4 * S); WANT(V(4 * S).stage == S2A_LOAD_DONE && V(4 * S).frac == 1.0); });
    CASE("首帧回调先于预热结束（直连层首次提交里等预热，10-30 真机冷首启黑屏 15 秒）：首帧时还在优化画面 → 不收页；编完那一 tick 直接收起；没预热的启动首帧照旧收起", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 100) == 0);
        s2a_load_first_frame(2 * S); WANT(V(2 * S).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(3 * S, 60, 100) == 0); WANT(V(3 * S).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(4 * S, 100, 100) == 0); WANT(V(4 * S).stage == S2A_LOAD_DONE);
        s2a_load_begin(10 * S, 1); s2a_load_first_frame(11 * S); WANT(V(11 * S).stage == S2A_LOAD_DONE); });
    CASE("没有可预热的条目（11-02 魔界战记5 首启卡在「已优化 0 / 0」）：完成 tick (0, 0) 先到 → 进入游戏，首帧 → 收起；首帧先到 → 收起，之后 (0, 0) 不再动阶段", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 0) == 0); { s2a_load_view v = V(1 * S); WANT(v.stage == S2A_LOAD_ENTER && v.go_reason == S2A_LOAD_GO_DONE); }
        s2a_load_first_frame(2 * S); WANT(V(2 * S).stage == S2A_LOAD_DONE);
        s2a_load_begin(10 * S, 1); s2a_load_first_frame(11 * S); WANT(V(11 * S).stage == S2A_LOAD_DONE);
        WANT(s2a_load_warm_tick(12 * S, 0, 0) == 0); WANT(V(12 * S).stage == S2A_LOAD_DONE); });
    CASE("直连层自己放行（11-06：清单领完只剩在编的几条 / 到上限，s2a_front_warm_released）：优化画面中 → 进入游戏、原因 HOST；首帧已到过 → 直接收起；已进入游戏后再通知不动阶段", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 100) == 0);
        s2a_front_warm_released(); { s2a_load_view v = V(2 * S); WANT(v.stage == S2A_LOAD_ENTER && v.go_reason == S2A_LOAD_GO_HOST); }
        s2a_front_warm_released(); WANT(V(2 * S).stage == S2A_LOAD_ENTER && V(2 * S).go_reason == S2A_LOAD_GO_HOST);
        s2a_load_first_frame(3 * S); WANT(V(3 * S).stage == S2A_LOAD_DONE);
        s2a_load_begin(10 * S, 1); WANT(s2a_load_warm_tick(11 * S, 0, 100) == 0); s2a_load_first_frame(12 * S); WANT(V(12 * S).stage == S2A_LOAD_OPTIMIZE);
        s2a_front_warm_released(); WANT(V(13 * S).stage == S2A_LOAD_DONE); });
    CASE("首帧已到、玩家点了先开始玩：那一 tick 回 1（转后台）并直接收起", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 100) == 0); s2a_load_first_frame(2 * S);
        s2a_load_user_skip(); WANT(s2a_load_warm_tick(3 * S, 10, 100) == 1); { s2a_load_view v = V(3 * S); WANT(v.stage == S2A_LOAD_DONE && v.go_reason == S2A_LOAD_GO_USER); } });
    CASE("匀速 100 条 / 秒、共 1000：测满 2 秒前不给剩余时间；3 秒时 7 秒、4 秒时 6 秒", {
        s2a_load_begin(0, 1);
        for (uint64_t t = 0; t <= 4 * S; t += S / 2) { s2a_load_warm_tick(t, (long)(t / (S / 100)), 1000);
            if (t == S) WANT(V(t).eta_s == -1);
            if (t == 3 * S) WANT(V(t).eta_s == 7);
            if (t == 4 * S) WANT(V(t).eta_s == 6); } });
    CASE("变慢到 10 条 / 秒：头 3 秒显示值只往下走，持续 3 秒后按实测往上修正（≥ 15 秒）", {
        s2a_load_begin(0, 1); int last = -1;
        for (uint64_t t = 0; t <= 4 * S; t += S / 2) { s2a_load_warm_tick(t, (long)(t / (S / 100)), 1000); last = V(t).eta_s; }
        WANT(last == 6);
        long d = 400;
        for (uint64_t t = 4 * S + S / 2; t <= 7 * S; t += S / 2) { d += 5; s2a_load_warm_tick(t, d, 1000);
            if (t % S == 0) { int e = V(t).eta_s; WANT(e <= last); last = e; } }
        int up = 0; for (uint64_t t = 7 * S + S / 2; t <= 9 * S; t += S / 2) { d += 5; s2a_load_warm_tick(t, d, 1000); if (t % S == 0 && V(t).eta_s >= 15) up = 1; }
        WANT(up); });
    CASE("进度只进不退：每 0.5 秒取一次快照，frac 不降；三段边界 5% / 95% / 100%", {
        s2a_load_begin(0, 1); double prev = 0;
        for (uint64_t t = 0; t <= 3 * S; t += S / 2) { double f = V(t).frac; WANT(f >= prev && f < 0.05); prev = f; }
        for (uint64_t t = 3 * S; t <= 13 * S; t += S / 2) { s2a_load_warm_tick(t, (long)((t - 3 * S) / (S / 100)), 1000); double f = V(t).frac; WANT(f >= prev); prev = f; }
        WANT(prev > 0.94 && prev <= 0.95); s2a_load_first_frame(14 * S); WANT(V(14 * S).frac == 1.0); });
    CASE("先开始玩：预热 8 秒前不出、8 秒后出；点了下一次 tick 返回 1、原因 = 玩家；之后按钮收起", {
        s2a_load_begin(0, 1);
        for (uint64_t t = 0; t < 8 * S; t += S / 2) { s2a_load_warm_tick(t, (long)(t / (S / 10)), 1000); WANT(!V(t).can_skip); }
        s2a_load_warm_tick(8 * S, 80, 1000); WANT(V(8 * S).can_skip);
        s2a_load_user_skip(); WANT(s2a_load_warm_tick(8 * S + S / 20, 80, 1000) == 1);
        { s2a_load_view v = V(9 * S); WANT(v.go_reason == S2A_LOAD_GO_USER && v.stage == S2A_LOAD_ENTER && !v.can_skip); } });
    CASE("快编完（剩余不到 5 秒）不出「先开始玩」；之后的启动（非首次）也不出", {
        s2a_load_begin(0, 1);
        for (uint64_t t = 0; t <= 10 * S; t += S / 2) s2a_load_warm_tick(t, (long)(t / (S / 95)), 1000);   // 95 条 / 秒，10 秒时剩 50 条
        WANT(V(10 * S).eta_s < 5 && !V(10 * S).can_skip);
        s2a_load_begin(0, 0); for (uint64_t t = 0; t <= 10 * S; t += S / 2) s2a_load_warm_tick(t, (long)(t / (S / 10)), 1000);
        WANT(!V(10 * S).can_skip); });
    CASE("护栏：已编数 30 秒没涨 → 返回 1、原因 = 无进展；29.5 秒时还在等", { setenv("S2A_LOAD_MAX_S", "600", 1);   /* 本例只测无进展护栏：上限放宽（缺省已是 15 秒，见下例） */
        s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 1000); s2a_load_warm_tick(1 * S, 10, 1000);
        WANT(s2a_load_warm_tick(30 * S + S / 2, 10, 1000) == 0);
        WANT(s2a_load_warm_tick(31 * S, 10, 1000) == 1); WANT(V(31 * S).go_reason == S2A_LOAD_GO_STALL); });
    CASE("护栏：S2A_LOAD_MAX_S=20，一直有进展也在 20 秒进游戏、原因 = 上限；19.5 秒时还在等", {
        setenv("S2A_LOAD_MAX_S", "20", 1); s2a_load_begin(0, 1); int r = 0;
        for (uint64_t t = 0; t <= 19 * S + S / 2; t += S / 2) r |= s2a_load_warm_tick(t, (long)(t / (S / 10)), 100000);
        WANT(!r); WANT(s2a_load_warm_tick(20 * S, 200, 100000) == 1); WANT(V(20 * S).go_reason == S2A_LOAD_GO_MAX); });
    CASE("上限缺省 = 直连层首帧上限 30 秒（11-06 维护者 放宽，原 15 秒；11-06 马车8：页面原缺省 600 秒，直连层放行后页面停在优化画面）：一直有进展，29.5 秒还在等、30 秒进游戏、原因 = 上限；DM_PSO_PREPARE_MAX_MS=8000 时 8 秒", {
        unsetenv("S2A_LOAD_MAX_S"); unsetenv("DM_PSO_PREPARE_MAX_MS"); s2a_load_begin(0, 1); int r = 0;
        for (uint64_t t = 0; t <= 29 * S + S / 2; t += S / 2) r |= s2a_load_warm_tick(t, (long)(t / (S / 10)), 100000);
        WANT(!r); WANT(s2a_load_warm_tick(30 * S, 300, 100000) == 1); WANT(V(30 * S).go_reason == S2A_LOAD_GO_MAX);
        setenv("DM_PSO_PREPARE_MAX_MS", "8000", 1); s2a_load_begin(0, 1); r = 0;
        for (uint64_t t = 0; t <= 7 * S + S / 2; t += S / 2) r |= s2a_load_warm_tick(t, (long)(t / (S / 10)), 100000);
        WANT(!r); WANT(s2a_load_warm_tick(8 * S, 100, 100000) == 1); unsetenv("DM_PSO_PREPARE_MAX_MS"); });
    CASE("剩余时间按页面上限封顶、逐秒往下走（11-06 维护者：冷装按速率估要几千秒、页面 30 秒就进游戏，原先显示的数对不上）：10 条 / 秒、共 100000 条，第 10 秒显示 20、第 20 秒显示 10、第 25 秒显示 5", {
        unsetenv("S2A_LOAD_MAX_S"); unsetenv("DM_PSO_PREPARE_MAX_MS"); s2a_load_begin(0, 1); int e10 = -9; int e20 = -9; int e25 = -9;
        for (uint64_t t = 0; t <= 25 * S; t += S / 2) { s2a_load_warm_tick(t, (long)(t / (S / 10)), 100000);
            if (t == 10 * S) e10 = V(t).eta_s; if (t == 20 * S) e20 = V(t).eta_s; if (t == 25 * S) e25 = V(t).eta_s; }
        WANT(e10 == 20); WANT(e20 == 10); WANT(e25 == 5); });
    CASE("全部编完才进游戏：记下本包已完整预热，同包之后 = 非首次、换包 = 首次", {
        WANT(s2a_load_first_run("aaaa"));
        s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 10); WANT(s2a_load_warm_tick(S, 10, 10) == 0); s2a_load_first_frame(2 * S);
        WANT(!s2a_load_first_run("aaaa")); WANT(s2a_load_first_run("bbbb")); });
    CASE("先开始玩后后台编完：首帧后迟到的 (N, N) 也记标记、不动阶段、回 0；没编完（只跳过）不记", {
        WANT(s2a_load_first_run("bbbb"));
        s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 10); s2a_load_user_skip(); WANT(s2a_load_warm_tick(S, 3, 10) == 1); s2a_load_first_frame(2 * S);
        WANT(s2a_load_first_run("bbbb"));
        WANT(s2a_load_warm_tick(30 * S, 10, 10) == 0); WANT(V(30 * S).stage == S2A_LOAD_DONE); WANT(!s2a_load_first_run("bbbb")); });
    CASE("反证：没有出包指纹（\"-\"）永远算首次、也不记", {
        WANT(s2a_load_first_run("-")); s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 10); s2a_load_warm_tick(S, 10, 10); s2a_load_first_frame(2 * S);
        WANT(s2a_load_first_run("-")); });
    CASE("没有加载页前端（没调过 s2a_load_begin）：s2a_front_warm_tick 回 -1；调过之后回 0 / 1", {
        WANT(s2a_front_warm_tick(0, 10) == -1); s2a_load_begin(0, 1); WANT(s2a_front_warm_tick(0, 10) == 0); });
    if (fails) { printf("✗ t_loadprog：%d 例不通\n", fails); return 1; }
    printf("✓ t_loadprog：13 例全过\n"); return 0;
}
