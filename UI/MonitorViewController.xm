#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <limits.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <unistd.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ClassManager.h"
#import "ClassListController.h"
#import "ExecutionTracker.h"
#import "ThemeManager.h"
#import "PTFakeMetaTouch.h"

static NSString *const kPrefRefreshInterval = @"monitor_refresh_interval";
static NSString *const kPrefBatterySaver = @"monitor_battery_saver";
static NSString *const kPrefCompactMode = @"monitor_compact_mode";
static NSString *const kPrefWriteConfirm = @"monitor_confirm_write";
static NSString *const kPrefBackgroundBinary = @"monitor_bg_binary";

static NSUserDefaults *MonitorUD(void) {
    return [NSUserDefaults standardUserDefaults];
}

static void ApplyThemeToCell(UITableViewCell *cell) {
    cell.backgroundColor = ThemeBackgroundColor();
    cell.textLabel.textColor = ThemePrimaryTextColor();
    cell.detailTextLabel.textColor = ThemeSecondaryTextColor();
}

static double MonitorRefreshInterval(void) {
    double v = [MonitorUD() doubleForKey:kPrefRefreshInterval];
    if (v <= 0) v = 1.0;
    return [MonitorUD() boolForKey:kPrefBatterySaver] ? MAX(2.0, v) : v;
}

static BOOL MonitorCompactMode(void) {
    return [MonitorUD() boolForKey:kPrefCompactMode];
}

static BOOL MonitorBackgroundBinary(void) {
    return [MonitorUD() boolForKey:kPrefBackgroundBinary];
}

static NSString *HexMemoryHash(const void *bytes, size_t length) {
    if (!bytes || length == 0) return nil;
    const uint8_t *p = (const uint8_t *)bytes;
    uint64_t hash = 1469598103934665603ULL; // FNV-1a 64-bit
    for (size_t i = 0; i < length; i++) {
        hash ^= p[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
}

static NSString *TextSegmentHashForImageIndex(uint32_t imageIndex) {
    const struct mach_header *header = _dyld_get_image_header(imageIndex);
    if (!header) return nil;

    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
    BOOL is64 = (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64);

    const uint8_t *cursor = (const uint8_t *)header + (is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
    uint32_t ncmds = header->ncmds;

    for (uint32_t i = 0; i < ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (is64 && lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                const void *textPtr = (const void *)(uintptr_t)(seg->vmaddr + slide);
                size_t textSize = (size_t)seg->vmsize;
                return HexMemoryHash(textPtr, textSize);
            }
        } else if (!is64 && lc->cmd == LC_SEGMENT) {
            const struct segment_command *seg = (const struct segment_command *)cursor;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                const void *textPtr = (const void *)(uintptr_t)(seg->vmaddr + slide);
                size_t textSize = (size_t)seg->vmsize;
                return HexMemoryHash(textPtr, textSize);
            }
        }
        cursor += lc->cmdsize;
    }
    return nil;
}

static NSString *NowTimeString(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return [formatter stringFromDate:[NSDate date]];
}

typedef NS_ENUM(NSInteger, TxtPatchBaseMode) {
    TxtPatchBaseModeMain = 0,
    TxtPatchBaseModeMinAddress,
    TxtPatchBaseModeModule
};

static NSMutableDictionary *TxtPatchStateCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static BOOL MonitorWriteBytesAt(vm_address_t address, const void *buffer, size_t size) {
    if (size == 0) return NO;
    kern_return_t kr = vm_write(mach_task_self(),
                                address,
                                (vm_offset_t)buffer,
                                (mach_msg_type_number_t)size);
    return (kr == KERN_SUCCESS);
}

static BOOL ParseSignedValue(NSString *token, long long *outValue) {
    NSString *s = [[token ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([s hasPrefix:@"+"]) s = [s substringFromIndex:1];
    if (s.length == 0) return NO;
    if (outValue) *outValue = strtoll(s.UTF8String, NULL, 0);
    return YES;
}

static NSData *PackedIntValue(long long value) {
    if (value >= INT32_MIN && value <= INT32_MAX) {
        int32_t v = (int32_t)value;
        return [NSData dataWithBytes:&v length:sizeof(v)];
    }
    int64_t v = (int64_t)value;
    return [NSData dataWithBytes:&v length:sizeof(v)];
}

static unsigned long long MainExecutableBaseAddress(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) continue;
        if (header->filetype == MH_EXECUTE) {
            return (unsigned long long)(uintptr_t)header;
        }
    }
    return 0;
}

static unsigned long long MinLoadedImageBaseAddress(void) {
    uint32_t count = _dyld_image_count();
    unsigned long long minBase = ULLONG_MAX;
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) continue;
        unsigned long long b = (unsigned long long)(uintptr_t)header;
        if (b > 0 && b < minBase) minBase = b;
    }
    return minBase == ULLONG_MAX ? 0 : minBase;
}

static NSArray<NSString *> *LoadedImagePaths(void) {
    uint32_t count = _dyld_image_count();
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (path.length) [items addObject:path];
    }
    return items;
}

static unsigned long long BaseAddressForModulePath(NSString *modulePath) {
    if (modulePath.length == 0) return 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (![path isEqualToString:modulePath]) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) return 0;
        return (unsigned long long)(uintptr_t)header;
    }
    return 0;
}

static unsigned long long TxtPatchResolveBaseAddress(TxtPatchBaseMode mode, NSString *modulePath) {
    if (mode == TxtPatchBaseModeMain) return MainExecutableBaseAddress();
    if (mode == TxtPatchBaseModeMinAddress) return MinLoadedImageBaseAddress();
    unsigned long long moduleBase = BaseAddressForModulePath(modulePath);
    return moduleBase > 0 ? moduleBase : MainExecutableBaseAddress();
}

static void ApplyTxtPatchRuntimeState(void) {
    NSDictionary *runtime = TxtPatchStateCache()[@"txt_patch_runtime"];
    if (![runtime isKindOfClass:[NSDictionary class]]) return;
    NSArray<NSDictionary *> *groups = runtime[@"groups"];
    NSArray<NSNumber *> *enabled = runtime[@"enabledRows"];
    TxtPatchBaseMode mode = (TxtPatchBaseMode)[runtime[@"baseMode"] integerValue];
    NSString *modulePath = runtime[@"selectedModulePath"] ?: @"";
    NSString *manualValue = runtime[@"manualValue"] ?: @"";
    if (![groups isKindOfClass:[NSArray class]] || ![enabled isKindOfClass:[NSArray class]]) return;

    NSMutableSet<NSNumber *> *enabledSet = [NSMutableSet setWithArray:enabled];
    unsigned long long base = TxtPatchResolveBaseAddress(mode, modulePath);
    if (base == 0) return;

    for (NSUInteger i = 0; i < groups.count; i++) {
        if (![enabledSet containsObject:@(i)]) continue;
        NSDictionary *group = groups[i];
        NSArray<NSDictionary *> *lines = group[@"lines"];
        if (![lines isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *line in lines) {
            NSString *offsetToken = line[@"offset"] ?: @"0";
            NSString *valueToken = line[@"value"] ?: @"0";
            long long offset = 0;
            long long value = 0;
            if (!ParseSignedValue(offsetToken, &offset)) continue;
            if ([[valueToken lowercaseString] isEqualToString:@"val"]) {
                if (!ParseSignedValue(manualValue, &value)) continue;
            } else if (!ParseSignedValue(valueToken, &value)) {
                continue;
            }
            unsigned long long target = (unsigned long long)((long long)base + offset);
            NSData *packed = PackedIntValue(value);
            MonitorWriteBytesAt((vm_address_t)target, packed.bytes, packed.length);
        }
    }
}

static void StartTxtPatchGlobalRunner(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer * _Nonnull timer) {
            ApplyTxtPatchRuntimeState();
        }];
    });
}

