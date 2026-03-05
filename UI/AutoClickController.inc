#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AutoClickController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) UIView *controlBar;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIButton *plusButton;
@property(nonatomic,strong) UIButton *minusButton;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *saveButton;
@property(nonatomic,strong) UIButton *loadButton;
@property(nonatomic,strong) UIButton *menuButton;
@property(nonatomic,strong) NSMutableArray<UIButton *> *markerButtons;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *markerMeta;
@property(nonatomic,strong) NSTimer *loopTimer;
@property(nonatomic) BOOL running;
@property(nonatomic) NSInteger currentLoopIndex;
@property(nonatomic) NSTimeInterval lastTapMonotonic;
@property(nonatomic) NSTimeInterval minTapGap;
@property(nonatomic,weak) UIWindow *hostWindow;
@property(nonatomic) BOOL didMoveControlsToHostWindow;
@property(nonatomic) BOOL detachedFromMenu;
@property(nonatomic,strong) NSURL *pendingExportURL;
@property(nonatomic) BOOL expectingImportSelection;
@end

static AutoClickController *gDetachedAutoClickController = nil;

@interface AutoClickPassthroughView : UIView
@end

@implementation AutoClickPassthroughView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        if (sub.hidden || !sub.userInteractionEnabled || sub.alpha < 0.01) continue;
        CGPoint p = [self convertPoint:point toView:sub];
        if ([sub pointInside:p withEvent:event]) return YES;
    }
    return NO;
}
@end

@interface AutoClickOverlayWindow : UIWindow
@end

@implementation AutoClickOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return v;
}
@end

@implementation AutoClickController

- (void)detachMenuIfNeeded {
    if (self.detachedFromMenu) return;
    if (!self.navigationController) return;
    if (!self.navigationController.presentingViewController) return;
    self.detachedFromMenu = YES;
    gDetachedAutoClickController = self;
    [self.navigationController dismissViewControllerAnimated:NO completion:nil];
}

- (void)loadView {
    self.view = [[AutoClickPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"オートクリック";
    self.view.backgroundColor = UIColor.clearColor;
    self.markerButtons = [NSMutableArray array];
    self.markerMeta = [NSMutableDictionary dictionary];
    self.currentLoopIndex = 0;
    self.lastTapMonotonic = 0;
    self.minTapGap = 0.10;

    self.navigationItem.leftBarButtonItem = nil;

    self.controlBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.controlBar.backgroundColor = [ThemeBackgroundColor() colorWithAlphaComponent:0.55];
    self.controlBar.layer.cornerRadius = 10;
    self.controlBar.layer.borderWidth = 1;
    self.controlBar.layer.borderColor = ThemeBorderColor().CGColor;
    self.controlBar.userInteractionEnabled = YES;
    [self.view addSubview:self.controlBar];

    UIPanGestureRecognizer *barPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleControlBarPan:)];
    [self.controlBar addGestureRecognizer:barPan];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textColor = ThemeSecondaryTextColor();
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    self.statusLabel.text = @"+/-/Start";
    [self.controlBar addSubview:self.statusLabel];

    self.plusButton = [self makeControlButton:@"+"
                                       action:@selector(addMarkerTapped)];
    self.minusButton = [self makeControlButton:@"-"
                                        action:@selector(removeMarkerTapped)];
    self.startButton = [self makeControlButton:@"Start"
                                        action:@selector(startTapped)];
    self.saveButton = [self makeControlButton:@"Save"
                                       action:@selector(saveLayoutTapped)];
    self.loadButton = [self makeControlButton:@"Load"
                                       action:@selector(loadLayoutTapped)];
    self.menuButton = [self makeControlButton:@"Menu"
                                       action:@selector(backToMainMenu)];
    [self.controlBar addSubview:self.plusButton];
    [self.controlBar addSubview:self.minusButton];
    [self.controlBar addSubview:self.startButton];
    [self.controlBar addSubview:self.saveButton];
    [self.controlBar addSubview:self.loadButton];
    [self.controlBar addSubview:self.menuButton];
}

