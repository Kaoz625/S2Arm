// 直连安全网（玩家包，10-30 维护者 拍板）：同一款直连连续起局失败 3 次（首帧前崩，或首帧后 60 秒内崩 / 被系统杀），下次起局先弹提示，
//   请玩家先更新 S2Arm 重新出包（重新出包指纹变了、从 0 数），仍失败就导出诊断包反馈（11-07 拆通用模式：不再有兼容模式重出这条退路）。包里不带通用产物，所以只提示、不切换；运行时不判断画面。
// 计数口径（11-02 改：只数有失败证据的局）：直连起局时把「本次」记成待定行落盘；有失败证据才转正——崩溃（crash.c 崩溃处理）、
//   前台收到内存告警（之后被系统按内存杀掉不会再有机会写盘）、出图停住看门打现场（帧又走了撤回）。下次起局待定行丢掉：被外部结束、
//   玩家在长预热里退出、进后台被回收都不是直连失败（11-02 怪猎：64 秒预热中退出 / 被工具结束攒满 3 次，误弹提示页）。
//   首帧后在前台累计满 60 秒清零，60 秒只数前台时间。记录带程序号与出包指纹，换了包（重新出包）从 0 数。
// 平台无关：时间由调用方传（纳秒，单调时钟），文件在 <Documents>/wire/direct_guard（iOS = $HOME/Documents；可用 S2A_DOCS 指，同 gfxmode.c）。
//   iOS 接入：host_main.c 起游戏主线程前 begin / arm、ap_host.c 每次上屏 frame 与停住看门 evidence、crash.c 崩溃 evidence、
//   ios/app.m 前后台 background、内存告警 evidence 与提示页。
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define S2A_DGUARD_LIMIT 3                 // 连续失败几次就提示
#define S2A_DGUARD_OK_NS 60000000000ull    // 首帧后前台累计多久算成功玩过
#define S2A_DGUARD_TITLE "这款游戏最近几次都没能启动"
#define S2A_DGUARD_MSG "请先把 Mac 上的 S2Arm 更新到最新版，再对这款游戏点「装到 iPhone」重新装一次；还是不行，请点「导出诊断包」把诊断包发给我们反馈。"
#define S2A_DGUARD_DIAG "导出诊断包"
#define S2A_DGUARD_GO "仍然启动"
// 英文（11-10 英文默认，iOS 按界面语言 S2A_TR 取，runtime/include/s2a_ui_lang.h）
#define S2A_DGUARD_TITLE_EN "This game failed to start the last few times"
#define S2A_DGUARD_MSG_EN "First update S2Arm on your Mac to the latest version, then click “Install on iPhone” for this game to reinstall it. If it still fails, tap “Export Diagnostics” and send us the diagnostics."
#define S2A_DGUARD_DIAG_EN "Export Diagnostics"
#define S2A_DGUARD_GO_EN "Start Anyway"
// 起局前要不要先起界面（main 里判，还不知道程序号）：记录里已连续失败 ≥ S2A_DGUARD_LIMIT 次 = 1；自动化 / 开发工具起的局（s2a_unattended.h）恒 0，
//   起局时满 3 次就记日志收局、不停在提示页。只读文件，不改
int s2a_dguard_needs_ui(void);
// 资源包的出包指纹：<游戏数据>/manifest.json 的 index_sha256 前 16 位；读不到 = "-"。返回静态串
const char *s2a_dguard_pack_fp(const char *game_data);
// 直连起局、起游戏主线程之前调：读记录（程序号、出包指纹、宿主提交号任一不同 = 新包，从 0 数），返回此前连续失败的次数（不含本次）。之后才能 arm
//   host = 宿主自身的构建提交号（iOS：Info.plist 的 S2ACommit；取不到传 NULL / "" 记「-」）
int s2a_dguard_begin(uint64_t program_id, const char *pack_fp, const char *host);
// 本次记一次失败并落盘；清零前进程没了就算这次失败
void s2a_dguard_arm(uint64_t now);
// 每次上屏调（任意线程）：首帧记下时刻；首帧后每过 10 秒更新本次的阶段，前台累计满 60 秒清零。清零后是一次原子读
void s2a_dguard_frame(uint64_t now);
// 进后台（on = 1）停表，内存告警证据撤回待定（画面停住的证据不撤）；回前台（on = 0）接着计时。清零后 / 没 arm 时空操作
void s2a_dguard_background(int on, uint64_t now);
// 本次的失败证据：why = "崩溃" / "内存告警" / "画面停住"（stall = 1，帧又走了用 why = NULL 撤回）。崩溃处理里可调（拿不到锁照写）
void s2a_dguard_evidence(const char *why, int stall);
// 诊断信息（中文多行：程序号、主程序构建号、出包指纹、翻译链、设备、系统、每次失败的阶段），写进 out，返回长度
size_t s2a_dguard_diag(char *out, size_t n, const char *build_id, const char *chain);
#ifdef __cplusplus
}
#endif
