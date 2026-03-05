#import "MethodListController.h"
#import "ClassManager.h"
#import "HookManager.h"
#import "ExecutionTracker.h"

typedef NS_ENUM(NSInteger, MethodSortMode) {
    MethodSortModeCount = 0,
    MethodSortModeRecent = 1,
    MethodSortModeDuration = 2
};

static BOOL NeedActionConfirm(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:@"monitor_confirm_write"] == nil) return YES;
    return [ud boolForKey:@"monitor_confirm_write"];
}

@interface MethodListController ()

@property(nonatomic,strong) NSString *className;
@property(nonatomic,strong) NSArray<NSString *> *methods;
@property(nonatomic,strong) NSArray<NSString *> *filteredMethods;
@property(nonatomic,strong) NSString *selectedMethod;
@property(nonatomic,strong) UISegmentedControl *sortControl;
@property(nonatomic,strong) UIBarButtonItem *actionsButton;
@property(nonatomic,strong) UIBarButtonItem *filterButton;
@property(nonatomic) MethodSortMode sortMode;
@property(nonatomic,strong) NSString *filterText;
@property(nonatomic,strong) NSMutableSet<NSString *> *pinnedMethods;

@end

@implementation MethodListController

- (instancetype)initWithClassName:(NSString *)className {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _className = className;
        _methods = GetMethodsForClass(className);
        _filteredMethods = _methods ?: @[];
        _sortMode = MethodSortModeCount;
        _filterText = @"";
        _pinnedMethods = [NSMutableSet setWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:[self pinKey]] ?: @[]];
        self.title = className;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 74.0;
    self.tableView.tableFooterView = [UIView new];

    [self setupActionButton];
    [self setupSortControl];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(methodExecuted:) name:@"MethodExecuted" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(methodAutoStopped:) name:@"MethodAutoStopped" object:nil];

    [self applyCurrentSortAndReloadData:NO];
    [self updateCountTitle];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)pinKey {
    return [NSString stringWithFormat:@"pinned_methods_%@", self.className ?: @""];
}

- (void)setupActionButton {
    self.actionsButton = [[UIBarButtonItem alloc] initWithTitle:@"Actions"
                                                          style:UIBarButtonItemStylePlain
                                                         target:self
                                                         action:@selector(showActions)];
    self.filterButton = [[UIBarButtonItem alloc] initWithTitle:@"Filter"
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(filterTapped)];
    self.navigationItem.rightBarButtonItems = @[self.actionsButton, self.filterButton];
}

