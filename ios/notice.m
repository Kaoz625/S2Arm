// 宿主提示 / 出错页（11-02 维护者 看资源导入出错页点名三个问题：四周留边不满屏、index.tsv / 执行器 / 返回 -8 这类内部词看不懂、样子丑且和我们的界面不一致）。
//   全部画成和加载页（loadpage.m，10-30 维护者 批准）同一套样子：游戏图标放大模糊铺满整屏（不留边）+ 圆角图标（角上一个状态符号）+ 一句话标题 + 一句「下一步做什么」
//   + 胶囊按钮（主按钮用启动器品牌色）。技术细节（失败码、文件名、地址上限）只进 host.log / unpack.log，经「导出诊断包」带走，不上屏。本文件只画
#import "notice.h"
#import "s2a_l10n.h"

UIColor *s2a_notice_accent(void) { return [UIColor colorWithRed:0.02 green:0.53 blue:0.57 alpha:1]; }   // 启动器 Brand.accent（launchers/macos/Sources/S2ArmLauncher/Appearance.swift）

static UILabel *label(CGFloat size, UIFontWeight w, UIColor *c) {
    UILabel *l = [UILabel new]; l.font = [UIFont systemFontOfSize:size weight:w]; l.textColor = c; l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO; return l;
}
UIButton *s2a_notice_button(NSString *title, BOOL primary, void (^tap)(UIButton *b)) {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration]; c.title = title;
    c.baseBackgroundColor = primary ? s2a_notice_accent() : [UIColor colorWithWhite:1 alpha:0.14]; c.baseForegroundColor = UIColor.whiteColor;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule; c.contentInsets = NSDirectionalEdgeInsetsMake(12, 24, 12, 24);
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) { NSMutableDictionary *m = a.mutableCopy; m[NSFontAttributeName] = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; return m; };
    return [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { if (tap) tap((UIButton *)a.sender); }]];
}
// 底：图标放大铺满、强模糊、压暗——同加载页，只给颜色氛围；返回整页，*content 是放内容的那层
static UIView *backdrop(CGRect f, UIView **content) {
    UIView *page = [[UIView alloc] initWithFrame:f]; page.backgroundColor = UIColor.blackColor; page.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    page.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    page.layer.zPosition = 2000;   // 整页提示压过虚拟手柄（1000），低于开发浮层（10000）
    UIImageView *bg = [[UIImageView alloc] initWithImage:s2a_game_icon()]; bg.contentMode = UIViewContentModeScaleAspectFill; bg.clipsToBounds = YES; bg.alpha = 0.9;
    bg.frame = page.bounds; bg.autoresizingMask = page.autoresizingMask; [page addSubview:bg];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.frame = page.bounds; blur.autoresizingMask = page.autoresizingMask; [page addSubview:blur];
    *content = blur.contentView; return page;
}
// 内容放进可滚动区：按整屏居中（横屏刘海只在一侧，按安全区居中会整体偏向另一边），只在放不下时让开安全区；矮屏（横屏小手机 + 大字号）能滚，不裁字
static void place(UIView *content, UIView *col, CGFloat width) {
    UIScrollView *sc = [UIScrollView new]; sc.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:sc];
    col.translatesAutoresizingMaskIntoConstraints = NO; [sc addSubview:col];
    UILayoutGuide *g = content.safeAreaLayoutGuide, *cg = sc.contentLayoutGuide, *fg = sc.frameLayoutGuide;
    NSLayoutConstraint *w = [col.widthAnchor constraintEqualToConstant:width]; w.priority = UILayoutPriorityRequired - 1;   // 尽量取满 width，屏窄时让给上面的安全区上限
    NSLayoutConstraint *cx = [col.centerXAnchor constraintEqualToAnchor:content.centerXAnchor]; cx.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [sc.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [sc.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [sc.topAnchor constraintEqualToAnchor:g.topAnchor], [sc.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [col.topAnchor constraintGreaterThanOrEqualToAnchor:cg.topAnchor constant:24], [col.bottomAnchor constraintLessThanOrEqualToAnchor:cg.bottomAnchor constant:-24],
        [col.leadingAnchor constraintGreaterThanOrEqualToAnchor:g.leadingAnchor constant:24], [col.trailingAnchor constraintLessThanOrEqualToAnchor:g.trailingAnchor constant:-24],
        cx, [col.centerYAnchor constraintEqualToAnchor:cg.centerYAnchor],
        [cg.heightAnchor constraintGreaterThanOrEqualToAnchor:fg.heightAnchor], [cg.widthAnchor constraintEqualToAnchor:fg.widthAnchor], w]];
}
// 圆角游戏图标 + 右下角状态符号（品牌色圆底）；没有图标时只画一个大符号
static UIView *badge_icon(NSString *symbol) {
    UIImage *ic = s2a_game_icon(); UIView *box = [UIView new]; box.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *big = [UIImageSymbolConfiguration configurationWithPointSize:52 weight:UIImageSymbolWeightRegular];
    if (!ic) { UIImageView *s = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:big]]; s.tintColor = UIColor.whiteColor;
        s.translatesAutoresizingMaskIntoConstraints = NO; [box addSubview:s];
        [NSLayoutConstraint activateConstraints:@[[s.centerXAnchor constraintEqualToAnchor:box.centerXAnchor], [s.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [box.widthAnchor constraintEqualToConstant:84], [box.heightAnchor constraintEqualToConstant:84]]]; return box; }
    UIImage *rounded = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(168, 168)] imageWithActions:^(UIGraphicsImageRendererContext *c) { (void)c;
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 168, 168) cornerRadius:38] addClip]; [ic drawInRect:CGRectMake(0, 0, 168, 168)]; }];
    UIImageView *iv = [[UIImageView alloc] initWithImage:rounded]; iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.layer.shadowColor = UIColor.blackColor.CGColor; iv.layer.shadowOpacity = 0.35; iv.layer.shadowRadius = 12; iv.layer.shadowOffset = CGSizeMake(0, 6);
    UIView *dot = [UIView new]; dot.translatesAutoresizingMaskIntoConstraints = NO; dot.backgroundColor = s2a_notice_accent(); dot.layer.cornerRadius = 16;
    dot.layer.borderWidth = 2.5; dot.layer.borderColor = [UIColor colorWithWhite:0.08 alpha:1].CGColor;
    UIImageView *s = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold]]];
    s.tintColor = UIColor.whiteColor; s.translatesAutoresizingMaskIntoConstraints = NO; [dot addSubview:s]; [box addSubview:iv]; [box addSubview:dot];
    [NSLayoutConstraint activateConstraints:@[[box.widthAnchor constraintEqualToConstant:84], [box.heightAnchor constraintEqualToConstant:84],
        [iv.leadingAnchor constraintEqualToAnchor:box.leadingAnchor], [iv.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [iv.topAnchor constraintEqualToAnchor:box.topAnchor], [iv.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [dot.widthAnchor constraintEqualToConstant:32], [dot.heightAnchor constraintEqualToConstant:32],
        [dot.centerXAnchor constraintEqualToAnchor:box.trailingAnchor constant:-4], [dot.centerYAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4],
        [s.centerXAnchor constraintEqualToAnchor:dot.centerXAnchor], [s.centerYAnchor constraintEqualToAnchor:dot.centerYAnchor]]];
    return box;
}
UIView *s2a_notice_page(CGRect f, NSString *symbol, NSString *title, NSString *body, float progress, NSString *caption, NSArray<UIButton *> *buttons) {
    UIView *content, *page = backdrop(f, &content);
    UILabel *t = label(24, UIFontWeightBold, UIColor.labelColor); t.text = title; t.textAlignment = NSTextAlignmentCenter;
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:badge_icon(symbol), t, nil];
    if (body.length) { UILabel *b = label(16, UIFontWeightRegular, UIColor.secondaryLabelColor); b.text = body; b.textAlignment = NSTextAlignmentCenter; [rows addObject:b]; }
    if (progress >= 0) {
        UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar]; bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.progressTintColor = [UIColor colorWithWhite:1 alpha:0.92]; bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.14]; bar.layer.cornerRadius = 2; bar.clipsToBounds = YES;
        bar.progress = progress; [bar.heightAnchor constraintEqualToConstant:4].active = YES;
        UILabel *c = label(13, UIFontWeightRegular, UIColor.tertiaryLabelColor); c.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular]; c.text = caption ?: @"";
        c.textAlignment = NSTextAlignmentCenter;
        UIStackView *p = [[UIStackView alloc] initWithArrangedSubviews:@[bar, c]]; p.axis = UILayoutConstraintAxisVertical; p.spacing = 8; [rows addObject:p];
        [bar.widthAnchor constraintEqualToConstant:360].active = YES;
    }
    if (buttons.count) { UIStackView *bs = [[UIStackView alloc] initWithArrangedSubviews:buttons]; bs.spacing = 12; [rows addObject:bs]; }
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:rows]; col.axis = UILayoutConstraintAxisVertical; col.alignment = UIStackViewAlignmentCenter; col.spacing = 10;
    [col setCustomSpacing:20 afterView:rows[0]]; if (rows.count > 2) [col setCustomSpacing:24 afterView:rows[rows.count - 2]];
    place(content, col, 520);
    return page;
}