- (UIButton *)makeControlButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = ThemeBorderColor().CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:ThemePrimaryTextColor() forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self prepareTransparentOverlay];
    [self activateOverlayWindow];
    [self detachMenuIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.detachedFromMenu) return;
    [self deactivateOverlayWindow];
    [self.loopTimer invalidate];
    self.loopTimer = nil;
    self.running = NO;
}

- (UIView *)canvasView {
    return self.hostWindow ?: self.view;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CGRectIsEmpty(self.controlBar.frame)) {
        CGFloat w = 282;
        CGFloat h = 92;
        UIView *canvas = [self canvasView];
        CGFloat x = canvas.bounds.size.width - w - 10;
        CGFloat y = canvas.safeAreaInsets.top + 6;
        self.controlBar.frame = CGRectMake(x, y, w, h);
    }
    self.statusLabel.frame = CGRectMake(8, 5, self.controlBar.bounds.size.width - 16, 12);
    CGFloat row1Y = 20;
    CGFloat row2Y = 54;
    CGFloat w = (self.controlBar.bounds.size.width - 24) / 3.0;
    self.plusButton.frame = CGRectMake(6, row1Y, w, 28);
    self.minusButton.frame = CGRectMake(CGRectGetMaxX(self.plusButton.frame) + 6, row1Y, w, 28);
    self.startButton.frame = CGRectMake(CGRectGetMaxX(self.minusButton.frame) + 6, row1Y, w, 28);
    self.saveButton.frame = CGRectMake(6, row2Y, w, 28);
    self.loadButton.frame = CGRectMake(CGRectGetMaxX(self.saveButton.frame) + 6, row2Y, w, 28);
    self.menuButton.frame = CGRectMake(CGRectGetMaxX(self.loadButton.frame) + 6, row2Y, w, 28);
}

- (void)prepareTransparentOverlay {
    self.view.opaque = NO;
    self.view.backgroundColor = UIColor.clearColor;
    self.navigationController.view.backgroundColor = UIColor.clearColor;
    self.navigationController.navigationBar.translucent = YES;
}

- (void)activateOverlayWindow {
    if (self.didMoveControlsToHostWindow) return;
    self.hostWindow = self.view.window;
    if (!self.hostWindow) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.windows.count > 0) {
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) {
                        self.hostWindow = w;
                        break;
                    }
                }
                if (!self.hostWindow) self.hostWindow = ws.windows.firstObject;
            }
            if (self.hostWindow) break;
        }
    }
    if (!self.hostWindow) return;

    UIView *from = self.controlBar.superview ?: self.view;
    CGRect f = [from convertRect:self.controlBar.frame toView:self.hostWindow];
    [self.controlBar removeFromSuperview];
    self.controlBar.frame = f;
    [self.hostWindow addSubview:self.controlBar];
    for (UIButton *m in self.markerButtons) {
        UIView *mv = m.superview ?: self.view;
        CGRect mf = [mv convertRect:m.frame toView:self.hostWindow];
        [m removeFromSuperview];
        m.frame = mf;
        [self.hostWindow addSubview:m];
    }
    self.didMoveControlsToHostWindow = YES;

    self.view.hidden = YES;
    self.view.userInteractionEnabled = NO;
    self.navigationController.view.hidden = YES;
    self.navigationController.view.userInteractionEnabled = NO;
    self.navigationController.navigationBarHidden = YES;
}

- (void)deactivateOverlayWindow {
    if (self.didMoveControlsToHostWindow) {
        UIView *from = self.controlBar.superview ?: self.hostWindow;
        CGRect f = [from convertRect:self.controlBar.frame toView:self.view];
        [self.controlBar removeFromSuperview];
        self.controlBar.frame = f;
        [self.view addSubview:self.controlBar];

        for (UIButton *m in self.markerButtons) {
            UIView *mv = m.superview ?: self.hostWindow;
            CGRect mf = [mv convertRect:m.frame toView:self.view];
            [m removeFromSuperview];
            m.frame = mf;
            [self.view addSubview:m];
        }
        self.didMoveControlsToHostWindow = NO;
    }
    self.view.hidden = NO;
    self.view.userInteractionEnabled = YES;
    self.navigationController.view.hidden = NO;
    self.navigationController.view.userInteractionEnabled = YES;
    self.navigationController.navigationBarHidden = NO;
    self.hostWindow = nil;
}

