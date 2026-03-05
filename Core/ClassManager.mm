// Core/ClassManager.mm
#import "ClassManager.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>


NSArray<NSString *> *GetClassesForImage(NSString *imagePath) {

    unsigned int classCount = 0;

    const char **classNames =
    objc_copyClassNamesForImage([imagePath UTF8String], &classCount);

    NSMutableArray *result = [NSMutableArray array];

    for (unsigned int i = 0; i < classCount; i++) {
        [result addObject:@(classNames[i])];
    }

    free(classNames);

    return result;
}

NSArray<NSString *> *GetMethodsForClass(NSString *className) {

    Class cls = NSClassFromString(className);
    if (!cls) return @[];

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);

    NSMutableArray *result = [NSMutableArray array];

    for (unsigned int i = 0; i < methodCount; i++) {

        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);

        [result addObject:name];
    }

    free(methods);

    return result;
}


NSArray<NSString *> *GetLoadedDylibs(void) {
    NSMutableArray<NSString *> *arr = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) [arr addObject:[NSString stringWithUTF8String:name]];
    }
    return arr;
}
