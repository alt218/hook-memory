#import "HookManager.h"
#import <objc/runtime.h>

static NSMutableDictionary *hookedMethods;
static NSMutableDictionary *originalIMPs;

#pragma mark - ダミーIMP

static id returnYES(id self, SEL _cmd) { return @YES; }
static id returnNO(id self, SEL _cmd) { return @NO; }
static id returnNil(id self, SEL _cmd) { return nil; }
static void returnVoid(id self, SEL _cmd) {}

#pragma mark - 初期化

__attribute__((constructor))
static void HookManagerInit() {
    hookedMethods = [NSMutableDictionary new];
    originalIMPs = [NSMutableDictionary new];
}

#pragma mark - 状態確認

BOOL HookManagerIsHooked(NSString *key) {
    return hookedMethods[key] != nil;
}

NSDictionary *HookManagerGetAllHooks(void) {
    return hookedMethods;
}

#pragma mark - IMP生成

IMP GetIMP(HookType type, const char *types) {

    if (types[0] == 'v') return (IMP)returnVoid;

    switch (type) {
        case HookTypeReturnYES: return (IMP)returnYES;
        case HookTypeReturnNO:  return (IMP)returnNO;
        case HookTypeReturnNil: return (IMP)returnNil;
        default: return (IMP)returnNil;
    }
}

#pragma mark - Hook適用

void HookManagerApply(NSString *className, NSString *methodName, HookType type) {

    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(methodName);

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    NSString *key = [NSString stringWithFormat:@"%@::%@", className, methodName];

    if (hookedMethods[key]) return;

    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    originalIMPs[key] = [NSValue valueWithPointer:(const void *)original];

    IMP newIMP = GetIMP(type, types);
    method_setImplementation(method, newIMP);

    hookedMethods[key] = @(type);

    NSLog(@"✅ Hook applied: %@", key);
}
