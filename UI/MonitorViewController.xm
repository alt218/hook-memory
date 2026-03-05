#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import "ClassManager.h"
#import "ClassListController.h"
#import "ExecutionTracker.h"

static NSString *const kPrefRefreshInterval = @"monitor_refresh_interval";
static NSString *const kPrefBatterySaver = @"monitor_battery_saver";
static NSString *const kPrefCompactMode = @"monitor_compact_mode";
static NSString *const kPrefWriteConfirm = @"monitor_confirm_write";
static NSString *const kPrefBackgroundBinary = @"monitor_bg_binary";
static NSString *const kProfileSlotsKey = @"monitor_profile_slots_v1";

static NSUserDefaults *MonitorUD(void) {
    return [NSUserDefaults standardUserDefaults];
}

static double MonitorRefreshInterval(void) {
    double v = [MonitorUD() doubleForKey:kPrefRefreshInterval];
    if (v <= 0) v = 1.0;
    return [MonitorUD() boolForKey:kPrefBatterySaver] ? MAX(2.0, v) : v;
}

static BOOL MonitorCompactMode(void) {
    return [MonitorUD() boolForKey:kPrefCompactMode];
}

static BOOL MonitorBackgroundBinary(void) {
    return [MonitorUD() boolForKey:kPrefBackgroundBinary];
}

static NSString *NowDateTimeString(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *HexMemoryHash(const void *bytes, size_t length) {
    if (!bytes || length == 0) return nil;
    const uint8_t *p = (const uint8_t *)bytes;
    uint64_t hash = 1469598103934665603ULL; // FNV-1a 64-bit
    for (size_t i = 0; i < length; i++) {
        hash ^= p[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
}

static NSString *TextSegmentHashForImageIndex(uint32_t imageIndex) {
    const struct mach_header *header = _dyld_get_image_header(imageIndex);
    if (!header) return nil;

    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
    BOOL is64 = (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64);

    const uint8_t *cursor = (const uint8_t *)header + (is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
    uint32_t ncmds = header->ncmds;

    for (uint32_t i = 0; i < ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (is64 && lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                const void *textPtr = (const void *)(uintptr_t)(seg->vmaddr + slide);
                size_t textSize = (size_t)seg->vmsize;
                return HexMemoryHash(textPtr, textSize);
            }
        } else if (!is64 && lc->cmd == LC_SEGMENT) {
            const struct segment_command *seg = (const struct segment_command *)cursor;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                const void *textPtr = (const void *)(uintptr_t)(seg->vmaddr + slide);
                size_t textSize = (size_t)seg->vmsize;
                return HexMemoryHash(textPtr, textSize);
            }
        }
        cursor += lc->cmdsize;
    }
    return nil;
}

static NSString *NowTimeString(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return [formatter stringFromDate:[NSDate date]];
}

@interface HookDylibListController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSString *> *allDylibPaths;
@property(nonatomic,strong) NSArray<NSString *> *filteredDylibPaths;
@property(nonatomic,strong) UISearchController *searchController;
@end

@implementation HookDylibListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"HOOK";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search dylib...";
    self.navigationItem.searchController = self.searchController;

    [self reloadDylibs];
}

- (void)reloadDylibs {
    NSArray<NSString *> *loaded = GetLoadedDylibs();
    NSMutableArray<NSString *> *dylibs = [NSMutableArray array];
    for (NSString *path in loaded) {
        if ([path.lastPathComponent hasSuffix:@".dylib"]) {
            [dylibs addObject:path];
        }
    }
    self.allDylibPaths = dylibs;
    self.filteredDylibPaths = dylibs;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text.lowercaseString ?: @"";
    if (text.length == 0) {
        self.filteredDylibPaths = self.allDylibPaths;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSString *path, NSDictionary *_) {
            return [path.lastPathComponent.lowercaseString containsString:text];
        }];
        self.filteredDylibPaths = [self.allDylibPaths filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredDylibPaths.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HookCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HookCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSString *path = self.filteredDylibPaths[indexPath.row];
    cell.textLabel.text = path.lastPathComponent;
    cell.detailTextLabel.text = path;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = self.filteredDylibPaths[indexPath.row];
    ClassListController *vc = [[ClassListController alloc] initWithImage:path];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

@interface BinaryMonitorController : UIViewController
- (instancetype)initWithBinaryPath:(NSString *)binaryPath imageIndex:(uint32_t)imageIndex;
@end

@interface BinaryMonitorController ()
@property(nonatomic,strong) NSString *binaryPath;
@property(nonatomic) uint32_t imageIndex;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UITextView *logView;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSString *baselineHash;
@property(nonatomic,strong) NSString *previousHash;
@property(nonatomic) BOOL alerted;
@property(nonatomic) BOOL diffOnly;
@end

@implementation BinaryMonitorController

- (instancetype)initWithBinaryPath:(NSString *)binaryPath imageIndex:(uint32_t)imageIndex {
    self = [super init];
    if (self) {
        _binaryPath = binaryPath;
        _imageIndex = imageIndex;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.binaryPath.lastPathComponent;
    self.view.backgroundColor = UIColor.blackColor;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, self.view.bounds.size.width - 32, 70)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = UIColor.systemGreenColor;
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, 180, self.view.bounds.size.width - 24, self.view.bounds.size.height - 200)];
    self.logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.logView.backgroundColor = UIColor.blackColor;
    self.logView.textColor = UIColor.greenColor;
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:self.logView];
    self.logView.hidden = MonitorCompactMode();

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"差分"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleDiffOnly)],
        [[UIBarButtonItem alloc] initWithTitle:@"BG"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleBackgroundMonitor)]
    ];

    self.baselineHash = TextSegmentHashForImageIndex(self.imageIndex);
    self.previousHash = self.baselineHash;
    if (!self.baselineHash) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"監視開始失敗:hashを取得できません";
        return;
    }

    self.statusLabel.text = @"JIT監視中 \nStatus: OK";
    [self appendLog:[NSString stringWithFormat:@"[%@] monitor started", NowTimeString()]];
    [self appendLog:[NSString stringWithFormat:@"baseline: %@", self.baselineHash]];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:MonitorRefreshInterval()
                                                  target:self
                                                selector:@selector(checkIntegrity)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!MonitorBackgroundBinary()) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