static void CallVoidObj(id target, NSString *selName, id arg) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

static void CallVoidBOOL(id target, NSString *selName, BOOL value) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
}

static void CallVoidCGPoint(id target, NSString *selName, CGPoint point) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:target];
    [inv setArgument:&point atIndex:2];
    [inv invoke];
}

static void CallVoidCGPointBOOL(id target, NSString *selName, CGPoint point, BOOL flag) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:target];
    [inv setArgument:&point atIndex:2];
    [inv setArgument:&flag atIndex:3];
    [inv invoke];
}

static void CallVoidInteger(id target, NSString *selName, NSInteger value) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, sel, value);
}

static void CallVoidDouble(id target, NSString *selName, double value) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(target, sel, value);
}

static UIWindow *BestInteractiveWindow(UIWindow *preferred) {
    if (preferred && !preferred.hidden && preferred.alpha > 0.01) return preferred;
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive &&
                ws.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            [windows addObjectsFromArray:ws.windows ?: @[]];
        }
    }
    if (windows.count == 0 && preferred) {
        [windows addObject:preferred];
    }
    for (NSInteger i = (NSInteger)windows.count - 1; i >= 0; i--) {
        UIWindow *w = windows[(NSUInteger)i];
        if (w.hidden || w.alpha <= 0.01 || !w.userInteractionEnabled) continue;
        if (w.windowLevel > UIWindowLevelStatusBar + 1) continue;
        return w;
    }
    return preferred;
}

static id BuildTouchEventWithTouch(id touch) {
    Class eventCls = NSClassFromString(@"UIEvent");
    if (!eventCls) return nil;
    id event = nil;
    SEL touchesSel = NSSelectorFromString(@"_touchesEvent");
    if ([eventCls respondsToSelector:touchesSel]) {
        event = ((id (*)(id, SEL))objc_msgSend)(eventCls, touchesSel);
    }
    if (!event) return nil;

    SEL add2Sel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
    if ([event respondsToSelector:add2Sel]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, add2Sel, touch, NO);
        return event;
    }

    SEL add1Sel = NSSelectorFromString(@"_addTouch:");
    if ([event respondsToSelector:add1Sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(event, add1Sel, touch);
        return event;
    }
    return nil;
}

static BOOL InjectSyntheticTapAtScreenPoint(CGPoint pScreen, UIWindow *preferredWindow) {
    UIWindow *window = BestInteractiveWindow(preferredWindow);
    if (!window) return NO;
    CGPoint pWin = [window convertPoint:pScreen fromWindow:nil];
    UIView *targetView = [window hitTest:pWin withEvent:nil];
    if (!targetView) return NO;

    Class touchCls = NSClassFromString(@"UITouch");
    if (!touchCls) return NO;
    id touch = [[touchCls alloc] init];
    if (!touch) return NO;

    CallVoidObj(touch, @"setWindow:", window);
    CallVoidObj(touch, @"setView:", targetView);
    CallVoidInteger(touch, @"setTapCount:", 1);
    CallVoidCGPointBOOL(touch, @"_setLocationInWindow:resetPrevious:", pWin, YES);
    CallVoidCGPoint(touch, @"setLocationInWindow:", pWin);
    CallVoidBOOL(touch, @"_setIsFirstTouchForView:", YES);
    CallVoidDouble(touch, @"setTimestamp:", CACurrentMediaTime());

    CallVoidInteger(touch, @"setPhase:", UITouchPhaseBegan);
    id beganEvent = BuildTouchEventWithTouch(touch);
    if (!beganEvent) return NO;
    [UIApplication.sharedApplication sendEvent:beganEvent];

    CallVoidDouble(touch, @"setTimestamp:", CACurrentMediaTime() + 0.008);
    CallVoidInteger(touch, @"setPhase:", UITouchPhaseEnded);
    id endEvent = BuildTouchEventWithTouch(touch);
    if (!endEvent) return NO;
    [UIApplication.sharedApplication sendEvent:endEvent];

    return YES;
}

static BOOL DispatchDirectResponderTapAtScreenPoint(CGPoint pScreen, UIWindow *preferredWindow) {
    UIWindow *window = BestInteractiveWindow(preferredWindow);
    if (!window) return NO;
    CGPoint pWin = [window convertPoint:pScreen fromWindow:nil];
    UIView *targetView = [window hitTest:pWin withEvent:nil];
    if (!targetView) return NO;

    Class touchCls = NSClassFromString(@"UITouch");
    if (!touchCls) return NO;
    id touch = [[touchCls alloc] init];
    if (!touch) return NO;

    CallVoidObj(touch, @"setWindow:", window);
    CallVoidObj(touch, @"setView:", targetView);
    CallVoidInteger(touch, @"setTapCount:", 1);
    CallVoidCGPointBOOL(touch, @"_setLocationInWindow:resetPrevious:", pWin, YES);
    CallVoidCGPoint(touch, @"setLocationInWindow:", pWin);
    CallVoidDouble(touch, @"setTimestamp:", CACurrentMediaTime());

    SEL beganSel = @selector(touchesBegan:withEvent:);
    SEL endedSel = @selector(touchesEnded:withEvent:);
    if (![targetView respondsToSelector:beganSel] || ![targetView respondsToSelector:endedSel]) return NO;
    NSSet *touches = [NSSet setWithObject:touch];

    CallVoidInteger(touch, @"setPhase:", UITouchPhaseBegan);
    ((void (*)(id, SEL, id, id))objc_msgSend)(targetView, beganSel, touches, nil);

    CallVoidDouble(touch, @"setTimestamp:", CACurrentMediaTime() + 0.008);
    CallVoidInteger(touch, @"setPhase:", UITouchPhaseEnded);
    ((void (*)(id, SEL, id, id))objc_msgSend)(targetView, endedSel, touches, nil);
    return YES;
}

typedef CFTypeRef IOHIDEventRef;
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFn)(CFAllocatorRef allocator,
                                                           uint64_t timeStamp,
                                                           uint32_t transducerType,
                                                           uint32_t index,
                                                           uint32_t identity,
                                                           uint32_t eventMask,
                                                           uint32_t buttonMask,
                                                           CGFloat x,
                                                           CGFloat y,
                                                           CGFloat z,
                                                           CGFloat tipPressure,
                                                           CGFloat twist,
                                                           Boolean range,
                                                           Boolean touch,
                                                           CFOptionFlags options);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFn)(CFAllocatorRef allocator,
                                                                 uint64_t timeStamp,
                                                                 uint32_t index,
                                                                 uint32_t identity,
                                                                 uint32_t eventMask,
                                                                 uint32_t buttonMask,
                                                                 CGFloat x,
                                                                 CGFloat y,
                                                                 CGFloat z,
                                                                 CGFloat tipPressure,
                                                                 CGFloat twist,
                                                                 Boolean range,
                                                                 Boolean touch,
                                                                 CFOptionFlags options);
typedef void (*IOHIDEventAppendEventFn)(IOHIDEventRef parent, IOHIDEventRef child, CFOptionFlags options);
typedef void (*BKSHIDEventSetDigitizerInfoFn)(IOHIDEventRef event,
                                              uint32_t contextID,
                                              Boolean systemGestureIsPossible,
                                              Boolean isSystemGestureStateChangeEvent,
                                              CFStringRef displayUUID,
                                              CFTimeInterval initialTouchTimestamp,
                                              float maxForce);
