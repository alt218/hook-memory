#import "ClassListController.h"
#import "ClassManager.h"
#import "MethodListController.h"

@interface ClassListController ()
@property(nonatomic,strong) NSArray<NSString *> *classes;
@property(nonatomic,strong) NSString *imageName;
@end

@implementation ClassListController

#pragma mark - init

- (instancetype)initWithImage:(NSString *)imageName {

    self = [super initWithStyle:UITableViewStylePlain];

    if (self) {
        _imageName = imageName;
        _classes = GetClassesForImage(imageName);
        self.title = imageName.lastPathComponent;
    }

    return self;
}

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // rootのときだけClose
    BOOL isRoot = (self.navigationController.viewControllers.firstObject == self);

    if (isRoot) {
        self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc]
         initWithBarButtonSystemItem:UIBarButtonSystemItemClose
         target:self
         action:@selector(dismissSelf)];
    } else {
        self.navigationItem.leftBarButtonItem = nil;
    }
}

#pragma mark - table datasource

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.classes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    UITableViewCell *cell =
    [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (!cell) {
        cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:@"cell"];

        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
    }

    cell.textLabel.text = self.classes[indexPath.row];

    return cell;
}

#pragma mark - table delegate

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *className = self.classes[indexPath.row];

    MethodListController *vc =
    [[MethodListController alloc] initWithClassName:className];

    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - dismiss

- (void)dismissSelf {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

@end
