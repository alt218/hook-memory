#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import "ExecutionTracker.h"
#import "ThemeManager.h"

typedef NS_ENUM(NSInteger, MemorySearchType) {
    MemorySearchTypeAuto = 0,
    MemorySearchTypeFloat,
    MemorySearchTypeDouble,
    MemorySearchTypeUInt8,
    MemorySearchTypeUInt16,
    MemorySearchTypeUInt32,
    MemorySearchTypeUInt64,
    MemorySearchTypeInt8,
    MemorySearchTypeInt16,
    MemorySearchTypeInt32,
    MemorySearchTypeInt64,
    MemorySearchTypeText
};

typedef NS_ENUM(NSInteger, MemoryBaseMode) {
    MemoryBaseModeMain = 0,
    MemoryBaseModeMinAddress,
    MemoryBaseModeModule
};

static NSString *const kPrefCompactMode = @"monitor_compact_mode";
static NSString *const kPrefWriteConfirm = @"monitor_confirm_write";
static NSString *const kPrefRefreshInterval = @"monitor_refresh_interval";

static NSUserDefaults *SearchUD(void) {
    return [NSUserDefaults standardUserDefaults];
}

static BOOL SearchCompactMode(void) {
    return [SearchUD() boolForKey:kPrefCompactMode];
}

static BOOL SearchConfirmWrite(void) {
    if ([SearchUD() objectForKey:kPrefWriteConfirm] == nil) return YES;
    return [SearchUD() boolForKey:kPrefWriteConfirm];
}

static double SearchRefreshInterval(void) {
    double v = [SearchUD() doubleForKey:kPrefRefreshInterval];
    if (v <= 0) v = 1.0;
    return MAX(0.15, v);
}

static NSMutableDictionary *MemorySearchStateCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSString *TypeName(MemorySearchType type) {
    switch (type) {
        case MemorySearchTypeAuto: return @"auto";
        case MemorySearchTypeFloat: return @"float";
        case MemorySearchTypeDouble: return @"double";
        case MemorySearchTypeUInt8: return @"uint8";
        case MemorySearchTypeUInt16: return @"uint16";
        case MemorySearchTypeUInt32: return @"uint32";
        case MemorySearchTypeUInt64: return @"uint64";
        case MemorySearchTypeInt8: return @"int8";
        case MemorySearchTypeInt16: return @"int16";
        case MemorySearchTypeInt32: return @"int32";
        case MemorySearchTypeInt64: return @"int64";
        case MemorySearchTypeText: return @"text";
    }
}

static size_t TypeSize(MemorySearchType type) {
    switch (type) {
        case MemorySearchTypeFloat: return sizeof(float);
        case MemorySearchTypeDouble: return sizeof(double);
        case MemorySearchTypeUInt8: return sizeof(uint8_t);
        case MemorySearchTypeUInt16: return sizeof(uint16_t);
        case MemorySearchTypeUInt32: return sizeof(uint32_t);
        case MemorySearchTypeUInt64: return sizeof(uint64_t);
        case MemorySearchTypeInt8: return sizeof(int8_t);
        case MemorySearchTypeInt16: return sizeof(int16_t);
        case MemorySearchTypeInt32: return sizeof(int32_t);
        case MemorySearchTypeInt64: return sizeof(int64_t);
        default: return 0;
    }
}

static BOOL ReadBytesAt(vm_address_t address, void *buffer, size_t size) {
    if (size == 0) return NO;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         address,
                                         (vm_size_t)size,
                                         (vm_address_t)buffer,
                                         &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

static BOOL WriteBytesAt(vm_address_t address, const void *buffer, size_t size) {
    if (size == 0) return NO;
    kern_return_t kr = vm_write(mach_task_self(),
                                address,
                                (vm_offset_t)buffer,
                                (mach_msg_type_number_t)size);
    return (kr == KERN_SUCCESS);
}

typedef NSString* _Nonnull (^MemoryValueProvider)(vm_address_t address);
typedef BOOL (^MemoryLockProvider)(vm_address_t address);
typedef void (^MemoryEditHandler)(vm_address_t address);
typedef void (^MemoryToggleLockHandler)(vm_address_t address);

@interface NearbyAddressController : UITableViewController
@property(nonatomic) vm_address_t baseAddress;
@property(nonatomic) size_t stride;
@property(nonatomic,copy) MemoryValueProvider valueProvider;
@property(nonatomic,copy) MemoryLockProvider lockProvider;
@property(nonatomic,copy) MemoryEditHandler editHandler;
@property(nonatomic,copy) MemoryToggleLockHandler toggleLockHandler;
@end

@implementation NearbyAddressController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"周辺アドレス";
    self.view.backgroundColor = ThemeBackgroundColor();
    self.tableView.backgroundColor = ThemeBackgroundColor();
    self.tableView.rowHeight = 58.0;
    self.tableView.tableFooterView = [UIView new];
    if (self.stride == 0) self.stride = 1;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSInteger center = [self centerRow];
    if (center > 0) {
        NSIndexPath *centerPath = [NSIndexPath indexPathForRow:center inSection:0];
        [self.tableView scrollToRowAtIndexPath:centerPath
                              atScrollPosition:UITableViewScrollPositionMiddle
                                      animated:NO];
    }
}

- (NSInteger)centerRow {
    return 1000;
}

- (NSInteger)totalRows {
    return 2001;
}

