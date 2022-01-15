//
//  ControlView.h
//  AVDemonCamManualMetalII
//
//  Created by Xcode Developer on 1/13/22.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <Metal/Metal.h>
#include "ShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

extern void set_radius(CGFloat radius);

static float button_angles[5] =               {0.0, 0.25, 0.5, 0.75, 1.0};    // button_center_xy__angle_z[0 ... 5].z
static vector_float2 arc_center =             {1.0, 1.0};                     // arc_center_xy__radius_z.z
static vector_float3 arc_control_points[2] = {{0.0, 0.0, 1.0},                // arc_control_points_xyz[0].xyz
                                              {1.0, 0.5, 0.5}};               // arc_control_points_xyz[1].xyz

static __strong UIButton * _Nonnull buttons[5];
static void (^(^populate_collection)(__strong UIButton * _Nonnull [_Nonnull 5]))(UIButton * (^__strong)(unsigned int)) = ^ (__strong UIButton * _Nonnull button_collection[5]) {
    dispatch_queue_t enumerator_queue  = dispatch_queue_create("enumerator_queue", DISPATCH_QUEUE_CONCURRENT);
    dispatch_queue_t enumeration_queue = dispatch_queue_create_with_target("enumeration_queue", DISPATCH_QUEUE_SERIAL, dispatch_get_main_queue());
    return ^ (UIButton *(^enumeration)(unsigned int)) {
        dispatch_apply(5, enumerator_queue, ^(size_t index) {
            dispatch_async(enumeration_queue, ^{
                button_collection[index] = enumeration((unsigned int)index); // adds buttons to an array after configured by enumeration
            });
        });
    };
};

static void (^(^enumerate_collection)(__strong UIButton * _Nonnull [_Nonnull 5]))(void (^__strong)(UIButton * _Nonnull, unsigned int)) = ^ (__strong UIButton * _Nonnull button_collection[5]) {
    dispatch_queue_t enumerator_queue  = dispatch_queue_create("enumerator_queue", DISPATCH_QUEUE_CONCURRENT);
    dispatch_queue_t enumeration_queue = dispatch_queue_create_with_target("enumeration_queue", DISPATCH_QUEUE_SERIAL, dispatch_get_main_queue());
    return ^ (void(^enumeration)(UIButton * _Nonnull, unsigned int)) {
        dispatch_apply(5, enumerator_queue, ^(size_t index) {
            dispatch_async(enumeration_queue, ^{
                enumeration(button_collection[index], (unsigned int)index); // no return value
            });
        });
    };
};

static void (^(^(^(^touch_handler_init)(dispatch_block_t))(void(^)(CGPoint)))(UITouch * _Nonnull))(void) = ^ (dispatch_block_t _Nullable init_blk) {
    (!init_blk) ?: init_blk();
    return ^ (void(^process_touch_point)(CGPoint)) {
        return ^ (UITouch * _Nonnull touch) {
            return ^ {
                CGPoint touch_point = [touch preciseLocationInView:touch.view];
                process_touch_point(touch_point);
            };
        };
    };
};
static void (^(^touch_handler)(UITouch *))(void);
static void (^handle_touch)(void);

@interface ControlView : UIView

@end

NS_ASSUME_NONNULL_END