- (void)setupSortControl {
    self.sortControl = [[UISegmentedControl alloc] initWithItems:@[@"多い順", @"新しい順", @"重い順"]];
    self.sortControl.selectedSegmentIndex = self.sortMode;
    [self.sortControl addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.sortControl;
}

- (void)updateCountTitle {
    NSString *modeText = self.sortMode == MethodSortModeCount ? @"count" : (self.sortMode == MethodSortModeRecent ? @"recent" : @"duration");
    self.navigationItem.prompt = [NSString stringWithFormat:@"Methods: %ld | sort: %@", (long)self.filteredMethods.count, modeText];
}

- (BOOL)isHooked:(NSString *)method {
    return HookManagerIsHooked([self methodKey:method]);
}

- (NSString *)methodKey:(NSString *)method {
    return [NSString stringWithFormat:@"%@::%@::%d", self.className, method, 0];
}

- (void)filterTapped {
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:@"フィルタ" message:@"method名の部分一致" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"empty = all";
        field.text = self.filterText ?: @"";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        self.filterText = @"";
        [self applyCurrentSortAndReloadData:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        self.filterText = alert.textFields.firstObject.text ?: @"";
        [[ExecutionTracker shared] logSessionEvent:@"filter" message:[NSString stringWithFormat:@"%@ filter:%@", self.className ?: @"", self.filterText ?: @""]];
        [self applyCurrentSortAndReloadData:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showActions {
    if (!self.selectedMethod) return;

    BOOL blocked = [[ExecutionTracker shared] isBlocked:[self methodKey:self.selectedMethod]];
    NSString *blockTitle = blocked ? @"Unblock Method" : @"Block Method";

    UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:self.selectedMethod message:@"Action" preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Hook" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self hookTapped]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Unhook" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self unhookTapped]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:blockTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self toggleBlockTapped]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Auto Stop" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self autoStopTapped]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Auto Swap/Disable Rule" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self autoSwapRuleTapped]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Flow Map" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self showFlowMapTapped]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.barButtonItem = self.actionsButton;
    [self presentViewController:sheet animated:YES completion:nil];
    [[ExecutionTracker shared] logSessionEvent:@"method" message:[NSString stringWithFormat:@"open actions %@", self.selectedMethod ?: @""]];
}

- (void)hookTapped {
    if (!self.selectedMethod) return;

    UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:@"Hook Type" message:self.selectedMethod preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[self action:@"Disable" type:HookTypeDisable]];
    [sheet addAction:[self action:@"Return YES" type:HookTypeReturnYES]];
    [sheet addAction:[self action:@"Return NO" type:HookTypeReturnNO]];
    [sheet addAction:[self action:@"Return nil" type:HookTypeReturnNil]];

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Swap Method" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        [weakSelf showSwapTargetSelector];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.actionsButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)unhookTapped {
    if (!self.selectedMethod) return;

    NSDictionary *info = @{ @"class": self.className, @"method": self.selectedMethod, @"isClassMethod": @NO };

    void (^runRemove)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RemoveHook" object:nil userInfo:info];
        [[ExecutionTracker shared] logSessionEvent:@"hook" message:[NSString stringWithFormat:@"unhook %@", self.selectedMethod ?: @""]];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
    };

    if (!NeedActionConfirm()) {
        runRemove();
        return;
    }

    UIAlertController *confirm =
    [UIAlertController alertControllerWithTitle:@"確認"
                                        message:[NSString stringWithFormat:@"Unhook %@ ?", self.selectedMethod ?: @""]
                                 preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"実行" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ runRemove(); }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (UIAlertAction *)action:(NSString *)title type:(HookType)type {
    __weak typeof(self) weakSelf = self;
    return [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSDictionary *info = @{ @"class": weakSelf.className, @"method": weakSelf.selectedMethod, @"type": @(type), @"isClassMethod": @NO };

        void (^applyNow)(void) = ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ApplyHook" object:nil userInfo:info];
            [[ExecutionTracker shared] logSessionEvent:@"hook" message:[NSString stringWithFormat:@"apply %@ %@", title, weakSelf.selectedMethod ?: @""]];
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyCurrentSortAndReloadData:YES]; });
        };

        if (!NeedActionConfirm()) {
            applyNow();
            return;
        }

        NSString *msg = [NSString stringWithFormat:@"Apply %@ to %@?", title, weakSelf.selectedMethod ?: @""];
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"確認" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"実行" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ applyNow(); }]];
        [weakSelf presentViewController:confirm animated:YES completion:nil];
    }];
}

- (void)applyCurrentSortAndReloadData:(BOOL)reload {
    NSArray<NSString *> *base = self.methods ?: @[];
    if (self.filterText.length > 0) {
        NSString *q = self.filterText.lowercaseString;
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *m, NSDictionary *_) {
            return [m.lowercaseString containsString:q];
        }]];
    }
    self.filteredMethods = base;
    [self applySort];
    [self updateCountTitle];
    if (reload) [self.tableView reloadData];
}

