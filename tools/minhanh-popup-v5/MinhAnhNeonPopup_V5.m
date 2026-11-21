#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>

/// MinhAnh Multi Neon Popup v5 — tested at build level, not on a physical iPhone.
/// No method swizzling, no separate UIWindow, and no UIKit work in the constructor.
/// Intended only for applications the owner is authorized to modify.

static BOOL MAAppWasActive = NO;
static BOOL MAShownThisActivation = NO;
static BOOL MASkipReturnFromTelegram = NO;
static unsigned MAReadyTicks = 0;
static const NSInteger MAOverlayTag = 0x4D415035;

static UIColor *MACyan(void) {
    return [UIColor colorWithRed:0.07 green:0.84 blue:1.0 alpha:1];
}
static UIColor *MAGreen(void) {
    return [UIColor colorWithRed:0.18 green:1.0 blue:0.49 alpha:1];
}

@interface MAMultiNeonPopupV5 : UIView
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *particles;
@property (nonatomic, strong) CAGradientLayer *panelGradient;
@property (nonatomic, assign) BOOL pressedJoin;
@end

@implementation MAMultiNeonPopupV5

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.tag = MAOverlayTag;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.76];
    self.accessibilityViewIsModal = YES;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    self.panel = panel;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 25;
    panel.layer.borderWidth = 1.8;
    panel.layer.borderColor = MACyan().CGColor;
    panel.layer.shadowColor = MACyan().CGColor;
    panel.layer.shadowOpacity = 0.75;
    panel.layer.shadowRadius = 24;
    panel.layer.shadowOffset = CGSizeZero;
    [self addSubview:panel];

    NSLayoutConstraint *preferredWidth = [panel.widthAnchor constraintEqualToConstant:350];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-32],
        preferredWidth,
        [panel.heightAnchor constraintEqualToConstant:345]
    ]];

    CAGradientLayer *gradient = [CAGradientLayer layer];
    self.panelGradient = gradient;
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.035 green:0.092 blue:0.15 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.025 green:0.08 blue:0.11 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.025 green:0.11 blue:0.07 alpha:1].CGColor
    ];
    gradient.startPoint = CGPointMake(0.08, 0.0);
    gradient.endPoint = CGPointMake(0.9, 1.0);
    gradient.cornerRadius = 24;
    [panel.layer insertSublayer:gradient atIndex:0];

    UIView *particles = [[UIView alloc] initWithFrame:CGRectZero];
    self.particles = particles;
    particles.userInteractionEnabled = NO;
    particles.clipsToBounds = YES;
    particles.layer.cornerRadius = 24;
    particles.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:particles];

    for (NSInteger i = 0; i < 16; i++) {
        CGFloat diameter = 3.0 + (i % 4) * 1.4;
        CGFloat x = 10 + ((i * 71) % 315);
        CGFloat y = 306 + ((i * 13) % 38);
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(x, y, diameter, diameter)];
        UIColor *color = ((i % 2) == 0) ? MAGreen() : MACyan();
        dot.backgroundColor = color;
        dot.layer.cornerRadius = diameter * 0.5;
        dot.layer.shadowColor = color.CGColor;
        dot.layer.shadowOpacity = 1.0;
        dot.layer.shadowRadius = 7;
        dot.layer.shadowOffset = CGSizeZero;
        dot.alpha = 0.78;
        [particles addSubview:dot];

        CABasicAnimation *up = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        up.fromValue = @(0);
        up.toValue = @(-270 - ((i * 17) % 52));
        up.duration = 3.1 + (i % 5) * 0.46;
        up.beginTime = CACurrentMediaTime() + ((i * 7) % 15) * 0.17;
        up.repeatCount = HUGE_VALF;
        up.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [dot.layer addAnimation:up forKey:@"maRise"];

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @(0.12);
        pulse.toValue = @(0.95);
        pulse.duration = 0.75 + (i % 4) * 0.23;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        [dot.layer addAnimation:pulse forKey:@"maSparkle"];
    }

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"THÔNG BÁO";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:27 weight:UIFontWeightHeavy];
    title.layer.shadowColor = MACyan().CGColor;
    title.layer.shadowOpacity = 1;
    title.layer.shadowRadius = 12;
    title.layer.shadowOffset = CGSizeZero;
    [panel addSubview:title];

    UIView *divider = [[UIView alloc] init];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = MACyan();
    divider.layer.cornerRadius = 1;
    divider.layer.shadowColor = MAGreen().CGColor;
    divider.layer.shadowRadius = 9;
    divider.layer.shadowOpacity = 0.95;
    [panel addSubview:divider];

    UILabel *message = [[UILabel alloc] init];
    message.translatesAutoresizingMaskIntoConstraints = NO;
    message.text = @"Vào Nhóm Lấy Nhiều Mod Game Hơn Nha!!!";
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;
    message.textColor = [UIColor whiteColor];
    message.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    [panel addSubview:message];

    UILabel *brand = [[UILabel alloc] init];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.text = @"MinhAnhMod - Multi Game";
    brand.textAlignment = NSTextAlignmentCenter;
    brand.numberOfLines = 1;
    brand.adjustsFontSizeToFitWidth = YES;
    brand.minimumScaleFactor = 0.8;
    brand.textColor = MAGreen();
    brand.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    brand.layer.shadowColor = MAGreen().CGColor;
    brand.layer.shadowOpacity = 0.8;
    brand.layer.shadowRadius = 9;
    [panel addSubview:brand];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕ Đóng" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    close.backgroundColor = [UIColor colorWithRed:0.07 green:0.17 blue:0.25 alpha:1];
    close.layer.cornerRadius = 13;
    close.layer.borderWidth = 1.1;
    close.layer.borderColor = MACyan().CGColor;
    [close addTarget:self action:@selector(maClose:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    UIButton *join = [UIButton buttonWithType:UIButtonTypeCustom];
    join.translatesAutoresizingMaskIntoConstraints = NO;
    [join setTitle:@"Vào Nhóm" forState:UIControlStateNormal];
    [join setTitleColor:[UIColor colorWithRed:0.01 green:0.12 blue:0.08 alpha:1] forState:UIControlStateNormal];
    join.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
    join.backgroundColor = MAGreen();
    join.layer.cornerRadius = 13;
    join.layer.shadowColor = MAGreen().CGColor;
    join.layer.shadowOpacity = 0.95;
    join.layer.shadowRadius = 13;
    join.layer.shadowOffset = CGSizeZero;
    [join addTarget:self action:@selector(maJoin:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:join];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:panel.topAnchor constant:35],
        [title.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [title.leadingAnchor constraintGreaterThanOrEqualToAnchor:panel.leadingAnchor constant:16],

        [divider.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [divider.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [divider.widthAnchor constraintEqualToConstant:176],
        [divider.heightAnchor constraintEqualToConstant:2],

        [message.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:29],
        [message.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:26],
        [message.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-26],

        [brand.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:20],
        [brand.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:26],
        [brand.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-26],

        [close.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:22],
        [close.trailingAnchor constraintEqualToAnchor:join.leadingAnchor constant:-11],
        [close.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-24],
        [close.heightAnchor constraintEqualToConstant:51],
        [close.widthAnchor constraintEqualToAnchor:join.widthAnchor],

        [join.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-22],
        [join.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-24],
        [join.heightAnchor constraintEqualToConstant:51],
    ]];

    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    glow.fromValue = @(0.34);
    glow.toValue = @(0.98);
    glow.duration = 1.35;
    glow.autoreverses = YES;
    glow.repeatCount = HUGE_VALF;
    [panel.layer addAnimation:glow forKey:@"maBorderGlow"];

    CABasicAnimation *borderChange = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    borderChange.fromValue = (id)MACyan().CGColor;
    borderChange.toValue = (id)MAGreen().CGColor;
    borderChange.duration = 2.4;
    borderChange.autoreverses = YES;
    borderChange.repeatCount = HUGE_VALF;
    [panel.layer addAnimation:borderChange forKey:@"maBorderColors"];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.panelGradient.frame = self.panel.bounds;
    self.particles.frame = self.panel.bounds;
}

- (void)maClose:(id)sender {
    [self removeFromSuperview];
}

- (void)maJoin:(id)sender {
    if (self.pressedJoin) return;
    self.pressedJoin = YES;
    MASkipReturnFromTelegram = YES;
    [self removeFromSuperview];

    // Wait for dismissal before requesting an app switch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        NSURL *telegram = [NSURL URLWithString:@"tg://resolve?domain=minhanhmulti"];
        NSURL *website = [NSURL URLWithString:@"https://t.me/minhanhmulti"];
        if (!app || !website) return;
        [app openURL:telegram options:@{} completionHandler:^(BOOL didOpenTelegram) {
            if (didOpenTelegram) return;
            [app openURL:website options:@{} completionHandler:^(BOOL didOpenWeb) {
                if (!didOpenWeb) {
                    [UIPasteboard generalPasteboard].string = website.absoluteString;
                    NSLog(@"[MinhAnhPopupV5] Cannot open external link; copied URL to pasteboard.");
                }
            }];
        }];
    });
}
@end

