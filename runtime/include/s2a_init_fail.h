// 初启失败的出口（审计 #1534 P1-4，做法 B，11-05 维护者定案）。实现 runtime/src/init_fail.c，调用方 runtime/src/host_main.c failed_session，iOS 页面 ios/app.m。
// 契约：初启失败 = 本进程终局。托管层（Exports.cs InitSession 进 try 前即标 Failed）、图形装配（Compose.cs 先标 Active 再建渲染器）、
//   原生会话（session.c 的 FAILED 是终态，prepare / restart 都拒）三层都按这一条设计，失败后不在同一进程里回收半建资源、不再起第二局；
//   新进程由系统整体收回内存、地址窗口、线程、GPU 对象，是唯一干净的重置。这里只决定「终局之后怎么让玩家知道」，不改任何生命周期状态。
// 出口分两种：
//   iOS 且不是自动化局（s2a_unattended.h）→ 停在提示页：按错误码映射的玩家话术一句 +「复制诊断」+ 请从后台划掉再打开（原先 _exit，玩家只看到 App 自己消失）；
//   Mac，或自动化 / 开发工具起的局 → 照旧失败退出（退出码 1）：执行器靠退出码收局，Mac 进 UIKit / 永久 pause 会让定时收局走不完（#902）。
// 上屏与诊断分开（11-02 维护者「内部词不上屏」；文案按启动器规矩登记在 launchers/shared/experience.v1.json 的 init_fail_page，
//   与本文件的宏逐字一致，launchers/shared/check_experience.py 比对）：
//   提示页只放玩家话术 = 按错误码映射的一句原因 + 下一步（s2a_init_fail_screen）；内部摘要（「服务会话初始化失败」这类）、错误码 id、
//   构建号、翻译链、红行只进诊断文本（s2a_init_fail_diag，「复制诊断」放进剪贴板、同时写进 host.log）。
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { S2A_INIT_FAIL_EXIT = 1, S2A_INIT_FAIL_PAGE = 2 };
#define S2A_INIT_FAIL_RED_LINES 8          // 诊断里带 host.log 最近几条红行
#define S2A_INIT_FAIL_LOG_TAIL (64 << 10)  // 只读 host.log 末尾这么多字节找红行
// 提示页文案（玩家话术；改字面要同一提交改 experience.v1.json 的 init_fail_page.items，revision + 1）
#define S2A_INIT_FAIL_TITLE       "游戏没能启动"
#define S2A_INIT_FAIL_TITLE_EN "The game couldn’t start"
#define S2A_INIT_FAIL_NEXT        "请从后台划掉本 App 再打开；仍不行请点「复制诊断」把诊断发给我们。"
#define S2A_INIT_FAIL_NEXT_EN "Swipe this app away in the app switcher and open it again. If it still fails, tap “Copy diagnostics” and send it to us."
#define S2A_INIT_FAIL_MSG_SERVICE "游戏需要的系统功能没能准备好。"
#define S2A_INIT_FAIL_MSG_SERVICE_EN "System features the game needs couldn’t be prepared."
#define S2A_INIT_FAIL_MSG_RUNTIME "本 App 没能准备好运行游戏。"
#define S2A_INIT_FAIL_MSG_RUNTIME_EN "This app couldn’t get ready to run the game."
#define S2A_INIT_FAIL_MSG_GAME    "游戏程序没能开始运行。"
#define S2A_INIT_FAIL_MSG_GAME_EN "The game program couldn’t start running."
#define S2A_INIT_FAIL_MSG_GENERIC "启动过程中出了问题。"
#define S2A_INIT_FAIL_MSG_GENERIC_EN "Something went wrong during startup."
#define S2A_INIT_FAIL_MSG_FILES   "游戏文件缺失，请重新导入：在 Mac 上的 S2Arm 里对这款游戏再点一次「装到 iPhone」。"
#define S2A_INIT_FAIL_MSG_FILES_EN "Game files are missing. Import them again: in S2Arm on your Mac, choose “Install on iPhone” for this game again."
#define S2A_INIT_FAIL_COPY        "复制诊断"
#define S2A_INIT_FAIL_COPY_EN "Copy diagnostics"
#define S2A_INIT_FAIL_COPIED      "已复制"
#define S2A_INIT_FAIL_COPIED_EN "Copied"
// 错误码：由失败出口显式指定（host_main.c failed_session 的调用点一处一个），不从摘要文本猜。
//   X(枚举名, 码 id, 内部摘要（只进诊断）, 玩家话术宏)；码 id 与话术归类同样登记在 experience.v1.json 的 init_fail_page.codes。
//   码表外的值按 S2A_INIT_FAIL_E_UNKNOWN（码 id unknown、通用句）处理
#define S2A_INIT_FAIL_CODES(X) \
    X(S2A_INIT_FAIL_E_SESSION_CTRL,  "session_ctrl",  "会话控制线程不可用",             S2A_INIT_FAIL_MSG_RUNTIME) \
    X(S2A_INIT_FAIL_E_SERVICE_INIT,  "service_init",  "服务会话初始化失败",             S2A_INIT_FAIL_MSG_SERVICE) \
    X(S2A_INIT_FAIL_E_GAME_THREAD,   "game_thread",   "游戏主线程启动失败或会话已失败", S2A_INIT_FAIL_MSG_GAME) \
    X(S2A_INIT_FAIL_E_SERVICE_EARLY, "service_early", "服务失败早于初启成功发布",       S2A_INIT_FAIL_MSG_SERVICE) \
    X(S2A_INIT_FAIL_E_DGUARD_LIMIT,  "dguard_limit",  "直连安全网：此前已连续失败满 3 次，自动化局不停在提示页，收局（重新出包后从 0 数）", S2A_INIT_FAIL_MSG_GENERIC) \
    X(S2A_INIT_FAIL_E_GAME_FILES,    "game_files_missing", "服务会话初始化失败：资源包里没有 exefs/main.npdm（游戏文件不在机上 / 没导完）", S2A_INIT_FAIL_MSG_FILES) \
    X(S2A_INIT_FAIL_E_DIRECT_LIB,    "direct_lib_missing", "包里没有本宿主口径的直连着色器库（没导完 / 旧版本出的包 / 设备跑不了直连；只有直连，11-07 拆通用模式后不再退通用）", S2A_INIT_FAIL_MSG_FILES)