- (void)applySort {
    ExecutionTracker *tracker = [ExecutionTracker shared];
    NSArray<NSString *> *sorted =
    [self.filteredMethods sortedArrayUsingComparator:^NSComparisonResult(NSString *m1, NSString *m2) {
        MethodExecutionInfo *i1 = [tracker infoForMethod:[self methodKey:m1]];
        MethodExecutionInfo *i2 = [tracker infoForMethod:[self methodKey:m2]];

        BOOL p1 = [self.pinnedMethods containsObject:m1];
        BOOL p2 = [self.pinnedMethods containsObject:m2];
        if (p1 != p2) return p1 ? NSOrderedAscending : NSOrderedDescending;

        if (self.sortMode == MethodSortModeCount) {
            NSInteger c1 = i1.count;
            NSInteger c2 = i2.count;
            if (c1 != c2) return c1 < c2 ? NSOrderedDescending : NSOrderedAscending;
        } else if (self.sortMode == MethodSortModeRecent) {
            NSDate *d1 = i1.lastExecution ?: [NSDate distantPast];
            NSDate *d2 = i2.lastExecution ?: [NSDate distantPast];
            NSComparisonResult result = [d2 compare:d1];
            if (result != NSOrderedSame) return result;
        } else {
            double t1 = i1.totalDurationMs;
            double t2 = i2.totalDurationMs;
            if (t1 != t2) return t1 < t2 ? NSOrderedDescending : NSOrderedAscending;
        }

        return [m1 compare:m2];
    }];

    self.filteredMethods = sorted;
}

- (void)sortChanged:(UISegmentedControl *)control {
    self.sortMode = (MethodSortMode)control.selectedSegmentIndex;
    [self applyCurrentSortAndReloadData:YES];
}

- (void)toggleBlockTapped {
    if (!self.selectedMethod) return;
    NSString *key = [self methodKey:self.selectedMethod];
    ExecutionTracker *tracker = [ExecutionTracker shared];
    BOOL blocked = [tracker isBlocked:key];
    [tracker setBlocked:!blocked forMethod:key];
    [[ExecutionTracker shared] logSessionEvent:@"block" message:[NSString stringWithFormat:@"%@ %@", !blocked ? @"block" : @"unblock", self.selectedMethod ?: @""]];
    [self applyCurrentSortAndReloadData:YES];
}