- (void)appendLog:(NSString *)line {
    NSString *existing = self.logView.text ?: @"";
    NSString *next = existing.length ? [existing stringByAppendingFormat:@"\n%@", line] : line;
    self.logView.text = next;
    NSRange bottom = NSMakeRange(next.length, 0);
    [self.logView scrollRangeToVisible:bottom];
}

- (void)checkIntegrity {
    NSString *current = TextSegmentHashForImageIndex(self.imageIndex);
    if (!current) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"Status: ERROR (__TEXT read failed)";
        [self appendLog:[NSString stringWithFormat:@"[%@] hash read failed", NowTimeString()]];
        return;
    }

    if (![current isEqualToString:self.baselineHash]) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"Status: ALERT (__TEXT changed)";
        if (!self.diffOnly || ![current isEqualToString:self.previousHash]) {
            [self appendLog:[NSString stringWithFormat:@"[%@] ALERT: hash mismatch", NowTimeString()]];
            [self appendLog:[NSString stringWithFormat:@"current: %@", current]];
        }

        if (!self.alerted) {
            self.alerted = YES;
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"不正変更を検知"
                                                message:@"JIT/パッチの可能性があります。"
                                         preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else {
        self.statusLabel.textColor = UIColor.systemGreenColor;
        self.statusLabel.text = [NSString stringWithFormat:@"JIT監視中\nStatus: OK (%@)", NowTimeString()];
    }
    self.previousHash = current;
}

- (void)toggleDiffOnly {
    self.diffOnly = !self.diffOnly;
    [[ExecutionTracker shared] logSessionEvent:@"binary" message:(self.diffOnly ? @"diff only on" : @"diff only off")];
}

