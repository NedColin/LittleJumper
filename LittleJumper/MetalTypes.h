//
//  MetalTypes.h
//  LittleJumper
//
//  Created by Ting on 5/3/21.
//  Copyright © 2021 anjohnlv. All rights reserved.
//

#ifndef MetalTypes_h
#define MetalTypes_h

#include <simd/simd.h>

// 顶点坐标和纹理坐标数据结构
typedef struct {
    // 顶点坐标 4维向量
    vector_float4 position;
    
    // 纹理坐标
    vector_float2 textureCoordinate;
    
} YYVideoVertex;

//颜色转换数据结构 YUV转RGBA 转换矩阵
typedef struct {
    
    //三维矩阵
    matrix_float3x3 matrix;
    //偏移量
    vector_float3 offset;
    
} YYVideoYUVToRGBConvertMatrix;


// 顶点index
typedef enum {
    
    YYVideoVertexInputIndexVertexs = 0,
    
} YYVideoVertexInputIndex;


// 纹理 index
typedef enum {
    
    // Y纹理索引 index
    YYVidoTextureIndexYTexture = 0,
    
    // UV纹理索引 index
    YYVidoTextureIndexUVTexture = 1,
    
} YYVideoTextureIndex;


// 颜色转换结构体 index
typedef enum {
    
    YYVideoConvertMatrixIndexYUVToRGB = 0,
    
    
} YYVideoConvertMatrixIndex;

#endif /* MetalTypes_h */
