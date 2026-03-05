#import "ExecutionTracker.h"
#import <signal.h>

@implementation MethodExecutionInfo
@end

@implementation MethodFlowEdge
@end

static NSString *const kMethodExecutedNotification = @"MethodExecuted";
static NSString *const kMethodAutoStoppedNotification = @"MethodAutoStopped";
static NSString *const kMethodAutoSwapNotification = @"MethodAutoSwap";
static NSString *const kMethodAutoDisableNotification = @"MethodAutoDisable";
static NSString *const kTrackerCrashInfoKey = @"tracker_last_crash_info_v1";
static NSString *const kTrackerSessionEventsKey = @"tracker_session_events_v1";

static void SaveCrashInfo(NSDictionary *info) {
    if (!info) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:info forKey:kTrackerCrashInfoKey];
    [ud synchronize];
}

static void TrackerSignalHandler(int sig) {
    SaveCrashInfo(@{
        @"kind": @"signal",
        @"signal": @(sig),
        @"time": @([[NSDate date] timeIntervalSince1970])
    });
    signal(sig, SIG_DFL);
    raise(sig);
}

static void TrackerExceptionHandler(NSException *exception) {
    SaveCrashInfo(@{
        @"kind": @"exception",
        @"name": exception.name ?: @"",
        @"reason": exception.reason ?: @"",
        @"time": @([[NSDate date] timeIntervalSince1970])
    });
}

static NSString *EdgeKey(NSString *caller, NSString *callee) {
    return [NSString stringWithFormat:@"%@=>%@", caller ?: @"(unknown)", callee ?: @"(unknown)"];
}

@interface ExecutionTracker ()
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *methodObjectSets;
@end

@implementation ExecutionTracker

+ (instancetype)shared {
    static ExecutionTracker *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[ExecutionTracker alloc] init];
        sharedInstance.methods = [NSMutableDictionary dictionary];
        sharedInstance.executionOrder = [NSMutableArray array];
        sharedInstance.autoStopLimits = [NSMutableDictionary dictionary];
        sharedInstance.blockedMethods = [NSMutableSet set];
        sharedInstance.autoSwapRules = [NSMutableDictionary dictionary];
        sharedInstance.flowEdges = [NSMutableDictionary dictionary];
        sharedInstance.methodObjectSets = [NSMutableDictionary dictionary];
        sharedInstance.sessionEvents = [NSMutableArray array];

        NSArray *savedEvents = [[NSUserDefaults standardUserDefaults] objectForKey:kTrackerSessionEventsKey];
        if ([savedEvents isKindOfClass:[NSArray class]]) {
            [sharedInstance.sessionEvents addObjectsFromArray:savedEvents];
        }

        NSSetUncaughtExceptionHandler(TrackerExceptionHandler);
        signal(SIGABRT, TrackerSignalHandler);
        signal(SIGSEGV, TrackerSignalHandler);
        signal(SIGBUS, TrackerSignalHandler);
        signal(SIGILL, TrackerSignalHandler);
    });
    return sharedInstance;
}

- (void)recordExecution:(NSString *)methodName {
    NSString *caller = nil;
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    if (stack.count > 2) {
        caller = stack[2];
    }
    [self recordExecutionForMethod:methodName
                            caller:caller
                         durationMs:0
                          arguments:nil
                        returnValue:nil
                            blocked:NO
                        retainCount:0
                    memoryDeltaBytes:0
                       objectAddress:nil];
}