- (void)toggleBackgroundMonitor {
    BOOL on = !MonitorBackgroundBinary();
    [MonitorUD() setBool:on forKey:kPrefBackgroundBinary];
    [[ExecutionTracker shared] logSessionEvent:@"binary" message:(on ? @"background monitor on" : @"background monitor off")];
}

@end

@interface BinaryListController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSDictionary *> *binaries;
@property(nonatomic,strong) NSArray<NSDictionary *> *filteredBinaries;
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,strong) NSMutableSet<NSString *> *favorites;
@end

@implementation BinaryListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"バイナリ監視";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.favorites = [NSMutableSet setWithArray:[MonitorUD() arrayForKey:@"binary_favorites"] ?: @[]];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"binary filter";
    self.navigationItem.searchController = self.searchController;
    [self loadMainBinaries];
}

- (void)loadMainBinaries {
    uint32_t count = _dyld_image_count();
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!header || !name) continue;
        if (header->filetype != MH_EXECUTE) continue;

        NSString *path = [NSString stringWithUTF8String:name];
        if ([seen containsObject:path]) continue;
        [seen addObject:path];

        [result addObject:@{
            @"name": path.lastPathComponent ?: @"(unknown)",
            @"path": path,
            @"index": @(i)
        }];
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL af = [self.favorites containsObject:a[@"path"]];
        BOOL bf = [self.favorites containsObject:b[@"path"]];
        if (af != bf) return af ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"]];
    }];
    self.binaries = result;
    self.filteredBinaries = result;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = searchController.searchBar.text.lowercaseString ?: @"";
    if (q.length == 0) {
        self.filteredBinaries = self.binaries;
    } else {
        self.filteredBinaries = [self.binaries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *obj, NSDictionary *_) {
            NSString *name = [obj[@"name"] lowercaseString] ?: @"";
            NSString *path = [obj[@"path"] lowercaseString] ?: @"";
            return [name containsString:q] || [path containsString:q];
        }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredBinaries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"BinaryCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"BinaryCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSDictionary *item = self.filteredBinaries[indexPath.row];
    cell.textLabel.text = item[@"name"];
    BOOL fav = [self.favorites containsObject:item[@"path"]];
    cell.detailTextLabel.text = fav ? [NSString stringWithFormat:@"★ %@", item[@"path"]] : item[@"path"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = self.filteredBinaries[indexPath.row];
    BinaryMonitorController *vc =
    [[BinaryMonitorController alloc] initWithBinaryPath:item[@"path"]
                                             imageIndex:[item[@"index"] unsignedIntValue]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.filteredBinaries[indexPath.row];
    NSString *path = item[@"path"];
    BOOL isFav = [self.favorites containsObject:path];
    UIContextualAction *fav =
    [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                            title:(isFav ? @"Unpin" : @"Pin")
                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        if (isFav) [self.favorites removeObject:path];
        else [self.favorites addObject:path];
        [MonitorUD() setObject:self.favorites.allObjects forKey:@"binary_favorites"];
        [[ExecutionTracker shared] logSessionEvent:@"favorite" message:[NSString stringWithFormat:@"%@ %@", isFav ? @"unpin binary" : @"pin binary", path.lastPathComponent ?: @""]];
        [self loadMainBinaries];
        completionHandler(YES);
    }];
    fav.backgroundColor = isFav ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[fav]];
}

@end

@interface MemoryMonitorController : UITableViewController
@property(nonatomic,strong) NSArray<MethodExecutionInfo *> *rows;
@property(nonatomic,strong) NSTimer *refreshTimer;
@end