- (void)autoStopTapped {
    if (!self.selectedMethod) return;

    NSString *key = [self methodKey:self.selectedMethod];
    NSInteger current = [[ExecutionTracker shared] autoStopLimitForMethod:key];
    NSString *message = [NSString stringWithFormat:@"%@\nCurrent limit: %ld (0 = off)", self.selectedMethod, (long)current];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Auto Stop Count" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"e.g. 50";
        field.text = current > 0 ? [@(current) stringValue] : @"";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSInteger limit = [alert.textFields.firstObject.text integerValue];
        [[ExecutionTracker shared] setAutoStopLimit:limit forMethod:key];
        [[ExecutionTracker shared] logSessionEvent:@"rule" message:[NSString stringWithFormat:@"autoStop %@ = %ld", self.selectedMethod ?: @"", (long)limit]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)autoSwapRuleTapped {
    if (!self.selectedMethod) return;

    NSString *key = [self methodKey:self.selectedMethod];
    NSDictionary *rule = [[ExecutionTracker shared] autoSwapRuleForMethod:key];
    NSInteger swapAt = [rule[@"swapAt"] integerValue];
    NSInteger disableAt = [rule[@"disableAt"] integerValue];
    NSString *targetMethod = rule[@"targetMethod"] ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Auto Swap/Disable" message:@"swapAt, disableAt, targetMethod" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"swapAt (e.g. 10)";
        field.text = swapAt > 0 ? [@(swapAt) stringValue] : @"";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"disableAt (e.g. 50)";
        field.text = disableAt > 0 ? [@(disableAt) stringValue] : @"";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"target method (for swap)";
        field.text = targetMethod;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSInteger s = [alert.textFields[0].text integerValue];
        NSInteger d = [alert.textFields[1].text integerValue];
        NSString *target = alert.textFields[2].text ?: @"";
        [[ExecutionTracker shared] setAutoSwapAt:s disableAt:d targetMethod:target forMethod:key];
        [[ExecutionTracker shared] logSessionEvent:@"rule" message:[NSString stringWithFormat:@"swapRule %@ swap:%ld disable:%ld target:%@", self.selectedMethod ?: @"", (long)s, (long)d, target]];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showFlowMapTapped {
    if (!self.selectedMethod) return;
    NSString *summary = [[ExecutionTracker shared] flowSummaryForMethod:[self methodKey:self.selectedMethod]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Flow Map" message:summary preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)methodExecuted:(NSNotification *)note {
    NSString *methodKey = note.userInfo[@"method"];
    if (![methodKey hasPrefix:[NSString stringWithFormat:@"%@::", self.className]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyCurrentSortAndReloadData:YES]; });
}

- (void)methodAutoStopped:(NSNotification *)note {
    NSString *methodKey = note.userInfo[@"method"];
    if (![methodKey hasPrefix:[NSString stringWithFormat:@"%@::", self.className]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyCurrentSortAndReloadData:YES]; });
}

- (void)showSwapTargetSelector {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Swap with" message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *method in self.methods) {
        [sheet addAction:[UIAlertAction actionWithTitle:method style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSDictionary *info = @{ @"class": self.className, @"method1": self.selectedMethod, @"method2": method, @"isClassMethod": @NO };
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SwapMethods" object:nil userInfo:info];
            [[ExecutionTracker shared] logSessionEvent:@"swap" message:[NSString stringWithFormat:@"%@ <-> %@", self.selectedMethod ?: @"", method ?: @""]];
            [self.tableView reloadData];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.actionsButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.filteredMethods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
    }

    NSString *method = self.filteredMethods[indexPath.row];
    BOOL pinned = [self.pinnedMethods containsObject:method];
    cell.textLabel.text = pinned ? [NSString stringWithFormat:@"★ %@", method] : method;

    BOOL hooked = [self isHooked:method];
    cell.textLabel.textColor = hooked ? UIColor.systemGreenColor : UIColor.greenColor;

    MethodExecutionInfo *info = [[ExecutionTracker shared] infoForMethod:[self methodKey:method]];
    if (info) {
        NSTimeInterval unix = info.lastExecution.timeIntervalSince1970;
        NSString *blocked = info.blocked ? @" BLOCKED" : @"";
        NSString *arg = info.lastArguments.length ? info.lastArguments : @"-";
        NSString *ret = info.lastReturnValue.length ? info.lastReturnValue : @"-";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"count:%ld dur:%.2f/Σ%.2fms last:%.3f%@ arg:%@ ret:%@",
                                     (long)info.count, info.lastDurationMs, info.totalDurationMs, unix, blocked, arg, ret];
    } else {
        cell.detailTextLabel.text = @"count:0";
    }

    cell.accessoryType = [method isEqualToString:self.selectedMethod] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *method = self.filteredMethods[indexPath.row];
    BOOL pinned = [self.pinnedMethods containsObject:method];
    UIContextualAction *pin =
    [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                            title:(pinned ? @"Unpin" : @"Pin")
                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        if (pinned) [self.pinnedMethods removeObject:method];
        else [self.pinnedMethods addObject:method];
        [[NSUserDefaults standardUserDefaults] setObject:self.pinnedMethods.allObjects forKey:[self pinKey]];
        [[ExecutionTracker shared] logSessionEvent:@"favorite" message:[NSString stringWithFormat:@"%@ method %@", pinned ? @"unpin" : @"pin", method ?: @""]];
        [self applyCurrentSortAndReloadData:YES];
        completionHandler(YES);
    }];
    pin.backgroundColor = pinned ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[pin]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    self.selectedMethod = self.filteredMethods[indexPath.row];
    [tableView reloadData];
}

@end
