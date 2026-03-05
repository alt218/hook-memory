#import <Foundation/Foundation.h>

static NSMutableArray *globalLogs;

void LoggerInit() {
    globalLogs = [NSMutableArray array];
}

void AddLog(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [globalLogs addObject:text];
        if (globalLogs.count > 1000)
            [globalLogs removeObjectAtIndex:0];
    });
}

NSArray *GetLogs() {
    return globalLogs;
}