typedef void (*BKSHIDEventSendToFocusedProcessFn)(IOHIDEventRef event);
typedef void (*BKSHIDEventSendToProcessFn)(IOHIDEventRef event, int pid);

static BOOL EnqueueHIDEventOnApplication(UIApplication *app, IOHIDEventRef event) {
    if (!app || !event) return NO;
    SEL s1 = NSSelectorFromString(@"_enqueueHIDEvent:");
    if ([app respondsToSelector:s1]) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, s1, event);
        return YES;
    }
    SEL s2 = NSSelectorFromString(@"_enqueueHIDEvent:sender:");
    if ([app respondsToSelector:s2]) {
        ((void (*)(id, SEL, IOHIDEventRef, id))objc_msgSend)(app, s2, event, nil);
        return YES;
    }
    SEL s3 = NSSelectorFromString(@"_enqueueHIDEvent:forScene:");
    if ([app respondsToSelector:s3]) {
        id scene = app.connectedScenes.anyObject;
        ((void (*)(id, SEL, IOHIDEventRef, id))objc_msgSend)(app, s3, event, scene);
        return YES;
    }
    return NO;
}

static BOOL InjectIOHIDTapAtScreenPoint(CGPoint pScreen, UIWindow *preferredWindow) {
    static IOHIDEventCreateDigitizerEventFn pCreateDigitizerEvent = NULL;
    static IOHIDEventCreateDigitizerFingerEventFn pCreateFingerEvent = NULL;
    static IOHIDEventAppendEventFn pAppendEvent = NULL;
    static BKSHIDEventSetDigitizerInfoFn pSetDigitizerInfo = NULL;
    static BKSHIDEventSendToFocusedProcessFn pSendToFocusedProcess = NULL;
    static BKSHIDEventSendToProcessFn pSendToProcess = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (ioKit) {
            pCreateDigitizerEvent = (IOHIDEventCreateDigitizerEventFn)dlsym(ioKit, "IOHIDEventCreateDigitizerEvent");
            pCreateFingerEvent = (IOHIDEventCreateDigitizerFingerEventFn)dlsym(ioKit, "IOHIDEventCreateDigitizerFingerEvent");
            pAppendEvent = (IOHIDEventAppendEventFn)dlsym(ioKit, "IOHIDEventAppendEvent");
        }
        if (bbs) {
            pSetDigitizerInfo = (BKSHIDEventSetDigitizerInfoFn)dlsym(bbs, "BKSHIDEventSetDigitizerInfo");
            pSendToFocusedProcess = (BKSHIDEventSendToFocusedProcessFn)dlsym(bbs, "BKSHIDEventSendToFocusedProcess");
            pSendToProcess = (BKSHIDEventSendToProcessFn)dlsym(bbs, "BKSHIDEventSendToProcess");
        }
    });

    UIApplication *app = UIApplication.sharedApplication;
    if (!pCreateDigitizerEvent || !pCreateFingerEvent || !pAppendEvent) {
        return NO;
    }

    UIWindow *window = BestInteractiveWindow(preferredWindow);
    if (!window) return NO;

    CGPoint pWin = [window convertPoint:pScreen fromWindow:nil];
    CGRect winBounds = window.bounds;
    CGFloat rawX = pWin.x;
    CGFloat rawY = pWin.y;
    rawX = MAX(CGRectGetMinX(winBounds), MIN(CGRectGetMaxX(winBounds), rawX));
    rawY = MAX(CGRectGetMinY(winBounds), MIN(CGRectGetMaxY(winBounds), rawY));
    CGFloat w = MAX(1.0, CGRectGetWidth(winBounds));
    CGFloat h = MAX(1.0, CGRectGetHeight(winBounds));
    CGFloat normX = MIN(1.0, MAX(0.0, rawX / w));
    CGFloat normY = MIN(1.0, MAX(0.0, rawY / h));

    uint32_t contextID = 0;
    SEL contextSel = NSSelectorFromString(@"_contextId");
    if ([window respondsToSelector:contextSel]) {
        contextID = (uint32_t)((NSInteger)((NSInteger (*)(id, SEL))objc_msgSend)(window, contextSel));
    } else {
        @try {
            id v = [window valueForKey:@"_contextId"];
            if ([v respondsToSelector:@selector(unsignedIntValue)]) contextID = [v unsignedIntValue];
        } @catch (__unused NSException *e) {}
    }

    const uint32_t kTransducerHand = 3;
    const uint32_t kEventMaskRange = 1 << 0;
    const uint32_t kEventMaskTouch = 1 << 1;
    const uint32_t kEventMaskPosition = 1 << 2;
    uint64_t t0 = mach_absolute_time();

    BOOL (^sendOneTap)(CGFloat, CGFloat) = ^BOOL(CGFloat x, CGFloat y) {
        IOHIDEventRef handDown = pCreateDigitizerEvent(kCFAllocatorDefault, t0, kTransducerHand, 0, 0,
                                                       (kEventMaskRange | kEventMaskTouch | kEventMaskPosition),
                                                       0, x, y, 0, 0, 0, true, true, 0);
        IOHIDEventRef fingerDown = pCreateFingerEvent(kCFAllocatorDefault, t0, 1, 2,
                                                      (kEventMaskRange | kEventMaskTouch | kEventMaskPosition),
                                                      0, x, y, 0, 0, 0, true, true, 0);
        if (!handDown || !fingerDown) {
            if (handDown) CFRelease(handDown);
            if (fingerDown) CFRelease(fingerDown);
            return NO;
        }
        pAppendEvent(handDown, fingerDown, 0);
        if (pSetDigitizerInfo) pSetDigitizerInfo(handDown, contextID, true, false, NULL, CACurrentMediaTime(), 0);
        BOOL sent = NO;
        if (pSendToFocusedProcess) { pSendToFocusedProcess(handDown); sent = YES; }
        else if (pSendToProcess) { pSendToProcess(handDown, getpid()); sent = YES; }
        else { sent = EnqueueHIDEventOnApplication(app, handDown); }
        CFRelease(handDown);
        CFRelease(fingerDown);
        if (!sent) return NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.008 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            uint64_t tm = mach_absolute_time();
            IOHIDEventRef handMove = pCreateDigitizerEvent(kCFAllocatorDefault, tm, kTransducerHand, 0, 0,
                                                           (kEventMaskRange | kEventMaskTouch | kEventMaskPosition),
                                                           0, x, y, 0, 0, 0, true, true, 0);
            IOHIDEventRef fingerMove = pCreateFingerEvent(kCFAllocatorDefault, tm, 1, 2,
                                                          (kEventMaskRange | kEventMaskTouch | kEventMaskPosition),
                                                          0, x, y, 0, 0, 0, true, true, 0);
            if (handMove && fingerMove) {
                pAppendEvent(handMove, fingerMove, 0);
                if (pSetDigitizerInfo) pSetDigitizerInfo(handMove, contextID, true, false, NULL, CACurrentMediaTime(), 0);
                if (pSendToFocusedProcess) pSendToFocusedProcess(handMove);
                else if (pSendToProcess) pSendToProcess(handMove, getpid());
                else EnqueueHIDEventOnApplication(app, handMove);
            }
            if (handMove) CFRelease(handMove);
            if (fingerMove) CFRelease(fingerMove);
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            uint64_t t1 = mach_absolute_time();
            IOHIDEventRef handUp = pCreateDigitizerEvent(kCFAllocatorDefault, t1, kTransducerHand, 0, 0,
                                                         (kEventMaskRange | kEventMaskPosition), 0, x, y, 0, 0, 0, false, false, 0);
            IOHIDEventRef fingerUp = pCreateFingerEvent(kCFAllocatorDefault, t1, 1, 2,
                                                        (kEventMaskRange | kEventMaskPosition), 0, x, y, 0, 0, 0, false, false, 0);
            if (handUp && fingerUp) {
                pAppendEvent(handUp, fingerUp, 0);
                if (pSetDigitizerInfo) pSetDigitizerInfo(handUp, contextID, true, false, NULL, CACurrentMediaTime(), 0);
                if (pSendToFocusedProcess) pSendToFocusedProcess(handUp);
                else if (pSendToProcess) pSendToProcess(handUp, getpid());
                else EnqueueHIDEventOnApplication(app, handUp);
            }
            if (handUp) CFRelease(handUp);
            if (fingerUp) CFRelease(fingerUp);
        });
        return YES;
    };

    BOOL sentRaw = sendOneTap(rawX, rawY);
    BOOL sentNorm = sendOneTap(normX, normY);
    return sentRaw || sentNorm;
}