- (void)recordExecutionForMethod:(NSString *)methodName
                          caller:(NSString *)caller
                       durationMs:(double)durationMs
                        arguments:(NSString *)arguments
                      returnValue:(NSString *)returnValue
                          blocked:(BOOL)blocked
                      retainCount:(NSUInteger)retainCount
                  memoryDeltaBytes:(long long)memoryDeltaBytes
                     objectAddress:(NSString *)objectAddress {
    if (methodName.length == 0) return;

    @synchronized (self) {

        MethodExecutionInfo *info = self.methods[methodName];
        NSDate *now = [NSDate date];

        if (!info) {
            info = [[MethodExecutionInfo alloc] init];
            info.methodName = methodName;
            info.count = 0;
            info.firstOrder = self.executionOrder.count + 1;
            [self.executionOrder addObject:methodName];
        }

        double interval = 0;
        if (info.lastExecution) {
            interval = [now timeIntervalSinceDate:info.lastExecution] * 1000;
        }

        info.count += 1;
        info.interval = interval;
        info.lastExecution = now;
        info.threadID = [NSString stringWithFormat:@"%p", [NSThread currentThread]];
        info.callStack = [NSThread callStackSymbols];
        info.caller = caller ?: @"(unknown)";
        info.lastArguments = arguments ?: @"";
        info.lastReturnValue = returnValue ?: @"";
        info.lastDurationMs = durationMs;
        info.totalDurationMs += durationMs;
        info.maxDurationMs = MAX(info.maxDurationMs, durationMs);
        info.blocked = blocked;
        info.lastRetainCount = retainCount;
        if (info.count > 0) {
            double weighted = info.averageRetainCount * (double)(info.count - 1);
            info.averageRetainCount = (weighted + (double)retainCount) / (double)info.count;
        } else {
            info.averageRetainCount = (double)retainCount;
        }
        info.lastMemoryDeltaBytes = memoryDeltaBytes;
        info.totalMemoryDeltaBytes += memoryDeltaBytes;

        if (objectAddress.length > 0) {
            NSMutableSet<NSString *> *set = self.methodObjectSets[methodName];
            if (!set) {
                set = [NSMutableSet set];
                self.methodObjectSets[methodName] = set;
            }
            NSUInteger beforeCount = set.count;
            [set addObject:objectAddress];
            if (set.count > beforeCount) {
                info.objectCreateCount += 1;
            }
        }

        self.methods[methodName] = info;

        if (caller.length > 0) {
            NSString *edgeKey = EdgeKey(caller, methodName);
            MethodFlowEdge *edge = self.flowEdges[edgeKey];
            if (!edge) {
                edge = [[MethodFlowEdge alloc] init];
                edge.caller = caller;
                edge.callee = methodName;
                edge.count = 0;
            }
            edge.count += 1;
            edge.lastSeen = now;
            self.flowEdges[edgeKey] = edge;
        }

        NSInteger limit = [self.autoStopLimits[methodName] integerValue];
        if (limit > 0 && info.count >= limit) {
            [[NSNotificationCenter defaultCenter]
             postNotificationName:kMethodAutoStoppedNotification
             object:nil
             userInfo:@{
                @"method": methodName,
                @"count": @(info.count),
                @"limit": @(limit)
             }];
            [self.autoStopLimits removeObjectForKey:methodName];
        }

        NSMutableDictionary *rule = self.autoSwapRules[methodName];
        if (rule) {
            NSInteger swapAt = [rule[@"swapAt"] integerValue];
            NSInteger disableAt = [rule[@"disableAt"] integerValue];
            BOOL swapDone = [rule[@"swapDone"] boolValue];
            BOOL disableDone = [rule[@"disableDone"] boolValue];

            if (!swapDone && swapAt > 0 && info.count >= swapAt) {
                rule[@"swapDone"] = @YES;
                [[NSNotificationCenter defaultCenter]
                 postNotificationName:kMethodAutoSwapNotification
                 object:nil
                 userInfo:@{
                    @"method": methodName,
                    @"targetMethod": rule[@"targetMethod"] ?: @"",
                    @"count": @(info.count)
                 }];
            }

            if (!disableDone && disableAt > 0 && info.count >= disableAt) {
                rule[@"disableDone"] = @YES;
                [[NSNotificationCenter defaultCenter]
                 postNotificationName:kMethodAutoDisableNotification
                 object:nil
                 userInfo:@{
                    @"method": methodName,
                    @"count": @(info.count)
                 }];
            }
        }

        [[NSNotificationCenter defaultCenter]
         postNotificationName:kMethodExecutedNotification
         object:nil
         userInfo:@{
            @"method": methodName,
            @"count": @(info.count),
            @"lastExecution": now,
            @"duration_ms": @(durationMs),
            @"blocked": @(blocked),
            @"caller": info.caller ?: @"",
            @"retain_count": @(retainCount),
            @"memory_delta_bytes": @(memoryDeltaBytes),
            @"object_create_count": @(info.objectCreateCount)
         }];

        [self logSessionEvent:@"exec"
                      message:[NSString stringWithFormat:@"%@ count:%ld dur:%.2fms",
                               methodName, (long)info.count, durationMs]];
    }
}

