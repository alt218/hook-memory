//
//  PTFakeMetaTouch.m
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import "PTFakeMetaTouch.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication-KIFAdditions.h"
#import "UIEvent+KIFAdditions.h"
#ifndef DLog
#define DLog(...) NSLog(__VA_ARGS__)
#endif

static UIWindow *PTActiveWindow(void) {
    extern __weak UIWindow *PTFakePreferredWindow;
    if (PTFakePreferredWindow && !PTFakePreferredWindow.hidden && PTFakePreferredWindow.alpha > 0.01) {
        return PTFakePreferredWindow;
    }
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

static NSMutableArray *touchAry;
__weak UIWindow *PTFakePreferredWindow = nil;
@implementation PTFakeMetaTouch

+ (void)load{
    KW_ENABLE_CATEGORY(UITouch_KIFAdditions);
    KW_ENABLE_CATEGORY(UIEvent_KIFAdditions);
    touchAry = [[NSMutableArray alloc] init];
}

+ (void)ensureTouchPoolReady {
    if (touchAry.count > 0) return;
    for (NSInteger i = 0; i < 100; i++) {
        [touchAry addObject:[NSNull null]];
    }
}

+ (void)setPreferredWindow:(UIWindow *)window {
    PTFakePreferredWindow = window;
}

+ (NSInteger)fakeTouchId:(NSInteger)pointId AtPoint:(CGPoint)point withTouchPhase:(UITouchPhase)phase{
    [self ensureTouchPoolReady];
    //DLog(@"4. fakeTouchId , phase : %ld ",(long)phase);
    if (pointId==0) {
        //随机一个没有使用的pointId
        pointId = [self getAvailablePointId];
        if (pointId==0) {
            DLog(@"PTFakeTouch ERROR! pointId all used");
            return 0;
        }
    }
    pointId = pointId - 1;
    id current = [touchAry objectAtIndex:pointId];
    UITouch *touch = [current isKindOfClass:[UITouch class]] ? (UITouch *)current : nil;
    if (phase == UITouchPhaseBegan) {
        touch = nil;
        UIWindow *window = PTActiveWindow();
        if (!window) return 0;
        touch = [[UITouch alloc] initAtPoint:point inWindow:window];
        
        [touchAry replaceObjectAtIndex:pointId withObject:touch];
        [touch setLocationInWindow:point];
    }else{
        if (!touch) return 0;
        [touch setLocationInWindow:point];
        [touch setPhaseAndUpdateTimestamp:phase];
    }
    
    
    
    UIEvent *event = [self eventWithTouches:touchAry];
    [[UIApplication sharedApplication] sendEvent:event];
    if ((touch.phase==UITouchPhaseBegan)||touch.phase==UITouchPhaseMoved) {
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
    } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
        [touchAry replaceObjectAtIndex:pointId withObject:[NSNull null]];
    }
    return (pointId+1);
}


+ (UIEvent *)eventWithTouches:(NSArray *)touches
{
    // _touchesEvent is a private selector, interface is exposed in UIApplication(KIFAdditionsPrivate)
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];
    NSMutableArray *validTouches = [NSMutableArray array];
    for (id t in touches) {
        if ([t isKindOfClass:[UITouch class]]) [validTouches addObject:t];
    }
    [event kif_setEventWithTouches:validTouches];
    
    for (UITouch *aTouch in validTouches) {
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }
    
    return event;
}

+ (NSInteger)getAvailablePointId{
    [self ensureTouchPoolReady];
    NSInteger availablePointId=0;
    NSMutableArray *availableIds = [[NSMutableArray alloc]init];
    for (NSInteger i=0; i<touchAry.count-50; i++) {
        id item = [touchAry objectAtIndex:i];
        if (![item isKindOfClass:[UITouch class]]) {
            [availableIds addObject:@(i+1)];
            continue;
        }
        UITouch *touch = (UITouch *)item;
        if (touch.phase==UITouchPhaseEnded||touch.phase==UITouchPhaseStationary||touch.phase==UITouchPhaseCancelled) {
            [availableIds addObject:@(i+1)];
        }
    }
    availablePointId = availableIds.count==0 ? 0 : [[availableIds objectAtIndex:(arc4random() % availableIds.count)] integerValue];
    return availablePointId;
}
@end
