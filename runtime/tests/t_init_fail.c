// 初启失败出口单测（runtime/include/s2a_init_fail.h，审计 #1534 P1-4 做法 B）：期望值按方案「验证判据」四格表手写，不取被测实现的输出。
//   四格：(iOS, 人手) → 提示页；(iOS, 自动化) / (Mac, 人手) / (Mac, 自动化) → 失败退出。自动化 = S2A_AUTOPLAY 非空且不为 "0"（s2a_unattended.h）。
//   负对照：把 s2a_init_fail_action 换回旧行为（无条件退出），第 1 例应红。
//   诊断文本：失败摘要 / 错误码 / 构建号 / 翻译链 + host.log 最近 8 条红行（按先后），日志末尾截断时丢掉不完整的第一行。
//   上屏与诊断分开（11-02 维护者 内部词不上屏）：每个错误码的上屏正文 = 手写的玩家话术一句 + 下一步，不含内部词表里任何一个；
//   内部摘要只在诊断里。负对照：把 s2a_init_fail_screen 换回旧逻辑（上屏「原因：<内部摘要>」），上屏用例应红。
#include "s2a_init_fail.h"
#include "s2a_ui_lang.h"
#include "s2a_unattended.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fails, cases;
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); ok = 0; } } while (0)
#define CASE(name, ...) do { int ok = 1; cases++; __VA_ARGS__; if (ok) printf("  ✓ %s\n", name); else { fails++; printf("✗ %s\n", name); } } while (0)

// 按环境变量算出「是不是自动化局」再判，和 host_main.c failed_session 同一条调用
static int act_env(int is_ios, const char *autoplay) {
    if (autoplay) setenv("S2A_AUTOPLAY", autoplay, 1); else unsetenv("S2A_AUTOPLAY");
    return s2a_init_fail_action(is_ios, s2a_unattended());
}
static int count(const char *s, const char *sub) { int n = 0; for (const char *p = s; (p = strstr(p, sub)); p += strlen(sub)) n++; return n; }

// 内部词表：开发侧用语，玩家看不懂、不该上屏（失败摘要里的词 + 诊断栏目名 + 日志 / 环境变量写法）
static const char *const k_internal[] = {"服务", "会话", "初始化", "线程", "安全网", "直连", "发布", "失败摘要", "错误码", "构建号", "翻译链", "初启", "未登记",
                                         "S2A_", "host.log", "【红】", "unknown", "_"};
static int has_internal(const char *s) { for (size_t i = 0; i < sizeof k_internal / sizeof *k_internal; i++) if (strstr(s, k_internal[i])) return 1; return 0; }
// host_main.c failed_session 的调用点 + 码表外：期望的码 id / 内部摘要 / 玩家话术按需求手写，不取被测实现
static const struct { int code; const char *id, *summary, *msg; } k_want[] = {
    {S2A_INIT_FAIL_E_SESSION_CTRL, "session_ctrl", "会话控制线程不可用", "本 App 没能准备好运行游戏。"},
    {S2A_INIT_FAIL_E_SERVICE_INIT, "service_init", "服务会话初始化失败", "游戏需要的系统功能没能准备好。"},
    {S2A_INIT_FAIL_E_GAME_THREAD, "game_thread", "游戏主线程启动失败或会话已失败", "游戏程序没能开始运行。"},
    {S2A_INIT_FAIL_E_SERVICE_EARLY, "service_early", "服务失败早于初启成功发布", "游戏需要的系统功能没能准备好。"},
    {S2A_INIT_FAIL_E_DGUARD_LIMIT, "dguard_limit", "直连安全网：此前已连续失败满 3 次，自动化局不停在提示页，收局（重新出包后从 0 数）", "启动过程中出了问题。"},
    {S2A_INIT_FAIL_E_GAME_FILES, "game_files_missing", "服务会话初始化失败：资源包里没有 exefs/main.npdm（游戏文件不在机上 / 没导完）",
     "游戏文件缺失，请重新导入：在 Mac 上的 S2Arm 里对这款游戏再点一次「装到 iPhone」。"},
    {S2A_INIT_FAIL_E_DIRECT_LIB, "direct_lib_missing", "包里没有本宿主口径的直连着色器库（没导完 / 旧版本出的包 / 设备跑不了直连；只有直连，11-07 拆通用模式后不再退通用）",
     "游戏文件缺失，请重新导入：在 Mac 上的 S2Arm 里对这款游戏再点一次「装到 iPhone」。"},
    {S2A_INIT_FAIL_E_UNKNOWN, "unknown", "未登记的初启失败", "启动过程中出了问题。"},
    {999, "unknown", "未登记的初启失败", "启动过程中出了问题。"},
    {-1, "unknown", "未登记的初启失败", "启动过程中出了问题。"},
};
#define NEXT_WANT "请从后台划掉本 App 再打开；仍不行请点「复制诊断」把诊断发给我们。"

