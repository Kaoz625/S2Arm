// 系统手柄存活判定：真机「-」键约 1 秒延迟的回归护栏（issue #58 真机调查副产物）。
// 只测纯决策函数 ios/pad_liveness.h，再对 controller.m 做接线断言——iOS 的 GameController / UIKit
//   在 Mac 宿主上编不了，行为靠决策表覆盖，接线靠文本断言钉住（旧写法一旦回来就红）。
#include "../../ios/pad_liveness.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
static void check(int ok, const char *what) {
    checks++;
    if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); }
}

static s2a_sys_state state(bool foreground, bool has_current, bool current_alive, bool candidate_ready, bool may_clear) {
    s2a_sys_state s;
    s.foreground = foreground; s.has_current = has_current; s.current_alive = current_alive;
    s.candidate_ready = candidate_ready; s.may_clear = may_clear;
    return s;
}

// controller.m 全文里 needle 的出现次数（接线断言用）。
static int count_in(const char *text, const char *needle) {
    int n = 0; size_t len = strlen(needle);
    for (const char *p = text; (p = strstr(p, needle)) != NULL; p += len) n++;
    return n;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "用法：t_pad_liveness <controller.m 路径>\n"); return 2; }
    FILE *file = fopen(argv[1], "rb");
    if (!file) { perror(argv[1]); return 2; }
    static char source[1 << 20];
    size_t size = fread(source, 1, sizeof source - 1, file);
    fclose(file);
    source[size] = 0;

    // ---- 行为：核心回归。快照不含当前手柄（candidate_ready=0），但对象自身 extendedGamepad 非 nil ----
    check(s2a_system_action(state(true, true, true, false, false)) == S2A_SYS_PUBLISH,
          "快照不含 + extendedGamepad 非 nil → 刷新共享内存，不清零");
    check(s2a_system_action(state(true, true, true, false, true)) == S2A_SYS_PUBLISH,
          "延迟复查时 extendedGamepad 仍非 nil → 已恢复，不清零");
    check(s2a_system_action(state(true, true, true, true, false)) == S2A_SYS_PUBLISH,
          "当前对象可用时即使快照里还有别的可用对象，也不换对象");

    // ---- 行为：断开要延迟确认，第一次不可用不清零 ----
    check(s2a_system_action(state(true, true, false, false, false)) == S2A_SYS_DEFER,
          "首次发现不可用 → 延迟确认，不清零、不摘 handler");
    check(s2a_system_action(state(true, true, false, false, true)) == S2A_SYS_CLEAR,
          "复查仍不可用 → 确认断开，清零并摘 handler");
    check(s2a_system_action(state(true, true, false, true, false)) == S2A_SYS_ATTACH,
          "当前对象不可用但快照里有别的可用对象 → 换对象");
    check(s2a_system_action(state(true, false, false, false, false)) == S2A_SYS_NONE,
          "从来没有接入手柄 → 什么都不做");
    check(s2a_system_action(state(false, true, true, false, false)) == S2A_SYS_CLEAR,
          "切后台 → 保持原行为立刻摘掉");
    check(s2a_system_action(state(false, false, false, true, false)) == S2A_SYS_NONE,
          "后台且没有当前对象 → 什么都不做");
    check(S2A_SYSTEM_RECHECK_MS == 200, "复查延迟是 200ms");

    // ---- 接线：controller.m 真的按这套决策走 ----
    check(count_in(source, "[controllers containsObject:") == 0,
          "controller.m 不再用 GCController.controllers 快照判活");
    check(count_in(source, "current.extendedGamepad != nil") == 1,
          "controller.m 用对象自身的 extendedGamepad 判活");
    check(count_in(source, "s2a_system_action(state)") == 1,
          "controller.m 的判定走 s2a_system_action");
    check(count_in(source, "s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL)") == 1,
          "系统手柄清零只有一处");
    const char *clear = strstr(source, "- (void)clearSystem {");
    const char *zero = strstr(source, "s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL)");
    check(clear && zero && clear < zero, "清零只在 clearSystem 里，不在延迟确认路径上");
    check(count_in(source, "S2A_SYSTEM_RECHECK_MS") >= 2, "controller.m 用统一的复查延迟常量");
    check(strstr(source, "从快照消失") != NULL && strstr(source, "确认断开") != NULL && strstr(source, "已恢复") != NULL,
          "断开日志三态齐全（延迟确认中 / 确认断开 / 已恢复）");
    check(count_in(source, "dispatch_after(") == 1, "延迟复查只有一个 dispatch_after 入口");

    // ---- 接线：「-」/「+」不再被系统手势吃掉（Minus 延迟的真根因，与本 PR 的判活健壮性独立）----
    // 「-」用 Disabled：手势识别器完全不跑、输入直接给 app。AlwaysReceive 已废弃且语义是「同时给手势识别器」
    //   （真机现象：按 Minus 触发录屏），这里断言它一处都不许出现，防止有人改回去。
    check(count_in(source, "preferredSystemGestureState = GCSystemGestureStateDisabled") == 2,
          "「-」与 Home 设 Disabled（手势不跑，输入直接给 app）");
    // #276：Home 关掉系统手势（否则系统拿去开游戏面板），并放进扩展位 bit16 供长按开局内菜单
    check(strstr(source, "pad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled") != NULL, "Home 设 Disabled");
    check(strstr(source, "if (pad.buttonHome.isPressed) buttons |= 1u << 16;") != NULL, "Home 进扩展位 bit16");
    check(count_in(source, "GCSystemGestureStateAlwaysReceive") == 0,
          "没有再用已废弃的 AlwaysReceive（它语义是「同时给手势识别器」，会触发录屏）");
    check(count_in(source, "buttonMenu.preferredSystemGestureState") == 0,
          "「+」不设手势状态：头文件没把它标成系统保留键，且实测本来即时响应");
    check(count_in(source, "@available(iOS 14.0, *)") == 1, "手势属性有 iOS 14 可用性保护（属性本身 ios(14.0) 引入）");
    check(count_in(source, "if (pad.buttonOptions)") == 1, "buttonOptions 有 nil 保护（与 Mac 侧 front_mac.m 对齐）");

    if (failures) { fprintf(stderr, "t_pad_liveness：%d/%d 项不符\n", failures, checks); return 1; }
    printf("✓ t_pad_liveness：%d 项（快照不含但 extendedGamepad 非 nil 不清零；首次不可用延迟 200ms 复查；清零只在确认断开）\n", checks);
    return 0;
}