- (MethodExecutionInfo *)infoForMethod:(NSString *)methodName {
    @synchronized (self) {
        return self.methods[methodName];
    }
}

- (NSArray *)sortedByOrder {
    NSMutableArray *array = [NSMutableArray array];
    for (NSString *name in self.executionOrder) {
        [array addObject:self.methods[name]];
    }
    return array;
}

- (NSArray *)sortedByCount {
    return [self.methods.allValues sortedArrayUsingComparator:^NSComparisonResult(MethodExecutionInfo *a, MethodExecutionInfo *b) {
        return b.count - a.count;
    }];
}

- (NSArray *)sortedByRecent {
    return [self.methods.allValues sortedArrayUsingComparator:^NSComparisonResult(MethodExecutionInfo *a, MethodExecutionInfo *b) {
        return [b.lastExecution compare:a.lastExecution];
    }];
}

- (NSArray *)sortedByDuration {
    return [self.methods.allValues sortedArrayUsingComparator:^NSComparisonResult(MethodExecutionInfo *a, MethodExecutionInfo *b) {
        if (a.totalDurationMs == b.totalDurationMs) return NSOrderedSame;
        return a.totalDurationMs < b.totalDurationMs ? NSOrderedDescending : NSOrderedAscending;
    }];
}

- (NSArray *)sortedByMemoryDelta {
    return [self.methods.allValues sortedArrayUsingComparator:^NSComparisonResult(MethodExecutionInfo *a, MethodExecutionInfo *b) {
        long long aa = llabs(a.totalMemoryDeltaBytes);
        long long bb = llabs(b.totalMemoryDeltaBytes);
        if (aa == bb) return NSOrderedSame;
        return aa < bb ? NSOrderedDescending : NSOrderedAscending;
    }];
}

- (void)setAutoStopLimit:(NSInteger)limit forMethod:(NSString *)methodName {
    if (methodName.length == 0) return;

    @synchronized (self) {
        if (limit <= 0) {
            [self.autoStopLimits removeObjectForKey:methodName];
        } else {
            self.autoStopLimits[methodName] = @(limit);
        }
    }
}

- (NSInteger)autoStopLimitForMethod:(NSString *)methodName {
    @synchronized (self) {
        return [self.autoStopLimits[methodName] integerValue];
    }
}

- (void)setBlocked:(BOOL)blocked forMethod:(NSString *)methodName {
    if (methodName.length == 0) return;
    @synchronized (self) {
        if (blocked) {
            [self.blockedMethods addObject:methodName];
        } else {
            [self.blockedMethods removeObject:methodName];
        }
    }
}

- (BOOL)isBlocked:(NSString *)methodName {
    if (methodName.length == 0) return NO;
    @synchronized (self) {
        return [self.blockedMethods containsObject:methodName];
    }
}

