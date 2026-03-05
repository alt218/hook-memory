#import <UIKit/UIKit.h>

extern void LoggerInit(void);

static UIButton *logButton;
static CGPoint dragStartCenter;

static UIWindow *ActiveWindow() {

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {

        if (scene.activationState != UISceneActivationStateForegroundActive)
            continue;

        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;

        UIWindowScene *ws = (UIWindowScene *)scene;

        for (UIWindow *w in ws.windows)
            if (w.isKeyWindow)
                return w;

        return ws.windows.firstObject;
    }

    return nil;
}

@interface NSObject (OpenMonitor)
- (void)openMonitor;
- (void)handleLogButtonPan:(UIPanGestureRecognizer *)gesture;
@end

@implementation NSObject (OpenMonitor)

- (void)openMonitor {

    UIWindow *window = ActiveWindow();
    if (!window) return;

    UIViewController *root = window.rootViewController;
    while (root.presentedViewController)
        root = root.presentedViewController;

    UIViewController *vc = [NSClassFromString(@"MonitorViewController") new];
    if (!vc) return;

    UINavigationController *nav =
    [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    [root presentViewController:nav animated:YES completion:nil];
}

- (void)handleLogButtonPan:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view || !view.superview) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        dragStartCenter = view.center;
    }

    CGPoint translation = [gesture translationInView:view.superview];
    CGPoint nextCenter = CGPointMake(dragStartCenter.x + translation.x,
                                     dragStartCenter.y + translation.y);

    CGFloat halfW = CGRectGetWidth(view.bounds) * 0.5;
    CGFloat halfH = CGRectGetHeight(view.bounds) * 0.5;
    CGFloat minX = halfW;
    CGFloat maxX = CGRectGetWidth(view.superview.bounds) - halfW;
    CGFloat minY = halfH;
    CGFloat maxY = CGRectGetHeight(view.superview.bounds) - halfH;

    nextCenter.x = MIN(MAX(nextCenter.x, minX), maxX);
    nextCenter.y = MIN(MAX(nextCenter.y, minY), maxY);
    view.center = nextCenter;
}

@end


%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (logButton) return;

    UIWindow *window = ActiveWindow();
    if (!window) return;

    logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    logButton.frame = CGRectMake(20, 200, 48, 48);
    logButton.backgroundColor = UIColor.redColor;
    logButton.layer.cornerRadius = 24;
    logButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [logButton setTitle:@"星那" forState:UIControlStateNormal];
    [logButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];

    [logButton addTarget:self
                  action:@selector(openMonitor)
        forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
    [[UIPanGestureRecognizer alloc] initWithTarget:self
                                            action:@selector(handleLogButtonPan:)];
    pan.cancelsTouchesInView = NO;
    [logButton addGestureRecognizer:pan];

    [window addSubview:logButton];
}

%end