@implementation MemoryMonitorController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"メモリ監視";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = MonitorCompactMode() ? 50.0 : 72.0;
    self.tableView.tableFooterView = [UIView new];
    [self refreshRows];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:MonitorRefreshInterval()
                                                         target:self
                                                       selector:@selector(refreshRows)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshRows {
    self.rows = [[ExecutionTracker shared] sortedByMemoryDelta];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MemoryCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"MemoryCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    }

    MethodExecutionInfo *info = self.rows[indexPath.row];
    cell.textLabel.text = info.methodName;
    if (MonitorCompactMode()) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"memΔ:%lldB count:%ld",
                                     info.totalMemoryDeltaBytes, (long)info.count];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"retain:%lu avg:%.2f memΔ:%lldB Σ:%lldB objCreate:%lu",
                                     (unsigned long)info.lastRetainCount,
                                     info.averageRetainCount,
                                     info.lastMemoryDeltaBytes,
                                     info.totalMemoryDeltaBytes,
                                     (unsigned long)info.objectCreateCount];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    MethodExecutionInfo *info = self.rows[indexPath.row];
    NSString *msg = [NSString stringWithFormat:@"method: %@\nretain(last): %lu\nretain(avg): %.2f\nmem delta(last): %lld bytes\nmem delta(total): %lld bytes\nobject create count: %lu",
                     info.methodName ?: @"",
                     (unsigned long)info.lastRetainCount,
                     info.averageRetainCount,
                     info.lastMemoryDeltaBytes,
                     info.totalMemoryDeltaBytes,
                     (unsigned long)info.objectCreateCount];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:@"Memory Detail"
                                        message:msg
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface SessionLogController : UITableViewController
@property(nonatomic,strong) NSArray<NSDictionary *> *rows;
@end

@implementation SessionLogController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"セッションログ";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = MonitorCompactMode() ? 44.0 : 66.0;
    self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItem =
    [[UIBarButtonItem alloc] initWithTitle:@"更新"
                                     style:UIBarButtonItemStylePlain
                                    target:self
                                    action:@selector(reloadRows)];
    [self reloadRows];
}

- (void)reloadRows {
    self.rows = [[[ExecutionTracker shared] recentSessionEvents] reverseObjectEnumerator].allObjects ?: @[];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SessionCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SessionCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    }
    NSDictionary *row = self.rows[indexPath.row];
    NSTimeInterval t = [row[@"time"] doubleValue];
    NSString *msg = row[@"message"] ?: @"";
    NSString *kind = row[@"kind"] ?: @"event";
    cell.textLabel.text = [NSString stringWithFormat:@"[%@] %@", kind, msg];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"unix:%.3f", t];
    return cell;
}

@end

@interface MonitorToolsController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *items;
@end

@implementation MonitorToolsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ツール";
    self.items = @[
        @"プロファイル保存 Slot1",
        @"プロファイル保存 Slot2",
        @"プロファイル保存 Slot3",
        @"プロファイル復元 Slot1",
        @"プロファイル復元 Slot2",
        @"プロファイル復元 Slot3",
        @"JSONコピー",
        @"CSVコピー",
        @"前回クラッシュ表示",
        @"クラッシュ情報クリア",
        @"診断テスト実行",
        @"セッションログを開く"
    ];
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 56.0;
    self.tableView.tableFooterView = [UIView new];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ToolCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ToolCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    }
    cell.textLabel.text = self.items[indexPath.row];
    if (indexPath.row <= 5) cell.detailTextLabel.text = @"現在の設定/統計を保存または復元";
    else if (indexPath.row <= 7) cell.detailTextLabel.text = @"クリップボードにエクスポート";
    else if (indexPath.row <= 10) cell.detailTextLabel.text = @"運用時のデバッグ補助";
    else cell.detailTextLabel.text = @"時系列イベント";
    return cell;
}