- (vm_address_t)addressForRow:(NSInteger)row {
    long long deltaRows = (long long)row - (long long)[self centerRow];
    long long deltaBytes = deltaRows * (long long)self.stride;
    long long raw = (long long)self.baseAddress + deltaBytes;
    if (raw < 0) raw = 0;
    return (vm_address_t)raw;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [self totalRows];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NearbyCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"NearbyCell"];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    }

    vm_address_t addr = [self addressForRow:indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"0x%llx", (unsigned long long)addr];
    cell.detailTextLabel.text = self.valueProvider ? self.valueProvider(addr) : @"";
    cell.accessoryType = (self.lockProvider && self.lockProvider(addr)) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

    BOOL isBase = (addr == self.baseAddress);
    cell.backgroundColor = isBase ? [ThemeBorderColor() colorWithAlphaComponent:0.15] : ThemeBackgroundColor();
    cell.textLabel.textColor = isBase ? UIColor.systemYellowColor : ThemePrimaryTextColor();
    cell.detailTextLabel.textColor = isBase ? UIColor.systemOrangeColor : ThemeSecondaryTextColor();
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    vm_address_t addr = [self addressForRow:indexPath.row];
    if (self.editHandler) self.editHandler(addr);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    vm_address_t addr = [self addressForRow:indexPath.row];
    BOOL locked = self.lockProvider ? self.lockProvider(addr) : NO;
    UIContextualAction *lockAction =
    [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                            title:(locked ? @"Unlock" : @"Lock")
                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        if (self.toggleLockHandler) self.toggleLockHandler(addr);
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];
    lockAction.backgroundColor = locked ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[lockAction]];
}

@end

@interface MemorySearchController : UITableViewController
@property(nonatomic) MemorySearchType selectedType;
@property(nonatomic) MemorySearchType resolvedType;
@property(nonatomic,strong) UIView *headerPanel;
@property(nonatomic,strong) UIScrollView *typeScrollView;
@property(nonatomic,strong) UITextField *queryField;
@property(nonatomic,strong) UITextField *startField;
@property(nonatomic,strong) UITextField *endField;
@property(nonatomic,strong) UIButton *continueButton;
@property(nonatomic,strong) UIButton *resetButton;
@property(nonatomic,strong) UIButton *historyButton;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *results;
@property(nonatomic,strong) NSData *queryData;
@property(nonatomic,strong) NSString *queryText;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *, NSData *> *lockedValues;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *, NSNumber *> *lockedTypes;
@property(nonatomic,strong) NSTimer *lockTimer;
@property(nonatomic) BOOL searching;
@property(nonatomic) BOOL searchHitLimit;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *searchHistory;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *favoriteAddresses;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *, NSData *> *baselineValues;
@property(nonatomic) BOOL showChangedOnly;
@property(nonatomic,strong) UIBarButtonItem *diffButton;
@property(nonatomic,strong) UIBarButtonItem *densityButton;
@property(nonatomic,strong) UIBarButtonItem *baseModeButton;
@property(nonatomic) MemoryBaseMode baseMode;
@property(nonatomic,copy) NSString *selectedBaseModulePath;
@end

@implementation MemorySearchController

- (void)viewDidLoad {
    [super viewDidLoad];
    ThemeApplyGlobalAppearance();
    self.title = @"メモリ追跡";
    self.view.backgroundColor = ThemeBackgroundColor();
    self.tableView.backgroundColor = ThemeBackgroundColor();
    self.tableView.rowHeight = SearchCompactMode() ? 46.0 : 62.0;
    self.tableView.tableFooterView = [UIView new];

    self.selectedType = MemorySearchTypeAuto;
    self.resolvedType = MemorySearchTypeAuto;
    self.results = [NSMutableArray array];
    self.lockedValues = [NSMutableDictionary dictionary];
    self.lockedTypes = [NSMutableDictionary dictionary];
    self.searchHistory = [NSMutableArray array];
    self.favoriteAddresses = [NSMutableSet setWithArray:[SearchUD() arrayForKey:@"memory_favorites"] ?: @[]];
    self.baselineValues = [NSMutableDictionary dictionary];
    self.baseMode = MemoryBaseModeMain;
    self.selectedBaseModulePath = @"";

    self.diffButton = [[UIBarButtonItem alloc] initWithTitle:@"差分"
                                                        style:UIBarButtonItemStylePlain
                                                       target:self
                                                       action:@selector(toggleDiffOnly)];
    self.densityButton = [[UIBarButtonItem alloc] initWithTitle:@"表示"
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(toggleDensity)];
    self.baseModeButton = [[UIBarButtonItem alloc] initWithTitle:@"Base:Main"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(baseModeTapped)];
    self.navigationItem.rightBarButtonItems = @[self.baseModeButton, self.diffButton, self.densityButton];

    [self setupHeader];
    self.startField.text = @"0x0";
    self.endField.text = @"0x200000000";
    [self restoreStateIfNeeded];
    [self updateBaseModeTitle];

    UILongPressGestureRecognizer *lp =
    [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tableView addGestureRecognizer:lp];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutHeader];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lockTimer = [NSTimer scheduledTimerWithTimeInterval:SearchRefreshInterval()
                                                      target:self
                                                    selector:@selector(applyLocks)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self saveState];
    [self.lockTimer invalidate];
    self.lockTimer = nil;
}