static void PresentMonitorMenuFromActiveWindow(void) {
    UIWindow *window = nil;
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) {
                window = w;
                break;
            }
        }
        if (!window && ws.windows.count > 0) window = ws.windows.firstObject;
        if (window) break;
    }
    if (!window) return;
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    UIViewController *vc = [NSClassFromString(@"MonitorViewController") new];
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationOverFullScreen;
    nav.view.backgroundColor = UIColor.clearColor;
    nav.navigationBar.translucent = YES;
    [root presentViewController:nav animated:YES completion:nil];
}

static UIViewController *TopMostViewControllerFromActiveWindow(void) {
    UIWindow *window = nil;
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) {
                window = w;
                break;
            }
        }
        if (!window && ws.windows.count > 0) window = ws.windows.firstObject;
        if (window) break;
    }
    if (!window) return nil;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static BOOL InjectViaPTFakeTouch(CGPoint pScreen, UIWindow *preferredWindow) {
    [PTFakeMetaTouch setPreferredWindow:preferredWindow];
    CGPoint p = pScreen;
    if (preferredWindow) {
        p = [preferredWindow convertPoint:pScreen fromWindow:nil];
    }
    NSInteger pointId = [PTFakeMetaTouch getAvailablePointId];
    if (pointId <= 0) return NO;
    NSInteger beganPointId = [PTFakeMetaTouch fakeTouchId:pointId AtPoint:p withTouchPhase:UITouchPhaseBegan];
    BOOL began = (beganPointId > 0);
    if (!began) return NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.010 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [PTFakeMetaTouch fakeTouchId:pointId AtPoint:p withTouchPhase:UITouchPhaseMoved];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.026 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [PTFakeMetaTouch fakeTouchId:pointId AtPoint:p withTouchPhase:UITouchPhaseEnded];
    });
    return YES;
}

@interface HookDylibListController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSString *> *allDylibPaths;
@property(nonatomic,strong) NSArray<NSString *> *filteredDylibPaths;
@property(nonatomic,strong) UISearchController *searchController;
@end

@implementation HookDylibListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"HOOK";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search dylib...";
    self.navigationItem.searchController = self.searchController;

    [self reloadDylibs];
}

- (void)reloadDylibs {
    NSArray<NSString *> *loaded = GetLoadedDylibs();
    NSMutableArray<NSString *> *dylibs = [NSMutableArray array];
    for (NSString *path in loaded) {
        if ([path.lastPathComponent hasSuffix:@".dylib"]) {
            [dylibs addObject:path];
        }
    }
    self.allDylibPaths = dylibs;
    self.filteredDylibPaths = dylibs;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text.lowercaseString ?: @"";
    if (text.length == 0) {
        self.filteredDylibPaths = self.allDylibPaths;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSString *path, NSDictionary *_) {
            return [path.lastPathComponent.lowercaseString containsString:text];
        }];
        self.filteredDylibPaths = [self.allDylibPaths filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredDylibPaths.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HookCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HookCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSString *path = self.filteredDylibPaths[indexPath.row];
    cell.textLabel.text = path.lastPathComponent;
    cell.detailTextLabel.text = path;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = self.filteredDylibPaths[indexPath.row];
    ClassListController *vc = [[ClassListController alloc] initWithImage:path];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

@interface BinaryMonitorController : UIViewController
- (instancetype)initWithBinaryPath:(NSString *)binaryPath imageIndex:(uint32_t)imageIndex;
@end

@interface BinaryMonitorController ()
@property(nonatomic,strong) NSString *binaryPath;
@property(nonatomic) uint32_t imageIndex;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UITextView *logView;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSString *baselineHash;
@property(nonatomic,strong) NSString *previousHash;
@property(nonatomic) BOOL alerted;
@property(nonatomic) BOOL diffOnly;
@end

@implementation BinaryMonitorController

- (instancetype)initWithBinaryPath:(NSString *)binaryPath imageIndex:(uint32_t)imageIndex {
    self = [super init];
    if (self) {
        _binaryPath = binaryPath;
        _imageIndex = imageIndex;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.binaryPath.lastPathComponent;
    self.view.backgroundColor = UIColor.blackColor;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, self.view.bounds.size.width - 32, 70)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = UIColor.systemGreenColor;
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, 180, self.view.bounds.size.width - 24, self.view.bounds.size.height - 200)];
    self.logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.logView.backgroundColor = UIColor.blackColor;
    self.logView.textColor = UIColor.greenColor;
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:self.logView];
    self.logView.hidden = MonitorCompactMode();

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"差分"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleDiffOnly)],
        [[UIBarButtonItem alloc] initWithTitle:@"BG"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleBackgroundMonitor)]
    ];

    self.baselineHash = TextSegmentHashForImageIndex(self.imageIndex);
    self.previousHash = self.baselineHash;
    if (!self.baselineHash) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"監視開始失敗:hashを取得できません";
        return;
    }

    self.statusLabel.text = @"JIT監視中 \nStatus: OK";
    [self appendLog:[NSString stringWithFormat:@"[%@] monitor started", NowTimeString()]];
    [self appendLog:[NSString stringWithFormat:@"baseline: %@", self.baselineHash]];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:MonitorRefreshInterval()
                                                  target:self
                                                selector:@selector(checkIntegrity)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!MonitorBackgroundBinary()) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

- (void)appendLog:(NSString *)line {
    NSString *existing = self.logView.text ?: @"";
    NSString *next = existing.length ? [existing stringByAppendingFormat:@"\n%@", line] : line;
    self.logView.text = next;
    NSRange bottom = NSMakeRange(next.length, 0);
    [self.logView scrollRangeToVisible:bottom];
}

- (void)checkIntegrity {
    NSString *current = TextSegmentHashForImageIndex(self.imageIndex);
    if (!current) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"Status: ERROR (__TEXT read failed)";
        [self appendLog:[NSString stringWithFormat:@"[%@] hash read failed", NowTimeString()]];
        return;
    }

    if (![current isEqualToString:self.baselineHash]) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"Status: ALERT (__TEXT changed)";
        if (!self.diffOnly || ![current isEqualToString:self.previousHash]) {
            [self appendLog:[NSString stringWithFormat:@"[%@] ALERT: hash mismatch", NowTimeString()]];
            [self appendLog:[NSString stringWithFormat:@"current: %@", current]];
        }

        if (!self.alerted) {
            self.alerted = YES;
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"不正変更を検知"
                                                message:@"JIT/パッチの可能性があります。"
                                         preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else {
        self.statusLabel.textColor = UIColor.systemGreenColor;
        self.statusLabel.text = [NSString stringWithFormat:@"JIT監視中\nStatus: OK (%@)", NowTimeString()];
    }
    self.previousHash = current;
}

