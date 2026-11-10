// 宿主上屏文字的语言（11-10 维护者：英文设备上看到中文）：原生层（C）的玩家话术默认英文，只在 App 的界面语言是中文时出中文。
//   iOS 主程序起来时按 App 实际选中的本地化（NSBundle.mainBundle.preferredLocalizations，跟设备首选语言，App 只带 en / zh-Hans 两份字符串表）
//   设 s2a_ui_zh（ios/app.m main）；Mac 宿主与单测不设 = 英文。Objective-C 侧走 S2AL 字符串表（ios/s2a_l10n.h），本头只给 C 源码用。
//   弱定义：每个包含本头的编译单元都有一份，链接时合成一个（没有单独的 .c，单测只编自己那几个文件也能链上）
#pragma once
__attribute__((weak)) int s2a_ui_zh = 0;
// 英文在前、中文在后：两句都是字面量，按 s2a_ui_zh 取一句
#define S2A_TR(en, zh) (s2a_ui_zh ? (zh) : (en))