- (void)setupHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 264)];
    header.backgroundColor = ThemeBackgroundColor();
    self.headerPanel = header;

    UILabel *typeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    typeLabel.tag = 1001;
    typeLabel.text = @"Type";
    typeLabel.textColor = ThemeSecondaryTextColor();
    typeLabel.font = [UIFont boldSystemFontOfSize:12];
    [header addSubview:typeLabel];

    self.typeScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.typeScrollView.showsHorizontalScrollIndicator = NO;
    [header addSubview:self.typeScrollView];

    for (NSNumber *n in [self allTypeValues]) {
        MemorySearchType type = (MemorySearchType)n.integerValue;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = 2000 + type;
        btn.layer.cornerRadius = 7;
        btn.layer.borderWidth = 1;
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [btn setTitle:TypeName(type) forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(typeChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.typeScrollView addSubview:btn];
    }

    self.queryField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.queryField.borderStyle = UITextBorderStyleRoundedRect;
    self.queryField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.queryField.textColor = ThemePrimaryTextColor();
    self.queryField.placeholder = @"value";
    self.queryField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [header addSubview:self.queryField];

    self.startField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.startField.borderStyle = UITextBorderStyleRoundedRect;
    self.startField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.startField.textColor = ThemePrimaryTextColor();
    self.startField.placeholder = @"start (hex)";
    self.startField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [header addSubview:self.startField];

    self.endField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.endField.borderStyle = UITextBorderStyleRoundedRect;
    self.endField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.endField.textColor = ThemePrimaryTextColor();
    self.endField.placeholder = @"end (hex)";
    self.endField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [header addSubview:self.endField];

    self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.resetButton.frame = CGRectZero;
    [self.resetButton setTitle:@"新規" forState:UIControlStateNormal];
    self.resetButton.layer.cornerRadius = 8;
    self.resetButton.layer.borderWidth = 1;
    self.resetButton.layer.borderColor = ThemeBorderColor().CGColor;
    [self.resetButton addTarget:self action:@selector(newSearchTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.resetButton];

    self.continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.continueButton.frame = CGRectZero;
    [self.continueButton setTitle:@"続けて" forState:UIControlStateNormal];
    self.continueButton.layer.cornerRadius = 8;
    self.continueButton.layer.borderWidth = 1;
    self.continueButton.layer.borderColor = ThemeBorderColor().CGColor;
    [self.continueButton addTarget:self action:@selector(continueSearchTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.continueButton];

    self.historyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.historyButton.frame = CGRectZero;
    [self.historyButton setTitle:@"サーチ履歴" forState:UIControlStateNormal];
    self.historyButton.layer.cornerRadius = 8;
    self.historyButton.layer.borderWidth = 1;
    self.historyButton.layer.borderColor = ThemeBorderColor().CGColor;
    [self.historyButton addTarget:self action:@selector(showSearchHistoryTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.historyButton];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textColor = ThemeSecondaryTextColor();
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.text = @"ready";
    [header addSubview:self.statusLabel];

    self.tableView.tableHeaderView = header;
    [self updateTypeChipStyles];
    [self layoutHeader];
}

- (NSArray<NSNumber *> *)allTypeValues {
    return @[
        @(MemorySearchTypeAuto), @(MemorySearchTypeFloat), @(MemorySearchTypeDouble),
        @(MemorySearchTypeUInt8), @(MemorySearchTypeUInt16), @(MemorySearchTypeUInt32), @(MemorySearchTypeUInt64),
        @(MemorySearchTypeInt8), @(MemorySearchTypeInt16), @(MemorySearchTypeInt32), @(MemorySearchTypeInt64),
        @(MemorySearchTypeText)
    ];
}

- (void)selectTypeTapped {
}

- (void)typeChipTapped:(UIButton *)sender {
    MemorySearchType type = (MemorySearchType)(sender.tag - 2000);
    self.selectedType = type;
    [self updateTypeChipStyles];
}

- (void)updateTypeChipStyles {
    for (UIView *v in self.typeScrollView.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        UIButton *btn = (UIButton *)v;
        MemorySearchType t = (MemorySearchType)(btn.tag - 2000);
        BOOL selected = (t == self.selectedType);
        btn.layer.borderColor = selected ? ThemeBorderColor().CGColor : UIColor.grayColor.CGColor;
        btn.backgroundColor = selected ? [ThemeBorderColor() colorWithAlphaComponent:0.2] : UIColor.clearColor;
        [btn setTitleColor:(selected ? ThemePrimaryTextColor() : ThemeSecondaryTextColor()) forState:UIControlStateNormal];
    }
}

- (void)layoutHeader {
    if (!self.headerPanel) return;

    CGFloat width = self.view.bounds.size.width;
    CGRect headerFrame = CGRectMake(0, 0, width, 264);
    if (!CGRectEqualToRect(self.headerPanel.frame, headerFrame)) {
        self.headerPanel.frame = headerFrame;
    }

    UILabel *typeLabel = [self.headerPanel viewWithTag:1001];
    typeLabel.frame = CGRectMake(12, 8, 70, 16);

    self.typeScrollView.frame = CGRectMake(12, 26, width - 24, 36);
    CGFloat x = 0;
    for (UIView *v in self.typeScrollView.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        UIButton *btn = (UIButton *)v;
        CGFloat w = MAX(64, [btn.currentTitle sizeWithAttributes:@{NSFontAttributeName: btn.titleLabel.font}].width + 18);
        btn.frame = CGRectMake(x, 3, w, 30);
        x += w + 8;
    }
    self.typeScrollView.contentSize = CGSizeMake(MAX(x, self.typeScrollView.bounds.size.width + 1), 36);

    self.queryField.frame = CGRectMake(12, 68, width - 24, 34);
    CGFloat rangeW = (width - 36) / 2.0;
    self.startField.frame = CGRectMake(12, 108, rangeW, 34);
    self.endField.frame = CGRectMake(CGRectGetMaxX(self.startField.frame) + 12, 108, rangeW, 34);
    CGFloat btnW = (width - 36) / 2.0;
    self.resetButton.frame = CGRectMake(12, 148, btnW, 34);
    self.continueButton.frame = CGRectMake(CGRectGetMaxX(self.resetButton.frame) + 12, 148, btnW, 34);
    self.historyButton.frame = CGRectMake(12, 188, width - 24, 30);
    self.statusLabel.frame = CGRectMake(12, 220, width - 24, 40);
}

- (void)toggleDiffOnly {
    self.showChangedOnly = !self.showChangedOnly;
    self.diffButton.title = self.showChangedOnly ? @"差分ON" : @"差分";
    [[ExecutionTracker shared] logSessionEvent:@"memory" message:(self.showChangedOnly ? @"diff only on" : @"diff only off")];
    [self.tableView reloadData];
}

- (void)toggleDensity {
    BOOL compact = !SearchCompactMode();
    [SearchUD() setBool:compact forKey:kPrefCompactMode];
    self.tableView.rowHeight = compact ? 46.0 : 62.0;
    self.densityButton.title = compact ? @"詳細" : @"表示";
    [[ExecutionTracker shared] logSessionEvent:@"ui" message:(compact ? @"compact on" : @"compact off")];
    [self.tableView reloadData];
}

- (void)updateBaseModeTitle {
    if (self.baseMode == MemoryBaseModeMain) self.baseModeButton.title = @"Base:Main";
    else if (self.baseMode == MemoryBaseModeMinAddress) self.baseModeButton.title = @"Base:Min";
    else self.baseModeButton.title = @"Base:Module";
}

- (unsigned long long)mainExecutableBaseAddress {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) continue;
        if (h->filetype == MH_EXECUTE) return (unsigned long long)(uintptr_t)h;
    }
    return 0;
}

- (unsigned long long)minLoadedImageBaseAddress {
    uint32_t count = _dyld_image_count();
    unsigned long long minBase = ULLONG_MAX;
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) continue;
        unsigned long long b = (unsigned long long)(uintptr_t)h;
        if (b > 0 && b < minBase) minBase = b;
    }
    return minBase == ULLONG_MAX ? 0 : minBase;
}

