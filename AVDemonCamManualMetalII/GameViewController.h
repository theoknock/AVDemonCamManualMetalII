//
//  GameViewController.h
//  AVDemonCamManualMetalII
//
//  Created by Xcode Developer on 1/13/22.
//

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "Renderer.h"
#import "ControlView.h"
#import "VideoCamera.h"

// Our iOS view controller
@interface GameViewController : UIViewController

@property (strong, nonatomic) IBOutlet ControlView *controlView;

@end
