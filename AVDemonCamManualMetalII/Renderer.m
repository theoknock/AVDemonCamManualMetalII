//
//  Renderer.m
//  AVDemonCamManualMetalII
//
//  Created by Xcode Developer on 1/13/22.
//

#import <simd/simd.h>
#import <ModelIO/ModelIO.h>
#import "ControlView.h"
#import "VideoCamera.h"

#import "Renderer.h"

// Include header shared between C code here, which executes Metal API commands, and .metal files
#import "ShaderTypes.h"

static const NSUInteger MaxBuffersInFlight = 3;

/* */
static simd_float2 touch_point;
id<MTLTexture>(^create_texture)(CVPixelBufferRef);
void(^draw_texture)(id<MTLTexture>);
id<MTLTexture>texture;

@implementation Renderer
{
    dispatch_semaphore_t _inFlightSemaphore;
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    
    id <MTLBuffer> _dynamicUniformBuffer[MaxBuffersInFlight];
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _colorMap;
    MTLVertexDescriptor *_mtlVertexDescriptor;
    
    uint8_t _uniformBufferIndex;
    
    matrix_float4x4 _projectionMatrix;
    
    float _rotation;
    
    MTKMesh *_mesh;
    
    /* */
    id<MTLComputePipelineState> _mComputeFunctionPSO;
    id<MTLBuffer> captureDevicePropertyControlLayoutBuffer;
    CGRect contextRect;
    CaptureDevicePropertyControlLayout * captureDevicePropertyControlLayoutBufferPtr;
    CADisplayLink * _Nonnull display_link;
    void (^(^animation)(void))(void);
}

