#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, HookType) {
    HookTypeDisable = 0,
    HookTypeReturnYES,
    HookTypeReturnNO,
    HookTypeReturnNil,
    HookTypeSwap
};

BOOL HookManagerIsHooked(NSString *key);
NSDictionary *HookManagerGetAllHooks(void);
void HookManagerSwapMethods(NSString *className,NSString *method1,NSString *method2,BOOL isClassMethod);
void HookManagerApply(NSString *className, NSString *methodName, HookType type, BOOL isClassMethod);
void HookManagerRemove(NSString *className, NSString *methodName, BOOL isClassMethod);