- (void)backToMainMenu {
    [self.loopTimer invalidate];
    self.loopTimer = nil;
    self.running = NO;
    self.detachedFromMenu = NO;
    gDetachedAutoClickController = nil;
    [self deactivateOverlayWindow];
    if (!self.navigationController) {
        PresentMonitorMenuFromActiveWindow();
        return;
    }
    for (UIViewController *vc in self.navigationController.viewControllers) {
        if ([NSStringFromClass(vc.class) isEqualToString:@"MonitorViewController"]) {
            [self.navigationController popToViewController:vc animated:YES];
            return;
        }
    }
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)addMarkerTapped {
    NSInteger nextIndex = 1;
    for (UIButton *b in self.markerButtons) nextIndex = MAX(nextIndex, b.tag + 1);

    UIButton *marker = [UIButton buttonWithType:UIButtonTypeSystem];
    marker.tag = nextIndex;
    UIView *canvas = [self canvasView];
    marker.frame = CGRectMake((canvas.bounds.size.width - 40) * 0.5,
                              (canvas.bounds.size.height - 40) * 0.5,
                              40, 40);
    marker.layer.cornerRadius = 21;
    marker.layer.borderWidth = 1;
    marker.layer.borderColor = ThemeBorderColor().CGColor;
    marker.backgroundColor = [ThemeBackgroundColor() colorWithAlphaComponent:0.82];
    [marker setTitle:[NSString stringWithFormat:@"%ld", (long)nextIndex] forState:UIControlStateNormal];
    [marker setTitleColor:ThemePrimaryTextColor() forState:UIControlStateNormal];
    [marker addTarget:self action:@selector(markerTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMarkerPan:)];
    [marker addGestureRecognizer:pan];

    [canvas addSubview:marker];
    [self.markerButtons addObject:marker];
    self.markerMeta[@(nextIndex)] = [@{
        @"interval": @1.0,
        @"nextFire": @([[NSDate date] timeIntervalSince1970])
    } mutableCopy];
    self.statusLabel.text = [NSString stringWithFormat:@"marker %ld added (1.0s)", (long)nextIndex];
}

- (void)removeMarkerTapped {
    if (self.markerButtons.count == 0) return;
    UIButton *target = nil;
    for (UIButton *b in self.markerButtons) {
        if (!target || b.tag > target.tag) target = b;
    }
    if (!target) return;
    [target removeFromSuperview];
    [self.markerButtons removeObject:target];
    [self.markerMeta removeObjectForKey:@(target.tag)];
    self.statusLabel.text = [NSString stringWithFormat:@"marker %ld removed", (long)target.tag];
}

- (NSString *)layoutFilePath {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = dirs.firstObject ?: NSTemporaryDirectory();
    return [doc stringByAppendingPathComponent:@"autoclick_layout.txt"];
}

- (UIButton *)addMarkerWithIndex:(NSInteger)index center:(CGPoint)center interval:(double)interval {
    UIButton *marker = [UIButton buttonWithType:UIButtonTypeSystem];
    marker.tag = index;
    marker.frame = CGRectMake(0, 0, 40, 40);
    marker.center = center;
    marker.layer.cornerRadius = 21;
    marker.layer.borderWidth = 1;
    marker.layer.borderColor = ThemeBorderColor().CGColor;
    marker.backgroundColor = [ThemeBackgroundColor() colorWithAlphaComponent:0.82];
    [marker setTitle:[NSString stringWithFormat:@"%ld", (long)index] forState:UIControlStateNormal];
    [marker setTitleColor:ThemePrimaryTextColor() forState:UIControlStateNormal];
    [marker addTarget:self action:@selector(markerTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMarkerPan:)];
    [marker addGestureRecognizer:pan];
    [[self canvasView] addSubview:marker];
    [self.markerButtons addObject:marker];
    if (interval <= 0.08) interval = 1.0;
    self.markerMeta[@(index)] = [@{
        @"interval": @(interval),
        @"nextFire": @([[NSDate date] timeIntervalSince1970] + interval)
    } mutableCopy];
    return marker;
}

