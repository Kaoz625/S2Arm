// 起局自检不过时 iOS 屏上的标题与正文（玩家话术；实现 runtime/src/selfcheck.c s2a_selfcheck_screen，上屏 runtime/src/host_main.c）。
// 文案按启动器规矩登记在 launchers/shared/experience.v1.json 的 selfcheck_page，与本文件的宏逐字一致，launchers/shared/check_experience.py 比对；
//   改字面要同一提交改 selfcheck_page.items（revision + 1）。游戏进程不读那份 JSON，本头文件是实现来源。
// 上屏只放一句人话 + 下一步（11-02 维护者：内部词不上屏）；地址上限 / main.npdm / MB 这类细节只进 host.log 的「【红】自检不过」。
#pragma once
// 没签「提高内存上限」权限 → 重装
#define S2A_SELFCHECK_ENT_TITLE    "安装少了一项必要权限"
#define S2A_SELFCHECK_ENT_TITLE_EN "A required permission is missing"
#define S2A_SELFCHECK_ENT_BODY     "这款游戏要用「提高内存上限」权限。请用 Mac 上的 S2Arm 对这款游戏点「装到 iPhone」重新装一次，会自动带上它。"
#define S2A_SELFCHECK_ENT_BODY_EN "This game needs the “Increased Memory Limit” permission. In S2Arm on your Mac, click “Install on iPhone” for this game again; it will be included automatically."
// 读不到本款要多大地址（包不完整）→ 重装补资源
#define S2A_SELFCHECK_PKG_TITLE    "游戏资源不完整"
#define S2A_SELFCHECK_PKG_TITLE_EN "Game files are incomplete"
#define S2A_SELFCHECK_PKG_BODY     "请在 Mac 上的 S2Arm 里对这款游戏再点一次「装到 iPhone」，它会把缺的补上。"
#define S2A_SELFCHECK_PKG_BODY_EN "In S2Arm on your Mac, click “Install on iPhone” for this game again to add what’s missing."
// 签了仍不够 → 本机型系统上限
#define S2A_SELFCHECK_DEVICE_TITLE "这台手机暂时玩不了这款游戏"
#define S2A_SELFCHECK_DEVICE_TITLE_EN "This iPhone can’t run this game yet"
#define S2A_SELFCHECK_DEVICE_BODY  "这款游戏要的内存超过了这台手机的系统上限，重新安装也解决不了。换一台内存更大的 iPhone 就能玩。"
#define S2A_SELFCHECK_DEVICE_BODY_EN "This game needs more memory than this iPhone’s system limit allows, and reinstalling won’t help. It will run on an iPhone with more memory."
// 游戏要的地址空间宽度暂不支持（NPDM 地址空间类型 0 / 2 = 32 位；1 = 36 位、3 = 39 位支持，见 runtime/src/as_type.h）→ 与机型、安装无关
#define S2A_SELFCHECK_AS_TITLE     "暂不支持这款游戏"
#define S2A_SELFCHECK_AS_TITLE_EN "This game isn’t supported yet"
#define S2A_SELFCHECK_AS32_BODY    "这款游戏使用 32 位地址空间，S2Arm 暂不支持，重新安装或换手机都解决不了。"
#define S2A_SELFCHECK_AS32_BODY_EN "This game uses a 32-bit address space, which S2Arm doesn’t support yet. Reinstalling or switching phones won’t help."