- (void)setAutoSwapAt:(NSInteger)swapAt
            disableAt:(NSInteger)disableAt
        targetMethod:(NSString *)targetMethod
            forMethod:(NSString *)methodName {
    if (methodName.length == 0) return;
    @synchronized (self) {
        if (swapAt <= 0 && disableAt <= 0) {
            [self.autoSwapRules removeObjectForKey:methodName];
            return;
        }
        NSMutableDictionary *rule = [@{
            @"swapAt": @(MAX(0, swapAt)),
            @"disableAt": @(MAX(0, disableAt)),
            @"targetMethod": targetMethod ?: @"",
            @"swapDone": @NO,
            @"disableDone": @NO
        } mutableCopy];
        self.autoSwapRules[methodName] = rule;
    }
}

- (NSDictionary *)autoSwapRuleForMethod:(NSString *)methodName {
    @synchronized (self) {
        return [self.autoSwapRules[methodName] copy];
    }
}

- (NSString *)flowSummaryForMethod:(NSString *)methodName {
    if (methodName.length == 0) return @"";

    @synchronized (self) {
        NSMutableArray<MethodFlowEdge *> *children = [NSMutableArray array];
        for (MethodFlowEdge *edge in self.flowEdges.allValues) {
            if ([edge.caller isEqualToString:methodName]) {
                [children addObject:edge];
            }
        }

        [children sortUsingComparator:^NSComparisonResult(MethodFlowEdge *a, MethodFlowEdge *b) {
            return b.count - a.count;
        }];

        NSMutableString *text = [NSMutableString stringWithFormat:@"%@\n", methodName];
        if (children.count == 0) {
            [text appendString:@"  (no tracked callees yet)"];
            return text;
        }

        NSInteger shown = 0;
        for (MethodFlowEdge *edge in children) {
            [text appendFormat:@"  └── %@  [count:%ld]\n", edge.callee, (long)edge.count];
            shown += 1;
            if (shown >= 20) break;
        }
        return text;
    }
}

- (void)logSessionEvent:(NSString *)kind message:(NSString *)message {
    if (message.length == 0) return;
    @synchronized (self) {
        NSDictionary *row = @{
            @"kind": kind ?: @"event",
            @"message": message,
            @"time": @([[NSDate date] timeIntervalSince1970])
        };
        [self.sessionEvents addObject:row];
        if (self.sessionEvents.count > 300) {
            NSRange r = NSMakeRange(0, self.sessionEvents.count - 300);
            [self.sessionEvents removeObjectsInRange:r];
        }
        [[NSUserDefaults standardUserDefaults] setObject:[self.sessionEvents copy]
                                                  forKey:kTrackerSessionEventsKey];
    }
}

- (NSArray<NSDictionary *> *)recentSessionEvents {
    @synchronized (self) {
        return [self.sessionEvents copy];
    }
}

- (NSDictionary *)snapshot {
    @synchronized (self) {
        NSMutableDictionary *methodsSnap = [NSMutableDictionary dictionary];
        for (NSString *key in self.methods) {
            MethodExecutionInfo *i = self.methods[key];
            methodsSnap[key] = @{
                @"methodName": i.methodName ?: @"",
                @"count": @(i.count),
                @"lastExecution": i.lastExecution ?: [NSDate distantPast],
                @"interval": @(i.interval),
                @"threadID": i.threadID ?: @"",
                @"callStack": i.callStack ?: @[],
                @"firstOrder": @(i.firstOrder),
                @"caller": i.caller ?: @"",
                @"lastArguments": i.lastArguments ?: @"",
                @"lastReturnValue": i.lastReturnValue ?: @"",
                @"lastDurationMs": @(i.lastDurationMs),
                @"totalDurationMs": @(i.totalDurationMs),
                @"maxDurationMs": @(i.maxDurationMs),
                @"blocked": @(i.blocked),
                @"lastRetainCount": @(i.lastRetainCount),
                @"averageRetainCount": @(i.averageRetainCount),
                @"lastMemoryDeltaBytes": @(i.lastMemoryDeltaBytes),
                @"totalMemoryDeltaBytes": @(i.totalMemoryDeltaBytes),
                @"objectCreateCount": @(i.objectCreateCount)
            };
        }
        return @{
            @"methods": methodsSnap,
            @"executionOrder": self.executionOrder ?: @[],
            @"autoStopLimits": self.autoStopLimits ?: @{},
            @"blockedMethods": self.blockedMethods.allObjects ?: @[],
            @"autoSwapRules": self.autoSwapRules ?: @{},
            @"sessionEvents": self.sessionEvents ?: @[]
        };
    }
}

