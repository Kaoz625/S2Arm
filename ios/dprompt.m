// 游戏内提示条（iOS；文案在 s2a_direct_prompt.h，Mac 同款在 macos/front_mac.m）：存档不能原子提交、签名快到期（prov_expiry.m，描述文件剩不到 48 小时）等。
//   贴画面顶部居中（两侧肩键之间），只占自己那一块，别处的触摸照常给游戏和虚拟手柄；带两个按钮的 seconds 秒没理会按「否」收起。
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import "s2a_l10n.h"
#include "s2a_direct_prompt.h"
#include "s2a_ui_lang.h"   // S2A_TR：英文缺省、界面语言中文才出中文
#include "native.h"
#include "s2a_unattended.h"
#include <math.h>
double s2a_prov_hours_left_self(void);   // prov_expiry.m：本包描述文件剩几小时，读不到 NAN

static UIVisualEffectView *g_banner;
static UILabel *g_title, *g_body;
static UIButton *g_accept, *g_decline;
static NSInteger g_gen;
static void (^g_onAnswer)(BOOL);
void s2a_dprompt_notice(NSString *title, NSString *body, double delay, double seconds);

static void hide(void) { g_banner.hidden = YES; }
static void answer(BOOL accept) { void (^cb)(BOOL) = g_onAnswer; g_onAnswer = nil; hide(); if (cb) cb(accept); }
@interface S2APromptTarget : NSObject
@end
@implementation S2APromptTarget
+ (void)accept { answer(YES); }
+ (void)decline { answer(NO); }
@end

// accept 为 nil = 只有「知道了」的确认条
static void show(NSString *title, NSString *body, NSString *accept, NSString *decline, double seconds) {
    g_title.text = title; g_title.hidden = title.length == 0; g_body.text = body;
    [g_accept setTitle:accept ?: @(S2A_TR(S2A_DPROMPT_OK_EN, S2A_DPROMPT_OK)) forState:UIControlStateNormal];
    [g_decline setTitle:decline forState:UIControlStateNormal]; g_decline.hidden = accept == nil;
    g_banner.hidden = NO; [g_banner.superview bringSubviewToFront:g_banner]; NSInteger gen = ++g_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == g_gen && !g_banner.hidden) { if (accept) answer(NO); else hide(); } });
}
static void poll(void) {
    // 存档不能原子提交（审计 P2-45，Mac 同款判定 runtime/src/direct_prompt.c）：第一次读到非 0 时用这条横幅提示一次
    if (s2a_save_atomic_poll()) s2a_dprompt_notice(@(S2A_TR(S2A_DPROMPT_SAVE_ATOMIC_TITLE_EN, S2A_DPROMPT_SAVE_ATOMIC_TITLE)), @(S2A_TR(S2A_DPROMPT_SAVE_ATOMIC_IOS_EN, S2A_DPROMPT_SAVE_ATOMIC_IOS)), 0, 15);
}

static UIButton *button(SEL action, BOOL primary) {
    UIButtonConfiguration *c = primary ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.grayButtonConfiguration;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule; c.buttonSize = UIButtonConfigurationSizeMedium;
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [b addTarget:S2APromptTarget.class action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
// 游戏画面建好后调（app.m 场景代理，提示页不调）
void s2a_dprompt_attach(UIView *root) {
    g_banner = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    g_banner.layer.cornerRadius = 16; g_banner.clipsToBounds = YES; g_banner.hidden = YES; g_banner.translatesAutoresizingMaskIntoConstraints = NO;
    g_title = [UILabel new]; g_title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; g_title.textColor = UIColor.whiteColor;
    g_body = [UILabel new]; g_body.font = [UIFont systemFontOfSize:14]; g_body.textColor = [UIColor colorWithWhite:1 alpha:0.75]; g_body.numberOfLines = 0;
    g_accept = button(@selector(accept), YES); g_decline = button(@selector(decline), NO);
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[g_title, g_body]]; text.axis = UILayoutConstraintAxisVertical; text.spacing = 2;
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[g_decline, g_accept]]; buttons.spacing = 8;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[text, buttons]]; row.spacing = 16; row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO; [g_banner.contentView addSubview:row]; [root addSubview:g_banner];
    [buttons setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:g_banner.contentView.leadingAnchor constant:18], [row.trailingAnchor constraintEqualToAnchor:g_banner.contentView.trailingAnchor constant:-12],
        [row.topAnchor constraintEqualToAnchor:g_banner.contentView.topAnchor constant:12], [row.bottomAnchor constraintEqualToAnchor:g_banner.contentView.bottomAnchor constant:-12],
        [g_banner.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12], [g_banner.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [g_banner.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor multiplier:0.55]]];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { (void)t; poll(); }];
    // 签名到期提示（prov_expiry.m）：描述文件剩不到 48 小时，起局 3 秒后提示一次；读不到描述文件不提示
    double h = s2a_prov_hours_left_self();
    if (!isnan(h) && h < 48) {
        LOG("签名到期提示：描述文件还剩 %.1f 小时", h);
        NSString *left = h < 1 ? S2AL(@"dprompt.signExpiry.lessThanHour") : [NSString stringWithFormat:S2AL(@"dprompt.signExpiry.hours"), (int)h];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (g_banner.hidden) show(S2AL(@"dprompt.signExpiry.title"), [NSString stringWithFormat:S2AL(@"dprompt.signExpiry.body"), left], nil, nil, 15); });
    }
    // Switch 2 Pro 手柄缺省不连（每 App 开关，开了才扫蓝牙）：从没设过这个开关、起局 20 秒还没有任何系统认得的手柄时，说一次去哪开（审计 P2-4）。
    //   只提示一次（S2ANS2ProHintShown）；自动化局不提示（s2a_unattended，日志由工具拉回）
    NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
    if (![u objectForKey:@"S2ANS2ProAdapterEnabled"] && ![u boolForKey:@"S2ANS2ProHintShown"] && !s2a_unattended())
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (GCController.controllers.count || [u objectForKey:@"S2ANS2ProAdapterEnabled"]) return;
            [u setBool:YES forKey:@"S2ANS2ProHintShown"];
            s2a_dprompt_notice(S2AL(@"dprompt.ns2pro.title"), S2AL(@"dprompt.ns2pro.body"), 0, 12); });
}

// 只有「知道了」的提示条（别的模块用，主线程）：delay 秒后显示；横幅正被别的提示占着就再等 5 秒，不顶掉（审计 P2-3 IML 权限丢失）
void s2a_dprompt_notice(NSString *title, NSString *body, double delay, double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!g_banner) return;
        if (!g_banner.hidden) { s2a_dprompt_notice(title, body, 5, seconds); return; }
        show(title, body, nil, nil, seconds); });
}

// 带两个按钮的提示条（别的模块用，主线程安全）：delay 秒后显示；横幅被别的提示占着就再等 5 秒；seconds 秒没理会按「否」收起。
//   cb(YES) = 点了 accept，cb(NO) = 点了 decline 或超时（11-04 触屏提示的「切到触屏」）
void s2a_dprompt_ask(NSString *title, NSString *body, NSString *accept, NSString *decline, double delay, double seconds, void (^cb)(BOOL)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!g_banner) { if (cb) cb(NO); return; }
        if (!g_banner.hidden) { s2a_dprompt_ask(title, body, accept, decline, 5, seconds, cb); return; }
        g_onAnswer = [cb copy]; show(title, body, accept, decline, seconds); });
}
