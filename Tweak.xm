#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import "HookManager.h"
#import "UI/ExecutionTracker.h"

extern void LoggerInit(void);

__attribute__((constructor))
static void InitTweak() {
    LoggerInit();
}

#pragma mark - storage

static NSMutableDictionary *originalIMPs;
static NSMutableDictionary *hookTypes;
static NSMutableDictionary *swappedMethods;

#pragma mark - util

static Class GetTargetClass(NSString *className, BOOL isClassMethod) {
    Class cls = NSClassFromString(className);
    return isClassMethod ? object_getClass(cls) : cls;
}

static NSString *HookKey(NSString *className, NSString *methodName, BOOL isClassMethod) {
    return [NSString stringWithFormat:@"%@::%@::%d", className, methodName, isClassMethod];
}

static NSString *SwapKey(NSString *cls, NSString *m1, NSString *m2, BOOL isClassMethod) {
    return [NSString stringWithFormat:@"%@::%@<->%@::%d", cls, m1, m2, isClassMethod];
}

static NSString *RuntimeMethodKey(id self, SEL _cmd) {
    if (!self || !_cmd) return nil;

    NSString *selectorName = NSStringFromSelector(_cmd);
    BOOL isClassMethod = object_isClass(self);
    Class cls = isClassMethod ? (Class)self : [self class];

    // If a superclass method is hooked and invoked on subclass instances,
    // resolve to the originally hooked class key.
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        NSString *probe = HookKey(NSStringFromClass(current), selectorName, isClassMethod);
        if (originalIMPs[probe]) return probe;
    }

    return HookKey(NSStringFromClass(cls), selectorName, isClassMethod);
}

static NSString *CallerSymbolFromStack(void) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    if (stack.count > 2) return stack[2];
    return @"(unknown)";
}

static uint64_t CurrentResidentBytes(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(),
                                 TASK_VM_INFO,
                                 (task_info_t)&vmInfo,
                                 &count);
    if (kr != KERN_SUCCESS) return 0;
    return vmInfo.phys_footprint;
}

static void TrackExecutionWithMeta(NSString *key,
                                   CFAbsoluteTime start,
                                   uint64_t memBefore,
                                   id trackedObject,
                                   NSString *arguments,
                                   NSString *returnValue,
                                   BOOL blocked) {
    if (key.length == 0) return;
    double durationMs = 0;
    if (start > 0) {
        durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    }
    uint64_t memAfter = CurrentResidentBytes();
    long long memDelta = (long long)memAfter - (long long)memBefore;
    NSUInteger retain = trackedObject ? CFGetRetainCount((__bridge CFTypeRef)trackedObject) : 0;
    NSString *objectAddress = trackedObject ? [NSString stringWithFormat:@"%p", trackedObject] : @"";

    [[ExecutionTracker shared] recordExecutionForMethod:key
                                                 caller:CallerSymbolFromStack()
                                              durationMs:durationMs
                                               arguments:arguments
                                             returnValue:returnValue
                                                 blocked:blocked
                                             retainCount:retain
                                         memoryDeltaBytes:memDelta
                                            objectAddress:objectAddress];
}

static BOOL ShouldBlockKey(NSString *key) {
    if (key.length == 0) return NO;
    return [[ExecutionTracker shared] isBlocked:key];
}

static BOOL ParseHookKey(NSString *key, NSString **className, NSString **methodName, BOOL *isClassMethod) {
    NSArray<NSString *> *parts = [key componentsSeparatedByString:@"::"];
    if (parts.count != 3) return NO;
    if (className) *className = parts[0];
    if (methodName) *methodName = parts[1];
    if (isClassMethod) *isClassMethod = [parts[2] boolValue];
    return YES;
}

#pragma mark - replacement IMP