- (void)restoreFromSnapshot:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:[NSDictionary class]]) return;
    @synchronized (self) {
        [self.methods removeAllObjects];
        [self.executionOrder removeAllObjects];
        [self.autoStopLimits removeAllObjects];
        [self.blockedMethods removeAllObjects];
        [self.autoSwapRules removeAllObjects];
        [self.flowEdges removeAllObjects];
        [self.methodObjectSets removeAllObjects];

        NSDictionary *methodRows = snapshot[@"methods"];
        if ([methodRows isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in methodRows) {
                NSDictionary *row = methodRows[key];
                if (![row isKindOfClass:[NSDictionary class]]) continue;
                MethodExecutionInfo *i = [MethodExecutionInfo new];
                i.methodName = row[@"methodName"];
                i.count = [row[@"count"] integerValue];
                i.lastExecution = row[@"lastExecution"];
                i.interval = [row[@"interval"] doubleValue];
                i.threadID = row[@"threadID"];
                i.callStack = row[@"callStack"];
                i.firstOrder = [row[@"firstOrder"] unsignedIntegerValue];
                i.caller = row[@"caller"];
                i.lastArguments = row[@"lastArguments"];
                i.lastReturnValue = row[@"lastReturnValue"];
                i.lastDurationMs = [row[@"lastDurationMs"] doubleValue];
                i.totalDurationMs = [row[@"totalDurationMs"] doubleValue];
                i.maxDurationMs = [row[@"maxDurationMs"] doubleValue];
                i.blocked = [row[@"blocked"] boolValue];
                i.lastRetainCount = [row[@"lastRetainCount"] unsignedIntegerValue];
                i.averageRetainCount = [row[@"averageRetainCount"] doubleValue];
                i.lastMemoryDeltaBytes = [row[@"lastMemoryDeltaBytes"] longLongValue];
                i.totalMemoryDeltaBytes = [row[@"totalMemoryDeltaBytes"] longLongValue];
                i.objectCreateCount = [row[@"objectCreateCount"] unsignedIntegerValue];
                self.methods[key] = i;
            }
        }

        NSArray *order = snapshot[@"executionOrder"];
        if ([order isKindOfClass:[NSArray class]]) [self.executionOrder addObjectsFromArray:order];

        NSDictionary *limits = snapshot[@"autoStopLimits"];
        if ([limits isKindOfClass:[NSDictionary class]]) [self.autoStopLimits addEntriesFromDictionary:limits];

        NSArray *blocked = snapshot[@"blockedMethods"];
        if ([blocked isKindOfClass:[NSArray class]]) [self.blockedMethods unionSet:[NSSet setWithArray:blocked]];

        NSDictionary *rules = snapshot[@"autoSwapRules"];
        if ([rules isKindOfClass:[NSDictionary class]]) [self.autoSwapRules addEntriesFromDictionary:rules];

        NSArray *events = snapshot[@"sessionEvents"];
        [self.sessionEvents removeAllObjects];
        if ([events isKindOfClass:[NSArray class]]) [self.sessionEvents addObjectsFromArray:events];

        [self logSessionEvent:@"profile" message:@"snapshot restored"];
    }
}

- (NSDictionary *)lastCrashInfo {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kTrackerCrashInfoKey];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    return nil;
}

- (void)clearLastCrashInfo {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTrackerCrashInfoKey];
}

@end