- (void)toggleDiffOnly {
    self.diffOnly = !self.diffOnly;
    [[ExecutionTracker shared] logSessionEvent:@"binary" message:(self.diffOnly ? @"diff only on" : @"diff only off")];
}

- (void)toggleBackgroundMonitor {
    BOOL on = !MonitorBackgroundBinary();
    [MonitorUD() setBool:on forKey:kPrefBackgroundBinary];
    [[ExecutionTracker shared] logSessionEvent:@"binary" message:(on ? @"background monitor on" : @"background monitor off")];
}

@end

@interface BinaryListController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSDictionary *> *binaries;
@property(nonatomic,strong) NSArray<NSDictionary *> *filteredBinaries;
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,strong) NSMutableSet<NSString *> *favorites;
@end

@implementation BinaryListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"バイナリ監視";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.favorites = [NSMutableSet setWithArray:[MonitorUD() arrayForKey:@"binary_favorites"] ?: @[]];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"binary filter";
    self.navigationItem.searchController = self.searchController;
    [self loadMainBinaries];
}

- (void)loadMainBinaries {
    uint32_t count = _dyld_image_count();
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!header || !name) continue;
        if (header->filetype != MH_EXECUTE) continue;

        NSString *path = [NSString stringWithUTF8String:name];
        if ([seen containsObject:path]) continue;
        [seen addObject:path];

        [result addObject:@{
            @"name": path.lastPathComponent ?: @"(unknown)",
            @"path": path,
            @"index": @(i)
        }];
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL af = [self.favorites containsObject:a[@"path"]];
        BOOL bf = [self.favorites containsObject:b[@"path"]];
        if (af != bf) return af ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"]];
    }];
    self.binaries = result;
    self.filteredBinaries = result;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = searchController.searchBar.text.lowercaseString ?: @"";
    if (q.length == 0) {
        self.filteredBinaries = self.binaries;
    } else {
        self.filteredBinaries = [self.binaries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *obj, NSDictionary *_) {
            NSString *name = [obj[@"name"] lowercaseString] ?: @"";
            NSString *path = [obj[@"path"] lowercaseString] ?: @"";
            return [name containsString:q] || [path containsString:q];
        }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredBinaries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"BinaryCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"BinaryCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSDictionary *item = self.filteredBinaries[indexPath.row];
    cell.textLabel.text = item[@"name"];
    BOOL fav = [self.favorites containsObject:item[@"path"]];
    cell.detailTextLabel.text = fav ? [NSString stringWithFormat:@"★ %@", item[@"path"]] : item[@"path"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = self.filteredBinaries[indexPath.row];
    BinaryMonitorController *vc =
    [[BinaryMonitorController alloc] initWithBinaryPath:item[@"path"]
                                             imageIndex:[item[@"index"] unsignedIntValue]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.filteredBinaries[indexPath.row];
    NSString *path = item[@"path"];
    BOOL isFav = [self.favorites containsObject:path];
    UIContextualAction *fav =
    [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                            title:(isFav ? @"Unpin" : @"Pin")
                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        if (isFav) [self.favorites removeObject:path];
        else [self.favorites addObject:path];
        [MonitorUD() setObject:self.favorites.allObjects forKey:@"binary_favorites"];
        [[ExecutionTracker shared] logSessionEvent:@"favorite" message:[NSString stringWithFormat:@"%@ %@", isFav ? @"unpin binary" : @"pin binary", path.lastPathComponent ?: @""]];
        [self loadMainBinaries];
        completionHandler(YES);
    }];
    fav.backgroundColor = isFav ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[fav]];
}

@end

@interface MemoryMonitorController : UITableViewController
@property(nonatomic,strong) NSArray<MethodExecutionInfo *> *rows;
@property(nonatomic,strong) NSTimer *refreshTimer;
@end

@implementation MemoryMonitorController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"メモリ監視";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = MonitorCompactMode() ? 50.0 : 72.0;
    self.tableView.tableFooterView = [UIView new];
    [self refreshRows];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:MonitorRefreshInterval()
                                                         target:self
                                                       selector:@selector(refreshRows)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshRows {
    self.rows = [[ExecutionTracker shared] sortedByMemoryDelta];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MemoryCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"MemoryCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    }

    MethodExecutionInfo *info = self.rows[indexPath.row];
    cell.textLabel.text = info.methodName;
    if (MonitorCompactMode()) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"memΔ:%lldB count:%ld",
                                     info.totalMemoryDeltaBytes, (long)info.count];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"retain:%lu avg:%.2f memΔ:%lldB Σ:%lldB objCreate:%lu",
                                     (unsigned long)info.lastRetainCount,
                                     info.averageRetainCount,
                                     info.lastMemoryDeltaBytes,
                                     info.totalMemoryDeltaBytes,
                                     (unsigned long)info.objectCreateCount];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    MethodExecutionInfo *info = self.rows[indexPath.row];
    NSString *msg = [NSString stringWithFormat:@"method: %@\nretain(last): %lu\nretain(avg): %.2f\nmem delta(last): %lld bytes\nmem delta(total): %lld bytes\nobject create count: %lu",
                     info.methodName ?: @"",
                     (unsigned long)info.lastRetainCount,
                     info.averageRetainCount,
                     info.lastMemoryDeltaBytes,
                     info.totalMemoryDeltaBytes,
                     (unsigned long)info.objectCreateCount];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:@"Memory Detail"
                                        message:msg
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface SessionLogController : UITableViewController
@property(nonatomic,strong) NSArray<NSDictionary *> *rows;
@end

@implementation SessionLogController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"セッションログ";
    self.view.backgroundColor = UIColor.blackColor;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = MonitorCompactMode() ? 44.0 : 66.0;
    self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItem =
    [[UIBarButtonItem alloc] initWithTitle:@"更新"
                                     style:UIBarButtonItemStylePlain
                                    target:self
                                    action:@selector(reloadRows)];
    [self reloadRows];
}

- (void)reloadRows {
    self.rows = [[[ExecutionTracker shared] recentSessionEvents] reverseObjectEnumerator].allObjects ?: @[];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SessionCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SessionCell"];
        cell.backgroundColor = UIColor.blackColor;
        cell.textLabel.textColor = UIColor.greenColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    }
    NSDictionary *row = self.rows[indexPath.row];
    NSTimeInterval t = [row[@"time"] doubleValue];
    NSString *msg = row[@"message"] ?: @"";
    NSString *kind = row[@"kind"] ?: @"event";
    cell.textLabel.text = [NSString stringWithFormat:@"[%@] %@", kind, msg];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"unix:%.3f", t];
    return cell;
}

@end

@interface MonitorToolsController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *items;
@end

@implementation MonitorToolsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ツール";
    self.items = @[
        @"前回クラッシュ表示",
        @"クラッシュ情報クリア",
        @"診断テスト実行",
        @"セッションログを開く"
    ];
    self.view.backgroundColor = ThemeBackgroundColor();
    self.tableView.backgroundColor = ThemeBackgroundColor();
    self.tableView.rowHeight = 56.0;
    self.tableView.tableFooterView = [UIView new];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ToolCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ToolCell"];
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    }
    ApplyThemeToCell(cell);
    cell.textLabel.text = self.items[indexPath.row];
    if (indexPath.row <= 2) cell.detailTextLabel.text = @"運用時のデバッグ補助";
    else cell.detailTextLabel.text = @"時系列イベント";
    return cell;
}

