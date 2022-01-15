//
//  Shaders.metal
//  AVDemonCamManualMetalII
//
//  Created by Xcode Developer on 1/13/22.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.texCoord = in.texCoord;

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);

    half4 colorSample   = colorMap.sample(colorSampler, in.texCoord.xy);

    return float4(colorSample);
}

kernel void computeKernel(device CaptureDevicePropertyControlLayout & layout [[ buffer(0) ]],
                          uint idx [[ thread_position_in_grid ]])
{
    // TO-DO: Simply plot control points of bezier curve for button center (all this other math is grossly unnecessary)
    
    layout.arc_center_xy__radius_z.z = sqrt(pow(layout.touch_point_xy__angle_z.x - layout.arc_center_xy__radius_z.x, 2.0) +
                                            pow(layout.touch_point_xy__angle_z.y - layout.arc_center_xy__radius_z.y, 2.0));
    layout.touch_point_xy__angle_z.z =    atan2(layout.touch_point_xy__angle_z.y - layout.arc_center_xy__radius_z.y,
                                                layout.touch_point_xy__angle_z.x - layout.arc_center_xy__radius_z.x) * (180.0 / M_PI_F);
    if (layout.touch_point_xy__angle_z.z < 0.0) layout.touch_point_xy__angle_z.z += 360.0;
    
    for (int property = 0; property < 5; property++) {
        float time = layout.button_center_xy__angle_z[property].z;
        float x = (1 - time) * (1 - time) * layout.arc_control_points_xyz[0].x + 2 * (1 - time) * time * layout.arc_control_points_xyz[0].y + time * time * layout.arc_control_points_xyz[0].z;
        float y = (1 - time) * (1 - time) * layout.arc_control_points_xyz[1].x + 2 * (1 - time) * time * layout.arc_control_points_xyz[1].y + time * time * layout.arc_control_points_xyz[1].z;
        layout.button_center_xy__angle_z[property] = vector_float3(vector_float2(x, y), layout.button_center_xy__angle_z[property].z);
    }
}
