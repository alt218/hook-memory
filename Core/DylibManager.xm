#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

NSArray *GetLoadedDylibs() {

    NSMutableArray *list = [NSMutableArray array];

    uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {

        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        NSString *path = [NSString stringWithUTF8String:name];
        [list addObject:path];
    }

    return list;
}
