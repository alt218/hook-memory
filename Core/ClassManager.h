// Core/ClassManager.h
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSArray<NSString *> *GetClassesForImage(NSString *imageName);
NSArray<NSString *> *GetLoadedDylibs(void);

NSArray<NSString *> *GetClassesForImage(NSString *imagePath);
NSArray<NSString *> *GetMethodsForClass(NSString *className);


#ifdef __cplusplus
}
#endif