int main(void) {
    s2a_ui_zh = 1;   // 下面的中文期望按中文界面（英文缺省另有一例）
    CASE("四格 1：iOS 人手局（没有 S2A_AUTOPLAY）→ 提示页", {
        WANT(s2a_init_fail_action(1, 0) == S2A_INIT_FAIL_PAGE);
        WANT(act_env(1, NULL) == S2A_INIT_FAIL_PAGE); WANT(act_env(1, "0") == S2A_INIT_FAIL_PAGE); WANT(act_env(1, "") == S2A_INIT_FAIL_PAGE); });
    CASE("四格 2：iOS 自动化局（dev_run 带 S2A_AUTOPLAY=1）→ 失败退出", {
        WANT(s2a_init_fail_action(1, 1) == S2A_INIT_FAIL_EXIT); WANT(act_env(1, "1") == S2A_INIT_FAIL_EXIT); });
    CASE("四格 3：Mac 人手局 → 失败退出", {
        WANT(s2a_init_fail_action(0, 0) == S2A_INIT_FAIL_EXIT); WANT(act_env(0, NULL) == S2A_INIT_FAIL_EXIT); });
    CASE("四格 4：Mac 自动化局 → 失败退出", {
        WANT(s2a_init_fail_action(0, 1) == S2A_INIT_FAIL_EXIT); WANT(act_env(0, "1") == S2A_INIT_FAIL_EXIT); });

    for (size_t i = 0; i < sizeof k_want / sizeof *k_want; i++) {
        char name[160]; snprintf(name, sizeof name, "上屏（码 %d → %s）：玩家话术 + 下一步，不含内部词、不含内部摘要", k_want[i].code, k_want[i].id);
        CASE(name, {
            char b[1024], want[1024]; size_t n = s2a_init_fail_screen(b, sizeof b, k_want[i].code);
            snprintf(want, sizeof want, "%s\n%s", k_want[i].msg, NEXT_WANT);
            WANT(n == strlen(b)); WANT(!strcmp(b, want)); WANT(!has_internal(b)); WANT(!strstr(b, k_want[i].summary)); });
        snprintf(name, sizeof name, "诊断（码 %d → %s）：带内部摘要与码 id", k_want[i].code, k_want[i].id);
        CASE(name, {
            char b[1024], want[1024]; s2a_init_fail_diag(b, sizeof b, k_want[i].code, "B1", "C1", NULL, 0);
            snprintf(want, sizeof want, "S2Arm 初启失败\n失败摘要：%s\n错误码：%s\n主程序构建号：B1\n翻译链：C1\n最近的红行：无\n", k_want[i].summary, k_want[i].id);
            WANT(!strcmp(b, want)); WANT(!strcmp(s2a_init_fail_code_id(k_want[i].code), k_want[i].id));
            WANT(!strcmp(s2a_init_fail_summary(k_want[i].code), k_want[i].summary)); });
    }
    CASE("上屏：放不下就截断，仍以 0 结尾、返回实际长度", {
        char b[16]; memset(b, 'Z', sizeof b); size_t n = s2a_init_fail_screen(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT);
        WANT(n == 15); WANT(b[15] == 0); WANT(strlen(b) == 15); });
    CASE("诊断：没有日志 → 摘要 / 码 id / 构建号 / 翻译链齐、红行写「无」", {
        char b[1024]; size_t n = s2a_init_fail_diag(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT, "B1", "C1", NULL, 0);
        WANT(n == strlen(b));
        WANT(!strcmp(b, "S2Arm 初启失败\n失败摘要：服务会话初始化失败\n错误码：service_init\n主程序构建号：B1\n翻译链：C1\n最近的红行：无\n")); });
    CASE("诊断：10 条红行夹普通行 → 只留最后 8 条（3..10）、按先后、不带普通行", {
        char log[4096] = "", b[4096];
        for (int i = 1; i <= 10; i++) { char l[96]; snprintf(l, sizeof l, "[s2a] 普通 %d\n[s2a] 【红】 R%02d\n", i, i); strcat(log, l); }
        s2a_init_fail_diag(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT, "B", "C", log, strlen(log));
        WANT(strstr(b, "最近的红行（host.log，8 条）：\n[s2a] 【红】 R03\n[s2a] 【红】 R04\n"));
        WANT(strstr(b, "[s2a] 【红】 R09\n[s2a] 【红】 R10\n"));
        WANT(!strstr(b, "R01")); WANT(!strstr(b, "R02")); WANT(!strstr(b, "普通")); WANT(count(b, "【红】") == 8); });
    CASE("诊断：最后一行没有换行也算", {
        const char *log = "a\n[s2a] 【红】 尾行"; char b[512];
        s2a_init_fail_diag(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT, "B", "C", log, strlen(log));
        WANT(strstr(b, "（host.log，1 条）：\n[s2a] 【红】 尾行\n")); });
    CASE("诊断：缓冲放不下就截断，仍以 0 结尾、返回实际长度", {
        char b[32]; memset(b, 'Z', sizeof b);
        size_t n = s2a_init_fail_diag(b, sizeof b, S2A_INIT_FAIL_E_DGUARD_LIMIT, "B", "C", NULL, 0);
        WANT(n == 31); WANT(b[31] == 0); WANT(strlen(b) == 31); });
    CASE("诊断文件：只看末尾 64 KB，截开的第一行丢掉（标记在截点之后也不算）", {
        char path[] = "/tmp/t_init_fail.XXXXXX"; int fd = mkstemp(path); FILE *f = fdopen(fd, "w");
        // 第一行 200 字节：前 150 字节填充、之后是红标记；截点落在第 100 字节 → 截出的残行带着红标记，必须丢掉
        fprintf(f, "%s【红】 OLD-HEAD\n", "####################################################################################################"
                                            "##################################################");
        long head = ftell(f); long total = S2A_INIT_FAIL_LOG_TAIL + 100;
        const char *last = "[s2a] 【红】 LAST\n"; long fill = total - head - (long)strlen(last);
        for (long i = 0; i < fill - 1; i++) fputc('.', f);
        fputc('\n', f); fputs(last, f); fclose(f);
        char b[2048]; s2a_init_fail_diag_file(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT, "B", "C", path); unlink(path);
        WANT(strstr(b, "（host.log，1 条）：\n[s2a] 【红】 LAST\n")); WANT(!strstr(b, "OLD-HEAD")); });
    CASE("诊断文件：不到 64 KB 全读、第一行保留", {
        char path[] = "/tmp/t_init_fail.XXXXXX"; int fd = mkstemp(path); FILE *f = fdopen(fd, "w");
        fputs("[s2a] 【红】 FIRST\nok\n", f); fclose(f);
        char b[512]; s2a_init_fail_diag_file(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT, "B", "C", path); unlink(path);
        WANT(strstr(b, "（host.log，1 条）：\n[s2a] 【红】 FIRST\n")); });
    CASE("诊断文件：读不到 → 按没有红行写", {
        char b[512]; s2a_init_fail_diag_file(b, sizeof b, S2A_INIT_FAIL_E_SERVICE_INIT, "B", "C", "/nonexistent/host.log");
        WANT(strstr(b, "失败摘要：服务会话初始化失败\n")); WANT(strstr(b, "最近的红行：无\n")); });

    CASE("服务会话初始化失败归码（11-07 Duo）：资源包没有 exefs/main.npdm → game_files_missing；有 → service_init；没给资源包根 → service_init", {
        char d[] = "/tmp/t_init_fail_gd.XXXXXX"; WANT(mkdtemp(d) != NULL);
        WANT(s2a_init_fail_service_code(d) == S2A_INIT_FAIL_E_GAME_FILES);            // 资源包根在、exefs 不在（Duo 日志的 DirectoryNotFound）
        char p[256]; snprintf(p, sizeof p, "%s/exefs", d); WANT(!mkdir(p, 0755));
        WANT(s2a_init_fail_service_code(d) == S2A_INIT_FAIL_E_GAME_FILES);            // exefs 在、main.npdm 不在
        snprintf(p, sizeof p, "%s/exefs/main.npdm", d); FILE *f = fopen(p, "w"); WANT(f != NULL); if (f) fclose(f);
        WANT(s2a_init_fail_service_code(d) == S2A_INIT_FAIL_E_SERVICE_INIT);          // 游戏文件在：是别的原因
        WANT(s2a_init_fail_service_code("/nonexistent/资源包") == S2A_INIT_FAIL_E_GAME_FILES);
        WANT(s2a_init_fail_service_code(NULL) == S2A_INIT_FAIL_E_SERVICE_INIT); WANT(s2a_init_fail_service_code("") == S2A_INIT_FAIL_E_SERVICE_INIT);
        unlink(p); snprintf(p, sizeof p, "%s/exefs", d); rmdir(p); rmdir(d);
        char b[512]; s2a_init_fail_screen(b, sizeof b, S2A_INIT_FAIL_E_GAME_FILES);
        WANT(!strcmp(b, "游戏文件缺失，请重新导入：在 Mac 上的 S2Arm 里对这款游戏再点一次「装到 iPhone」。\n" NEXT_WANT)); });
    CASE("上屏英文（11-10 英文默认：界面语言不是中文）：英文话术 + 英文下一步，与规格 en 逐字", {
        s2a_ui_zh = 0; char b[512]; s2a_init_fail_screen(b, sizeof b, S2A_INIT_FAIL_E_GAME_FILES);
        WANT(!strcmp(b, "Game files are missing. Import them again: in S2Arm on your Mac, choose “Install on iPhone” for this game again.\n"
                        "Swipe this app away in the app switcher and open it again. If it still fails, tap “Copy diagnostics” and send it to us."));
        s2a_init_fail_screen(b, sizeof b, 999); WANT(!strncmp(b, "Something went wrong during startup.\n", 37)); s2a_ui_zh = 1; });

    if (fails) { printf("✗ t_init_fail：%d / %d 例不通\n", fails, cases); return 1; }
    printf("✓ t_init_fail：%d 例全过\n", cases); return 0;
}
