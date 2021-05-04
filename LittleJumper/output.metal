//
//  output.metal
//  LittleJumper
//
//  Created by Ting on 5/3/21.
//  Copyright © 2021 anjohnlv. All rights reserved.
//



#include <metal_stdlib>
#import "MetalTypes.h"

using namespace metal;

// 定义了一个类型为RasterizerData的结构体，里面有一个float4向量和float2向量，其中float4被[[position]]修饰，其表示的变量为顶点

typedef struct {
    // float4 4维向量 clipSpacePosition参数名
    // position 修饰符的表示顶点 语法是[[position]]，这是苹果内置的语法和position关键字不能改变
    float4 clipSpacePosition [[position]];
    
    // float2 2维向量  表示纹理
    float2 textureCoordinate;
    
} RasterizerData;

// 顶点函数通过一个自定义的结构体，返回对应的数据，顶点函数的输入参数也可以是自定义结构体

// 顶点函数
// vertex 函数修饰符表示顶点函数，
// RasterizerData返回值类型，
// vertexImageShader函数名
// vertex_id 顶点id修饰符，苹果内置不可变，[[vertex_id]]
// buffer 缓存数据修饰符，苹果内置不可变，YYImageVertexInputIndexVertexs是索引
// [[buffer(YYImageVertexInputIndexVertexs)]]
// constant 变量类型修饰符，表示存储在device区域

vertex RasterizerData vertexVideoShader(uint vertexID [[vertex_id]], constant YYVideoVertex * vertexArray [[buffer(YYVideoVertexInputIndexVertexs)]]) {
    
    RasterizerData outData;
    
    // 获取YYVertex里面的顶点坐标和纹理坐标
    outData.clipSpacePosition = vertexArray[vertexID].position;
    outData.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    
    return outData;
}

// 片元函数
// fragment 函数修饰符表示片元函数 float4 返回值类型->颜色RGBA fragmentImageShader 函数名
// RasterizerData 参数类型 input 变量名
// [[stage_in] stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
// texture2d 类型表示纹理 baseTexture 变量名
// [[ texture(index)]] 纹理修饰符
// 可以加索引 [[ texture(0)]]纹理0， [[ texture(1)]]纹理1
// YYImageTextureIndexBaseTexture表示纹理索引

fragment float4 fragmentVideoShader(RasterizerData input [[stage_in]], texture2d<float> textureY [[texture (YYVidoTextureIndexYTexture)]], texture2d<float> textureUV [[texture(YYVidoTextureIndexUVTexture)]], constant YYVideoYUVToRGBConvertMatrix * convertMatrix [[buffer(YYVideoConvertMatrixIndexYUVToRGB)]]) {
    
    // constexpr 修饰符
    // sampler 采样器
    // textureSampler 采样器变量名
    // mag_filter:: linear, min_filter:: linear 设置放大缩小过滤方式
    constexpr sampler textureSampler(mag_filter:: linear, min_filter:: linear);
    
    // 得到纹理对应位置的颜色
//    float YColor = textureY.sample(textureSampler, input.textureCoordinate).r;
//    float2 UVColor = textureUV.sample(textureSampler, input.textureCoordinate).rg;
//    float3 color = float3(YColor, UVColor);
//    float3 outputColor = matrix->matrix * (color + matrix->offset);
    
    float3 yuv = float3(textureY.sample(textureSampler, input.textureCoordinate).r,
                        textureUV.sample(textureSampler, input.textureCoordinate).rg);
    
    //3.将YUV 转化为 RGB值.convertMatrix->matrix * (YUV + convertMatrix->offset)
    float3 rgb = convertMatrix->matrix * (yuv + convertMatrix->offset);

    // 返回颜色值
    return float4(rgb, 1.0);
}

void rgb2hsv(texture2d<float, access::read> inTexture [[texture(0)]],
             texture2d<float, access::write> outTexture [[texture(1)]],
             uint2 gid [[thread_position_in_grid]]) {
    float4 c = inTexture.read(gid);
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = c.z < c.y ? float4(c.yz, K.wz) : float4(c.zy, K.xy);
    float4 q = c.w < p.x ? float4(p.xyw, c.w) : float4(c.w, p.yzx);
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    //    float4 hsv = float4(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x, 1.0);
    outTexture.write(float4(d / (q.x + e), 0, 0, 0), gid);
}


kernel void
rgb2hsvKernelNonuniform(texture2d<float, access::read> inTexture [[texture(0)]],
              texture2d<float, access::write> outTexture [[texture(1)]],
              uint2 gid [[thread_position_in_grid]])
{
    rgb2hsv(inTexture, outTexture, gid);
}