static UIWindow *MAFindWindow(UIApplication *app) {
    if (!app) return nil;
    UIWindow *key = app.keyWindow;
    if (key && !key.hidden && key.rootViewController && key.rootViewController.viewIfLoaded.window)
        return key;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow && !w.hidden && w.rootViewController && w.rootViewController.viewIfLoaded.window)
                    return w;
            }
        }
    }
    for (UIWindow *w in app.windows) {
        if (!w.hidden && w.rootViewController && w.rootViewController.viewIfLoaded.window)
            return w;
    }
    return nil;
}

static void MAHeartbeat(void *unused) {
    (void)unused;
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        if (app && app.applicationState == UIApplicationStateActive) {
            if (!MAAppWasActive) {
                MAAppWasActive = YES;
                MAShownThisActivation = NO;
                MAReadyTicks = 0;
                if (MASkipReturnFromTelegram) {
                    MAShownThisActivation = YES;
                    MASkipReturnFromTelegram = NO;
                }
            }
            if (!MAShownThisActivation && ++MAReadyTicks >= 5) {
                UIWindow *window = MAFindWindow(app);
                if (window) {
                    if (![window viewWithTag:MAOverlayTag]) {
                        MAMultiNeonPopupV5 *popup = [[MAMultiNeonPopupV5 alloc] initWithFrame:window.bounds];
                        [window addSubview:popup];
                        [window bringSubviewToFront:popup];
                    }
                    MAShownThisActivation = YES;
                }
            }
        } else {
            if (MAAppWasActive) {
                UIWindow *window = MAFindWindow(app);
                UIView *old = [window viewWithTag:MAOverlayTag];
                [old removeFromSuperview];
            }
            MAAppWasActive = NO;
            MAReadyTicks = 0;
        }
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                     dispatch_get_main_queue(), NULL, MAHeartbeat);
}

__attribute__((constructor))
static void MAInstall(void) {
    // Match the proven-safe delayed boot sequence of V4.
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, MAHeartbeat);
}
