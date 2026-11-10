// 本地联机的「本地网络」权限：系统弹框前先在界面上说清用途，被拒后引导去设置重开（10-31 维护者派，真机体验线）。
//   ① s2a_lan_permission_then(go)：联机第一次开始找设备前弹说明（「知道了」后才真正开始发布 / 浏览，系统授权框紧接着出现）；
//      只说明一次（NSUserDefaults S2ALanPermExplained）；还没有界面时不开始，等界面出现先说明（审计 P2-17）。自动化 / 开发局（S2A_AUTOPLAY=1，或起局前就给了 S2A_LDN_SERVER=lan）跳过说明，免得挡住无人值守的局。
//   ② s2a_lan_permission_failed(what, err)：发布本机中继或浏览失败——本地网络被拒时 NSNetService 正是走这两个失败回调——提示去
//      「设置 › 隐私与安全性 › 本地网络」打开本 App，带「去设置」按钮（打开本 App 的设置页）；每次启动最多提示一次，自动化局不弹、只写日志。
//   文案与 Info.plist 的 NSLocalNetworkUsageDescription（runtime/build.mk）同一口径：同一 Wi-Fi、互相发现、进同一个房间。
#import <UIKit/UIKit.h>
#include <stdlib.h>
#include <string.h>
#include "native.h"
#include "s2a_unattended.h"
#include "root_ready.h"
#import "s2a_l10n.h"

static BOOL lan_unattended(void) { return s2a_unattended(); }

// 当前最上层的界面（同 diag.m：从根界面沿 presentedViewController 往上找）
static UIViewController *lan_top_vc(void) {
    UIViewController *top = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow || !top) top = w.rootViewController;
    }
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static NSString *lan_app_name(void) {
    NSString *n = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    return n.length ? n : ([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: S2AL(@"lan.appNameFallback"));
}

// 主线程调用。dev_mode = 起局前就设了 S2A_LDN_SERVER=lan（ldn_lan.m 在 setenv 之前读好传进来）
void s2a_lan_permission_then(int dev_mode, void (^go)(void)) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (dev_mode || lan_unattended() || [ud boolForKey:@"S2ALanPermExplained"]) { go(); return; }
    UIViewController *top = lan_top_vc();
    // 没有界面（审计 P2-17：原先打一行日志就开始找设备、不记已说明，玩家只看到系统框）：不开始，等界面出现再回到这里先说明。
    //   根视图还没就绪 → 就绪后（root_ready.m）；已就绪却取不到界面（场景暂时断开）→ 下一次场景激活后
    if (!top) {
        void (^retry)(void) = ^{ s2a_lan_permission_then(dev_mode, go); };
        if (s2a_ios_wait_root_view(0) != 0) { LOG("[S2A 联机] 本地网络说明：界面还没就绪，就绪后先说明再找设备"); s2a_ios_on_root_view(retry); return; }
        LOG("[S2A 联机] 本地网络说明：暂时没有可用的界面，下次场景激活后先说明再找设备");
        __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *n) { (void)n; [NSNotificationCenter.defaultCenter removeObserver:token]; token = nil; retry(); }];
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"lan.permission.title")
        message:S2AL(@"lan.permission.message")
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        (void)x; [ud setBool:YES forKey:@"S2ALanPermExplained"]; LOG("[S2A 联机] 本地网络说明：玩家已读，开始找设备"); go(); }]];
    LOG("[S2A 联机] 本地网络说明：首次联机，先说明用途再请求授权");
    [top presentViewController:a animated:YES completion:nil];
}

// 主线程调用。what = 「发布本机中继」/「查找其他设备」，err = NSNetService 的错误字典
void s2a_lan_permission_failed(const char *what, NSDictionary *err) {
    static BOOL shown;
    LOG("【红】联机局域网：%s失败 %s（本地网络权限可能被拒）", what, err.description.UTF8String);
    if (shown || lan_unattended()) return;
    UIViewController *top = lan_top_vc(); if (!top) return;
    shown = YES;
    NSString *msg = [NSString stringWithFormat:S2AL(@"lan.denied.message"), lan_app_name(), lan_app_name()];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"lan.denied.title") message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"lan.denied.later") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"lan.denied.openSettings") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        (void)x; [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil]; }]];
    [top presentViewController:a animated:YES completion:nil];
}