- (void)saveLayoutTapped {
    NSMutableArray<UIButton *> *sorted = [[self.markerButtons sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return a.tag < b.tag ? NSOrderedAscending : (a.tag > b.tag ? NSOrderedDescending : NSOrderedSame);
    }] mutableCopy];
    NSMutableString *txt = [NSMutableString stringWithString:@"# autoclick layout v1\n# id,x,y,interval\n"];
    for (UIButton *m in sorted) {
        CGPoint p = [m.superview convertPoint:m.center toView:nil];
        NSDictionary *meta = self.markerMeta[@(m.tag)] ?: @{};
        double interval = [meta[@"interval"] doubleValue];
        if (interval <= 0.08) interval = 1.0;
        [txt appendFormat:@"%ld,%.3f,%.3f,%.4f\n", (long)m.tag, p.x, p.y, interval];
    }
    NSString *localPath = [self layoutFilePath];
    NSError *err = nil;
    NSString *dir = [localPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL okLocal = [txt writeToFile:localPath atomically:YES encoding:NSUTF8StringEncoding error:&err];

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"autoclick_layout.txt"];
    NSError *tmpErr = nil;
    BOOL okTmp = [txt writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:&tmpErr];
    if (okTmp) {
        self.pendingExportURL = [NSURL fileURLWithPath:tmpPath];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[self.pendingExportURL] asCopy:YES];
        picker.delegate = self;
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
        UIViewController *presenter = TopMostViewControllerFromActiveWindow();
        if (presenter) {
            [presenter presentViewController:picker animated:YES completion:nil];
            self.statusLabel.text = @"export txt...";
            return;
        }
    }
    self.statusLabel.text = okLocal ? @"saved local: Documents/autoclick_layout.txt" : [NSString stringWithFormat:@"save failed: %@", err.localizedDescription ?: tmpErr.localizedDescription ?: @"error"];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.expectingImportSelection = NO;
    self.statusLabel.text = @"cancelled";
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (self.expectingImportSelection) {
        self.expectingImportSelection = NO;
        NSURL *u = urls.firstObject;
        if (!u) {
            self.statusLabel.text = @"load failed: no file";
            return;
        }
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSError *err = nil;
        NSString *txt = [NSString stringWithContentsOfURL:u encoding:NSUTF8StringEncoding error:&err];
        if (scoped) [u stopAccessingSecurityScopedResource];
        if (!txt.length) {
            self.statusLabel.text = [NSString stringWithFormat:@"load failed: %@", err.localizedDescription ?: @"read error"];
            return;
        }
        [txt writeToFile:[self layoutFilePath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self applyLayoutFromText:txt];
        return;
    }
    self.statusLabel.text = @"exported txt";
}

- (void)loadLayoutTapped {
    self.expectingImportSelection = YES;
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePlainText, UTTypeText] asCopy:YES];
    }
    if (!picker) {
        self.statusLabel.text = @"load failed: picker";
        return;
    }
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    UIViewController *presenter = TopMostViewControllerFromActiveWindow();
    if (!presenter) {
        self.statusLabel.text = @"load failed: presenter";
        return;
    }
    [presenter presentViewController:picker animated:YES completion:nil];
    self.statusLabel.text = @"select txt...";
}

- (void)applyLayoutFromText:(NSString *)txt {
    if (!txt.length) {
        self.statusLabel.text = @"load failed: empty";
        return;
    }
    for (UIButton *b in self.markerButtons) [b removeFromSuperview];
    [self.markerButtons removeAllObjects];
    [self.markerMeta removeAllObjects];

    UIView *canvas = [self canvasView];
    NSArray<NSString *> *lines = [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSInteger loaded = 0;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@","];
        if (parts.count < 4) continue;
        NSInteger idx = [parts[0] integerValue];
        CGFloat sx = (CGFloat)[parts[1] doubleValue];
        CGFloat sy = (CGFloat)[parts[2] doubleValue];
        double interval = [parts[3] doubleValue];
        if (idx <= 0) continue;
        CGPoint screen = CGPointMake(sx, sy);
        CGPoint center = [canvas convertPoint:screen fromView:nil];
        CGFloat halfW = 20.0, halfH = 20.0;
        center.x = MAX(halfW, MIN(canvas.bounds.size.width - halfW, center.x));
        center.y = MAX(halfH, MIN(canvas.bounds.size.height - halfH, center.y));
        [self addMarkerWithIndex:idx center:center interval:interval];
        loaded++;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"loaded %ld markers", (long)loaded];
}

