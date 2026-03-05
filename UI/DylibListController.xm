#import <UIKit/UIKit.h>
#import "ClassListController.h"

extern NSArray *GetLoadedDylibs(void);

@interface DylibListController : UITableViewController
@property(nonatomic,strong) NSArray *dylibs;
@end

@implementation DylibListController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Loaded dylibs";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;

    self.dylibs = GetLoadedDylibs();

    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.dylibs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.textLabel.text = [self.dylibs[indexPath.row] lastPathComponent];
    cell.textLabel.textColor = UIColor.greenColor;
    cell.backgroundColor = UIColor.blackColor;
    cell.textLabel.font = [UIFont systemFontOfSize:12];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *selected = self.dylibs[indexPath.row];

    Class cls = NSClassFromString(@"ClassListController");
    if (!cls) return;

    UIViewController *vc = [[cls alloc] initWithImage:selected];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
