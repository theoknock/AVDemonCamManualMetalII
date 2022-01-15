//
//  ControlView.m
//  AVDemonCamManualMetalII
//
//  Created by Xcode Developer on 1/13/22.
//

#import "ControlView.h"
#import "Renderer.h"

static CGFloat radius;

@implementation ControlView {
    UIBezierPath *path;
}

+(Class)layerClass {
    return [CAShapeLayer class];
}

#define degreesToRadians(angleDegrees) (angleDegrees * M_PI / 180.0)

static void (^(^(^touch_handler_init_)(CAShapeLayer *))(UITouch *))(void) = ^ (CAShapeLayer * layer) {
    __block UIBezierPath * path = [UIBezierPath bezierPath];
    return ^ (UITouch * touch) {
        return ^{
            set_touch_point([touch preciseLocationInView:touch.view]);
            path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMaxX(layer.bounds), CGRectGetMaxY(layer.bounds)) radius:radius startAngle:degreesToRadians(180.0) endAngle:degreesToRadians(270.0) clockwise:TRUE];
            [(CAShapeLayer *)layer setPath:path.CGPath];
        };
        
    };
};

static void (^(^touch_handler_)(UITouch *))(void);
static void (^handle_touch_)(void);

             
- (void)awakeFromNib {
    [super awakeFromNib];
    [(CAShapeLayer *)self.layer setStrokeColor:[UIColor systemBlueColor].CGColor];
    [(CAShapeLayer *)self.layer setFillColor:[UIColor clearColor].CGColor];
    path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMaxX(self.bounds), CGRectGetMaxY(self.bounds)) radius:radius startAngle:degreesToRadians(180.0) endAngle:degreesToRadians(270.0) clockwise:TRUE];
    [(CAShapeLayer *)self.layer setPath:path.CGPath];
    touch_handler_ = touch_handler_init_((CAShapeLayer *)self.layer);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    handle_touch_ = touch_handler_(touches.anyObject);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    handle_touch_();
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    handle_touch_();
    
}

void set_radius(CGFloat r) {
    const CGRect ctx = UIScreen.mainScreen.bounds;
    radius = simd_clamp((float)r, (float)CGRectGetMinX(ctx), (float)CGRectGetMaxX(ctx));
//    printf("radius == %f\n", radius);
}

@end
