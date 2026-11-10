// 游戏声明触屏配置 → 自动切「仅触屏操作」（11-04 维护者定，方案第 1 条）。
//   游戏调 hid SetTouchScreenConfiguration（声明手指 / 手写笔触屏模式）= 它自己的界面靠触屏走（脑锻炼标题页「开始」只认点按：
//   普查 c1103 / c1104 按键 25+ 下不动、点触 (120,330) 即进下一页）。普查 144 款里只有这一款调它，ActivateTouchScreen 则有 70 款开机就调、分不出真用不用。
//   链路：Ryujinx IHidServer.SetTouchScreenConfiguration 记 Hid.Touchscreen.ConfiguredMode（补丁 hid-touch-config-mode）
//   → 服务层 InputPump.OfferTouchConfigured 每次 HID 提交看一眼，有值就调这里的 s2a_vpad_touch_configured(模式)
//   → 主线程 s2a_vpad_set_touch_only(1, 0, …)（vpad.m，「键 / 触」切换钮同一入口）：manual = 0 只改本次运行、不写持久化；玩家手动选过方案时它返回 0、这里不提示。
//   切成了提示一条（S2A_DPROMPT_VPAD_TOUCH_AUTO：指屏幕上方常驻的「键 / 触」钮，用 dprompt.m 现有的提示条）；无人值守局不提示。
// 只用 Foundation（不碰 UIKit，vpad.h 引 UIKit 所以这里自己声明）：runtime/tests/t_touch_config.m 在 Mac 上直接编这份源码、桩掉 vpad.m 测。
#import <Foundation/Foundation.h>
#include "native.h"
#include "s2a_unattended.h"
#include "s2a_direct_prompt.h"   // 提示文案（与 launchers/shared/experience.v1.json prompts 逐字一致）
#include "s2a_ui_lang.h"   // S2A_TR：英文缺省、界面语言中文才出中文

uint64_t s2a_ap_frames(void);   // runtime/src/ap_host.c：上屏帧数
int s2a_vpad_set_touch_only(int on, int manual, const char *why);   // vpad.m：主线程同步返回 1 切了 / 0 没切（本来就是或玩家手动选过）/ -1 失败
void s2a_dprompt_notice(NSString *title, NSString *body, double delay, double seconds) __attribute__((weak_import));

// 主线程：按游戏声明的触屏模式自动切仅触屏。返回 s2a_vpad_set_touch_only 的结果：1 切了（提示）、0 没切（本来就是仅触屏 / 玩家手动选过）、-1 失败（记黄）
int s2a_touchcfg_apply(int mode) {
    int r = s2a_vpad_set_touch_only(1, 0, "游戏声明触屏配置");
    if (r < 0) { LOG("【黄】触屏：游戏声明了触屏配置（模式 %d），自动切仅触屏失败（%d：虚拟手柄没挂或写盘失败），保持原方案", mode, r); return r; }
    if (r == 0) { LOG("触屏：游戏声明了触屏配置（模式 %d），没自动切（本来就是仅触屏，或玩家手动选过方案）", mode); return 0; }
    LOG("触屏：游戏声明了触屏配置（模式 %d），已自动切到仅触屏操作（本次运行，不改玩家设置）", mode);
    if (!s2a_unattended() && s2a_dprompt_notice)
        s2a_dprompt_notice(@"", @(S2A_TR(S2A_DPROMPT_VPAD_TOUCH_AUTO_EN, S2A_DPROMPT_VPAD_TOUCH_AUTO)), 0, 12);
    return r;
}

// 服务层 InputPump 按符号查（HID 线程，每次提交至多一次，直到返回 1）：mode = 游戏传的 TouchScreenModeForNx（0 跟系统 / 1 手指 / 2 手写笔）。
//   0 = 还没出首帧（加载页盖着，提示看不见），下一拍再问；1 = 收下了（派回主线程切），之后不再调
__attribute__((visibility("default"), used)) int s2a_vpad_touch_configured(int mode) {
    if (!s2a_ap_frames()) return 0;
    dispatch_async(dispatch_get_main_queue(), ^{ s2a_touchcfg_apply(mode); });
    return 1;
}