- (void)startTapped {
    [self detachMenuIfNeeded];
    self.running = !self.running;
    [self.startButton setTitle:(self.running ? @"Stop" : @"Start") forState:UIControlStateNormal];
    if (self.running) {
        [self.loopTimer invalidate];
        self.loopTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                          target:self
                                                        selector:@selector(loopTick)
                                                        userInfo:nil
                                                         repeats:YES];
        self.statusLabel.text = @"running...";
    } else {
        [self.loopTimer invalidate];
        self.loopTimer = nil;
        self.statusLabel.text = @"stopped";
    }
}

- (void)markerTapped:(UIButton *)marker {
    NSMutableDictionary *meta = self.markerMeta[@(marker.tag)] ?: [NSMutableDictionary dictionary];
    NSString *current = [NSString stringWithFormat:@"%.3f", [meta[@"interval"] doubleValue] > 0 ? [meta[@"interval"] doubleValue] : 1.0];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"#%ld 間隔(秒)", (long)marker.tag]
                                        message:@"このアイコンのタップ間隔を設定"
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = current;
        field.placeholder = @"例: 0.5";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction * _Nonnull action) {
        double v = [alert.textFields.firstObject.text doubleValue];
        if (v <= 0.08) v = 0.08;
        meta[@"interval"] = @(v);
        meta[@"nextFire"] = @([[NSDate date] timeIntervalSince1970] + v);
        self.markerMeta[@(marker.tag)] = meta;
        self.statusLabel.text = [NSString stringWithFormat:@"#%ld interval=%.3fs", (long)marker.tag, v];
    }]];
    UIViewController *presenter = nil;
    if (self.view.window && !self.view.hidden) {
        presenter = self;
    }
    if (!presenter) presenter = TopMostViewControllerFromActiveWindow();
    if (!presenter) return;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)handleMarkerPan:(UIPanGestureRecognizer *)gr {
    UIView *v = gr.view;
    UIView *canvas = [self canvasView];
    CGPoint t = [gr translationInView:canvas];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    CGFloat halfW = v.bounds.size.width * 0.5;
    CGFloat halfH = v.bounds.size.height * 0.5;
    c.x = MAX(halfW, MIN(canvas.bounds.size.width - halfW, c.x));
    c.y = MAX(halfH, MIN(canvas.bounds.size.height - halfH, c.y));
    v.center = c;
    [gr setTranslation:CGPointZero inView:canvas];
}

- (void)handleControlBarPan:(UIPanGestureRecognizer *)gr {
    UIView *canvas = [self canvasView];
    CGPoint t = [gr translationInView:canvas];
    CGPoint c = self.controlBar.center;
    c.x += t.x;
    c.y += t.y;
    CGFloat halfW = self.controlBar.bounds.size.width * 0.5;
    CGFloat halfH = self.controlBar.bounds.size.height * 0.5;
    c.x = MAX(halfW, MIN(canvas.bounds.size.width - halfW, c.x));
    c.y = MAX(halfH, MIN(canvas.bounds.size.height - halfH, c.y));
    self.controlBar.center = c;
    [gr setTranslation:CGPointZero inView:canvas];
}