-(nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
{
    self = [super init];
    if(self)
    {
        _device = view.device;
        _inFlightSemaphore = dispatch_semaphore_create(MaxBuffersInFlight);
        [self _loadMetalWithView:view];
        [self _loadAssets];
    }
    
    return self;
}

- (void)_loadMetalWithView:(nonnull MTKView *)view;
{
    /// Load Metal state objects and initialize renderer dependent view properties
    
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    view.sampleCount = 1;
    
    _mtlVertexDescriptor = [[MTLVertexDescriptor alloc] init];
    
    _mtlVertexDescriptor.attributes[VertexAttributePosition].format = MTLVertexFormatFloat3;
    _mtlVertexDescriptor.attributes[VertexAttributePosition].offset = 0;
    _mtlVertexDescriptor.attributes[VertexAttributePosition].bufferIndex = BufferIndexMeshPositions;
    
    _mtlVertexDescriptor.attributes[VertexAttributeTexcoord].format = MTLVertexFormatFloat2;
    _mtlVertexDescriptor.attributes[VertexAttributeTexcoord].offset = 0;
    _mtlVertexDescriptor.attributes[VertexAttributeTexcoord].bufferIndex = BufferIndexMeshGenerics;
    
    _mtlVertexDescriptor.layouts[BufferIndexMeshPositions].stride = 12;
    _mtlVertexDescriptor.layouts[BufferIndexMeshPositions].stepRate = 1;
    _mtlVertexDescriptor.layouts[BufferIndexMeshPositions].stepFunction = MTLVertexStepFunctionPerVertex;
    
    _mtlVertexDescriptor.layouts[BufferIndexMeshGenerics].stride = 8;
    _mtlVertexDescriptor.layouts[BufferIndexMeshGenerics].stepRate = 1;
    _mtlVertexDescriptor.layouts[BufferIndexMeshGenerics].stepFunction = MTLVertexStepFunctionPerVertex;
    
    id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];
    
    id <MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];
    
    id <MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"fragmentShader"];
    
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    pipelineStateDescriptor.sampleCount = view.sampleCount;
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.vertexDescriptor = _mtlVertexDescriptor;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    pipelineStateDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;
    pipelineStateDescriptor.stencilAttachmentPixelFormat = view.depthStencilPixelFormat;
    
    NSError *error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState)
    {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
    
    for(NSUInteger i = 0; i < MaxBuffersInFlight; i++)
    {
        _dynamicUniformBuffer[i] = [_device newBufferWithLength:sizeof(Uniforms)
                                                        options:MTLResourceStorageModeShared];
        
        _dynamicUniformBuffer[i].label = @"UniformBuffer";
    }
    
    /* */
    id<MTLFunction> computeFunction = [defaultLibrary newFunctionWithName:@"computeKernel"];
    _mComputeFunctionPSO = [_device newComputePipelineStateWithFunction:computeFunction error:&error];
    captureDevicePropertyControlLayoutBuffer       = [_device newBufferWithLength:sizeof(CaptureDevicePropertyControlLayout) options:MTLResourceStorageModeShared];
    captureDevicePropertyControlLayoutBufferPtr    = captureDevicePropertyControlLayoutBuffer.contents;
    
    create_texture = ^{
        MTLPixelFormat pixelFormat = view.colorPixelFormat;
        CFStringRef textureCacheKeys[2] = { kCVMetalTextureCacheMaximumTextureAgeKey, kCVMetalTextureUsage };
        float maximumTextureAge = (1.0); // / view.preferredFramesPerSecond);
        CFNumberRef maximumTextureAgeValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &maximumTextureAge);
        MTLTextureUsage textureUsage = MTLTextureUsageShaderRead;
        CFNumberRef textureUsageValue = CFNumberCreate(NULL, kCFNumberNSIntegerType, &textureUsage);
        CFTypeRef textureCacheValues[2] = { maximumTextureAgeValue, textureUsageValue };
        CFIndex textureCacheAttributesCount = 2;
        CFDictionaryRef cacheAttributes = CFDictionaryCreate(NULL, (const void **)textureCacheKeys, (const void **)textureCacheValues, textureCacheAttributesCount, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        
        CVMetalTextureCacheRef textureCache;
        CVMetalTextureCacheCreate(NULL, cacheAttributes, self->_device, NULL, &textureCache);
        CFShow(cacheAttributes);
        CFRelease(textureUsageValue);
        CFRelease(cacheAttributes);
        
        return ^ id<MTLTexture> _Nonnull (CVPixelBufferRef pixel_buffer) {
            @autoreleasepool {
                __autoreleasing id<MTLTexture> texture = nil;
                CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
                {
                    CVMetalTextureRef metalTextureRef = NULL;
                    CVMetalTextureCacheCreateTextureFromImage(NULL, textureCache, pixel_buffer, cacheAttributes, pixelFormat, CVPixelBufferGetWidth(pixel_buffer), CVPixelBufferGetHeight(pixel_buffer), 0, &metalTextureRef);
                    texture = CVMetalTextureGetTexture(metalTextureRef);
                    CFRelease(metalTextureRef);
                }
                CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
                return texture;
            }
        };
    }();
    
    draw_texture = ^ (id<MTLTexture> tex) {
        /// Per frame updates here
        
    //    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);
                id<CAMetalDrawable> layerDrawable = [(CAMetalLayer *)(view.layer) nextDrawable];

        _uniformBufferIndex = (_uniformBufferIndex + 1) % MaxBuffersInFlight;
        
        id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        commandBuffer.label = @"MyCommand";
        
    //    __block dispatch_semaphore_t block_sema = _inFlightSemaphore;
        [commandBuffer addCompletedHandler:^ (id<MTLBuffer> buffer) {
            return ^ (id<MTLCommandBuffer> _Nonnull commands) {
                
    //            dispatch_semaphore_signal(block_sema);
                
                set_radius((CGFloat)(*self->captureDevicePropertyControlLayoutBufferPtr).arc_center_xy__radius_z.z);
                
                //            printf("\ntouch_point\t\t\t\t{%.1f, %.1f}\n",
                //                   (*self->captureDevicePropertyControlLayoutBufferPtr).touch_point_xy__angle_z.x,
                //                   (*self->captureDevicePropertyControlLayoutBufferPtr).touch_point_xy__angle_z.y);
                //            for (int i = 0; i < 2; i++) {
                //                printf("control_points %d\t\t{%.1f, %.1f}\n",
                //                       i,
                //                       (*self->captureDevicePropertyControlLayoutBufferPtr).arc_control_points_xyz[i].x,
                //                       (*self->captureDevicePropertyControlLayoutBufferPtr).arc_control_points_xyz[i].y);
                //            }
                //            for (int i = 0; i < 5; i++) {
                //                printf("button_center  %d\t\t{%.1f, %.1f}\n",
                //                       i,
                //                       (*self->captureDevicePropertyControlLayoutBufferPtr).button_center_xy__angle_z[i].x,
                //                       (*self->captureDevicePropertyControlLayoutBufferPtr).button_center_xy__angle_z[i].y);
                //            }
                //            printf("radius\t\t\t\t\t{%.1f}\n",
                //                   (*self->captureDevicePropertyControlLayoutBufferPtr).arc_center_xy__radius_z.z);
            };
        }(captureDevicePropertyControlLayoutBuffer)];
        
    //    [self _updateGameState];
        
        /// Delay getting the currentRenderPassDescriptor until absolutely needed. This avoids
        ///   holding onto the drawable and blocking the display pipeline any longer than necessary
        MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
        
        if(renderPassDescriptor != nil)
        {
            /// Final pass rendering code here
            
            id <MTLRenderCommandEncoder> renderEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            renderEncoder.label = @"MyRenderEncoder";
            
            [renderEncoder pushDebugGroup:@"DrawBox"];
            
            [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
            [renderEncoder setCullMode:MTLCullModeBack];
            [renderEncoder setRenderPipelineState:_pipelineState];
            [renderEncoder setDepthStencilState:_depthState];
            
            [renderEncoder setVertexBuffer:_dynamicUniformBuffer[_uniformBufferIndex]
                                    offset:0
                                   atIndex:BufferIndexUniforms];
            
            [renderEncoder setFragmentBuffer:_dynamicUniformBuffer[_uniformBufferIndex]
                                      offset:0
                                     atIndex:BufferIndexUniforms];
            
            for (NSUInteger bufferIndex = 0; bufferIndex < _mesh.vertexBuffers.count; bufferIndex++)
            {
                MTKMeshBuffer *vertexBuffer = _mesh.vertexBuffers[bufferIndex];
                if((NSNull*)vertexBuffer != [NSNull null])
                {
                    [renderEncoder setVertexBuffer:vertexBuffer.buffer
                                            offset:vertexBuffer.offset
                                           atIndex:bufferIndex];
                }
            }
            
            [renderEncoder setFragmentTexture:tex
                                      atIndex:TextureIndexColor];
            
            for(MTKSubmesh *submesh in _mesh.submeshes)
            {
                [renderEncoder drawIndexedPrimitives:submesh.primitiveType
                                          indexCount:submesh.indexCount
                                           indexType:submesh.indexType
                                         indexBuffer:submesh.indexBuffer.buffer
                                   indexBufferOffset:submesh.indexBuffer.offset];
            }
            
            [renderEncoder popDebugGroup];
            
            [renderEncoder endEncoding];
            
            [commandBuffer presentDrawable:layerDrawable];// view.currentDrawable];
        }
        
        {
            id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
            assert(computeEncoder != nil);
            [computeEncoder setComputePipelineState:_mComputeFunctionPSO];
            [computeEncoder setBuffer:captureDevicePropertyControlLayoutBuffer offset:0 atIndex:0];
            MTLSize threadsPerThreadgroup = MTLSizeMake(MIN(sizeof(CaptureDevicePropertyControlLayout), (_mComputeFunctionPSO.maxTotalThreadsPerThreadgroup / _mComputeFunctionPSO.threadExecutionWidth)), 1, 1);
            MTLSize threadsPerGrid = MTLSizeMake(sizeof(CaptureDevicePropertyControlLayout), 1, 1);
            [computeEncoder dispatchThreads: threadsPerGrid
                      threadsPerThreadgroup: threadsPerThreadgroup];
            [computeEncoder endEncoding];
        }
        
        [commandBuffer commit];
    };
    
    [VideoCamera setAVCaptureVideoDataOutputSampleBufferDelegate:self];
    
    animation = ^{
//        printf("1\t\t%s\n", __PRETTY_FUNCTION__);
        float frameInterval = .05;
        void (^eventHandlerBlock)(void) = ^{
//            printf("3\t\t%s\n", __PRETTY_FUNCTION__);
            Uniforms * uniforms = (Uniforms*)_dynamicUniformBuffer[_uniformBufferIndex].contents;
            
            uniforms->projectionMatrix = _projectionMatrix;
            
            vector_float3 rotationAxis = {1, 1, 0};
            matrix_float4x4 modelMatrix = matrix4x4_rotation(_rotation, rotationAxis);
            matrix_float4x4 viewMatrix = matrix4x4_translation(0.0, 0.0, -8.0);
            
            uniforms->modelViewMatrix = matrix_multiply(viewMatrix, modelMatrix);
            
            _rotation += frameInterval;
            
            /* */
//            [self drawInMTKView:view];
            
            captureDevicePropertyControlLayoutBufferPtr[0].touch_point_xy__angle_z = simd_make_float3(simd_make_float2((float)(touch_point.x), (float)(touch_point.y)), (float)(0.0));
            
            //                [display_link invalidate];
            //                [display_link removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        };
        
        return ^ {
//            printf("2\t\t%s\n", __PRETTY_FUNCTION__);
            [display_link invalidate];
            display_link = [CADisplayLink displayLinkWithTarget:eventHandlerBlock selector:@selector(invoke)];
            display_link.preferredFramesPerSecond = frameInterval;
            
            [display_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        };
    };
    /* */
    
    _commandQueue = [_device newCommandQueue];
    
    animation()();
}

- (void)_loadAssets
{
    /// Load assets into metal objects
    
    NSError *error;
    
    MTKMeshBufferAllocator *metalAllocator = [[MTKMeshBufferAllocator alloc]
                                              initWithDevice: _device];
    
    MDLMesh *mdlMesh = [MDLMesh newBoxWithDimensions:(vector_float3){4, 4, 4}
                                            segments:(vector_uint3){2, 2, 2}
                                        geometryType:MDLGeometryTypeTriangles
                                       inwardNormals:NO
                                           allocator:metalAllocator];
    
    MDLVertexDescriptor *mdlVertexDescriptor =
    MTKModelIOVertexDescriptorFromMetal(_mtlVertexDescriptor);
    
    mdlVertexDescriptor.attributes[VertexAttributePosition].name  = MDLVertexAttributePosition;
    mdlVertexDescriptor.attributes[VertexAttributeTexcoord].name  = MDLVertexAttributeTextureCoordinate;
    
    mdlMesh.vertexDescriptor = mdlVertexDescriptor;
    
    _mesh = [[MTKMesh alloc] initWithMesh:mdlMesh
                                   device:_device
                                    error:&error];
    
    if(!_mesh || error)
    {
        NSLog(@"Error creating MetalKit mesh %@", error.localizedDescription);
    }
    
    MTKTextureLoader* textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
    
    NSDictionary *textureLoaderOptions =
    @{
        MTKTextureLoaderOptionTextureUsage       : @(MTLTextureUsageShaderRead),
        MTKTextureLoaderOptionTextureStorageMode : @(MTLStorageModePrivate)
    };
    
    _colorMap = [textureLoader newTextureWithName:@"ColorMap"
                                      scaleFactor:1.0
                                           bundle:nil
                                          options:textureLoaderOptions
                                            error:&error];
    
    if(!_colorMap || error)
    {
        NSLog(@"Error creating texture %@", error.localizedDescription);
    }
    
    /* */
    captureDevicePropertyControlLayoutBufferPtr[0].arc_center_xy__radius_z = simd_make_float3(simd_make_float2((float)CGRectGetMaxX(UIScreen.mainScreen.bounds), (float)CGRectGetMaxY(UIScreen.mainScreen.bounds)), (float)CGRectGetMidX(UIScreen.mainScreen.bounds));
}


//- (void)_updateGameState
//{
//    /// Update any game state before encoding renderint commands to our drawable
//
//    Uniforms * uniforms = (Uniforms*)_dynamicUniformBuffer[_uniformBufferIndex].contents;
//
//    uniforms->projectionMatrix = _projectionMatrix;
//
//    vector_float3 rotationAxis = {1, 1, 0};
//    matrix_float4x4 modelMatrix = matrix4x4_rotation(_rotation, rotationAxis);
//    matrix_float4x4 viewMatrix = matrix4x4_translation(0.0, 0.0, -8.0);
//
//    uniforms->modelViewMatrix = matrix_multiply(viewMatrix, modelMatrix);
//
//    _rotation += .01;
//
//    /* */
//    captureDevicePropertyControlLayoutBufferPtr[0].touch_point_xy__angle_z = simd_make_float3(simd_make_float2((float)(touch_point.x), (float)(touch_point.y)), (float)(0.0));
//}

//- (void)drawInMTKView:(nonnull MTKView *)view
//{
//    /// Per frame updates here
//
////    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);
//            id<CAMetalDrawable> layerDrawable = [(CAMetalLayer *)(view.layer) nextDrawable];
//
//    _uniformBufferIndex = (_uniformBufferIndex + 1) % MaxBuffersInFlight;
//
//    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
//    commandBuffer.label = @"MyCommand";
//
////    __block dispatch_semaphore_t block_sema = _inFlightSemaphore;
//    [commandBuffer addCompletedHandler:^ (id<MTLBuffer> buffer) {
//        return ^ (id<MTLCommandBuffer> _Nonnull commands) {
//
////            dispatch_semaphore_signal(block_sema);
//
//            set_radius((CGFloat)(*self->captureDevicePropertyControlLayoutBufferPtr).arc_center_xy__radius_z.z);
//
//            //            printf("\ntouch_point\t\t\t\t{%.1f, %.1f}\n",
//            //                   (*self->captureDevicePropertyControlLayoutBufferPtr).touch_point_xy__angle_z.x,
//            //                   (*self->captureDevicePropertyControlLayoutBufferPtr).touch_point_xy__angle_z.y);
//            //            for (int i = 0; i < 2; i++) {
//            //                printf("control_points %d\t\t{%.1f, %.1f}\n",
//            //                       i,
//            //                       (*self->captureDevicePropertyControlLayoutBufferPtr).arc_control_points_xyz[i].x,
//            //                       (*self->captureDevicePropertyControlLayoutBufferPtr).arc_control_points_xyz[i].y);
//            //            }
//            //            for (int i = 0; i < 5; i++) {
//            //                printf("button_center  %d\t\t{%.1f, %.1f}\n",
//            //                       i,
//            //                       (*self->captureDevicePropertyControlLayoutBufferPtr).button_center_xy__angle_z[i].x,
//            //                       (*self->captureDevicePropertyControlLayoutBufferPtr).button_center_xy__angle_z[i].y);
//            //            }
//            //            printf("radius\t\t\t\t\t{%.1f}\n",
//            //                   (*self->captureDevicePropertyControlLayoutBufferPtr).arc_center_xy__radius_z.z);
//        };
//    }(captureDevicePropertyControlLayoutBuffer)];
//
////    [self _updateGameState];
//
//    /// Delay getting the currentRenderPassDescriptor until absolutely needed. This avoids
//    ///   holding onto the drawable and blocking the display pipeline any longer than necessary
//    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
//
//    if(renderPassDescriptor != nil)
//    {
//        /// Final pass rendering code here
//
//        id <MTLRenderCommandEncoder> renderEncoder =
//        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
//        renderEncoder.label = @"MyRenderEncoder";
//
//        [renderEncoder pushDebugGroup:@"DrawBox"];
//
//        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
//        [renderEncoder setCullMode:MTLCullModeBack];
//        [renderEncoder setRenderPipelineState:_pipelineState];
//        [renderEncoder setDepthStencilState:_depthState];
//
//        [renderEncoder setVertexBuffer:_dynamicUniformBuffer[_uniformBufferIndex]
//                                offset:0
//                               atIndex:BufferIndexUniforms];
//
//        [renderEncoder setFragmentBuffer:_dynamicUniformBuffer[_uniformBufferIndex]
//                                  offset:0
//                                 atIndex:BufferIndexUniforms];
//
//        for (NSUInteger bufferIndex = 0; bufferIndex < _mesh.vertexBuffers.count; bufferIndex++)
//        {
//            MTKMeshBuffer *vertexBuffer = _mesh.vertexBuffers[bufferIndex];
//            if((NSNull*)vertexBuffer != [NSNull null])
//            {
//                [renderEncoder setVertexBuffer:vertexBuffer.buffer
//                                        offset:vertexBuffer.offset
//                                       atIndex:bufferIndex];
//            }
//        }
//
//        [renderEncoder setFragmentTexture:texture
//                                  atIndex:TextureIndexColor];
//
//        for(MTKSubmesh *submesh in _mesh.submeshes)
//        {
//            [renderEncoder drawIndexedPrimitives:submesh.primitiveType
//                                      indexCount:submesh.indexCount
//                                       indexType:submesh.indexType
//                                     indexBuffer:submesh.indexBuffer.buffer
//                               indexBufferOffset:submesh.indexBuffer.offset];
//        }
//
//        [renderEncoder popDebugGroup];
//
//        [renderEncoder endEncoding];
//
//        [commandBuffer presentDrawable:layerDrawable];// view.currentDrawable];
//    }
//
//    {
//        id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
//        assert(computeEncoder != nil);
//        [computeEncoder setComputePipelineState:_mComputeFunctionPSO];
//        [computeEncoder setBuffer:captureDevicePropertyControlLayoutBuffer offset:0 atIndex:0];
//        MTLSize threadsPerThreadgroup = MTLSizeMake(MIN(sizeof(CaptureDevicePropertyControlLayout), (_mComputeFunctionPSO.maxTotalThreadsPerThreadgroup / _mComputeFunctionPSO.threadExecutionWidth)), 1, 1);
//        MTLSize threadsPerGrid = MTLSizeMake(sizeof(CaptureDevicePropertyControlLayout), 1, 1);
//        [computeEncoder dispatchThreads: threadsPerGrid
//                  threadsPerThreadgroup: threadsPerThreadgroup];
//        [computeEncoder endEncoding];
//    }
//
//    [commandBuffer commit];
//}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    /// Respond to drawable size or orientation changes here
    
    float aspect = size.width / (float)size.height;
    _projectionMatrix = matrix_perspective_right_hand(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0f);
}

#pragma mark Matrix Math Utilities

matrix_float4x4 matrix4x4_translation(float tx, float ty, float tz)
{
    return (matrix_float4x4) {{
        { 1,   0,  0,  0 },
        { 0,   1,  0,  0 },
        { 0,   0,  1,  0 },
        { tx, ty, tz,  1 }
    }};
}

static matrix_float4x4 matrix4x4_rotation(float radians, vector_float3 axis)
{
    axis = vector_normalize(axis);
    float ct = cosf(radians);
    float st = sinf(radians);
    float ci = 1 - ct;
    float x = axis.x, y = axis.y, z = axis.z;
    
    return (matrix_float4x4) {{
        { ct + x * x * ci,     y * x * ci + z * st, z * x * ci - y * st, 0},
        { x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0},
        { x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0},
        {                   0,                   0,                   0, 1}
    }};
}

matrix_float4x4 matrix_perspective_right_hand(float fovyRadians, float aspect, float nearZ, float farZ)
{
    float ys = 1 / tanf(fovyRadians * 0.5);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);
    
    return (matrix_float4x4) {{
        { xs,   0,          0,  0 },
        {  0,  ys,          0,  0 },
        {  0,   0,         zs, -1 },
        {  0,   0, nearZ * zs,  0 }
    }};
}

CaptureDevicePropertyControlLayout control_layout_context(CGRect contextRect)
{
    float minX = (float)CGRectGetMinX(contextRect);
    float midX = (float)CGRectGetMidX(contextRect);
    float mdnX = (float)(((int)midX & (int)minX) + (((int)midX ^ (int)minX) >> 1));
    float maxX = (float)CGRectGetMinX(contextRect);
    float mdxX = (float)(((int)maxX & (int)midX) + (((int)maxX ^ (int)midX) >> 1));
    
    float minY = (float)CGRectGetMinY(contextRect);
    float midY = (float)CGRectGetMidY(contextRect);
    float mdnY = (float)(((int)midY & (int)minY) + (((int)midY ^ (int)minY) >> 1));
    float maxY = (float)CGRectGetMinY(contextRect);
    float mdxY = (float)(((int)maxY & (int)midY) + (((int)maxY ^ (int)midY) >> 1));
    
    return (CaptureDevicePropertyControlLayout) {
        .touch_point_xy__angle_z = {
            (simd_make_float3(simd_make_float2(minX, midY), 0.50))
        },
            .button_center_xy__angle_z = {
                (simd_make_float3(simd_make_float2(minX, maxY), button_angles[0])),
                (simd_make_float3(simd_make_float2(mdnX, mdxY), button_angles[1])),
                (simd_make_float3(simd_make_float2(midX, midY), button_angles[2])),
                (simd_make_float3(simd_make_float2(mdxX, mdnY), button_angles[3])),
                (simd_make_float3(simd_make_float2(maxX, minY), button_angles[4]))
            },
            .arc_center_xy__radius_z = {
                (simd_make_float3(simd_make_float2(maxX, maxY), midX))
            },
            .arc_control_points_xyz = {
                (simd_make_float3(minX, minX, maxX)),
                (simd_make_float3(maxY, midY, midY))
            }
    };
}

void set_touch_point(CGPoint tp) {
    const CGRect ctx = UIScreen.mainScreen.bounds;
    touch_point = simd_make_float2(
                                   simd_clamp((float)tp.x, (float)CGRectGetMinX(ctx), (float)CGRectGetMaxX(ctx)),
                                   simd_clamp((float)tp.y, (float)CGRectGetMidY(ctx), (float)CGRectGetMaxY(ctx)));
}


- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
//    dispatch_async(dispatch_get_main_queue(), ^{
        draw_texture(create_texture(CMSampleBufferGetImageBuffer(sampleBuffer)));
//    });
}

@end
