#import <Foundation/Foundation.h>

@interface MethodExecutionInfo : NSObject

@property NSString *methodName;
@property NSInteger count;
@property NSDate *lastExecution;
@property double interval;
@property NSString *threadID;
@property NSArray *callStack;
@property NSUInteger firstOrder;
@property NSString *caller;
@property NSString *lastArguments;
@property NSString *lastReturnValue;
@property double lastDurationMs;
@property double totalDurationMs;
@property double maxDurationMs;
@property BOOL blocked;
@property NSUInteger lastRetainCount;
@property double averageRetainCount;
@property long long lastMemoryDeltaBytes;
@property long long totalMemoryDeltaBytes;
@property NSUInteger objectCreateCount;

@end

@interface MethodFlowEdge : NSObject
@property NSString *caller;
@property NSString *callee;
@property NSInteger count;
@property NSDate *lastSeen;
@end

@interface ExecutionTracker : NSObject

@property NSMutableDictionary<NSString *, MethodExecutionInfo *> *methods;
@property NSMutableArray<NSString *> *executionOrder;
@property NSMutableDictionary<NSString *, NSNumber *> *autoStopLimits;
@property NSMutableSet<NSString *> *blockedMethods;
@property NSMutableDictionary<NSString *, NSMutableDictionary *> *autoSwapRules;
@property NSMutableDictionary<NSString *, MethodFlowEdge *> *flowEdges;
@property NSMutableArray<NSDictionary *> *sessionEvents;

+ (instancetype)shared;

- (void)recordExecution:(NSString *)methodName;
- (void)recordExecutionForMethod:(NSString *)methodName
                          caller:(NSString *)caller
                       durationMs:(double)durationMs
                        arguments:(NSString *)arguments
                      returnValue:(NSString *)returnValue
                          blocked:(BOOL)blocked
                      retainCount:(NSUInteger)retainCount
                  memoryDeltaBytes:(long long)memoryDeltaBytes
                     objectAddress:(NSString *)objectAddress;
- (MethodExecutionInfo *)infoForMethod:(NSString *)methodName;
- (NSArray<MethodExecutionInfo *> *)sortedByOrder;
- (NSArray<MethodExecutionInfo *> *)sortedByCount;
- (NSArray<MethodExecutionInfo *> *)sortedByRecent;
- (NSArray<MethodExecutionInfo *> *)sortedByDuration;
- (NSArray<MethodExecutionInfo *> *)sortedByMemoryDelta;
- (void)setAutoStopLimit:(NSInteger)limit forMethod:(NSString *)methodName;
- (NSInteger)autoStopLimitForMethod:(NSString *)methodName;
- (void)setBlocked:(BOOL)blocked forMethod:(NSString *)methodName;
- (BOOL)isBlocked:(NSString *)methodName;
- (void)setAutoSwapAt:(NSInteger)swapAt
            disableAt:(NSInteger)disableAt
        targetMethod:(NSString *)targetMethod
            forMethod:(NSString *)methodName;
- (NSDictionary *)autoSwapRuleForMethod:(NSString *)methodName;
- (NSString *)flowSummaryForMethod:(NSString *)methodName;
- (void)logSessionEvent:(NSString *)kind message:(NSString *)message;
- (NSArray<NSDictionary *> *)recentSessionEvents;
- (NSDictionary *)snapshot;
- (void)restoreFromSnapshot:(NSDictionary *)snapshot;
- (NSString *)exportJSONSummary;
- (NSString *)exportCSVSummary;
- (NSDictionary *)lastCrashInfo;
- (void)clearLastCrashInfo;

@end