static id return_nil(id self, SEL _cmd) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    NSString *key = RuntimeMethodKey(self, _cmd);
    BOOL blocked = ShouldBlockKey(key);
    TrackExecutionWithMeta(key, start, memBefore, self, @"", blocked ? @"BLOCKED:nil" : @"nil", blocked);
    return nil;
}
static BOOL return_yes(id self, SEL _cmd) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    NSString *key = RuntimeMethodKey(self, _cmd);
    BOOL blocked = ShouldBlockKey(key);
    BOOL value = blocked ? NO : YES;
    TrackExecutionWithMeta(key, start, memBefore, self, @"", value ? @"YES" : @"NO", blocked);
    return value;
}
static BOOL return_no(id self, SEL _cmd) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    NSString *key = RuntimeMethodKey(self, _cmd);
    BOOL blocked = ShouldBlockKey(key);
    TrackExecutionWithMeta(key, start, memBefore, self, @"", @"NO", blocked);
    return NO;
}
static void disabled_void(id self, SEL _cmd) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    NSString *key = RuntimeMethodKey(self, _cmd);
    TrackExecutionWithMeta(key, start, memBefore, self, @"", @"void", YES);
}
static id disabled_id(id self, SEL _cmd) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    NSString *key = RuntimeMethodKey(self, _cmd);
    TrackExecutionWithMeta(key, start, memBefore, self, @"", @"nil", YES);
    return nil;
}

static IMP GetReplacementIMP(const char *types, HookType type) {

    char ret = types[0];

    switch (type) {

        case HookTypeReturnYES:
        case HookTypeReturnNO:
            if (ret == 'B')
                return type == HookTypeReturnYES ? (IMP)return_yes : (IMP)return_no;
            break;

        case HookTypeReturnNil:
            return (IMP)return_nil;

        case HookTypeDisable:
        default:
            return ret == 'v' ? (IMP)disabled_void : (IMP)disabled_id;
    }

    return (IMP)disabled_id;
}

#pragma mark - Hook適用

void HookManagerApply(NSString *className, NSString *methodName, HookType type, BOOL isClassMethod) {

    Class cls = GetTargetClass(className, isClassMethod);
    SEL sel = NSSelectorFromString(methodName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    NSString *key = HookKey(className, methodName, isClassMethod);
    if (originalIMPs[key]) return;

    IMP originalIMP = method_getImplementation(method);

    originalIMPs[key] = [NSValue valueWithPointer:(const void *)originalIMP];
    hookTypes[key] = @(type);

    IMP newIMP = GetReplacementIMP(method_getTypeEncoding(method), type);
    method_setImplementation(method, newIMP);
}

#pragma mark - Hook解除

void HookManagerRemove(NSString *className, NSString *methodName, BOOL isClassMethod) {

    NSString *key = HookKey(className, methodName, isClassMethod);
    NSValue *val = originalIMPs[key];
    if (!val) return;

    Class cls = GetTargetClass(className, isClassMethod);
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(methodName));

    method_setImplementation(method, (IMP)[val pointerValue]);

    [originalIMPs removeObjectForKey:key];
    [hookTypes removeObjectForKey:key];
}

#pragma mark - Swap

void HookManagerSwapMethods(NSString *className,
                            NSString *method1,
                            NSString *method2,
                            BOOL isClassMethod)
{
    Class cls = GetTargetClass(className, isClassMethod);

    Method m1 = class_getInstanceMethod(cls, NSSelectorFromString(method1));
    Method m2 = class_getInstanceMethod(cls, NSSelectorFromString(method2));

    if (!m1 || !m2) return;

    NSString *key = SwapKey(className, method1, method2, isClassMethod);
    if (swappedMethods[key]) return;

    method_exchangeImplementations(m1, m2);

    swappedMethods[key] = @YES;
}

#pragma mark - 状態確認

BOOL HookManagerIsHooked(NSString *key) {
    return originalIMPs[key] != nil || swappedMethods[key] != nil;
}

NSDictionary *HookManagerGetAllHooks(void) {
    return [originalIMPs copy];
}

#pragma mark - ctor