- (void)runQuickDiagnostic {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"[OK] tracker singleton"];
    uint8_t test = 0x2a;
    vm_address_t addr = (vm_address_t)&test;
    vm_size_t outSize = 0;
    uint8_t readBack = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), addr, sizeof(uint8_t), (vm_address_t)&readBack, &outSize);
    if (kr == KERN_SUCCESS && outSize == sizeof(uint8_t)) [lines addObject:@"[OK] vm_read_overwrite"];
    else [lines addObject:@"[WARN] vm_read_overwrite"];
    [lines addObject:[NSString stringWithFormat:@"[OK] methods:%lu", (unsigned long)[ExecutionTracker shared].methods.count]];

    NSString *msg = [lines componentsJoinedByString:@"\n"];
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:@"診断テスト"
                                        message:msg
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [[ExecutionTracker shared] logSessionEvent:@"diag" message:@"quick diagnostic run"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;

    if (row == 0) {
        NSDictionary *crash = [[ExecutionTracker shared] lastCrashInfo];
        NSString *msg = crash ? [NSString stringWithFormat:@"%@", crash] : @"前回クラッシュ情報なし";
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"前回クラッシュ"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (row == 1) {
        [[ExecutionTracker shared] clearLastCrashInfo];
        return;
    }
    if (row == 2) {
        [self runQuickDiagnostic];
        return;
    }
    if (row == 3) {
        [self.navigationController pushViewController:[SessionLogController new] animated:YES];
    }
}

@end

@interface TxtPatchEditorController : UIViewController
@property(nonatomic,strong) UITextView *textView;
@property(nonatomic,copy) NSString *initialText;
@property(nonatomic,copy) void (^saveHandler)(NSString *text);
@end

@implementation TxtPatchEditorController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"txt編集";
    self.view.backgroundColor = UIColor.blackColor;
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.textView.textColor = UIColor.greenColor;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.text = self.initialText ?: @"";
    [self.view addSubview:self.textView];
    self.navigationItem.rightBarButtonItem =
    [[UIBarButtonItem alloc] initWithTitle:@"完了" style:UIBarButtonItemStyleDone target:self action:@selector(doneTapped)];
}
- (void)doneTapped {
    if (self.saveHandler) self.saveHandler(self.textView.text ?: @"");
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface TxtMemoryPatchController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *groups;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *enabledRows;
@property(nonatomic,copy) NSString *rawText;
@property(nonatomic,copy) NSString *manualValue;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIBarButtonItem *baseModeButton;
@property(nonatomic) TxtPatchBaseMode baseMode;
@property(nonatomic,copy) NSString *selectedModulePath;
@property(nonatomic,strong) NSURL *pendingSaveURL;
@end

@implementation TxtMemoryPatchController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"txtメモリパッチ";
    self.view.backgroundColor = ThemeBackgroundColor();
    self.tableView.backgroundColor = ThemeBackgroundColor();
    self.tableView.rowHeight = 56.0;
    self.tableView.tableFooterView = [UIView new];
    self.groups = [NSMutableArray array];
    self.enabledRows = [NSMutableSet set];
    self.baseMode = TxtPatchBaseModeMain;
    self.selectedModulePath = @"";

    [self setupHeader];
    [self restoreState];
    [self publishRuntimeState];
    StartTxtPatchGlobalRunner();

    UIBarButtonItem *fileButton =
    [[UIBarButtonItem alloc] initWithTitle:@"ファイル"
                                     style:UIBarButtonItemStylePlain
                                    target:self
                                    action:@selector(fileTapped)];
    self.baseModeButton = [[UIBarButtonItem alloc] initWithTitle:@"Base:Main" style:UIBarButtonItemStylePlain target:self action:@selector(baseModeTapped)];
    self.navigationItem.rightBarButtonItems = @[
        fileButton,
        [[UIBarButtonItem alloc] initWithTitle:@"編集" style:UIBarButtonItemStylePlain target:self action:@selector(editTapped)],
        self.baseModeButton
    ];
    [self refreshBaseTitle];
}

- (void)setupHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 40)];
    header.backgroundColor = UIColor.blackColor;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, self.view.bounds.size.width - 24, 24)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.statusLabel.textColor = ThemeSecondaryTextColor();
    self.statusLabel.text = @"ready";
    [header addSubview:self.statusLabel];
    self.tableView.tableHeaderView = header;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self persistState];
    [self publishRuntimeState];
}

- (void)refreshBaseTitle {
    NSString *title = @"Base:Main";
    if (self.baseMode == TxtPatchBaseModeMinAddress) title = @"Base:Min";
    if (self.baseMode == TxtPatchBaseModeModule) title = @"Base:Module";
    self.baseModeButton.title = title;
}

- (void)restoreState {
    NSDictionary *state = [MonitorUD() dictionaryForKey:@"txt_patch_state_v2"];
    if ([state isKindOfClass:[NSDictionary class]]) {
        NSArray *g = state[@"groups"];
        if ([g isKindOfClass:[NSArray class]]) self.groups = [g mutableCopy];
        NSArray *en = state[@"enabledRows"];
        if ([en isKindOfClass:[NSArray class]]) self.enabledRows = [NSMutableSet setWithArray:en];
        self.rawText = state[@"rawText"] ?: @"";
        self.manualValue = state[@"manualValue"] ?: @"";
        self.baseMode = (TxtPatchBaseMode)[state[@"baseMode"] integerValue];
        self.selectedModulePath = state[@"selectedModulePath"] ?: @"";
    }
    if (self.rawText.length > 0 && self.groups.count == 0) {
        [self parseRawTextAndReload];
    }
}

- (void)persistState {
    [MonitorUD() setObject:@{
        @"groups": self.groups ?: @[],
        @"enabledRows": self.enabledRows.allObjects ?: @[],
        @"rawText": self.rawText ?: @"",
        @"manualValue": self.manualValue ?: @"",
        @"baseMode": @(self.baseMode),
        @"selectedModulePath": self.selectedModulePath ?: @""
    } forKey:@"txt_patch_state_v2"];
}

- (void)publishRuntimeState {
    TxtPatchStateCache()[@"txt_patch_runtime"] = @{
        @"groups": self.groups ?: @[],
        @"enabledRows": self.enabledRows.allObjects ?: @[],
        @"baseMode": @(self.baseMode),
        @"selectedModulePath": self.selectedModulePath ?: @"",
        @"manualValue": self.manualValue ?: @""
    };
}

