// 档位梯子·宿主侧（判定在 qladder.c，单测 runtime/tests/t_qladder.c）：直连上屏每帧经 s2a_qp_frame（runtime/src/qprompt_host.c）调 s2a_ql_host_frame。
//   梯子种类按本局运行时状态定（不查按款表）：有真帧率来源（帧率表 / 社区补丁，s2a_fps_real_source）且 60 帧开关开着 = 原生 30 帧靠补丁 → 三档；否则两档（帧率归游戏）。
//   档位记忆：<Documents>/ladder.txt 一行「kind=<1|2> tier=<n>」，一款一个 App、一台机一个容器 = 自然按机按款；首次从最高档起。
//     起局（s2a_ql_boot，早于服务层 / 宽屏装表读 S2A_DOCKED）按记下的档设 S2A_DOCKED；60 帧那半在第一帧按档压回 / 放开（s2a_fps_hold，热切）。
//   换档执行：60 帧当场热切（s2a_fps_hold）；主机 / 掌机能热切就当场切（s2a_console_mode_set → 服务层 ChangeDockedModeState），
//     宽屏第二层（游戏代码补丁，按起局档位装的表）在生效的款切档只记下、下次启动生效（局中换档补丁还是旧档位的），给玩家一行提示。
//   开关：S2A_LADDER=0 关；自动化局（s2a_unattended）缺省关、S2A_LADDER=1 才开（普查 / 测量局要固定档位）。
#include "native.h"
#include "s2a_qladder.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include "s2a_unattended.h"
#include "s2a_ui_lang.h"   // 上屏话术英文默认（S2A_TR）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int s2a_fps_real_source(void); int s2a_fps_enabled(void); void s2a_fps_hold(int hold); int s2a_widen_game(void);
void s2a_console_mode_set(int docked); int s2a_console_mode(void);
__attribute__((weak)) double s2a_gpu_busy_ms(void) { return -1; }   // 直连层 graphics/nvn hle_nvn.c 强定义
__attribute__((weak)) int dm_thermal_now(void) { return -1; }        // iOS ios/app.m、Mac runtime/src/host_main.c 强定义
__attribute__((weak)) void s2a_ios_ladder_note(const char *msg) { (void)msg; }   // iOS 横幅（ios/app.m）；Mac / 单测没有界面