- (void)loopTick {
    if (!self.running || self.markerButtons.count == 0) return;
    NSTimeInterval monoNow = CACurrentMediaTime();
    if (self.lastTapMonotonic > 0 && (monoNow - self.lastTapMonotonic) < self.minTapGap) return;
    NSArray<UIButton *> *sorted = [self.markerButtons sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        if (a.tag < b.tag) return NSOrderedAscending;
        if (a.tag > b.tag) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger n = sorted.count;
    for (NSInteger offset = 0; offset < n; offset++) {
        NSInteger idx = (self.currentLoopIndex + offset) % n;
        UIButton *marker = sorted[idx];
        NSMutableDictionary *meta = self.markerMeta[@(marker.tag)];
        if (!meta) continue;
        double interval = [meta[@"interval"] doubleValue];
        if (interval <= 0.08) interval = 0.08;
        double nextFire = [meta[@"nextFire"] doubleValue];
        if (now < nextFire) continue;

        [self performTapAtMarker:marker];
        self.lastTapMonotonic = CACurrentMediaTime();
        meta[@"nextFire"] = @(now + interval);
        self.currentLoopIndex = (idx + 1) % n;
        break;
    }
}

- (void)performTapAtMarker:(UIButton *)marker {
    [UIView animateWithDuration:0.08 animations:^{
        marker.transform = CGAffineTransformMakeScale(0.82, 0.82);
        marker.alpha = 0.55;
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.08 animations:^{
            marker.transform = CGAffineTransformIdentity;
            marker.alpha = 1.0;
        }];
    }];

    CGPoint pScreen = [marker.superview convertPoint:marker.center toView:nil];
    UIWindow *targetWindow = self.hostWindow ?: self.view.window;
    NSMutableArray<UIView *> *overlayViews = [NSMutableArray arrayWithObject:self.controlBar];
    [overlayViews addObjectsFromArray:self.markerButtons];
    NSMutableArray<NSNumber *> *interactionBackup = [NSMutableArray arrayWithCapacity:overlayViews.count];
    for (UIView *v in overlayViews) {
        [interactionBackup addObject:@(v.userInteractionEnabled)];
        v.userInteractionEnabled = NO;
    }
    if (InjectViaPTFakeTouch(pScreen, targetWindow)) {
        for (NSUInteger i = 0; i < overlayViews.count; i++) {
            UIView *v = overlayViews[i];
            BOOL old = (i < interactionBackup.count) ? interactionBackup[i].boolValue : YES;
            v.userInteractionEnabled = old;
        }
        return;
    }
    if (InjectIOHIDTapAtScreenPoint(pScreen, targetWindow)) {
        for (NSUInteger i = 0; i < overlayViews.count; i++) {
            UIView *v = overlayViews[i];
            BOOL old = (i < interactionBackup.count) ? interactionBackup[i].boolValue : YES;
            v.userInteractionEnabled = old;
        }
        return;
    }
    if (InjectSyntheticTapAtScreenPoint(pScreen, targetWindow)) {
        for (NSUInteger i = 0; i < overlayViews.count; i++) {
            UIView *v = overlayViews[i];
            BOOL old = (i < interactionBackup.count) ? interactionBackup[i].boolValue : YES;
            v.userInteractionEnabled = old;
        }
        return;
    }
    if (DispatchDirectResponderTapAtScreenPoint(pScreen, targetWindow)) {
        for (NSUInteger i = 0; i < overlayViews.count; i++) {
            UIView *v = overlayViews[i];
            BOOL old = (i < interactionBackup.count) ? interactionBackup[i].boolValue : YES;
            v.userInteractionEnabled = old;
        }
        return;
    }

    if (!targetWindow) {
        for (NSUInteger i = 0; i < overlayViews.count; i++) {
            UIView *v = overlayViews[i];
            BOOL old = (i < interactionBackup.count) ? interactionBackup[i].boolValue : YES;
            v.userInteractionEnabled = old;
        }
        return;
    }
    CGPoint pInTarget = [targetWindow convertPoint:pScreen fromWindow:nil];
    UIView *hit = [targetWindow hitTest:pInTarget withEvent:nil];
    UIView *target = hit;
    while (target && ![target isKindOfClass:[UIControl class]]) target = target.superview;
    if ([target isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)target;
        [control sendActionsForControlEvents:UIControlEventTouchDown];
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    for (NSUInteger i = 0; i < overlayViews.count; i++) {
        UIView *v = overlayViews[i];
        BOOL old = (i < interactionBackup.count) ? interactionBackup[i].boolValue : YES;
        v.userInteractionEnabled = old;
    }
}

@end