static UIView *glyph(NSString *sym, NSString *cap) {
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightRegular]]];
    iv.tintColor = UIColor.whiteColor; iv.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *l = label(13, UIFontWeightRegular, UIColor.secondaryLabelColor); l.text = cap; l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 2;
    [l.widthAnchor constraintLessThanOrEqualToConstant:96].active = YES;   // App 名长时折两行，不截成「…」
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[iv, l]]; v.axis = UILayoutConstraintAxisVertical; v.spacing = 6; v.alignment = UIStackViewAlignmentCenter; return v;
}
static UIView *arrow(void) {
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]]];
    iv.tintColor = UIColor.tertiaryLabelColor; return iv;
}
UIView *s2a_notice_help_page(CGRect f, NSString *title, NSString *detail, NSString *app, UIButton *recheck) {
    UIView *content, *page = backdrop(f, &content);
    UIStackView *pic = [[UIStackView alloc] initWithArrangedSubviews:@[glyph(@"laptopcomputer", @"Mac"), arrow(), glyph(@"cable.connector", S2AL(@"notice.cable")), arrow(), glyph(@"iphone.gen3", app)]];
    pic.spacing = 10; pic.alignment = UIStackViewAlignmentCenter;
    UIImageView *folder = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"folder.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular]]];
    folder.tintColor = s2a_notice_accent();
    UILabel *fl = label(15, UIFontWeightMedium, UIColor.labelColor); NSString *pack = [NSString stringWithFormat:@"%@资源包", app];   // 设备上的文件夹名（与 Mac 启动器约定），不翻译
    fl.text = [NSString stringWithFormat:S2AL(@"notice.folder"), pack];
    UIStackView *fr = [[UIStackView alloc] initWithArrangedSubviews:@[folder, fl]]; fr.spacing = 8; fr.alignment = UIStackViewAlignmentCenter;
    UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[pic, fr]]; left.axis = UILayoutConstraintAxisVertical; left.spacing = 20; left.alignment = UIStackViewAlignmentCenter;
    UILabel *t = label(24, UIFontWeightBold, UIColor.labelColor); t.text = title;
    UILabel *d = label(16, UIFontWeightRegular, UIColor.secondaryLabelColor); d.text = detail;
    NSArray *steps = @[
        S2AL(@"notice.step1"),
        [NSString stringWithFormat:S2AL(@"notice.step2"), app],
        [NSString stringWithFormat:S2AL(@"notice.step3"), pack, app]];
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:t, d, nil];
    for (NSUInteger i = 0; i < steps.count; i++) {
        UILabel *n = label(13, UIFontWeightBold, UIColor.whiteColor); n.text = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1]; n.textAlignment = NSTextAlignmentCenter;
        n.backgroundColor = s2a_notice_accent(); n.layer.cornerRadius = 11; n.clipsToBounds = YES;
        [n.widthAnchor constraintEqualToConstant:22].active = YES; [n.heightAnchor constraintEqualToConstant:22].active = YES;
        UILabel *x = label(15, UIFontWeightRegular, UIColor.labelColor); x.text = steps[i];
        UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[n, x]]; r.spacing = 12; r.alignment = UIStackViewAlignmentTop; [rows addObject:r];
    }
    UIView *gap = [UIView new]; [gap setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];   // 按钮按字宽，不拉满整栏
    [recheck setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *bw = [[UIStackView alloc] initWithArrangedSubviews:@[recheck, gap]]; [rows addObject:bw];
    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:rows]; right.axis = UILayoutConstraintAxisVertical; right.spacing = 14;
    [right setCustomSpacing:22 afterView:d]; [right setCustomSpacing:24 afterView:rows[rows.count - 2]];
    UIStackView *all = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]]; all.spacing = 40; all.alignment = UIStackViewAlignmentCenter;
    [left.widthAnchor constraintEqualToAnchor:all.widthAnchor multiplier:0.36].active = YES;
    place(content, all, 820);
    return page;
}