static int g_on = -1, g_kind0, g_tier0 = -1;   // g_kind0 / g_tier0：ladder.txt 里记的（-1 = 没记过）
static char g_path[1100];
static int ladder_on(void) {
    if (g_on < 0) { const char *e = getenv("S2A_LADDER"); g_on = e && *e ? strcmp(e, "0") != 0 : !s2a_unattended(); }
    return g_on;
}
static void save(int kind, int tier) {
    if (!g_path[0]) return;
    char tmp[1200]; snprintf(tmp, sizeof tmp, "%s.tmp", g_path);
    FILE *f = fopen(tmp, "w"); if (!f) { LOG("【红】档位梯子：记不下档位（%s 打不开）", tmp); return; }
    fprintf(f, "kind=%d tier=%d\n", kind, tier); fclose(f);
    if (rename(tmp, g_path)) LOG("【红】档位梯子：记不下档位（改名失败）");
}
// 起局（host_main.c host_run 开头，早于 iOS 画面设置注入、服务层与宽屏装表读 S2A_DOCKED）：读记下的档，按它设起局档位。
//   启动环境显式给的 S2A_DOCKED 优先（测量局固定档位）
void s2a_ql_boot(void) {
    if (!ladder_on()) return;
    s2a_docs_path(g_path, sizeof g_path, "ladder.txt");
    FILE *f = fopen(g_path, "r"); int k = 0, t = -1;
    if (f) { if (fscanf(f, "kind=%d tier=%d", &k, &t) != 2) k = 0, t = -1; fclose(f); }
    if ((k == S2A_QL_FPS && t >= 0 && t <= 2) || (k == S2A_QL_MODE && t >= 0 && t <= 1)) { g_kind0 = k; g_tier0 = t; }
    if (getenv("S2A_DOCKED")) return;
    int docked = g_tier0 < 0 ? 1 : (g_kind0 == S2A_QL_FPS ? g_tier0 < 2 : g_tier0 == 0);   // 首次：最高档 = 主机
    setenv("S2A_DOCKED", docked ? "1" : "0", 1);
}
static const char *tier_name(int kind, int t) {
    static const char *f[] = {"主机 60 帧", "主机 30 帧", "掌机 30 帧"}, *m[] = {"主机", "掌机"};
    return kind == S2A_QL_FPS ? f[t < 0 ? 0 : t > 2 ? 2 : t] : m[t < 0 ? 0 : t > 1 ? 1 : t];
}
static int g_kind, g_ready, g_pend_docked = -1;
static void apply(int t, int boot) {
    if (g_kind == S2A_QL_FPS) s2a_fps_hold(!s2a_ql_fps60(t));
    int want = s2a_ql_docked(t), cur = s2a_console_mode(); if (cur < 0) { const char *d = getenv("S2A_DOCKED"); cur = d && !strcmp(d, "1"); }
    if (want == cur) { g_pend_docked = -1; return; }
    if (boot) return;   // 起局档位已在构造期设好；对不上（启动环境显式给了）就按启动环境，不改
    if (s2a_widen_game()) { g_pend_docked = want;   // 宽屏第二层按起局档位装的表：局中切档补丁对不上，下次启动生效
        LOG("档位梯子：%s 要切到%s，本款宽屏第二层按起局档位装表，下次启动生效", tier_name(g_kind, t), want ? "主机" : "掌机");
        if (!s2a_unattended()) s2a_ios_ladder_note(want ? S2A_TR("Graphics level raised; takes effect the next time you start the game", "画面档位已调高，下次启动游戏生效") : S2A_TR("Switched to handheld mode to keep things smooth; takes effect the next time you start the game", "已调到掌机档以保持流畅，下次启动游戏生效"));
        return; }
    s2a_console_mode_set(want); g_pend_docked = -1;
}
// 每次上屏（qprompt_host.c s2a_qp_frame）调：game = 这一帧是局内游戏画面（s2a_qp_game）；dt 与上一帧间隔；game_itv 游戏自设交换间隔
void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv) {
    if (!ladder_on()) return;
    if (!g_ready) { g_ready = 1;
        g_kind = s2a_fps_real_source() && s2a_fps_enabled() ? S2A_QL_FPS : S2A_QL_MODE;
        int t = g_tier0 >= 0 && g_kind0 == g_kind ? g_tier0 : 0;
        s2a_ql_setup(g_kind, t); apply(t, 1);
        LOG("档位梯子：%s，起始档 %s（%s）", g_kind == S2A_QL_FPS ? "三档（主机60 → 主机30 → 掌机30，本款靠 60 帧补丁）" : "两档（主机 → 掌机，帧率归游戏）",
            tier_name(g_kind, t), g_tier0 >= 0 && g_kind0 == g_kind ? "上次稳定档" : "首次，从最高档起");
    }
    int t = s2a_ql_frame(now, game, dt, s2a_gpu_busy_ms(), dm_thermal_now(), game_itv);
    if (s2a_ql_stable_now()) { save(g_kind, s2a_ql_tier()); LOG("档位梯子：%s 稳住 2 分钟，记成本机本款的最后稳定档", tier_name(g_kind, s2a_ql_tier())); }
    if (t < 0) return;
    double fps, slow, gpu; int th; s2a_ql_last(&fps, &slow, &gpu, &th); int why = s2a_ql_why();
    LOG("档位梯子：换到 %s（%s；上个窗口 %.1f 帧/秒、慢帧 %.1f%%、GPU 忙 %.0f%%、热状态 %d）", tier_name(g_kind, t),
        why == S2A_QL_WHY_HOT ? "热状态危急，安全阀强降" : why == S2A_QL_WHY_FPS ? "局内帧率达不到本档目标" : "余量够、凉下来 2 分钟，升一档", fps, slow, gpu, th);
    if (why != S2A_QL_WHY_UP) save(g_kind, t);   // 降档立刻记（上一档不稳）；升档等稳住 2 分钟再记
    apply(t, 0);
}
int s2a_ql_host_on(void) { return ladder_on(); }