#define S2A_INIT_FAIL_ENUM_(e, id, summary, msg) e,
enum { S2A_INIT_FAIL_E_UNKNOWN = 0, S2A_INIT_FAIL_CODES(S2A_INIT_FAIL_ENUM_) S2A_INIT_FAIL_E_COUNT };
#undef S2A_INIT_FAIL_ENUM_
// 服务会话初始化失败时归哪个码（11-07 Duo：资源包不在机上，服务层读 资源包/exefs/main.npdm 抛 DirectoryNotFound，原先一律 service_init「系统功能没能准备好」，
//   玩家不知道该重新导入）：按事实判、不解析异常文本——game_data/exefs/main.npdm 不在 → S2A_INIT_FAIL_E_GAME_FILES，否则 S2A_INIT_FAIL_E_SERVICE_INIT
int s2a_init_fail_service_code(const char *game_data);
// 失败后怎么收：is_ios = 本构建是 iOS；unattended = s2a_unattended()
int s2a_init_fail_action(int is_ios, int unattended);
// 错误码 → 码 id / 内部摘要（码表外 → "unknown" / "未登记的初启失败"）
const char *s2a_init_fail_code_id(int code);
const char *s2a_init_fail_summary(int code);
// 提示页正文（只有玩家话术）：「<按码映射的一句原因>\n<下一步>」。总是以 0 结尾，返回写入长度；放不下就截断
size_t s2a_init_fail_screen(char *out, size_t n, int code);
// 诊断文本（「复制诊断」放进剪贴板的那份，同时写进 host.log）：内部摘要 + 错误码 id、主程序构建号、翻译链，加 log[0, len) 里最近 S2A_INIT_FAIL_RED_LINES 条含「【红】」的行（按出现先后）。
//   总是以 0 结尾，返回写入长度（不含结尾 0）；放不下就截断
size_t s2a_init_fail_diag(char *out, size_t n, int code, const char *build_id, const char *chain, const char *log, size_t len);
// 同上，红行取自日志文件 path 的末尾 S2A_INIT_FAIL_LOG_TAIL 字节（从中间截开的第一行丢掉）；文件读不到按没有红行写
size_t s2a_init_fail_diag_file(char *out, size_t n, int code, const char *build_id, const char *chain, const char *path);
#ifdef __cplusplus
}
#endif