- (void)parseRawTextAndReload {
    NSMutableArray<NSDictionary *> *outGroups = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    for (NSString *line in [self.rawText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trim.length == 0) continue;
        if ([trim hasPrefix:@"["] && [trim hasSuffix:@"]"]) {
            if (current) [outGroups addObject:current];
            NSString *name = [trim substringWithRange:NSMakeRange(1, trim.length - 2)];
            current = [@{@"name": (name.length ? name : @"(unnamed)"), @"lines": [NSMutableArray array]} mutableCopy];
            continue;
        }
        NSArray<NSString *> *parts = [trim componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        for (NSString *p in parts) if (p.length) [tokens addObject:p];
        if (tokens.count >= 3 && [tokens[0].lowercaseString isEqualToString:@"base"]) {
            if (!current) current = [@{@"name": @"(default)", @"lines": [NSMutableArray array]} mutableCopy];
            NSMutableArray *lines = current[@"lines"];
            [lines addObject:@{@"offset": tokens[1], @"value": tokens[2]}];
        }
    }
    if (current) [outGroups addObject:current];
    self.groups = outGroups;
    NSMutableSet<NSNumber *> *newEnabled = [NSMutableSet set];
    for (NSNumber *n in self.enabledRows) {
        if (n.integerValue < (NSInteger)self.groups.count) [newEnabled addObject:n];
    }
    self.enabledRows = newEnabled;
    [self.tableView reloadData];
    [self persistState];
    [self publishRuntimeState];
}

- (void)editTapped {
    TxtPatchEditorController *editor = [TxtPatchEditorController new];
    editor.initialText = self.rawText ?: @"";
    __weak typeof(self) weakSelf = self;
    editor.saveHandler = ^(NSString *text) {
        weakSelf.rawText = text ?: @"";
        [weakSelf parseRawTextAndReload];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"parsed groups:%lu", (unsigned long)weakSelf.groups.count];
    };
    [self.navigationController pushViewController:editor animated:YES];
}

- (void)fileTapped {
    UIAlertController *sheet =
    [UIAlertController alertControllerWithTitle:@"ファイル"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"読み込み"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction * _Nonnull action) {
        [self importTapped];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction * _Nonnull action) {
        [self exportTapped];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)baseModeTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Auto Base" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"メイン実行バイナリ基準" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        self.baseMode = TxtPatchBaseModeMain;
        [self refreshBaseTitle];
        [self persistState];
        [self publishRuntimeState];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"最小アドレス基準" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        self.baseMode = TxtPatchBaseModeMinAddress;
        [self refreshBaseTitle];
        [self persistState];
        [self publishRuntimeState];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"任意モジュール基準" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        [self pickModuleBase];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.baseModeButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickModuleBase {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"モジュール選択" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *paths = LoadedImagePaths();
    NSInteger limit = MIN((NSInteger)paths.count, 25);
    for (NSInteger i = 0; i < limit; i++) {
        NSString *path = paths[i];
        NSString *title = path.lastPathComponent ?: path;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
            self.baseMode = TxtPatchBaseModeModule;
            self.selectedModulePath = path ?: @"";
            [self refreshBaseTitle];
            [self persistState];
            [self publishRuntimeState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.baseModeButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)importTapped {
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        Class utTypeClass = NSClassFromString(@"UTType");
        id plainType = nil;
        if (utTypeClass && [utTypeClass respondsToSelector:NSSelectorFromString(@"plainText")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            plainType = [utTypeClass performSelector:NSSelectorFromString(@"plainText")];
#pragma clang diagnostic pop
        }
        NSArray *types = plainType ? @[plainType] : @[];
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    }
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)exportTapped {
    NSString *text = self.rawText ?: @"";
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"txt_patch.txt"];
    [text writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSURL *url = [NSURL fileURLWithPath:tmp];
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url]];
    }
    picker.delegate = self;
    self.pendingSaveURL = url;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.count == 0) return;
    NSURL *url = urls.firstObject;
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (text.length > 0) {
        self.rawText = text;
        [self parseRawTextAndReload];
        self.statusLabel.text = [NSString stringWithFormat:@"loaded %@", url.lastPathComponent ?: @"file"];
        self.statusLabel.textColor = UIColor.systemGreenColor;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.groups.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TxtPatchCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"TxtPatchCell"];
    }
    ApplyThemeToCell(cell);
    NSDictionary *group = self.groups[indexPath.row];
    NSString *name = group[@"name"] ?: @"(unnamed)";
    NSArray *lines = group[@"lines"];
    cell.textLabel.text = name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"patches:%lu", (unsigned long)lines.count];
    cell.accessoryType = [self.enabledRows containsObject:@(indexPath.row)] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSNumber *rowNum = @(indexPath.row);
    if ([self.enabledRows containsObject:rowNum]) {
        [self.enabledRows removeObject:rowNum];
    } else {
        NSDictionary *group = self.groups[indexPath.row];
        NSArray<NSDictionary *> *lines = group[@"lines"];
        BOOL needValInput = NO;
        for (NSDictionary *line in lines) {
            if ([[line[@"value"] lowercaseString] isEqualToString:@"val"]) {
                needValInput = YES;
                break;
            }
        }
        if (needValInput) {
            UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"val入力"
                                                message:@"この項目は val を使用します"
                                         preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull field) {
                field.text = self.manualValue ?: @"";
                field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
                field.placeholder = @"例: 123";
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"適用"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction * _Nonnull action) {
                self.manualValue = alert.textFields.firstObject.text ?: @"";
                [self.enabledRows addObject:rowNum];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
                [self persistState];
                [self publishRuntimeState];
                self.statusLabel.textColor = ThemeSecondaryTextColor();
                self.statusLabel.text = [NSString stringWithFormat:@"enabled:%lu", (unsigned long)self.enabledRows.count];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [self.enabledRows addObject:rowNum];
    }
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self persistState];
    [self publishRuntimeState];
    self.statusLabel.textColor = ThemeSecondaryTextColor();
    self.statusLabel.text = [NSString stringWithFormat:@"enabled:%lu", (unsigned long)self.enabledRows.count];
}

@end

@interface ThemeEditorController : UIViewController
@property(nonatomic,strong) UITextField *bgField;
@property(nonatomic,strong) UITextField *textField;
@property(nonatomic,strong) UITextField *subField;
@property(nonatomic,strong) UITextField *borderField;
@property(nonatomic,strong) UIView *previewBox;
@property(nonatomic,strong) UILabel *previewTitle;
@property(nonatomic,strong) UILabel *previewSub;
@end

@implementation ThemeEditorController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"カラー設定";
    self.view.backgroundColor = ThemeBackgroundColor();
    NSDictionary *hex = ThemeCurrentHexStrings();
    CGFloat w = self.view.bounds.size.width;

    self.bgField = [self makeField:CGRectMake(12, 100, w - 24, 34) placeholder:@"背景 #RRGGBB" value:hex[@"background"]];
    self.textField = [self makeField:CGRectMake(12, 142, w - 24, 34) placeholder:@"文字 #RRGGBB" value:hex[@"primaryText"]];
    self.subField = [self makeField:CGRectMake(12, 184, w - 24, 34) placeholder:@"補助文字 #RRGGBB" value:hex[@"secondaryText"]];
    self.borderField = [self makeField:CGRectMake(12, 226, w - 24, 34) placeholder:@"枠 #RRGGBB" value:hex[@"border"]];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(12, 270, (w - 36) / 2.0, 36);
    apply.layer.cornerRadius = 8;
    apply.layer.borderWidth = 1;
    apply.layer.borderColor = ThemeBorderColor().CGColor;
    [apply setTitle:@"適用" forState:UIControlStateNormal];
    [apply setTitleColor:ThemePrimaryTextColor() forState:UIControlStateNormal];
    [apply addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:apply];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(CGRectGetMaxX(apply.frame) + 12, 270, (w - 36) / 2.0, 36);
    reset.layer.cornerRadius = 8;
    reset.layer.borderWidth = 1;
    reset.layer.borderColor = ThemeBorderColor().CGColor;
    [reset setTitle:@"初期化" forState:UIControlStateNormal];
    [reset setTitleColor:ThemePrimaryTextColor() forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:reset];

    self.previewBox = [[UIView alloc] initWithFrame:CGRectMake(12, 318, w - 24, 120)];
    self.previewBox.layer.cornerRadius = 10;
    self.previewBox.layer.borderWidth = 1;
    [self.view addSubview:self.previewBox];

    self.previewTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, self.previewBox.bounds.size.width - 28, 24)];
    self.previewTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.previewTitle.text = @"Preview Title";
    [self.previewBox addSubview:self.previewTitle];

    self.previewSub = [[UILabel alloc] initWithFrame:CGRectMake(14, 44, self.previewBox.bounds.size.width - 28, 24)];
    self.previewSub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.previewSub.text = @"Preview Subtitle";
    [self.previewBox addSubview:self.previewSub];
    [self applyPreview];
}