%ctor {

    originalIMPs   = [NSMutableDictionary new];
    hookTypes      = [NSMutableDictionary new];
    swappedMethods = [NSMutableDictionary new];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:@"ApplyHook" object:nil queue:nil usingBlock:^(NSNotification *note) {

        HookManagerApply(
            note.userInfo[@"class"],
            note.userInfo[@"method"],
            (HookType)[note.userInfo[@"type"] integerValue],
            [note.userInfo[@"isClassMethod"] boolValue]
        );
    }];

    [nc addObserverForName:@"RemoveHook" object:nil queue:nil usingBlock:^(NSNotification *note) {

        HookManagerRemove(
            note.userInfo[@"class"],
            note.userInfo[@"method"],
            [note.userInfo[@"isClassMethod"] boolValue]
        );
    }];

    [nc addObserverForName:@"SwapMethods" object:nil queue:nil usingBlock:^(NSNotification *note) {

        HookManagerSwapMethods(
            note.userInfo[@"class"],
            note.userInfo[@"method1"],
            note.userInfo[@"method2"],
            [note.userInfo[@"isClassMethod"] boolValue]
        );
    }];

    [nc addObserverForName:@"MethodAutoStopped" object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSString *key = note.userInfo[@"method"];
        NSString *className = nil;
        NSString *methodName = nil;
        BOOL isClassMethod = NO;
        if (!ParseHookKey(key, &className, &methodName, &isClassMethod)) return;

        NSString *fullKey = HookKey(className, methodName, isClassMethod);
        if (!originalIMPs[fullKey]) return;

        HookManagerRemove(className, methodName, isClassMethod);
        NSLog(@"[Monitor] auto-unhooked %@ at count=%@", key, note.userInfo[@"count"]);
    }];

    [nc addObserverForName:@"MethodAutoSwap" object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSString *key = note.userInfo[@"method"];
        NSString *target = note.userInfo[@"targetMethod"];
        if (target.length == 0) return;

        NSString *className = nil;
        NSString *methodName = nil;
        BOOL isClassMethod = NO;
        if (!ParseHookKey(key, &className, &methodName, &isClassMethod)) return;

        HookManagerSwapMethods(className, methodName, target, isClassMethod);
        NSLog(@"[Monitor] auto-swapped %@ <-> %@ at count=%@", methodName, target, note.userInfo[@"count"]);
    }];

    [nc addObserverForName:@"MethodAutoDisable" object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSString *key = note.userInfo[@"method"];
        NSString *className = nil;
        NSString *methodName = nil;
        BOOL isClassMethod = NO;
        if (!ParseHookKey(key, &className, &methodName, &isClassMethod)) return;

        NSString *fullKey = HookKey(className, methodName, isClassMethod);
        if (!originalIMPs[fullKey]) {
            HookManagerApply(className, methodName, HookTypeDisable, isClassMethod);
            return;
        }

        Class cls = GetTargetClass(className, isClassMethod);
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(methodName));
        if (!method) return;
        IMP disabled = GetReplacementIMP(method_getTypeEncoding(method), HookTypeDisable);
        method_setImplementation(method, disabled);
        hookTypes[fullKey] = @(HookTypeDisable);
        NSLog(@"[Monitor] auto-disabled %@ at count=%@", key, note.userInfo[@"count"]);
    }];
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    %orig;
    NSString *key = HookKey(@"UIViewController", NSStringFromSelector(_cmd), NO);
    if (ShouldBlockKey(key)) return;
    TrackExecutionWithMeta(key, start, memBefore, self, animated ? @"animated=YES" : @"animated=NO", @"void", NO);
}

%end

%hook UIView

- (void)setFrame:(CGRect)frame {
    NSString *key = HookKey(@"UIView", NSStringFromSelector(_cmd), NO);
    if (ShouldBlockKey(key)) {
        uint64_t memBefore = CurrentResidentBytes();
        TrackExecutionWithMeta(key,
                               CFAbsoluteTimeGetCurrent(),
                               memBefore,
                               self,
                               [NSString stringWithFormat:@"frame=%@", NSStringFromCGRect(frame)],
                               @"BLOCKED:void",
                               YES);
        return;
    }

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    uint64_t memBefore = CurrentResidentBytes();
    %orig;
    TrackExecutionWithMeta(key,
                           start,
                           memBefore,
                           self,
                           [NSString stringWithFormat:@"frame=%@", NSStringFromCGRect(frame)],
                           @"void",
                           NO);
}

%end
