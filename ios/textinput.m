// 系统键盘桥接 iOS 端（约定见 runtime/include/s2a_text_input.h）：游戏要玩家输入文字（输入名字、聊天等软键盘）时，
//   在当前最上层的界面上弹 UIAlertController + 一个输入框，用系统键盘（玩家装的中文等输入法都能用）。
//   标题 = 游戏给的标题（没有就「输入」），说明 = 副标题 / 提示，初始文本 = 游戏给的；长度上下限、数字 / 半角模式照游戏要求（s2a_text_input_rules.h，与 Mac 共用）；
//   不到最短时「确定」置灰。游戏 / 服务线程不在这里等：弹框排到主线程，玩家点了再回调（服务层转线程池交回游戏）。
#import <UIKit/UIKit.h>
#include "s2a_text_input.h"
#import "s2a_text_input_rules.h"
#import "s2a_l10n.h"

@interface S2ATextInput : NSObject <UITextFieldDelegate>
@property(nonatomic) int64_t ident;
@property(nonatomic) s2a_text_input_cb cb;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) NSInteger min, max;
@property(nonatomic, weak) UIAlertController *alert;
@property(nonatomic, weak) UIAlertAction *ok;
@property(nonatomic) BOOL answered;
@end

static NSMutableDictionary<NSNumber *, S2ATextInput *> *g_inputs;   // 只在主线程读写

@implementation S2ATextInput
- (void)finish:(int)status text:(NSString *)text {
    if (self.answered) return;
    self.answered = YES;
    [g_inputs removeObjectForKey:@(self.ident)];
    if (self.cb) self.cb(self.ident, status, status == 1 ? (text ?: @"").UTF8String : NULL);
}
- (void)refresh:(UITextField *)field {
    self.ok.enabled = (NSInteger)field.text.length >= self.min;
}
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)s {
    if (field.markedTextRange) return YES;   // 中文等输入法正在拼写：组字完成后由 editingChanged 收口
    NSString *add = s2a_text_input_filter(s, self.mode);
    NSString *next = [field.text stringByReplacingCharactersInRange:range withString:add];
    NSString *fit = s2a_text_input_clip(next, self.max);
    if ([add isEqualToString:s] && fit.length == next.length) return YES;
    field.text = fit;
    [self refresh:field];
    return NO;
}
- (void)changed:(UITextField *)field {
    if (field.markedTextRange) return;
    NSString *fit = s2a_text_input_clip(s2a_text_input_filter(field.text ?: @"", self.mode), self.max);
    if (![fit isEqualToString:field.text ?: @""]) field.text = fit;
    [self refresh:field];
}
@end

static UIViewController *top_controller(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) key = w;
        if (!key) key = ((UIWindowScene *)scene).windows.firstObject;
    }
    UIViewController *p = key.rootViewController;
    while (p.presentedViewController && !p.presentedViewController.isBeingDismissed) p = p.presentedViewController;
    return p;
}

static void present(S2ATextInput *in, NSDictionary *a) {
    UIViewController *top = top_controller();
    if (!top) { [in finish:0 text:nil]; return; }   // 没有界面可挂：按取消交回（游戏收到取消，不卡）
    NSString *header = [a[@"header"] length] ? a[@"header"] : S2AL(@"textinput.title");
    NSMutableArray *lines = [NSMutableArray array];
    if ([a[@"subtitle"] length]) [lines addObject:a[@"subtitle"]];
    if (in.min > 1 || in.max > 0) [lines addObject:in.max > 0 ? [NSString stringWithFormat:S2AL(@"textinput.limit.range"), (long)MAX(in.min, 0), (long)in.max] : [NSString stringWithFormat:S2AL(@"textinput.limit.min"), (long)in.min]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:header message:lines.count ? [lines componentsJoinedByString:@"\n"] : nil preferredStyle:UIAlertControllerStyleAlert];
    __weak S2ATextInput *weak = in;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = s2a_text_input_clip(s2a_text_input_filter(a[@"initial"] ?: @"", in.mode), in.max);
        f.placeholder = [a[@"guide"] length] ? a[@"guide"] : nil;
        f.delegate = in;
        f.clearButtonMode = UITextFieldViewModeWhileEditing;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.keyboardType = [in.mode isEqualToString:@"numeric"] ? UIKeyboardTypeNumberPad : [in.mode isEqualToString:@"ascii"] ? UIKeyboardTypeASCIICapable : UIKeyboardTypeDefault;
        f.accessibilityIdentifier = @"s2a.textinput.field";
        [f addTarget:in action:@selector(changed:) forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; [weak finish:0 text:nil]; }]];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:[a[@"submit"] length] ? a[@"submit"] : S2AL(@"textinput.ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        (void)x; S2ATextInput *s = weak; UIAlertController *al = s.alert;
        [s finish:1 text:s2a_text_input_clip(al.textFields.firstObject.text ?: @"", s.max)];
    }];
    [alert addAction:ok];
    alert.preferredAction = ok;
    in.alert = alert; in.ok = ok;
    ok.enabled = (NSInteger)alert.textFields.firstObject.text.length >= in.min;
    [top presentViewController:alert animated:YES completion:nil];
}

static int begin_input(int64_t id, const char *json, s2a_text_input_cb cb) {
    if (!s2a_text_input_interactive() || !json || !cb) return 0;
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    NSDictionary *a = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![a isKindOfClass:NSDictionary.class]) return 0;
    S2ATextInput *in = [S2ATextInput new];
    in.ident = id; in.cb = cb; in.mode = [a[@"mode"] isKindOfClass:NSString.class] ? a[@"mode"] : @"full";
    in.min = [a[@"min"] integerValue]; in.max = [a[@"max"] integerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_inputs) g_inputs = [NSMutableDictionary dictionary];
        g_inputs[@(id)] = in;
        present(in, a);
    });
    return 1;
}

static void cancel_input(int64_t id) {
    dispatch_async(dispatch_get_main_queue(), ^{
        S2ATextInput *in = g_inputs[@(id)];
        if (!in) return;
        in.answered = YES;   // 调用方自己按取消处理，不再回调
        [g_inputs removeObjectForKey:@(id)];
        [in.alert dismissViewControllerAnimated:YES completion:nil];
    });
}

// 启动即登记到公用分发（runtime/src/text_input.c）
__attribute__((constructor)) static void provide_text_input(void) { s2a_text_input_provide(begin_input, cancel_input); }