- (void)saveProfileSlot:(NSInteger)slot {
    NSMutableDictionary *all = [[MonitorUD() dictionaryForKey:kProfileSlotsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *snap = @{
        @"time": NowDateTimeString(),
        @"tracker": [[ExecutionTracker shared] snapshot],
        @"prefs": @{
            kPrefRefreshInterval: @([MonitorUD() doubleForKey:kPrefRefreshInterval]),
            kPrefBatterySaver: @([MonitorUD() boolForKey:kPrefBatterySaver]),
            kPrefCompactMode: @([MonitorUD() boolForKey:kPrefCompactMode]),
            kPrefWriteConfirm: @([MonitorUD() boolForKey:kPrefWriteConfirm]),
            kPrefBackgroundBinary: @([MonitorUD() boolForKey:kPrefBackgroundBinary])
        }
    };
    all[[NSString stringWithFormat:@"slot%ld", (long)slot]] = snap;
    [MonitorUD() setObject:all forKey:kProfileSlotsKey];
    [[ExecutionTracker shared] logSessionEvent:@"profile" message:[NSString stringWithFormat:@"save slot%ld", (long)slot]];
}

- (void)loadProfileSlot:(NSInteger)slot {
    NSDictionary *all = [MonitorUD() dictionaryForKey:kProfileSlotsKey];
    NSDictionary *snap = all[[NSString stringWithFormat:@"slot%ld", (long)slot]];
    if (![snap isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *prefs = snap[@"prefs"];
    if ([prefs isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in prefs) [MonitorUD() setObject:prefs[key] forKey:key];
    }
    NSDictionary *tracker = snap[@"tracker"];
    if ([tracker isKindOfClass:[NSDictionary class]]) {
        [[ExecutionTracker shared] restoreFromSnapshot:tracker];
    }
    [[ExecutionTracker shared] logSessionEvent:@"profile" message:[NSString stringWithFormat:@"load slot%ld", (long)slot]];
}

- (void)runQuickDiagnostic {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"[OK] tracker singleton"];
    uint8_t test = 0x2a;
    vm_address_t addr = (vm_address_t)&test;
    vm_size_t outSize = 0;
    uint8_t readBack = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), addr, sizeof(uint8_t), (vm_address_t)&readBack, &outSize);
    if (kr == KERN_SUCCESS && outSize == sizeof(uint8_t)) [lines addObject:@"[OK] vm_read_overwrite"];
    else [lines addObject:@"[WARN] vm_read_overwrite"];
    [lines addObject:[NSString stringWithFormat:@"[OK] methods:%lu", (unsigned long)[ExecutionTracker shared].methods.count]];

    NSString *msg = [lines componentsJoinedByString:@"\n"];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:@"診断テスト"
                                        message:msg
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [[ExecutionTracker shared] logSessionEvent:@"diag" message:@"quick diagnostic run"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;

    if (row >= 0 && row <= 2) {
        [self saveProfileSlot:(row + 1)];
        return;
    }
    if (row >= 3 && row <= 5) {
        [self loadProfileSlot:(row - 2)];
        return;
    }
    if (row == 6) {
        [UIPasteboard generalPasteboard].string = [[ExecutionTracker shared] exportJSONSummary] ?: @"{}";
        return;
    }
    if (row == 7) {
        [UIPasteboard generalPasteboard].string = [[ExecutionTracker shared] exportCSVSummary] ?: @"";
        return;
    }
    if (row == 8) {
        NSDictionary *crash = [[ExecutionTracker shared] lastCrashInfo];
        NSString *msg = crash ? [NSString stringWithFormat:@"%@", crash] : @"前回クラッシュ情報なし";
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"前回クラッシュ"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (row == 9) {
        [[ExecutionTracker shared] clearLastCrashInfo];
        return;
    }
    if (row == 10) {
        [self runQuickDiagnostic];
        return;
    }
    if (row == 11) {
        [self.navigationController pushViewController:[SessionLogController new] animated:YES];
    }
}

@end

@interface MonitorSettingsController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *items;
@end

@implementation MonitorSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"設定";
    self.items = @[@"更新間隔 0.25s", @"更新間隔 0.5s", @"更新間隔 1.0s", @"更新間隔 2.0s", @"バッテリー節約", @"コンパクト表示", @"書込前確認", @"バックグラウンドバイナリ監視"];
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 54.0;
    self.tableView.tableFooterView = [UIView new];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SettingCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"SettingCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
    }
    cell.textLabel.text = self.items[indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryNone;

    double interval = [MonitorUD() doubleForKey:kPrefRefreshInterval];
    if (interval <= 0) interval = 1.0;
    if (indexPath.row == 0 && fabs(interval - 0.25) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row == 1 && fabs(interval - 0.5) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row == 2 && fabs(interval - 1.0) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row == 3 && fabs(interval - 2.0) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row >= 4) {
        BOOL on = NO;
        if (indexPath.row == 4) on = [MonitorUD() boolForKey:kPrefBatterySaver];
        if (indexPath.row == 5) on = [MonitorUD() boolForKey:kPrefCompactMode];
        if (indexPath.row == 6) on = [MonitorUD() objectForKey:kPrefWriteConfirm] ? [MonitorUD() boolForKey:kPrefWriteConfirm] : YES;
        if (indexPath.row == 7) on = [MonitorUD() boolForKey:kPrefBackgroundBinary];
        cell.detailTextLabel.text = on ? @"ON" : @"OFF";
    } else {
        cell.detailTextLabel.text = @"";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row <= 3) {
        NSArray *vals = @[@0.25, @0.5, @1.0, @2.0];
        [MonitorUD() setDouble:[vals[indexPath.row] doubleValue] forKey:kPrefRefreshInterval];
    } else {
        NSString *key = nil;
        if (indexPath.row == 4) key = kPrefBatterySaver;
        if (indexPath.row == 5) key = kPrefCompactMode;
        if (indexPath.row == 6) key = kPrefWriteConfirm;
        if (indexPath.row == 7) key = kPrefBackgroundBinary;
        if (key) [MonitorUD() setBool:![MonitorUD() boolForKey:key] forKey:key];
    }
    [[ExecutionTracker shared] logSessionEvent:@"setting" message:[NSString stringWithFormat:@"tapped row:%ld", (long)indexPath.row]];
    [tableView reloadData];
}

@end

@interface MonitorViewController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *menuItems;
@end

@implementation MonitorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Monitor";
    self.menuItems = @[@"HOOK", @"バイナリ監視", @"メモリ監視", @"メモリ追跡", @"ツール", @"設定"];

    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.tableFooterView = [UIView new];

    self.navigationItem.leftBarButtonItem =
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                   target:self
                                                   action:@selector(closeTapped)];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.menuItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MenuCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"MenuCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSString *title = self.menuItems[indexPath.row];
    cell.textLabel.text = title;
    if (indexPath.row == 0) {
        cell.detailTextLabel.text = @"Hookブラウザ";
    } else if (indexPath.row == 1) {
        cell.detailTextLabel.text = @"実行中メインバイナリのJIT不正変更監視";
    } else if (indexPath.row == 2) {
        cell.detailTextLabel.text = @"メソッドごとのretain/memory/object生成監視";
    } else if (indexPath.row == 3) {
        cell.detailTextLabel.text = @"数値/文字列サーチ・書換え・ロック";
    } else if (indexPath.row == 4) {
        cell.detailTextLabel.text = @"プロファイル/ログ/エクスポート/診断";
    } else {
        cell.detailTextLabel.text = @"更新間隔/省電力/コンパクト表示/安全ガード";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    UIViewController *next = nil;
    if (indexPath.row == 0) {
        next = [HookDylibListController new];
    } else if (indexPath.row == 1) {
        next = [BinaryListController new];
    } else if (indexPath.row == 2) {
        next = [MemoryMonitorController new];
    } else if (indexPath.row == 3) {
        Class cls = NSClassFromString(@"MemorySearchController");
        next = [cls new];
    } else if (indexPath.row == 4) {
        next = [MonitorToolsController new];
    } else {
        next = [MonitorSettingsController new];
    }
    [[ExecutionTracker shared] logSessionEvent:@"menu" message:[NSString stringWithFormat:@"open %@", self.menuItems[indexPath.row]]];
    [self.navigationController pushViewController:next animated:YES];
}

- (BOOL)shouldAutorotate {
    return NO;
}

@end