- (unsigned long long)moduleBaseAddress {
    if (self.selectedBaseModulePath.length == 0) return 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (![path isEqualToString:self.selectedBaseModulePath]) continue;
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) return 0;
        return (unsigned long long)(uintptr_t)h;
    }
    return 0;
}

- (unsigned long long)resolvedBaseAddress {
    if (self.baseMode == MemoryBaseModeMain) return [self mainExecutableBaseAddress];
    if (self.baseMode == MemoryBaseModeMinAddress) return [self minLoadedImageBaseAddress];
    unsigned long long m = [self moduleBaseAddress];
    return m > 0 ? m : [self mainExecutableBaseAddress];
}

- (void)baseModeTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Base" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Main" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        self.baseMode = MemoryBaseModeMain;
        [self updateBaseModeTitle];
        [self saveState];
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"MinAddress" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        self.baseMode = MemoryBaseModeMinAddress;
        [self updateBaseModeTitle];
        [self saveState];
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Module" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        [self pickBaseModule];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.baseModeButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickBaseModule {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Module" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    uint32_t count = _dyld_image_count();
    NSInteger limit = MIN((NSInteger)count, 25);
    for (NSInteger i = 0; i < limit; i++) {
        const char *name = _dyld_get_image_name((uint32_t)i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        [sheet addAction:[UIAlertAction actionWithTitle:(path.lastPathComponent ?: path)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction * _Nonnull action) {
            self.baseMode = MemoryBaseModeModule;
            self.selectedBaseModulePath = path ?: @"";
            [self updateBaseModeTitle];
            [self saveState];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.baseModeButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)saveState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"selectedType"] = @(self.selectedType);
    state[@"resolvedType"] = @(self.resolvedType);
    state[@"queryText"] = self.queryField.text ?: @"";
    state[@"startText"] = self.startField.text ?: @"0x0";
    state[@"endText"] = self.endField.text ?: @"0x200000000";
    state[@"statusText"] = self.statusLabel.text ?: @"ready";
    if (self.queryData) state[@"queryData"] = self.queryData;
    if (self.results) state[@"results"] = [self.results copy];
    if (self.lockedValues) state[@"lockedValues"] = [self.lockedValues copy];
    if (self.lockedTypes) state[@"lockedTypes"] = [self.lockedTypes copy];
    if (self.searchHistory) state[@"searchHistory"] = [self.searchHistory copy];
    state[@"baseMode"] = @(self.baseMode);
    state[@"selectedBaseModulePath"] = self.selectedBaseModulePath ?: @"";
    MemorySearchStateCache()[@"memory_search"] = state;
}

- (void)restoreStateIfNeeded {
    NSDictionary *state = MemorySearchStateCache()[@"memory_search"];
    if (![state isKindOfClass:[NSDictionary class]]) return;

    self.selectedType = (MemorySearchType)[state[@"selectedType"] integerValue];
    self.resolvedType = (MemorySearchType)[state[@"resolvedType"] integerValue];
    self.queryField.text = state[@"queryText"] ?: @"";
    self.startField.text = state[@"startText"] ?: @"0x0";
    self.endField.text = state[@"endText"] ?: @"0x200000000";
    self.statusLabel.text = state[@"statusText"] ?: @"ready";
    self.queryData = state[@"queryData"];
    self.results = [state[@"results"] mutableCopy] ?: [NSMutableArray array];
    self.lockedValues = [state[@"lockedValues"] mutableCopy] ?: [NSMutableDictionary dictionary];
    self.lockedTypes = [state[@"lockedTypes"] mutableCopy] ?: [NSMutableDictionary dictionary];
    self.searchHistory = [state[@"searchHistory"] mutableCopy] ?: [NSMutableArray array];
    self.baseMode = (MemoryBaseMode)[state[@"baseMode"] integerValue];
    self.selectedBaseModulePath = state[@"selectedBaseModulePath"] ?: @"";
    [self updateBaseModeTitle];
    [self updateTypeChipStyles];
    [self.tableView reloadData];
}

- (BOOL)parseQueryText:(NSString *)text
           desiredType:(MemorySearchType)desiredType
          resolvedType:(MemorySearchType *)resolvedType
                 bytes:(NSData **)bytes
{
    if (text.length == 0) return NO;

    MemorySearchType type = desiredType;
    if (type == MemorySearchTypeAuto) {
        NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
        BOOL hasLetters = [text rangeOfCharacterFromSet:letters].location != NSNotFound;
        if (hasLetters) type = MemorySearchTypeText;
        else if ([text containsString:@"."]) type = MemorySearchTypeDouble;
        else type = MemorySearchTypeInt64;
    }

    NSData *output = nil;
    switch (type) {
        case MemorySearchTypeFloat: {
            float v = text.floatValue; output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeDouble: {
            double v = text.doubleValue; output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeUInt8: {
            uint8_t v = (uint8_t)strtoull(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeUInt16: {
            uint16_t v = (uint16_t)strtoull(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeUInt32: {
            uint32_t v = (uint32_t)strtoull(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeUInt64: {
            uint64_t v = (uint64_t)strtoull(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeInt8: {
            int8_t v = (int8_t)strtoll(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeInt16: {
            int16_t v = (int16_t)strtoll(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeInt32: {
            int32_t v = (int32_t)strtoll(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeInt64: {
            int64_t v = (int64_t)strtoll(text.UTF8String, NULL, 10); output = [NSData dataWithBytes:&v length:sizeof(v)]; break;
        }
        case MemorySearchTypeText: {
            output = [text dataUsingEncoding:NSUTF8StringEncoding]; break;
        }
        default:
            return NO;
    }

    if (resolvedType) *resolvedType = type;
    if (bytes) *bytes = output;
    return output.length > 0;
}

- (void)newSearchTapped {
    [self.results removeAllObjects];
    [self.lockedValues removeAllObjects];
    [self.lockedTypes removeAllObjects];
    [self runSearchReset:YES];
}

- (void)continueSearchTapped {
    [self runSearchReset:NO];
}

- (void)runSearchReset:(BOOL)reset {
    if (self.searching) return;

    NSString *text = self.queryField.text ?: @"";
    unsigned long long start = 0;
    unsigned long long end = 0;
    if (![self parseRangeStart:&start end:&end]) {
        self.statusLabel.text = @"invalid range";
        return;
    }

    MemorySearchType resolved = MemorySearchTypeAuto;
    NSData *query = nil;
    if (![self parseQueryText:text desiredType:self.selectedType resolvedType:&resolved bytes:&query]) {
        self.statusLabel.text = @"invalid query";
        return;
    }

    self.searching = YES;
    self.searchHitLimit = NO;
    self.resetButton.enabled = NO;
    self.continueButton.enabled = NO;
    self.statusLabel.text = reset ? @"searching (new)..." : @"searching (continue)...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<NSNumber *> *matches = [NSMutableArray array];

        if (reset || self.results.count == 0) {
            [self scanAllMemoryForQuery:query
                                   type:resolved
                                 start:(vm_address_t)start
                                   end:(vm_address_t)end
                                matches:matches];
        } else {
            [self filterCurrentResultsForQuery:query type:resolved matches:matches];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.searching = NO;
            self.resetButton.enabled = YES;
            self.continueButton.enabled = YES;
            self.resolvedType = resolved;
            self.queryData = query;
            self.queryText = text;
            self.results = matches;
            [self captureBaselineValues];
            NSString *tail = self.searchHitLimit ? @" (limit)" : @"";
            self.statusLabel.text = [NSString stringWithFormat:@"type:%@ hits:%lu%@", TypeName(resolved), (unsigned long)matches.count, tail];
            [[ExecutionTracker shared] logSessionEvent:@"search"
                                               message:[NSString stringWithFormat:@"%@ type:%@ hits:%lu",
                                                        reset ? @"new" : @"continue",
                                                        TypeName(resolved),
                                                        (unsigned long)matches.count]];
            [self appendSearchHistoryWithReset:reset
                                          type:resolved
                                         query:text
                                         start:start
                                           end:end
                                          hits:matches];
            [self.tableView reloadData];
        });
    });
}

- (void)scanAllMemoryForQuery:(NSData *)query
                         type:(MemorySearchType)type
                        start:(vm_address_t)start
                          end:(vm_address_t)end
                      matches:(NSMutableArray<NSNumber *> *)matches
{
    const NSUInteger maxHits = 20000;
    vm_address_t address = MAX((vm_address_t)VM_MIN_ADDRESS, start);
    vm_address_t hardEnd = end > address ? end : (vm_address_t)VM_MAX_ADDRESS;
    vm_address_t prevAddress = 0;
    NSUInteger regionIndex = 0;

    while (address < hardEnd) {
        vm_size_t size = 0;
        uint32_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(),
                                                &address,
                                                &size,
                                                &depth,
                                                (vm_region_recurse_info_t)&info,
                                                &count);
        if (kr != KERN_SUCCESS) break;

        if (info.is_submap) {
            depth++;
            if (size == 0) address += 0x1000;
            continue;
        }

        BOOL writable = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE);
        if (writable && size > 0) {
            vm_size_t capped = size;
            if (address + capped > hardEnd) {
                capped = (vm_size_t)(hardEnd - address);
            }
            [self scanRegionFrom:address size:capped query:query type:type matches:matches];
            if (matches.count >= maxHits) {
                self.searchHitLimit = YES;
                break;
            }
        }

        if (size == 0) {
            address += 0x1000;
        } else {
            address += size;
        }

        if (address <= prevAddress) {
            address = prevAddress + 0x1000;
        }
        prevAddress = address;

        regionIndex += 1;
        if (regionIndex % 200 == 0) {
            NSUInteger currentHits = matches.count;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = [NSString stringWithFormat:@"searching... region:%lu hits:%lu",
                                         (unsigned long)regionIndex,
                                         (unsigned long)currentHits];
            });
        }
    }
}

- (BOOL)parseRangeStart:(unsigned long long *)start end:(unsigned long long *)end {
    NSString *sText = self.startField.text.length ? self.startField.text : @"0x0";
    NSString *eText = self.endField.text.length ? self.endField.text : @"0x200000000";

    unsigned long long s = strtoull(sText.UTF8String, NULL, 0);
    unsigned long long e = strtoull(eText.UTF8String, NULL, 0);
    if (e == 0) e = 0x200000000ULL;
    if (e <= s) return NO;

    if (start) *start = s;
    if (end) *end = e;
    return YES;
}

- (void)appendSearchHistoryWithReset:(BOOL)reset
                                type:(MemorySearchType)type
                               query:(NSString *)query
                               start:(unsigned long long)start
                                 end:(unsigned long long)end
                                hits:(NSArray<NSNumber *> *)hits
{
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"mode"] = reset ? @"新規" : @"続けて";
    entry[@"type"] = TypeName(type) ?: @"";
    entry[@"query"] = query ?: @"";
    entry[@"start"] = [NSString stringWithFormat:@"0x%llx", start];
    entry[@"end"] = [NSString stringWithFormat:@"0x%llx", end];
    entry[@"time"] = [NSDate date];
    NSUInteger keep = MIN((NSUInteger)300, hits.count);
    entry[@"hits"] = [hits subarrayWithRange:NSMakeRange(0, keep)];

    [self.searchHistory addObject:entry];
    if (self.searchHistory.count > 30) {
        [self.searchHistory removeObjectAtIndex:0];
    }
}

- (void)showSearchHistoryTapped {
    if (self.searchHistory.count == 0) {
        UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"サーチ履歴"
                                            message:@"履歴がありません"
                                     preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:@"サーチ履歴"
                                        message:@"表示する履歴を選択"
                                 preferredStyle:UIAlertControllerStyleActionSheet];

    NSInteger startIndex = MAX(0, (NSInteger)self.searchHistory.count - 10);
    for (NSInteger i = self.searchHistory.count - 1; i >= startIndex; i--) {
        NSDictionary *entry = self.searchHistory[i];
        NSString *title = [NSString stringWithFormat:@"#%ld %@ %@ (%lu)",
                           (long)(i + 1),
                           entry[@"mode"] ?: @"",
                           entry[@"type"] ?: @"",
                           (unsigned long)[entry[@"hits"] count]];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [self showHistoryDetail:entry index:(i + 1)];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.historyButton;
    sheet.popoverPresentationController.sourceRect = self.historyButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showHistoryDetail:(NSDictionary *)entry index:(NSInteger)index {
    NSString *detail = [self formattedHistoryDetail:entry index:index];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:@"サーチ履歴詳細"
                                        message:detail
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"コピー"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = detail ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)formattedHistoryDetail:(NSDictionary *)entry index:(NSInteger)index {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"#%ld\n", (long)index];
    [s appendFormat:@"mode: %@\n", entry[@"mode"] ?: @""];
    [s appendFormat:@"type: %@\n", entry[@"type"] ?: @""];
    [s appendFormat:@"query: %@\n", entry[@"query"] ?: @""];
    [s appendFormat:@"range: %@ ~ %@\n", entry[@"start"] ?: @"", entry[@"end"] ?: @""];

    NSArray<NSNumber *> *hits = entry[@"hits"];
    if (hits.count == 0) {
        [s appendString:@"hits: 0"];
        return s;
    }

    unsigned long long base = hits.firstObject.unsignedLongLongValue;
    [s appendFormat:@"hits: %lu\n", (unsigned long)hits.count];
    [s appendFormat:@"[1] 0x%llx (base)\n", base];
    for (NSUInteger i = 1; i < hits.count; i++) {
        unsigned long long addr = hits[i].unsignedLongLongValue;
        long long delta = (long long)addr - (long long)base;
        NSString *deltaHex = [NSString stringWithFormat:@"%@0x%llx", (delta >= 0 ? @"+" : @"-"), (unsigned long long)llabs(delta)];
        [s appendFormat:@"[%lu] 0x%llx (delta:%@)\n", (unsigned long)(i + 1), addr, deltaHex];
        if (i >= 80) {
            [s appendString:@"...truncated...\n"];
            break;
        }
    }
    return s;
}

- (void)scanRegionFrom:(vm_address_t)base
                  size:(vm_size_t)size
                 query:(NSData *)query
                  type:(MemorySearchType)type
               matches:(NSMutableArray<NSNumber *> *)matches
{
    const size_t chunkSize = 0x8000;
    uint8_t *buffer = (uint8_t *)malloc(chunkSize + query.length);
    if (!buffer) return;

    size_t step = (type == MemorySearchTypeText) ? 1 : MAX((size_t)1, TypeSize(type));
    vm_address_t cursor = base;
    vm_address_t end = base + size;

    while (cursor < end) {
        vm_size_t toRead = (vm_size_t)MIN((vm_size_t)chunkSize, end - cursor);
        vm_size_t outSize = 0;
        kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                             cursor,
                                             toRead,
                                             (vm_address_t)buffer,
                                             &outSize);
        if (kr != KERN_SUCCESS || outSize == 0) {
            cursor += toRead;
            continue;
        }

        if (outSize >= query.length) {
            for (size_t i = 0; i + query.length <= outSize; i += step) {
                if (memcmp(buffer + i, query.bytes, query.length) == 0) {
                    [matches addObject:@(cursor + i)];
                }
            }
        }
        cursor += outSize;
    }

    free(buffer);
}

- (void)filterCurrentResultsForQuery:(NSData *)query
                                type:(MemorySearchType)type
                             matches:(NSMutableArray<NSNumber *> *)matches
{
    size_t bytes = (type == MemorySearchTypeText) ? query.length : MAX((size_t)1, TypeSize(type));
    uint8_t *buf = (uint8_t *)malloc(bytes);
    if (!buf) return;

    for (NSNumber *n in self.results) {
        vm_address_t addr = (vm_address_t)n.unsignedLongLongValue;
        if (ReadBytesAt(addr, buf, bytes) && memcmp(buf, query.bytes, bytes) == 0) {
            [matches addObject:n];
        }
    }
    free(buf);
}

- (NSString *)stringValueAtAddress:(vm_address_t)addr type:(MemorySearchType)type {
    switch (type) {
        case MemorySearchTypeFloat: {
            float v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%f", v];
        }
        case MemorySearchTypeDouble: {
            double v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%lf", v];
        }
        case MemorySearchTypeUInt8: {
            uint8_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%u", v];
        }
        case MemorySearchTypeUInt16: {
            uint16_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%u", v];
        }
        case MemorySearchTypeUInt32: {
            uint32_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%u", v];
        }
        case MemorySearchTypeUInt64: {
            uint64_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%llu", v];
        }
        case MemorySearchTypeInt8: {
            int8_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%d", v];
        }
        case MemorySearchTypeInt16: {
            int16_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%d", v];
        }
        case MemorySearchTypeInt32: {
            int32_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%d", v];
        }
        case MemorySearchTypeInt64: {
            int64_t v = 0; if (!ReadBytesAt(addr, &v, sizeof(v))) return @"<unreadable>"; return [NSString stringWithFormat:@"%lld", v];
        }
        case MemorySearchTypeText: {
            if (self.queryData.length == 0) return @"";
            uint8_t *buf = (uint8_t *)malloc(self.queryData.length + 1);
            if (!buf) return @"<oom>";
            memset(buf, 0, self.queryData.length + 1);
            NSString *text = @"<unreadable>";
            if (ReadBytesAt(addr, buf, self.queryData.length)) {
                text = [[NSString alloc] initWithBytes:buf length:self.queryData.length encoding:NSUTF8StringEncoding] ?: @"<binary>";
            }
            free(buf);
            return text;
        }
        default:
            return @"";
    }
}

- (void)captureBaselineValues {
    [self.baselineValues removeAllObjects];
    size_t bytes = (self.resolvedType == MemorySearchTypeText) ? self.queryData.length : MAX((size_t)1, TypeSize(self.resolvedType));
    if (bytes == 0) return;

    for (NSNumber *n in self.results) {
        vm_address_t addr = (vm_address_t)n.unsignedLongLongValue;
        NSMutableData *data = [NSMutableData dataWithLength:bytes];
        if (ReadBytesAt(addr, data.mutableBytes, bytes)) {
            self.baselineValues[n] = data;
        }
    }
}

- (BOOL)isAddressChanged:(NSNumber *)addressNumber {
    if (!self.showChangedOnly) return YES;
    NSData *base = self.baselineValues[addressNumber];
    if (!base) return NO;
    NSMutableData *cur = [NSMutableData dataWithLength:base.length];
    if (!ReadBytesAt((vm_address_t)addressNumber.unsignedLongLongValue, cur.mutableBytes, cur.length)) return NO;
    return ![cur isEqualToData:base];
}

- (NSArray<NSNumber *> *)visibleResults {
    if (!self.showChangedOnly) return self.results;
    NSMutableArray<NSNumber *> *rows = [NSMutableArray array];
    for (NSNumber *n in self.results) {
        if ([self isAddressChanged:n]) [rows addObject:n];
    }
    return rows;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [self visibleResults].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ScanCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ScanCell"];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    }
    cell.backgroundColor = ThemeBackgroundColor();
    cell.textLabel.textColor = ThemePrimaryTextColor();
    cell.detailTextLabel.textColor = ThemeSecondaryTextColor();

    NSArray<NSNumber *> *rows = [self visibleResults];
    vm_address_t addr = (vm_address_t)rows[indexPath.row].unsignedLongLongValue;
    NSString *value = [self stringValueAtAddress:addr type:self.resolvedType];
    cell.textLabel.text = [NSString stringWithFormat:@"0x%llx", (unsigned long long)addr];
    BOOL fav = [self.favoriteAddresses containsObject:@(addr)];
    unsigned long long base = [self resolvedBaseAddress];
    long long delta = (long long)addr - (long long)base;
    NSString *deltaHex = [NSString stringWithFormat:@"%@0x%llx", (delta >= 0 ? @"+" : @"-"), (unsigned long long)llabs(delta)];
    NSString *suffix = self.showChangedOnly ? [NSString stringWithFormat:@"  Δ%@:%@", self.baseModeButton.title ?: @"Base", deltaHex] : @"";
    if (SearchCompactMode()) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%@", fav ? @"★ " : @"", value ?: @"", suffix];
    } else {
        NSString *body = fav ? [NSString stringWithFormat:@"★ %@", value ?: @""] : (value ?: @"");
        cell.detailTextLabel.text = [body stringByAppendingString:suffix];
    }
    cell.accessoryType = self.lockedValues[@(addr)] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSNumber *> *rows = [self visibleResults];
    vm_address_t addr = (vm_address_t)rows[indexPath.row].unsignedLongLongValue;
    [self showEditForAddress:addr];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSNumber *> *rows = [self visibleResults];
    vm_address_t addr = (vm_address_t)rows[indexPath.row].unsignedLongLongValue;
    BOOL locked = (self.lockedValues[@(addr)] != nil);
    BOOL fav = [self.favoriteAddresses containsObject:@(addr)];
    UIContextualAction *lockAction =
    [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                            title:(locked ? @"Unlock" : @"Lock")
                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self toggleLockAtAddress:addr];
        completionHandler(YES);
    }];
    lockAction.backgroundColor = locked ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    UIContextualAction *favAction =
    [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                            title:(fav ? @"Unpin" : @"Pin")
                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        NSNumber *k = @(addr);
        if (fav) [self.favoriteAddresses removeObject:k];
        else [self.favoriteAddresses addObject:k];
        [SearchUD() setObject:self.favoriteAddresses.allObjects forKey:@"memory_favorites"];
        [[ExecutionTracker shared] logSessionEvent:@"favorite" message:[NSString stringWithFormat:@"%@ addr:0x%llx", fav ? @"unpin" : @"pin", (unsigned long long)addr]];
        [self.tableView reloadData];
        completionHandler(YES);
    }];
    favAction.backgroundColor = UIColor.systemPurpleColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[lockAction, favAction]];
}

- (void)showEditForAddress:(vm_address_t)addr {
    NSString *current = [self stringValueAtAddress:addr type:self.resolvedType];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"0x%llx", (unsigned long long)addr]
                                        message:@"値を書き換え"
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = current; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self confirmAndWriteValue:alert.textFields.firstObject.text toAddress:addr lock:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save+Lock" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self confirmAndWriteValue:alert.textFields.firstObject.text toAddress:addr lock:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmAndWriteValue:(NSString *)text toAddress:(vm_address_t)addr lock:(BOOL)lock {
    if (!SearchConfirmWrite()) {
        [self writeValue:text toAddress:addr lock:lock];
        return;
    }
    NSString *msg = [NSString stringWithFormat:@"addr:0x%llx\nnew:%@", (unsigned long long)addr, text ?: @""];
    UIAlertController *confirm =
    [UIAlertController alertControllerWithTitle:@"書き込み確認"
                                        message:msg
                                 preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"実行" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self writeValue:text toAddress:addr lock:lock];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)writeValue:(NSString *)text toAddress:(vm_address_t)addr lock:(BOOL)lock {
    MemorySearchType resolved = self.resolvedType;
    NSData *bytes = nil;
    if (![self parseQueryText:text desiredType:resolved resolvedType:&resolved bytes:&bytes]) return;
    if (!WriteBytesAt(addr, bytes.bytes, bytes.length)) return;

    if (lock) {
        self.lockedValues[@(addr)] = bytes;
        self.lockedTypes[@(addr)] = @(resolved);
    }
    [[ExecutionTracker shared] logSessionEvent:@"write" message:[NSString stringWithFormat:@"addr:0x%llx lock:%d", (unsigned long long)addr, lock ? 1 : 0]];
    [self.tableView reloadData];
}

- (void)toggleLockAtAddress:(vm_address_t)addr {
    NSNumber *key = @(addr);
    if (self.lockedValues[key]) {
        [self.lockedValues removeObjectForKey:key];
        [self.lockedTypes removeObjectForKey:key];
        [self.tableView reloadData];
        return;
    }

    size_t bytes = (self.resolvedType == MemorySearchTypeText) ? self.queryData.length : TypeSize(self.resolvedType);
    if (bytes == 0) return;
    NSMutableData *data = [NSMutableData dataWithLength:bytes];
    if (!ReadBytesAt(addr, data.mutableBytes, bytes)) return;
    self.lockedValues[key] = data;
    self.lockedTypes[key] = @(self.resolvedType);
    [self.tableView reloadData];
}

- (void)applyLocks {
    for (NSNumber *key in self.lockedValues.allKeys) {
        vm_address_t addr = (vm_address_t)key.unsignedLongLongValue;
        NSData *data = self.lockedValues[key];
        if (data.length > 0) WriteBytesAt(addr, data.bytes, data.length);
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:p];
    if (!indexPath) return;
    NSArray<NSNumber *> *rows = [self visibleResults];
    if (indexPath.row >= (NSInteger)rows.count) return;
    vm_address_t addr = (vm_address_t)rows[indexPath.row].unsignedLongLongValue;
    [self showNearbyAddressesFor:addr];
}

- (void)showNearbyAddressesFor:(vm_address_t)address {
    size_t unit = (self.resolvedType == MemorySearchTypeText) ? MAX((size_t)1, self.queryData.length) : MAX((size_t)1, TypeSize(self.resolvedType));

    NearbyAddressController *vc = [NearbyAddressController new];
    vc.baseAddress = address;
    vc.stride = unit;
    __weak typeof(self) weakSelf = self;
    vc.valueProvider = ^NSString * _Nonnull(vm_address_t a) {
        return [weakSelf stringValueAtAddress:a type:weakSelf.resolvedType];
    };
    vc.lockProvider = ^BOOL(vm_address_t a) {
        return weakSelf.lockedValues[@(a)] != nil;
    };
    vc.editHandler = ^(vm_address_t a) {
        [weakSelf showEditForAddress:a];
    };
    vc.toggleLockHandler = ^(vm_address_t a) {
        [weakSelf toggleLockAtAddress:a];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

@end
