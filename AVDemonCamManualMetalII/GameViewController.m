//
//  GameViewController.m
//  AVDemonCamManualMetalII
//
//  Created by Xcode Developer on 1/13/22.
//

#import "GameViewController.h"
#import "Renderer.h"

@implementation GameViewController
{
    MTKView *_view;

    Renderer *_renderer;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _view = (MTKView *)self.view;

    _view.device = MTLCreateSystemDefaultDevice();
    _view.backgroundColor = UIColor.blackColor;

    if(!_view.device)
    {
        NSLog(@"Metal is not supported on this device");
        self.view = [[UIView alloc] initWithFrame:self.view.frame];
        return;
    }

    _renderer = [[Renderer alloc] initWithMetalKitView:_view];

    [_renderer mtkView:_view drawableSizeWillChange:_view.bounds.size];

    _view.delegate = _renderer; // TO_DO: Replace delegate with direct draw call to layer
}



@end