- (UITextField *)makeField:(CGRect)frame placeholder:(NSString *)placeholder value:(NSString *)value {
    UITextField *f = [[UITextField alloc] initWithFrame:frame];
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    f.textColor = UIColor.whiteColor;
    f.placeholder = placeholder;
    f.text = value ?: @"";
    [self.view addSubview:f];
    return f;
}

- (void)applyPreview {
    UIColor *bg = ThemeBackgroundColor();
    UIColor *tx = ThemePrimaryTextColor();
    UIColor *sub = ThemeSecondaryTextColor();
    UIColor *bd = ThemeBorderColor();
    self.view.backgroundColor = bg;
    self.previewBox.backgroundColor = bg;
    self.previewBox.layer.borderColor = bd.CGColor;
    self.previewTitle.textColor = tx;
    self.previewSub.textColor = sub;
}

- (void)applyTapped {
    NSString *err = nil;
    if (!ThemeSetHexStrings(self.bgField.text, self.textField.text, self.subField.text, self.borderField.text, &err)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"エラー" message:(err ?: @"invalid") preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self applyPreview];
}

- (void)resetTapped {
    ThemeResetDefaults();
    NSDictionary *hex = ThemeCurrentHexStrings();
    self.bgField.text = hex[@"background"];
    self.textField.text = hex[@"primaryText"];
    self.subField.text = hex[@"secondaryText"];
    self.borderField.text = hex[@"border"];
    [self applyPreview];
}

@end

@interface MonitorSettingsController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *items;
@end

#include "AutoClickController.inc"

@implementation MonitorSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"設定";
    self.items = @[@"更新間隔 0.25s", @"更新間隔 0.5s", @"更新間隔 1.0s", @"更新間隔 2.0s", @"バッテリー節約", @"コンパクト表示", @"書込前確認", @"バックグラウンドバイナリ監視", @"カラー設定"];
    self.view.backgroundColor = ThemeBackgroundColor();
    self.tableView.backgroundColor = ThemeBackgroundColor();
    self.tableView.rowHeight = 54.0;
    self.tableView.tableFooterView = [UIView new];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SettingCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"SettingCell"];
        cell.textLabel.font = [UIFont systemFontOfSize:13];
    }
    ApplyThemeToCell(cell);
    cell.textLabel.text = self.items[indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryNone;

    double interval = [MonitorUD() doubleForKey:kPrefRefreshInterval];
    if (interval <= 0) interval = 1.0;
    if (indexPath.row == 0 && fabs(interval - 0.25) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row == 1 && fabs(interval - 0.5) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row == 2 && fabs(interval - 1.0) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row == 3 && fabs(interval - 2.0) < 0.001) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    if (indexPath.row >= 4 && indexPath.row <= 7) {
        BOOL on = NO;
        if (indexPath.row == 4) on = [MonitorUD() boolForKey:kPrefBatterySaver];
        if (indexPath.row == 5) on = [MonitorUD() boolForKey:kPrefCompactMode];
        if (indexPath.row == 6) on = [MonitorUD() objectForKey:kPrefWriteConfirm] ? [MonitorUD() boolForKey:kPrefWriteConfirm] : YES;
        if (indexPath.row == 7) on = [MonitorUD() boolForKey:kPrefBackgroundBinary];
        cell.detailTextLabel.text = on ? @"ON" : @"OFF";
    } else if (indexPath.row == 8) {
        cell.detailTextLabel.text = @"開く";
    } else {
        cell.detailTextLabel.text = @"";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 8) {
        [self.navigationController pushViewController:[ThemeEditorController new] animated:YES];
        return;
    }
    if (indexPath.row <= 3) {
        NSArray *vals = @[@0.25, @0.5, @1.0, @2.0];
        [MonitorUD() setDouble:[vals[indexPath.row] doubleValue] forKey:kPrefRefreshInterval];
    } else {
        NSString *key = nil;
        if (indexPath.row == 4) key = kPrefBatterySaver;
        if (indexPath.row == 5) key = kPrefCompactMode;
        if (indexPath.row == 6) key = kPrefWriteConfirm;
        if (indexPath.row == 7) key = kPrefBackgroundBinary;
        if (key) [MonitorUD() setBool:![MonitorUD() boolForKey:key] forKey:key];
    }
    [[ExecutionTracker shared] logSessionEvent:@"setting" message:[NSString stringWithFormat:@"tapped row:%ld", (long)indexPath.row]];
    [tableView reloadData];
}

@end

@interface MonitorViewController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *menuItems;
@end

@implementation MonitorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    ThemeApplyGlobalAppearance();
    self.title = @"Monitor";
    self.menuItems = @[@"HOOK", @"バイナリ監視", @"メモリ追跡", @"txtメモリパッチ", @"オートクリック", @"ツール", @"設定"];

    self.view.backgroundColor = ThemeBackgroundColor();
    self.tableView.backgroundColor = ThemeBackgroundColor();
    self.tableView.tableFooterView = [UIView new];

    self.navigationItem.leftBarButtonItem =
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                   target:self
                                                   action:@selector(closeTapped)];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.menuItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MenuCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"MenuCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    ApplyThemeToCell(cell);

    NSString *title = self.menuItems[indexPath.row];
    cell.textLabel.text = title;
    if (indexPath.row == 0) {
        cell.detailTextLabel.text = @"Hookブラウザ";
    } else if (indexPath.row == 1) {
        cell.detailTextLabel.text = @"実行中メインバイナリのJIT不正変更監視";
    } else if (indexPath.row == 2) {
        cell.detailTextLabel.text = @"数値/文字列サーチ・書換え・ロック";
    } else if (indexPath.row == 3) {
        cell.detailTextLabel.text = @"base/search/getコマンド実行";
    } else if (indexPath.row == 4) {
        cell.detailTextLabel.text = @"縮小表示 + 数字アイコン順タップループ";
    } else if (indexPath.row == 5) {
        cell.detailTextLabel.text = @"クラッシュ/診断/ログ";
    } else {
        cell.detailTextLabel.text = @"更新間隔/省電力/コンパクト表示/安全ガード";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    UIViewController *next = nil;
    if (indexPath.row == 0) {
        next = [HookDylibListController new];
    } else if (indexPath.row == 1) {
        next = [BinaryListController new];
    } else if (indexPath.row == 2) {
        Class cls = NSClassFromString(@"MemorySearchController");
        next = [cls new];
    } else if (indexPath.row == 3) {
        next = [TxtMemoryPatchController new];
    } else if (indexPath.row == 4) {
        next = [AutoClickController new];
    } else if (indexPath.row == 5) {
        next = [MonitorToolsController new];
    } else {
        next = [MonitorSettingsController new];
    }
    [[ExecutionTracker shared] logSessionEvent:@"menu" message:[NSString stringWithFormat:@"open %@", self.menuItems[indexPath.row]]];
    [self.navigationController pushViewController:next animated:YES];
}

- (BOOL)shouldAutorotate {
    return NO;
}

@end
